-- M4. The smallest persistent item-memory table.
--
-- INVARIANT: only an owner correction creates human-confirmed memory. This is
-- enforced by privilege, not by an RLS policy that tries to guess which
-- application path is calling. anon/authenticated get NO grants at all, so
-- PostgREST will not expose this table to the browser. The only writer is
-- mise_apply_correction() (SECURITY DEFINER, owned by postgres) and the
-- service role.
--
-- IDENTITY: exact match is (client_id, vendor_key, vendor_item_code).
-- description_key exists ONLY as a fallback for vendors that print no item
-- code. No fuzzy matching, no similarity, no embeddings.
--
-- KNOWN LIMITATION -- VENDOR ALIASES (deliberately out of scope for this PoC):
-- mise_vendor_key() normalises punctuation, case and legal suffixes. It does
-- NOT and cannot prove that "SYSCO SAN FRANCISCO, INC." and
-- "SYSCO - SAN FRANCISCO" are the same vendor -- they normalise to different
-- keys and will hold separate memory. That is the SAFE failure direction: a
-- missed match asks the owner again, whereas a wrong match would silently
-- apply one vendor's pack size to another vendor's SKU. A real vendor-master
-- with an alias table is the next required improvement after this proof.

-- ── normalisation helpers ───────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.mise_vendor_key(p_vendor text)
 RETURNS varchar
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

COMMENT ON FUNCTION public.mise_vendor_key(text) IS
  'Normalises a printed vendor name into a comparison key. Does NOT resolve vendor aliases - two spellings of the same distributor can still produce different keys, which keeps their memory isolated rather than wrongly shared.';

CREATE OR REPLACE FUNCTION public.mise_description_key(p_description text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT nullif(regexp_replace(upper(coalesce(p_description,'')), '[^A-Z0-9]+', '', 'g'), '');
$function$;

COMMENT ON FUNCTION public.mise_description_key(text) IS
  'Exact-match fallback key for vendors that print no item code. Case/punctuation insensitive only - this is NOT fuzzy matching.';

-- ── the memory table ────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.client_item_memory (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),

  -- identity
  client_id             uuid NOT NULL REFERENCES public.clients(id) ON DELETE CASCADE,
  vendor_key            varchar NOT NULL,
  vendor_item_code      varchar,
  description_key       text,

  -- what the owner confirmed
  ingredient_id         uuid REFERENCES public.ingredients(id),
  chef_category         varchar,
  pnl_category          varchar,
  raw_pack              varchar,
  raw_size              varchar,
  raw_uom               varchar,
  standardized_base_unit varchar,

  -- which of the above the human actually confirmed. Only these are ever
  -- applied to a later invoice; everything else stays as extracted.
  confirmed_fields      text[] NOT NULL DEFAULT '{}',

  -- provenance
  source                varchar NOT NULL DEFAULT 'human',
  confirmed_at          timestamptz NOT NULL DEFAULT now(),
  confirm_count         integer NOT NULL DEFAULT 1,
  source_invoice_id     uuid REFERENCES public.invoices(id) ON DELETE SET NULL,
  source_line_item_id   uuid REFERENCES public.invoice_line_items(id) ON DELETE SET NULL,
  applied_count         integer NOT NULL DEFAULT 0,
  last_applied_at       timestamptz,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT client_item_memory_source_check
    CHECK (source IN ('human')),
  CONSTRAINT client_item_memory_has_a_key
    CHECK (vendor_item_code IS NOT NULL OR description_key IS NOT NULL),
  CONSTRAINT client_item_memory_confirmed_fields_known
    CHECK (confirmed_fields <@ ARRAY[
      'ingredient_id','chef_category','pnl_category',
      'raw_pack','raw_size','raw_uom','standardized_base_unit'
    ]::text[])
);

COMMENT ON TABLE public.client_item_memory IS
  'One row per item this restaurant has taught MiseAI. Written ONLY by mise_apply_correction() when an owner confirms a correction. Read once per line at ingestion by trg_a_memory_lookup. A correction becomes a row here, never a migration.';
COMMENT ON COLUMN public.client_item_memory.confirmed_fields IS
  'The subset of fields the owner actually confirmed. Only these override a later extraction; unconfirmed fields are left to normal extraction and classification.';
COMMENT ON COLUMN public.client_item_memory.description_key IS
  'Fallback identity for vendors printing no item code. Exact normalised match only - never fuzzy.';
COMMENT ON COLUMN public.client_item_memory.applied_count IS
  'How many later invoice lines this memory has corrected without a human. This is the learning metric.';

-- exact identity: one memory per client + vendor + SKU
CREATE UNIQUE INDEX IF NOT EXISTS client_item_memory_sku_key
  ON public.client_item_memory (client_id, vendor_key, vendor_item_code)
  WHERE vendor_item_code IS NOT NULL;

-- fallback identity: only for rows that have no SKU at all
CREATE UNIQUE INDEX IF NOT EXISTS client_item_memory_desc_key
  ON public.client_item_memory (client_id, vendor_key, description_key)
  WHERE vendor_item_code IS NULL AND description_key IS NOT NULL;

-- lookup support for the fallback path
CREATE INDEX IF NOT EXISTS client_item_memory_desc_lookup
  ON public.client_item_memory (client_id, vendor_key, description_key);

-- ── privilege: the browser cannot manufacture memory ────────────────────────
ALTER TABLE public.client_item_memory ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.client_item_memory FROM anon, authenticated;
GRANT  ALL ON public.client_item_memory TO service_role;
-- No RLS policy is created for anon/authenticated. With RLS enabled and no
-- policy, every statement from those roles is denied even if a GRANT is ever
-- added back by mistake. Defence in depth, both layers pointing the same way.
