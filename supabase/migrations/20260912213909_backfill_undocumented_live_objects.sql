-- CATCH-UP MIGRATION: documents objects that already exist live in production
-- but have never appeared in any migration file across this repo's history.
-- Confirmed by cross-referencing every table/function/view name in the live
-- database against every .sql file under supabase/migrations/ -- these had
-- zero references anywhere. All statements below are idempotent (IF NOT
-- EXISTS / OR REPLACE / DROP+CREATE for triggers) so re-running this against
-- the already-live database is a safe no-op; it exists purely to close the
-- gap between the repo and reality.
--
-- Excluded on purpose: parsed_data (0 rows, 0 references anywhere including
-- edge functions, shaped like a superseded early design with a loose
-- restaurant_id text column instead of the client_id uuid FK pattern every
-- other table uses) -- documenting it as real architecture would misrepresent
-- dead schema as active. locker_findings/locker_issues/locker_milestones/
-- locker_status are NOT missing -- they were created under their original
-- names (security_findings/open_issues/project_milestones/project_status)
-- in earlier migrations and later renamed; that history is already tracked.

-- ── Tables ──────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.inventory_counts (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id   uuid NOT NULL REFERENCES public.clients(id) ON DELETE CASCADE,
  count_date  date NOT NULL DEFAULT CURRENT_DATE,
  note        text,
  counted_by  text,
  created_at  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.inventory_counts IS 'One physical count session -- a walk of the walk-in, the bar, or one section of either.';
ALTER TABLE public.inventory_counts ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS public.inventory_count_lines (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  inventory_count_id  uuid NOT NULL REFERENCES public.inventory_counts(id) ON DELETE CASCADE,
  ingredient_id       uuid REFERENCES public.ingredients(id) ON DELETE CASCADE,
  beverage_item_id    uuid REFERENCES public.beverage_items(id) ON DELETE CASCADE,
  counted_base_units  numeric NOT NULL CHECK (counted_base_units >= 0),
  system_base_units   numeric,
  variance_base_units numeric,
  cost_per_base_unit  numeric,
  variance_dollars    numeric,
  note                text,
  created_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT count_line_targets_exactly_one CHECK (
    (ingredient_id IS NOT NULL AND beverage_item_id IS NULL) OR
    (ingredient_id IS NULL AND beverage_item_id IS NOT NULL)
  )
);
CREATE INDEX IF NOT EXISTS inventory_count_lines_by_count ON public.inventory_count_lines (inventory_count_id);
ALTER TABLE public.inventory_count_lines ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS public.inventory_receipts (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id             uuid NOT NULL REFERENCES public.clients(id) ON DELETE CASCADE,
  invoice_line_item_id  uuid NOT NULL UNIQUE REFERENCES public.invoice_line_items(id) ON DELETE CASCADE,
  ingredient_id         uuid REFERENCES public.ingredients(id) ON DELETE SET NULL,
  beverage_item_id      uuid REFERENCES public.beverage_items(id) ON DELETE SET NULL,
  base_units_received   numeric NOT NULL,
  cost_per_base_unit    numeric,
  dollar_value          numeric,
  received_at           timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.inventory_receipts IS 'One row per invoice line that put stock on the shelf. The UNIQUE on invoice_line_item_id is what makes receiving idempotent: a re-run adjusts by the difference instead of adding a second time.';
ALTER TABLE public.inventory_receipts ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS public.client_item_memory (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id               uuid NOT NULL REFERENCES public.clients(id) ON DELETE CASCADE,
  vendor_key              varchar NOT NULL,
  vendor_item_code        varchar,
  description_key         text,
  ingredient_id           uuid REFERENCES public.ingredients(id),
  chef_category           varchar,
  pnl_category            varchar,
  raw_pack                varchar,
  raw_size                varchar,
  raw_uom                 varchar,
  standardized_base_unit  varchar,
  confirmed_fields        text[] NOT NULL DEFAULT '{}',
  source                  varchar NOT NULL DEFAULT 'human' CHECK (source = 'human'),
  confirmed_at            timestamptz NOT NULL DEFAULT now(),
  confirm_count           integer NOT NULL DEFAULT 1,
  source_invoice_id       uuid REFERENCES public.invoices(id) ON DELETE SET NULL,
  source_line_item_id     uuid REFERENCES public.invoice_line_items(id) ON DELETE SET NULL,
  applied_count           integer NOT NULL DEFAULT 0,
  last_applied_at         timestamptz,
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT client_item_memory_has_a_key CHECK (vendor_item_code IS NOT NULL OR description_key IS NOT NULL),
  CONSTRAINT client_item_memory_confirmed_fields_known CHECK (
    confirmed_fields <@ ARRAY['ingredient_id','chef_category','pnl_category','raw_pack','raw_size','raw_uom','standardized_base_unit']
  )
);
COMMENT ON TABLE public.client_item_memory IS 'One row per item this restaurant has taught MiseAI. Written ONLY by mise_apply_correction() when an owner confirms a correction. Read once per line at ingestion by trg_a_memory_lookup. A correction becomes a row here, never a migration.';
CREATE UNIQUE INDEX IF NOT EXISTS client_item_memory_sku_key ON public.client_item_memory (client_id, vendor_key, vendor_item_code) WHERE (vendor_item_code IS NOT NULL);
CREATE UNIQUE INDEX IF NOT EXISTS client_item_memory_desc_key ON public.client_item_memory (client_id, vendor_key, description_key) WHERE (vendor_item_code IS NULL AND description_key IS NOT NULL);
CREATE INDEX IF NOT EXISTS client_item_memory_desc_lookup ON public.client_item_memory (client_id, vendor_key, description_key);
ALTER TABLE public.client_item_memory ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS public.menu_item_boms (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id           uuid NOT NULL REFERENCES public.clients(id) ON DELETE CASCADE,
  pos_item_name       text NOT NULL,
  menu_item_id        uuid REFERENCES public.menu_items(id) ON DELETE SET NULL,
  ingredient_id       uuid NOT NULL REFERENCES public.ingredients(id) ON DELETE CASCADE,
  portion_size        text,
  yield_factor        numeric NOT NULL DEFAULT 1.0 CHECK (yield_factor > 0 AND yield_factor <= 1),
  base_units_consumed numeric NOT NULL CHECK (base_units_consumed > 0),
  notes               text,
  created_at          timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.menu_item_boms IS 'What one sale of a POS button consumes from inventory, in the ingredient base unit. The kitchen twin of beverage_boms.';
CREATE INDEX IF NOT EXISTS menu_item_boms_lookup ON public.menu_item_boms (client_id, lower(pos_item_name));
ALTER TABLE public.menu_item_boms ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS public.service_waste_log (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id     uuid NOT NULL REFERENCES public.clients(id),
  service_date  date NOT NULL DEFAULT CURRENT_DATE,
  prep_item_id  uuid REFERENCES public.prep_items(id),
  item_name     text,
  dollar_value  numeric NOT NULL,
  note          text,
  logged_at     timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.service_waste_log IS 'Waste logged during service, in dollars. Separate from prep_yield_log
   (batch-prep portion/weight yield). Not yet wired to any app screen --
   built ahead of the Cook App UI decision, use if/when that flow ships.';
ALTER TABLE public.service_waste_log ENABLE ROW LEVEL SECURITY;

-- ── Functions ───────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.mise_vendor_key(p_vendor text)
 RETURNS character varying
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT nullif(
    regexp_replace(
      regexp_replace(
        regexp_replace(upper(coalesce(p_vendor,'')), '\y(INC|LLC|LTD|CO|CORP|COMPANY|INCORPORATED)\y', '', 'g'),
        '[^A-Z0-9]+', ' ', 'g'),
      '^\s+|\s+$', '', 'g')
  , '')::varchar;
$function$;

CREATE OR REPLACE FUNCTION public.mise_description_key(p_description text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT nullif(regexp_replace(upper(coalesce(p_description,'')), '[^A-Z0-9]+', '', 'g'), '');
$function$;

CREATE OR REPLACE FUNCTION public.mise_confirmable(p_field text, p_value text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT CASE
    WHEN p_value IS NULL OR btrim(p_value) = '' THEN false
    WHEN p_field = 'chef_category' AND lower(btrim(p_value)) = 'uncategorized' THEN false
    ELSE true
  END;
$function$;

CREATE OR REPLACE FUNCTION public.mise_memory_lookup()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_client_id  uuid;
  v_vendor_key varchar;
  v_sku        varchar;
  v_desc_key   text;
  m            record;
  f            text;
BEGIN
  -- A line the reviewer is typing in by hand already carries human intent.
  -- Never let memory argue with the person sitting in front of it.
  IF NEW.category_source = 'human' THEN
    RETURN NEW;
  END IF;

  SELECT i.client_id, public.mise_vendor_key(i.vendor_name)
    INTO v_client_id, v_vendor_key
    FROM public.invoices i
   WHERE i.id = NEW.invoice_id;

  IF v_client_id IS NULL OR v_vendor_key IS NULL THEN
    RETURN NEW;                         -- nothing to key on
  END IF;

  -- mise_line_item_defaults derives the SKU from the description later; do the
  -- same derivation here so a code-less line can still match on its code.
  v_sku      := coalesce(NEW.vendor_item_code, public.mise_item_code(NEW.item_description));
  v_desc_key := public.mise_description_key(NEW.item_description);

  -- 1. exact identity: client + vendor + SKU
  IF v_sku IS NOT NULL THEN
    SELECT * INTO m FROM public.client_item_memory cim
     WHERE cim.client_id = v_client_id
       AND cim.vendor_key = v_vendor_key
       AND cim.vendor_item_code = v_sku
     LIMIT 1;
  END IF;

  -- 2. fallback ONLY for vendors that print no item code. Exact normalised
  --    description match -- not fuzzy, not similarity.
  IF m IS NULL AND v_desc_key IS NOT NULL THEN
    SELECT * INTO m FROM public.client_item_memory cim
     WHERE cim.client_id = v_client_id
       AND cim.vendor_key = v_vendor_key
       AND cim.vendor_item_code IS NULL
       AND cim.description_key = v_desc_key
     LIMIT 1;
  END IF;

  IF m IS NULL THEN
    RETURN NEW;                         -- unknown stays unknown
  END IF;

  -- Apply ONLY the fields the owner actually confirmed.
  FOREACH f IN ARRAY m.confirmed_fields
  LOOP
    CASE f
      WHEN 'ingredient_id' THEN
        NEW.ingredient_id := m.ingredient_id;
        NEW.matched_at    := coalesce(NEW.matched_at, now());
      WHEN 'chef_category' THEN
        NEW.chef_category   := m.chef_category;
        NEW.category_source := 'human';
      WHEN 'pnl_category' THEN
        NEW.pnl_category    := m.pnl_category;
        NEW.category_source := 'human';
      WHEN 'raw_pack' THEN
        NEW.raw_pack := m.raw_pack;
      WHEN 'raw_size' THEN
        NEW.raw_size := m.raw_size;
      WHEN 'raw_uom' THEN
        NEW.raw_uom    := m.raw_uom;
        NEW.uom_locked := true;         -- keep canonical_uom off a human unit
      ELSE
        NULL;                           -- standardized_base_unit is derived, never forced
    END CASE;
  END LOOP;

  UPDATE public.client_item_memory
     SET applied_count   = applied_count + 1,
         last_applied_at = now()
   WHERE id = m.id;

  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.mise_apply_correction(p_line_item_id uuid, p_patch jsonb, p_ingredient_name text DEFAULT NULL::text, p_remember boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
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

CREATE OR REPLACE FUNCTION public.mise_apply_inventory_count_line()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_system numeric;
  v_cost   numeric;
BEGIN
  IF NEW.beverage_item_id IS NOT NULL THEN
    SELECT coalesce(total_base_units_in_stock, 0), cost_per_base_unit
      INTO v_system, v_cost
      FROM public.beverage_items WHERE id = NEW.beverage_item_id;

    UPDATE public.beverage_items
       SET total_base_units_in_stock = NEW.counted_base_units, updated_at = now()
     WHERE id = NEW.beverage_item_id;
  ELSE
    SELECT coalesce(on_hand, 0) INTO v_system
      FROM public.ingredients WHERE id = NEW.ingredient_id;

    -- Food has no stored cost: it comes from what was last invoiced, which is
    -- the honest figure to value a variance at.
    SELECT cost_per_base_unit INTO v_cost
      FROM public.v_ingredient_last_price WHERE ingredient_id = NEW.ingredient_id;

    UPDATE public.ingredients
       SET on_hand = NEW.counted_base_units, on_hand_updated_at = now()
     WHERE id = NEW.ingredient_id;
  END IF;

  NEW.system_base_units   := v_system;
  NEW.variance_base_units := round(NEW.counted_base_units - coalesce(v_system, 0), 4);
  NEW.cost_per_base_unit  := v_cost;
  NEW.variance_dollars    := CASE WHEN v_cost IS NOT NULL
                                  THEN round(NEW.variance_base_units * v_cost, 2) END;
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.mise_deplete_on_mix_insert()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
  r record;
BEGIN
  FOR r IN SELECT DISTINCT nightly_report_id FROM newrows WHERE nightly_report_id IS NOT NULL
  LOOP
    PERFORM public.mise_apply_nightly_depletion(r.nightly_report_id);
  END LOOP;
  RETURN NULL;
END;
$function$;

-- ── View ────────────────────────────────────────────────────────────────

CREATE OR REPLACE VIEW public.v_inventory_variance
WITH (security_invoker = true) AS
SELECT c.client_id,
    c.count_date,
    c.id AS inventory_count_id,
    COALESCE(i.name, bi.name) AS item_name,
    CASE
        WHEN l.beverage_item_id IS NOT NULL THEN 'beverage'::text
        ELSE 'food'::text
    END AS kind,
    COALESCE(i.base_unit, bi.base_unit) AS base_unit,
    l.system_base_units,
    l.counted_base_units,
    l.variance_base_units,
    l.cost_per_base_unit,
    l.variance_dollars,
    CASE
        WHEN COALESCE(l.system_base_units, 0::numeric) = 0::numeric THEN NULL::numeric
        ELSE round(100.0 * l.variance_base_units / l.system_base_units, 2)
    END AS variance_pct,
    l.note
   FROM public.inventory_count_lines l
     JOIN public.inventory_counts c ON c.id = l.inventory_count_id
     LEFT JOIN public.ingredients i ON i.id = l.ingredient_id
     LEFT JOIN public.beverage_items bi ON bi.id = l.beverage_item_id;

-- ── Triggers ────────────────────────────────────────────────────────────

DROP TRIGGER IF EXISTS trg_a_memory_lookup ON public.invoice_line_items;
CREATE TRIGGER trg_a_memory_lookup BEFORE INSERT ON public.invoice_line_items
  FOR EACH ROW EXECUTE FUNCTION public.mise_memory_lookup();

DROP TRIGGER IF EXISTS trg_apply_inventory_count_line ON public.inventory_count_lines;
CREATE TRIGGER trg_apply_inventory_count_line BEFORE INSERT ON public.inventory_count_lines
  FOR EACH ROW EXECUTE FUNCTION public.mise_apply_inventory_count_line();

DROP TRIGGER IF EXISTS trg_deplete_on_mix_insert ON public.nightly_product_mix;
CREATE TRIGGER trg_deplete_on_mix_insert AFTER INSERT ON public.nightly_product_mix
  REFERENCING NEW TABLE AS newrows
  FOR EACH STATEMENT EXECUTE FUNCTION public.mise_deplete_on_mix_insert();
