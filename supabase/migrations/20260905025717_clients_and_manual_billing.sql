-- Every table carries client_id and nothing defines what a client IS. There is
-- no restaurant name, no contact, no way to tell a paying customer from a
-- trial, and no way to switch anyone off. Onboarding is manual and billing is
-- monthly by Venmo, so this doesn't need a payment processor - it needs a
-- customer list and a way to record who has paid.

CREATE TABLE IF NOT EXISTS public.clients (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name           text NOT NULL,
  slug           varchar UNIQUE,
  contact_name   text,
  contact_email  text,
  contact_phone  text,
  timezone       text NOT NULL DEFAULT 'America/Los_Angeles',

  -- Manual billing. No processor, no webhooks, no card on file.
  status         varchar NOT NULL DEFAULT 'trial'
                 CHECK (status IN ('trial','active','past_due','paused','cancelled')),
  monthly_rate   numeric,
  billing_day    smallint CHECK (billing_day BETWEEN 1 AND 28),
  venmo_handle   text,
  trial_ends_on  date,
  started_on     date,
  cancelled_on   date,
  notes          text,

  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.clients IS
  'One row per restaurant. status is the switch: anything other than active or trial means the app should stop serving them.';
COMMENT ON COLUMN public.clients.billing_day IS
  'Day of the month the Venmo request goes out. Capped at 28 so it exists in February.';

-- Adopt the restaurant already in the data rather than leaving it orphaned.
INSERT INTO public.clients (id, name, slug, status, started_on, notes)
VALUES ('7d1f0a2e-6c44-4b9a-9f31-2ab8e5c07d10', 'Cellar', 'cellar', 'active', '2026-09-01',
        'First restaurant. Invoices arrive at invoice@ and invoices@in.miseai-0000.com.')
ON CONFLICT (id) DO NOTHING;

-- Now the references can be real.
ALTER TABLE public.invoices             ADD CONSTRAINT invoices_client_fk             FOREIGN KEY (client_id) REFERENCES public.clients(id) ON DELETE CASCADE;
ALTER TABLE public.client_email_routes  ADD CONSTRAINT client_email_routes_client_fk  FOREIGN KEY (client_id) REFERENCES public.clients(id) ON DELETE CASCADE;
ALTER TABLE public.client_routing_hints ADD CONSTRAINT client_routing_hints_client_fk FOREIGN KEY (client_id) REFERENCES public.clients(id) ON DELETE CASCADE;
ALTER TABLE public.ingredients          ADD CONSTRAINT ingredients_client_fk          FOREIGN KEY (client_id) REFERENCES public.clients(id) ON DELETE CASCADE;
ALTER TABLE public.prep_items           ADD CONSTRAINT prep_items_client_fk           FOREIGN KEY (client_id) REFERENCES public.clients(id) ON DELETE CASCADE;
ALTER TABLE public.prep_day             ADD CONSTRAINT prep_day_client_fk             FOREIGN KEY (client_id) REFERENCES public.clients(id) ON DELETE CASCADE;

-- One row per Venmo payment received. Typed in by hand, which is the point.
CREATE TABLE IF NOT EXISTS public.client_payments (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id    uuid NOT NULL REFERENCES public.clients(id) ON DELETE CASCADE,
  period       varchar NOT NULL,              -- 'YYYY-MM', the month being paid for
  amount       numeric NOT NULL,
  paid_on      date NOT NULL DEFAULT current_date,
  method       varchar NOT NULL DEFAULT 'venmo',
  reference    text,
  note         text,
  recorded_at  timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS client_payments_period_key ON public.client_payments (client_id, period);

/**
 * Who to chase this month. One screen: what they owe, whether it landed, and
 * how much work the app actually did for them - because that is the number that
 * makes a Venmo request easy to send.
 */
CREATE OR REPLACE VIEW public.billing_this_month AS
SELECT c.id AS client_id,
       c.name,
       c.status,
       c.monthly_rate,
       c.billing_day,
       c.venmo_handle,
       to_char(current_date, 'YYYY-MM')            AS period,
       p.amount                                    AS paid_amount,
       p.paid_on,
       (p.id IS NOT NULL)                          AS paid,
       CASE WHEN c.status IN ('active','trial') AND p.id IS NULL
            THEN coalesce(c.monthly_rate, 0) ELSE 0 END AS owed,
       (SELECT count(*) FROM public.invoices i
         WHERE i.client_id = c.id
           AND i.merged_into IS NULL
           AND to_char(i.created_at, 'YYYY-MM') = to_char(current_date, 'YYYY-MM')) AS invoices_this_month,
       (SELECT round(sum(li.line_total), 2)
          FROM public.invoices i
          JOIN public.invoice_line_items li ON li.invoice_id = i.id
         WHERE i.client_id = c.id
           AND i.merged_into IS NULL
           AND li.removed_by_review IS NOT TRUE
           AND to_char(i.created_at, 'YYYY-MM') = to_char(current_date, 'YYYY-MM')) AS spend_processed_this_month
  FROM public.clients c
  LEFT JOIN public.client_payments p
    ON p.client_id = c.id AND p.period = to_char(current_date, 'YYYY-MM')
 WHERE c.status <> 'cancelled';

/**
 * Onboard a restaurant in one call: the client, its intake address, and the
 * sender and subject fallbacks that stopped three of your own emails being
 * dropped. Returns the client_id to paste into the app.
 */
CREATE OR REPLACE FUNCTION public.mise_onboard_client(
  p_name          text,
  p_intake_email  text,
  p_contact_email text DEFAULT NULL,
  p_contact_name  text DEFAULT NULL,
  p_monthly_rate  numeric DEFAULT NULL,
  p_venmo         text DEFAULT NULL,
  p_subject_word  text DEFAULT NULL
) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v_id uuid;
BEGIN
  INSERT INTO public.clients (name, slug, contact_name, contact_email, status,
                              monthly_rate, venmo_handle, billing_day, started_on, trial_ends_on)
  VALUES (p_name,
          lower(regexp_replace(p_name, '[^a-zA-Z0-9]+', '-', 'g')),
          p_contact_name, p_contact_email, 'trial',
          p_monthly_rate, p_venmo, 1, current_date, current_date + 14)
  RETURNING id INTO v_id;

  INSERT INTO public.client_email_routes (client_id, email_address, restaurant_name, is_active)
  VALUES (v_id, lower(trim(p_intake_email)), p_name, true)
  ON CONFLICT DO NOTHING;

  -- The sender fallback: a forwarded invoice from the owner's own phone still
  -- routes even when they send to a slightly wrong address.
  IF p_contact_email IS NOT NULL THEN
    INSERT INTO public.client_routing_hints (client_id, kind, value, note)
    VALUES (v_id, 'sender', lower(trim(p_contact_email)), 'Owner address; routes their forwards.')
    ON CONFLICT DO NOTHING;
  END IF;

  IF p_subject_word IS NOT NULL THEN
    INSERT INTO public.client_routing_hints (client_id, kind, value, note)
    VALUES (v_id, 'subject_keyword', p_subject_word, 'Word this restaurant puts in the subject line.')
    ON CONFLICT DO NOTHING;
  END IF;

  RETURN v_id;
END;
$$;

COMMENT ON FUNCTION public.mise_onboard_client IS
  'One call to onboard: client row, intake address, sender and subject fallbacks. Returns the client_id for CORR_RESTAURANT_ID in the app.';
