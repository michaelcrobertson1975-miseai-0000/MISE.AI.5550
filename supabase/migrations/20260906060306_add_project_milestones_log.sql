CREATE TABLE IF NOT EXISTS public.project_milestones (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  title text NOT NULL,
  summary text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.project_milestones IS 'Snapshots of where the project stands, agreed on together, to pick up from next session.';

INSERT INTO public.project_milestones (title, summary) VALUES (
  'Math-in-Postgres confirmed working; security findings logged, fix deferred',
  'CONFIRMED WORKING: Gemini only transcribes invoices (no math, no page grouping). Postgres does all arithmetic and unit parsing via triggers (mise_line_item_math, mise_parse_pack, mise_audit_invoice), wired up in migrations move_invoice_math_to_postgres and postgres_math_full_coverage (2026-09-05 morning). Verified live end-to-end: a forwarded Sysco invoice went through email-inbound -> ingest-invoice -> Postgres triggers -> a correctly-audited invoice row in about 20 seconds, with 2 lines correctly flagged for human review.

SECURITY: 4 findings logged in public.security_findings (2 critical, 1 high, 1 medium) -- RLS disabled project-wide, the Review Queue page has no login and shows all clients'' data mixed together, the api function trusts a caller-supplied restaurant_id with no ownership check, and the inbound email webhook token may not be set. All left OPEN on purpose -- we are intentionally in a trial-and-error phase and will fix these together when ready, not before.

GROUND RULE IN EFFECT: no migrations, code changes, or edge function deploys happen without explicit mutual sign-off first. Read-only checks (viewing code, querying data, logs) are always fine.

NEXT TIME: pick up from the security_findings table -- decide the Review Queue''s intended audience (all-clients internal tool vs. per-restaurant) and design RLS/auth to match, before anything else changes.'
);
