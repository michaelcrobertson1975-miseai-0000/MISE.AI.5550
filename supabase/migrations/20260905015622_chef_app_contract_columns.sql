-- The chef app sends a finer category vocabulary than the P&L uses:
--   produce, protein, dairy, dry_goods, beverage, non_cogs_fee, other, uncategorized
-- The P&L rolls up to FOOD / BEVERAGE / SUPPLIES / FREIGHT, and v_period_cogs and
-- mise_refresh_pnl both depend on those four. So the app's choice is stored as
-- chef_category and pnl_category is derived from it - fine grain for the chef,
-- coarse grain for the accountant, one edit feeding both.

ALTER TABLE public.invoice_line_items
  ADD COLUMN IF NOT EXISTS chef_category   varchar,
  ADD COLUMN IF NOT EXISTS beverage_type   varchar,
  ADD COLUMN IF NOT EXISTS beverage_class  varchar;

COMMENT ON COLUMN public.invoice_line_items.chef_category IS
  'The app''s vocabulary: produce, protein, dairy, dry_goods, beverage, non_cogs_fee, other, uncategorized. Set by a human in the Review Queue; pnl_category is derived from it.';
COMMENT ON COLUMN public.invoice_line_items.beverage_type IS 'Free text from the Review Queue, e.g. wine, beer, spirit. Only meaningful when chef_category = beverage.';
COMMENT ON COLUMN public.invoice_line_items.beverage_class IS 'Sub-classification within beverage_type, e.g. red, white, sparkling.';

CREATE INDEX IF NOT EXISTS line_items_chef_category_idx ON public.invoice_line_items (chef_category);

/** Roll the chef's category up to the four P&L buckets the reports depend on. */
CREATE OR REPLACE FUNCTION public.mise_pnl_bucket(p_chef_category text)
RETURNS varchar LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE lower(coalesce(p_chef_category,''))
           WHEN 'produce'      THEN 'FOOD'
           WHEN 'protein'      THEN 'FOOD'
           WHEN 'dairy'        THEN 'FOOD'
           WHEN 'dry_goods'    THEN 'FOOD'
           WHEN 'beverage'     THEN 'BEVERAGE'
           WHEN 'non_cogs_fee' THEN 'FREIGHT'
           WHEN 'other'        THEN 'SUPPLIES'
           ELSE NULL
         END::varchar;
$$;

/**
 * Extends the existing trigger rather than replacing it. Unchanged behaviour:
 * fill vendor_item_code and pnl_category when they are null. Added: when a human
 * sets chef_category in the Review Queue, that decision wins and pnl_category is
 * recomputed from it, so a correction reaches the P&L without a second edit.
 */
CREATE OR REPLACE FUNCTION public.mise_line_item_defaults()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.vendor_item_code IS NULL THEN
    NEW.vendor_item_code := mise_item_code(NEW.item_description);
  END IF;

  -- A human's chef_category is the authority.
  IF NEW.chef_category IS NOT NULL AND lower(NEW.chef_category) <> 'uncategorized' THEN
    NEW.pnl_category := coalesce(mise_pnl_bucket(NEW.chef_category), NEW.pnl_category);
  ELSIF NEW.pnl_category IS NULL THEN
    NEW.pnl_category := mise_pnl_category(NEW.vendor_category, NEW.item_description);
  END IF;

  RETURN NEW;
END;
$$;

-- A fee is "mapped" without an ingredient; everything else needs one.
COMMENT ON FUNCTION public.mise_line_item_defaults IS
  'Fills vendor_item_code, and keeps pnl_category in step with the chef_category a human picked in the Review Queue.';
