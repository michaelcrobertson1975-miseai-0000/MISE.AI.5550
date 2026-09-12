-- Two defects caught by RUNNING the thing rather than reading it.
--
-- 1. nightly_product_mix_depletions.beverage_bom_id and .beverage_item_id were
--    NOT NULL, written when beverage was the only kind of depletion there was.
--    A food row carries neither, so every food depletion was rejected outright.
--
-- 2. YIELD WAS APPLIED BACKWARDS, which is the dangerous one because it
--    produces a plausible number instead of an error. yield_factor is the
--    usable fraction after trim and cook loss. To PLATE 6 oz at a 0.75 yield
--    you must CONSUME 6 / 0.75 = 8 oz. The function multiplied instead:
--    6 * 0.75 = 4.5 oz. Every plate would have been costed at roughly half
--    what it actually eats, and the error grows as yield gets worse -- a whole
--    tenderloin at 0.55 yield would have been out by nearly 3x, silently, in
--    the direction that flatters the food cost.

ALTER TABLE public.nightly_product_mix_depletions
  ALTER COLUMN beverage_bom_id  DROP NOT NULL,
  ALTER COLUMN beverage_item_id DROP NOT NULL;

COMMENT ON COLUMN public.menu_item_boms.yield_factor IS
  'Usable fraction after trim and cook loss. Consumption is portion / yield_factor: 6 oz plated at 0.75 yield consumes 8 oz. A yield of 1.0 means nothing is lost.';

-- Yield cannot exceed 1: you cannot get more usable product out than you put
-- in. The old check allowed up to 10, which let the backwards reading look
-- legitimate.
ALTER TABLE public.menu_item_boms DROP CONSTRAINT IF EXISTS menu_item_boms_yield_sane;
ALTER TABLE public.menu_item_boms
  ADD CONSTRAINT menu_item_boms_yield_sane CHECK (yield_factor > 0 AND yield_factor <= 1);
