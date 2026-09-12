-- The old domain in.miseai-0000.com is dead: deleted from Resend entirely.
-- Three routes still pointed at it and were still marked active, so the
-- routing table advertised addresses that can never receive anything.
--
-- Deactivated rather than deleted: mise_client_for_email and
-- mise_client_for_report_email both require is_active = true, so switching
-- these off stops them routing completely, while keeping the historical row
-- (and its client_id) recoverable with a single flip.
--
-- invoices@miseai0010.com -- the ONE live invoice intake, routed to Cellar --
-- is deliberately untouched by the WHERE clause below.

UPDATE public.client_email_routes
   SET is_active = false
 WHERE email_address ILIKE '%@in.miseai-0000.com'
   AND is_active = true;

INSERT INTO locker_milestones (title, summary) VALUES (
'Dead-domain email routes deactivated — invoices@miseai0010.com is now the only live intake',
'Three routes on the retired domain in.miseai-0000.com (invoices@, invoice@, and sales@ for nightly reports) were still flagged is_active = true in client_email_routes, even though that domain was deleted from Resend days earlier. Nothing was arriving on them, but the table still advertised them as live intake addresses.

They are now is_active = false. Both lookup functions (mise_client_for_email, mise_client_for_report_email) filter on is_active = true, so these addresses no longer resolve to any client at all.

Deactivated, not deleted, on purpose: the row and its client_id stay recoverable with a single flip if one is ever needed for history.

NOTE ON THE NIGHTLY REPORT PATH: sales@in.miseai-0000.com was the ONLY nightly_report route. There is now no active nightly-report address at all. If nightly report ingestion is wanted later, a replacement row on miseai0010.com has to be added with route_kind = nightly_report. The invoice path is unaffected.

LIVE INTAKE AFTER THIS CHANGE: invoices@miseai0010.com -> Cellar. That is the only active route.'
);
