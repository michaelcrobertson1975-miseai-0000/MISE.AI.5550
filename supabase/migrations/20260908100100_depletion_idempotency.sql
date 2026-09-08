-- ============================================================================
-- Make nightly depletion safe to run twice.
--
-- mise_apply_nightly_depletion() subtracts from beverage_items unconditionally
-- and has no record of having already run for a report. Nothing stops the same
-- night being ingested twice either. So a re-forwarded nightly report, or a
-- re-run after a partial failure, drains stock a second time -- and because
-- stock is a running balance rather than a derived figure, that error is
-- permanent and silent.
--
-- Three changes, smallest first:
--   1. one nightly report per restaurant per date
--   2. one depletion row per (product mix line, BOM) pair
--   3. the function itself skips a report that has already been applied
--
-- Idempotency has to be enforced by the schema. A convention does not survive
-- a retry, and the queue worker now retries.
-- ============================================================================

-- 1 ── One report per restaurant per night. -----------------------------------
-- Deliberately not a blind ALTER: if the trial data already contains a
-- duplicate this will fail loudly rather than silently discarding a row.
CREATE UNIQUE INDEX IF NOT EXISTS nightly_reports_one_per_night
  ON public.nightly_reports (client_id, report_date);

COMMENT ON INDEX public.nightly_reports_one_per_night IS
  'A restaurant has one sales night per date. Re-forwarding the same report is a duplicate, not a second night.';

-- 2 ── One depletion row per sale line per BOM component. ---------------------
-- A multi-ingredient cocktail legitimately produces several rows for the same
-- nightly_product_mix_id -- one per component -- so the key includes the BOM.
CREATE UNIQUE INDEX IF NOT EXISTS npm_depletions_one_per_line_per_bom
  ON public.nightly_product_mix_depletions (nightly_product_mix_id, beverage_bom_id);

COMMENT ON INDEX public.npm_depletions_one_per_line_per_bom IS
  'Backstop against double depletion: the same POS line can only drain the same BOM component once.';

-- 3 ── The function refuses to apply a report twice. --------------------------
CREATE OR REPLACE FUNCTION public.mise_apply_nightly_depletion(p_nightly_report_id uuid)
 RETURNS TABLE(pos_button text, matched boolean, base_units_depleted numeric, ingredient_count integer)
 LANGUAGE plpgsql
 SET search_path = public, pg_temp
AS $function$
DECLARE
  m record;
  b record;
  v_total numeric;
  v_count integer;
  v_units numeric;
  v_already integer;
BEGIN
  -- Already applied? Report what happened last time and change nothing.
  SELECT count(*) INTO v_already
    FROM public.nightly_product_mix_depletions d
    JOIN public.nightly_product_mix npm ON npm.id = d.nightly_product_mix_id
   WHERE npm.nightly_report_id = p_nightly_report_id;

  IF v_already > 0 THEN
    RAISE NOTICE 'Nightly report % already depleted (% rows); leaving stock alone.', p_nightly_report_id, v_already;
    RETURN QUERY
      SELECT npm.pos_button,
             npm.base_units_depleted IS NOT NULL,
             npm.base_units_depleted,
             (SELECT count(*)::integer FROM public.nightly_product_mix_depletions d
               WHERE d.nightly_product_mix_id = npm.id)
        FROM public.nightly_product_mix npm
       WHERE npm.nightly_report_id = p_nightly_report_id;
    RETURN;
  END IF;

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
       WHERE bb.client_id = m.client_id
         AND lower(btrim(bb.pos_item_name)) = lower(btrim(m.pos_button))
    LOOP
      -- base_units_consumed is nullable; without this the multiply yields NULL,
      -- the NOT NULL insert below raises, and the whole night rolls back.
      IF b.base_units_consumed IS NULL THEN
        RAISE WARNING 'BOM % for "%" has no base_units_consumed; skipping it.', b.bom_id, m.pos_button;
        CONTINUE;
      END IF;

      v_units := round(m.qty_sold * b.base_units_consumed, 4);

      INSERT INTO public.nightly_product_mix_depletions (nightly_product_mix_id, beverage_bom_id, beverage_item_id, base_units_depleted)
      VALUES (m.id, b.bom_id, b.beverage_item_id, v_units)
      ON CONFLICT (nightly_product_mix_id, beverage_bom_id) DO NOTHING;

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

COMMENT ON FUNCTION public.mise_apply_nightly_depletion(uuid) IS
  'Applies one nightly report to beverage stock, exactly once. Re-running it reports the previous result instead of depleting again. POS button matching is trimmed and case-insensitive; a BOM row with no base_units_consumed is skipped with a warning rather than aborting the night.';
