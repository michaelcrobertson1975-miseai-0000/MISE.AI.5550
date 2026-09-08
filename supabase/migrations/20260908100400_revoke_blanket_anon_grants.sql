-- ============================================================================
-- Take away the standing INSERT/UPDATE/DELETE/TRUNCATE grants held by anon and
-- authenticated, and stop the two views bypassing RLS.
--
-- Today RLS is the only thing holding these back: every table in public grants
-- the full set to both roles, and it is invisible because no policy lets them
-- through. That makes it a trapdoor rather than a wall -- the first permissive
-- policy anyone adds for one legitimate feature also switches on the standing
-- grant to delete and truncate that table.
--
-- Nothing in the codebase needs these. Every edge function connects with the
-- service-role key, which is a different role and is unaffected. After
-- 20260908100000 the Review Queue no longer uses the anon key either, so there
-- is no remaining anon PostgREST caller to break.
--
-- Safe ordering: this migration must run AFTER 20260908100000 and after the
-- `review` function is deployed.
-- ============================================================================

REVOKE ALL PRIVILEGES ON ALL TABLES    IN SCHEMA public FROM anon, authenticated;
REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public FROM anon, authenticated;
REVOKE ALL PRIVILEGES ON ALL ROUTINES  IN SCHEMA public FROM anon, authenticated;

-- Stop new tables inheriting the same blanket grant. Supabase's default
-- privileges hand these out automatically, which is how every table ended up
-- with them in the first place.
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES    FROM anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON SEQUENCES FROM anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON ROUTINES  FROM anon, authenticated;

-- ── The two views that bypass RLS ────────────────────────────────────────────
-- A SECURITY DEFINER view runs with its creator's rights, so it reads straight
-- past row-level security. Both of these are read by edge functions running as
-- service-role, which is not affected by the switch -- but leaving them as
-- DEFINER means any future anon grant on the view is a hole through RLS.
ALTER VIEW public.price_moves             SET (security_invoker = true);
ALTER VIEW public.v_ingredient_last_price SET (security_invoker = true);

COMMENT ON VIEW public.price_moves IS
  'security_invoker: reads with the caller''s row-level security, not the creator''s. Read by the api and monthly-audit functions as service-role.';
