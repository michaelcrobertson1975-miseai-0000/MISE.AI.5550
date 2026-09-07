create table public.prep_yield_log (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references public.clients(id),
  prep_item_id uuid not null references public.prep_items(id),
  entry_type varchar not null check (entry_type in ('portions', 'weight')),
  status varchar not null default 'finished' check (status in ('pending', 'finished')),
  expected_portions numeric,
  actual_portions numeric,
  weight_in numeric,
  weight_out numeric,
  raw_cost_per_lb numeric,
  logged_at timestamp with time zone not null default now()
);

comment on table public.prep_yield_log is 'Real yield-tracking entries per prep item: portion variance for standard recipes, weight-in/weight-out for butchery-style prep (e.g. Atlantic Salmon). Replaces the old browser-only storage the cook-app HTML used.';

alter table public.prep_yield_log enable row level security;

create policy "allow all for now" on public.prep_yield_log
  for all using (true) with check (true);
