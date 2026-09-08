// @ts-nocheck
/**
 * Nightly sales report ingestion.
 *
 * Receives the nightly POS summary (sales, labor, product mix by POS button)
 * as an email attachment, reads it with Gemini (transcription only, same
 * division of labor as invoices - Gemini reads, Postgres does the math), then
 * calls mise_apply_nightly_depletion to drain beverage_items stock based on
 * each POS button's matching BOM.
 *
 * ASSUMPTION FLAGGED: this assumes the report arrives as an image or PDF
 * attachment, the same way every invoice does. That has not been confirmed
 * against a real report yet - if the actual format turns out to be a CSV or
 * spreadsheet export instead, this needs a different reader, not a tweak.
 *
 *   GET  ?probe=1                     -> config check
 *   POST ?client_id=<uuid>  {files:[{...}]}
 */
import { createClient } from 'jsr:@supabase/supabase-js@2';
import { encodeBase64, decodeBase64 } from 'jsr:@std/encoding@1/base64';

const KEY_NAMES = ['GEMINI_API_KEY','GOOGLE_API_KEY','GOOGLE_GENAI_API_KEY','GEMINI_KEY','GOOGLE_GEMINI_API_KEY'];
const MODEL_FALLBACKS = ['gemini-3.7-flash','gemini-3.6-flash','gemini-3.5-flash','gemini-2.5-flash'];
const API_BASE = 'https://generativelanguage.googleapis.com/v1beta';

const json = (body, status = 200) =>
  new Response(JSON.stringify(body, null, 2), { status, headers: { 'Content-Type': 'application/json' } });

/**
 * INTERNAL ONLY. These two ingestion functions cost real money per page and
 * write straight into a restaurant's books, so they are not part of the public
 * surface. Callers are the queue worker and upload-scan, both of which run
 * server-side and hold the service-role key. A caller holding only the anon
 * key -- which is published in the front end by design -- is refused.
 */
function callerIsInternal(req) {
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!serviceKey) return false;
  const auth = req.headers.get('authorization') ?? '';
  const bearer = auth.replace(/^Bearer\s+/i, '').trim();
  return bearer === serviceKey;
}

function findKey() {
  for (const name of KEY_NAMES) {
    const value = Deno.env.get(name);
    if (value) return value;
  }
  return null;
}

const SCHEMA = {
  type: 'OBJECT',
  properties: {
    report_date: { type: 'STRING', nullable: true, description: 'Report date as YYYY-MM-DD, if printed.' },
    sales_amount: { type: 'NUMBER', nullable: true, description: 'Total gross sales for the day/night, if printed.' },
    labor_cost: { type: 'NUMBER', nullable: true, description: 'Total labor cost in dollars, if printed. Null if the report only shows hours, not a dollar figure.' },
    product_mix: {
      type: 'ARRAY',
      items: {
        type: 'OBJECT',
        properties: {
          pos_button: { type: 'STRING', description: 'The menu/POS item name exactly as printed.' },
          qty_sold: { type: 'NUMBER' },
        },
        required: ['pos_button', 'qty_sold'],
      },
    },
  },
  required: ['report_date', 'sales_amount', 'labor_cost', 'product_mix'],
};

const SYSTEM_INSTRUCTION = `ROLE: Transcribe a restaurant's nightly POS sales report into JSON.

You are a transcriber, not a calculator. Never compute, sum, or convert anything - report exactly what is printed. If a figure is not printed, it is null.

RULES:
1. Include EVERY item on the product mix / sales-by-item section, food and drink alike - do not filter to only beverages. Downstream code decides what each item means.
2. qty_sold is however many were sold/rung up that period - not revenue, not price.
3. sales_amount is the total gross sales dollar figure, if printed. labor_cost is a dollar figure, if printed - if the report only shows labor HOURS with no dollar cost, leave labor_cost null.
4. Skip subtotal/tax/discount summary lines that are not individual menu items.
5. If illegible or absent, use null. Never guess.`;

const USER_INSTRUCTION = 'Transcribe this nightly sales report. List every item sold with its quantity. Report sales_amount and labor_cost only if printed as dollar figures.';

async function callGemini(bytes, mimeType, apiKey) {
  const body = JSON.stringify({
    systemInstruction: { parts: [{ text: SYSTEM_INSTRUCTION }] },
    contents: [{ role: 'user', parts: [
      { inlineData: { mimeType, data: encodeBase64(bytes) } },
      { text: USER_INSTRUCTION },
    ] }],
    generationConfig: { temperature: 0, responseMimeType: 'application/json', responseSchema: SCHEMA, maxOutputTokens: 16384 },
  });
  const tried = [];
  for (const model of MODEL_FALLBACKS) {
    const res = await fetch(`${API_BASE}/models/${model}:generateContent`, {
      method: 'POST', headers: { 'Content-Type': 'application/json', 'x-goog-api-key': apiKey }, body,
    });
    if (res.ok) {
      const payload = await res.json();
      const text = (payload.candidates?.[0]?.content?.parts ?? []).map((p) => p.text ?? '').join('').trim();
      return { data: JSON.parse(text.replace(/^```(?:json)?\s*/i, '').replace(/\s*```$/, '')), model };
    }
    tried.push(`${model} -> ${res.status}`);
  }
  throw new Error(`No usable Gemini model. Tried: ${tried.join('; ')}`);
}

Deno.serve(async (req) => {
  const url = new URL(req.url);
  const key = findKey();

  if (req.method === 'GET' || url.searchParams.get('probe')) {
    return json({
      ok: Boolean(key),
      purpose: 'Reads a nightly POS sales report and drains beverage inventory via the matching BOM.',
      assumption_flagged: 'Assumes the report arrives as an image/PDF attachment, same as invoices. NOT yet confirmed against a real report.',
      gemini_secret_found: Boolean(key),
    }, key ? 200 : 503);
  }
  if (req.method !== 'POST') return json({ error: 'POST only.' }, 405);
  if (!callerIsInternal(req)) return json({ error: 'This endpoint is internal. Nightly reports arrive through the inbound-email queue.' }, 401);
  if (!key) return json({ error: `No Gemini credential. Set one of ${KEY_NAMES.join(', ')}.` }, 503);

  const clientId = url.searchParams.get('client_id');
  if (!clientId) return json({ error: 'client_id query parameter is required.' }, 400);

  let files;
  try {
    const body = await req.json();
    files = Array.isArray(body?.files) ? body.files : [];
    if (!files.length) throw new Error('No files array.');
  } catch (err) {
    return json({ error: `Unparseable body: ${err.message}` }, 400);
  }

  const db = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));

  let extracted;
  try {
    const first = files[0];
    const bytes = decodeBase64(first.data ?? first.content ?? '');
    const mimeType = (first.mimeType ?? first.type ?? 'image/jpeg').split(';')[0].trim();
    const result = await callGemini(bytes, mimeType, key);
    extracted = result.data;
    extracted._model = result.model;
  } catch (err) {
    console.error('[nightly-report] extraction failed:', err.message);
    return json({ stage: 'extraction', error: err.message }, 502);
  }

  const { data: report, error: insErr } = await db.from('nightly_reports').insert({
    client_id: clientId,
    report_date: extracted.report_date ?? null,
    sales_amount: extracted.sales_amount ?? null,
    labor_cost: extracted.labor_cost ?? null,
    model_used: extracted._model ?? null,
  }).select('id').single();

  if (insErr) {
    console.error('[nightly-report] insert failed:', insErr.message);
    return json({ stage: 'insert_report', error: insErr.message }, 500);
  }

  const mixRows = (extracted.product_mix ?? []).map((m) => ({
    nightly_report_id: report.id,
    pos_button: m.pos_button,
    qty_sold: m.qty_sold,
  }));

  if (mixRows.length) {
    const { error: mixErr } = await db.from('nightly_product_mix').insert(mixRows);
    if (mixErr) {
      console.error('[nightly-report] product mix insert failed:', mixErr.message);
      return json({ stage: 'insert_product_mix', error: mixErr.message, report_id: report.id }, 500);
    }
  }

  const { data: depletion, error: depErr } = await db.rpc('mise_apply_nightly_depletion', { p_nightly_report_id: report.id });
  if (depErr) {
    console.error('[nightly-report] depletion failed:', depErr.message);
    return json({ stage: 'depletion', error: depErr.message, report_id: report.id }, 500);
  }

  const matched = (depletion ?? []).filter((d) => d.matched);
  const unmatched = (depletion ?? []).filter((d) => !d.matched);
  console.log(`[nightly-report] report_id=${report.id} date=${extracted.report_date} sales=${extracted.sales_amount} items=${mixRows.length} matched_to_bom=${matched.length} unmatched=${unmatched.length}`);

  return json({
    status: 'PROCESSED',
    report_id: report.id,
    report_date: extracted.report_date,
    sales_amount: extracted.sales_amount,
    labor_cost: extracted.labor_cost,
    items_reported: mixRows.length,
    drained_from_inventory: matched,
    no_bom_match: unmatched.map((u) => u.pos_button),
  }, 201);
});
