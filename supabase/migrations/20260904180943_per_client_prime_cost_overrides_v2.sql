-- Whether a category is COGS depends on the concept, not on the category.
-- A coffee shop's cup and lid are in the BOM for the drink, so they are cost of
-- goods and belong in prime cost. The same to-go clamshell at a steakhouse is an
-- operating supply. pnl_categories.in_prime_cost is only the default; this table
-- is how one client says otherwise.
CREATE TABLE IF NOT EXISTS public.client_category_settings (
  client_id     uuid    NOT NULL,
  category_code varchar NOT NULL REFERENCES public.pnl_categories(code) ON DELETE CASCADE,
  in_prime_cost boolean NOT NULL,
  in_bom        boolean NOT NULL DEFAULT false,
  note          text,
  updated_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (client_id, category_code)
);

COMMENT ON COLUMN public.client_category_settings.in_bom IS
  'True when this category appears in a recipe/bill of materials for this concept - a cup and lid in a latte. Recording the reason, not just the effect, so the override is auditable later.';

-- Column set changes, so the view is replaced rather than redefined in place.
DROP VIEW IF EXISTS public.pnl_period_summary;

CREATE VIEW public.pnl_period_summary AS
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
       COALESCE(p.labor_kitchen,0)+COALESCE(p.labor_management,0)+COALESCE(p.labor_front_house,0) AS labor_total,
       COALESCE(SUM(c.amount) FILTER (WHERE c.counts_in_prime),0)
         + COALESCE(p.labor_kitchen,0)+COALESCE(p.labor_management,0)+COALESCE(p.labor_front_house,0) AS prime_cost_total,
       CASE WHEN COALESCE(p.gross_sales,0) > 0 THEN
         ROUND(((COALESCE(SUM(c.amount) FILTER (WHERE c.counts_in_prime),0)
           + COALESCE(p.labor_kitchen,0)+COALESCE(p.labor_management,0)+COALESCE(p.labor_front_house,0))
           / p.gross_sales) * 100, 2)
       END AS prime_cost_percentage,
       r.invoices_total, r.invoices_unreviewed, r.lines_uncategorized,
       (r.invoices_unreviewed = 0 AND r.lines_uncategorized = 0 AND p.gross_sales IS NOT NULL) AS ready_to_close
  FROM public.pnl_periods p
  LEFT JOIN costed c    ON c.period_id = p.id
  LEFT JOIN readiness r ON r.period_id = p.id
 GROUP BY p.id, p.client_id, p.period_start, p.period_end, p.label, p.length_weeks,
          p.is_closed, p.gross_sales, p.labor_kitchen, p.labor_management, p.labor_front_house,
          r.invoices_total, r.invoices_unreviewed, r.lines_uncategorized;

COMMENT ON VIEW public.pnl_period_summary IS
  'Prime cost = everything this client counts as COGS + labor, over gross sales. What counts as COGS is resolved per client, so a coffee shop with cups in the BOM and a steakhouse with to-go containers as supplies both get a correct number from the same query.';
