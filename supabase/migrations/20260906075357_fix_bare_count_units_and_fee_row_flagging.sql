-- Fix 1: recognize a pack number paired with a bare, already-known unit
-- (e.g. PACK 150, SIZE "CT") as high confidence, not just numbers stuck
-- together in one field like ".5GAL".
CREATE OR REPLACE FUNCTION public.mise_parse_pack(p_pack text, p_size text, p_uom text, p_description text)
 RETURNS TABLE(base_unit character varying, per_purchase_unit numeric, catch_weight boolean, confidence character varying, note text)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_pack numeric; v_m text[]; v_u record; v_txt text;
BEGIN
  IF (coalesce(p_size,'') || ' ' || coalesce(p_uom,'')) ~* 'ACAB|CATCH\s*W(EIGH)?T|T\s*/\s*WT' THEN
    RETURN QUERY SELECT 'WT_OZ'::varchar, 16::numeric, true, 'high'::varchar,
      'Catch-weight item: the billed quantity is the weighed amount, not the case count.'::text;
    RETURN;
  END IF;

  IF coalesce(p_description,'') ~* '\y(FUEL|DELIVERY|SURCHARGE|SPLIT\s*CASE|FREIGHT|MIN(IMUM)?\s*ORDER|PICKUP|CREDIT|DEPOSIT)\y'
     OR coalesce(p_uom,'') ~* '\y(FUEL|SURCHARGE|DEPOSIT)\y' THEN
    RETURN QUERY SELECT 'EACH'::varchar, 1::numeric, false, 'high'::varchar, 'Non-inventory charge; one EACH.'::text;
    RETURN;
  END IF;

  v_pack := CASE WHEN upper(trim(coalesce(p_pack,''))) IN ('ONLY','EA','EACH') THEN 1
                 WHEN trim(coalesce(p_pack,'')) ~ '^\d+(\.\d+)?$' THEN trim(p_pack)::numeric END;

  v_m := regexp_match(upper(coalesce(p_size,'')), '^\s*(\d*\.?\d+)\s*([A-Z#]+)\.?\s*$');
  IF v_pack IS NOT NULL AND v_pack > 0 AND v_m IS NOT NULL THEN
    SELECT * INTO v_u FROM public.mise_unit(v_m[2]);
    IF FOUND THEN
      RETURN QUERY SELECT v_u.base_unit, round(v_pack * v_m[1]::numeric * v_u.factor, 4),
                          coalesce(p_size,'') ~* '(#|LB|LBS)\s*(AVG?|A)\y', 'high'::varchar,
                          format('PACK %s x SIZE %s.', p_pack, p_size)::text;
      RETURN;
    END IF;
  END IF;

  -- NEW: pack number came with a bare unit in a separate field (no digit
  -- attached to it, like "CT" or "EA" on its own) but the unit is fully
  -- known, so there is nothing actually ambiguous here.
  IF v_pack IS NOT NULL AND v_pack > 0 AND upper(trim(coalesce(p_size,''))) ~ '^[A-Z#]+$' THEN
    SELECT * INTO v_u FROM public.mise_unit(upper(trim(p_size)));
    IF FOUND THEN
      RETURN QUERY SELECT v_u.base_unit, round(v_pack * v_u.factor, 4), false, 'high'::varchar,
                          format('PACK %s x bare unit %s.', p_pack, p_size)::text;
      RETURN;
    END IF;
  END IF;

  v_txt := upper(coalesce(p_description,''));
  v_m := regexp_match(v_txt, '(\d+)\s*/\s*(\d+(\.\d+)?)(\s*-\s*\d+(\.\d+)?)?\s*(#|LBS?|OZ|GAL|QT|PT|ML|LTR|L|CT|EA)\y');
  IF v_m IS NOT NULL THEN
    SELECT * INTO v_u FROM public.mise_unit(v_m[6]);
    IF FOUND THEN
      RETURN QUERY SELECT v_u.base_unit, round(v_m[1]::numeric * v_m[2]::numeric * v_u.factor, 4),
                          v_m[4] IS NOT NULL,
                          CASE WHEN v_m[4] IS NOT NULL THEN 'medium' ELSE 'high' END::varchar,
                          format('Read "%s x %s %s" from the item text; this vendor prints no size column.',
                                 v_m[1], v_m[2], v_m[6])::text;
      RETURN;
    END IF;
  END IF;

  v_m := regexp_match(v_txt, '(\d+(\.\d+)?)\s*(ML|LTR|LITER|LITRE|GAL|QT|PT|FL\s*OZ|OZ|LBS?|#|CT|L)\y');
  IF v_m IS NOT NULL THEN
    SELECT * INTO v_u FROM public.mise_unit(v_m[3]);
    IF FOUND THEN
      RETURN QUERY SELECT v_u.base_unit, round(coalesce(v_pack,1) * v_m[1]::numeric * v_u.factor, 4),
                          false, 'high'::varchar,
                          format('Read "%s %s" from the item text; pack %s.', v_m[1], v_m[3], coalesce(v_pack::text,'1'))::text;
      RETURN;
    END IF;
  END IF;

  v_txt := regexp_replace(upper(coalesce(p_uom,'')), '\yONLY\y', '1', 'g');
  v_m := regexp_match(v_txt, '(\d+(\.\d+)?)\s*/\s*(\d*\.?\d+)\s*([A-Z#]+)');
  IF v_m IS NOT NULL THEN
    SELECT * INTO v_u FROM public.mise_unit(v_m[4]);
    IF FOUND THEN
      RETURN QUERY SELECT v_u.base_unit, round(v_m[1]::numeric * v_m[3]::numeric * v_u.factor, 4),
                          v_m[4] ~* '(AVG?|A)$', 'high'::varchar,
                          format('Parsed from the UOM column "%s".', p_uom)::text;
      RETURN;
    END IF;
  END IF;

  v_m := regexp_match(v_txt, '(\d*\.?\d+)\s*([A-Z#]+)');
  IF v_m IS NOT NULL THEN
    SELECT * INTO v_u FROM public.mise_unit(v_m[2]);
    IF FOUND THEN
      RETURN QUERY SELECT v_u.base_unit, round(v_m[1]::numeric * v_u.factor, 4),
                          v_m[2] ~* '(AVG?|A)$', 'high'::varchar,
                          format('Parsed from the UOM column "%s".', p_uom)::text;
      RETURN;
    END IF;
  END IF;

  SELECT * INTO v_u FROM public.mise_unit(coalesce(p_uom,''));
  IF FOUND THEN
    RETURN QUERY SELECT v_u.base_unit, v_u.factor, false, 'medium'::varchar,
                        format('Bare unit "%s" with no pack size.', p_uom)::text;
    RETURN;
  END IF;

  RETURN QUERY SELECT 'EACH'::varchar, NULL::numeric, false, 'low'::varchar,
                      format('Could not read a pack size from PACK %s, SIZE %s, UOM %s or the item text.',
                             coalesce(p_pack,'-'), coalesce(p_size,'-'), coalesce(p_uom,'-'))::text;
END;
$function$;

-- Fix 2: don't flag a genuinely-identified charge/fee row just because it
-- has no quantity to compute base units from -- that's normal for a fee,
-- not a sign of anything unclear.
CREATE OR REPLACE FUNCTION public.mise_line_item_math()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
DECLARE
  v_pack record;
  v_calc numeric;
  v_variance numeric;
  v_money_ok boolean;
  v_notes text[] := '{}';
  v_amount numeric;
  v_total numeric;
  cand record;
  v_is_charge_row boolean;
BEGIN
  SELECT * INTO v_pack FROM public.mise_parse_pack(NEW.raw_pack, NEW.raw_size, NEW.raw_uom, NEW.item_description);

  NEW.standardized_base_unit := v_pack.base_unit;
  NEW.catch_weight := coalesce(v_pack.catch_weight, false);
  NEW.pack_confidence := v_pack.confidence;
  NEW.raw_uom := public.mise_canonical_uom(NEW.raw_pack, NEW.raw_size, NEW.raw_uom);

  IF NEW.raw_quantity IS NOT NULL AND v_pack.per_purchase_unit IS NOT NULL THEN
    NEW.total_base_units := round(NEW.raw_quantity * v_pack.per_purchase_unit, 3);
  ELSE
    NEW.total_base_units := NULL;
  END IF;

  IF v_pack.confidence = 'low' THEN
    v_notes := array_append(v_notes, 'Pack code parsed with low confidence; confirm the case configuration.');
  END IF;

  v_is_charge_row := (NEW.raw_quantity IS NULL AND NEW.raw_unit_price IS NULL AND NEW.line_total IS NOT NULL);

  IF NEW.raw_quantity IS NULL OR NEW.raw_unit_price IS NULL OR NEW.line_total IS NULL THEN
    v_calc := NULL; v_variance := NULL; v_money_ok := NULL; NEW.priced_per := NULL;
    IF v_is_charge_row THEN
      v_notes := array_append(v_notes, 'Charge row: only a total is printed, so there is no line arithmetic to check.');
    ELSE
      v_notes := array_append(v_notes, 'Missing raw_quantity, raw_unit_price or line_total (illegible on the invoice).');
    END IF;
  ELSE
    v_calc := round(NEW.raw_quantity * NEW.raw_unit_price, 2);
    v_variance := round(abs(v_calc - NEW.line_total), 2);
    v_money_ok := abs(round(v_calc * 100) - round(NEW.line_total * 100)) <= 2;
    NEW.priced_per := CASE WHEN v_money_ok THEN 'purchase unit' ELSE NULL END;

    IF NOT v_money_ok AND NEW.total_base_units IS NOT NULL AND NEW.total_base_units > 0 THEN
      FOR cand IN
        SELECT * FROM (VALUES
          ('WT_OZ','pound',16::numeric), ('WT_OZ','ounce',1::numeric),
          ('FL_OZ','gallon',128::numeric), ('FL_OZ','litre',33.814::numeric),
          ('COUNT','each',1::numeric), ('COUNT','dozen',12::numeric)
        ) AS t(base_unit, label, divisor)
        WHERE t.base_unit = NEW.standardized_base_unit
      LOOP
        v_amount := NEW.total_base_units / cand.divisor;
        v_total := round(v_amount * NEW.raw_unit_price, 2);
        IF abs(round(v_total * 100) - round(NEW.line_total * 100)) <= 2 THEN
          v_money_ok := true;
          NEW.priced_per := cand.label;
          v_calc := v_total;
          v_variance := round(abs(v_total - NEW.line_total), 2);
          v_notes := array_append(v_notes, format('Priced per %s: %s x %s = %s, which matches the printed total.',
                     cand.label, round(v_amount,3), NEW.raw_unit_price, v_total));
          EXIT;
        END IF;
      END LOOP;
    END IF;

    IF NOT v_money_ok THEN
      v_notes := array_append(v_notes, format('Line math mismatch: %s x %s = %s, invoice says %s.',
                 NEW.raw_quantity, NEW.raw_unit_price, round(NEW.raw_quantity * NEW.raw_unit_price, 2), NEW.line_total));
    END IF;
  END IF;

  NEW.calculated_line_total := v_calc;
  NEW.variance := v_variance;
  NEW.cost_per_base_unit := CASE
    WHEN NEW.line_total IS NOT NULL AND NEW.total_base_units IS NOT NULL AND NEW.total_base_units > 0
    THEN round(NEW.line_total / NEW.total_base_units, 4) ELSE NULL END;

  NEW.money_problem := (v_money_ok IS FALSE);
  NEW.unit_problem := (NOT v_is_charge_row) AND (v_pack.confidence = 'low' OR NEW.total_base_units IS NULL OR NEW.cost_per_base_unit IS NULL);
  NEW.is_flagged := NEW.money_problem OR NEW.unit_problem;
  NEW.flag_notes := v_notes;

  RETURN NEW;
END;
$function$;
