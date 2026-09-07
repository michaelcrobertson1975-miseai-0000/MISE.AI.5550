-- Prime cost needs three things invoices alone don't give us:
--   1. which P&L bucket each line belongs to (food vs beverage vs supplies vs freight)
--   2. a stable key to track the SAME item across deliveries (vendor item code)
--   3. the vendor's own section header, which is the most reliable category signal

ALTER TABLE invoice_line_items ADD COLUMN IF NOT EXISTS vendor_category VARCHAR(60);
ALTER TABLE invoice_line_items ADD COLUMN IF NOT EXISTS pnl_category VARCHAR(20);
ALTER TABLE invoice_line_items ADD COLUMN IF NOT EXISTS vendor_item_code VARCHAR(50);

CREATE INDEX IF NOT EXISTS invoice_line_items_item_code_idx
    ON invoice_line_items (vendor_item_code);
CREATE INDEX IF NOT EXISTS invoice_line_items_pnl_category_idx
    ON invoice_line_items (pnl_category);

-- Sysco prints section headers (DAIRY, MEATS, FROZEN, MISC CHARGES). That is the
-- vendor's own classification and beats keyword guessing. Description keywords are
-- the fallback when no section header was captured.
CREATE OR REPLACE FUNCTION mise_pnl_category(vendor_category TEXT, description TEXT)
RETURNS VARCHAR(20) AS $$
DECLARE
  v TEXT := upper(coalesce(vendor_category, ''));
  d TEXT := upper(coalesce(description, ''));
BEGIN
  -- Fees and freight are never inventory.
  IF v LIKE '%MISC%' OR d ~ '(FUEL|FREIGHT|DELIVERY|SURCHARGE|SPLIT CASE|MIN.*ORDER|PICKUP)' THEN
    RETURN 'FREIGHT';
  END IF;

  IF v ~ '(HEALTHCARE|SUPPL|PAPER|DISPOSAB|CHEMICAL|JANITOR|SMALLWARE)'
     OR d ~ '(MASK|GLOVE|NAPKIN|TOWEL|DETERGENT|SANITIZER|FOIL|WRAP|CONTAINER|STRAW|LINER|BAG PLAS)' THEN
    RETURN 'SUPPLIES';
  END IF;

  IF v ~ '(BEVERAGE|LIQUOR|BEER|WINE|SPIRIT|SODA|JUICE BAR)'
     OR d ~ '(BEER|WINE|VODKA|WHISKEY|BOURBON|TEQUILA|LIQUOR|SODA|COLA|SYRUP BAR)' THEN
    RETURN 'BEVERAGE';
  END IF;

  IF v ~ '(DAIRY|MEAT|SEAFOOD|FROZEN|PRODUCE|BAKERY|GROCERY|CANNED|DRY|POULTRY|DELI|CHEESE)' THEN
    RETURN 'FOOD';
  END IF;

  -- An unclassified line still has to land somewhere; food is the safe default for
  -- a broadline order, and the column is nullable-checked in the rollup report.
  RETURN 'FOOD';
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Sysco prints the item code inside the description; pull it out for price tracking.
CREATE OR REPLACE FUNCTION mise_item_code(description TEXT)
RETURNS VARCHAR(50) AS $$
BEGIN
  RETURN substring(coalesce(description, '') FROM '(\d{6,})\s*$');
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Backfill everything already ingested.
UPDATE invoice_line_items
   SET pnl_category    = mise_pnl_category(vendor_category, item_description),
       vendor_item_code = coalesce(vendor_item_code, mise_item_code(item_description))
 WHERE pnl_category IS NULL;
