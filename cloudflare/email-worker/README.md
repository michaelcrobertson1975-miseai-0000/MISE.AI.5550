# Cloudflare Email Worker — inbound invoice mail

A second receiving path for invoice mail, independent of Resend.

## Why

Inbound mail runs through Resend (which receives via Amazon SES). On 2026-09-08
that path began deferring — mail to the verified receiving domain returns
`delivery_delayed` rather than being accepted, and nothing has reached the
pipeline since 2026-09-07 06:44. `email-inbound` is never invoked because no
mail arrives.

This Worker takes Resend out of the receiving path. Cloudflare accepts the mail
and posts the raw message straight to `email-inbound`, which parses MIME
already. Everything downstream — routing, the ingestion queue, Gemini
extraction, the Postgres audit — is unchanged.

## Setup

Requires the domain's DNS to be on Cloudflare.

1. **Enable Email Routing** — Cloudflare dashboard → the zone for
   `miseai-0000.com` → **Email** → **Email Routing** → enable. Cloudflare adds
   its own MX records.

   > This replaces the Resend MX record on whichever hostname you point at
   > Cloudflare. Run it on a *new* hostname first (see step 4) so the existing
   > Resend route is untouched until you have seen this one work.

2. **Deploy the Worker**

   ```
   cd cloudflare/email-worker
   npx wrangler deploy
   npx wrangler secret put INBOUND_TOKEN     # same value as Supabase's INBOUND_TOKEN
   ```

3. **Set `INBOUND_TOKEN` in Supabase** to the same value, if it is not set
   already. Without it `email-inbound` refuses unsigned callers, which is what
   this Worker is.

4. **Route an address to the Worker** — Email Routing → **Routes** → create a
   custom address, e.g. `invoices@cf.miseai-0000.com`, with action **Send to a
   Worker** → `mise-email-inbound`.

5. **Test** by emailing that address with an invoice attached, then check:

   ```
   npx wrangler tail mise-email-inbound
   ```

   and the Supabase logs for `email-inbound`. A queued job appears in
   `ingestion_queue`; `process-queue` picks it up within 60 seconds.

6. **Cut over** once it works: point the address restaurants use at the Worker,
   or keep both paths live — `email-inbound` deduplicates by invoice number, so
   the same invoice arriving twice does not double-post.

## Notes

- The Worker sends raw RFC-822 with `Content-Type: message/rfc822`, which
  `email-inbound` handles via its `fromMime()` path. Forwarded mail carrying a
  nested `.eml` is unwrapped there, same as on the Resend path.
- Requests carry `x-forwarded-by: cloudflare-email-worker` so the two inbound
  paths are distinguishable in the Supabase logs.
- A rejected forward throws, so Cloudflare bounces to the sender rather than
  silently dropping the invoice.
- 25 MB cap, matching `MAX_EML_BYTES` in `email-inbound`.
