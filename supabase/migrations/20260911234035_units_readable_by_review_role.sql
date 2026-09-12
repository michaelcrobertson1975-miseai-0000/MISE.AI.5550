-- M1. The ops Review Queue writes as `anon`. public.units has RLS enabled with
-- ZERO policies, and every mise_* function is SECURITY INVOKER, so the BEFORE
-- UPDATE trigger's lookup into units returned no rows for that role and
-- mise_parse_pack fell through to its last-resort branch: EACH / NULL / low.
-- Every correction saved through that tool blanked total_base_units and
-- cost_per_base_unit and dropped the line out of all four price views.
--
-- units is a 36-row GLOBAL token -> base-unit conversion table. It holds no
-- client data, no financial data and nothing restaurant-specific, so making it
-- readable is not a data-exposure change. Read-only: no INSERT/UPDATE/DELETE
-- policy is granted, so a browser still cannot teach the system a unit.

CREATE POLICY units_read_all
  ON public.units
  FOR SELECT
  TO anon, authenticated
  USING (true);

COMMENT ON TABLE public.units IS
  'Unit token -> base unit and conversion factor. A new distributor abbreviation is an INSERT, never a deploy. Readable by anon/authenticated because the SECURITY INVOKER math triggers resolve units as the calling role; writes remain service-role only.';
