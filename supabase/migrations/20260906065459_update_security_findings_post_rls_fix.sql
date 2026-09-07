UPDATE public.security_findings
SET status = 'resolved', resolved_at = now()
WHERE title = 'Row Level Security disabled on all tables';

UPDATE public.security_findings
SET description = description || ' UPDATE: RLS is now enabled on all 21 tables. 16 tables that Review Queue never touches are now fully locked to anon/authenticated. The 5 tables Review Queue does need (invoices, invoice_line_items, ingredients, pnl_categories, invoice_corrections) still allow anon access, scoped to exactly the operations that page performs -- so the core problem (no login, no per-client filtering on those 5 tables) is unchanged and still open.'
WHERE title = 'Review Queue page has no login and no per-client filtering';

INSERT INTO public.security_findings (title, severity, description, affected_objects, recommended_fix, status, resolved_at) VALUES
(
  'Six views defined as SECURITY DEFINER could bypass the new RLS policies',
  'critical',
  'Discovered while verifying the RLS fix via Supabase''s own advisor. These views ran with their creator''s privileges rather than the querying user''s, meaning anyone could have queried them directly (e.g. GET /rest/v1/v_item_price_variance) to read data across every client, completely sidestepping the table-level RLS policies just added.',
  ARRAY['public.v_item_price_variance','public.v_period_cogs','public.v_chef_price_book','public.ingredient_price_history','public.pnl_period_summary','public.billing_this_month'],
  'Fixed immediately: all six converted to security_invoker so they now respect the querying role''s RLS, same as any table.',
  'resolved',
  now()
),
(
  'About 18 database functions have a mutable search_path',
  'medium',
  'Supabase''s advisor flags every mise_* function (mise_line_item_math, mise_audit_invoice, mise_onboard_client, etc.) for not pinning search_path. This is a hardening gap, not an active data leak -- it is a theoretical route for search-path-hijacking if an attacker could ever create objects in a schema ahead of these functions'' lookup path, which is not currently reachable here. Lower urgency than the other findings.',
  ARRAY['~18 functions in public schema, prefixed mise_'],
  'Add SET search_path = public, pg_temp to each function definition. Mechanical, low-risk, but touches ~18 functions -- worth doing as a batch, not urgent.',
  'open',
  null
);
