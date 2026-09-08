// @ts-nocheck
/**
 * upload-scan - the landing-page camera path.
 *
 * The app's Upload tab has always POSTed a multipart form here and this endpoint
 * never existed, so DEMO_MODE was left true and a photograph produced a 600ms
 * fake success. This is the real thing: photo in, invoice in the Review Queue.
 *
 *   POST multipart/form-data
 *     file           the photo or PDF
 *     doc_type       invoice | recipe | waste_list | pos_printout | product_mix | order_sheet
 *     restaurant_id  client uuid
 *
 * An invoice is handed straight to ingest-invoice, which does the reading, the
 * page grouping and the maths. Anything else is archived with its type so it is
 * not lost while those paths are built - a chef photographing a waste sheet
 * should never get an error telling them the feature does not exist yet.
 */
import { createClient } from 'jsr:@supabase/supabase-js@2';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, x-client-info, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (b, s = 200) =>
  new Response(JSON.stringify(b, null, 2), { status: s, headers: { ...CORS, 'Content-Type': 'application/json' } });

const INVOICE_TYPES = /^(application\/pdf|image\/(jpeg|jpg|png|webp|heic|heif))$/i;
const DOC_BUCKET = 'invoice-files';

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ error: 'POST a multipart form with a file.' }, 405);

  let form;
  try { form = await req.formData(); }
  catch (err) { return json({ error: `Could not read the upload: ${err.message}` }, 400); }

  const file = form.get('file');
  const docType = String(form.get('doc_type') ?? 'invoice');
  const clientId = String(form.get('restaurant_id') ?? '').trim();
  const apiToken = String(form.get('api_token') ?? '').trim();

  if (!(file instanceof File) && !(file instanceof Blob)) {
    return json({ error: 'No file in the form.' }, 400);
  }
  if (!clientId) return json({ error: 'restaurant_id is required.' }, 400);
  if (!apiToken) return json({ error: 'api_token is required.' }, 401);

  const name = (file.name ?? 'upload').toString();
  const mimeType = (file.type || 'application/octet-stream').split(';')[0].trim();
  const bytes = new Uint8Array(await file.arrayBuffer());
  if (bytes.length === 0) return json({ error: 'That file is empty.' }, 400);

  const db = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));

  // The client has to exist, or the invoice lands under a uuid pointing nowhere.
  const { data: client, error: clientErr } = await db
    .from('clients').select('id, name, status, api_token').eq('id', clientId).maybeSingle();
  if (clientErr) return json({ error: clientErr.message }, 500);
  if (!client) return json({ error: 'That restaurant is not set up.' }, 404);
  // An existence check is a spelling check, not an authorisation check: without
  // this, anyone could push invoices into any restaurant's books (and bill us
  // for the extraction).
  if (String(client.api_token) !== apiToken) {
    return json({ error: 'Wrong api_token for this restaurant_id.' }, 401);
  }
  if (!['active', 'trial'].includes(client.status)) {
    return json({ error: `This account is ${client.status}. Get in touch and we'll switch it back on.` }, 403);
  }

  console.log(`[upload-scan] ${client.name} ${docType} ${name} ${(bytes.length / 1024) | 0} KB ${mimeType}`);

  // ---- Invoices go straight through the real pipeline ----
  if (docType === 'invoice' && INVOICE_TYPES.test(mimeType)) {
    try {
      const res = await fetch(
        `${Deno.env.get('SUPABASE_URL')}/functions/v1/ingest-invoice?client_id=${encodeURIComponent(clientId)}`,
        { method: 'POST',
          headers: { Authorization: `Bearer ${Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')}`, 'Content-Type': mimeType },
          body: bytes });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) {
        console.error('[upload-scan] ingest failed:', data?.error);
        return json({ error: data?.error ?? `Reading that invoice failed (${res.status}).` }, 502);
      }
      const inv = Array.isArray(data.invoices) ? data.invoices[0] : data;
      return json({
        ok: true,
        doc_type: docType,
        invoice_id: inv?.invoice_id ?? null,
        invoice_number: inv?.invoice_number ?? null,
        vendor_name: inv?.vendor_name ?? null,
        status: inv?.status ?? null,
        line_count: inv?.line_count ?? null,
        needs_review: inv?.status !== 'COMPLETED',
        message: inv?.status === 'COMPLETED'
          ? `Read and reconciled — ${inv?.line_count ?? 0} lines from ${inv?.vendor_name ?? 'this invoice'}.`
          : 'Read. A few lines need a look — they are in your Review Queue.',
      });
    } catch (err) {
      console.error('[upload-scan] ingest threw:', err?.message);
      return json({ error: err?.message ?? 'Reading that invoice failed.' }, 502);
    }
  }

  // ---- Everything else is archived rather than refused ----
  const ext = (name.match(/\.([a-z0-9]+)$/i)?.[1] ?? 'bin').toLowerCase();
  const path = `${clientId}/${docType}/${Date.now()}-${name.replace(/[^A-Za-z0-9._-]/g, '_')}`;
  const { error: upErr } = await db.storage.from(DOC_BUCKET)
    .upload(path, bytes, { contentType: mimeType, upsert: false });
  if (upErr) {
    console.error('[upload-scan] archive failed:', upErr.message);
    return json({ error: `Could not store that file: ${upErr.message}` }, 500);
  }

  return json({
    ok: true,
    doc_type: docType,
    stored_at: path,
    message: `Received your ${docType.replace(/_/g, ' ')}. It is filed and will be read once that path is switched on.`,
  });
});
