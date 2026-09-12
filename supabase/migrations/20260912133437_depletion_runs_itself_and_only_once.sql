-- Depletion had to be asked for. ingest-nightly-report called it after an
-- emailed report landed, but product mix arriving any other way -- a CSV, a
-- manual insert, an operator loading a month of history during onboarding --
-- depleted nothing. The inventory silently stopped tracking.
--
-- Making it automatic is the easy half. The half that matters is making it
-- SAFE to run twice, because ingest-nightly-report still calls it explicitly:
-- with a naive trigger, every emailed nightly report would deplete once from
-- the trigger and once from the edge function, and stock would fall at double
-- rate with nothing in the logs to explain it.
--
-- So the function now skips any product mix row that already has depletion
-- rows. Running it again is a no-op rather than a second subtraction. That
-- also makes it safe to re-run by hand after fixing a BOM, which is the normal
-- way this gets used.

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
       -- ALREADY DONE = LEAVE ALONE. This is what makes a second run harmless.
       AND NOT EXISTS (
         SELECT 1 FROM public.nightly_product_mix_depletions d
          WHERE d.nightly_product_mix_id = npm.id
       )
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

      v_total := v_total + v_units; v_count := v_count + 1; v_bev := v_bev + 1;
      v_money := v_money + coalesce(round(v_units * v_cost, 2), 0);
    END LOOP;

    FOR f IN
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
      VALUES
        (m.id, f.bom_id, f.ingredient_id, v_units, 'food', v_cost,
         CASE WHEN v_cost IS NOT NULL THEN round(v_units * v_cost, 2) END);

      UPDATE public.ingredients
         SET on_hand = coalesce(on_hand, 0) - v_units,
             on_hand_updated_at = now()
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

COMMENT ON FUNCTION public.mise_apply_nightly_depletion(uuid) IS
  'Applies one night of product mix to inventory, food and beverage both. IDEMPOTENT: a product mix row that already has depletion rows is skipped, so calling this twice never subtracts twice. Records the dollar value at the cost in effect that night. An unmatched button depletes nothing and is reported as matched=false rather than guessed at.';

-- ── it runs itself now ──────────────────────────────────────────────────────
-- Statement-level, not row-level: a product mix arrives as many rows in one
-- insert, and depletion works per report. A row-level trigger would call it
-- once per line of the mix.
CREATE OR REPLACE FUNCTION public.mise_deplete_on_mix_insert()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
  r record;
BEGIN
  FOR r IN SELECT DISTINCT nightly_report_id FROM newrows WHERE nightly_report_id IS NOT NULL
  LOOP
    PERFORM public.mise_apply_nightly_depletion(r.nightly_report_id);
  END LOOP;
  RETURN NULL;
END;
$function$;

DROP TRIGGER IF EXISTS trg_deplete_on_mix_insert ON public.nightly_product_mix;
CREATE TRIGGER trg_deplete_on_mix_insert
  AFTER INSERT ON public.nightly_product_mix
  REFERENCING NEW TABLE AS newrows
  FOR EACH STATEMENT EXECUTE FUNCTION public.mise_deplete_on_mix_insert();
