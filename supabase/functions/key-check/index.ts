// @ts-nocheck
/**
 * Credential diagnostic. Isolated on purpose: touches no other function and no
 * table, so running it cannot disturb the pipeline.
 *
 * Checks both routes and reports the SHAPE of each credential, never its value:
 *   AI Studio  - API key against generativelanguage.googleapis.com
 *   Vertex AI  - service account -> signed JWT -> access token -> aiplatform
 *
 * For Vertex it also probes each candidate model with a one-word prompt, so the
 * available model names come from Google rather than from anyone's memory.
 */
const NAMES = ['GEMINI_API_KEY', 'GOOGLE_API_KEY', 'GOOGLE_GENAI_API_KEY', 'GEMINI_KEY', 'GOOGLE_GEMINI_API_KEY'];
const MODELS = ['gemini-flash-latest', 'gemini-2.5-flash', 'gemini-2.0-flash', 'gemini-1.5-flash'];
const json = (b, s = 200) =>
  new Response(JSON.stringify(b, null, 2), { status: s, headers: { 'Content-Type': 'application/json' } });

const b64url = (bytes) =>
  btoa(String.fromCharCode(...new Uint8Array(bytes))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

function classify(v) {
  const s = String(v ?? '');
  if (!s) return 'empty';
  if (s.startsWith('AIza')) return 'AI Studio API key — correct for the AI Studio endpoint';
  if (s.startsWith('ya29')) return 'OAuth access token — expires in about an hour';
  if (s.trimStart().startsWith('{')) return 'Service account JSON — belongs in GCP_SERVICE_ACCOUNT_JSON, not here';
  return 'Unrecognized format';
}

async function accessToken(sa) {
  const body = String(sa.private_key)
    .replace(/-----BEGIN PRIVATE KEY-----/, '').replace(/-----END PRIVATE KEY-----/, '').replace(/\s+/g, '');
  const der = Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey('pkcs8', der.buffer,
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['sign']);

  const now = Math.floor(Date.now() / 1000);
  const aud = sa.token_uri ?? 'https://oauth2.googleapis.com/token';
  const enc = new TextEncoder();
  const unsigned = `${b64url(enc.encode(JSON.stringify({ alg: 'RS256', typ: 'JWT' })))}.` +
    `${b64url(enc.encode(JSON.stringify({
      iss: sa.client_email, scope: 'https://www.googleapis.com/auth/cloud-platform',
      aud, iat: now, exp: now + 3600,
    })))}`;
  const sig = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key, enc.encode(unsigned));

  const res = await fetch(aud, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: `${unsigned}.${b64url(sig)}`,
    }),
  });
  const out = await res.json().catch(() => ({}));
  if (!res.ok || !out.access_token) {
    throw new Error(`token exchange ${res.status}: ${out.error_description ?? out.error ?? 'no detail'}`);
  }
  return out.access_token;
}

Deno.serve(async () => {
  const report = { ai_studio: null, vertex: null };

  // ---- AI Studio -----------------------------------------------------------
  const found = NAMES.map((n) => [n, Deno.env.get(n)]).filter(([, v]) => v);
  if (found.length === 0) {
    report.ai_studio = { configured: false };
  } else {
    const [name, value] = found[0];
    const entry = { configured: true, secret_name: name, length: value.length, starts_with: value.slice(0, 4), looks_like: classify(value) };
    try {
      const res = await fetch('https://generativelanguage.googleapis.com/v1beta/models', { headers: { 'x-goog-api-key': value } });
      const body = await res.json().catch(() => ({}));
      if (res.ok) {
        entry.verdict = 'ACCEPTED';
        entry.models = (body.models ?? [])
          .filter((m) => (m.supportedGenerationMethods ?? []).includes('generateContent'))
          .map((m) => String(m.name).replace(/^models\//, ''))
          .filter((m) => m.includes('flash')).slice(0, 15);
      } else {
        entry.verdict = 'REJECTED';
        entry.google_error = body?.error?.message ?? `HTTP ${res.status}`;
      }
    } catch (err) { entry.verdict = 'unreachable'; entry.error = err.message; }
    report.ai_studio = entry;
  }

  // ---- Vertex AI -----------------------------------------------------------
  const raw = Deno.env.get('GCP_SERVICE_ACCOUNT_JSON');
  if (!raw) {
    report.vertex = { configured: false, hint: 'Set GCP_SERVICE_ACCOUNT_JSON to the full service account JSON.' };
    return json(report);
  }

  const v = { configured: true, secret_length: raw.length };
  let sa;
  try {
    let text = raw.trim();
    if (text.startsWith('"') && text.endsWith('"')) { try { text = JSON.parse(text); } catch {} }
    sa = typeof text === 'string' ? JSON.parse(text) : text;
    v.parsed = true;
    v.client_email = sa.client_email ?? null;
    v.project_id = sa.project_id ?? null;
    v.type = sa.type ?? null;
    if (!sa.client_email || !sa.private_key) throw new Error('missing client_email or private_key');
  } catch (err) {
    v.parsed = false;
    v.error = `Secret is not usable service account JSON: ${err.message}`;
    report.vertex = v;
    return json(report);
  }

  let token;
  try {
    token = await accessToken(sa);
    v.token = 'ACQUIRED — service account is valid';
  } catch (err) {
    v.token = 'FAILED';
    v.error = err.message;
    report.vertex = v;
    return json(report);
  }

  // Ask Vertex which of the candidate models actually answer.
  const region = Deno.env.get('GCP_REGION') ?? 'us-central1';
  const project = Deno.env.get('GCP_PROJECT_ID') ?? sa.project_id;
  v.region = region;
  v.project = project;
  v.model_probe = {};

  for (const model of MODELS) {
    const url = `https://${region}-aiplatform.googleapis.com/v1/projects/${project}/locations/${region}/publishers/google/models/${model}:generateContent`;
    try {
      const res = await fetch(url, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
        body: JSON.stringify({ contents: [{ role: 'user', parts: [{ text: 'hi' }] }] }),
      });
      if (res.ok) { v.model_probe[model] = 'WORKS'; continue; }
      const detail = await res.text().catch(() => '');
      v.model_probe[model] = `${res.status} ${detail.slice(0, 160).replace(/\s+/g, ' ')}`;
    } catch (err) {
      v.model_probe[model] = `unreachable: ${err.message}`;
    }
  }

  v.usable_models = Object.entries(v.model_probe).filter(([, s]) => s === 'WORKS').map(([m]) => m);
  report.vertex = v;
  return json(report, v.usable_models.length ? 200 : 503);
});
