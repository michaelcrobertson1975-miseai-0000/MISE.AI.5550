-- Close the anon-key data door.
--
-- Background: enable_rls_all_tables_with_review_exceptions turned RLS on
-- everywhere and then punched five USING (true) holes back through it for the
-- Review Queue. Those holes were granted to the `anon` role, and the anon key
-- is published to every browser by design -- it is printed in apps/chef-app,
-- and Supabase hands it out on request. So in practice:
--
--   * any person on the internet could read every restaurant's invoices, line
--     items, prices and ingredient list, and
--   * rewrite invoice headers and line items belonging to any restaurant.
--
-- No restaurant filter could have saved this. An RLS policy filters on the
-- caller's identity, and the anon role has no identity -- there is no client_id
-- in an anon JWT to compare a row against. Any `USING (client_id = ...)` written
-- for `anon` would have been decoration. The only real fix is that the anon key
-- stops being a database credential for this project.
--
-- The Review Queue was the sole consumer of these policies. It now proxies every
-- read and write through its own edge function, behind the REVIEW_ACCESS_CODE
-- cookie, using the service-role key that never leaves the server. Every other
-- client-facing function already authenticates with clients.api_token and scopes
-- its queries with .eq('client_id', ...), so nothing else is affected.

-- 1. The Review Queue's five holes. ------------------------------------------
DROP POLICY IF EXISTS invoices_anon_select ON public.invoices;
DROP POLICY IF EXISTS invoices_anon_update ON public.invoices;

DROP POLICY IF EXISTS invoice_line_items_anon_select ON public.invoice_line_items;
DROP POLICY IF EXISTS invoice_line_items_anon_insert ON public.invoice_line_items;
DROP POLICY IF EXISTS invoice_line_items_anon_update ON public.invoice_line_items;

DROP POLICY IF EXISTS ingredients_anon_select ON public.ingredients;
DROP POLICY IF EXISTS ingredients_anon_insert ON public.ingredients;

DROP POLICY IF EXISTS pnl_categories_anon_select ON public.pnl_categories;

DROP POLICY IF EXISTS invoice_corrections_anon_insert ON public.invoice_corrections;

-- 2. Two more that were created outside git, in the dashboard. ---------------
--
-- prep_yield_log's was the widest policy in the project: FOR ALL to `public`,
-- which is every role including anon, so the anon key could read, rewrite and
-- DELETE any restaurant's yield history. The Cook App never needed it -- it
-- reaches this table through prep-sync-v2, which uses the service-role key.
DROP POLICY IF EXISTS "allow all for now" ON public.prep_yield_log;

-- units is global reference data (token, base_unit, factor) with nothing
-- tenant-specific in it, but nothing reads it over the public API any more
-- either, so it goes too -- leaving a single rule that is easy to check:
-- no table in this project is reachable with the anon key.
DROP POLICY IF EXISTS units_read_all ON public.units;

-- 3. The door that RLS could not have closed anyway. -------------------------
--
-- mise_apply_correction is SECURITY DEFINER, so it runs as its owner and
-- bypasses RLS entirely -- dropping the policies above would not have touched
-- it. EXECUTE was granted to anon and authenticated and it is exposed over
-- PostgREST at /rest/v1/rpc/mise_apply_correction, where it takes a bare
-- line_item_id with no restaurant check and will rewrite prices, quantities and
-- categories on any restaurant's invoice, write into that client's
-- client_item_memory (which poisons every future ingestion for them), and flip
-- the invoice to status = 'completed' so the change sails past review.
--
-- Nothing in this repository calls it. service_role keeps EXECUTE so the
-- function stays usable from an edge function if it is ever adopted.
REVOKE EXECUTE ON FUNCTION public.mise_apply_correction(uuid, jsonb, text, boolean) FROM anon, authenticated;

-- 4. Make the next table fail closed instead of fail open. -------------------
--
-- Supabase grants anon and authenticated full DML on public by default, and RLS
-- is the only thing holding them back. That default is why a single forgotten
-- `ENABLE ROW LEVEL SECURITY` becomes a public data leak, and it is the shape of
-- the bug being fixed here. Since neither role is used as a database credential
-- anywhere in this project -- every client authenticates through an edge
-- function -- the grants themselves come off, so a new table is unreachable
-- from the public API until someone deliberately grants access to it.
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM anon, authenticated;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM anon, authenticated;
REVOKE ALL ON ALL ROUTINES IN SCHEMA public FROM anon, authenticated;

ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES FROM anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON SEQUENCES FROM anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON ROUTINES FROM anon, authenticated;

-- Same, for anything postgres creates later (Supabase's default privileges are
-- recorded per granting role, and the dashboard's SQL editor connects as
-- postgres rather than supabase_admin).
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON TABLES FROM anon, authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON SEQUENCES FROM anon, authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON ROUTINES FROM anon, authenticated;
