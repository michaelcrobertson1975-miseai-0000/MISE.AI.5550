-- CLEAN SLATE before a full from-scratch onboarding (6 recipes, product mix,
-- order guide, POS migration, all by CSV).
--
-- Restaurant DATA only. Deliberately KEPT, because they are not restaurant
-- content and wiping them would break things that currently work:
--   clients                -- Cellar stays, same client_id the dashboard has
--   client_email_routes    -- invoices@miseai0010.com keeps receiving invoices
--   client_routing_hints   -- owner forwarding address + "Cellar" subject rule
--   units, pnl_categories  -- global reference data every math path reads
--   prep_units, prep_stations -- global reference lists
--   locker_*               -- the project notebook, not restaurant data
--
-- A full JSON backup of everything below was taken and handed to the owner
-- immediately before this ran.
--
-- NOTE: prep_recipes has no client_id column -- it is a GLOBAL table, so the
-- two rows removed here were not scoped to Cellar in the first place. Worth
-- making client-scoped before a second restaurant exists.

-- children first, parents after (FKs)
DELETE FROM nightly_product_mix_depletions;
DELETE FROM nightly_product_mix;
DELETE FROM nightly_reports;
DELETE FROM beverage_variance_log;
DELETE FROM beverage_boms;
DELETE FROM beverage_items;
DELETE FROM menu_items;

DELETE FROM prep_yield_log;
DELETE FROM prep_day;
DELETE FROM prep_items;
DELETE FROM prep_recipes;
DELETE FROM service_waste_log;

DELETE FROM shifts;
DELETE FROM staff;

DELETE FROM invoice_corrections;
DELETE FROM invoice_line_items;
DELETE FROM invoices;

DELETE FROM client_item_memory;
DELETE FROM ingredients;

DELETE FROM ingestion_queue;
DELETE FROM intake_rows;
DELETE FROM parsed_data;
DELETE FROM emails;
DELETE FROM unrouted_emails;

DELETE FROM pnl_manual_costs;
DELETE FROM pnl_periods;
DELETE FROM monthly_audits;
DELETE FROM monthly_pnl_snapshots;
DELETE FROM client_payments;
DELETE FROM client_category_settings;

INSERT INTO locker_milestones (title, summary) VALUES (
'Clean slate taken — all restaurant data cleared ahead of a full CSV onboarding',
'Every piece of restaurant DATA was deleted to start a proper end-to-end onboarding from scratch: 5 invoices, 42 line items, 63 ingredients, 6 queued jobs, 5 beverage items, 5 beverage BOMs, 2 prep recipes and 6 prep items. A full JSON backup was taken first and handed to Mikey before anything was deleted.

DELIBERATELY KEPT, because they are configuration or global reference data rather than restaurant content:
- clients: Cellar keeps the SAME client_id (7d1f0a2e-6c44-4b9a-9f31-2ab8e5c07d10), so the hardcoded MISE_RESTAURANT_ID in the dashboard still resolves. Mikey asked for this explicitly.
- client_email_routes: invoices@miseai0010.com stays active, so invoices keep arriving through the live Resend pipeline. Nothing in the email path was touched at any point.
- client_routing_hints: the owner forwarding address and the "Cellar" subject keyword rule.
- units (36), pnl_categories (12), prep_units (9), prep_stations (7): global reference data. Deleting units in particular would break every pack/unit calculation in the system.
- the locker itself.

STILL TO DO, NOT DONE HERE: the 57 archived invoice images in the invoice-files storage bucket were left in place. They are orphaned now that the invoice rows are gone. Clearing them needs the storage API, which was not reachable from the session that ran this.

KNOWN ISSUE SURFACED BY THIS: prep_recipes has NO client_id column -- it is global. The 6 recipes coming in the onboarding will land globally too, shared by every future restaurant. This needs to become client-scoped before a second restaurant is onboarded.

NEXT SESSION: full onboarding start to finish -- 6 recipes, product mix menu, order guide, and POS migration, all uploaded as CSV, the way a real restaurant would be brought on.'
);
