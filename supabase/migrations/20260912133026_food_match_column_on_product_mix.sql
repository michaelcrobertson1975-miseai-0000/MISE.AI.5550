-- nightly_product_mix.matched_bom_id foreign-keys to beverage_boms, so writing
-- a food bom id into it fails. The fix is a second column rather than dropping
-- the constraint: both foreign keys stay real, and "which bom matched" is still
-- answerable for each side of the house.
--
-- This migration also carries the final depletion function -- food and beverage
-- both, with yield applied the right way round.

ALTER TABLE public.nightly_product_mix
  ADD COLUMN IF NOT EXISTS matched_menu_item_bom_id uuid
    REFERENCES public.menu_item_boms(id) ON DELETE SET NULL;

COMMENT ON COLUMN public.nightly_product_mix.matched_bom_id IS
  'The beverage BOM matched, when exactly one did. Food matches go in matched_menu_item_bom_id.';
COMMENT ON COLUMN public.nightly_product_mix.matched_menu_item_bom_id IS
  'The food BOM matched, when exactly one did. Beverage matches go in matched_bom_id.';

CREATE OR REPLACE FUNCTION public.mise_apply_nightly_depletion(p_nightly_report_id uuid)
 RETURNS TABLE(pos_button text, matched boolean, base_units_depleted numeric, ingredient_count integer, dollar_value numeric)
 LANGUAGE plpgsql
AS $function$
DECLARE
  m        record;
  b        record;
  f        record;
  v_total  numeric;
  v_count  integer;
  v_units  numeric;
  v_cost   numeric;
  v_money  numeric;
  v_bev    integer;
  v_food   integer;
BEGIN
  FOR m IN
    SELECT npm.id, npm.pos_button, npm.qty_sold, nr.client_id
      FROM public.nightly_product_mix npm
      JOIN public.nightly_reports nr ON nr.id = npm.nightly_report_id
     WHERE npm.nightly_report_id = p_nightly_report_id
  LOOP
    v_total := 0; v_count := 0; v_money := 0; v_bev := 0; v_food := 0;

    FOR b IN
      SELECT bb.id AS bom_id, bb.beverage_item_id, bb.base_units_consumed,
             bi.cost_per_base_unit
        FROM public.beverage_boms bb
        LEFT JOIN public.beverage_items bi ON bi.id = bb.beverage_item_id
       WHERE bb.client_id = m.client_id AND lower(bb.pos_item_name) = lower(m.pos_button)
    LOOP
      v_units := round(m.qty_sold * b.base_units_consumed, 4);
      v_cost  := b.cost_per_base_unit;

      INSERT INTO public.nightly_product_mix_depletions
        (nightly_product_mix_id, beverage_bom_id, beverage_item_id,
         base_units_depleted, kind, cost_per_base_unit, dollar_value)
      VALUES
        (m.id, b.bom_id, b.beverage_item_id, v_units, 'beverage', v_cost,
         CASE WHEN v_cost IS NOT NULL THEN round(v_units * v_cost, 2) END);

      UPDATE public.beverage_items
         SET total_base_units_in_stock = total_base_units_in_stock - v_units,
             updated_at = now()
       WHERE id = b.beverage_item_id;

      v_total := v_total + v_units;
      v_count := v_count + 1;
      v_bev   := v_bev + 1;
      v_money := v_money + coalesce(round(v_units * v_cost, 2), 0);
    END LOOP;

    FOR f IN
      SELECT mb.id AS bom_id, mb.ingredient_id,
             -- DIVIDE: plated portion / usable fraction = what the kitchen eats.
             round(mb.base_units_consumed / mb.yield_factor, 6) AS per_sale,
             lp.cost_per_base_unit
        FROM public.menu_item_boms mb
        LEFT JOIN public.v_ingredient_last_price lp ON lp.ingredient_id = mb.ingredient_id
       WHERE mb.client_id = m.client_id AND lower(mb.pos_item_name) = lower(m.pos_button)
    LOOP
      v_units := round(m.qty_sold * f.per_sale, 4);
      v_cost  := f.cost_per_base_unit;

      INSERT INTO public.nightly_product_mix_depletions
        (nightly_product_mix_id, menu_item_bom_id, ingredient_id,
         base_units_depleted, kind, cost_per_base_unit, dollar_value)
      VALUES
        (m.id, f.bom_id, f.ingredient_id, v_units, 'food', v_cost,
         CASE WHEN v_cost IS NOT NULL THEN round(v_units * v_cost, 2) END);

      UPDATE public.ingredients
         SET on_hand = coalesce(on_hand, 0) - v_units,
             on_hand_updated_at = now()
       WHERE id = f.ingredient_id;

      v_total := v_total + v_units;
      v_count := v_count + 1;
      v_food  := v_food + 1;
      v_money := v_money + coalesce(round(v_units * v_cost, 2), 0);
    END LOOP;

    UPDATE public.nightly_product_mix
       SET matched_bom_id = CASE WHEN v_bev = 1 AND v_food = 0
             THEN (SELECT d.beverage_bom_id FROM public.nightly_product_mix_depletions d
                    WHERE d.nightly_product_mix_id = m.id AND d.beverage_bom_id IS NOT NULL LIMIT 1)
             ELSE NULL END,
           matched_menu_item_bom_id = CASE WHEN v_food = 1 AND v_bev = 0
             THEN (SELECT d.menu_item_bom_id FROM public.nightly_product_mix_depletions d
                    WHERE d.nightly_product_mix_id = m.id AND d.menu_item_bom_id IS NOT NULL LIMIT 1)
             ELSE NULL END,
           base_units_depleted = CASE WHEN v_count > 0 THEN v_total ELSE NULL END
     WHERE id = m.id;

    RETURN QUERY SELECT m.pos_button, v_count > 0,
                        (CASE WHEN v_count > 0 THEN v_total ELSE NULL END),
                        v_count,
                        (CASE WHEN v_count > 0 THEN v_money ELSE NULL END);
  END LOOP;
END;
$function$;

COMMENT ON FUNCTION public.mise_apply_nightly_depletion(uuid) IS
  'Applies one night of product mix to inventory, food and beverage both. Matches each POS button to its BOMs, subtracts what was consumed, and records the dollar value at the cost in effect that night. An unmatched button depletes nothing and is reported as matched=false rather than guessed at.';
