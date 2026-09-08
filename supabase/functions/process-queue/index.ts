// @ts-nocheck
/**
 * Queue worker - drains ingestion_queue and replays each job to the real
 * ingestion function (ingest-invoice or ingest-nightly-report).
 *
 * PACING. This used to claim exactly ONE job per invocation, and cron calls it
 * once a minute, which capped the whole platform at 60 invoices an hour no
 * matter how many restaurants were sending. It now drains in a loop until a
 * time budget is spent, so a forty-invoice Monday morning clears in minutes
 * instead of forty. The real throttle that matters is model calls, and that
 * belongs in ingest-invoice (which bounds its own per-page concurrency), not
 * here.
 *
 * RETRIES. A failure used to be terminal: any non-2xx marked the job 'failed'
 * forever, and since email-inbound already returned 200 to the mail provider,
 * the invoice was simply gone. Gemini returns 429 and 503 routinely under
 * load, so that lost real invoices. Now a retryable failure goes back to
 * 'pending' and is picked up on a later tick, up to MAX_ATTEMPTS. A job that
 * fails for a reason retrying cannot fix (an unreadable payload, an unknown
 * job type) still fails immediately rather than burning three lots of
 * extraction spend on it.
 *
 * A job re-queued during this invocation is not retried again in the same
 * invocation - the drain stops when it comes back around, so a persistently
 * failing job can never spin the loop.
 *
 *   POST (no body needed) -> drains until the queue is empty or the budget is spent
 */
import { createClient } from 'jsr:@supabase/supabase-js@2';

const json = (body, status = 200) =>
  new Response(JSON.stringify(body, null, 2), { status, headers: { 'Content-Type': 'application/json' } });

const FUNCTION_FOR_JOB_TYPE = {
  invoice: 'ingest-invoice',
  nightly_report: 'ingest-nightly-report',
};

/** Edge functions get ~150s; stop claiming new work well before that. */
const TIME_BUDGET_MS = 100_000;
const MAX_ATTEMPTS = 3;

/**
 * Worth trying again, or not? Rate limits, upstream errors and dropped
 * connections are transient. A 4xx means this payload will fail the same way
 * every time, and each attempt costs another extraction.
 */
const isRetryable = (status) => status === 429 || status === 408 || status >= 500;

Deno.serve(async (req) => {
  if (req.method !== 'POST' && req.method !== 'GET') return json({ error: 'POST to run.' }, 405);

  const db = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  const base = Deno.env.get('SUPABASE_URL');

  const startedAt = Date.now();
  const seen = new Set();
  const processed = [];
  let requeued = 0;
  let failed = 0;

  while (Date.now() - startedAt < TIME_BUDGET_MS) {
    const { data: job, error: claimErr } = await db.rpc('mise_claim_next_queue_job');
    if (claimErr) {
      console.error('[queue] claim failed:', claimErr.message);
      return json({ error: claimErr.message, processed }, 500);
    }
    if (!job || !job.id) break;                       // queue empty

    // Already attempted in this run and put back - leave it for a later tick.
    if (seen.has(job.id)) {
      await db.from('ingestion_queue').update({ status: 'pending' }).eq('id', job.id);
      break;
    }
    seen.add(job.id);

    const targetFn = FUNCTION_FOR_JOB_TYPE[job.job_type];
    if (!targetFn) {
      await db.from('ingestion_queue').update({
        status: 'failed', last_error: `Unknown job_type: ${job.job_type}`, finished_at: new Date().toISOString(),
      }).eq('id', job.id);
      failed++;
      processed.push({ job_id: job.id, ok: false, error: `Unknown job_type: ${job.job_type}` });
      continue;
    }

    console.log(`[queue] processing job=${job.id} type=${job.job_type} client=${job.client_id} attempt=${job.attempts}`);

    let outcome;
    try {
      const res = await fetch(`${base}/functions/v1/${targetFn}?client_id=${encodeURIComponent(job.client_id)}`, {
        method: 'POST',
        // The ingestion functions are internal-only and check for this key.
        headers: { Authorization: `Bearer ${serviceKey}`, 'Content-Type': 'application/json' },
        body: JSON.stringify(job.payload),
      });
      const data = await res.json().catch(() => ({}));
      outcome = res.ok
        ? { ok: true, data }
        : { ok: false, retryable: isRetryable(res.status), error: `HTTP ${res.status}: ${JSON.stringify(data).slice(0, 500)}` };
    } catch (err) {
      // A throw here is a network or runtime fault, never the payload's fault.
      outcome = { ok: false, retryable: true, error: err.message };
    }

    if (outcome.ok) {
      await db.from('ingestion_queue').update({ status: 'done', finished_at: new Date().toISOString() }).eq('id', job.id);
      console.log(`[queue] job=${job.id} done`);
      processed.push({ job_id: job.id, ok: true, job_type: job.job_type });
      continue;
    }

    const canRetry = outcome.retryable && job.attempts < MAX_ATTEMPTS;
    if (canRetry) {
      // Back to pending, keeping attempts, so a later tick picks it up. The
      // invoice stays in the system instead of disappearing.
      await db.from('ingestion_queue').update({ status: 'pending', last_error: outcome.error }).eq('id', job.id);
      requeued++;
      console.warn(`[queue] job=${job.id} attempt ${job.attempts}/${MAX_ATTEMPTS} failed, re-queued: ${outcome.error}`);
      processed.push({ job_id: job.id, ok: false, requeued: true, attempts: job.attempts, error: outcome.error });
    } else {
      await db.from('ingestion_queue').update({
        status: 'failed',
        last_error: outcome.retryable ? `Gave up after ${job.attempts} attempts. ${outcome.error}` : outcome.error,
        finished_at: new Date().toISOString(),
      }).eq('id', job.id);
      failed++;
      console.error(`[queue] job=${job.id} failed permanently: ${outcome.error}`);
      processed.push({ job_id: job.id, ok: false, requeued: false, attempts: job.attempts, error: outcome.error });
    }
  }

  return json({
    ok: true,
    drained: processed.length,
    succeeded: processed.filter((p) => p.ok).length,
    requeued,
    failed,
    elapsed_seconds: Number(((Date.now() - startedAt) / 1000).toFixed(1)),
    jobs: processed,
  });
});
