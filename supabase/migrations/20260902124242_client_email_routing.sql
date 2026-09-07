-- Each restaurant forwards invoices to its own address. The address is what
-- identifies the client, so nothing has to be configured per-webhook and adding
-- a restaurant is one row, not a redeploy.
CREATE TABLE IF NOT EXISTS client_email_routes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id UUID NOT NULL,
    email_address TEXT NOT NULL,
    restaurant_name TEXT,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Addresses are case-insensitive; store however, match lowercased.
CREATE UNIQUE INDEX IF NOT EXISTS client_email_routes_address_idx
    ON client_email_routes (lower(email_address));

-- Resolve a recipient address to a client. Handles plus-addressing
-- (cellar+dec@… -> cellar@…) so a restaurant can tag forwards without breaking.
CREATE OR REPLACE FUNCTION mise_client_for_email(p_address TEXT)
RETURNS UUID AS $$
DECLARE
  addr TEXT := lower(trim(coalesce(p_address, '')));
  base TEXT;
  found UUID;
BEGIN
  -- Strip a display name: "The Cellar <cellar@x.com>" -> cellar@x.com
  IF addr LIKE '%<%>%' THEN
    addr := substring(addr FROM '<([^>]+)>');
  END IF;

  SELECT client_id INTO found FROM client_email_routes
   WHERE lower(email_address) = addr AND is_active LIMIT 1;
  IF found IS NOT NULL THEN RETURN found; END IF;

  -- Retry without the +tag.
  base := regexp_replace(addr, '\+[^@]*@', '@');
  SELECT client_id INTO found FROM client_email_routes
   WHERE lower(email_address) = base AND is_active LIMIT 1;
  RETURN found;
END;
$$ LANGUAGE plpgsql STABLE;

INSERT INTO client_email_routes (client_id, email_address, restaurant_name)
VALUES ('7d1f0a2e-6c44-4b9a-9f31-2ab8e5c07d10', 'cellar@mise.ai-0000.com', 'The Cellar — Benicia')
ON CONFLICT DO NOTHING;

SELECT email_address, restaurant_name,
       mise_client_for_email('The Cellar <CELLAR+dec@mise.ai-0000.com>') AS plus_tag_resolves
FROM client_email_routes;
