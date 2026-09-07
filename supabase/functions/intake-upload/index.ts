// @ts-nocheck
/**
 * intake-upload - the spreadsheet path of the Upload tab.
 *
 * The app parses a CSV or XLSX in the browser, finds the date / item / qty /
 * price columns, and POSTs rows shaped {d,i,c,q,p}. This endpoint never existed,
 * so DEMO_MODE was true and the confirm button reported a fake row count.
 *
 *   POST { rows:[{d,i,c,q,p}], restaurant_id, doc_type? }
 *   ->   { inserted, rejected:[{row, reason}] }
 *
 * Rejected rows come back with the reason and the row number, because a chef
 * uploading 200 lines needs to know WHICH four failed, not just that four did.
 */
import { createClient } from 'jsr:@supabase/supabase-js@2';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, x-client-info, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (b, s = 200) =>
  new Response(JSON.stringify(b, null, 2), { status: s, headers: { ...CORS, 'Content-Type': 'application/json' } });

const MAX_ROWS = 5000;

/** The browser sends dates already formatted, but be forgiving about the shape. */
function toDate(v) {
  const t = String(v ?? '').trim();
  if (!t) return null;
  if (/^\d{4}-\d{2}-\d{2}$/.test(t)) return t;
  const m = t.match(/^(\d{1,2})[/\-.](\d{1,2})[/\-.](\d{2}|\d{4})$/);
  if (m) {
    let [, mo, d, y] = m;
    y = y.length === 2 ? String(Number(y) + (Number(y) < 70 ? 2000 : 1900)) : y;
    const iso = `${y}-${String(mo).padStart(2,'0')}-${String(d).padStart(2,'0')}`;
    return isNaN(Date.parse(iso)) ? null : iso;
  }
  const parsed = Date.parse(t);
  return isNaN(parsed) ? null : new Date(parsed).toISOString().slice(0, 10);
}

const num = (v) => {
  if (v === '' || v === null || v === undefined) return null;
  const n = Number(String(v).replace(/[^0-9.\-]/g, ''));
  return Number.isFinite(n) ? n : null;
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ error: 'POST rows as JSON.' }, 405);

  let body;
  try { body = await req.json(); }
  catch (err) { return json({ error: `Unparseable body: ${err.message}` }, 400); }

  const clientId = String(body.restaurant_id ?? '').trim();
  const docType = String(body.doc_type ?? 'invoice');
  const rows = Array.isArray(body.rows) ? body.rows : [];

  if (!clientId) return json({ error: 'restaurant_id is required.' }, 400);
  if (!rows.length) return json({ error: 'No rows to upload.' }, 400);
  if (rows.length > MAX_ROWS) return json({ error: `${rows.length} rows is over the ${MAX_ROWS} row limit for one upload.` }, 413);

  const db = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));

  const { data: client, error: clientErr } = await db
    .from('clients').select('id, name, status').eq('id', clientId).maybeSingle();
  if (clientErr) return json({ error: clientErr.message }, 500);
  if (!client) return json({ error: 'That restaurant is not set up.' }, 404);
  if (!['active', 'trial'].includes(client.status)) {
    return json({ error: `This account is ${client.status}.` }, 403);
  }

  const ready = [];
  const rejected = [];

  rows.forEach((r, i) => {
    const rowNo = i + 2;                       // +1 for the header, +1 for 1-based
    const item = String(r.i ?? '').trim();
    if (!item) { rejected.push({ row: rowNo, reason: 'no item name' }); return; }

    const date = toDate(r.d);
    if (!date) { rejected.push({ row: rowNo, item, reason: `could not read the date "${r.d ?? ''}"` }); return; }

    const qty = num(r.q);
    const price = num(r.p);
    if (qty === null && price === null) {
      rejected.push({ row: rowNo, item, reason: 'neither quantity nor price is a number' });
      return;
    }

    ready.push({
      client_id: clientId,
      doc_type: docType,
      source_name: String(body.source_name ?? '').trim() || null,
      row_date: date,
      item,
      category: String(r.c ?? '').trim() || null,
      quantity: qty,
      price: price,
    });
  });

  let inserted = 0;
  // Chunked so one oversized paste doesn't fail the whole upload.
  for (let i = 0; i < ready.length; i += 500) {
    const chunk = ready.slice(i, i + 500);
    const { error } = await db.from('intake_rows').insert(chunk);
    if (error) {
      console.error('[intake-upload] insert failed:', error.message);
      return json({ error: error.message, inserted, rejected }, 500);
    }
    inserted += chunk.length;
  }

  console.log(`[intake-upload] ${client.name} ${docType}: ${inserted} in, ${rejected.length} rejected`);
  return json({ ok: true, inserted, rejected, doc_type: docType });
});
