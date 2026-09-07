-- Categorisation was only ever applied by a manual backfill, so the first real
-- extraction landed with pnl_category NULL and never reached food COGS.
-- A trigger makes it structural: no insert path can bypass it.
CREATE OR REPLACE FUNCTION mise_line_item_defaults()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.vendor_item_code IS NULL THEN
    NEW.vendor_item_code := mise_item_code(NEW.item_description);
  END IF;
  IF NEW.pnl_category IS NULL THEN
    NEW.pnl_category := mise_pnl_category(NEW.vendor_category, NEW.item_description);
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_line_item_defaults ON invoice_line_items;
CREATE TRIGGER trg_line_item_defaults
  BEFORE INSERT OR UPDATE ON invoice_line_items
  FOR EACH ROW EXECUTE FUNCTION mise_line_item_defaults();

-- Repair the invoice that just came in.
UPDATE invoice_line_items SET pnl_category = NULL WHERE pnl_category IS NULL;
