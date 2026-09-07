
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
  v_bullet text := chr(8226);
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
    ARRAY(SELECT v_bullet || ' [MONEY] ' || x FROM unnest(v_money) x),
    ARRAY(SELECT v_bullet || ' [UNITS] ' || x FROM unnest(v_unit) x)
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

-- Re-run the audit for the test invoice to confirm the fix, then clean up the test rows.
UPDATE public.invoice_line_items SET raw_quantity = raw_quantity
 WHERE invoice_id = (SELECT id FROM public.invoices WHERE invoice_number = 'TEST-EDGE-CASES');

