-- A change and its revert, kept together on purpose so the reasoning survives.
--
-- I saw beverage_boms.yield_factor apparently unused by the depletion loop and
-- "fixed" it to divide, the way the kitchen does. It was not unused:
-- base_units_consumed is a GENERATED column, serving_size_oz * yield_factor.
-- The yield was already applied, at insert time, by the database.
--
-- Dividing by it afterwards cancelled it exactly:
--     (serving_size_oz * yield_factor) / yield_factor = serving_size_oz
-- so every drink would have consumed its full glass size of product. A 12 oz
-- fountain soda would have drawn 12 oz of syrup instead of 2. Caught by
-- running a coffee example, not by reading the code.
--
-- THE TWO SIDES MEAN DIFFERENT THINGS BY "YIELD" AND BOTH ARE RIGHT:
--
--   FOOD  yield_factor is a TRIM LOSS. Portion is what reaches the plate and
--         the kitchen must start with more: 6 oz at 0.75 consumes 8 oz.
--         Consumption = portion / yield.
--
--   BAR   yield_factor is a CONVERSION RATIO. serving_size_oz is the size of
--         the DRINK and the factor says how much stock one ounce of drink
--         draws: 12 oz soda * 0.167 = 2 oz syrup; 12 oz brewed coffee
--         * 0.0625 = 0.75 oz beans; a 1.5 oz spirit pour * 1.0 = 1.5 oz.
--         Consumption = serving * ratio, already computed by the column.
--
-- Same word, opposite arithmetic. The next person to notice the asymmetry will
-- be tempted to "fix" it exactly as I did.

ALTER TABLE public.beverage_boms
  ALTER COLUMN yield_factor SET DEFAULT 1.0;

ALTER TABLE public.beverage_boms DROP CONSTRAINT IF EXISTS beverage_boms_yield_sane;
ALTER TABLE public.beverage_boms
  ADD CONSTRAINT beverage_boms_yield_sane
  CHECK (yield_factor IS NULL OR (yield_factor > 0 AND yield_factor <= 1));

COMMENT ON COLUMN public.beverage_boms.yield_factor IS
  'CONVERSION RATIO: how much stock one ounce of finished drink draws. 1.0 for a straight pour (a 1.5 oz spirit serving consumes 1.5 oz). Below 1 where the glass is mostly not the product: fountain syrup, brewed coffee, diluted juice. base_units_consumed is GENERATED as serving_size_oz * yield_factor -- the depletion function uses that column as-is and must not divide by the factor again. This is NOT the same meaning as menu_item_boms.yield_factor, which is a trim loss and IS divided by.';

-- Final depletion function: beverage uses the generated column as-is,
-- food divides by its trim yield.
CREATE OR REPLACE FUNCTION public.mise_apply_nightly_depletion(p_nightly_report_id uuid)
 RETURNS TABLE(pos_button text, matched boolean, base_units_depleted numeric, ingredient_count integer, dollar_value numeric)
 LANGUAGE plpgsql
AS $function$
DECLARE
  m record; b record; f record;
  v_total numeric; v_count integer; v_units numeric;
  v_cost numeric; v_money numeric; v_bev integer; v_food integer;
BEGIN
  FOR m IN
    SELECT npm.id, npm.pos_button, npm.qty_sold, nr.client_id
      FROM public.nightly_product_mix npm
      JOIN public.nightly_reports nr ON nr.id = npm.nightly_report_id
     WHERE npm.nightly_report_id = p_nightly_report_id
       AND NOT EXISTS (SELECT 1 FROM public.nightly_product_mix_depletions d
                        WHERE d.nightly_product_mix_id = npm.id)
  LOOP
    v_total := 0; v_count := 0; v_money := 0; v_bev := 0; v_food := 0;

    FOR b IN
      -- base_units_consumed is GENERATED as serving_size_oz * yield_factor.
      -- Use it as-is. Do NOT divide by yield_factor again.
      SELECT bb.id AS bom_id, bb.beverage_item_id, bb.base_units_consumed AS per_sale,
             bi.cost_per_base_unit
        FROM public.beverage_boms bb
        LEFT JOIN public.beverage_items bi ON bi.id = bb.beverage_item_id
       WHERE bb.client_id = m.client_id AND lower(bb.pos_item_name) = lower(m.pos_button)
    LOOP
      v_units := round(m.qty_sold * b.per_sale, 4);
      v_cost  := b.cost_per_base_unit;
      INSERT INTO public.nightly_product_mix_depletions
        (nightly_product_mix_id, beverage_bom_id, beverage_item_id,
         base_units_depleted, kind, cost_per_base_unit, dollar_value)
      VALUES (m.id, b.bom_id, b.beverage_item_id, v_units, 'beverage', v_cost,
              CASE WHEN v_cost IS NOT NULL THEN round(v_units * v_cost, 2) END);
      UPDATE public.beverage_items
         SET total_base_units_in_stock = total_base_units_in_stock - v_units, updated_at = now()
       WHERE id = b.beverage_item_id;
      v_total := v_total + v_units; v_count := v_count + 1; v_bev := v_bev + 1;
      v_money := v_money + coalesce(round(v_units * v_cost, 2), 0);
    END LOOP;

    FOR f IN
      -- Food is the other convention: portion / usable fraction.
      SELECT mb.id AS bom_id, mb.ingredient_id,
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
      VALUES (m.id, f.bom_id, f.ingredient_id, v_units, 'food', v_cost,
              CASE WHEN v_cost IS NOT NULL THEN round(v_units * v_cost, 2) END);
      UPDATE public.ingredients
         SET on_hand = coalesce(on_hand, 0) - v_units, on_hand_updated_at = now()
       WHERE id = f.ingredient_id;
      v_total := v_total + v_units; v_count := v_count + 1; v_food := v_food + 1;
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
