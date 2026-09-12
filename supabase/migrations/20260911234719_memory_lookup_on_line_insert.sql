-- M5. ONE memory lookup, in ONE place: BEFORE INSERT on invoice_line_items.
--
-- ORDERING. Postgres fires BEFORE ROW triggers in alphabetical order by
-- trigger name. Naming this trg_a_memory_lookup puts it ahead of
-- trg_line_item_defaults (classification) and trg_line_item_math (arithmetic):
--
--   trg_a_memory_lookup   -> remembered human knowledge lands on the row
--   trg_line_item_defaults-> static regex fills only what is still unknown
--   trg_line_item_math    -> software does the math on the corrected inputs
--
-- PRECEDENCE (the point of the whole exercise):
--   human-confirmed memory  >  new machine extraction  >  static classification
--
-- A remembered value is applied EVEN WHEN the new extraction supplies a
-- conflicting non-null value -- that is exactly the INV-2 case, where Gemini
-- again reads "2/5 LB" as pack 25 / size LB. Only fields listed in
-- confirmed_fields are overridden; everything else is left untouched.
--
-- Memory supplies corrected INPUTS. It never supplies an answer:
-- total_base_units and cost_per_base_unit are still computed by
-- mise_parse_pack/mise_line_item_math. Software still does the math.
--
-- A memory miss changes nothing at all -- unknown stays unknown.

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

COMMENT ON FUNCTION public.mise_memory_lookup() IS
  'The single memory read in the ingestion path. Applies human-confirmed values over a conflicting machine extraction, for confirmed fields only. A miss is a no-op: unknown stays unknown.';

DROP TRIGGER IF EXISTS trg_a_memory_lookup ON public.invoice_line_items;
CREATE TRIGGER trg_a_memory_lookup
  BEFORE INSERT ON public.invoice_line_items
  FOR EACH ROW EXECUTE FUNCTION public.mise_memory_lookup();
