-- Upgrades mise_audit_invoice with three new checks beyond arithmetic:
--   1. Possible duplicate invoice (same vendor/date/total, or same invoice
--      number with an identical line-total fingerprint) -- folded into
--      math_is_correct so ingest-invoice's existing status branch
--      (audit.math_is_correct ? 'completed' : 'requires_human_review')
--      routes duplicates to human review with zero edge-function changes.
--   2. Duplicate SKU within the same invoice (hard money_problem).
--   3. Advisory risk_warnings (price spike vs v_ingredient_last_price,
--      vendor tax-rate anomaly, disproportionate freight/fees, credit
--      lines) -- surfaced but does NOT block auto-completion, so a single
--      price bump doesn't force every otherwise-correct invoice into
--      manual review.
-- All existing math/unit checks are unchanged.
--
-- The output row shape changed (two new columns), which Postgres does not
-- allow via CREATE OR REPLACE alone -- drop first, same signature.
DROP FUNCTION IF EXISTS public.mise_audit_invoice(uuid);

CREATE FUNCTION public.mise_audit_invoice(p_invoice_id uuid)
 RETURNS TABLE(
   math_is_correct boolean,
   calculated_subtotal numeric,
   checked_against text,
   subtotal_variance numeric,
   money_problems text[],
   unit_problems text[],
   risk_warnings text[],
   is_possible_duplicate boolean,
   flag_reason text
 )
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_this       public.invoices%ROWTYPE;
  v_tax        numeric;
  v_calc       numeric := 0;
  v_any_missing boolean := false;
  v_basis      numeric; v_basis_label text;
  v_money      text[] := '{}';
  v_unit       text[] := '{}';
  v_risk       text[] := '{}';
  v_short      numeric;
  v_all        text[];
  v_bullet     text := chr(8226);
  rec          record;
  v_money_print    text;
  v_dupe_id        uuid;
  v_dupe_number    varchar;
  v_is_duplicate   boolean := false;
  v_fee_total      numeric;
  v_vendor_avg_tax_rate numeric;
  v_this_rate      numeric;
BEGIN
  SELECT * INTO v_this FROM public.invoices WHERE id = p_invoice_id;
  v_tax := coalesce(v_this.tax, 0);

  SELECT coalesce(sum(round(line_total * 100)), 0) / 100.0,
         bool_or(line_total IS NULL)
    INTO v_calc, v_any_missing
    FROM public.invoice_line_items
   WHERE invoice_id = p_invoice_id AND removed_by_review IS NOT TRUE;

  IF v_this.subtotal IS NOT NULL THEN
    v_basis := v_this.subtotal; v_basis_label := 'printed subtotal';
  ELSIF v_this.grand_total IS NOT NULL THEN
    v_basis := round(v_this.grand_total - v_tax, 2);
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

  IF v_this.subtotal IS NOT NULL AND v_this.grand_total IS NOT NULL
     AND abs(round((v_this.subtotal + v_tax) * 100) - round(v_this.grand_total * 100)) > 2 THEN
    v_money := array_append(v_money, format('Grand total mismatch: subtotal %s + tax %s = %s, invoice says %s.',
        round(v_this.subtotal,2), round(v_tax,2), round(v_this.subtotal + v_tax,2), round(v_this.grand_total,2)));
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

  SELECT string_agg(line_total::text, ',' ORDER BY line_total)
    INTO v_money_print
    FROM public.invoice_line_items
   WHERE invoice_id = p_invoice_id AND removed_by_review IS NOT TRUE;

  SELECT i2.id, i2.invoice_number INTO v_dupe_id, v_dupe_number
    FROM public.invoices i2
   WHERE i2.id <> p_invoice_id
     AND i2.client_id = v_this.client_id
     AND i2.merged_into IS NULL
     AND (
       (v_this.invoice_number IS NOT NULL
        AND upper(i2.invoice_number) = upper(v_this.invoice_number)
        AND coalesce((SELECT string_agg(line_total::text, ',' ORDER BY line_total)
                        FROM public.invoice_line_items
                       WHERE invoice_id = i2.id AND removed_by_review IS NOT TRUE), '')
            = coalesce(v_money_print, ''))
       OR
       (v_this.vendor_name IS NOT NULL AND i2.vendor_name = v_this.vendor_name
        AND v_this.invoice_date IS NOT NULL AND i2.invoice_date = v_this.invoice_date
        AND v_this.grand_total IS NOT NULL AND i2.grand_total = v_this.grand_total)
     )
   LIMIT 1;

  IF v_dupe_id IS NOT NULL THEN
    v_is_duplicate := true;
    v_money := array_append(v_money, format(
      'Looks like a duplicate of invoice %s (id %s) -- same vendor/date/total or an identical line-total fingerprint under the same invoice number. If it truly is, mark this one removed rather than letting it post twice to inventory and COGS.',
      coalesce(v_dupe_number, '(no number)'), v_dupe_id));
  END IF;

  FOR rec IN
    SELECT vendor_item_code, item_description, count(*) AS n
      FROM public.invoice_line_items
     WHERE invoice_id = p_invoice_id AND removed_by_review IS NOT TRUE
       AND vendor_item_code IS NOT NULL
     GROUP BY vendor_item_code, item_description
    HAVING count(*) > 1
  LOOP
    v_money := array_append(v_money, format(
      'SKU %s ("%s") appears %s times on this invoice -- check it wasn''t billed twice.',
      rec.vendor_item_code, rec.item_description, rec.n));
  END LOOP;

  FOR rec IN
    SELECT li.item_description, li.cost_per_base_unit AS now_cost, lp.cost_per_base_unit AS last_cost
      FROM public.invoice_line_items li
      JOIN public.v_ingredient_last_price lp ON lp.ingredient_id = li.ingredient_id
     WHERE li.invoice_id = p_invoice_id AND li.removed_by_review IS NOT TRUE
       AND li.cost_per_base_unit IS NOT NULL AND lp.cost_per_base_unit > 0
       AND li.cost_per_base_unit > lp.cost_per_base_unit * 1.25
  LOOP
    v_risk := array_append(v_risk, format(
      '[%s] cost jumped from %s to %s per unit (+%s%%) vs the last completed invoice -- confirm this wasn''t a pricing error or an unannounced increase.',
      rec.item_description, rec.last_cost, rec.now_cost,
      round(100.0 * (rec.now_cost - rec.last_cost) / rec.last_cost, 1)));
  END LOOP;

  SELECT avg(tax / NULLIF(subtotal, 0)) INTO v_vendor_avg_tax_rate
    FROM public.invoices
   WHERE client_id = v_this.client_id AND vendor_name = v_this.vendor_name
     AND status = 'completed' AND subtotal > 0 AND tax IS NOT NULL AND id <> p_invoice_id;

  IF v_vendor_avg_tax_rate IS NOT NULL AND v_this.subtotal > 0 AND v_this.tax IS NOT NULL THEN
    v_this_rate := v_this.tax / v_this.subtotal;
    IF abs(v_this_rate - v_vendor_avg_tax_rate) > 0.03 THEN
      v_risk := array_append(v_risk, format(
        'Tax is %s%% of subtotal on this invoice; %s''s other invoices average %s%% -- worth a second look.',
        round(v_this_rate * 100, 1), v_this.vendor_name, round(v_vendor_avg_tax_rate * 100, 1)));
    END IF;
  END IF;

  SELECT coalesce(sum(line_total), 0) INTO v_fee_total
    FROM public.invoice_line_items
   WHERE invoice_id = p_invoice_id AND removed_by_review IS NOT TRUE
     AND item_description ~* '\y(FUEL|DELIVERY|SURCHARGE|SPLIT\s*CASE|FREIGHT|MIN(IMUM)?\s*ORDER|PICKUP)\y';

  IF v_basis IS NOT NULL AND v_basis > 0 AND v_fee_total > 0
     AND v_fee_total / v_basis > 0.15 THEN
    v_risk := array_append(v_risk, format(
      'Freight/fee lines total %s -- %s%% of this invoice, unusually high.',
      round(v_fee_total, 2), round(100.0 * v_fee_total / v_basis, 1)));
  END IF;

  FOR rec IN
    SELECT item_description, line_total
      FROM public.invoice_line_items
     WHERE invoice_id = p_invoice_id AND removed_by_review IS NOT TRUE AND line_total < 0
  LOOP
    v_risk := array_append(v_risk, format(
      '[%s] is a credit of %s -- confirm it was actually issued by the vendor, not a misread sign.',
      rec.item_description, rec.line_total));
  END LOOP;

  v_all := array_cat(array_cat(
    ARRAY(SELECT v_bullet || ' [MONEY] ' || x FROM unnest(v_money) x),
    ARRAY(SELECT v_bullet || ' [UNITS] ' || x FROM unnest(v_unit) x)),
    ARRAY(SELECT v_bullet || ' [RISK] '  || x FROM unnest(v_risk) x)
  );

  math_is_correct      := (array_length(v_money, 1) IS NULL) AND NOT v_is_duplicate;
  calculated_subtotal  := v_calc;
  checked_against      := v_basis_label;
  subtotal_variance    := CASE WHEN v_basis IS NULL THEN NULL ELSE round(abs(v_calc - v_basis), 2) END;
  money_problems       := v_money;
  unit_problems        := v_unit;
  risk_warnings        := v_risk;
  is_possible_duplicate := v_is_duplicate;
  flag_reason := CASE WHEN array_length(v_all, 1) IS NULL THEN NULL
    ELSE format('AUDIT (%s money, %s unit, %s risk):',
           coalesce(array_length(v_money,1),0), coalesce(array_length(v_unit,1),0), coalesce(array_length(v_risk,1),0))
          || E'\n' || array_to_string(v_all, E'\n')
  END;
  RETURN NEXT;
END;
$function$;

COMMENT ON FUNCTION public.mise_audit_invoice(uuid) IS
  'Audits one invoice: line-vs-subtotal/grand-total arithmetic (hard, blocks completion), possible-duplicate detection via vendor/date/total or line-total fingerprint (hard, blocks completion), duplicate SKU within the invoice (hard), and advisory risk_warnings -- price spike vs v_ingredient_last_price, vendor tax-rate anomaly, disproportionate freight/fees, unexplained credits -- which surface in flag_reason but do not block auto-completion.';
