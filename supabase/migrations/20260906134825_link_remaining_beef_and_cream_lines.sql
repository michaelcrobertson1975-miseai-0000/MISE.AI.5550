UPDATE public.invoice_line_items
   SET ingredient_id = '353d92c2-357a-4419-b908-1bf630219da9', chef_category = 'protein', matched_at = now()
 WHERE item_description IN ('SNAKRIV BEEF GROUND PTY KOBE STY IQF 98201', '98201 SNAKRIV BEEF GROUND PTY KOBE STY IQF')
   AND ingredient_id IS NULL;

UPDATE public.invoice_line_items
   SET ingredient_id = 'e47de639-7c03-4984-8c5e-3326a2396e2b', chef_category = 'dairy', matched_at = now()
 WHERE item_description IN ('CRYSCRM CREAM HEAVY 40% 160405', '160405 CRYSCRM CREAM HEAVY 40%')
   AND ingredient_id IS NULL;
