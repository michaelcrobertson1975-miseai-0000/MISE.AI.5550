-- Enable RLS on all 21 previously-unprotected tables.
ALTER TABLE public.invoices ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.invoice_line_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.monthly_pnl_snapshots ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.client_email_routes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.invoice_corrections ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ingredients ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pnl_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pnl_periods ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pnl_manual_costs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.client_category_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.client_routing_hints ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.unrouted_emails ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.units ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.prep_stations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.prep_units ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.prep_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.prep_recipes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.prep_day ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.clients ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.client_payments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.intake_rows ENABLE ROW LEVEL SECURITY;

-- No policies on the 16 tables above that Review Queue doesn't touch -- that
-- means zero anon/authenticated access, full stop. Only service-role (used by
-- every edge function except review) can still read/write them.

-- Narrow exceptions, exactly matching what the Review Queue page actually does:
CREATE POLICY invoices_anon_select ON public.invoices FOR SELECT TO anon USING (true);
CREATE POLICY invoices_anon_update ON public.invoices FOR UPDATE TO anon USING (true) WITH CHECK (true);

CREATE POLICY invoice_line_items_anon_select ON public.invoice_line_items FOR SELECT TO anon USING (true);
CREATE POLICY invoice_line_items_anon_insert ON public.invoice_line_items FOR INSERT TO anon WITH CHECK (true);
CREATE POLICY invoice_line_items_anon_update ON public.invoice_line_items FOR UPDATE TO anon USING (true) WITH CHECK (true);

CREATE POLICY ingredients_anon_select ON public.ingredients FOR SELECT TO anon USING (true);
CREATE POLICY ingredients_anon_insert ON public.ingredients FOR INSERT TO anon WITH CHECK (true);

CREATE POLICY pnl_categories_anon_select ON public.pnl_categories FOR SELECT TO anon USING (true);

CREATE POLICY invoice_corrections_anon_insert ON public.invoice_corrections FOR INSERT TO anon WITH CHECK (true);
