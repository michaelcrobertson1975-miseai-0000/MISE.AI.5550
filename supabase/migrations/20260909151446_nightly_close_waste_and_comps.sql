-- Service waste log: waste logged during a shift, in dollars.
-- Separate from prep_yield_log (which tracks batch-prep portion/weight yield).
-- No personal identity fields -- access is via the owner's single login,
-- same pattern as Review Queue's shared access code.
create table public.service_waste_log (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references public.clients(id),
  service_date date not null default current_date,
  prep_item_id uuid references public.prep_items(id),
  item_name text,
  dollar_value numeric not null,
  note text,
  logged_at timestamptz not null default now()
);

comment on table public.service_waste_log is
  'Waste logged during service, in dollars. Separate from prep_yield_log
   (batch-prep portion/weight yield). Not yet wired to any app screen --
   built ahead of the Cook App UI decision, use if/when that flow ships.';

-- Nightly close additions: one comps total (manager-entered), plus simple
-- confirmation timestamps so the app can tell whether the chef's waste
-- review and the manager's labor/sales/comps review have actually been sent.
-- No _by columns -- access is the owner's single login, not per-person.
alter table public.nightly_reports
  add column comps_total numeric,
  add column chef_confirmed_at timestamptz,
  add column manager_confirmed_at timestamptz;
