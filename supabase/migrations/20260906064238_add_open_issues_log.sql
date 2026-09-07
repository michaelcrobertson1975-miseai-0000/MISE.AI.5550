CREATE TABLE IF NOT EXISTS public.open_issues (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  title text NOT NULL,
  description text NOT NULL,
  area varchar,
  status varchar NOT NULL DEFAULT 'open' CHECK (status IN ('open','resolved','wont_fix')),
  created_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.open_issues IS 'Non-security bugs and rough edges to revisit, separate from security_findings.';

INSERT INTO public.open_issues (title, description, area) VALUES (
  'Signup page appeared blank in browser (unconfirmed cause)',
  'Server-side logs confirm the signup page returned 200 OK and served the full page correctly when tested. The blank screen was seen through a Chrome AI reading tool that also returned garbled/fabricated HTML ("corrected" code that did not match reality), suggesting that tool corrupted the page rather than the page itself being broken. Never confirmed with a direct hard-refresh or incognito-window test. Worth a clean cross-browser check before wider release, since a broken first impression on signup would be costly.',
  'signup-page'
);
