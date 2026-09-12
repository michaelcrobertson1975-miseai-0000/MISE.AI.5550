insert into locker_milestones (title, summary) values (
'READ THIS FIRST — organized current status + priority list (as of Sept 9, 2026)',
'This entry exists to save a future session from piecing together the full picture from many scattered locker entries. Read this one first, then dig into locker_issues/locker_findings for detail on any specific item below.

=== DONE, CONFIRMED WORKING ===
- Email pipeline is LIVE end-to-end on miseai0010.com (the new domain). Real email -> Resend -> email-inbound -> ingestion_queue -> process-queue -> Gemini (gemini-3.7-flash) -> Postgres audit -> finished invoice. Proven with a real invoice, not a test button. See milestone "Email pipeline now LIVE end-to-end..." for full detail.
- Old dead domain miseai-0000.com fully removed from Resend. Gone for good, not coming back.
- RLS enabled on all 21 public tables. 16 fully locked to anon/authenticated.
- Postgres does all invoice math/auditing (mise_line_item_math, mise_audit_invoice) — Gemini is transcription only, confirmed by design and by the real test.

=== OPEN, HIGH PRIORITY (real security exposure) ===
1. api function (review-queue, invoices/lines, price-moves) trusts a client-supplied restaurant_id with NO ownership check. CORS fully open, verify_jwt false. Anyone with/guessing a client UUID can read or modify that restaurant''s data. See locker_findings d7373ad5.
2. 5 tables (invoices, invoice_line_items, ingredients, pnl_categories, invoice_corrections) still allow anon access scoped to what Review Queue needs, but with no per-client filtering. Review Queue has a shared password gate now (REVIEW_ACCESS_CODE), not per-restaurant. See locker_findings 9ac158b0.

=== OPEN, MUST FIX BEFORE REAL CUSTOMERS USE THE SYSTEM ===
3. signup falls back to the DEAD domain (in.miseai-0000.com / michael@miseai-0000.com) if MISE_MAIL_DOMAIN / MISE_OWNER_EMAIL secrets are not set in Supabase. Fix: set both secrets to miseai0010.com values before anyone signs up for real. See locker_issues (signup-flow area).
4. ingest-nightly-report only reads files[0] — extra attachments in one email are silently dropped, no error. Also never confirmed against a real nightly report (assumes image/PDF, unverified). See locker_issues (nightly-report-ingestion area).
5. Whether INBOUND_TOKEN is actually set has never been directly confirmed either way. See locker_findings aa47c271.

=== OPEN, LOWER PRIORITY / NOT YET BUILT ===
6. beverage_boms has ZERO rows. Nothing can deplete bar inventory yet. Blocked on getting real menu/pour names from the restaurant (distributor invoice names don''t match what''s called behind the bar) — do not fabricate plausible names to fill this gap.
7. Bar/beverage math is NOT one-size-fits-all: wine/spirits/kegs are simple 1:1 pour depletion, but fountain drinks (syrup ratio), coffee (bean-to-brew yield), and diluted juice each need their own conversion factor. Do not build these as one uniform system.
8. beverage_variance_log is permanently blocked until a real POS feed exists for units-sold — the inventory/BOM tables themselves are buildable without it, variance tracking is not.
9. ~18 mise_* Postgres functions have a mutable search_path (medium/low hardening gap, not an active exploit path today). See locker_findings 2309fefa.
10. Full key rotation (Resend, Supabase, Gemini, everything) planned for right before launch, deliberately not done piecemeal. Not yet scheduled.
11. The external Cloud Run Daily/Weekly Brief service was never confirmed working end-to-end — only its fake demo fallback was removed from the Chef App frontend.

=== WORKING AGREEMENTS TO CARRY FORWARD ===
- Mikey does not write code — plain explanations, step-by-step build sheets when action is needed, no unexplained jargon.
- No migrations, schema changes, or edge function deploys without explicit sign-off on that specific thing. Read-only checks (viewing code, querying data/logs) are always fine and encouraged without asking first.
- When told "you decide," pick the safest option that does not break anything currently working, explain the choice plainly, and still say what changed afterward.
- THE LOCKER (this table + locker_issues + locker_findings) is the single source of truth for project status. A separate markdown handoff file was retired in favor of this — do not recreate a second parallel doc.'
);
