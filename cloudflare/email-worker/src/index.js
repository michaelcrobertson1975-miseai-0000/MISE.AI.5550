/**
 * Cloudflare Email Worker — a second way in for invoice mail.
 *
 * WHY THIS EXISTS. Inbound mail runs through Resend, which receives via Amazon
 * SES. On 2026-09-08 that path started deferring: messages to the verified
 * receiving domain returned delivery_delayed instead of being accepted, and
 * nothing has reached the pipeline since 2026-09-07 06:44. Nothing downstream
 * is at fault — email-inbound is never invoked, because no mail arrives. This
 * Worker removes Resend from the receiving path so a single vendor's inbound
 * outage cannot stop invoices again.
 *
 * WHAT IT DOES. Cloudflare Email Routing hands this Worker the raw RFC-822
 * message. It forwards those exact bytes to email-inbound, which already
 * parses raw MIME (sender, subject, recipients and attachments all come out of
 * the message itself) — so no payload translation is needed here, and there is
 * one less shape to keep in sync.
 *
 * AUTH. Cloudflare cannot produce a Resend/Svix signature, so this
 * authenticates with INBOUND_TOKEN via the x-inbound-token header, which is the
 * unsigned-caller path email-inbound already supports. Set it as a Worker
 * secret; it must match the INBOUND_TOKEN secret in Supabase.
 *
 * FAILURE BEHAVIOUR. If email-inbound does not accept the message, this throws
 * rather than returning quietly. Throwing makes Cloudflare treat delivery as
 * failed, so the sender gets a bounce and the invoice is visibly not received —
 * far better than a silent 200 that loses it, which is the failure mode the
 * ingestion queue was built to avoid in the first place.
 */

const MAX_BYTES = 25 * 1024 * 1024; // matches MAX_EML_BYTES in email-inbound

export default {
  async email(message, env, ctx) {
    const endpoint = env.EMAIL_INBOUND_URL;
    const token = env.INBOUND_TOKEN;

    if (!endpoint || !token) {
      // Fail loudly and bounce: accepting mail we cannot forward would lose it.
      throw new Error('Worker is not configured: EMAIL_INBOUND_URL and INBOUND_TOKEN are both required.');
    }

    const raw = new Uint8Array(await new Response(message.raw).arrayBuffer());

    if (raw.byteLength === 0) throw new Error('Empty message.');
    if (raw.byteLength > MAX_BYTES) {
      throw new Error(`Message is ${(raw.byteLength / 1048576).toFixed(1)} MB, over the ${MAX_BYTES / 1048576} MB limit.`);
    }

    const res = await fetch(endpoint, {
      method: 'POST',
      headers: {
        // Raw MIME: email-inbound's fromMime() path reads From/Subject/To and
        // pulls the attachments straight out of the message.
        'Content-Type': 'message/rfc822',
        'x-inbound-token': token,
        // Handy in the Supabase logs for telling this path apart from Resend's.
        'x-forwarded-by': 'cloudflare-email-worker',
      },
      body: raw,
    });

    const body = await res.text().catch(() => '');

    if (!res.ok) {
      console.error(`[email-worker] email-inbound returned ${res.status}: ${body.slice(0, 500)}`);
      throw new Error(`email-inbound rejected the message (HTTP ${res.status}).`);
    }

    console.log(`[email-worker] forwarded ${message.from} -> ${message.to} (${raw.byteLength} bytes): ${body.slice(0, 300)}`);
  },
};
