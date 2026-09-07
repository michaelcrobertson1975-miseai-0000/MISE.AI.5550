-- Product Mix needs a real menu price per POS button to compute Revenue and
-- Food Cost % -- nightly_product_mix only ever stored qty_sold, never a
-- price. Rather than fabricate numbers, add the table so real prices (once
-- the restaurant provides them) make those columns real. Until then the
-- product-mix edge function reports units sold honestly and leaves revenue
-- null instead of guessing -- same rule this project already uses for
-- beverage_boms waiting on real menu names.
CREATE TABLE public.menu_items (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id          uuid NOT NULL REFERENCES public.clients(id) ON DELETE CASCADE,
  pos_button         text NOT NULL,
  display_name       text,
  category           text,
  menu_price         numeric,
  food_cost_per_unit numeric,
  active             boolean NOT NULL DEFAULT true,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  UNIQUE (client_id, pos_button)
);
COMMENT ON TABLE public.menu_items IS 'Real menu price per POS button, keyed to whatever nightly_product_mix.pos_button actually says. Empty until the restaurant supplies real menu prices -- Product Mix reports units sold from real data regardless, but Revenue/Food Cost % stay null per item until a price row exists here.';
ALTER TABLE public.menu_items ENABLE ROW LEVEL SECURITY;
CREATE INDEX menu_items_client_idx ON public.menu_items(client_id);
