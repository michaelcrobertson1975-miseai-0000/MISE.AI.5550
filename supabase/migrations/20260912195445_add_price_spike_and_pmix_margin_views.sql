-- Dashboard views: ingredient price-spike history and PMIX gross-margin
-- ranking. Both are read-only aggregates over data the existing invoice and
-- nightly-depletion triggers already produce -- no new writes, no change to
-- receiving or depletion logic.
--
-- security_invoker = true on both, matching every other view in this schema
-- (see 20260906065435_fix_security_definer_views.sql): without it a view
-- checks RLS as its owner, not the querying user, which can leak
-- cross-client rows even though the base tables have RLS enabled.

CREATE OR REPLACE VIEW public.v_ingredient_price_spikes
WITH (security_invoker = true) AS
WITH priced_lines AS (
  SELECT
    li.ingredient_id,
    i.client_id,
    i.id                    AS invoice_id,
    i.invoice_date,
    li.cost_per_base_unit   AS current_cost_per_base_unit,
    LAG(li.cost_per_base_unit) OVER (
      PARTITION BY li.ingredient_id
      ORDER BY i.invoice_date, li.created_at
    )                       AS previous_cost_per_base_unit
  FROM public.invoice_line_items li
  JOIN public.invoices i ON i.id = li.invoice_id
  WHERE li.ingredient_id IS NOT NULL
    AND li.cost_per_base_unit IS NOT NULL
    AND li.removed_by_review IS NOT TRUE
    AND i.status = 'completed'
    AND i.invoice_date IS NOT NULL
)
SELECT
  pl.ingredient_id,
  ing.name AS ingredient_name,
  pl.client_id,
  pl.invoice_id,
  pl.invoice_date,
  pl.current_cost_per_base_unit,
  pl.previous_cost_per_base_unit,
  round(
    100.0 * (pl.current_cost_per_base_unit - pl.previous_cost_per_base_unit)
    / NULLIF(pl.previous_cost_per_base_unit, 0)
  , 2) AS percentage_change
FROM priced_lines pl
LEFT JOIN public.ingredients ing ON ing.id = pl.ingredient_id;

COMMENT ON VIEW public.v_ingredient_price_spikes IS
  'Per-ingredient cost_per_base_unit trend across completed invoices, one row per priced line, with LAG()-computed previous price and percentage_change. Undated or removed-by-review lines are excluded rather than arbitrarily ordered.';

CREATE OR REPLACE VIEW public.v_pmix_margins
WITH (security_invoker = true) AS
WITH sold AS (
  SELECT nr.client_id, npm.pos_button, SUM(npm.qty_sold) AS total_qty_sold
  FROM public.nightly_product_mix npm
  JOIN public.nightly_reports nr ON nr.id = npm.nightly_report_id
  GROUP BY nr.client_id, npm.pos_button
),
cogs AS (
  SELECT nr.client_id, npm.pos_button, SUM(d.dollar_value) AS total_cogs
  FROM public.nightly_product_mix_depletions d
  JOIN public.nightly_product_mix npm ON npm.id = d.nightly_product_mix_id
  JOIN public.nightly_reports nr ON nr.id = npm.nightly_report_id
  GROUP BY nr.client_id, npm.pos_button
)
SELECT
  s.client_id,
  s.pos_button,
  COALESCE(mi.display_name, s.pos_button) AS menu_item_name,
  s.total_qty_sold,
  c.total_cogs,
  mi.menu_price,
  CASE WHEN mi.menu_price IS NOT NULL
       THEN round(mi.menu_price * s.total_qty_sold, 2) END AS total_revenue,
  CASE WHEN mi.menu_price IS NOT NULL AND c.total_cogs IS NOT NULL
            AND mi.menu_price * s.total_qty_sold <> 0
       THEN round(
         100.0 * (mi.menu_price * s.total_qty_sold - c.total_cogs)
         / (mi.menu_price * s.total_qty_sold)
       , 2)
  END AS gross_margin_pct
FROM sold s
LEFT JOIN cogs c
  ON c.client_id = s.client_id AND c.pos_button = s.pos_button
LEFT JOIN public.menu_items mi
  ON mi.client_id = s.client_id AND lower(mi.pos_button) = lower(s.pos_button);

COMMENT ON VIEW public.v_pmix_margins IS
  'Per-POS-button quantity sold, total COGS (summed from nightly_product_mix_depletions), and gross margin using menu_items.menu_price. total_cogs and gross_margin_pct are NULL (not 0/100%) when a POS button has no matched BOM or no known ingredient cost, so an unmapped item never displays a false 100% margin.';
