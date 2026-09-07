UPDATE public.security_findings
SET status = 'resolved', resolved_at = now(),
    description = description || ' UPDATE: A password gate was added in front of the whole page (shared access code, not per-client -- matches how this tool is actually used, as one internal ops view across all clients). Requires the REVIEW_ACCESS_CODE secret to be set in the Supabase project for the page to work at all; it fails closed (locked) until then.'
WHERE title = 'Review Queue page has no login and no per-client filtering';
