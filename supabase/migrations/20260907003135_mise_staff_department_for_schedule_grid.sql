-- Additive only: the Schedule tab's UI groups staff into BOH/FOH sections,
-- but the real `staff` table (already used by schedule-sync) has no
-- department column. Add it, nullable, defaulting to nothing assumed --
-- existing rows (there are none live yet for this client) are unaffected.
alter table public.staff add column if not exists dept text check (dept in ('BOH','FOH'));
comment on column public.staff.dept is 'Kitchen (BOH) or Front of House (FOH) grouping used by the Schedule tab grid.';