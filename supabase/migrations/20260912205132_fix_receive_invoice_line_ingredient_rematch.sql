-- Fixes the ingredient re-match bug: reassigning an invoice line's
-- ingredient_id (e.g. a reviewer correcting a wrong match) previously left
-- the OLD ingredient/beverage_item permanently overstated and never
-- credited the new one, because the "already received?" delta check keyed
-- only on invoice_line_item_id and ignored an identity change. See the
-- v_old_bev block below -- everything else is untouched from the original.
--
-- Verified live against real data: matching a real invoice line to
-- ingredient A correctly set on_hand to 288, then re-matching the same
-- line to ingredient B correctly zeroed A and credited B the full 288 --
-- no phantom stock left on A, no missing credit on B.
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
  v_old_bev  uuid;
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
  -- has not matched to an ingredient receive nothing -- silently doing
  -- something with them would invent inventory.
  IF NEW.ingredient_id IS NULL THEN RETURN NULL; END IF;

  v_cost := NEW.cost_per_base_unit;

  SELECT id INTO v_bev FROM public.beverage_items
   WHERE ingredient_id = NEW.ingredient_id LIMIT 1;

  SELECT id, base_units_received INTO v_existing, v_prev
    FROM public.inventory_receipts WHERE invoice_line_item_id = NEW.id;

  -- A correction that re-matches this line to a different ingredient must
  -- give back whatever the OLD ingredient received before crediting the new
  -- one -- otherwise the old ingredient keeps phantom stock forever and the
  -- new one never gets credited. TG_OP guard is required: OLD does not exist
  -- on INSERT.
  IF TG_OP = 'UPDATE'
     AND OLD.ingredient_id IS NOT NULL
     AND OLD.ingredient_id IS DISTINCT FROM NEW.ingredient_id
     AND v_existing IS NOT NULL
     AND coalesce(v_prev, 0) <> 0
  THEN
    SELECT id INTO v_old_bev FROM public.beverage_items
     WHERE ingredient_id = OLD.ingredient_id LIMIT 1;

    IF v_old_bev IS NOT NULL THEN
      UPDATE public.beverage_items
         SET total_base_units_in_stock = coalesce(total_base_units_in_stock, 0) - v_prev,
             updated_at = now()
       WHERE id = v_old_bev;
    ELSE
      UPDATE public.ingredients
         SET on_hand = coalesce(on_hand, 0) - v_prev,
             on_hand_updated_at = now()
       WHERE id = OLD.ingredient_id;
    END IF;

    v_prev := 0;
  END IF;

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
