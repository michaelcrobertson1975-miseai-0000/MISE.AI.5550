-- Keep the original invoice bytes so any invoice can be re-run against an
-- improved parser and so a later Pro-escalation pass has something to re-read.
alter table public.invoices
  add column if not exists source_file_path text;

comment on column public.invoices.source_file_path is
  'Path within the private invoice-files Storage bucket to the original uploaded bytes (client_id/invoice_id.ext). Null when archival was skipped or failed; ingestion never blocks on it.';

-- Private bucket for the raw source files. Service role (edge function) bypasses
-- storage RLS; nothing is world-readable.
insert into storage.buckets (id, name, public)
values ('invoice-files', 'invoice-files', false)
on conflict (id) do nothing;
