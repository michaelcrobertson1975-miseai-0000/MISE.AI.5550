-- Price Moves needs a stable identity for "the same thing bought again".
-- vendor_item_code is per-distributor, so it cannot track a switch from Sysco to
-- US Foods; an ingredient row is the canonical key a price series hangs on.

CREATE TABLE IF NOT EXISTS public.ingredients (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id   uuid NOT NULL,
  name        text NOT NULL,
  base_unit   varchar,
  pnl_category varchar,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS ingredients_client_name_key
  ON public.ingredients (client_id, lower(name));

COMMENT ON TABLE public.ingredients IS
  'Canonical ingredient a line item is matched to. Price Moves compares cost_per_base_unit across invoices grouped by this id, so a vendor change does not break the series.';

ALTER TABLE public.invoice_line_items
  ADD COLUMN IF NOT EXISTS ingredient_id uuid REFERENCES public.ingredients(id),
  ADD COLUMN IF NOT EXISTS matched_at    timestamptz;

COMMENT ON COLUMN public.invoice_line_items.ingredient_id IS
  'Set by a reviewer in the queue. Null means unmatched - the line is costed but does not yet feed a price series.';
COMMENT ON COLUMN public.invoice_line_items.matched_at IS
  'When a human confirmed the ingredient match.';

CREATE INDEX IF NOT EXISTS line_items_ingredient_idx ON public.invoice_line_items (ingredient_id);
CREATE INDEX IF NOT EXISTS line_items_unmatched_idx  ON public.invoice_line_items (invoice_id) WHERE ingredient_id IS NULL;

-- Price Moves reads from here: one row per ingredient per purchase, in base units.
CREATE OR REPLACE VIEW public.ingredient_price_history AS
  SELECT li.ingredient_id,
         ing.name              AS ingredient_name,
         inv.client_id,
         inv.invoice_date,
         inv.vendor_name,
         li.vendor_item_code,
         li.cost_per_base_unit,
         li.standardized_base_unit,
         li.total_base_units,
         li.line_total,
         li.id                 AS line_item_id,
         inv.id                AS invoice_id
    FROM public.invoice_line_items li
    JOIN public.invoices    inv ON inv.id = li.invoice_id
    JOIN public.ingredients ing ON ing.id = li.ingredient_id
   WHERE li.ingredient_id IS NOT NULL
     AND li.removed_by_review IS NOT TRUE
     AND li.cost_per_base_unit IS NOT NULL;

COMMENT ON VIEW public.ingredient_price_history IS
  'Flattened price series for the Price Moves tab. Only matched, non-removed lines with a computed cost per base unit.';
