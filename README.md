# MISE.AI

Mise.AI is an AI-powered back-of-house platform for restaurants: invoice ingestion and COGS
tracking, price-variance alerts, beverage/bar inventory with BOM-based depletion, nightly
POS report ingestion, prep & yield tracking, ordering guides, staff scheduling, and monthly
audit reporting — all backed by Supabase (Postgres + Edge Functions).

This repository is the exported source of record for the Mise.AI Supabase project. It was
migrated out of Supabase into git so the codebase has real version control, code review, and
a durable history independent of the Supabase dashboard.

## Repo layout

```
apps/
  chef-app/         Chef App — the restaurant-facing dashboard (single-page HTML app)
    index.html        Review Queue, Price Moves, Order Food, Order Beverage,
                       Prep & Cook, Schedule, and Monthly Audit tabs
  cook-app/          Cook App — kitchen-floor prep & yield logging app
    index.html

supabase/
  migrations/        All Postgres schema migrations, in order (70 files as of this export).
                      Covers: invoice engine + COGS categorization, price variance tracking,
                      Postgres-side invoice math (mise_parse_pack / mise_line_item_math /
                      mise_audit_invoice), clients + manual billing + api_token auth,
                      intake_rows spreadsheet uploads, RLS security hardening, the "locker"
                      continuity-log subsystem, beverage/bar inventory + BOM system, nightly
                      report ingestion + inventory depletion, the ingestion_queue job system
                      (pg_cron + pg_net), prep_yield_log, and the ordering/schedule/monthly
                      audit subsystems built on top of the real ingredients table.

  functions/         All Supabase Edge Functions (Deno), one directory per function:
    ingest-invoice/    Core invoice ingestion — Gemini (Vertex + AI Studio) extraction,
                       cross-batch invoice-number grouping, dedup against live invoices
    upload/            Public invoice-drop HTML page
    email-inbound/     Inbound email webhook (Resend/SendGrid/Mailgun/Postmark/Cloudflare),
                       routes to a client and enqueues to ingestion_queue
    key-check/         Diagnostic: AI Studio + Vertex credential / model probe
    review/            Review Queue HTML UI + corrections-tracking backend
    prep-probe/        Throwaway ImageMagick WASM diagnostic (not in production pipeline)
    api/               Backend for Chef App's Review Queue and Price Moves tabs
    signup/            Self-serve trial signup, client onboarding, intake email
    upload-scan/       Landing-page camera multipart upload
    intake-upload/     CSV/XLSX row upload with per-row rejection reporting
    ingest-nightly-report/  Gemini transcription of nightly POS reports
    process-queue/     Ingestion queue worker (claims + replays jobs)
    order-guide/       Backend for Order Food tab (reads/writes ingredients)
    beverage-guide/    Backend for Order Beverage tab (reads/writes beverage_items)
    product-mix/       Backend for Product Mix tab
    prep-sync/         Early diagnostic predecessor to prep-sync-v2
    prep-sync-v2/      Production backend for Prep & Cook tab and the Cook App
    schedule-sync/     Backend for Schedule tab (staff + shifts)
    monthly-audit/      Original monthly audit generator (superseded by -v2)
    monthly-audit-v2/   Production monthly audit generator, wired into Chef App

docs/                Reserved for project documentation.
```

## Auth model

Every function falls into one of three groups.

**Client-facing — `restaurant_id` + `api_token`.** `api`, `order-guide`, `beverage-guide`,
`product-mix`, `prep-sync-v2`, `schedule-sync`, `monthly-audit`, `monthly-audit-v2`,
`upload-scan` and `intake-upload` check the pair against `clients.api_token`, with
`clients.status` required to be `active` or `trial`. This is a custom check rather than
Supabase JWT auth.

**Internal only — service-role key.** `ingest-invoice` and `ingest-nightly-report` cost real
money per page and write directly into a restaurant's books, so they refuse any caller that
does not present the service-role key. Their callers are `process-queue` and `upload-scan`,
both server-side. `email-inbound` is the third internal endpoint; it cannot use a JWT because
mail providers cannot mint one, so it requires `INBOUND_TOKEN` and refuses to serve at all
when that secret is unset.

**Session-gated — `review`.** Gated by `REVIEW_ACCESS_CODE`, which is exchanged at login for
a signed, expiring session cookie. The page's data access goes through `/review/db/...` on
the function itself, which re-checks the session and forwards to PostgREST with the
service-role key against a table and verb allowlist. It does not use the anon key, and the
invoice tables carry no anon policies.

> **Known gap.** `apps/chef-app` and `apps/cook-app` still hardcode `MISE_API_TOKEN` in
> client-side JavaScript, so the token reaches every visitor. The checks above are real, but a
> published credential passes them. Replacing this with per-user auth (Supabase Auth + RLS, or
> Cloudflare Access injecting the token server-side) is the outstanding piece of work, and the
> token should be rotated when it lands.

## Local development

This project uses the [Supabase CLI](https://supabase.com/docs/guides/local-development) for
local development: `supabase start`, `supabase db reset` to replay migrations, and
`supabase functions serve` to run Edge Functions locally. See each function's directory for
any additional per-function config (`deno.json`).

## Ground rule

No schema migrations, code changes, or edge function deploys happen without explicit mutual
sign-off first. Read-only checks (viewing code, querying data, logs) are always fine.
