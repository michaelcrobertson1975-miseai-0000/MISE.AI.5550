-- The fix-the-lines leg. Every human edit is recorded with the value the model
-- produced, which is the only way "80 -> 98" is measurable rather than asserted:
-- accuracy is corrections per line, and this table is the numerator.

CREATE TABLE IF NOT EXISTS public.invoice_corrections (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_id    uuid NOT NULL REFERENCES public.invoices(id) ON DELETE CASCADE,
  line_item_id  uuid REFERENCES public.invoice_line_items(id) ON DELETE CASCADE,
  field_name    varchar NOT NULL,
  old_value     text,
  new_value     text,
  model_used    varchar,
  corrected_at  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.invoice_corrections IS
  'One row per field a human changed. line_item_id is null for header-level fields.';

CREATE INDEX IF NOT EXISTS invoice_corrections_invoice_idx ON public.invoice_corrections (invoice_id);
CREATE INDEX IF NOT EXISTS invoice_corrections_field_idx   ON public.invoice_corrections (field_name);

ALTER TABLE public.invoices
  ADD COLUMN IF NOT EXISTS corrected_at    timestamptz,
  ADD COLUMN IF NOT EXISTS correction_count integer DEFAULT 0;

COMMENT ON COLUMN public.invoices.corrected_at IS
  'When a human last saved corrections. Null means the extraction has never been touched.';
COMMENT ON COLUMN public.invoices.correction_count IS
  'How many fields a human had to fix. Zero on a clean read; this is the accuracy signal.';

-- Line items were deleted-and-reinserted nowhere, so a removed row needs a marker
-- rather than a hard delete: a line the model invented is itself a correction.
ALTER TABLE public.invoice_line_items
  ADD COLUMN IF NOT EXISTS removed_by_review boolean DEFAULT false;

COMMENT ON COLUMN public.invoice_line_items.removed_by_review IS
  'True when a reviewer deleted this row as something the model hallucinated. Kept rather than deleted so the error stays countable.';
