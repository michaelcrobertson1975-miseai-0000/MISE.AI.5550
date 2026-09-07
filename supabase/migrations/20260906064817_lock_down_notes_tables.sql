ALTER TABLE public.project_milestones ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.security_findings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.open_issues ENABLE ROW LEVEL SECURITY;

-- No policies added on purpose: this means the public API (anon/authenticated
-- keys) gets zero access, full stop. Only direct database access -- the
-- Supabase dashboard, or a service-role connection -- can read these now.
ALTER VIEW public.project_status SET (security_invoker = true);
