-- Enable RLS with no policies = deny all to anon/authenticated by default.
-- Access happens only through edge functions using the service role key,
-- same pattern as prep_day and the other locked-down tables.
alter table public.service_waste_log enable row level security;
