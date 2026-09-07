INSERT INTO public.locker_issues (title, description, area, status) VALUES (
  'Planned: bar/beer inventory + BOM + variance tracking',
  'A design was proposed for tracking beer/keg inventory: beer_inventory (ounces in stock per item), beer_boms (links a POS menu button/pour size to ounces subtracted from a keg), and beer_variance_history (weekly foam/loss variance = starting + invoiced in - ending - POS sold).

STATUS: nothing built yet. None of these three tables exist in the database.

WHAT IS BUILDABLE TODAY, independent of anything else: beer_inventory and beer_boms. These just track what is on hand and what a given pour size is supposed to draw down -- no external dependency.

WHAT IS BLOCKED: beer_variance_history depends on a real "pos_ounces_sold" number, and there is no POS system connected anywhere in this project. Without that feed, the variance formula has a permanent hole in it (would require someone to hand-type sales-by-the-ounce weekly, defeating the automation).

NOTE ON THE ORIGINAL PROPOSAL: it used placeholder values that do not match this project (restaurant_id "miseai-oooo" instead of the real client UUID, "Oregon Region" instead of the actual us-west-1 project region) -- treat it as a generic template to adapt, not something written against this specific database.

NEXT STEP WHEN READY: decide whether to build beer_inventory + beer_boms now (useful on their own for costing pours) while leaving variance tracking parked until a POS integration exists, or wait and build all three together once POS access is sorted out.',
  'bar-inventory',
  'open'
);
