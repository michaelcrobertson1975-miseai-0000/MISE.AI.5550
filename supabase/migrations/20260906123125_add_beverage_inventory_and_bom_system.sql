-- One item per thing you stock behind the bar or on the coffee station.
-- base_unit reuses the same system as invoice line items (FL_OZ / WT_OZ /
-- COUNT) so a bottle of vodka and a bag of coffee beans both fit here.
CREATE TABLE public.beverage_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id uuid NOT NULL REFERENCES public.clients(id),
  name text NOT NULL,
  category varchar NOT NULL CHECK (category IN (
    'keg_beer','bottle_beer','wine','spirits','fountain_syrup','coffee_beans','juice','other'
  )),
  base_unit varchar NOT NULL CHECK (base_unit IN ('FL_OZ','WT_OZ','COUNT')),
  total_base_units_in_stock numeric NOT NULL DEFAULT 0,
  cost_per_base_unit numeric,
  ingredient_id uuid REFERENCES public.ingredients(id),
  updated_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.beverage_items IS 'What is behind the bar / on the coffee station right now, in the same base-unit system invoices already use. ingredient_id links this to the invoice-costing pipeline once wired up -- not automatic yet.';
COMMENT ON COLUMN public.beverage_items.total_base_units_in_stock IS 'Manually adjusted for now. Auto-updating this from incoming invoices is a separate, not-yet-built integration step.';

-- One row per POS button (or manual sale entry). serving_size_oz is what the
-- CUSTOMER gets; yield_factor is what that actually costs you from stock.
-- For a direct pour (wine, spirits, keg beer): yield_factor = 1, a straight
-- 1:1 depletion. For fountain syrup or coffee beans, yield_factor is the real
-- conversion (e.g. syrup-to-total-drink ratio, or beans-per-brewed-ounce) --
-- this is exactly the nuance that would have been silently wrong if every
-- category used the same 1:1 assumption.
CREATE TABLE public.beverage_boms (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id uuid NOT NULL REFERENCES public.clients(id),
  pos_item_name text NOT NULL,
  beverage_item_id uuid NOT NULL REFERENCES public.beverage_items(id),
  serving_size_oz numeric NOT NULL,
  yield_factor numeric NOT NULL DEFAULT 1,
  base_units_consumed numeric GENERATED ALWAYS AS (serving_size_oz * yield_factor) STORED,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.beverage_boms IS 'One row per sellable pour/drink. base_units_consumed is what actually comes out of beverage_items.total_base_units_in_stock per sale -- NOT the same as serving_size_oz for fountain drinks or coffee.';
COMMENT ON COLUMN public.beverage_boms.yield_factor IS 'Direct pour (wine/spirits/keg): 1. Fountain syrup: the mix ratio (e.g. 0.2 if 1 part syrup makes 5 parts drink). Coffee: oz of beans consumed per oz brewed and served.';

-- Structure only -- these columns exist so variance tracking has somewhere
-- to go the moment a real POS feed exists. pos_ounces_sold has no automatic
-- source yet; leaving that unfilled is honest, not a bug.
CREATE TABLE public.beverage_variance_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id uuid NOT NULL REFERENCES public.clients(id),
  beverage_item_id uuid NOT NULL REFERENCES public.beverage_items(id),
  period_start date NOT NULL,
  period_end date NOT NULL,
  starting_base_units numeric,
  invoiced_base_units_in numeric,
  ending_base_units numeric,
  pos_base_units_sold numeric,
  variance_base_units numeric GENERATED ALWAYS AS (
    coalesce(starting_base_units,0) + coalesce(invoiced_base_units_in,0)
    - coalesce(ending_base_units,0) - coalesce(pos_base_units_sold,0)
  ) STORED,
  cost_impact numeric,
  created_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.beverage_variance_log IS 'Blocked on a real POS feed for pos_base_units_sold -- this table is ready to receive that data the moment it exists, but nothing populates it automatically today.';

ALTER TABLE public.beverage_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.beverage_boms ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.beverage_variance_log ENABLE ROW LEVEL SECURITY;
-- No anon/authenticated policies added on purpose, matching every other real
-- data table in this project -- only service-role (your own backend) reads
-- or writes these until a real access pattern is designed.
