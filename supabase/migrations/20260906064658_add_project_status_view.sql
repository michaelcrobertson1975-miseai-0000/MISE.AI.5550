CREATE OR REPLACE VIEW public.project_status AS
SELECT 'milestone' AS category, title, summary AS detail, NULL::varchar AS severity, NULL::varchar AS status, created_at AS logged_at
  FROM public.project_milestones
UNION ALL
SELECT 'security_finding', title, description, severity, status, found_at
  FROM public.security_findings
UNION ALL
SELECT 'open_issue', title, description, NULL, status, created_at
  FROM public.open_issues
ORDER BY logged_at DESC;

COMMENT ON VIEW public.project_status IS 'One combined, dated timeline of milestones, security findings, and open issues -- the single starting point for picking this project back up.';
