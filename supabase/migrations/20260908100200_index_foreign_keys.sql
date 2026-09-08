-- ============================================================================
-- Cover the 27 foreign keys the performance linter reports as unindexed.
--
-- Free to add now, while the tables hold trial data. These are the exact joins
-- the P&L rollups, the Review Queue and the depletion pass walk, so they are
-- the ones that turn into sequential scans at a hundred thousand line items.
--
-- Postgres indexes a foreign key's target automatically (it is a unique key);
-- it does NOT index the referencing column, which is what every join and every
-- cascading delete needs.
-- ============================================================================

-- ── invoice pipeline ─────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS invoices_escalated_from_idx
  ON public.invoices (escalated_from);
CREATE INDEX IF NOT EXISTS invoices_merged_into_idx
  ON public.invoices (merged_into);
CREATE INDEX IF NOT EXISTS invoice_corrections_line_item_idx
  ON public.invoice_corrections (line_item_id);
CREATE INDEX IF NOT EXISTS parsed_data_email_idx
  ON public.parsed_data (email_id);

-- ── ingestion queue ──────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS ingestion_queue_client_idx
  ON public.ingestion_queue (client_id);

-- ── nightly reports and depletion ────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS nightly_reports_client_idx
  ON public.nightly_reports (client_id);
CREATE INDEX IF NOT EXISTS nightly_product_mix_report_idx
  ON public.nightly_product_mix (nightly_report_id);
CREATE INDEX IF NOT EXISTS nightly_product_mix_matched_bom_idx
  ON public.nightly_product_mix (matched_bom_id);
CREATE INDEX IF NOT EXISTS npm_depletions_mix_idx
  ON public.nightly_product_mix_depletions (nightly_product_mix_id);
CREATE INDEX IF NOT EXISTS npm_depletions_bom_idx
  ON public.nightly_product_mix_depletions (beverage_bom_id);
CREATE INDEX IF NOT EXISTS npm_depletions_item_idx
  ON public.nightly_product_mix_depletions (beverage_item_id);

-- ── beverage ─────────────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS beverage_items_client_idx
  ON public.beverage_items (client_id);
CREATE INDEX IF NOT EXISTS beverage_items_ingredient_idx
  ON public.beverage_items (ingredient_id);
CREATE INDEX IF NOT EXISTS beverage_boms_client_idx
  ON public.beverage_boms (client_id);
CREATE INDEX IF NOT EXISTS beverage_boms_item_idx
  ON public.beverage_boms (beverage_item_id);
CREATE INDEX IF NOT EXISTS beverage_variance_log_client_idx
  ON public.beverage_variance_log (client_id);
CREATE INDEX IF NOT EXISTS beverage_variance_log_item_idx
  ON public.beverage_variance_log (beverage_item_id);

-- ── clients, routing, P&L ────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS client_email_routes_client_idx
  ON public.client_email_routes (client_id);
CREATE INDEX IF NOT EXISTS client_routing_hints_client_idx
  ON public.client_routing_hints (client_id);
CREATE INDEX IF NOT EXISTS client_category_settings_category_idx
  ON public.client_category_settings (category_code);
CREATE INDEX IF NOT EXISTS pnl_manual_costs_category_idx
  ON public.pnl_manual_costs (category);

-- ── prep ─────────────────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS prep_day_prep_item_idx
  ON public.prep_day (prep_item_id);
CREATE INDEX IF NOT EXISTS prep_items_unit_idx
  ON public.prep_items (unit);
CREATE INDEX IF NOT EXISTS prep_yield_log_client_idx
  ON public.prep_yield_log (client_id);
CREATE INDEX IF NOT EXISTS prep_yield_log_prep_item_idx
  ON public.prep_yield_log (prep_item_id);
CREATE INDEX IF NOT EXISTS prep_yield_log_related_entry_idx
  ON public.prep_yield_log (related_entry_id);

-- prep_items_station_fkey is already covered by prep_items_station_idx.
