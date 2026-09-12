-- PHYSICAL COUNTS. The shelf gets the final word.
--
-- The system now knows what was bought and what was sold, so it can say what
-- SHOULD be there. It could never say what IS there. That gap -- theoretical
-- against actual -- is the whole point of a costing system: it is where theft,
-- over-portioning, spoilage and bad recipes show up, and none of them are
-- visible from invoices and sales alone.
--
-- A count is not a suggestion. When someone walks the walk-in and writes down
-- 31 lb, there are 31 lb. The system's figure was a calculation and the
-- calculation was wrong by however much. So a count line records BOTH numbers,
-- keeps the difference forever, and then sets stock to what was actually
-- there. Silently overwriting without keeping the difference would hide the
-- one number worth having.

CREATE TABLE IF NOT EXISTS public.inventory_counts (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id   uuid NOT NULL REFERENCES public.clients(id) ON DELETE CASCADE,
  count_date  date NOT NULL DEFAULT current_date,
  note        text,
  counted_by  text,          -- free text, not a staff link: no PII by design
  created_at  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.inventory_counts IS
  'One physical count session -- a walk of the walk-in, the bar, or one section of either.';
COMMENT ON COLUMN public.inventory_counts.counted_by IS
  'Free text on purpose. Deliberately not a link to a staff record: this system holds no personal data.';

CREATE TABLE IF NOT EXISTS public.inventory_count_lines (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  inventory_count_id  uuid NOT NULL REFERENCES public.inventory_counts(id) ON DELETE CASCADE,
  ingredient_id       uuid REFERENCES public.ingredients(id) ON DELETE CASCADE,
  beverage_item_id    uuid REFERENCES public.beverage_items(id) ON DELETE CASCADE,
  counted_base_units  numeric NOT NULL,
  -- filled in by the trigger, never by hand
  system_base_units   numeric,
  variance_base_units numeric,
  cost_per_base_unit  numeric,
  variance_dollars    numeric,
  note                text,
  created_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT count_line_targets_exactly_one CHECK (
    (ingredient_id IS NOT NULL AND beverage_item_id IS NULL) OR
    (ingredient_id IS NULL AND beverage_item_id IS NOT NULL)
  ),
  CONSTRAINT count_line_not_negative CHECK (counted_base_units >= 0)
);

COMMENT ON COLUMN public.inventory_count_lines.variance_base_units IS
  'counted - system. Negative is shrinkage: product left without being sold. Positive usually means a receipt or a recipe is wrong, not a windfall.';

CREATE INDEX IF NOT EXISTS inventory_count_lines_by_count
  ON public.inventory_count_lines (inventory_count_id);

ALTER TABLE public.inventory_counts      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_count_lines ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.inventory_counts      FROM anon, authenticated;
REVOKE ALL ON public.inventory_count_lines FROM anon, authenticated;
GRANT ALL ON public.inventory_counts      TO service_role;
GRANT ALL ON public.inventory_count_lines TO service_role;

CREATE OR REPLACE FUNCTION public.mise_apply_inventory_count_line()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_system numeric;
  v_cost   numeric;
BEGIN
  IF NEW.beverage_item_id IS NOT NULL THEN
    SELECT coalesce(total_base_units_in_stock, 0), cost_per_base_unit
      INTO v_system, v_cost
      FROM public.beverage_items WHERE id = NEW.beverage_item_id;

    UPDATE public.beverage_items
       SET total_base_units_in_stock = NEW.counted_base_units, updated_at = now()
     WHERE id = NEW.beverage_item_id;
  ELSE
    SELECT coalesce(on_hand, 0) INTO v_system
      FROM public.ingredients WHERE id = NEW.ingredient_id;

    -- Food has no stored cost: it comes from what was last invoiced, which is
    -- the honest figure to value a variance at.
    SELECT cost_per_base_unit INTO v_cost
      FROM public.v_ingredient_last_price WHERE ingredient_id = NEW.ingredient_id;

    UPDATE public.ingredients
       SET on_hand = NEW.counted_base_units, on_hand_updated_at = now()
     WHERE id = NEW.ingredient_id;
  END IF;

  NEW.system_base_units   := v_system;
  NEW.variance_base_units := round(NEW.counted_base_units - coalesce(v_system, 0), 4);
  NEW.cost_per_base_unit  := v_cost;
  NEW.variance_dollars    := CASE WHEN v_cost IS NOT NULL
                                  THEN round(NEW.variance_base_units * v_cost, 2) END;
  RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.mise_apply_inventory_count_line() IS
  'Records what the system believed, works out the difference, values it at the cost in effect, then sets stock to what was actually counted. The shelf wins; the difference is kept.';

DROP TRIGGER IF EXISTS trg_apply_inventory_count_line ON public.inventory_count_lines;
CREATE TRIGGER trg_apply_inventory_count_line
  BEFORE INSERT ON public.inventory_count_lines
  FOR EACH ROW EXECUTE FUNCTION public.mise_apply_inventory_count_line();

CREATE OR REPLACE VIEW public.v_inventory_variance AS
SELECT c.client_id,
       c.count_date,
       c.id                              AS inventory_count_id,
       coalesce(i.name, bi.name)         AS item_name,
       CASE WHEN l.beverage_item_id IS NOT NULL THEN 'beverage' ELSE 'food' END AS kind,
       coalesce(i.base_unit, bi.base_unit) AS base_unit,
       l.system_base_units,
       l.counted_base_units,
       l.variance_base_units,
       l.cost_per_base_unit,
       l.variance_dollars,
       CASE WHEN coalesce(l.system_base_units, 0) = 0 THEN NULL
            ELSE round(100.0 * l.variance_base_units / l.system_base_units, 2)
       END                               AS variance_pct,
       l.note
  FROM public.inventory_count_lines l
  JOIN public.inventory_counts c ON c.id = l.inventory_count_id
  LEFT JOIN public.ingredients    i  ON i.id  = l.ingredient_id
  LEFT JOIN public.beverage_items bi ON bi.id = l.beverage_item_id;

ALTER VIEW public.v_inventory_variance SET (security_invoker = true);

COMMENT ON VIEW public.v_inventory_variance IS
  'What a count found against what the system expected, in units, dollars and percent. Negative variance is product that left without being sold.';
