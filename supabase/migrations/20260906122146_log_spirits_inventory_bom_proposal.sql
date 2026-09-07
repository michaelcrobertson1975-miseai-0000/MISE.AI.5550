INSERT INTO public.locker_issues (title, description, area, status) VALUES (
  'Planned: spirits/liquor inventory + BOM + variance tracking',
  'Companion design to the beer inventory proposal, for liquor (Southern Glazers, Young''s Market style invoices). Converts bottle size (750mL/1L/1.75L handle) x case pack into total ounces on receipt, then a BOM maps POS pour buttons (neat, rocks, cocktail, happy hour) down to ounces subtracted from the same bottle. Multi-ingredient cocktails (e.g. a Negroni) would hit three inventory rows at once from one POS button. Same variance formula as beer: starting + invoiced in - ending - POS out.

STATUS: nothing built. No spirits inventory or BOM tables exist yet.

SAME BLOCKER AS BEER: variance tracking needs a real POS feed for "ounces sold," which does not exist anywhere in this project. Inventory + BOM tables themselves (tracking what is on hand, and what each pour/cocktail is supposed to draw down) are buildable today without that dependency.

SAME PLACEHOLDER NOTE: proposal used "restaurant_id": "miseai-oooo" and generic values, not this project''s real client UUID -- treat as a template to adapt, not literal.

Natural to build alongside the beer inventory work (same underlying pattern: item -> ounces in stock, BOM -> pour size drawn from it, variance -> needs POS). Consider doing both together when the time comes.',
  'bar-inventory',
  'open'
);
