-- ── Categories, as data rather than a hard-coded list ──────────────────────
-- The review page reads these, so adding TO-GO or splitting PAPER is an INSERT,
-- not a redeploy.
CREATE TABLE IF NOT EXISTS public.pnl_categories (
  code          varchar PRIMARY KEY,
  label         text NOT NULL,
  pnl_bucket    varchar NOT NULL,
  in_prime_cost boolean NOT NULL DEFAULT false,
  sort_order    smallint NOT NULL DEFAULT 100
);

COMMENT ON COLUMN public.pnl_categories.in_prime_cost IS
  'Prime cost is COGS + labor. Paper, to-go and cleaning are real costs and are tracked, but they are operating supplies - folding them into prime cost makes the number incomparable to every industry benchmark.';

INSERT INTO public.pnl_categories (code,label,pnl_bucket,in_prime_cost,sort_order) VALUES
  ('FOOD',       'Food',              'cogs_food',     true,  10),
  ('BEVERAGE',   'Beverage (N/A)',    'cogs_beverage', true,  20),
  ('ALCOHOL',    'Alcohol',           'cogs_beverage', true,  30),
  ('PAPER',      'Paper goods',       'supplies',      false, 40),
  ('TO_GO',      'To-go packaging',   'supplies',      false, 50),
  ('CLEANING',   'Cleaning / chem',   'supplies',      false, 60),
  ('SMALLWARES', 'Smallwares',        'supplies',      false, 70),
  ('FEE',        'Fees / surcharges', 'other',         false, 80),
  ('OTHER',      'Other',             'other',         false, 90)
ON CONFLICT (code) DO NOTHING;

-- ── Accounting periods: 1, 2 or 4 weeks, not calendar months ───────────────
CREATE TABLE IF NOT EXISTS public.pnl_periods (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id     uuid NOT NULL,
  period_start  date NOT NULL,
  period_end    date NOT NULL,
  label         text,
  length_weeks  smallint NOT NULL DEFAULT 4 CHECK (length_weeks IN (1,2,4)),
  gross_sales      numeric,
  labor_kitchen    numeric,
  labor_management numeric,
  labor_front_house numeric,
  is_closed     boolean NOT NULL DEFAULT false,
  closed_at     timestamptz,
  notes         text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  CHECK (period_end >= period_start)
);
CREATE UNIQUE INDEX IF NOT EXISTS pnl_periods_client_start_key ON public.pnl_periods (client_id, period_start);

COMMENT ON TABLE public.pnl_periods IS
  'One accounting period. Food cost is derived from invoices dated inside it; sales and labor are entered by the owner, which is the manual half of the P&L.';

-- Owner-entered costs that never arrive as an invoice: cash market runs,
-- a credit the distributor issued off-invoice, a farmer paid direct.
CREATE TABLE IF NOT EXISTS public.pnl_manual_costs (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  period_id    uuid NOT NULL REFERENCES public.pnl_periods(id) ON DELETE CASCADE,
  category     varchar REFERENCES public.pnl_categories(code),
  description  text,
  amount       numeric NOT NULL,
  entered_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS pnl_manual_costs_period_idx ON public.pnl_manual_costs (period_id);

-- ── The P&L itself ─────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW public.pnl_period_summary AS
WITH invoiced AS (
  SELECT p.id AS period_id,
         COALESCE(c.pnl_bucket,'unclassified') AS bucket,
         SUM(li.line_total) AS amount
    FROM public.pnl_periods p
    JOIN public.invoices inv
      ON inv.client_id = p.client_id
     AND inv.invoice_date BETWEEN p.period_start AND p.period_end
    JOIN public.invoice_line_items li ON li.invoice_id = inv.id
    LEFT JOIN public.pnl_categories c ON c.code = li.pnl_category
   WHERE li.removed_by_review IS NOT TRUE
   GROUP BY p.id, COALESCE(c.pnl_bucket,'unclassified')
),
manual AS (
  SELECT m.period_id,
         COALESCE(c.pnl_bucket,'unclassified') AS bucket,
         SUM(m.amount) AS amount
    FROM public.pnl_manual_costs m
    LEFT JOIN public.pnl_categories c ON c.code = m.category
   GROUP BY m.period_id, COALESCE(c.pnl_bucket,'unclassified')
),
combined AS (
  SELECT period_id, bucket, SUM(amount) AS amount
    FROM (SELECT * FROM invoiced UNION ALL SELECT * FROM manual) x
   GROUP BY period_id, bucket
),
readiness AS (
  SELECT p.id AS period_id,
         COUNT(*) FILTER (WHERE inv.status <> 'completed')        AS invoices_unreviewed,
         COUNT(*)                                                 AS invoices_total,
         COUNT(li.id) FILTER (WHERE li.pnl_category IS NULL
                                AND li.removed_by_review IS NOT TRUE) AS lines_uncategorized
    FROM public.pnl_periods p
    LEFT JOIN public.invoices inv
      ON inv.client_id = p.client_id
     AND inv.invoice_date BETWEEN p.period_start AND p.period_end
    LEFT JOIN public.invoice_line_items li ON li.invoice_id = inv.id
   GROUP BY p.id
)
SELECT p.id,
       p.client_id,
       p.period_start,
       p.period_end,
       p.label,
       p.length_weeks,
       p.is_closed,
       p.gross_sales,
       COALESCE(SUM(cb.amount) FILTER (WHERE cb.bucket='cogs_food'),0)     AS cogs_food,
       COALESCE(SUM(cb.amount) FILTER (WHERE cb.bucket='cogs_beverage'),0) AS cogs_beverage,
       COALESCE(SUM(cb.amount) FILTER (WHERE cb.bucket='supplies'),0)      AS supplies_total,
       COALESCE(SUM(cb.amount) FILTER (WHERE cb.bucket='other'),0)         AS other_costs,
       COALESCE(SUM(cb.amount) FILTER (WHERE cb.bucket='unclassified'),0)  AS unclassified_costs,
       COALESCE(p.labor_kitchen,0) + COALESCE(p.labor_management,0) + COALESCE(p.labor_front_house,0) AS labor_total,
       COALESCE(SUM(cb.amount) FILTER (WHERE cb.bucket IN ('cogs_food','cogs_beverage')),0)
         + COALESCE(p.labor_kitchen,0) + COALESCE(p.labor_management,0) + COALESCE(p.labor_front_house,0) AS prime_cost_total,
       CASE WHEN COALESCE(p.gross_sales,0) > 0 THEN
         ROUND(((COALESCE(SUM(cb.amount) FILTER (WHERE cb.bucket IN ('cogs_food','cogs_beverage')),0)
           + COALESCE(p.labor_kitchen,0) + COALESCE(p.labor_management,0) + COALESCE(p.labor_front_house,0))
           / p.gross_sales) * 100, 2)
       END AS prime_cost_percentage,
       r.invoices_total,
       r.invoices_unreviewed,
       r.lines_uncategorized,
       (r.invoices_unreviewed = 0 AND r.lines_uncategorized = 0 AND p.gross_sales IS NOT NULL) AS ready_to_close
  FROM public.pnl_periods p
  LEFT JOIN combined cb ON cb.period_id = p.id
  LEFT JOIN readiness r ON r.period_id = p.id
 GROUP BY p.id, p.client_id, p.period_start, p.period_end, p.label, p.length_weeks,
          p.is_closed, p.gross_sales, p.labor_kitchen, p.labor_management, p.labor_front_house,
          r.invoices_total, r.invoices_unreviewed, r.lines_uncategorized;

COMMENT ON VIEW public.pnl_period_summary IS
  'The P&L. Food and beverage cost derive from reviewed invoices; sales and labor come from the owner. ready_to_close is false while any invoice in the window is still in the review queue - closing a period on unreviewed extractions is how a wrong prime cost becomes permanent.';
