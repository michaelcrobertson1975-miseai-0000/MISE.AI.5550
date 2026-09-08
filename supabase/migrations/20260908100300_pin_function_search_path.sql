-- ============================================================================
-- Pin search_path on every mise_* function.
--
-- A function with a role-mutable search_path resolves its table and operator
-- references against whatever schema list the caller happens to have. That is
-- the standard privilege-escalation route into SECURITY DEFINER code: create a
-- lookalike table in a schema that sorts earlier, and the function reads yours
-- instead of public's. The linter flags 21 of these.
--
-- Written as a loop over pg_proc rather than 21 hand-typed ALTERs, because the
-- signature has to match exactly and several of these are overloaded.
-- ============================================================================

DO $$
DECLARE
  f record;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure AS sig
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname LIKE 'mise\_%'
       AND p.prokind = 'f'
       -- only those not already pinned
       AND NOT EXISTS (
         SELECT 1 FROM unnest(coalesce(p.proconfig, '{}')) AS c
          WHERE c LIKE 'search_path=%'
       )
  LOOP
    EXECUTE format('ALTER FUNCTION %s SET search_path = public, pg_temp', f.sig);
    RAISE NOTICE 'pinned search_path on %', f.sig;
  END LOOP;
END $$;

-- ── pg_net: NOT moved here, on purpose ──────────────────────────────────────
-- The linter also flags pg_net sitting in `public`. Moving it is left out of
-- this migration deliberately: the queue's cron job calls net.http_post(), and
-- whether that call survives an ALTER EXTENSION ... SET SCHEMA depends on how
-- pg_net is mapped in this project. Getting it wrong stops invoice ingestion
-- entirely. Verify the current schema mapping first, then move it in its own
-- migration where the blast radius is one thing:
--
--   SELECT e.extname, n.nspname
--     FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace
--    WHERE e.extname = 'pg_net';
