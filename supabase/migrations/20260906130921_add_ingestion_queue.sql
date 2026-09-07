-- Everything that comes in lands here FIRST, instantly, no matter how much
-- arrives at once. A separate worker drains this steadily, one job at a time,
-- so a busy morning of invoices from ten restaurants never all hit Gemini in
-- the same second.
CREATE TABLE public.ingestion_queue (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id uuid NOT NULL REFERENCES public.clients(id),
  job_type varchar NOT NULL CHECK (job_type IN ('invoice','nightly_report')),
  payload jsonb NOT NULL,
  status varchar NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','processing','done','failed')),
  attempts smallint NOT NULL DEFAULT 0,
  last_error text,
  created_at timestamptz NOT NULL DEFAULT now(),
  started_at timestamptz,
  finished_at timestamptz
);

COMMENT ON TABLE public.ingestion_queue IS 'Landing spot for everything Resend delivers. Written to instantly on arrival; a separate worker function drains it at a controlled pace, one job at a time per call, regardless of how many things arrived together.';
COMMENT ON COLUMN public.ingestion_queue.payload IS 'The files array (name/mimeType/base64 data) exactly as it would be sent to ingest-invoice or ingest-nightly-report -- the worker just replays it when its turn comes.';

CREATE INDEX ingestion_queue_pending_idx ON public.ingestion_queue (created_at) WHERE status = 'pending';

ALTER TABLE public.ingestion_queue ENABLE ROW LEVEL SECURITY;
-- No anon/authenticated policies -- only service-role (edge functions) touch this.

-- Grabs the oldest pending job and marks it processing, atomically, so two
-- worker runs overlapping in time never grab the same job twice.
CREATE OR REPLACE FUNCTION public.mise_claim_next_queue_job()
RETURNS public.ingestion_queue
LANGUAGE plpgsql
AS $function$
DECLARE
  v_job public.ingestion_queue;
BEGIN
  SELECT * INTO v_job FROM public.ingestion_queue
   WHERE status = 'pending'
   ORDER BY created_at ASC
   LIMIT 1
   FOR UPDATE SKIP LOCKED;

  IF v_job.id IS NOT NULL THEN
    UPDATE public.ingestion_queue
       SET status = 'processing', started_at = now(), attempts = attempts + 1
     WHERE id = v_job.id
     RETURNING * INTO v_job;
  END IF;

  RETURN v_job;
END;
$function$;
