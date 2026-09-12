-- THE KITCHEN LOOP.
--
-- The bar could already do this: beverage_boms said how many base units a POS
-- button pours, mise_apply_nightly_depletion subtracted them from
-- beverage_items, and beverage_items carried cost_per_base_unit.
--
-- The kitchen could not. There was no food equivalent of beverage_boms, and
-- nothing anywhere wrote to ingredients.on_hand -- zero functions touched it.
-- Sell 30 burgers and nothing came off the beef, ever.
--
-- This adds the missing half, shaped exactly like the working bar half.
-- NOTE: superseded in part by the two migrations that follow it, which fix a
-- NOT NULL that rejected every food row, a backwards yield calculation, and a
-- foreign key that only accepted beverage BOMs. Read all three together.

CREATE TABLE IF NOT EXISTS public.menu_item_boms (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id           uuid NOT NULL REFERENCES public.clients(id) ON DELETE CASCADE,
  pos_item_name       text NOT NULL,
  menu_item_id        uuid REFERENCES public.menu_items(id) ON DELETE SET NULL,
  ingredient_id       uuid NOT NULL REFERENCES public.ingredients(id) ON DELETE CASCADE,
  portion_size        text,
  yield_factor        numeric NOT NULL DEFAULT 1.0,
  base_units_consumed numeric NOT NULL,
  notes               text,
  created_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT menu_item_boms_consumes_something CHECK (base_units_consumed > 0),
  CONSTRAINT menu_item_boms_yield_sane CHECK (yield_factor > 0 AND yield_factor <= 10)
);

COMMENT ON TABLE public.menu_item_boms IS
  'What one sale of a POS button consumes from inventory, in the ingredient base unit. The kitchen twin of beverage_boms.';

CREATE INDEX IF NOT EXISTS menu_item_boms_lookup
  ON public.menu_item_boms (client_id, lower(pos_item_name));

ALTER TABLE public.menu_item_boms ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.menu_item_boms FROM anon, authenticated;
GRANT ALL ON public.menu_item_boms TO service_role;

ALTER TABLE public.nightly_product_mix_depletions
  ADD COLUMN IF NOT EXISTS menu_item_bom_id   uuid REFERENCES public.menu_item_boms(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS ingredient_id      uuid REFERENCES public.ingredients(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS kind               varchar,
  ADD COLUMN IF NOT EXISTS cost_per_base_unit numeric,
  ADD COLUMN IF NOT EXISTS dollar_value       numeric;

COMMENT ON COLUMN public.nightly_product_mix_depletions.cost_per_base_unit IS
  'Cost captured AT DEPLETION TIME, not looked up later. Prices move; what a plate cost on the night it sold is the number that belongs in a food cost.';
