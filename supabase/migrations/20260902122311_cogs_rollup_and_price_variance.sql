-- ── COGS by period, straight from verified invoices ──────────────────────────
-- Only 'completed' invoices count. Anything sitting in the review queue is
-- excluded on purpose: unverified numbers must never reach the P&L.
CREATE OR REPLACE VIEW v_period_cogs AS
SELECT i.client_id,
       to_char(i.invoice_date, 'YYYY-MM')                      AS period_year_month,
       sum(li.line_total) FILTER (WHERE li.pnl_category = 'FOOD')     AS cogs_food,
       sum(li.line_total) FILTER (WHERE li.pnl_category = 'BEVERAGE') AS cogs_beverage,
       sum(li.line_total) FILTER (WHERE li.pnl_category = 'SUPPLIES') AS supplies,
       sum(li.line_total) FILTER (WHERE li.pnl_category = 'FREIGHT')  AS freight,
       sum(li.line_total)                                             AS total_purchases,
       count(DISTINCT i.id)                                           AS invoice_count
FROM invoices i
JOIN invoice_line_items li ON li.invoice_id = i.id
WHERE i.status = 'completed' AND i.invoice_date IS NOT NULL
GROUP BY i.client_id, to_char(i.invoice_date, 'YYYY-MM');

-- ── oz in / oz out: what the SAME item costs per base unit, delivery to delivery ──
-- This is the variance engine. Joins on the vendor item code so a rename or a
-- pack change cannot hide a price move, and reports the dollar impact of the
-- move on the quantity actually purchased.
CREATE OR REPLACE VIEW v_item_price_variance AS
WITH purchases AS (
  SELECT i.client_id,
         li.vendor_item_code,
         li.item_description,
         i.invoice_date,
         i.invoice_number,
         li.standardized_base_unit,
         li.total_base_units,
         li.cost_per_base_unit,
         li.line_total,
         lag(li.cost_per_base_unit) OVER w AS prev_cost_per_base_unit,
         lag(i.invoice_date)        OVER w AS prev_invoice_date
  FROM invoices i
  JOIN invoice_line_items li ON li.invoice_id = i.id
  WHERE i.status = 'completed'
    AND li.vendor_item_code IS NOT NULL
    AND li.cost_per_base_unit IS NOT NULL
  WINDOW w AS (PARTITION BY i.client_id, li.vendor_item_code ORDER BY i.invoice_date, i.id)
)
SELECT *,
       round(cost_per_base_unit - prev_cost_per_base_unit, 4) AS unit_cost_delta,
       CASE WHEN prev_cost_per_base_unit > 0
            THEN round(((cost_per_base_unit - prev_cost_per_base_unit) / prev_cost_per_base_unit) * 100, 2)
       END AS unit_cost_delta_pct,
       -- What the price move cost (or saved) on this delivery's volume.
       round((cost_per_base_unit - prev_cost_per_base_unit) * total_base_units, 2) AS dollar_impact
FROM purchases
WHERE prev_cost_per_base_unit IS NOT NULL;

-- ── Push verified COGS into the P&L snapshot ────────────────────────────────
-- Sales and labor are human inputs and are never overwritten here; only the
-- invoice-derived numbers and the resulting prime cost are recomputed.
CREATE OR REPLACE FUNCTION mise_refresh_pnl(p_client_id UUID, p_period VARCHAR(7))
RETURNS TABLE (
  period VARCHAR(7), cogs_food NUMERIC, cogs_beverage NUMERIC,
  prime_cost_total NUMERIC, prime_cost_percentage NUMERIC, gross_sales NUMERIC
) AS $$
BEGIN
  INSERT INTO monthly_pnl_snapshots AS s (client_id, period_year_month, cogs_food, cogs_beverage, updated_at)
  SELECT p_client_id, p_period,
         coalesce(c.cogs_food, 0), coalesce(c.cogs_beverage, 0), NOW()
  FROM (SELECT * FROM v_period_cogs
         WHERE client_id = p_client_id AND period_year_month = p_period) c
  ON CONFLICT (client_id, period_year_month) DO UPDATE
     SET cogs_food = EXCLUDED.cogs_food,
         cogs_beverage = EXCLUDED.cogs_beverage,
         updated_at = NOW()
   WHERE s.is_closed = FALSE;

  UPDATE monthly_pnl_snapshots s
     SET prime_cost_percentage = CASE WHEN s.gross_sales > 0
            THEN round((s.prime_cost_total / s.gross_sales) * 100, 2) END,
         updated_at = NOW()
   WHERE s.client_id = p_client_id AND s.period_year_month = p_period;

  RETURN QUERY
    SELECT s.period_year_month, s.cogs_food, s.cogs_beverage,
           s.prime_cost_total, s.prime_cost_percentage, s.gross_sales
      FROM monthly_pnl_snapshots s
     WHERE s.client_id = p_client_id AND s.period_year_month = p_period;
END;
$$ LANGUAGE plpgsql;
