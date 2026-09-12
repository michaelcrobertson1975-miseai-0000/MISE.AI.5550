// @ts-nocheck
/**
 * MiseAI invoice ingestion - Supabase Edge Function.
 *
 * CROSS-BATCH ATTACH. email-inbound splits very large attachment sets into more
 * than one request. Before inserting a new invoice header, this checks for an
 * existing LIVE invoice with the same client + invoice number FIRST - it does
 * not wait for the database's one-live-per-number rule to block it, because
 * that rule also requires vendor_name to match exactly, and the same invoice's
 * vendor name can be transcribed differently page to page ("Sysco SAN
 * FRANCISCO, INC." on the letterhead page vs plain "Sysco" on a page without
 * it) - relying on that match alone let a real duplicate through. Matching on
 * invoice number alone, per client, is what actually catches it. The database
 * rule stays in place underneath as a second, defensive layer.
 */
import { createClient } from 'jsr:@supabase/supabase-js@2';
import { encodeBase64, decodeBase64 } from 'jsr:@std/encoding@1/base64';
import { invoiceSchema } from './schema.js';
import { SYSTEM_INSTRUCTION, USER_INSTRUCTION } from './prompt.js';
import { parseServiceAccount, getAccessToken } from './googleAuth.js';

const SA_NAMES = ['GCP_SERVICE_ACCOUNT_JSON','GCP_SERVICE_ACCOUNT_KEY','GOOGLE_SERVICE_ACCOUNT_KEY','VERTEX_SERVICE_ACCOUNT_KEY'];
const KEY_NAMES = ['GEMINI_API_KEY','GOOGLE_API_KEY','GOOGLE_GENAI_API_KEY','GEMINI_KEY','GOOGLE_GEMINI_API_KEY'];
const MODEL_FALLBACKS = ['gemini-3.8-flash','gemini-3.7-flash','gemini-3.6-flash','gemini-3.5-flash','gemini-2.5-flash'];
const API_BASE = 'https://generativelanguage.googleapis.com/v1beta';
const INVOICE_BUCKET = 'invoice-files';
const MAX_PAGES = 24;
const MAX_OUTPUT_TOKENS = 32768;
const ONE_LIVE_PER_NUMBER_INDEX = 'invoices_one_live_per_number';

const FILE_EXT = {
  'application/pdf': 'pdf', 'image/jpeg': 'jpg', 'image/jpg': 'jpg',
  'image/png': 'png', 'image/webp': 'webp', 'image/heic': 'heic', 'image/heif': 'heif',
};

function vertexConfig() {
  const raw = SA_NAMES.map((n) => Deno.env.get(n)).find(Boolean);
  if (!raw) return null;
  const serviceAccount = parseServiceAccount(raw);
  const project = Deno.env.get('GCP_PROJECT_ID') ?? serviceAccount.project_id;
  const region = Deno.env.get('GCP_REGION') ?? 'global';
  if (!project) throw new Error('Vertex needs a project id: set GCP_PROJECT_ID or use a service account JSON carrying project_id.');
  return { serviceAccount, project, region };
}

const json = (body, status = 200) =>
  new Response(JSON.stringify(body, null, 2), { status, headers: { 'Content-Type': 'application/json' } });

function findKey() {
  for (const name of KEY_NAMES) {
    const value = Deno.env.get(name);
    if (value) return { name, value };
  }
  return null;
}

async function readPages(req) {
  const ct = (req.headers.get('content-type') ?? 'application/pdf').split(';')[0].trim();
  if (ct === 'application/json') {
    const body = await req.json();
    const list = Array.isArray(body?.files) ? body.files : [];
    if (!list.length) throw new Error('JSON body carried no files array.');
    if (list.length > MAX_PAGES) throw new Error(`${list.length} pages exceeds the ${MAX_PAGES} page limit.`);
    return list.map((f, i) => ({
      name: f.name ?? `page-${i + 1}`,
      mimeType: (f.mimeType ?? f.type ?? 'image/jpeg').split(';')[0].trim(),
      bytes: decodeBase64(f.data ?? f.content ?? ''),
    }));
  }
  const bytes = new Uint8Array(await req.arrayBuffer());
  if (bytes.length === 0) throw new Error('Empty body. Send the file with curl --data-binary @invoice.pdf');
  return [{ name: 'page-1', mimeType: ct, bytes }];
}

const keyOf = (n) => {
  const k = String(n ?? '').toUpperCase().replace(/[^A-Z0-9]/g, '');
  return k.length >= 3 ? k : null;
};

function groupByInvoiceNumber(readings, pages) {
  const groups = [];
  const byKey = new Map();
  let previous = null;
  let pending = null;

  for (let i = 0; i < readings.length; i++) {
    const key = keyOf(readings[i].invoice_number);
    if (key) {
      let g = byKey.get(key);
      const isNewGroup = !g;
      if (!g) { g = { key, parts: [], pages: [], notes: [] }; byKey.set(key, g); groups.push(g); }
      if (isNewGroup && pending) {
        g.parts.unshift(...pending.parts);
        g.pages.unshift(...pending.pages);
        for (const p of pending.pages) {
          g.notes.push(`${p.name} carried no readable invoice number; attached forward once a later page revealed "${readings[i].invoice_number}".`);
        }
        pending = null;
      }
      g.parts.push(readings[i]); g.pages.push(pages[i]); previous = g;
    } else if (previous) {
      previous.parts.push(readings[i]); previous.pages.push(pages[i]);
      previous.notes.push(`${pages[i].name} carried no readable invoice number; attached to the page before it.`);
    } else {
      if (!pending) pending = { parts: [], pages: [] };
      pending.parts.push(readings[i]);
      pending.pages.push(pages[i]);
    }
  }

  if (pending) {
    groups.push({
      key: null,
      parts: pending.parts,
      pages: pending.pages,
      notes: pending.pages.map((p) => `${p.name} carried no readable invoice number, and no later page in this batch revealed one either.`),
    });
  }

  return groups;
}

function assemble(group) {
  const parts = group.parts;
  const firstText = (k) => parts.map((p) => p?.[k]).find((v) => typeof v === 'string' && v.trim() !== '') ?? null;
  const firstNum = (k) => parts.map((p) => p?.[k]).find((v) => typeof v === 'number' && Number.isFinite(v)) ?? null;

  const notes = [...group.notes];
  const totalsPages = parts.filter((p) => p?.has_totals_block === true || typeof p?.grand_total === 'number').length;
  if (totalsPages > 1) notes.push(`${totalsPages} pages each showed a totals block for this invoice number - check they are not different invoices.`);

  return {
    data: {
      invoice_number: firstText('invoice_number'),
      vendor_name: firstText('vendor_name'),
      invoice_date: firstText('invoice_date'),
      subtotal: firstNum('subtotal'),
      tax: firstNum('tax'),
      grand_total: firstNum('grand_total'),
      line_items: parts.flatMap((p) => (Array.isArray(p?.line_items) ? p.line_items : [])),
    },
    assembly: { pages: group.pages.length, notes },
  };
}

/**
 * Find a live invoice for this client + number FIRST, checked before any
 * insert is attempted. Matches on invoice number alone (not vendor_name,
 * which can legitimately read differently page to page for the same
 * invoice) - this is deliberately looser than the database's own
 * one-live-per-number index, which still exists underneath as a second,
 * defensive check in case this lookup ever misses.
 */
async function findLiveInvoice(db, clientId, invoiceNumber) {
  if (!invoiceNumber) return null;
  const { data } = await db.from('invoices')
    .select('id, page_count, vendor_name, subtotal, tax, grand_total, invoice_date')
    .eq('client_id', clientId)
    .ilike('invoice_number', invoiceNumber)
    .is('merged_into', null)
    .limit(1)
    .maybeSingle();
  return data ?? null;
}

async function attachToExisting(db, existing, merged, pageCount) {
  const headerPatch = { page_count: (existing.page_count ?? 0) + pageCount };
  if (existing.subtotal == null && merged.subtotal != null) headerPatch.subtotal = merged.subtotal;
  if (existing.tax == null && merged.tax != null) headerPatch.tax = merged.tax;
  if (existing.grand_total == null && merged.grand_total != null) headerPatch.grand_total = merged.grand_total;
  if (existing.invoice_date == null && merged.invoice_date != null) headerPatch.invoice_date = merged.invoice_date;
  // Prefer the longer, more complete vendor name if the two batches disagree
  // ("Sysco SAN FRANCISCO, INC." vs plain "Sysco").
  if (merged.vendor_name && (!existing.vendor_name || merged.vendor_name.length > existing.vendor_name.length)) {
    headerPatch.vendor_name = merged.vendor_name;
  }
  await db.from('invoices').update(headerPatch).eq('id', existing.id);
  return existing.id;
}

/**
 * Place this batch's invoice: attach to an existing live invoice with the
 * same number if one is found first; otherwise insert fresh. The database's
 * one-live-per-number constraint is kept as a defensive fallback in case two
 * requests race past the findLiveInvoice check at the same instant.
 */
async function insertOrAttachInvoice(db, clientId, merged, modelUsed, pageCount) {
  const existing = await findLiveInvoice(db, clientId, merged.invoice_number);
  if (existing) {
    console.log(`[ingest] found existing live invoice ${existing.id} for ${merged.invoice_number} before inserting - attaching this batch (${pageCount} page(s)) to it instead of creating a new row.`);
    const invoiceId = await attachToExisting(db, existing, merged, pageCount);
    return { invoiceId, attachedToExisting: true };
  }

  const insertResult = await db.from('invoices').insert({
    client_id: clientId,
    vendor_name: merged.vendor_name ?? null,
    invoice_number: merged.invoice_number ?? null,
    invoice_date: merged.invoice_date ?? null,
    subtotal: merged.subtotal ?? null,
    tax: merged.tax ?? null,
    grand_total: merged.grand_total ?? null,
    model_used: modelUsed,
    page_count: pageCount,
  }).select('id').single();

  if (!insertResult.error) {
    return { invoiceId: insertResult.data.id, attachedToExisting: false };
  }

  const err = insertResult.error;
  const blockedByOneLivePerNumber = err.code === '23505' && String(err.message ?? '').includes(ONE_LIVE_PER_NUMBER_INDEX);

  if (!blockedByOneLivePerNumber || !merged.invoice_number) {
    console.error(`[ingest] insert_invoice failed for ${merged.invoice_number ?? '(no number)'}: ${err.message}`);
    return { error: err.message, stage: 'insert_invoice' };
  }

  // Defensive fallback: our pre-check above did not find it (rare race, or a
  // vendor_name mismatch this loose match still somehow missed), but the
  // database's stricter index caught it anyway. Re-look-up and attach.
  console.warn(`[ingest] insert for ${merged.invoice_number} blocked by ${ONE_LIVE_PER_NUMBER_INDEX} despite the pre-check finding nothing - looking again.`);
  const fallbackExisting = await findLiveInvoice(db, clientId, merged.invoice_number);
  if (!fallbackExisting) {
    console.error(`[ingest] blocked by ${ONE_LIVE_PER_NUMBER_INDEX} for ${merged.invoice_number} but still could not find the existing row. This batch's pages are NOT saved.`);
    return { error: `Blocked by a duplicate-invoice-number rule, and the existing invoice could not be located: ${err.message}`, stage: 'insert_invoice_duplicate_unresolved' };
  }
  const invoiceId = await attachToExisting(db, fallbackExisting, merged, pageCount);
  return { invoiceId, attachedToExisting: true };
}

Deno.serve(async (req) => {
  const url = new URL(req.url);
  const key = findKey();
  const saName = SA_NAMES.find((n) => Deno.env.get(n)) ?? null;

  if (req.method === 'GET' || url.searchParams.get('probe')) {
    let tokenOk = null, tokenError = null;
    if (saName) {
      try { await getAccessToken(vertexConfig().serviceAccount); tokenOk = true; }
      catch (err) { tokenOk = false; tokenError = err.message; }
    }
    return json({
      ok: Boolean(saName ? tokenOk : key),
      route: saName ? 'vertex' : 'ai-studio',
      service_account_secret: saName,
      token_exchange_ok: tokenOk,
      token_exchange_error: tokenError,
      gemini_secret_found: key ? key.name : null,
      model_preference: [url.searchParams.get('model'), Deno.env.get('GEMINI_MODEL'), ...MODEL_FALLBACKS].filter(Boolean),
      page_assembly: 'grouped by printed invoice number, forward or backward, within a batch',
      cross_batch_attach: 'checks for an existing live invoice by number BEFORE inserting; attaches instead of duplicating',
      math_runs_in: 'postgres (mise_parse_pack / mise_line_item_math / mise_audit_invoice)',
      handles_priced_by_weight: true,
      max_pages: MAX_PAGES,
      database: Boolean(Deno.env.get('SUPABASE_URL')),
      hint: saName ? (tokenOk ? 'Ready. POST the invoice bytes.' : `Service account found but token exchange failed: ${tokenError}`)
                   : (key ? 'Ready on the AI Studio key.' : `Set one of ${SA_NAMES.join(', ')}.`),
    }, (saName ? tokenOk : Boolean(key)) ? 200 : 503);
  }

  if (req.method !== 'POST') return json({ error: 'Use POST with the invoice bytes as the body.' }, 405);
  if (!key && !saName) return json({ error: `No credential. Set one of ${SA_NAMES.join(', ')} for Vertex, or ${KEY_NAMES[0]} for AI Studio.` }, 503);

  const clientId = url.searchParams.get('client_id');
  if (!clientId) return json({ error: 'client_id query parameter is required.' }, 400);

  let pages;
  try { pages = await readPages(req); }
  catch (err) { return json({ stage: 'read_body', error: err.message }, 400); }

  const totalBytes = pages.reduce((n, p) => n + p.bytes.length, 0);
  if (totalBytes === 0) return json({ error: 'All pages were empty.' }, 400);

  const started = Date.now();
  console.log(`[ingest] ${pages.length} page(s), ${(totalBytes / 1048576).toFixed(1)} MB — reading each page`);

  let readings, modelUsed, routeUsed;
  try {
    const models = [url.searchParams.get('model'), Deno.env.get('GEMINI_MODEL'), ...MODEL_FALLBACKS];
    const vertex = vertexConfig();
    const results = await Promise.all(pages.map((p) => vertex ? callVertex(p, vertex, models) : callGemini(p, key.value, models)));
    readings = results.map((r) => r.data);

for (const reading of readings) {
  for (const item of (reading.line_items ?? [])) {
    if ((item.item_description ?? '').toUpperCase().includes('FETA')) {
      console.log(
        '[ingest] GEMINI FETA RAW:',
        JSON.stringify(item)
      );
    }
  }
}

modelUsed = results[0].model;
routeUsed = vertex ? `vertex:${vertex.project}/${vertex.region}` : 'ai-studio';
  } catch (err) {
    console.error('[ingest] extraction failed:', err.message);
    return json({ stage: 'extraction', error: err.message }, 502);
  }

  const groups = groupByInvoiceNumber(readings, pages);
  console.log(`[ingest] ${pages.length} page(s) -> ${groups.length} invoice(s): ${groups.map((g) => `${g.key ?? 'UNNUMBERED'}(${g.pages.length}p)`).join(', ')}`);

  const db = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));
  const out = [];

  for (const group of groups) {
    const { data: merged, assembly } = assemble(group);

    const placement = await insertOrAttachInvoice(db, clientId, merged, modelUsed, group.pages.length);
    if (placement.error) {
      out.push({ invoice_number: merged.invoice_number, error: placement.error, stage: placement.stage });
      continue;
    }
    const invoiceId = placement.invoiceId;

    const rows = (merged.line_items ?? []).map((i) => ({
      invoice_id: invoiceId,
      item_description: i.item_description,
      vendor_item_code: i.vendor_item_code ?? null,
      vendor_category: i.vendor_category ?? null,
      raw_quantity: i.raw_quantity ?? null,
      raw_uom: i.raw_uom ?? null,
      raw_pack: i.raw_pack ?? null,
      raw_size: i.raw_size ?? null,
      raw_unit_price: i.raw_unit_price ?? null,
      line_total: i.line_total ?? null,
    }));

    if (rows.length) {
      const { error: liErr } = await db.from('invoice_line_items').insert(rows);
      if (liErr) {
        console.error(`[ingest] insert_line_items failed for invoice ${invoiceId} (${merged.invoice_number}): ${liErr.message}`);
        if (!placement.attachedToExisting) await db.from('invoices').delete().eq('id', invoiceId);
        out.push({ invoice_number: merged.invoice_number, error: liErr.message, stage: 'insert_line_items' });
        continue;
      }
    }

    const { data: auditRows, error: auditErr } = await db.rpc('mise_audit_invoice', { p_invoice_id: invoiceId });
    if (auditErr) {
      console.error(`[ingest] audit failed for invoice ${invoiceId} (${merged.invoice_number}): ${auditErr.message}`);
      out.push({ invoice_number: merged.invoice_number, invoice_id: invoiceId, error: auditErr.message, stage: 'audit' });
      continue;
    }
    const audit = auditRows[0];
    const status = audit.math_is_correct ? 'completed' : 'requires_human_review';
    await db.from('invoices').update({ status }).eq('id', invoiceId);

    const { data: savedLines, error: lineReadErr } = await db.from('invoice_line_items')
      .select('money_problem, unit_problem, is_flagged')
      .eq('invoice_id', invoiceId);
    if (lineReadErr) console.warn(`[ingest] could not re-read lines for the response: ${lineReadErr.message}`);
    const lines = savedLines ?? [];

    const paths = [];
    for (let p = 0; p < group.pages.length; p++) {
      const page = group.pages[p];
      const ext = FILE_EXT[page.mimeType] ?? 'bin';
      const path = `${clientId}/${invoiceId}-${Date.now()}-p${p + 1}.${ext}`;
      try {
        const { error: upErr } = await db.storage.from(INVOICE_BUCKET).upload(path, page.bytes, { contentType: page.mimeType, upsert: true });
        if (upErr) console.warn(`[ingest] archive failed for ${path} (invoice kept): ${upErr.message}`);
        else paths.push(path);
      } catch (err) {
        console.warn(`[ingest] archive threw for ${path} (invoice kept): ${err.message}`);
      }
    }
    if (paths.length) {
      const { data: cur } = await db.from('invoices').select('source_file_paths').eq('id', invoiceId).maybeSingle();
      const combined = [...(cur?.source_file_paths ?? []), ...paths];
      await db.from('invoices').update({ source_file_path: combined[0], source_file_paths: combined }).eq('id', invoiceId);
    }

    const moneyFlagged = lines.filter((i) => i.money_problem).length;
    const unitFlagged = lines.filter((i) => i.unit_problem && !i.money_problem).length;
    console.log(`[ingest] ${status} number=${merged.invoice_number} invoice_id=${invoiceId} attached=${placement.attachedToExisting} pages=${group.pages.length} lines_added=${rows.length} lines_sum=${audit.calculated_subtotal} vs ${audit.checked_against} money_flags=${moneyFlagged} unit_flags=${unitFlagged}`);
    for (const problem of [...(audit.money_problems ?? []), ...(audit.unit_problems ?? [])]) console.log(`[ingest]   • ${problem}`);

    out.push({
      status: audit.math_is_correct ? 'COMPLETED' : 'REQUIRES_HUMAN_REVIEW',
      invoice_id: invoiceId,
      attached_to_existing_invoice: placement.attachedToExisting,
      invoice_number: merged.invoice_number,
      vendor_name: merged.vendor_name,
      invoice_date: merged.invoice_date,
      pages: group.pages.length,
      page_files: group.pages.map((p) => p.name),
      printed: { subtotal: merged.subtotal, tax: merged.tax, grand_total: merged.grand_total },
      recomputed: { lines_sum: audit.calculated_subtotal, checked_against: audit.checked_against },
      math_is_correct: audit.math_is_correct,
      units_need_review: (audit.unit_problems ?? []).length > 0,
      line_count: rows.length,
      flagged_lines: moneyFlagged + unitFlagged,
      money_problems: audit.money_problems,
      unit_problems: audit.unit_problems,
      assembly_notes: assembly.notes,
    });
  }

  return json({
    pages_received: pages.length,
    invoices_created: out.filter((o) => o.invoice_id).length,
    model_used: modelUsed,
    route: routeUsed,
    elapsed_seconds: Number(((Date.now() - started) / 1000).toFixed(1)),
    invoices: out,
  }, 201);
});

function requestBody(page) {
  return JSON.stringify({
    systemInstruction: { parts: [{ text: SYSTEM_INSTRUCTION }] },
    contents: [{ role: 'user', parts: [
      { inlineData: { mimeType: page.mimeType, data: encodeBase64(page.bytes) } },
      { text: USER_INSTRUCTION },
    ] }],
    generationConfig: { temperature: 0, responseMimeType: 'application/json', responseSchema: invoiceSchema, maxOutputTokens: MAX_OUTPUT_TOKENS },
  });
}

async function callGemini(page, apiKey, candidates) {
  const tried = [];
  const models = [...new Set(candidates.filter(Boolean))];
  const body = requestBody(page);
  for (const model of models) {
    const res = await fetch(`${API_BASE}/models/${encodeURIComponent(model)}:generateContent`, {
      method: 'POST', headers: { 'Content-Type': 'application/json', 'x-goog-api-key': apiKey }, body,
    });
    if (res.ok) return { data: parseGeminiJson(await res.json()), model };
    const detail = await res.text().catch(() => '');
    tried.push(`${model} -> ${res.status}`);
    if (!(res.status === 404 || /not found|not supported|unsupported model/i.test(detail))) {
      throw new Error(`Gemini ${res.status} on ${model}: ${detail.slice(0, 400)}`);
    }
    console.log(`[ingest] model ${model} unavailable, trying next`);
  }
  throw new Error(`No usable Gemini model. Tried: ${tried.join('; ')}`);
}

async function callVertex(page, { serviceAccount, project, region }, candidates) {
  const token = await getAccessToken(serviceAccount);
  const models = [...new Set(candidates.filter(Boolean))];
  const tried = [];
  const body = requestBody(page);
  const host = region === 'global' ? 'aiplatform.googleapis.com' : `${region}-aiplatform.googleapis.com`;
  for (const model of models) {
    const endpoint = `https://${host}/v1/projects/${project}/locations/${region}/publishers/google/models/${encodeURIComponent(model)}:generateContent`;
    const res = await fetch(endpoint, { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` }, body });
    if (res.ok) return { data: parseGeminiJson(await res.json()), model };
    const detail = await res.text().catch(() => '');
    tried.push(`${model} -> ${res.status}`);
    if (!(res.status === 404 || /not found|was not found/i.test(detail))) {
      throw new Error(`Vertex ${res.status} on ${model}: ${detail.slice(0, 400)}`);
    }
    console.log(`[ingest] vertex model ${model} unavailable, trying next`);
  }
  throw new Error(`No usable Vertex model in ${region}. Tried: ${tried.join('; ')}`);
}

function parseGeminiJson(payload) {
  const candidate = payload?.candidates?.[0];
  if (!candidate) {
    const reason = payload?.promptFeedback?.blockReason;
    throw new Error(reason ? `Blocked: ${reason}` : 'No candidates returned.');
  }
  if (candidate.finishReason && !['STOP', 'MAX_TOKENS'].includes(candidate.finishReason)) {
    throw new Error(`Stopped early: ${candidate.finishReason}`);
  }
  const text = (candidate.content?.parts ?? []).map((p) => p.text ?? '').join('').trim();
  if (!text) throw new Error('Empty response body.');
  try {
    return JSON.parse(text.replace(/^```(?:json)?\s*/i, '').replace(/\s*```$/, ''));
  } catch (err) {
    if (candidate.finishReason === 'MAX_TOKENS') throw new Error(`Page response hit the ${MAX_OUTPUT_TOKENS}-token cap and was cut off mid-JSON.`);
    throw new Error(`Unparseable JSON: ${err.message} :: ${text.slice(0, 300)}`);
  }
}
