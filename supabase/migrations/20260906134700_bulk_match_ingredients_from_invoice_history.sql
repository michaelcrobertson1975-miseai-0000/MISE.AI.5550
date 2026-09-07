CREATE TEMP TABLE line_groups AS
SELECT
  li.id AS line_id,
  i.client_id AS client_id,
  coalesce(li.vendor_item_code, upper(trim(li.item_description))) AS product_key,
  li.item_description,
  li.standardized_base_unit,
  CASE
    WHEN li.raw_quantity IS NULL AND li.raw_unit_price IS NULL THEN 'non_cogs_fee'
    WHEN upper(li.item_description) ~ 'BLEACH|SANITIZER|DETERGENT|STRAW PAPER|BAG PAPER|CONTAINER PAPER|BOWL PLAS|CONTAINER PLAS|MASK FACE|^DEPOSIT' THEN 'non_cogs_fee'
    WHEN upper(li.item_description) ~ 'LAGER|BOUSQUET|SYRUP MOUNTAIN|SYRUP COLA|SYRUP LEMONADE' THEN 'beverage'
    WHEN upper(li.item_description) ~ 'CREAM|BUTTERMILK|BUTTER SOLID|CHEESE' THEN 'dairy'
    WHEN upper(li.item_description) ~ 'BEEF|PORK|SAUSAGE|PANGASIUS|SHRIMP|MAHI|TUNA|BASA|EGG SHELL' THEN 'protein'
    WHEN upper(li.item_description) ~ 'PEPPER CHERRY|GIULIAN' THEN 'dry_goods'
    WHEN upper(li.item_description) ~ 'SHALLOT|BROCCOLINI|ONION|PAPAYA|\yPEPPER|POTATO FRY|POTATO FF' THEN 'produce'
    ELSE 'dry_goods'
  END AS category
FROM public.invoice_line_items li
JOIN public.invoices i ON i.id = li.invoice_id
WHERE li.removed_by_review IS NOT TRUE
  AND li.ingredient_id IS NULL;

UPDATE public.invoice_line_items li
   SET chef_category = 'non_cogs_fee'
  FROM line_groups g
 WHERE g.line_id = li.id AND g.category = 'non_cogs_fee';

INSERT INTO public.ingredients (client_id, name, base_unit, pnl_category)
SELECT DISTINCT ON (client_id, product_key)
  client_id, item_description, standardized_base_unit,
  CASE category WHEN 'beverage' THEN 'beverage' ELSE 'food' END
FROM line_groups
WHERE category <> 'non_cogs_fee'
ORDER BY client_id, product_key, length(item_description) DESC;

UPDATE public.invoice_line_items li
   SET ingredient_id = ing.id,
       chef_category = g.category,
       matched_at = now()
  FROM line_groups g
  JOIN public.ingredients ing
    ON ing.client_id = g.client_id
   AND ing.name = (
     SELECT g2.item_description FROM line_groups g2
      WHERE g2.client_id = g.client_id AND g2.product_key = g.product_key
      ORDER BY length(g2.item_description) DESC LIMIT 1
   )
 WHERE g.line_id = li.id AND g.category <> 'non_cogs_fee';

DROP TABLE line_groups;
