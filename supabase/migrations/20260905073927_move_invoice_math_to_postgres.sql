
-- ============================================================================
-- Move invoice arithmetic out of the edge function and into Postgres.
--
-- Gemini already transcribes only (see ingest-invoice/prompt.js). The gap was
-- that pack-code parsing + line/invoice math ran in Deno (packCodes.js,
-- validateMath.js) before landing in Postgres. mise_parse_pack()/mise_unit()
-- already existed here but nothing called them. This wires them up as
-- triggers so ANY raw row landing in invoice_line_items - from ingestion or
-- from a later human correction - gets audited by Postgres, not by code.
-- ============================================================================

-- New columns to hold the money/unit distinction (previously computed in JS
-- and only ever collapsed into a single is_flagged boolean).
ALTER TABLE public.invoice_line_items ADD COLUMN IF NOT EXISTS money_problem boolean;
ALTER TABLE public.invoice_line_items ADD COLUMN IF NOT EXISTS unit_problem boolean;
ALTER TABLE public.invoice_line_items ADD COLUMN IF NOT EXISTS priced_per varchar;

COMMENT ON COLUMN public.invoice_line_items.money_problem IS 'qty x price does not reconcile to line_total (after trying priced-by-weight/volume/count). Computed by mise_line_item_math().';
COMMENT ON COLUMN public.invoice_line_items.unit_problem IS 'Pack size could not be parsed with confidence, or base units/cost-per-unit could not be computed. Computed by mise_line_item_math().';
COMMENT ON COLUMN public.invoice_line_items.priced_per IS 'Which unit the printed price actually keys off when it is not the purchase unit, e.g. "pound", "gallon".';

-- ----------------------------------------------------------------------------
-- mise_parse_pack: add the one real gap - explicit catch-weight markers
-- (T/WT=, ACAB, "CATCH WEIGHT") in the SIZE or UOM column. The existing
-- function already caught "#AVG"-style average-weight suffixes; it did not
-- catch these. This was flagged as a real bug source in the JS comments
-- (meat/seafood lines billed by actual weight, not by the case).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.mise_parse_pack(p_pack text, p_size text, p_uom text, p_description text)
 RETURNS TABLE(base_unit character varying, per_purchase_unit numeric, catch_weight boolean, confidence character varying, note text)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_pack numeric; v_m text[]; v_u record; v_txt text;
BEGIN
  -- Catch weight: the billed quantity IS the weighed amount (raw_quantity is
  -- already in LB per the transcription prompt), not a case count to convert.
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

-- ----------------------------------------------------------------------------
-- mise_canonical_uom: rebuild the printed form ("CS (6/.5GAL)") for storage
-- and the review table, same as JS canonicalUom().
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.mise_canonical_uom(p_pack text, p_size text, p_raw_uom text, p_uom text DEFAULT 'CS')
RETURNS text LANGUAGE sql IMMUTABLE AS $function$
  SELECT CASE
    WHEN coalesce(trim(p_pack),'') = '' AND coalesce(trim(p_size),'') = '' THEN p_raw_uom
    WHEN coalesce(trim(p_pack),'') <> '' AND coalesce(trim(p_size),'') <> ''
      THEN p_uom || ' (' || trim(p_pack) || '/' || trim(p_size) || ')'
    ELSE p_uom || ' (' || coalesce(nullif(trim(p_pack),''), trim(p_size)) || ')'
  END;
$function$;

-- ----------------------------------------------------------------------------
-- mise_line_item_math: the port of validateLineItem() from validateMath.js.
-- Runs BEFORE INSERT OR UPDATE, so every row - from Gemini or from a human
-- correction - gets the same audit, in the same place, every time.
-- ----------------------------------------------------------------------------
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

  IF NEW.raw_quantity IS NULL OR NEW.raw_unit_price IS NULL OR NEW.line_total IS NULL THEN
    v_calc := NULL; v_variance := NULL; v_money_ok := NULL; NEW.priced_per := NULL;
    IF NEW.line_total IS NOT NULL AND NEW.raw_quantity IS NULL AND NEW.raw_unit_price IS NULL THEN
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
  NEW.unit_problem := (v_pack.confidence = 'low' OR NEW.total_base_units IS NULL OR NEW.cost_per_base_unit IS NULL);
  NEW.is_flagged := NEW.money_problem OR NEW.unit_problem;
  NEW.flag_notes := v_notes;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_line_item_math ON public.invoice_line_items;
CREATE TRIGGER trg_line_item_math
BEFORE INSERT OR UPDATE ON public.invoice_line_items
FOR EACH ROW EXECUTE FUNCTION public.mise_line_item_math();

-- ----------------------------------------------------------------------------
-- mise_audit_invoice: the port of validateInvoice() from validateMath.js.
-- Pure read - safe to call from the edge function (RPC) or from a trigger.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.mise_audit_invoice(p_invoice_id uuid)
RETURNS TABLE(
  math_is_correct boolean,
  calculated_subtotal numeric,
  checked_against text,
  subtotal_variance numeric,
  money_problems text[],
  unit_problems text[],
  flag_reason text
)
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  v_subtotal numeric; v_tax numeric; v_grand numeric;
  v_calc numeric := 0;
  v_any_missing boolean := false;
  v_basis numeric; v_basis_label text;
  v_money text[] := '{}';
  v_unit text[] := '{}';
  v_short numeric;
  v_all text[];
  rec record;
BEGIN
  SELECT subtotal, coalesce(tax,0), grand_total
    INTO v_subtotal, v_tax, v_grand
    FROM public.invoices WHERE id = p_invoice_id;

  SELECT coalesce(sum(round(line_total * 100)), 0) / 100.0,
         bool_or(line_total IS NULL)
    INTO v_calc, v_any_missing
    FROM public.invoice_line_items
   WHERE invoice_id = p_invoice_id AND removed_by_review IS NOT TRUE;

  IF v_subtotal IS NOT NULL THEN
    v_basis := v_subtotal; v_basis_label := 'printed subtotal';
  ELSIF v_grand IS NOT NULL THEN
    v_basis := round(v_grand - v_tax, 2);
    v_basis_label := CASE WHEN v_tax = 0 THEN 'printed grand total' ELSE 'grand total less tax' END;
  ELSE
    v_basis := NULL; v_basis_label := NULL;
  END IF;

  IF v_basis IS NULL THEN
    v_money := array_append(v_money, 'No page carried a subtotal or a grand total, so the line items could not be checked against anything. A page may be missing.');
  ELSIF v_any_missing THEN
    v_money := array_append(v_money, 'One or more line totals are illegible; the lines cannot be checked against the invoice.');
  ELSIF abs(round(v_calc * 100) - round(v_basis * 100)) > 2 THEN
    v_short := round(v_basis * 100) - round(v_calc * 100);
    v_money := array_append(v_money, format('Lines sum to %s against a %s of %s.%s',
        round(v_calc,2), v_basis_label, round(v_basis,2),
        CASE WHEN v_short > 0 THEN ' The lines fall SHORT, which usually means a page was not sent.' ELSE '' END));
  END IF;

  IF v_subtotal IS NOT NULL AND v_grand IS NOT NULL
     AND abs(round((v_subtotal + v_tax) * 100) - round(v_grand * 100)) > 2 THEN
    v_money := array_append(v_money, format('Grand total mismatch: subtotal %s + tax %s = %s, invoice says %s.',
        round(v_subtotal,2), round(v_tax,2), round(v_subtotal + v_tax,2), round(v_grand,2)));
  END IF;

  FOR rec IN
    SELECT item_description, flag_notes, money_problem
      FROM public.invoice_line_items
     WHERE invoice_id = p_invoice_id AND removed_by_review IS NOT TRUE AND is_flagged = true
  LOOP
    IF rec.money_problem THEN
      v_money := array_append(v_money, format('[%s] %s', rec.item_description, array_to_string(rec.flag_notes, ' ')));
    ELSE
      v_unit := array_append(v_unit, format('[%s] %s', rec.item_description, array_to_string(rec.flag_notes, ' ')));
    END IF;
  END LOOP;

  v_all := array_cat(
    ARRAY(SELECT '\u2022 [MONEY] ' || x FROM unnest(v_money) x),
    ARRAY(SELECT '\u2022 [UNITS] ' || x FROM unnest(v_unit) x)
  );

  math_is_correct := (array_length(v_money,1) IS NULL);
  calculated_subtotal := v_calc;
  checked_against := v_basis_label;
  subtotal_variance := CASE WHEN v_basis IS NULL THEN NULL ELSE round(abs(v_calc - v_basis), 2) END;
  money_problems := v_money;
  unit_problems := v_unit;
  flag_reason := CASE WHEN array_length(v_all,1) IS NULL THEN NULL
    ELSE format('AUDIT (%s money, %s unit):', coalesce(array_length(v_money,1),0), coalesce(array_length(v_unit,1),0))
         || E'\n' || array_to_string(v_all, E'\n')
  END;
  RETURN NEXT;
END;
$function$;

-- ----------------------------------------------------------------------------
-- Keep invoices.flag_reason live: any line insert/update/delete re-audits its
-- parent invoice automatically. status is intentionally left untouched here -
-- ingest-invoice sets it once from this same function right after ingesting,
-- and the review API separately promotes to 'completed' once every line is
-- mapped to an ingredient. This trigger only keeps the audit TEXT honest.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.mise_invoice_reaudit()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
DECLARE
  v_invoice_id uuid := coalesce(NEW.invoice_id, OLD.invoice_id);
  v_audit record;
BEGIN
  IF v_invoice_id IS NULL THEN RETURN NULL; END IF;
  SELECT * INTO v_audit FROM public.mise_audit_invoice(v_invoice_id);
  UPDATE public.invoices SET flag_reason = v_audit.flag_reason WHERE id = v_invoice_id;
  RETURN NULL;
END;
$function$;

DROP TRIGGER IF EXISTS trg_invoice_reaudit ON public.invoice_line_items;
CREATE TRIGGER trg_invoice_reaudit
AFTER INSERT OR UPDATE OR DELETE ON public.invoice_line_items
FOR EACH ROW EXECUTE FUNCTION public.mise_invoice_reaudit();

