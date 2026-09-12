-- mise_apply_correction() is SECURITY DEFINER and was still directly
-- executable by anon/authenticated via /rest/v1/rpc/mise_apply_correction
-- (Supabase's default grant for new functions). That meant the access-code
-- cookie gating review/correct never actually protected this RPC: anyone
-- holding the anon key -- which this project deliberately exposes on other
-- public pages (upload, upload-scan) -- could call it directly and write
-- corrections to ANY client's invoice_line_items, no cookie required.
--
-- Only review and correct call this RPC, and both now proxy every call
-- through their edge function using SUPABASE_SERVICE_ROLE_KEY (see
-- 20260912223317's proxy rewrite of both functions), so revoking public
-- EXECUTE breaks nothing and closes the gap.

revoke execute on function public.mise_apply_correction(uuid, jsonb, text, boolean) from anon;
revoke execute on function public.mise_apply_correction(uuid, jsonb, text, boolean) from authenticated;
