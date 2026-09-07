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

  IF upper(trim(coalesce(p_size,''))) = '#10' AND v_pack IS NOT NULL AND v_pack > 0 THEN
    RETURN QUERY SELECT 'FL_OZ'::varchar, round(v_pack * 128, 4), false, 'high'::varchar,
                        format('PACK %s x #10 can (128 fl oz, this kitchen''s standard).', p_pack)::text;
    RETURN;
  END IF;

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

  IF v_pack IS NOT NULL AND v_pack > 0 AND upper(trim(coalesce(p_size,''))) ~ '^[A-Z#]+$' THEN
    SELECT * INTO v_u FROM public.mise_unit(upper(trim(p_size)));
    IF FOUND THEN
      RETURN QUERY SELECT v_u.base_unit, round(v_pack * v_u.factor, 4), false, 'high'::varchar,
                          format('PACK %s x bare unit %s.', p_pack, p_size)::text;
      RETURN;
    END IF;
  END IF;

  -- Size and pack count came through in ONE field, reversed order (e.g.
  -- "750ml 12" meaning 750ML bottles, 12 to a case) instead of two separate
  -- PACK and SIZE fields. Only tried when PACK itself came back empty --
  -- if PACK has its own value, the earlier branches already handle it.
  IF v_pack IS NULL THEN
    v_m := regexp_match(upper(trim(coalesce(p_size,''))), '^\s*(\d+(\.\d+)?)\s*([A-Z]+)\s+(\d+)\s*$');
    IF v_m IS NOT NULL THEN
      SELECT * INTO v_u FROM public.mise_unit(v_m[3]);
      IF FOUND THEN
        RETURN QUERY SELECT v_u.base_unit, round(v_m[4]::numeric * v_m[1]::numeric * v_u.factor, 4),
                            false, 'high'::varchar,
                            format('SIZE %s came with the pack count attached: %s x %s.', p_size, v_m[4], v_m[1] || ' ' || v_m[3])::text;
        RETURN;
      END IF;
    END IF;
  END IF;

  v_txt := upper(coalesce(p_description,''));
  v_m := regexp_match(v_txt, '(\d+)\s*/\s*(\d+(\.\d+)?)(\s*-\s*\d+(\.\d+)?)?\s*(#|LBS?|POUNDS?|OZ|OUNCES?|GALLONS?|GAL|QUARTS?|QT|PINTS?|PT|ML|LTR|LITERS?|LITRES?|L|CT|COUNT|EA|EACH)\y');
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

  v_m := regexp_match(v_txt, '(\d+(\.\d+)?)\s*(ML|LTR|LITERS?|LITRES?|GALLONS?|GAL|QUARTS?|QT|PINTS?|PT|FL\s*OZ|OUNCES?|OZ|POUNDS?|LBS?|#|COUNT|CT|EACH|EA|L)\y');
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
