-- M7. Hardening the memory invariant.
--
-- A "correction" that clears a field, or that sets chef_category to the chef
-- app's placeholder 'uncategorized', is NOT knowledge. Before this, such a save
-- would have written a memory row teaching the system to blank the field or to
-- call the item uncategorised on every future invoice -- the exact opposite of
-- the point, and it would have overridden a perfectly good extraction.
--
-- The line still updates and the audit row is still written. Only the MEMORY
-- confirmation is withheld. Unknown stays unknown.

CREATE OR REPLACE FUNCTION public.mise_confirmable(p_field text, p_value text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT CASE
    WHEN p_value IS NULL OR btrim(p_value) = '' THEN false
    WHEN p_field = 'chef_category' AND lower(btrim(p_value)) = 'uncategorized' THEN false
    ELSE true
  END;
$function$;

COMMENT ON FUNCTION public.mise_confirmable(text,text) IS
  'Is this corrected value real knowledge worth remembering? A cleared field and the placeholder chef_category "uncategorized" are not.';
