-- M2 + M3. Two defects that make an owner correction fail to survive the
-- transaction that saves it.
--
-- M2: mise_canonical_uom() rewrites raw_uom from raw_pack/raw_size on every
--     INSERT *and every UPDATE*, with 'CS' hardcoded. Verified:
--        mise_canonical_uom('25','LB','EA') -> 'CS (25/LB)'
--     An owner who types EA gets CS (25/LB) back. uom_locked marks a line whose
--     unit a human set; the math trigger then leaves raw_uom alone.
--
-- M3: the ops queue writes pnl_category, the chef app writes chef_category.
--     Same human decision, two columns. chef_category becomes the single
--     authority (the defaults trigger already treats it as senior) and
--     category_source records whether a human or the regex set it, so a machine
--     guess can never overwrite a human decision on a later re-run.

ALTER TABLE public.invoice_line_items
  ADD COLUMN IF NOT EXISTS uom_locked      boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS category_source varchar;

COMMENT ON COLUMN public.invoice_line_items.uom_locked IS
  'True when a human set raw_uom. mise_line_item_math will not canonicalise over it.';
COMMENT ON COLUMN public.invoice_line_items.category_source IS
  'human | machine | null. Who set chef_category/pnl_category. A machine pass never overwrites human.';

ALTER TABLE public.invoice_line_items
  DROP CONSTRAINT IF EXISTS invoice_line_items_category_source_check;
ALTER TABLE public.invoice_line_items
  ADD CONSTRAINT invoice_line_items_category_source_check
  CHECK (category_source IS NULL OR category_source IN ('human','machine'));

-- ── M3: defaults trigger ────────────────────────────────────────────────────
-- Unchanged behaviour except: a human-sourced category is never re-derived or
-- overwritten by the regex, and machine passes stamp category_source='machine'.
CREATE OR REPLACE FUNCTION public.mise_line_item_defaults()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF NEW.vendor_item_code IS NULL THEN
    NEW.vendor_item_code := mise_item_code(NEW.item_description);
  END IF;

  -- A human's decision is final. Never re-derive over it.
  IF NEW.category_source = 'human' THEN
    IF NEW.chef_category IS NOT NULL AND lower(NEW.chef_category) <> 'uncategorized' THEN
      NEW.pnl_category := coalesce(mise_pnl_bucket(NEW.chef_category), NEW.pnl_category);
    END IF;
    RETURN NEW;
  END IF;

  -- chef_category remains the authority when present.
  IF NEW.chef_category IS NOT NULL AND lower(NEW.chef_category) <> 'uncategorized' THEN
    NEW.pnl_category    := coalesce(mise_pnl_bucket(NEW.chef_category), NEW.pnl_category);
    NEW.category_source := coalesce(NEW.category_source, 'machine');
  ELSIF NEW.pnl_category IS NULL THEN
    -- Static regex. Returns NULL when genuinely unknown -- unknown stays unknown.
    NEW.pnl_category := mise_pnl_category(NEW.vendor_category, NEW.item_description);
    IF NEW.pnl_category IS NOT NULL THEN
      NEW.category_source := coalesce(NEW.category_source, 'machine');
    END IF;
  END IF;

  RETURN NEW;
END;
$function$;

-- ── M2: math trigger ────────────────────────────────────────────────────────
-- Identical to the existing function except for the uom_locked guard on the
-- single canonical_uom line. All pack parsing, catch-weight, charge-row,
-- priced-per-unit reconciliation and flagging behaviour is untouched.
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

  -- M2: only canonicalise when a human has not fixed this unit themselves.
  IF NOT coalesce(NEW.uom_locked, false) THEN
    NEW.raw_uom := public.mise_canonical_uom(NEW.raw_pack, NEW.raw_size, NEW.raw_uom);
  END IF;

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
