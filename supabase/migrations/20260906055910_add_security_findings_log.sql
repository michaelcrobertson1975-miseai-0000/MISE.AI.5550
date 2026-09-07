CREATE TABLE IF NOT EXISTS public.security_findings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  title text NOT NULL,
  severity varchar NOT NULL CHECK (severity IN ('critical','high','medium','low')),
  description text NOT NULL,
  affected_objects text[],
  recommended_fix text,
  status varchar NOT NULL DEFAULT 'open' CHECK (status IN ('open','resolved','wont_fix')),
  found_at timestamptz NOT NULL DEFAULT now(),
  resolved_at timestamptz
);

COMMENT ON TABLE public.security_findings IS 'Running log of security issues found during review. Intentionally not enforced or acted on automatically -- fixes require explicit sign-off before anything changes.';

INSERT INTO public.security_findings (title, severity, description, affected_objects, recommended_fix) VALUES
(
  'Row Level Security disabled on all tables',
  'critical',
  'None of the 21 public tables have RLS enabled. Anyone with the project''s public anon key can read or write every row in every table via the PostgREST API (/rest/v1/...), including all clients'' invoices, contact info, and financials.',
  ARRAY['public.invoices','public.invoice_line_items','public.clients','public.ingredients','public.invoice_corrections','and 16 other public tables'],
  'Enable RLS and add explicit policies matched to how each table is actually accessed (see the review-page finding below -- some tables are read directly by the anon key and need working policies, not blanket deny-all).'
),
(
  'Review Queue page has no login and no per-client filtering',
  'critical',
  'The review edge function serves an HTML page with the project anon key hardcoded in its JavaScript. The page has verify_jwt disabled, so no login is required to open it. Once open, it queries /rest/v1/invoices with no client_id filter at all, meaning it loads and allows editing of every restaurant''s invoices in one list.',
  ARRAY['functions/review','public.invoices','public.invoice_line_items','public.ingredients','public.pnl_categories','public.invoice_corrections'],
  'Decide who should be able to open this page at all (add a login or restrict access), and decide whether it should be scoped per-restaurant or intentionally stay as an all-clients internal tool -- then design RLS policies and/or app-level auth to match that decision.'
),
(
  'api function trusts client-supplied restaurant_id with no ownership check',
  'high',
  'The api edge function (review-queue, invoices/lines, price-moves) takes restaurant_id as a plain query parameter or body field, with no authentication proving the caller is actually associated with that restaurant. CORS is fully open (Access-Control-Allow-Origin: *) and verify_jwt is false. Anyone who obtains or guesses a valid restaurant_id (client UUID) can read or modify that restaurant's invoice data.',
  ARRAY['functions/api'],
  'Add a way to verify the caller is authorized for the restaurant_id they pass -- e.g. a per-client access token issued at signup, or a real login tied to client_id.'
),
(
  'Inbound email webhook auth token may not be set',
  'medium',
  'The email-inbound function checks for an INBOUND_TOKEN secret and requires it on incoming webhook calls, but only warns (does not block) if the secret is unset. Not yet confirmed whether this secret is actually configured in this project.',
  ARRAY['functions/email-inbound'],
  'Confirm INBOUND_TOKEN is set as a secret; if not, anyone who discovers the webhook URL could submit fake invoices for any onboarded client.'
);
