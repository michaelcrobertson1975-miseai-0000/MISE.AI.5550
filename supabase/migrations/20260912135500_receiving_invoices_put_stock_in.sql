-- RECEIVING. Buying something now puts it on the shelf.
--
-- Depletion took stock out when a plate or a drink sold. Nothing ever put any
-- in. An invoice recorded what a thing COST and stopped there, so on_hand only
-- ever fell -- straight through zero and into negative numbers, forever. Every
-- inventory figure in the system was going to be wrong in the same direction.
--
-- WHERE STOCK LANDS: exactly one place per ingredient, never both.
-- beverage_items.ingredient_id links a bottle/keg/bean record to the invoice
-- ingredient it is bought as. When that link exists the beverage item IS the
-- stock record and receives the units; otherwise ingredients.on_hand does.
-- Adding to both would double the inventory of every drink in the building.
--
-- CORRECTIONS ARE THE HARD PART, not the first receipt. A line gets fixed
-- later -- the Feta case, pack read as 25 instead of 2/5 -- and its
-- total_base_units changes. So receiving is recorded per line in
-- inventory_receipts, and a re-run adjusts by the DIFFERENCE rather than
-- adding again.

CREATE TABLE IF NOT EXISTS public.inventory_receipts (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id             uuid NOT NULL REFERENCES public.clients(id) ON DELETE CASCADE,
  invoice_line_item_id  uuid NOT NULL UNIQUE
                          REFERENCES public.invoice_line_items(id) ON DELETE CASCADE,
  ingredient_id         uuid REFERENCES public.ingredients(id) ON DELETE SET NULL,
  beverage_item_id      uuid REFERENCES public.beverage_items(id) ON DELETE SET NULL,
  base_units_received   numeric NOT NULL,
  cost_per_base_unit    numeric,
  dollar_value          numeric,
  received_at           timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.inventory_receipts IS
  'One row per invoice line that put stock on the shelf. The UNIQUE on invoice_line_item_id is what makes receiving idempotent: a re-run adjusts by the difference instead of adding a second time.';

ALTER TABLE public.inventory_receipts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.inventory_receipts FROM anon, authenticated;
GRANT ALL ON public.inventory_receipts TO service_role;

CREATE OR REPLACE FUNCTION public.mise_receive_invoice_line()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_client   uuid;
  v_bev      uuid;
  v_units    numeric;
  v_cost     numeric;
  v_prev     numeric := 0;
  v_delta    numeric;
  v_existing uuid;
BEGIN
  SELECT client_id INTO v_client FROM public.invoices WHERE id = NEW.invoice_id;
  IF v_client IS NULL THEN RETURN NULL; END IF;

  -- A line removed by a reviewer never really arrived: take back whatever it
  -- previously put on the shelf.
  IF coalesce(NEW.removed_by_review, false) THEN
    v_units := 0;
  ELSE
    v_units := coalesce(NEW.total_base_units, 0);
  END IF;

  -- Unlinked lines are not stock yet. Fees, freight and anything the reviewer
  -- has not matched to an ingredient receive nothing.
  IF NEW.ingredient_id IS NULL THEN RETURN NULL; END IF;

  v_cost := NEW.cost_per_base_unit;

  SELECT id INTO v_bev FROM public.beverage_items
   WHERE ingredient_id = NEW.ingredient_id LIMIT 1;

  SELECT id, base_units_received INTO v_existing, v_prev
    FROM public.inventory_receipts WHERE invoice_line_item_id = NEW.id;

  v_delta := v_units - coalesce(v_prev, 0);
  IF v_delta = 0 AND v_existing IS NOT NULL THEN RETURN NULL; END IF;

  IF v_bev IS NOT NULL THEN
    UPDATE public.beverage_items
       SET total_base_units_in_stock = coalesce(total_base_units_in_stock, 0) + v_delta,
           updated_at = now()
     WHERE id = v_bev;
  ELSE
    UPDATE public.ingredients
       SET on_hand = coalesce(on_hand, 0) + v_delta,
           on_hand_updated_at = now()
     WHERE id = NEW.ingredient_id;
  END IF;

  IF v_existing IS NULL THEN
    INSERT INTO public.inventory_receipts
      (client_id, invoice_line_item_id, ingredient_id, beverage_item_id,
       base_units_received, cost_per_base_unit, dollar_value)
    VALUES
      (v_client, NEW.id, NEW.ingredient_id, v_bev, v_units, v_cost,
       CASE WHEN v_cost IS NOT NULL THEN round(v_units * v_cost, 2) END);
  ELSE
    UPDATE public.inventory_receipts
       SET base_units_received = v_units,
           beverage_item_id    = v_bev,
           cost_per_base_unit  = v_cost,
           dollar_value        = CASE WHEN v_cost IS NOT NULL THEN round(v_units * v_cost, 2) END,
           updated_at          = now()
     WHERE id = v_existing;
  END IF;

  RETURN NULL;
END;
$function$;

COMMENT ON FUNCTION public.mise_receive_invoice_line() IS
  'Puts an invoice line on the shelf. Idempotent by invoice_line_item_id: a correction adjusts stock by the difference rather than receiving twice. Beverage items receive in place of their linked ingredient so nothing is counted in both.';

-- FIRES ON ANY UPDATE, DELIBERATELY.
--
-- The first version was declared UPDATE OF total_base_units, ... which looks
-- right and is not: in Postgres that column list matches the columns NAMED IN
-- THE SET CLAUSE, not the columns whose values actually changed. Every real
-- correction goes through the raw fields -- a reviewer fixes raw_size from
-- "40 LB" to "4 LB" and the BEFORE trigger recomputes total_base_units from
-- it. total_base_units is never named in the SET clause, so receiving never
-- fired and the shelf kept stock the correction had just disproved.
--
-- The function computes the difference against what the line previously
-- received and exits when it is zero, so the extra invocations are cheap.
DROP TRIGGER IF EXISTS trg_z_receive_invoice_line ON public.invoice_line_items;
CREATE TRIGGER trg_z_receive_invoice_line
  AFTER INSERT OR UPDATE ON public.invoice_line_items
  FOR EACH ROW EXECUTE FUNCTION public.mise_receive_invoice_line();
