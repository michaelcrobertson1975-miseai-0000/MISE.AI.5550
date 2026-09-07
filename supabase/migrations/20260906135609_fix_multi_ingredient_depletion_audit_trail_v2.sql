DROP FUNCTION public.mise_apply_nightly_depletion(uuid);

CREATE OR REPLACE FUNCTION public.mise_apply_nightly_depletion(p_nightly_report_id uuid)
RETURNS TABLE(pos_button text, matched boolean, base_units_depleted numeric, ingredient_count integer)
LANGUAGE plpgsql
AS $function$
DECLARE
  m record;
  b record;
  v_total numeric;
  v_count integer;
  v_units numeric;
BEGIN
  FOR m IN
    SELECT npm.id, npm.pos_button, npm.qty_sold, nr.client_id
      FROM public.nightly_product_mix npm
      JOIN public.nightly_reports nr ON nr.id = npm.nightly_report_id
     WHERE npm.nightly_report_id = p_nightly_report_id
  LOOP
    v_total := 0;
    v_count := 0;

    FOR b IN
      SELECT bb.id AS bom_id, bb.beverage_item_id, bb.base_units_consumed
        FROM public.beverage_boms bb
       WHERE bb.client_id = m.client_id AND lower(bb.pos_item_name) = lower(m.pos_button)
    LOOP
      v_units := round(m.qty_sold * b.base_units_consumed, 4);

      INSERT INTO public.nightly_product_mix_depletions (nightly_product_mix_id, beverage_bom_id, beverage_item_id, base_units_depleted)
      VALUES (m.id, b.bom_id, b.beverage_item_id, v_units);

      UPDATE public.beverage_items
         SET total_base_units_in_stock = total_base_units_in_stock - v_units, updated_at = now()
       WHERE id = b.beverage_item_id;

      v_total := v_total + v_units;
      v_count := v_count + 1;
    END LOOP;

    UPDATE public.nightly_product_mix
       SET matched_bom_id = CASE WHEN v_count = 1 THEN (SELECT beverage_bom_id FROM public.nightly_product_mix_depletions WHERE nightly_product_mix_id = m.id LIMIT 1) ELSE NULL END,
           base_units_depleted = CASE WHEN v_count > 0 THEN v_total ELSE NULL END
     WHERE id = m.id;

    RETURN QUERY SELECT m.pos_button, v_count > 0, (CASE WHEN v_count > 0 THEN v_total ELSE NULL END), v_count;
  END LOOP;
END;
$function$;
