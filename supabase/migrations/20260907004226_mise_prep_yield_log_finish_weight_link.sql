-- Additive only. The Cook App's butchery flow logs a "weight in" entry now
-- and finishes it with "weight out" later (possibly much later) -- prep_yield_log
-- is append-only by design (never update a past entry), so the finish is a
-- second row that references the first, rather than mutating it in place.
alter table public.prep_yield_log add column if not exists related_entry_id uuid references public.prep_yield_log(id);
comment on column public.prep_yield_log.related_entry_id is 'For a weight-out finish entry, points back at the pending weight-in entry it completes. Null for a fresh entry.';