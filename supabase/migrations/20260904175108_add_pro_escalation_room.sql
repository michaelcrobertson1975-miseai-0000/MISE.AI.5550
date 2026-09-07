-- Room for a Pro escalation pass (e.g. gemini-3.1-pro) over flagged invoices.
-- No code change is needed to run one: ingest-invoice already honours ?model=,
-- and source_file_path keeps the original bytes so any invoice can be re-read.
-- These columns are what make a re-read distinguishable from the first pass.

ALTER TABLE public.invoices
  ADD COLUMN IF NOT EXISTS model_used         varchar,
  ADD COLUMN IF NOT EXISTS extraction_attempt smallint DEFAULT 1,
  ADD COLUMN IF NOT EXISTS escalated_at       timestamptz,
  ADD COLUMN IF NOT EXISTS escalated_from     uuid REFERENCES public.invoices(id);

COMMENT ON COLUMN public.invoices.model_used IS
  'Which model produced this extraction, e.g. gemini-3.7-flash. Without it a Pro re-read is indistinguishable from the original Flash pass.';
COMMENT ON COLUMN public.invoices.extraction_attempt IS
  '1 for the first pass, 2+ for an escalated re-read of the archived source file.';
COMMENT ON COLUMN public.invoices.escalated_at IS
  'When this row was produced by an escalation pass. Null on first-pass rows.';
COMMENT ON COLUMN public.invoices.escalated_from IS
  'The first-pass invoice row this escalation replaces, so Flash and Pro readings of the same document can be compared line by line.';

CREATE INDEX IF NOT EXISTS invoices_needs_escalation_idx
  ON public.invoices (client_id, status)
  WHERE status = 'requires_human_review';
