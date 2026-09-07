CREATE TABLE public.nightly_product_mix_depletions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  nightly_product_mix_id uuid NOT NULL REFERENCES public.nightly_product_mix(id) ON DELETE CASCADE,
  beverage_bom_id uuid NOT NULL REFERENCES public.beverage_boms(id),
  beverage_item_id uuid NOT NULL REFERENCES public.beverage_items(id),
  base_units_depleted numeric NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.nightly_product_mix_depletions IS 'One row per ingredient actually drained for one sale. A multi-ingredient cocktail produces multiple rows here for the same nightly_product_mix_id.';
ALTER TABLE public.nightly_product_mix_depletions ENABLE ROW LEVEL SECURITY;
