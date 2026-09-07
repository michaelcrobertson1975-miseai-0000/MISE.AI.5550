-- mise_line_item_defaults has been writing SUPPLIES and FREIGHT since before the
-- pnl_categories table existed. Neither code was in that table, so every paper,
-- glove, container and fuel-surcharge line fell out of pnl_period_summary as
-- "unclassified" - silently, which is the worst way for money to go missing.
--
-- The trigger's four codes are the source of truth because they are what is
-- actually in the data. The finer codes stay available for a reviewer to refine
-- a line by hand; they roll into the same buckets.

INSERT INTO public.pnl_categories (code, label, pnl_bucket, in_prime_cost, sort_order) VALUES
  ('SUPPLIES', 'Supplies (paper, chemical, smallwares)', 'supplies', false, 45),
  ('FREIGHT',  'Freight and surcharges',                 'other',    false, 85)
ON CONFLICT (code) DO NOTHING;

-- BEVERAGE from the trigger covers alcohol too, since mise_pnl_category matches
-- BEER, WINE, VODKA and friends into it. Both roll into cogs_beverage already.
UPDATE public.pnl_categories
   SET label = 'Beverage (incl. beer and wine)'
 WHERE code = 'BEVERAGE';

SELECT c.code, c.label, c.pnl_bucket, c.in_prime_cost,
       (SELECT count(*) FROM public.invoice_line_items li WHERE li.pnl_category = c.code) AS lines_using
  FROM public.pnl_categories c
 ORDER BY c.sort_order;
