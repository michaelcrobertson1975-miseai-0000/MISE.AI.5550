-- Nightly reports need their own dedicated inbound address, separate from
-- invoices@ -- otherwise the system would have to guess whether an
-- attachment is an invoice or a sales report, which is fragile. A distinct
-- address makes routing unambiguous.
ALTER TABLE public.client_email_routes
  ADD COLUMN IF NOT EXISTS route_kind varchar NOT NULL DEFAULT 'invoice'
  CHECK (route_kind IN ('invoice','nightly_report'));

CREATE OR REPLACE FUNCTION public.mise_client_for_report_email(p_address text)
RETURNS uuid
LANGUAGE sql STABLE
AS $$
  SELECT client_id FROM public.client_email_routes
   WHERE lower(email_address) = lower(p_address)
     AND is_active = true AND route_kind = 'nightly_report'
   LIMIT 1;
$$;

-- Keep the existing invoice router scoped to invoice routes only, now that
-- both kinds live in the same table.
CREATE OR REPLACE FUNCTION public.mise_client_for_email(p_address text)
RETURNS uuid
LANGUAGE sql STABLE
AS $$
  SELECT client_id FROM public.client_email_routes
   WHERE lower(email_address) = lower(p_address)
     AND is_active = true AND route_kind = 'invoice'
   LIMIT 1;
$$;

INSERT INTO public.client_email_routes (client_id, email_address, restaurant_name, route_kind)
VALUES ('7d1f0a2e-6c44-4b9a-9f31-2ab8e5c07d10', 'sales@in.miseai-0000.com', 'Cellar - nightly sales report', 'nightly_report');

-- One row per night's report.
CREATE TABLE public.nightly_reports (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id uuid NOT NULL REFERENCES public.clients(id),
  report_date date,
  sales_amount numeric,
  labor_cost numeric,
  model_used varchar,
  source_file_path text,
  created_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.nightly_reports IS 'One row per nightly sales/labor report. Feeds prime cost (with monthly_pnl_snapshots) and triggers inventory depletion via nightly_product_mix.';

-- One row per POS button sold that night, matched to a BOM to drain stock.
CREATE TABLE public.nightly_product_mix (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  nightly_report_id uuid NOT NULL REFERENCES public.nightly_reports(id) ON DELETE CASCADE,
  pos_button text NOT NULL,
  qty_sold numeric NOT NULL,
  matched_bom_id uuid REFERENCES public.beverage_boms(id),
  base_units_depleted numeric,
  created_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.nightly_product_mix IS 'Raw POS line items for one night. matched_bom_id and base_units_depleted are filled in by mise_apply_nightly_depletion -- null means no BOM exists yet for that POS button (e.g. a food item with no liquid to track, or one nobody has mapped yet).';

-- The actual "drain the inventory" step. Matches each POS button to a BOM
-- (case-insensitive), multiplies qty_sold by that BOM's base_units_consumed
-- (which already accounts for yield_factor -- fountain/coffee are not
-- treated as a plain 1:1 pour), and subtracts it from stock on hand.
CREATE OR REPLACE FUNCTION public.mise_apply_nightly_depletion(p_nightly_report_id uuid)
RETURNS TABLE(pos_button text, matched boolean, base_units_depleted numeric)
LANGUAGE plpgsql
AS $function$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT npm.id, npm.pos_button, npm.qty_sold, bb.id AS bom_id, bb.beverage_item_id, bb.base_units_consumed
      FROM public.nightly_product_mix npm
      LEFT JOIN public.nightly_reports nr ON nr.id = npm.nightly_report_id
      LEFT JOIN public.beverage_boms bb
        ON bb.client_id = nr.client_id AND lower(bb.pos_item_name) = lower(npm.pos_button)
     WHERE npm.nightly_report_id = p_nightly_report_id
  LOOP
    IF r.bom_id IS NULL THEN
      UPDATE public.nightly_product_mix SET matched_bom_id = NULL, base_units_depleted = NULL WHERE id = r.id;
      RETURN QUERY SELECT r.pos_button, false, NULL::numeric;
    ELSE
      UPDATE public.nightly_product_mix
         SET matched_bom_id = r.bom_id, base_units_depleted = round(r.qty_sold * r.base_units_consumed, 4)
       WHERE id = r.id;
      UPDATE public.beverage_items
         SET total_base_units_in_stock = total_base_units_in_stock - round(r.qty_sold * r.base_units_consumed, 4),
             updated_at = now()
       WHERE id = r.beverage_item_id;
      RETURN QUERY SELECT r.pos_button, true, round(r.qty_sold * r.base_units_consumed, 4);
    END IF;
  END LOOP;
END;
$function$;
