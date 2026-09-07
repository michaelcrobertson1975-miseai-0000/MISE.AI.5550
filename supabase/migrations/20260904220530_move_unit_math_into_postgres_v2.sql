-- Gemini reads. Edge writes the clean data. POSTGRES does the math.
--
-- Until now the arithmetic ran once inside the edge function and froze into the
-- row. A reviewer fixing a quantity left cost_per_base_unit stale, and improving
-- the parser left every older row on the old answer. Computed here, a row
-- recalculates itself whenever anything it depends on changes.

CREATE TABLE IF NOT EXISTS public.units (
  token     varchar PRIMARY KEY,
  base_unit varchar NOT NULL CHECK (base_unit IN ('WT_OZ','FL_OZ','COUNT','EACH')),
  factor    numeric NOT NULL,
  note      text
);

COMMENT ON TABLE public.units IS
  'Unit token -> base unit and conversion factor. A new distributor abbreviation is an INSERT, never a deploy.';

INSERT INTO public.units (token, base_unit, factor) VALUES
  ('GAL','FL_OZ',128), ('GALLON','FL_OZ',128), ('GA','FL_OZ',128),
  ('QT','FL_OZ',32), ('QUART','FL_OZ',32), ('PT','FL_OZ',16), ('PINT','FL_OZ',16),
  ('L','FL_OZ',33.814), ('LTR','FL_OZ',33.814), ('LITER','FL_OZ',33.814), ('LITRE','FL_OZ',33.814),
  ('ML','FL_OZ',0.033814), ('FLOZ','FL_OZ',1), ('FZ','FL_OZ',1),
  ('LB','WT_OZ',16), ('LBS','WT_OZ',16), ('POUND','WT_OZ',16), ('#','WT_OZ',16),
  ('OZ','WT_OZ',1), ('OUNCE','WT_OZ',1),
  ('KG','WT_OZ',35.274), ('G','WT_OZ',0.035274), ('GR','WT_OZ',0.035274),
  ('CT','COUNT',1), ('CNT','COUNT',1), ('COUNT','COUNT',1),
  ('PC','COUNT',1), ('PCS','COUNT',1), ('PK','COUNT',1), ('BG','COUNT',1),
  ('EA','COUNT',1), ('EACH','COUNT',1), ('DZ','COUNT',12), ('DOZ','COUNT',12)
ON CONFLICT (token) DO NOTHING;

INSERT INTO public.units (token, base_unit, factor, note) VALUES
  ('KE','FL_OZ',659.373,'Keg. Overridden whenever the description prints a real volume, e.g. 19.5 L.'),
  ('KEG','FL_OZ',659.373,'Half-barrel equivalent; most kegs here are 19.5 L and read from the description.')
ON CONFLICT (token) DO NOTHING;

/** Normalize a unit token: strip punctuation, drop an AVG/AV/A suffix. */
CREATE OR REPLACE FUNCTION public.mise_unit(p_token text)
RETURNS TABLE (base_unit varchar, factor numeric)
LANGUAGE sql STABLE AS $$
  SELECT u.base_unit, u.factor
    FROM public.units u
   WHERE u.token = regexp_replace(
           regexp_replace(upper(coalesce(p_token,'')), '[^A-Z#]', '', 'g'),
           '^(#|LB|LBS|OZ|GAL|QT|PT|ML|L|CT|EA)(AVG|AV|A)$', '\1')
   LIMIT 1;
$$;

/**
 * How many base units one purchase unit contains.
 * Order, cheapest evidence first:
 *   1. a surcharge or deposit is never inventory  -> 1 EACH
 *   2. the PACK and SIZE columns, ONLY meaning 1
 *   3. the size printed in the item text          "750 ML", "1/10 LB CS"
 *   4. a flattened code in the UOM column         "CS (6/.5GAL)"
 */
CREATE OR REPLACE FUNCTION public.mise_parse_pack(
  p_pack text, p_size text, p_uom text, p_description text
) RETURNS TABLE (
  base_unit varchar, per_purchase_unit numeric,
  catch_weight boolean, confidence varchar, note text
) LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_pack numeric; v_m text[]; v_u record; v_txt text;
BEGIN
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
$$;

COMMENT ON FUNCTION public.mise_parse_pack IS
  'Every rule here came from a real string that failed: ONLY as a pack count, 15#AVG, 750 ML in the description, 1/10 LB CS.';
