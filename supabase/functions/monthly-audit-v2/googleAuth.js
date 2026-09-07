let cached = null;
const b64url = (bytes) =>
  btoa(String.fromCharCode(...new Uint8Array(bytes))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

async function importPrivateKey(pem) {
  const body = String(pem).replace(/-----BEGIN PRIVATE KEY-----/, '').replace(/-----END PRIVATE KEY-----/, '').replace(/\s+/g, '');
  const der = Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
  return crypto.subtle.importKey('pkcs8', der.buffer, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['sign']);
}

export function parseServiceAccount(raw) {
  if (!raw) return null;
  let text = String(raw).trim();
  if (text.startsWith('"') && text.endsWith('"')) { try { text = JSON.parse(text); } catch { /* leave */ } }
  const sa = typeof text === 'string' ? JSON.parse(text) : text;
  if (!sa.client_email || !sa.private_key) throw new Error('Service account JSON is missing client_email or private_key.');
  return sa;
}

export async function getAccessToken(serviceAccount) {
  const now = Math.floor(Date.now() / 1000);
  if (cached && cached.expiresAt > now + 60) return cached.token;

  const claims = {
    iss: serviceAccount.client_email,
    scope: 'https://www.googleapis.com/auth/cloud-platform',
    aud: serviceAccount.token_uri ?? 'https://oauth2.googleapis.com/token',
    iat: now, exp: now + 3600,
  };
  const encoder = new TextEncoder();
  const unsigned = `${b64url(encoder.encode(JSON.stringify({ alg: 'RS256', typ: 'JWT' })))}.${b64url(encoder.encode(JSON.stringify(claims)))}`;
  const key = await importPrivateKey(serviceAccount.private_key);
  const signature = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key, encoder.encode(unsigned));

  const res = await fetch(claims.aud, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', assertion: `${unsigned}.${b64url(signature)}` }),
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok || !body.access_token) {
    throw new Error(`Could not get a Google access token (${res.status}): ${body.error_description ?? body.error ?? 'no detail'}`);
  }
  cached = { token: body.access_token, expiresAt: now + (body.expires_in ?? 3600) };
  return cached.token;
}
