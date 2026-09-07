// @ts-nocheck
/**
 * Queue worker - claims ONE job at a time from ingestion_queue and replays it
 * to the real ingestion function (ingest-invoice or ingest-nightly-report).
 *
 * This is the "one ticket at a time" pacing piece: no matter how many emails
 * land in the same minute, this only ever processes one job per invocation.
 * A cron schedule calls this repeatedly, so the queue drains steadily instead
 * of everything hitting Gemini at once.
 *
 *   POST (no body needed) -> claims and processes the oldest pending job, if any
 */
import { createClient } from 'jsr:@supabase/supabase-js@2';

const json = (body, status = 200) =>
  new Response(JSON.stringify(body, null, 2), { status, headers: { 'Content-Type': 'application/json' } });

const FUNCTION_FOR_JOB_TYPE = {
  invoice: 'ingest-invoice',
  nightly_report: 'ingest-nightly-report',
};

Deno.serve(async (req) => {
  if (req.method !== 'POST' && req.method !== 'GET') return json({ error: 'POST to run.' }, 405);

  const db = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY');
  const base = Deno.env.get('SUPABASE_URL');

  const { data: job, error: claimErr } = await db.rpc('mise_claim_next_queue_job');
  if (claimErr) {
    console.error('[queue] claim failed:', claimErr.message);
    return json({ error: claimErr.message }, 500);
  }
  if (!job || !job.id) {
    return json({ ok: true, note: 'Queue empty - nothing to do.' });
  }

  const targetFn = FUNCTION_FOR_JOB_TYPE[job.job_type];
  if (!targetFn) {
    await db.from('ingestion_queue').update({
      status: 'failed', last_error: `Unknown job_type: ${job.job_type}`, finished_at: new Date().toISOString(),
    }).eq('id', job.id);
    return json({ ok: false, job_id: job.id, error: `Unknown job_type: ${job.job_type}` });
  }

  console.log(`[queue] processing job=${job.id} type=${job.job_type} client=${job.client_id} attempt=${job.attempts}`);

  try {
    const res = await fetch(`${base}/functions/v1/${targetFn}?client_id=${encodeURIComponent(job.client_id)}`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${anonKey}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(job.payload),
    });
    const data = await res.json().catch(() => ({}));

    if (!res.ok) {
      console.error(`[queue] job=${job.id} failed: HTTP ${res.status} ${JSON.stringify(data).slice(0, 300)}`);
      await db.from('ingestion_queue').update({
        status: 'failed', last_error: `HTTP ${res.status}: ${JSON.stringify(data).slice(0, 500)}`,
        finished_at: new Date().toISOString(),
      }).eq('id', job.id);
      return json({ ok: false, job_id: job.id, error: data });
    }

    await db.from('ingestion_queue').update({ status: 'done', finished_at: new Date().toISOString() }).eq('id', job.id);
    console.log(`[queue] job=${job.id} done`);
    return json({ ok: true, job_id: job.id, job_type: job.job_type, result: data });
  } catch (err) {
    console.error(`[queue] job=${job.id} threw: ${err.message}`);
    await db.from('ingestion_queue').update({
      status: 'failed', last_error: err.message, finished_at: new Date().toISOString(),
    }).eq('id', job.id);
    return json({ ok: false, job_id: job.id, error: err.message }, 500);
  }
});
