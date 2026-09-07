-- A restaurant photographs a three-page invoice as three JPEGs and forwards all
-- three in one email. Ingesting them separately produced three invoices, none of
-- which reconciled - even though the extraction was perfect and the three page
-- sums came to the printed subtotal exactly.
ALTER TABLE public.invoices
  ADD COLUMN IF NOT EXISTS source_file_paths text[],
  ADD COLUMN IF NOT EXISTS page_count smallint DEFAULT 1;

COMMENT ON COLUMN public.invoices.source_file_paths IS
  'Every archived page of this invoice, in the order sent. source_file_path keeps the first for backwards compatibility.';
COMMENT ON COLUMN public.invoices.page_count IS
  'How many images or pages were read together as this one invoice.';

-- Backfill the single-page history so the column is never half-populated.
UPDATE public.invoices
   SET source_file_paths = ARRAY[source_file_path]
 WHERE source_file_path IS NOT NULL
   AND source_file_paths IS NULL;
