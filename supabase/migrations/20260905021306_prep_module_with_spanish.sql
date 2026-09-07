-- PREP, with Spanish held next to the English rather than translated at read
-- time. A prep list is read at 7am on a wall tablet by cooks whose first
-- language is Spanish; a runtime translation call is a spinner, a cost, and a
-- single point of failure at exactly the wrong moment. Translated once when the
-- recipe is written, stored, served instantly.
--
-- Translations live in an i18n jsonb on the row itself: {"es": {...}}. That
-- keeps a recipe's Spanish with the recipe, handles the steps array naturally,
-- and adds a third language later without a schema change.

CREATE TABLE IF NOT EXISTS public.prep_stations (
  code       varchar PRIMARY KEY,
  label      text NOT NULL,
  sort_order smallint NOT NULL DEFAULT 100,
  i18n       jsonb NOT NULL DEFAULT '{}'::jsonb
);

INSERT INTO public.prep_stations (code, label, sort_order, i18n) VALUES
  ('grill',    'Grill',    10, '{"es":{"label":"Parrilla"}}'),
  ('fry',      'Fry',      20, '{"es":{"label":"Freidora"}}'),
  ('saute',    'Saute',    30, '{"es":{"label":"Salteado"}}'),
  ('salads',   'Salads',   40, '{"es":{"label":"Ensaladas"}}'),
  ('desserts', 'Desserts', 50, '{"es":{"label":"Postres"}}'),
  ('pantry',   'Pantry',   60, '{"es":{"label":"Despensa"}}'),
  ('butcher',  'Butcher',  70, '{"es":{"label":"Carnicería"}}')
ON CONFLICT (code) DO NOTHING;

-- Units a cook reads on a prep sheet, not the invoice base units.
CREATE TABLE IF NOT EXISTS public.prep_units (
  code  varchar PRIMARY KEY,
  label text NOT NULL,
  i18n  jsonb NOT NULL DEFAULT '{}'::jsonb
);

INSERT INTO public.prep_units (code, label, i18n) VALUES
  ('lb',    'lb',        '{"es":{"label":"lb","long":"libras"}}'),
  ('oz',    'oz',        '{"es":{"label":"oz","long":"onzas"}}'),
  ('qt',    'qt',        '{"es":{"label":"qt","long":"cuartos"}}'),
  ('gal',   'gal',       '{"es":{"label":"gal","long":"galones"}}'),
  ('each',  'each',      '{"es":{"label":"c/u","long":"cada uno"}}'),
  ('bin',   'bin',       '{"es":{"label":"cajón","long":"cajón"}}'),
  ('case',  'case',      '{"es":{"label":"caja","long":"caja"}}'),
  ('batch', 'batch',     '{"es":{"label":"tanda","long":"tanda"}}'),
  ('portion','portion',  '{"es":{"label":"porción","long":"porciones"}}')
ON CONFLICT (code) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.prep_items (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id  uuid NOT NULL,
  station    varchar NOT NULL REFERENCES public.prep_stations(code),
  name       text NOT NULL,
  unit       varchar REFERENCES public.prep_units(code),
  par        numeric NOT NULL DEFAULT 0,
  is_active  boolean NOT NULL DEFAULT true,
  i18n       jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS prep_items_client_name_key ON public.prep_items (client_id, lower(name));
CREATE INDEX IF NOT EXISTS prep_items_station_idx ON public.prep_items (client_id, station) WHERE is_active;

COMMENT ON COLUMN public.prep_items.i18n IS
  'Per-language overrides, e.g. {"es":{"name":"Sopa de Almejas"}}. Falls back to the English column when a language is missing.';

CREATE TABLE IF NOT EXISTS public.prep_recipes (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  prep_item_id uuid NOT NULL UNIQUE REFERENCES public.prep_items(id) ON DELETE CASCADE,
  name         text NOT NULL,
  batch_yield  text,
  shelf_life   text,
  track_trim   boolean NOT NULL DEFAULT false,
  ingredients  jsonb NOT NULL DEFAULT '[]'::jsonb,
  steps        text[] NOT NULL DEFAULT '{}',
  i18n         jsonb NOT NULL DEFAULT '{}'::jsonb,
  updated_at   timestamptz NOT NULL DEFAULT now()
);

COMMENT ON COLUMN public.prep_recipes.steps IS
  'Method, in order. These carry the instructions that actually cost money when misread - ladle size, scorch warnings, shelf life - so the Spanish has to be exact, not approximate.';
COMMENT ON COLUMN public.prep_recipes.i18n IS
  'e.g. {"es":{"name":"...","batch_yield":"...","shelf_life":"...","steps":["...","..."],"ingredients":[{"name":"..."}]}} - steps must be the same length and order as the English.';

-- One row per item per service day: what is on hand, what got prepped.
CREATE TABLE IF NOT EXISTS public.prep_day (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id     uuid NOT NULL,
  service_date  date NOT NULL DEFAULT current_date,
  prep_item_id  uuid NOT NULL REFERENCES public.prep_items(id) ON DELETE CASCADE,
  on_hand       numeric NOT NULL DEFAULT 0,
  prepped       numeric NOT NULL DEFAULT 0,
  status        varchar NOT NULL DEFAULT 'not_started'
                CHECK (status IN ('not_started','in_progress','complete','flagged')),
  completed_at  timestamptz,
  completed_by  text,
  note          text
);
CREATE UNIQUE INDEX IF NOT EXISTS prep_day_unique ON public.prep_day (client_id, service_date, prep_item_id);
CREATE INDEX IF NOT EXISTS prep_day_today_idx ON public.prep_day (client_id, service_date);

/**
 * Resolve a row into one language, falling back to English field by field so a
 * half-translated recipe still renders - it shows English for the lines nobody
 * has translated yet rather than a blank on the wall.
 */
CREATE OR REPLACE FUNCTION public.mise_i18n(p_i18n jsonb, p_lang text, p_field text, p_fallback text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce(nullif(p_i18n -> p_lang ->> p_field, ''), p_fallback);
$$;

CREATE OR REPLACE FUNCTION public.mise_i18n_array(p_i18n jsonb, p_lang text, p_field text, p_fallback text[])
RETURNS text[] LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN jsonb_typeof(p_i18n -> p_lang -> p_field) = 'array'
     AND jsonb_array_length(p_i18n -> p_lang -> p_field) = coalesce(array_length(p_fallback,1),0)
    THEN ARRAY(SELECT jsonb_array_elements_text(p_i18n -> p_lang -> p_field))
    ELSE p_fallback
  END;
$$;

COMMENT ON FUNCTION public.mise_i18n_array IS
  'Returns the translated steps only when the count matches the English exactly. A recipe with a missing or extra step is a safety problem, so a mismatched translation is refused and the English is served instead.';
