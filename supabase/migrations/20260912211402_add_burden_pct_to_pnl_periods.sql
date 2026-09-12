-- Prime cost is COGS + labor, but "labor" only meant raw wages typed into
-- labor_kitchen/labor_management/labor_front_house -- payroll tax and
-- benefits (the "burden" the Schedule tab's disconnected what-if slider
-- already estimates client-side, in localStorage only, per its own
-- comment: "not restaurant data, just a what-if slider") never reached
-- prime cost. That silently understated prime cost every period.
--
-- burden_pct is owner-set per period, nullable (null = 0%, no invented
-- default), and grosses up the labor total this view feeds into prime
-- cost. Nothing about staff/shifts/hourly_rate is required -- this works
-- whether labor dollars come from manual entry today or nightly BOH/FOH
-- hours later.
ALTER TABLE public.pnl_periods ADD COLUMN IF NOT EXISTS burden_pct numeric;
COMMENT ON COLUMN public.pnl_periods.burden_pct IS
  'Payroll tax + benefits load, as a percentage applied on top of the raw wages in labor_kitchen/labor_management/labor_front_house. Owner-set per period; null is treated as 0%, never assumed.';

DROP VIEW IF EXISTS public.pnl_period_summary;

CREATE VIEW public.pnl_period_summary
WITH (security_invoker = true) AS
WITH cat AS (
  SELECT p.id AS period_id, c.code, c.pnl_bucket,
         COALESCE(s.in_prime_cost, c.in_prime_cost) AS counts_in_prime
    FROM public.pnl_periods p
    CROSS JOIN public.pnl_categories c
    LEFT JOIN public.client_category_settings s
      ON s.client_id = p.client_id AND s.category_code = c.code
),
invoiced AS (
  SELECT p.id AS period_id, li.pnl_category AS code, SUM(li.line_total) AS amount
    FROM public.pnl_periods p
    JOIN public.invoices inv
      ON inv.client_id = p.client_id
     AND inv.invoice_date BETWEEN p.period_start AND p.period_end
    JOIN public.invoice_line_items li ON li.invoice_id = inv.id
   WHERE li.removed_by_review IS NOT TRUE
   GROUP BY p.id, li.pnl_category
),
manual AS (
  SELECT m.period_id, m.category AS code, SUM(m.amount) AS amount
    FROM public.pnl_manual_costs m
   GROUP BY m.period_id, m.category
),
combined AS (
  SELECT period_id, code, SUM(amount) AS amount
    FROM (SELECT * FROM invoiced UNION ALL SELECT * FROM manual) x
   GROUP BY period_id, code
),
costed AS (
  SELECT cb.period_id, cb.amount,
         COALESCE(cat.pnl_bucket,'unclassified') AS bucket,
         COALESCE(cat.counts_in_prime,false)     AS counts_in_prime
    FROM combined cb
    LEFT JOIN cat ON cat.period_id = cb.period_id AND cat.code = cb.code
),
readiness AS (
  SELECT p.id AS period_id,
         COUNT(DISTINCT inv.id) FILTER (WHERE inv.status <> 'completed') AS invoices_unreviewed,
         COUNT(DISTINCT inv.id)                                          AS invoices_total,
         COUNT(li.id) FILTER (WHERE li.pnl_category IS NULL
                                AND li.removed_by_review IS NOT TRUE)    AS lines_uncategorized
    FROM public.pnl_periods p
    LEFT JOIN public.invoices inv
      ON inv.client_id = p.client_id
     AND inv.invoice_date BETWEEN p.period_start AND p.period_end
    LEFT JOIN public.invoice_line_items li ON li.invoice_id = inv.id
   GROUP BY p.id
)
SELECT p.id, p.client_id, p.period_start, p.period_end, p.label, p.length_weeks,
       p.is_closed, p.gross_sales,
       COALESCE(SUM(c.amount) FILTER (WHERE c.bucket='cogs_food'),0)     AS cogs_food,
       COALESCE(SUM(c.amount) FILTER (WHERE c.bucket='cogs_beverage'),0) AS cogs_beverage,
       COALESCE(SUM(c.amount) FILTER (WHERE c.bucket='supplies'),0)      AS supplies_total,
       COALESCE(SUM(c.amount) FILTER (WHERE c.bucket='other'),0)         AS other_costs,
       COALESCE(SUM(c.amount) FILTER (WHERE c.bucket='unclassified'),0)  AS unclassified_costs,
       COALESCE(SUM(c.amount) FILTER (WHERE c.counts_in_prime),0)        AS cogs_in_prime,
       p.burden_pct,
       COALESCE(p.labor_kitchen,0)+COALESCE(p.labor_management,0)+COALESCE(p.labor_front_house,0) AS labor_raw,
       ROUND((COALESCE(p.labor_kitchen,0)+COALESCE(p.labor_management,0)+COALESCE(p.labor_front_house,0))
             * (1 + COALESCE(p.burden_pct,0)/100), 2) AS labor_total,
       COALESCE(SUM(c.amount) FILTER (WHERE c.counts_in_prime),0)
         + ROUND((COALESCE(p.labor_kitchen,0)+COALESCE(p.labor_management,0)+COALESCE(p.labor_front_house,0))
               * (1 + COALESCE(p.burden_pct,0)/100), 2) AS prime_cost_total,
       CASE WHEN COALESCE(p.gross_sales,0) > 0 THEN
         ROUND(((COALESCE(SUM(c.amount) FILTER (WHERE c.counts_in_prime),0)
           + ROUND((COALESCE(p.labor_kitchen,0)+COALESCE(p.labor_management,0)+COALESCE(p.labor_front_house,0))
                 * (1 + COALESCE(p.burden_pct,0)/100), 2))
           / p.gross_sales) * 100, 2)
       END AS prime_cost_percentage,
       r.invoices_total, r.invoices_unreviewed, r.lines_uncategorized,
       (r.invoices_unreviewed = 0 AND r.lines_uncategorized = 0 AND p.gross_sales IS NOT NULL) AS ready_to_close
  FROM public.pnl_periods p
  LEFT JOIN costed c    ON c.period_id = p.id
  LEFT JOIN readiness r ON r.period_id = p.id
 GROUP BY p.id, p.client_id, p.period_start, p.period_end, p.label, p.length_weeks,
          p.is_closed, p.gross_sales, p.labor_kitchen, p.labor_management, p.labor_front_house, p.burden_pct,
          r.invoices_total, r.invoices_unreviewed, r.lines_uncategorized;

COMMENT ON VIEW public.pnl_period_summary IS
  'Prime cost = everything this client counts as COGS + fully-loaded labor, over gross sales. labor_raw is what the owner typed in; labor_total and prime_cost_total gross that up by burden_pct so payroll tax/benefits are no longer silently excluded. What counts as COGS is resolved per client via client_category_settings.';
