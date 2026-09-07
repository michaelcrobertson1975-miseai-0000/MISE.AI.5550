
-- ============================================================================
-- Close the two remaining gaps:
--   1. mise_parse_pack() still read the raw_uom column too literally - it
--      didn't handle multi-level slash chains ("3/6/4 LB") or the ambiguous
--      run-together case codes ("624LB" meaning 6 x 24 LB) that packCodes.js
--      used to guess at. Both only matter when a vendor packs the whole pack
--      code into one column instead of separate PACK/SIZE columns or the item
--      text - rarer, but still real money on real invoices.
--   2. api.js computed a line's default total (qty x price) in JS when a
--      reviewer typed in a brand-new line with no total given. Moved to a
--      one-line SQL function so nothing in the app does that arithmetic.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- mise_split_run_together: port of splitRunTogether() from packCodes.js.
-- Only ever tried when the literal reading of a run of digits is implausible
-- for its unit (a single case does not weigh 624 lb) - a case of otherwise
-- unreadable pack codes, not a substitute for the PACK/SIZE columns.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.mise_split_run_together(p_digits text, p_base_unit varchar, p_factor numeric, p_literal_base numeric)
RETURNS TABLE(pack_count numeric, size_value numeric, confidence varchar)
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v_dec text[];
  v_implausible numeric;
  v_pack int;
  v_prefix text;
  v_size numeric;
BEGIN
  v_implausible := CASE p_base_unit WHEN 'WT_OZ' THEN 800 WHEN 'FL_OZ' THEN 1920 WHEN 'COUNT' THEN 1000 ELSE NULL END;

  -- "6.5" LB read as 6 x 0.5 LB, not literally 6.5 lb in one case.
  v_dec := regexp_match(p_digits, '^(\d+)\.(\d+)$');
  IF v_dec IS NOT NULL THEN
    v_pack := v_dec[1]::int;
    v_size := ('0.' || v_dec[2])::numeric;
    IF v_pack = ANY(ARRAY[2,3,4,6,8,10,12,16,20,24,30,36,48]) AND v_size > 0 AND v_size < 1 THEN
      RETURN QUERY SELECT v_pack::numeric, v_size, 'medium'::varchar;
    END IF;
    RETURN;
  END IF;

  IF v_implausible IS NULL OR p_literal_base <= v_implausible THEN
    RETURN; -- the literal reading is already plausible; nothing to split
  END IF;

  FOREACH v_pack IN ARRAY ARRAY[2,3,4,6,8,10,12,16,20,24,30,36,48]
  LOOP
    v_prefix := v_pack::text;
    IF p_digits NOT LIKE v_prefix || '%' OR length(p_digits) <= length(v_prefix) THEN CONTINUE; END IF;
    v_size := substring(p_digits FROM length(v_prefix) + 1)::numeric;
    IF NOT (v_size > 0) THEN CONTINUE; END IF;
    IF v_pack * v_size * p_factor > v_implausible THEN CONTINUE; END IF;
    RETURN QUERY SELECT v_pack::numeric, v_size, 'low'::varchar;
    RETURN;
  END LOOP;
  RETURN; -- no plausible split found; caller falls back to the literal reading
END;
$function$;

-- ----------------------------------------------------------------------------
-- mise_parse_pack: branches 1-5 (catch weight, surcharge, PACK+SIZE columns,
-- pack/size read from the item description) are unchanged and already
-- verified against real invoice data. Only the "parse straight off the
-- UOM/pack-code column" tail is rewritten, to add multi-level slash chains
-- and the run-together guess.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.mise_parse_pack(p_pack text, p_size text, p_uom text, p_description text)
 RETURNS TABLE(base_unit character varying, per_purchase_unit numeric, catch_weight boolean, confidence character varying, note text)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_pack numeric; v_m text[]; v_u record; v_txt text;
  v_first_token text; v_is_case boolean; v_inner text; v_candidate text;
  v_pack_product numeric; v_parts text[]; v_idx int;
  v_literal numeric; v_literal_base numeric; v_avg boolean; v_split record;
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

  -- ---- everything below is new: parse a combined pack code straight off the
  -- UOM/pack-code column, e.g. "CS (6/2 LB)", "CS (3/6/4 LB)", "CS 624LB". ----
  v_txt := regexp_replace(upper(coalesce(p_uom,'')), '\yONLY\y', '1', 'g');
  v_first_token := (regexp_match(coalesce(p_uom,''), '^\s*([A-Za-z]+)'))[1];
  v_is_case := upper(coalesce(v_first_token,'')) = ANY(ARRAY['CS','CA','CASE','CAS','BX','BOX','CTN','CARTON','KE','KEG']);
  v_inner := (regexp_match(v_txt, '\(([^)]*)\)'))[1];
  IF v_inner IS NULL THEN v_inner := regexp_replace(v_txt, '^[A-Z]+\s*', ''); END IF;
  v_inner := trim(v_inner);
  IF v_inner = '' THEN v_inner := v_txt; END IF;

  FOREACH v_candidate IN ARRAY ARRAY[v_inner, v_txt]
  LOOP
    -- Form A: N/M/.../SIZE UNIT at any depth ("3/6/4 LB", "6/.5 GAL", "1/15#AVG").
    v_m := regexp_match(v_candidate, '^((?:\d+(?:\.\d+)?\s*/\s*)+)(\d*\.?\d+)\s*([A-Z#]+)\.?$');
    IF v_m IS NOT NULL THEN
      SELECT * INTO v_u FROM public.mise_unit(v_m[3]);
      IF FOUND THEN
        v_parts := string_to_array(trim(trailing '/' from regexp_replace(v_m[1], '\s', '', 'g')), '/');
        v_pack_product := 1;
        FOR v_idx IN 1..array_length(v_parts,1) LOOP
          v_pack_product := v_pack_product * v_parts[v_idx]::numeric;
        END LOOP;
        RETURN QUERY SELECT v_u.base_unit, round(v_pack_product * v_m[2]::numeric * v_u.factor, 4),
                            v_m[3] ~* '(AVG?|A)$', 'high'::varchar,
                            format('Parsed "%s x %s %s" from the UOM column "%s".', v_pack_product, v_m[2], v_m[3], p_uom)::text;
        RETURN;
      END IF;
    END IF;

    -- Form B: SIZE UNIT alone ("15 LB", "0.5GAL", "624LB" - possibly a run-together code).
    v_m := regexp_match(v_candidate, '^(\d*\.?\d+)\s*([A-Z#]+)\.?$');
    IF v_m IS NOT NULL THEN
      SELECT * INTO v_u FROM public.mise_unit(v_m[2]);
      IF FOUND THEN
        v_literal := v_m[1]::numeric;
        v_literal_base := v_literal * v_u.factor;
        v_avg := v_m[2] ~* '(AVG?|A)$';

        IF v_is_case THEN
          SELECT * INTO v_split FROM public.mise_split_run_together(v_m[1], v_u.base_unit, v_u.factor, v_literal_base);
          IF FOUND THEN
            RETURN QUERY SELECT v_u.base_unit, round(v_split.pack_count * v_split.size_value * v_u.factor, 4),
                        v_avg, v_split.confidence,
                        format('Ambiguous run-together case code "%s": read as %s x %s %s. Literal reading would be %s.',
                               v_candidate, v_split.pack_count, v_split.size_value, v_m[2], v_literal)::text;
            RETURN;
          END IF;
        END IF;

        RETURN QUERY SELECT v_u.base_unit, round(v_literal_base, 4), v_avg, 'high'::varchar,
                    format('Parsed "%s" from the UOM column "%s".', v_candidate, p_uom)::text;
        RETURN;
      END IF;
    END IF;
  END LOOP;

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

-- ----------------------------------------------------------------------------
-- mise_manual_line_total: the one JS arithmetic left in the app (api.js
-- defaulting a brand-new reviewer-typed line's total to qty x price when no
-- total was given). Moved here so the review API has zero arithmetic of its
-- own. Deliberately separate from mise_line_item_math - Gemini-sourced rows
-- with an illegible line_total must stay NULL and flagged, never backfilled.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.mise_manual_line_total(p_quantity numeric, p_unit_price numeric, p_provided numeric)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $function$
  SELECT coalesce(p_provided,
    CASE WHEN p_quantity IS NOT NULL AND p_unit_price IS NOT NULL THEN round(p_quantity * p_unit_price, 2) END);
$function$;

