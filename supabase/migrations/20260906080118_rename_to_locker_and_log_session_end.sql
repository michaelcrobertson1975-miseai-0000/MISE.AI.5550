ALTER TABLE public.project_milestones RENAME TO locker_milestones;
ALTER TABLE public.security_findings RENAME TO locker_findings;
ALTER TABLE public.open_issues RENAME TO locker_issues;
ALTER VIEW public.project_status RENAME TO locker_status;

COMMENT ON TABLE public.locker_milestones IS 'The "locker" -- where session summaries, process notes, and status get stored for any future session (human or AI) to read before starting work.';

INSERT INTO public.locker_milestones (title, summary) VALUES
(
  'Process example: how a false-positive flag was diagnosed and fixed',
  'CASE STUDY for future sessions, not just a fix log. Two lines on a real Sysco invoice (a packer face mask line, a fuel surcharge line) were always getting flagged for human review even though nothing was wrong.

DIAGNOSTIC PROCESS FOLLOWED:
1. Did not assume the flag meant a reading error. Pulled the exact stored field values (raw_pack, raw_size, raw_uom, total_base_units, pack_confidence) from Postgres first.
2. Cross-checked those stored values against a real photo of the invoice the user uploaded, character by character, before concluding anything -- confirmed Gemini had transcribed it correctly (not an OCR problem).
3. Traced the actual Postgres function logic (mise_parse_pack, mise_line_item_math) line by line to find exactly which condition caused each flag, rather than guessing or re-reading the prompt.
4. Distinguished two different root causes that looked similar on the surface: (a) mask -- a real pattern gap in mise_parse_pack (no rule for "pack number + bare known unit in separate fields", e.g. 150 + CT) (b) fuel surcharge -- a correct identification (confidence already high) undone by a downstream check (unit_problem) that did not know a fee row is supposed to have no quantity.
5. Explicitly considered and rejected editing the Gemini prompt, explaining WHY that would break something else (invoice math reconciliation depends on every dollar being transcribed, food or not).
6. Proposed both fixes in plain language and got explicit sign-off before writing any SQL.
7. Verification was two-layered: first re-triggered the fix against the existing flagged rows to confirm the logic change worked in isolation, THEN asked the user to resend the actual source invoice through the real end-to-end pipeline (email -> Resend -> edge -> Gemini -> Postgres) from scratch, to prove the fix holds under real conditions, not just a forced re-check.

PRINCIPLE: add a narrow, additive rule for the exact gap found; never widen a check to "stop flagging this category" without understanding the specific pattern being missed. Genuine low-confidence or math-mismatch lines still flag correctly after these changes -- confirmed by the fact only these two specific line types changed behavior, nothing else did.'
),
(
  'Session end-of-day summary',
  'FULLY RESOLVED THIS SESSION: All 4 original security findings (RLS disabled project-wide, Review Queue exposure, api function trust gap addressed via new clients.api_token column, inbound webhook token flagged). Review Queue now has a real password gate (REVIEW_ACCESS_CODE secret) instead of being wide open. Six SECURITY DEFINER views that could have bypassed the RLS fix were also caught and closed. Two genuine Postgres logic bugs fixed and verified end-to-end on a real resent invoice: bare-count pack units (e.g. "150 CT") and fee/charge rows (e.g. fuel surcharge) no longer get falsely flagged for human review.

STILL OPEN, LOW PRIORITY: ~18 functions could have search_path hardening added (locker_findings has full detail) -- not an active data exposure, just tidiness, no rush.

STILL OPEN, NOT YET WIRED UP: the new clients.api_token column exists on every client row but nothing reads or checks it yet -- the api edge function itself was never modified to require it. That is a real next step, not a finished fix -- do not assume it is enforced.

WORKING AGREEMENT REINFORCED THIS SESSION: no migrations, schema changes, or edge function deploys without the user explicitly saying go on that specific thing. Read-only checks are always fine and encouraged. When the user says "you decide," pick the safest option that does not break anything currently working, explain the choice plainly, and still tell them exactly what changed afterward -- do not skip the explanation just because permission was blanket.'
);
