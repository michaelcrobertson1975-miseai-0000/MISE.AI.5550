-- Three emails carrying eight photos each were dropped because the address said
-- invoice@ and the route table said invoices@. The subject line said "Cellar0010"
-- the whole time. An invoice should only be turned away after every identifier
-- on the message has been tried - and even then it should be visible, not gone.

CREATE TABLE IF NOT EXISTS public.client_routing_hints (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id  uuid NOT NULL,
  kind       varchar NOT NULL CHECK (kind IN ('to_address','sender','subject_keyword')),
  value      text NOT NULL,
  note       text,
  is_active  boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS client_routing_hints_key ON public.client_routing_hints (kind, lower(value));

COMMENT ON TABLE public.client_routing_hints IS
  'Extra ways to tell whose invoice an email carries, tried in order after client_email_routes: the sender address, then a keyword in the subject. Onboarding stays one row per identifier, no redeploy.';

-- Anything that still cannot be routed lands here rather than being answered 200
-- and forgotten. This is the drawer the lost invoices go in.
CREATE TABLE IF NOT EXISTS public.unrouted_emails (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sender      text,
  recipients  text[],
  subject     text,
  attachments text[],
  reason      text,
  resolved    boolean NOT NULL DEFAULT false,
  received_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS unrouted_emails_open_idx ON public.unrouted_emails (received_at DESC) WHERE resolved IS FALSE;

COMMENT ON TABLE public.unrouted_emails IS
  'Inbound mail whose restaurant could not be identified. Resend was told 200 and will never resend, so without this row the invoice is simply lost.';

/**
 * Resolve a client from everything the message carries, cheapest first:
 *   1. the address it was sent TO   (client_email_routes)
 *   2. the address it was sent TO   (routing hints)
 *   3. who sent it
 *   4. a keyword in the subject, e.g. "Cellar0010" matching hint 'CELLAR'
 */
CREATE OR REPLACE FUNCTION public.mise_route_email(
  p_recipients text[],
  p_sender     text DEFAULT NULL,
  p_subject    text DEFAULT NULL
) RETURNS TABLE (client_id uuid, matched_on text, matched_value text)
LANGUAGE sql STABLE AS $$
  WITH tos AS (SELECT lower(trim(unnest(coalesce(p_recipients, '{}')))) AS addr)
  SELECT r.client_id, 'to_address'::text, t.addr
    FROM public.client_email_routes r JOIN tos t ON lower(r.email_address) = t.addr
   WHERE r.is_active
  UNION ALL
  SELECT h.client_id, 'to_address_hint'::text, t.addr
    FROM public.client_routing_hints h JOIN tos t ON lower(h.value) = t.addr
   WHERE h.is_active AND h.kind = 'to_address'
  UNION ALL
  SELECT h.client_id, 'sender'::text, lower(trim(p_sender))
    FROM public.client_routing_hints h
   WHERE h.is_active AND h.kind = 'sender'
     AND p_sender IS NOT NULL AND lower(h.value) = lower(trim(p_sender))
  UNION ALL
  SELECT h.client_id, 'subject_keyword'::text, h.value
    FROM public.client_routing_hints h
   WHERE h.is_active AND h.kind = 'subject_keyword'
     AND p_subject IS NOT NULL AND p_subject ILIKE '%' || h.value || '%'
  LIMIT 1;
$$;

-- Seed what this restaurant actually sends from and titles its emails.
INSERT INTO public.client_routing_hints (client_id, kind, value, note) VALUES
  ('7d1f0a2e-6c44-4b9a-9f31-2ab8e5c07d10', 'sender',          'jennheitz2@icloud.com', 'Owner phone, forwards invoices directly.'),
  ('7d1f0a2e-6c44-4b9a-9f31-2ab8e5c07d10', 'subject_keyword', 'Cellar',                'Subjects arrive as Cellar0010, Cellar00010.')
ON CONFLICT DO NOTHING;
