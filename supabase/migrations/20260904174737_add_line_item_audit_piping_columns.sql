-- Piping fix: the edge function computes all of this and then throws it away.
-- Without these columns the review screen shows a flag with no reason, and the
-- PACK/SIZE columns the pack parser depends on are unrecoverable after ingest.

ALTER TABLE public.invoice_line_items
  ADD COLUMN IF NOT EXISTS raw_pack              varchar,
  ADD COLUMN IF NOT EXISTS raw_size              varchar,
  ADD COLUMN IF NOT EXISTS pack_confidence       varchar,
  ADD COLUMN IF NOT EXISTS catch_weight          boolean DEFAULT false,
  ADD COLUMN IF NOT EXISTS calculated_line_total numeric,
  ADD COLUMN IF NOT EXISTS variance              numeric,
  ADD COLUMN IF NOT EXISTS flag_notes            text[];

COMMENT ON COLUMN public.invoice_line_items.raw_pack IS
  'PACK column verbatim from the invoice, e.g. "6". Kept so a low-confidence pack parse can be corrected by a human without re-reading the source file.';
COMMENT ON COLUMN public.invoice_line_items.raw_size IS
  'SIZE column verbatim, e.g. ".5GAL". Paired with raw_pack this is what packCodes.js parses; storing both makes every base-unit figure reproducible.';
COMMENT ON COLUMN public.invoice_line_items.pack_confidence IS
  'high | medium | low, from packCodes.js. low means the case configuration was a guess and needs human confirmation.';
COMMENT ON COLUMN public.invoice_line_items.catch_weight IS
  'True when the row is billed by actual weight (T/WT= or #ACAB) rather than by case.';
COMMENT ON COLUMN public.invoice_line_items.calculated_line_total IS
  'raw_quantity * raw_unit_price, recomputed in code. Compare against line_total to see the arithmetic the invoice claims.';
COMMENT ON COLUMN public.invoice_line_items.variance IS
  'abs(calculated_line_total - line_total) in dollars. This is what the review screen should sort on.';
COMMENT ON COLUMN public.invoice_line_items.flag_notes IS
  'Why this line was flagged, in plain language. Previously computed and discarded, leaving is_flagged with no explanation.';
