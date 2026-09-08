// @ts-nocheck
/**
 * Inbound-email intake: forward an invoice (or nightly report) to an address,
 * it lands in the queue for a worker to process at a controlled pace.
 *
 * Provider-agnostic. Resend, SendGrid, Mailgun, Postmark and a Cloudflare Email
 * Worker each POST a different shape, so this pulls attachments out of whichever
 * arrives rather than committing to one vendor's contract.
 *
 * QUEUED, NOT PROCESSED HERE. Attachments are written to ingestion_queue and
 * the webhook returns immediately. A separate worker (process-queue), run on a
 * schedule, drains that queue one job at a time. This means ten restaurants
 * all emailing at once never all hit Gemini in the same second - they just
 * queue up and get worked through steadily. Extraction used to run inline
 * here (via EdgeRuntime.waitUntil); that is gone now in favor of the queue.
 *
 * Resend is the exception worth knowing about: its email.received webhook sends
 * attachment METADATA only -- filename, content_type, id -- and no bytes. The
 * file is fetched in a second call against the Resend API, which hands back a
 * short-lived signed URL. So a Resend payload needs RESEND_API_KEY set.
 *
 * FORWARDED MAIL. A restaurant does not download the PDF and re-attach it --
 * they hit forward on the invoice their distributor sent. Gmail and Outlook can
 * attach the whole original message as a .eml (message/rfc822), with the real
 * invoice nested one layer inside, so a .eml is opened rather than discarded.
 *
 * ONE EMAIL IS ONE INVOICE. A restaurant photographs a long invoice page by page
 * and forwards all the shots together. Attachments from one email go over as
 * ONE queue job, so ingest-invoice still groups them as pages of one document
 * rather than splitting them into separate invoices.
 *
 * TWO KINDS OF MAIL, TWO ADDRESSES. invoices@... routes via
 * mise_client_for_email and becomes an 'invoice' job. sales@... (or whatever
 * address is set up with route_kind='nightly_report') routes via
 * mise_client_for_report_email and becomes a 'nightly_report' job instead.
 * Which address it was sent TO decides the job type - no guessing from the
 * file contents.
 *
 * Which restaurant an invoice belongs to comes from the address it was sent TO,
 * looked up in client_email_routes. Onboarding a restaurant is one row -- no
 * redeploy, no per-client webhook. ?client_id= still works as an override
 * (always treated as an invoice job in that case).
 *
 * Auth: set an INBOUND_TOKEN secret and pass ?token=... on the webhook URL. The
 * endpoint cannot use verify_jwt because mail providers cannot mint a JWT.
 */
import { createClient } from 'jsr:@supabase/supabase-js@2';
import { encodeBase64 } from 'jsr:@std/encoding@1/base64';

const INVOICE_TYPES = /^(application\/pdf|image\/(jpeg|jpg|png|webp|heic|heif))$/i;
const INVOICE_EXT = /\.(pdf|jpe?g|png|webp|heic|heif)$/i;
const EML_EXT = /\.eml$/i;
const MAX_ATTACHMENTS = 10;
const MAX_EML_BYTES = 25 * 1024 * 1024;
const RESEND_API = 'https://api.resend.com';

const json = (body, status = 200) =>
  new Response(JSON.stringify(body, null, 2), { status, headers: { 'Content-Type': 'application/json' } });

/** One queue job per email's worth of attachments - pages of one document stay together. */
async function enqueue(db, clientId, jobType, files) {
  const { data, error } = await db.from('ingestion_queue').insert({
    client_id: clientId,
    job_type: jobType,
    payload: { files: files.map((f) => ({ name: f.name, mimeType: f.type, data: encodeBase64(f.bytes) })) },
  }).select('id').single();
  if (error) throw new Error(`Could not queue job: ${error.message}`);
  console.log(`[email] queued ${jobType} job=${data.id} client=${clientId} pages=${files.length} (${files.map((f) => f.name).join(', ')})`);
  return data.id;
}

Deno.serve(async (req) => {
  const url = new URL(req.url);

  if (req.method === 'GET') {
    return json({
      ok: true,
      purpose: 'Point a mail provider inbound webhook here; attachments get queued for a worker to process at a controlled pace.',
      token_required: Boolean(Deno.env.get('INBOUND_TOKEN')),
      resend_fetch_ready: Boolean(Deno.env.get('RESEND_API_KEY')),
      unwraps_forwarded_mail: true,
      queues_instead_of_processing_inline: true,
      job_types: ['invoice', 'nightly_report'],
    });
  }
  if (req.method !== 'POST') return json({ error: 'POST only.' }, 405);

  const expected = Deno.env.get('INBOUND_TOKEN');
  // Fail closed. This used to skip the check entirely when the secret was
  // missing, so a restore or a renamed environment variable silently turned
  // authentication off on a public endpoint instead of stopping the service.
  if (!expected) {
    console.error('[email] INBOUND_TOKEN is not set - refusing inbound mail rather than accepting it unauthenticated.');
    return json({ error: 'Inbound mail is not configured.' }, 503);
  }
  {
    const given = url.searchParams.get('token') ?? req.headers.get('x-inbound-token');
    if (given !== expected) return json({ error: 'Bad or missing token.' }, 401);
  }

  const contentType = (req.headers.get('content-type') ?? '').toLowerCase();
  let attachments = [], sender = null, subject = null, recipients = [], fetchNote = null;

  try {
    if (contentType.includes('application/json')) {
      const body = await req.json();
      ({ sender, subject, recipients } = describe(body));
      attachments = fromJson(body);
      if (attachments.length === 0) {
        const pulled = await fromResend(body);
        attachments = pulled.files;
        fetchNote = pulled.note;
      }
    } else if (contentType.includes('multipart/form-data')) {
      const form = await req.formData();
      sender = form.get('from') ?? null;
      subject = form.get('subject') ?? null;
      recipients = splitAddresses(form.get('to'));
      attachments = await fromFormData(form);
    } else {
      const raw = await req.text();
      sender = raw.match(/^From:\s*(.+)$/im)?.[1]?.trim() ?? null;
      subject = raw.match(/^Subject:\s*(.+)$/im)?.[1]?.trim() ?? null;
      recipients = splitAddresses(raw.match(/^To:\s*(.+)$/im)?.[1]);
      attachments = fromMime(raw);
    }
  } catch (err) {
    console.error('[email] could not parse payload:', err.message);
    return json({ error: `Unparseable webhook payload: ${err.message}`, content_type: contentType }, 400);
  }

  attachments = dedupe(attachments)
    .sort((a, b) => String(a.name).localeCompare(String(b.name), undefined, { numeric: true }))
    .slice(0, MAX_ATTACHMENTS);

  const db = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));

  let clientId = url.searchParams.get('client_id');
  let matchedAddress = null;
  let jobType = clientId ? 'invoice' : null;

  if (!clientId) {
    for (const address of recipients) {
      const { data } = await db.rpc('mise_client_for_email', { p_address: address });
      if (data) { clientId = data; matchedAddress = address; jobType = 'invoice'; break; }
    }
  }
  if (!clientId) {
    for (const address of recipients) {
      const { data } = await db.rpc('mise_client_for_report_email', { p_address: address });
      if (data) { clientId = data; matchedAddress = address; jobType = 'nightly_report'; break; }
    }
  }

  console.log(`[email] from=${sender ?? '?'} to=${recipients.join(', ') || '?'} client=${clientId ?? 'UNROUTED'} job_type=${jobType ?? '?'} attachments=${attachments.length} subject=${JSON.stringify(subject)}`);

  if (!clientId) {
    return json({
      status: 'UNKNOWN_RECIPIENT', from: sender, to: recipients,
      hint: 'No active row in client_email_routes matches this address (checked both invoice and nightly_report routes). Add one to onboard the restaurant.',
    });
  }

  if (attachments.length === 0) {
    return json({
      status: 'NO_INVOICE_ATTACHED', from: sender, subject, fetch_note: fetchNote,
      hint: 'No PDF or image attachment found, and no forwarded message containing one.',
    });
  }

  let jobId;
  try {
    jobId = await enqueue(db, clientId, jobType, attachments);
  } catch (err) {
    console.error('[email] enqueue failed:', err.message);
    return json({ error: err.message }, 500);
  }

  return json({
    status: 'QUEUED', from: sender, to: recipients, routed_via: matchedAddress,
    client_id: clientId, job_type: jobType, job_id: jobId, subject,
    queued: attachments.map((f) => ({ filename: f.name, type: f.type, from_forwarded_mail: f.unwrapped ?? false })),
    note: `${attachments.length} attachment(s) queued as a ${jobType} job. A worker processes the queue on a schedule - this is not processed inline anymore.`,
  }, 202);
});

/* -- payload shapes -------------------------------------------------------- */

function dedupe(files) {
  const best = new Map();
  for (const f of files) {
    const key = String(f.name ?? '').trim().toLowerCase();
    const existing = best.get(key);
    if (!existing || f.bytes.length > existing.bytes.length) best.set(key, f);
  }
  const out = [...best.values()];
  if (out.length !== files.length) console.log(`[email] dropped ${files.length - out.length} duplicate attachment(s)`);
  return out;
}

function describe(body) {
  const d = body?.data ?? body;
  return {
    sender: d?.from?.address ?? d?.from ?? d?.sender ?? d?.From ?? null,
    subject: d?.subject ?? d?.Subject ?? null,
    recipients: [
      ...splitAddresses(d?.to), ...splitAddresses(d?.To),
      ...splitAddresses(d?.recipient), ...splitAddresses(d?.envelope?.to),
      ...splitAddresses(d?.received_for),
    ],
  };
}

function splitAddresses(value) {
  if (!value) return [];
  const flat = Array.isArray(value) ? value : [value];
  return flat
    .flatMap((v) => (typeof v === 'string' ? v.split(',') : [v?.address ?? v?.email ?? '']))
    .map((v) => String(v).trim())
    .filter(Boolean);
}

function looksLikeEml(declaredType, filename) {
  const t = String(declaredType ?? '').split(';')[0].trim();
  if (EML_EXT.test(String(filename ?? ''))) return true;
  return /^message\/rfc822$/i.test(t);
}

function fromJson(body) {
  const d = body?.data ?? body;
  const list = d?.attachments ?? d?.Attachments ?? body?.attachments ?? [];
  const out = [];
  for (const a of Array.isArray(list) ? list : []) {
    const name = a.filename ?? a.Name ?? a.name ?? 'attachment';
    const declared = a.content_type ?? a.contentType ?? a.ContentType ?? a.type;
    const content = typeof a.content === 'string' ? a.content : a.Content ?? a.data ?? a.base64 ?? null;
    if (!content) continue;

    if (looksLikeEml(declared, name)) {
      try {
        const nested = fromMime(new TextDecoder().decode(decodeBase64(content)));
        for (const f of nested) out.push({ ...f, unwrapped: true });
        console.log(`[email] unwrapped ${name}: found ${nested.length} invoice attachment(s)`);
      } catch (err) {
        console.warn(`[email] could not open forwarded message ${name}: ${err.message}`);
      }
      continue;
    }

    const type = normalizeType(declared, name);
    if (!type) continue;
    try {
      out.push({ name, type, bytes: decodeBase64(content) });
    } catch {
      console.warn(`[email] attachment ${name} was not valid base64; skipped.`);
    }
  }
  return out;
}

async function fromResend(body) {
  const d = body?.data ?? body;
  const emailId = d?.email_id ?? d?.id ?? null;
  const list = Array.isArray(d?.attachments) ? d.attachments : [];
  if (!emailId || list.length === 0) return { files: [], note: null };

  const key = Deno.env.get('RESEND_API_KEY');
  if (!key) {
    const note = 'Attachment metadata arrived with no bytes and RESEND_API_KEY is not set, so the file could not be fetched.';
    console.error(`[email] ${note}`);
    return { files: [], note };
  }

  const out = [], skipped = [];

  const pulled = await Promise.all(list.slice(0, MAX_ATTACHMENTS).map(async (a) => {
    const name = a.filename ?? 'attachment';
    const declared = a.content_type ?? a.contentType;
    const isEml = looksLikeEml(declared, name);
    const type = isEml ? 'message/rfc822' : normalizeType(declared, name);
    if (!type || !a.id) return { skip: `${name} (${declared ?? 'unknown type'})` };

    try {
      const metaRes = await fetch(`${RESEND_API}/emails/receiving/${emailId}/attachments/${a.id}`, {
        headers: { Authorization: `Bearer ${key}` },
      });
      if (!metaRes.ok) return { skip: `${name} (metadata HTTP ${metaRes.status})` };
      const meta = await metaRes.json();
      const href = meta?.download_url ?? meta?.data?.download_url ?? meta?.url ?? null;
      if (!href) return { skip: `${name} (no download_url in response)` };

      const fileRes = await fetch(href);
      if (!fileRes.ok) return { skip: `${name} (download HTTP ${fileRes.status})` };
      const bytes = new Uint8Array(await fileRes.arrayBuffer());

      if (isEml) {
        if (bytes.length > MAX_EML_BYTES) {
          return { skip: `${name} (forwarded message is ${(bytes.length / 1048576) | 0} MB, too large to open)` };
        }
        const nested = fromMime(new TextDecoder().decode(bytes)).map((f) => ({ ...f, unwrapped: true }));
        console.log(`[email] unwrapped ${name}: found ${nested.length} invoice attachment(s)`);
        return nested.length ? { files: nested } : { skip: `${name} (forwarded message held no PDF or image)` };
      }

      console.log(`[email] fetched ${name} from Resend (${type})`);
      return { files: [{ name, type, bytes }] };
    } catch (err) {
      return { skip: `${name} (${err.message})` };
    }
  }));

  for (const p of pulled) {
    if (p?.files) out.push(...p.files);
    else if (p?.skip) skipped.push(p.skip);
  }

  return { files: out, note: out.length === 0 && skipped.length ? `Nothing usable: ${skipped.join('; ')}` : null };
}

async function fromFormData(form) {
  const out = [];
  for (const [, value] of form.entries()) {
    if (typeof value === 'string' || !value?.name) continue;
    if (looksLikeEml(value.type, value.name)) {
      try {
        const nested = fromMime(await value.text());
        for (const f of nested) out.push({ ...f, unwrapped: true });
      } catch (err) {
        console.warn(`[email] could not open forwarded message ${value.name}: ${err.message}`);
      }
      continue;
    }
    const type = normalizeType(value.type, value.name);
    if (!type) continue;
    out.push({ name: value.name, type, bytes: new Uint8Array(await value.arrayBuffer()) });
  }
  return out;
}

function fromMime(raw) {
  const text = String(raw);
  const boundaries = [...new Set([...text.matchAll(/boundary="?([^";\r\n]+)"?/gi)].map((m) => m[1]))];
  if (boundaries.length === 0) return [];

  const out = [];
  for (const boundary of boundaries) {
    for (const part of text.split(`--${boundary}`)) {
      const split = part.indexOf('\r\n\r\n') >= 0 ? part.indexOf('\r\n\r\n') : part.indexOf('\n\n');
      if (split < 0) continue;
      const headers = part.slice(0, split);
      if (!/content-transfer-encoding:\s*base64/i.test(headers)) continue;

      const name =
        headers.match(/filename\*?="?([^";\r\n]+)"?/i)?.[1] ??
        headers.match(/name="?([^";\r\n]+)"?/i)?.[1] ?? 'attachment';
      const declared = headers.match(/content-type:\s*([^;\r\n]+)/i)?.[1]?.trim();
      const type = normalizeType(declared, name);
      if (!type) continue;

      const payload = part.slice(split).replace(/[^A-Za-z0-9+/=]/g, '');
      if (!payload) continue;
      try {
        out.push({ name, type, bytes: decodeBase64(payload) });
      } catch {
        console.warn(`[email] MIME part ${name} failed base64 decode; skipped.`);
      }
    }
  }
  return dedupe(out);
}

function normalizeType(declared, filename) {
  const t = String(declared ?? '').split(';')[0].trim().toLowerCase();
  if (INVOICE_TYPES.test(t)) return t === 'image/jpg' ? 'image/jpeg' : t;
  const ext = String(filename ?? '').match(INVOICE_EXT)?.[1]?.toLowerCase();
  if (!ext) return null;
  if (ext === 'pdf') return 'application/pdf';
  if (ext === 'jpg' || ext === 'jpeg') return 'image/jpeg';
  return `image/${ext}`;
}

function decodeBase64(text) {
  const clean = String(text).replace(/^data:[^,]*,/, '').replace(/\s/g, '');
  const bin = atob(clean);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i += 1) bytes[i] = bin.charCodeAt(i);
  return bytes;
}
