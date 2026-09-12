-- M7b. mise_apply_correction now runs every candidate field through
-- mise_confirmable() before it is allowed to become memory. Identical in every
-- other respect to the version applied in M6.

CREATE OR REPLACE FUNCTION public.mise_apply_correction(
  p_line_item_id    uuid,
  p_patch           jsonb,
  p_ingredient_name text DEFAULT NULL,
  p_remember        boolean DEFAULT true
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $function$
DECLARE
  v_line        public.invoice_line_items%ROWTYPE;
  v_after       public.invoice_line_items%ROWTYPE;
  v_invoice     public.invoices%ROWTYPE;
  v_vendor_key  varchar;
  v_desc_key    text;
  v_sku         varchar;
  v_ingredient  uuid;
  v_changed     text[] := '{}';
  v_confirmed   text[] := '{}';
  v_skipped     text[] := '{}';
  v_mem_id      uuid;
  v_unmapped    int;
  v_total       int;
  v_status      varchar;
  v_corr        int := 0;
  v_newval      text;
  fld           text;
  MEMORABLE     text[] := ARRAY['ingredient_id','chef_category','pnl_category','raw_pack','raw_size','raw_uom'];
  PATCHABLE     text[] := ARRAY['item_description','vendor_item_code','raw_quantity','raw_uom','raw_pack',
                                'raw_size','raw_unit_price','line_total','chef_category','pnl_category','ingredient_id'];
BEGIN
  SELECT * INTO v_line FROM public.invoice_line_items WHERE id = p_line_item_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Line item % not found', p_line_item_id USING ERRCODE = 'no_data_found';
  END IF;

  SELECT * INTO v_invoice FROM public.invoices WHERE id = v_line.invoice_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Invoice for line % not found', p_line_item_id USING ERRCODE = 'no_data_found';
  END IF;

  FOR fld IN SELECT jsonb_object_keys(coalesce(p_patch,'{}'::jsonb)) LOOP
    IF NOT (fld = ANY(PATCHABLE)) THEN
      RAISE EXCEPTION 'Field % is not correctable', fld USING ERRCODE = 'invalid_parameter_value';
    END IF;
  END LOOP;

  v_ingredient := CASE WHEN p_patch ? 'ingredient_id'
                       THEN nullif(p_patch->>'ingredient_id','')::uuid
                       ELSE v_line.ingredient_id END;

  IF v_ingredient IS NULL AND coalesce(trim(p_ingredient_name),'') <> '' THEN
    SELECT id INTO v_ingredient
      FROM public.ingredients
     WHERE client_id = v_invoice.client_id AND lower(name) = lower(trim(p_ingredient_name));
    IF v_ingredient IS NULL THEN
      INSERT INTO public.ingredients (client_id, name)
      VALUES (v_invoice.client_id, trim(p_ingredient_name))
      RETURNING id INTO v_ingredient;
    END IF;
  END IF;

  UPDATE public.invoice_line_items SET
    item_description = CASE WHEN p_patch ? 'item_description' THEN p_patch->>'item_description' ELSE item_description END,
    vendor_item_code = CASE WHEN p_patch ? 'vendor_item_code' THEN nullif(p_patch->>'vendor_item_code','')::varchar ELSE vendor_item_code END,
    raw_quantity     = CASE WHEN p_patch ? 'raw_quantity'   THEN nullif(p_patch->>'raw_quantity','')::numeric ELSE raw_quantity END,
    raw_unit_price   = CASE WHEN p_patch ? 'raw_unit_price' THEN nullif(p_patch->>'raw_unit_price','')::numeric ELSE raw_unit_price END,
    line_total       = CASE WHEN p_patch ? 'line_total'     THEN nullif(p_patch->>'line_total','')::numeric ELSE line_total END,
    raw_pack         = CASE WHEN p_patch ? 'raw_pack'       THEN nullif(p_patch->>'raw_pack','')::varchar ELSE raw_pack END,
    raw_size         = CASE WHEN p_patch ? 'raw_size'       THEN nullif(p_patch->>'raw_size','')::varchar ELSE raw_size END,
    raw_uom          = CASE WHEN p_patch ? 'raw_uom'        THEN nullif(p_patch->>'raw_uom','')::varchar ELSE raw_uom END,
    chef_category    = CASE WHEN p_patch ? 'chef_category'  THEN nullif(p_patch->>'chef_category','')::varchar ELSE chef_category END,
    pnl_category     = CASE WHEN p_patch ? 'pnl_category'   THEN nullif(p_patch->>'pnl_category','')::varchar ELSE pnl_category END,
    ingredient_id    = v_ingredient,
    matched_at       = CASE WHEN v_ingredient IS NOT NULL THEN coalesce(matched_at, now()) ELSE matched_at END,
    uom_locked       = CASE WHEN p_patch ? 'raw_uom' AND coalesce(btrim(p_patch->>'raw_uom'),'') <> ''
                            THEN true ELSE uom_locked END,
    category_source  = CASE WHEN (p_patch ? 'chef_category' AND public.mise_confirmable('chef_category', p_patch->>'chef_category'))
                              OR (p_patch ? 'pnl_category'  AND public.mise_confirmable('pnl_category',  p_patch->>'pnl_category'))
                            THEN 'human' ELSE category_source END
  WHERE id = p_line_item_id
  RETURNING * INTO v_after;

  -- Audit log: every changed field is recorded, confirmable or not.
  FOREACH fld IN ARRAY PATCHABLE LOOP
    CONTINUE WHEN NOT (p_patch ? fld);
    IF to_jsonb(v_line)->>fld IS DISTINCT FROM to_jsonb(v_after)->>fld THEN
      v_changed := array_append(v_changed, fld);
      INSERT INTO public.invoice_corrections
        (invoice_id, line_item_id, field_name, old_value, new_value, model_used)
      VALUES
        (v_line.invoice_id, p_line_item_id, fld,
         to_jsonb(v_line)->>fld, to_jsonb(v_after)->>fld, v_invoice.model_used);
      v_corr := v_corr + 1;

      -- ...but only real knowledge becomes memory.
      IF fld = ANY(MEMORABLE) THEN
        v_newval := to_jsonb(v_after)->>fld;
        IF public.mise_confirmable(fld, v_newval) THEN
          v_confirmed := array_append(v_confirmed, fld);
        ELSE
          v_skipped := array_append(v_skipped, fld);
        END IF;
      END IF;
    END IF;
  END LOOP;

  IF v_ingredient IS DISTINCT FROM v_line.ingredient_id AND NOT ('ingredient_id' = ANY(v_confirmed)) THEN
    IF v_ingredient IS NOT NULL THEN
      v_confirmed := array_append(v_confirmed, 'ingredient_id');
    END IF;
    IF NOT ('ingredient_id' = ANY(v_changed)) THEN
      v_changed := array_append(v_changed, 'ingredient_id');
      INSERT INTO public.invoice_corrections
        (invoice_id, line_item_id, field_name, old_value, new_value, model_used)
      VALUES (v_line.invoice_id, p_line_item_id, 'ingredient_id',
              v_line.ingredient_id::text, v_ingredient::text, v_invoice.model_used);
      v_corr := v_corr + 1;
    END IF;
  END IF;

  v_vendor_key := public.mise_vendor_key(v_invoice.vendor_name);
  v_sku        := coalesce(v_after.vendor_item_code, public.mise_item_code(v_after.item_description));
  v_desc_key   := public.mise_description_key(v_after.item_description);

  IF p_remember AND array_length(v_confirmed,1) > 0 AND v_vendor_key IS NOT NULL
     AND (v_sku IS NOT NULL OR v_desc_key IS NOT NULL) THEN

    IF v_sku IS NOT NULL THEN
      SELECT id INTO v_mem_id FROM public.client_item_memory
       WHERE client_id = v_invoice.client_id AND vendor_key = v_vendor_key AND vendor_item_code = v_sku;
    ELSE
      SELECT id INTO v_mem_id FROM public.client_item_memory
       WHERE client_id = v_invoice.client_id AND vendor_key = v_vendor_key
         AND vendor_item_code IS NULL AND description_key = v_desc_key;
    END IF;

    IF v_mem_id IS NULL THEN
      INSERT INTO public.client_item_memory (
        client_id, vendor_key, vendor_item_code, description_key,
        ingredient_id, chef_category, pnl_category,
        raw_pack, raw_size, raw_uom, standardized_base_unit,
        confirmed_fields, source, confirmed_at, confirm_count,
        source_invoice_id, source_line_item_id
      ) VALUES (
        v_invoice.client_id, v_vendor_key, v_sku, v_desc_key,
        v_after.ingredient_id, v_after.chef_category, v_after.pnl_category,
        v_after.raw_pack, v_after.raw_size, v_after.raw_uom, v_after.standardized_base_unit,
        v_confirmed, 'human', now(), 1,
        v_line.invoice_id, p_line_item_id
      ) RETURNING id INTO v_mem_id;
    ELSE
      UPDATE public.client_item_memory SET
        ingredient_id          = v_after.ingredient_id,
        chef_category          = v_after.chef_category,
        pnl_category           = v_after.pnl_category,
        raw_pack               = v_after.raw_pack,
        raw_size               = v_after.raw_size,
        raw_uom                = v_after.raw_uom,
        standardized_base_unit = v_after.standardized_base_unit,
        confirmed_fields       = ARRAY(SELECT DISTINCT unnest(confirmed_fields || v_confirmed)),
        confirmed_at           = now(),
        confirm_count          = confirm_count + 1,
        source_invoice_id      = v_line.invoice_id,
        source_line_item_id    = p_line_item_id,
        updated_at             = now()
      WHERE id = v_mem_id;
    END IF;
  END IF;

  SELECT count(*),
         count(*) FILTER (WHERE ingredient_id IS NULL AND coalesce(chef_category,'') <> 'non_cogs_fee')
    INTO v_total, v_unmapped
    FROM public.invoice_line_items
   WHERE invoice_id = v_line.invoice_id AND removed_by_review IS NOT TRUE;

  v_status := CASE WHEN v_total > 0 AND v_unmapped = 0 THEN 'completed' ELSE 'requires_human_review' END;

  UPDATE public.invoices
     SET status           = v_status,
         corrected_at     = now(),
         correction_count = coalesce(correction_count,0) + v_corr
   WHERE id = v_line.invoice_id;

  RETURN jsonb_build_object(
    'line_item_id',       p_line_item_id,
    'invoice_id',         v_line.invoice_id,
    'fields_changed',     to_jsonb(v_changed),
    'corrections_logged', v_corr,
    'ingredient_id',      v_ingredient,
    'memory_id',          v_mem_id,
    'memory_confirmed',   to_jsonb(v_confirmed),
    'memory_skipped',     to_jsonb(v_skipped),
    'invoice_status',     v_status,
    'lines_unmapped',     v_unmapped,
    'total_base_units',   v_after.total_base_units,
    'cost_per_base_unit', v_after.cost_per_base_unit,
    'standardized_base_unit', v_after.standardized_base_unit,
    'is_flagged',         v_after.is_flagged
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.mise_apply_correction(uuid,jsonb,text,boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.mise_apply_correction(uuid,jsonb,text,boolean)
  TO anon, authenticated, service_role;
