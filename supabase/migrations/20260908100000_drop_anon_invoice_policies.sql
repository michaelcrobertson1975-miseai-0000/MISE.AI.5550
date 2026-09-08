-- ============================================================================
-- Remove the anon read/write policies on the invoice tables.
--
-- 20260906065346 added these as "narrow exceptions, exactly matching what the
-- Review Queue page actually does". The narrowness was in WHICH TABLES, not in
-- WHO: every policy is USING (true) granted TO anon, with no client scoping.
--
-- The anon key is public by design and ships in the front end, so in practice
-- these policies meant anyone on the internet could, straight against
-- /rest/v1/ and without ever loading the Review Queue or knowing the access
-- code:
--
--   * read every invoice and every line item belonging to every restaurant
--   * UPDATE any invoice -- including setting status='completed', which pushes
--     unreviewed extractions into the P&L
--   * INSERT and UPDATE line items, i.e. write arbitrary costs into COGS
--   * INSERT ingredients
--
-- REVIEW_ACCESS_CODE gated the HTML page. It never gated the database.
--
-- PAIRED CODE CHANGE -- APPLY TOGETHER. The Review Queue page no longer talks
-- to PostgREST directly. It calls /functions/v1/review/db/..., which checks the
-- session cookie and forwards with the service-role key against a table and
-- verb allowlist. Deploy the `review` function and apply this migration in the
-- same change; this migration alone would break the Review Queue, and the
-- deploy alone would leave the hole open.
-- ============================================================================

DROP POLICY IF EXISTS invoices_anon_select            ON public.invoices;
DROP POLICY IF EXISTS invoices_anon_update            ON public.invoices;

DROP POLICY IF EXISTS invoice_line_items_anon_select  ON public.invoice_line_items;
DROP POLICY IF EXISTS invoice_line_items_anon_insert  ON public.invoice_line_items;
DROP POLICY IF EXISTS invoice_line_items_anon_update  ON public.invoice_line_items;

DROP POLICY IF EXISTS ingredients_anon_select         ON public.ingredients;
DROP POLICY IF EXISTS ingredients_anon_insert         ON public.ingredients;

DROP POLICY IF EXISTS pnl_categories_anon_select      ON public.pnl_categories;

DROP POLICY IF EXISTS invoice_corrections_anon_insert ON public.invoice_corrections;

-- These five tables now match the other 32: RLS on, no policies, so only
-- service-role (every edge function) can reach them.
COMMENT ON TABLE public.invoices IS
  'RLS on with no anon policy: reachable only through an edge function running as service-role. The Review Queue reaches it through the session-gated proxy in the review function, never with the anon key.';
