INSERT INTO public.locker_issues (title, description, area, status) VALUES (
  'beverage_boms rows not created yet -- waiting on real menu names from the restaurant',
  '5 real beverage_items exist (Domaine Bousquet Cab, Mountain Dew/Pepsi/Tropicana Lemonade syrups, the lager keg), all linked to real invoice data. No beverage_boms rows exist for any of them yet.

WHY: pos_item_name (really "menu_item_name" -- this system has no POS and never will, standalone by design) has to match whatever the restaurant actually calls the drink when it sells it, which is often different from the distributor''s invoice description ("Lager At World''s End" on the invoice is not necessarily what it is called behind the bar). This is real information only the restaurant has -- guessing it would create BOM rows that never match anything real.

ALSO CONFIRMED: every single pour needs its own BOM row, no matter how simple -- a straight shot of tequila is not exempt. With something like a tequila selection (the example given: 5 different Jose Cuervo expressions by year, each a different real cost), each specific bottle needs its own beverage_item and its own name -- there is no shortcut for a category with many similarly-named but differently-priced variants.

NEXT STEP: get the actual menu/serving names from the restaurant for at least the 5 items that already have real invoice data, then build beverage_boms for those. Do not fabricate plausible-sounding names to fill this gap.

RENAME NOTED: beverage_boms.pos_item_name column name is misleading now that there is confirmed to be no POS -- consider renaming to menu_item_name when convenient (not urgent, cosmetic).',
  'bar-inventory',
  'open'
);
