-- The Upload tab accepts six document types (invoice, recipe, waste_list,
-- pos_printout, product_mix, order_sheet) but its CSV parser only ever produces
-- one shape: date / item / category / qty / price. Rather than invent six
-- tables tonight for data nobody reads yet, rows land here with the doc_type
-- that was selected, so nothing a restaurant uploads is thrown away and each
-- type can be promoted into its own home when something actually consumes it.
CREATE TABLE IF NOT EXISTS public.intake_rows (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id    uuid NOT NULL REFERENCES public.clients(id) ON DELETE CASCADE,
  doc_type     varchar NOT NULL DEFAULT 'invoice',
  source_name  text,
  row_date     date,
  item         text NOT NULL,
  category     text,
  quantity     numeric,
  price        numeric,
  promoted_to  varchar,
  uploaded_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS intake_rows_client_idx ON public.intake_rows (client_id, doc_type, row_date);
CREATE INDEX IF NOT EXISTS intake_rows_unpromoted_idx ON public.intake_rows (client_id) WHERE promoted_to IS NULL;

COMMENT ON TABLE public.intake_rows IS
  'Raw spreadsheet rows exactly as uploaded. promoted_to records where a row was later copied to, so a re-import cannot double-count it.';
