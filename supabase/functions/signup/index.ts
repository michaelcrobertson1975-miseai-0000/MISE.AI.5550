// @ts-nocheck
/**
 * MiseAI signup.
 *
 * Onboarding is manual and billing is monthly by Venmo, so this takes no card,
 * no processor, no webhook. It creates a trial client, its intake address, and
 * the two routing fallbacks - then EMAILS the restaurant the one thing they
 * need to start: the address to forward invoices to. The address is no longer
 * shown on screen on success -- email is the only delivery path, unless the
 * email itself fails to send, in which case it falls back to on-screen display
 * so nobody gets permanently locked out of their own signup.
 *
 *   GET  /  -> the form
 *   POST /  -> create the client, email the intake address, return status only
 *
 * The sender and subject fallbacks are not optional extras. Three of this
 * project's own emails were silently dropped because they went to invoice@
 * when the route said invoices@; a restaurant that mistypes its own address
 * still routes on who sent it.
 */
import { createClient } from 'jsr:@supabase/supabase-js@2';

const MAIL_DOMAIN = Deno.env.get('MISE_MAIL_DOMAIN') ?? 'in.miseai-0000.com';
const FROM_EMAIL = Deno.env.get('MISE_FROM_EMAIL') ?? `MiseAI <welcome@${MAIL_DOMAIN}>`;
const OWNER_EMAIL = Deno.env.get('MISE_OWNER_EMAIL') ?? 'michael@miseai-0000.com';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'content-type',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
};
const json = (b, s = 200) =>
  new Response(JSON.stringify(b, null, 2), { status: s, headers: { ...CORS, 'Content-Type': 'application/json' } });

const slugify = (s) =>
  String(s ?? '').toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '')
    .replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 40);

const escHtml = (s) =>
  String(s ?? '').replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

/**
 * Tell the owner a new signup came in, with whatever screening details were
 * submitted, so onboarding can stay a manual, personal reply rather than
 * automatic access. Never throws -- a failed notification should not block
 * the client's own signup from completing.
 */
async function sendOwnerNotification(clientId, name, contactName, contactEmail, phone, screening) {
  const key = Deno.env.get('RESEND_API_KEY');
  if (!key) {
    console.warn('[signup] RESEND_API_KEY is not set; cannot notify the owner of this signup.');
    return { sent: false, reason: 'RESEND_API_KEY not set' };
  }
  const rows = [
    ['Restaurant', name],
    ['Contact', contactName],
    ['Email', contactEmail],
    ['Phone', phone],
    ['Role', screening.role],
    ['Kitchen type', screening.kitchenType],
    ['Locations', screening.locations],
    ['Covers/night (avg)', screening.coversPerNight],
    ['POS / accounting', screening.posSystem],
    ['Notes', screening.notes],
    ['Client ID', clientId],
  ].filter(([, v]) => v);
  const html = `
    <p>New MiseAI signup to review:</p>
    <ul>${rows.map(([k, v]) => `<li><strong>${escHtml(k)}:</strong> ${escHtml(v)}</li>`).join('')}</ul>
  `;
  try {
    const res = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        from: FROM_EMAIL,
        to: OWNER_EMAIL,
        subject: `New signup: ${name}`,
        html,
      }),
    });
    if (!res.ok) {
      const detail = await res.text().catch(() => '');
      console.error(`[signup] owner notification failed (${res.status}): ${detail}`);
      return { sent: false, reason: `Resend HTTP ${res.status}` };
    }
    return { sent: true };
  } catch (err) {
    console.error('[signup] owner notification threw:', err.message);
    return { sent: false, reason: err.message };
  }
}

/**
 * Send the intake address by email. Never throws -- a failed send should not
 * block onboarding, it should just fall back to showing the address on screen.
 */
async function sendWelcomeEmail(toEmail, restaurantName, intakeEmail, trialDays) {
  const key = Deno.env.get('RESEND_API_KEY');
  if (!key) {
    console.warn('[signup] RESEND_API_KEY is not set; cannot email the intake address, falling back to on-screen display.');
    return { sent: false, reason: 'RESEND_API_KEY not set' };
  }
  const html = `
    <p>${restaurantName} is set up on MiseAI.</p>
    <p>Forward invoices to this address, and they'll be read and checked automatically:</p>
    <p style="font-size:20px;font-weight:bold;margin:16px 0;">${intakeEmail}</p>
    <p>Photos of a paper invoice work too -- several pages in one email become one invoice.</p>
    <p>${trialDays} days free. We'll be in touch before anything is owed.</p>
  `;
  try {
    const res = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        from: FROM_EMAIL,
        to: toEmail,
        subject: 'Your MiseAI invoice address is ready',
        html,
      }),
    });
    if (!res.ok) {
      const detail = await res.text().catch(() => '');
      console.error(`[signup] Resend send failed (${res.status}): ${detail}`);
      return { sent: false, reason: `Resend HTTP ${res.status}` };
    }
    return { sent: true };
  } catch (err) {
    console.error('[signup] Resend send threw:', err.message);
    return { sent: false, reason: err.message };
  }
}

async function signup(req) {
  let body;
  try { body = await req.json(); }
  catch { return json({ success: false, error: 'Send JSON.' }, 400); }

  // The request-access form (public/form.html) sends a richer set of fields
  // than the original embedded GET page below; accept either shape.
  const firstName = String(body.first_name ?? '').trim();
  const lastName = String(body.last_name ?? '').trim();
  const name = String(body.name ?? body.restaurant_name ?? '').trim();
  const contactName = String(body.contact_name ?? `${firstName} ${lastName}`).trim() || null;
  const contactEmail = String(body.contact_email ?? body.work_email ?? '').trim().toLowerCase() || null;
  const phone = String(body.contact_phone ?? '').trim() || null;

  // Screening fields, present only from the richer request-access form.
  // Never stored in Postgres -- just relayed to the owner for manual review,
  // so adding a field here never needs a schema migration.
  const screening = {
    role: String(body.role ?? '').trim(),
    kitchenType: String(body.kitchen_type ?? '').trim(),
    locations: String(body.locations ?? '').trim(),
    coversPerNight: String(body.covers_per_night ?? '').trim(),
    posSystem: String(body.pos_system ?? '').trim(),
    notes: String(body.notes ?? '').trim(),
  };

  if (name.length < 2) return json({ success: false, error: 'Restaurant name is required.' }, 400);
  if (!contactEmail) return json({ success: false, error: 'An email address is required -- that is now the only way we can send you your invoice address.' }, 400);
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(contactEmail)) {
    return json({ success: false, error: 'That email address does not look right.' }, 400);
  }

  const slug = slugify(name);
  if (!slug) return json({ success: false, error: 'That name has no letters or numbers in it.' }, 400);

  const db = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));

  const { data: taken } = await db.from('clients').select('id').eq('slug', slug).maybeSingle();
  if (taken) {
    return json({ success: false, error: `A restaurant called "${name}" is already set up. Get in touch and we'll sort it out.` }, 409);
  }

  const intake = `${slug}@${MAIL_DOMAIN}`;
  const { data, error } = await db.rpc('mise_onboard_client', {
    p_name: name,
    p_intake_email: intake,
    p_contact_email: contactEmail,
    p_contact_name: contactName,
    p_monthly_rate: null,          // set by hand when the trial converts
    p_venmo: null,
    p_subject_word: null,
  });
  if (error) {
    console.error('[signup] failed:', error.message);
    return json({ success: false, error: error.message }, 500);
  }

  if (phone) await db.from('clients').update({ contact_phone: phone }).eq('id', data);

  const trialDays = 14;
  const emailResult = await sendWelcomeEmail(contactEmail, name, intake, trialDays);
  await sendOwnerNotification(data, name, contactName, contactEmail, phone, screening);

  console.log(`[signup] ${name} -> ${data} (${intake}) email_sent=${emailResult.sent}${emailResult.sent ? '' : ` reason=${emailResult.reason}`}`);

  return json({
    success: true,
    client_id: data,
    restaurant: name,
    contact_email: contactEmail,
    trial_days: trialDays,
    email_sent: emailResult.sent,
    // Only present so the page can fall back to on-screen display if the email
    // could not be sent. Never shown when email_sent is true.
    intake_email: emailResult.sent ? undefined : intake,
  });
}

const PAGE = `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>MiseAI — Start</title>
<link href="https://fonts.googleapis.com/css2?family=Fraunces:ital,wght@0,400;0,600;1,400&display=swap" rel="stylesheet">
<style>
*{box-sizing:border-box;margin:0;padding:0;}
:root{
  --bg-app:#0A0A0C; --bg-card:#141416; --bg-recessed:#060608;
  --text-hero:#FFFFFF; --text-muted:#F0F4F8; --text-faint:#A8AEB8;
  --brand-accent:#FDE047; --brand-accent-hover:#FFED4E;
  --alert-success:#CCFBF1; --alert-danger:#FF6B6B;
  --border-subtle:rgba(240,244,248,0.20);
  --shadow-soft:rgba(0,0,0,0.7);
  --line-fade:linear-gradient(90deg,#1C1E26 0%,#0A0A0C 50%,#FDE047 100%);
  --font:'Fraunces',Georgia,serif;
}
b,strong{font-weight:400;}
body{background:var(--bg-app);color:var(--text-hero);font:16px/1.55 var(--font);min-height:100vh;padding:32px 20px 80px;}
.wrap{max-width:520px;margin:0 auto;}
.brand{font-size:11px;letter-spacing:.22em;text-transform:uppercase;color:var(--brand-accent);margin-bottom:6px;}
h1{font-size:30px;font-weight:400;line-height:1.15;letter-spacing:-.01em;margin-bottom:10px;}
.sub{color:var(--text-faint);font-size:15px;margin-bottom:22px;}
.rule{height:3px;background:var(--line-fade);border-radius:2px;margin-bottom:26px;}
.card{background:var(--bg-card);border:1px solid var(--border-subtle);border-radius:8px;padding:22px 20px;box-shadow:0 4px 18px var(--shadow-soft);}
label{display:block;font-size:11px;letter-spacing:.12em;text-transform:uppercase;color:var(--text-faint);margin:16px 0 6px;}
label:first-of-type{margin-top:0;}
input{width:100%;background:var(--bg-recessed);border:1px solid var(--border-subtle);border-radius:5px;
  padding:13px 12px;font:16px var(--font);color:var(--text-hero);outline:none;min-height:48px;}
input:focus{border-color:var(--brand-accent);}
.req{color:var(--brand-accent);}
button{width:100%;margin-top:22px;background:var(--brand-accent);color:var(--bg-app);border:none;border-radius:5px;
  padding:16px;font:12px var(--font);letter-spacing:.14em;text-transform:uppercase;cursor:pointer;min-height:52px;}
button:hover{background:var(--brand-accent-hover);}
button:disabled{opacity:.45;cursor:not-allowed;}
.note{color:var(--text-faint);font-size:13px;margin-top:16px;line-height:1.5;}
.err{background:rgba(255,107,107,.10);border:1px solid var(--alert-danger);color:var(--alert-danger);
  border-radius:5px;padding:11px 13px;font-size:14px;margin-top:16px;}
.done .big{font-size:20px;margin-bottom:14px;}
.addr{background:var(--bg-recessed);border:1px solid var(--brand-accent);border-radius:5px;padding:15px 13px;
  font-size:17px;color:var(--brand-accent);word-break:break-all;text-align:center;margin:14px 0;}
.steps{counter-reset:s;margin-top:18px;}
.steps li{list-style:none;counter-increment:s;position:relative;padding-left:32px;margin-bottom:12px;color:var(--text-muted);font-size:15px;}
.steps li::before{content:counter(s);position:absolute;left:0;top:1px;width:22px;height:22px;border-radius:50%;
  background:var(--brand-accent);color:var(--bg-app);font-size:12px;display:flex;align-items:center;justify-content:center;}
.copy{background:transparent;color:var(--text-hero);border:1px solid var(--border-subtle);margin-top:0;}
.copy:hover{background:var(--bg-recessed);border-color:var(--text-hero);}
.foot{text-align:center;color:var(--text-faint);font-size:11px;letter-spacing:.18em;text-transform:uppercase;margin-top:30px;}
</style></head><body>
<div class="wrap">
  <div class="brand">MiseAI</div>
  <h1>Forward an invoice. Get your food cost.</h1>
  <div class="sub">No card, no contract. Two weeks free, then a flat monthly fee billed by Venmo.</div>
  <div class="rule"></div>

  <div class="card" id="card">
    <form id="f" novalidate>
      <label for="name">Restaurant name <span class="req">*</span></label>
      <input id="name" name="name" autocomplete="organization" required>

      <label for="contact_name">Your name</label>
      <input id="contact_name" name="contact_name" autocomplete="name">

      <label for="contact_email">Email <span class="req">*</span></label>
      <input id="contact_email" name="contact_email" type="email" inputmode="email" autocomplete="email" required>

      <label for="contact_phone">Phone</label>
      <input id="contact_phone" name="contact_phone" type="tel" inputmode="tel" autocomplete="tel">

      <button type="submit" id="go">Start free</button>
      <div class="note">Your invoice-forwarding address will be emailed to you — it's the only place you'll see it, so use an inbox you check.</div>
      <div id="err"></div>
    </form>
  </div>

  <div class="foot">Every invoice read · Every price move caught</div>
</div>
<script>
var f = document.getElementById('f'), go = document.getElementById('go'), err = document.getElementById('err');
function esc(s){return String(s==null?'':s).replace(/[&<>"]/g,function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c];});}

f.addEventListener('submit', async function(ev){
  ev.preventDefault();
  err.innerHTML = '';
  var body = {
    name: document.getElementById('name').value.trim(),
    contact_name: document.getElementById('contact_name').value.trim(),
    contact_email: document.getElementById('contact_email').value.trim(),
    contact_phone: document.getElementById('contact_phone').value.trim()
  };
  if(body.name.length < 2){ err.innerHTML = '<div class="err">Tell us the restaurant name.</div>'; return; }
  if(!body.contact_email){ err.innerHTML = '<div class="err">An email address is required — that\\'s how you\\'ll get your invoice address.</div>'; return; }

  go.disabled = true; go.textContent = 'Setting you up…';
  try{
    var res = await fetch(location.pathname, {
      method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(body)
    });
    var data = await res.json();
    if(!res.ok || !data.success) throw new Error(data.error || 'Something went wrong.');

    if (data.email_sent) {
      document.getElementById('card').innerHTML =
        '<div class="done">'
        + '<div class="big">' + esc(data.restaurant) + ' is set up.</div>'
        + '<div class="note" style="margin-top:0">Check <b>' + esc(data.contact_email) + '</b> for an email with your invoice-forwarding address.</div>'
        + '<ol class="steps">'
        + '<li>Open the email and save the address it gives you.</li>'
        + '<li>Forward a delivery invoice, or photograph one and send it.</li>'
        + '<li>It is read and the maths checked in about twenty seconds.</li>'
        + '</ol>'
        + '<div class="note">' + esc(String(data.trial_days)) + ' days free. We will be in touch before anything is owed.</div>'
        + '</div>';
    } else {
      // Fallback: the email could not be sent, so show the address directly
      // rather than leaving the restaurant with no way to get it at all.
      document.getElementById('card').innerHTML =
        '<div class="done">'
        + '<div class="big">' + esc(data.restaurant) + ' is set up.</div>'
        + '<div class="note" style="margin-top:0">We could not email your address, so here it is — save it now:</div>'
        + '<div class="addr" id="addr">' + esc(data.intake_email) + '</div>'
        + '<button class="copy" id="cp">Copy address</button>'
        + '<ol class="steps">'
        + '<li>Forward a delivery invoice, or photograph one and send it.</li>'
        + '<li>It is read and the maths checked in about twenty seconds.</li>'
        + '<li>Anything unclear waits in your Review Queue — fix it once and it is remembered.</li>'
        + '</ol>'
        + '<div class="note">' + esc(String(data.trial_days)) + ' days free. We will be in touch before anything is owed.</div>'
        + '</div>';
      var cpBtn = document.getElementById('cp');
      if (cpBtn) cpBtn.addEventListener('click', function(){
        var t = document.getElementById('addr').textContent;
        if(navigator.clipboard){ navigator.clipboard.writeText(t); this.textContent = 'Copied'; }
        else { this.textContent = t; }
      });
    }
  } catch(e){
    err.innerHTML = '<div class="err">' + esc(e.message) + '</div>';
    go.disabled = false; go.textContent = 'Start free';
  }
});
</script>
</body></html>`;

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method === 'POST') {
    try { return await signup(req); }
    catch (err) {
      console.error('[signup] unhandled:', err?.message ?? err);
      return json({ success: false, error: err?.message ?? String(err) }, 500);
    }
  }
  return new Response(PAGE, { headers: { ...CORS, 'Content-Type': 'text/html; charset=utf-8' } });
});
