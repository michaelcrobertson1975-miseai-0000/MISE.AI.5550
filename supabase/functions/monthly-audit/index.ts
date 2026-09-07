// @ts-nocheck
import { createClient } from 'jsr:@supabase/supabase-js@2';
import { parseServiceAccount, getAccessToken } from './googleAuth.js';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
};
const json = (b, s = 200) => new Response(JSON.stringify(b, null, 2), { status: s, headers: { ...CORS, 'Content-Type': 'application/json' } });
const db = () => createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));

const SA_NAMES = ['GCP_SERVICE_ACCOUNT_JSON','GCP_SERVICE_ACCOUNT_KEY','GOOGLE_SERVICE_ACCOUNT_KEY','VERTEX_SERVICE_ACCOUNT_KEY'];
const KEY_NAMES = ['GEMINI_API_KEY','GOOGLE_API_KEY','GOOGLE_GENAI_API_KEY','GEMINI_KEY','GOOGLE_GEMINI_API_KEY'];
const MODEL_FALLBACKS = ['gemini-3.7-flash','gemini-3.6-flash','gemini-3.5-flash','gemini-2.5-flash'];

function findKey() {
  for (const name of KEY_NAMES) { const v = Deno.env.get(name); if (v) return v; }
  return null;
}
function vertexConfig() {
  const raw = SA_NAMES.map((n) => Deno.env.get(n)).find(Boolean);
  if (!raw) return null;
  const serviceAccount = parseServiceAccount(raw);
  const project = Deno.env.get('GCP_PROJECT_ID') ?? serviceAccount.project_id;
  const region = Deno.env.get('GCP_REGION') ?? 'global';
  if (!project) throw new Error('Vertex needs a project id: set GCP_PROJECT_ID or use a service account JSON carrying project_id.');
  return { serviceAccount, project, region };
}

async function authClient(supabase, restaurantId, apiToken) {
  if (!restaurantId || !apiToken) return { error: 'restaurant_id and api_token are both required.' };
  const { data, error } = await supabase.from('clients').select('id, name, status, api_token').eq('id', restaurantId).maybeSingle();
  if (error) return { error: error.message };
  if (!data) return { error: 'No such restaurant.' };
  if (String(data.api_token) !== String(apiToken)) return { error: 'Wrong api_token for this restaurant_id.' };
  if (!['active', 'trial'].includes(data.status)) return { error: `This account is ${data.status}.` };
  return { client: data };
}

function monthRange(year, month) {
  const start = `${year}-${String(month).padStart(2, '0')}-01`;
  const endDate = new Date(Date.UTC(year, month, 0));
  const end = endDate.toISOString().slice(0, 10);
  return { start, end, period: start, label: `${year}-${String(month).padStart(2, '0')}` };
}

async function gatherData(supabase, clientId, range) {
  const { data: invoices } = await supabase.from('invoices')
    .select('id, vendor_name, invoice_date, grand_total')
    .eq('client_id', clientId).eq('status', 'completed')
    .gte('invoice_date', range.start).lte('invoice_date', range.end);

  const spendByVendor = new Map();
  let totalSpend = 0;
  for (const inv of invoices ?? []) {
    const amt = Number(inv.grand_total) || 0;
    totalSpend += amt;
    spendByVendor.set(inv.vendor_name ?? 'Unknown', (spendByVendor.get(inv.vendor_name ?? 'Unknown') ?? 0) + amt);
  }

  const { data: priceMoves } = await supabase.from('v_item_price_variance')
    .select('item_description, unit_cost_delta_pct, dollar_impact, invoice_date')
    .eq('client_id', clientId).gte('invoice_date', range.start).lte('invoice_date', range.end)
    .order('dollar_impact', { ascending: false }).limit(500);
  const topMoves = (priceMoves ?? [])
    .filter((m) => m.unit_cost_delta_pct != null)
    .sort((a, b) => Math.abs(b.dollar_impact ?? 0) - Math.abs(a.dollar_impact ?? 0))
    .slice(0, 8);

  const { data: periods } = await supabase.from('pnl_periods')
    .select('id, period_start, period_end, label, gross_sales, labor_kitchen, labor_management, labor_front_house, notes')
    .eq('client_id', clientId).lte('period_start', range.end).gte('period_end', range.start);

  let manualCosts = [];
  if ((periods ?? []).length) {
    const { data } = await supabase.from('pnl_manual_costs').select('category, description, amount')
      .in('period_id', periods.map((p) => p.id));
    manualCosts = data ?? [];
  }

  const { data: nightly } = await supabase.from('nightly_reports')
    .select('report_date, sales_amount, labor_cost')
    .eq('client_id', clientId).gte('report_date', range.start).lte('report_date', range.end);
  const nightlySales = (nightly ?? []).reduce((s, r) => s + (Number(r.sales_amount) || 0), 0);
  const nightlyLabor = (nightly ?? []).reduce((s, r) => s + (Number(r.labor_cost) || 0), 0);

  const { data: yieldLog } = await supabase.from('prep_yield_log')
    .select('entry_type, status, expected_portions, actual_portions, weight_in, weight_out, logged_at')
    .eq('client_id', clientId).gte('logged_at', range.start).lte('logged_at', range.end + 'T23:59:59');

  return {
    invoice_count: (invoices ?? []).length,
    total_invoiced_spend: Math.round(totalSpend * 100) / 100,
    spend_by_vendor: Object.fromEntries([...spendByVendor.entries()].map(([k, v]) => [k, Math.round(v * 100) / 100])),
    top_price_moves: topMoves,
    pnl_periods_on_file: (periods ?? []).map((p) => ({ ...p, id: undefined })),
    manual_costs_on_file: manualCosts,
    nightly_reports_count: (nightly ?? []).length,
    nightly_sales_total: nightly?.length ? Math.round(nightlySales * 100) / 100 : null,
    nightly_labor_total: nightly?.length ? Math.round(nightlyLabor * 100) / 100 : null,
    prep_yield_entries: (yieldLog ?? []).length,
    prep_yield_sample: (yieldLog ?? []).slice(0, 20),
  };
}

const RESULT_SCHEMA = {
  type: 'OBJECT',
  properties: {
    overview: { type: 'STRING', description: 'What the month actually was, 2-4 sentences, grounded only in the data given.' },
    money_leaks: { type: 'ARRAY', items: { type: 'STRING' }, description: 'Specific price moves or spend patterns from the data, with $ amounts. Empty array if none stood out.' },
    product_mix_notes: { type: 'STRING', nullable: true, description: 'Only if product mix / sales data was provided; otherwise null -- do not guess.' },
    budget_vs_actual: { type: 'STRING', nullable: true, description: 'Only if pnl_periods/manual costs were provided; otherwise null stating that no budget was entered this period.' },
    next_steps: { type: 'ARRAY', items: { type: 'STRING' }, description: 'Exactly 3 concrete, specific actions grounded in this data.' },
    data_gaps: { type: 'ARRAY', items: { type: 'STRING' }, description: 'What data was missing for this period that would have made the audit more complete (e.g. no manual sales/labor entered, no nightly reports).' },
  },
  required: ['overview', 'money_leaks', 'next_steps', 'data_gaps'],
};

function buildBody(restaurantName, range, data) {
  const systemInstruction = `You are writing a monthly operations audit for a restaurant owner, from real Postgres data only. Never invent a number that is not in the data provided. If something needed for a full audit (sales, labor, product mix) is missing, say so plainly in data_gaps instead of estimating it. Be specific and use real dollar figures from the data. Write for a busy restaurant owner: direct, concrete, no filler.`;
  const userText = `Restaurant: ${restaurantName}\nPeriod: ${range.label}\n\nDATA:\n${JSON.stringify(data, null, 2)}\n\nWrite the audit.`;
  return JSON.stringify({
    systemInstruction: { parts: [{ text: systemInstruction }] },
    contents: [{ role: 'user', parts: [{ text: userText }] }],
    generationConfig: { temperature: 0.3, responseMimeType: 'application/json', responseSchema: RESULT_SCHEMA, maxOutputTokens: 4096 },
  });
}

function extractText(payload) {
  const candidate = payload?.candidates?.[0];
  if (!candidate) throw new Error(payload?.promptFeedback?.blockReason ? `Blocked: ${payload.promptFeedback.blockReason}` : 'No candidates returned.');
  const text = (candidate.content?.parts ?? []).map((p) => p.text ?? '').join('').trim();
  if (!text) throw new Error('Empty response body.');
  return JSON.parse(text.replace(/^```(?:json)?\s*/i, '').replace(/\s*```$/, ''));
}

async function callGemini(restaurantName, range, data) {
  const body = buildBody(restaurantName, range, data);
  const vertex = vertexConfig();
  const tried = [];

  if (vertex) {
    const token = await getAccessToken(vertex.serviceAccount);
    const host = vertex.region === 'global' ? 'aiplatform.googleapis.com' : `${vertex.region}-aiplatform.googleapis.com`;
    for (const model of MODEL_FALLBACKS) {
      const endpoint = `https://${host}/v1/projects/${vertex.project}/locations/${vertex.region}/publishers/google/models/${encodeURIComponent(model)}:generateContent`;
      const res = await fetch(endpoint, { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` }, body });
      if (res.ok) return { result: extractText(await res.json()), model };
      tried.push(`vertex:${model} -> ${res.status}`);
    }
  }

  const apiKey = findKey();
  if (apiKey) {
    for (const model of MODEL_FALLBACKS) {
      const res = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(model)}:generateContent`, {
        method: 'POST', headers: { 'Content-Type': 'application/json', 'x-goog-api-key': apiKey }, body,
      });
      if (res.ok) return { result: extractText(await res.json()), model };
      tried.push(`ai-studio:${model} -> ${res.status}`);
    }
  }

  if (!vertex && !apiKey) throw new Error(`No Gemini credential found (checked ${SA_NAMES.join(', ')}, ${KEY_NAMES.join(', ')}).`);
  throw new Error(`No usable Gemini model. Tried: ${tried.join('; ')}`);
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  const url = new URL(req.url);
  const supabase = db();

  try {
    if (req.method === 'GET' && url.searchParams.get('run') === '1') {
      const auth = await authClient(supabase, url.searchParams.get('restaurant_id'), url.searchParams.get('api_token'));
      if (auth.error) return json({ success: false, error: auth.error }, 401);
      const year = Number(url.searchParams.get('year')), month = Number(url.searchParams.get('month'));
      const range = monthRange(year, month);
      const data = await gatherData(supabase, auth.client.id, range);
      try {
        const generated = await callGemini(auth.client.name, range, data);
        return json({ success: true, period: range.label, generated, data_used: data });
      } catch (err) {
        return json({ success: false, error: `Model call failed: ${err.message}`, data_used: data });
      }
    }

    if (req.method === 'GET') {
      const auth = await authClient(supabase, url.searchParams.get('restaurant_id'), url.searchParams.get('api_token'));
      if (auth.error) return json({ success: false, error: auth.error }, 401);
      const year = Number(url.searchParams.get('year'));
      const month = Number(url.searchParams.get('month'));
      if (!year || !month) return json({ success: false, error: 'year and month are required.' }, 400);
      const range = monthRange(year, month);

      const { data, error } = await supabase.from('monthly_audits').select('*')
        .eq('client_id', auth.client.id).eq('period', range.period).maybeSingle();
      if (error) return json({ success: false, error: error.message }, 500);
      if (!data) return json({ success: true, exists: false, period: range.label });
      return json({ success: true, exists: true, period: range.label, narrative: data.narrative, highlights: data.highlights, model_used: data.model_used, generated_at: data.generated_at });
    }

    if (req.method === 'POST') {
      let body;
      try { body = await req.json(); } catch (err) { return json({ success: false, error: `Unparseable body: ${err.message}` }, 400); }
      const auth = await authClient(supabase, body.restaurant_id, body.api_token);
      if (auth.error) return json({ success: false, error: auth.error }, 401);
      const year = Number(body.year), month = Number(body.month);
      if (!year || !month || month < 1 || month > 12) return json({ success: false, error: 'year and month (1-12) are required.' }, 400);

      const range = monthRange(year, month);
      const data = await gatherData(supabase, auth.client.id, range);

      let generated;
      try {
        generated = await callGemini(auth.client.name, range, data);
      } catch (err) {
        return json({ success: false, error: `Model call failed: ${err.message}` }, 502);
      }

      const narrative = generated.result.overview;
      const { data: saved, error: saveErr } = await supabase.from('monthly_audits')
        .upsert({
          client_id: auth.client.id, period: range.period, narrative,
          highlights: generated.result, model_used: generated.model, generated_at: new Date().toISOString(),
        }, { onConflict: 'client_id,period' })
        .select('*').single();
      if (saveErr) return json({ success: false, error: `Generated but failed to save: ${saveErr.message}`, highlights: generated.result }, 500);

      return json({ success: true, period: range.label, narrative: saved.narrative, highlights: saved.highlights, model_used: saved.model_used, data_used: data });
    }

    return json({ success: false, error: `${req.method} not supported.` }, 405);
  } catch (err) {
    console.error('[monthly-audit] unhandled:', err?.message ?? err);
    return json({ success: false, error: err?.message ?? String(err) }, 500);
  }
});
