-- Removes the last of the wide-open anon RLS policies that let anyone with
-- the (publicly-visible-by-design) anon key read and write every
-- restaurant's invoices, line items, ingredients and corrections with no
-- client_id filter at all (locker finding 9ac158b0).
--
-- Safe now because both browser pages that used to rely on this
-- (review, correct) have been converted to server-side proxies: the browser
-- calls the edge function's own ?api= endpoint, the edge function re-checks
-- the existing access-code cookie, then makes the real PostgREST call
-- itself using SUPABASE_SERVICE_ROLE_KEY, which never reaches the browser.
-- No remaining code path needs anon access to these four tables (verified:
-- upload, upload-scan and process-queue only ever use the anon key as a
-- bearer token to invoke OTHER edge functions, never to call PostgREST
-- directly).
--
-- After this, anon has zero grants on these tables; RLS default-denies.

drop policy if exists ingredients_anon_select on public.ingredients;
drop policy if exists ingredients_anon_insert on public.ingredients;

drop policy if exists invoice_corrections_anon_insert on public.invoice_corrections;

drop policy if exists invoice_line_items_anon_select on public.invoice_line_items;
drop policy if exists invoice_line_items_anon_insert on public.invoice_line_items;
drop policy if exists invoice_line_items_anon_update on public.invoice_line_items;

drop policy if exists invoices_anon_select on public.invoices;
drop policy if exists invoices_anon_update on public.invoices;
