-- Correction: Order Food should be built on the REAL ingredients table (63
-- rows already tied to real invoices for this client) rather than a parallel
-- table shaped like the app's old hardcoded demo data. Dropping the
-- stand-alone table from the previous migration.
DROP TABLE IF EXISTS public.order_guide_items;

-- Only add what genuinely doesn't exist anywhere yet: a par target, a human
-- on-hand count (no automated physical inventory exists), an optional
-- chef-defined display grouping, and the approve/skip state for this week's
-- order. Vendor and price are deliberately NOT duplicated here -- they stay
-- derived live from invoice_line_items/invoices (the same real data Price
-- Moves already reads), so there is exactly one source of truth for cost.
ALTER TABLE public.ingredients
  ADD COLUMN par            numeric,
  ADD COLUMN on_hand        numeric,
  ADD COLUMN order_category text,
  ADD COLUMN approved       boolean,
  ADD COLUMN skipped        boolean NOT NULL DEFAULT false,
  ADD COLUMN on_hand_updated_at timestamptz;
COMMENT ON COLUMN public.ingredients.par IS 'Order Food target level, entered by the restaurant. Null until they set one -- never defaulted to a guessed number.';
COMMENT ON COLUMN public.ingredients.on_hand IS 'Order Food human stock count. Nobody has automated physical inventory in this project, so this is chef-entered, persisted so it is shared across devices instead of one browser''s localStorage.';

-- View the order-guide edge function reads from: each ingredient plus its
-- most recent price/vendor from a completed invoice line, computed live so
-- it can never drift from Price Moves' own numbers.
CREATE VIEW public.v_ingredient_last_price AS
SELECT DISTINCT ON (li.ingredient_id)
  li.ingredient_id,
  i.vendor_name,
  li.raw_unit_price AS last_unit_price,
  li.raw_uom        AS last_purchase_unit,
  li.cost_per_base_unit,
  i.invoice_date    AS last_invoice_date
FROM public.invoice_line_items li
JOIN public.invoices i ON i.id = li.invoice_id
WHERE li.ingredient_id IS NOT NULL
  AND i.status = 'completed'
ORDER BY li.ingredient_id, i.invoice_date DESC NULLS LAST, i.created_at DESC;
COMMENT ON VIEW public.v_ingredient_last_price IS 'Latest real vendor + price per ingredient, from the same completed-invoice data Price Moves reads. Order Food joins against this instead of storing its own copy.';
