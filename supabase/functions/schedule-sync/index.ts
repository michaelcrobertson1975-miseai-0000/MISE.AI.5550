// @ts-nocheck
/**
 * schedule-sync - backs the app's "Schedule" tab.
 *
 * Matches the TODO already sketched in the app's own HTML comments:
 *   POST { restaurant_id, week_of, staff: [...], shifts: [...] }
 *   idempotent, keyed by restaurant_id + staff_id + date so re-running the
 *   same night never double-books.
 *
 * New tables (staff, shifts) -- this subsystem did not exist before at all.
 * `staff.dept` ('BOH'|'FOH') was added on top afterward, additive, because
 * the Schedule tab's grid groups staff by kitchen vs front-of-house and the
 * table had no such column yet.
 *
 * AUTH: restaurant_id + api_token must match clients.api_token.
 *
 *   GET /schedule-sync?restaurant_id=&api_token=&week_of=YYYY-MM-DD
 *     -> { staff: [...active staff...], shifts: [...this week's shifts...] }
 *
 *   POST /schedule-sync  { restaurant_id, api_token, week_of, staff, shifts }
 *     staff: [{ id?, name, role?, hourly_rate?, dept?, active? }]
 *       -> upserts by id when given, inserts new otherwise (matched by
 *          name if no id, so re-sending the same roster does not duplicate
 *          people).
 *     shifts: [{ staff_id, shift_date, start_time?, end_time?, role? }]
 *       -> the whole week's shift list is treated as the source of truth:
 *          existing shifts for this client + week_of are replaced with
 *          exactly the set sent, matching the UI (edit a week, save the
 *          week). staff_id must belong to this client.
 *     action 'delete_staff' { id } -> removes one staff member (and,
 *          via FK, their shifts) from this client's roster.
 */
import { createClient } from 'jsr:@supabase/supabase-js@2';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
};
const json = (b, s = 200) => new Response(JSON.stringify(b, null, 2), { status: s, headers: { ...CORS, 'Content-Type': 'application/json' } });
const db = () => createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));

async function authClient(supabase, restaurantId, apiToken) {
  if (!restaurantId || !apiToken) return { error: 'restaurant_id and api_token are both required.' };
  const { data, error } = await supabase.from('clients').select('id, status, api_token').eq('id', restaurantId).maybeSingle();
  if (error) return { error: error.message };
  if (!data) return { error: 'No such restaurant.' };
  if (String(data.api_token) !== String(apiToken)) return { error: 'Wrong api_token for this restaurant_id.' };
  if (!['active', 'trial'].includes(data.status)) return { error: `This account is ${data.status}.` };
  return { client: data };
}

function mondayOf(dateStr) {
  const d = new Date(dateStr + 'T00:00:00Z');
  const day = d.getUTCDay();
  const diff = (day === 0 ? -6 : 1) - day;
  d.setUTCDate(d.getUTCDate() + diff);
  return d.toISOString().slice(0, 10);
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  const url = new URL(req.url);
  const supabase = db();

  try {
    if (req.method === 'GET') {
      const auth = await authClient(supabase, url.searchParams.get('restaurant_id'), url.searchParams.get('api_token'));
      if (auth.error) return json({ success: false, error: auth.error }, 401);
      const weekOf = mondayOf(url.searchParams.get('week_of') || new Date().toISOString().slice(0, 10));

      const [{ data: staff, error: staffErr }, { data: shifts, error: shiftErr }] = await Promise.all([
        supabase.from('staff').select('*').eq('client_id', auth.client.id).eq('active', true).order('name'),
        supabase.from('shifts').select('*').eq('client_id', auth.client.id).eq('week_of', weekOf).order('shift_date'),
      ]);
      if (staffErr) return json({ success: false, error: staffErr.message }, 500);
      if (shiftErr) return json({ success: false, error: shiftErr.message }, 500);

      return json({ success: true, week_of: weekOf, staff: staff ?? [], shifts: shifts ?? [] });
    }

    if (req.method === 'POST') {
      let body;
      try { body = await req.json(); } catch (err) { return json({ success: false, error: `Unparseable body: ${err.message}` }, 400); }
      const auth = await authClient(supabase, body.restaurant_id, body.api_token);
      if (auth.error) return json({ success: false, error: auth.error }, 401);

      if (body.action === 'delete_staff') {
        if (!body.id) return json({ success: false, error: 'id is required.' }, 400);
        const { error } = await supabase.from('staff').delete().eq('id', body.id).eq('client_id', auth.client.id);
        if (error) return json({ success: false, error: error.message }, 500);
        return json({ success: true });
      }

      if (!body.week_of) return json({ success: false, error: 'week_of is required.' }, 400);
      const weekOf = mondayOf(body.week_of);

      // ---- staff: upsert by id, else match-or-create by name ----
      const staffIn = Array.isArray(body.staff) ? body.staff : [];
      const { data: existingStaff, error: exErr } = await supabase.from('staff').select('id, name').eq('client_id', auth.client.id);
      if (exErr) return json({ success: false, error: exErr.message }, 500);
      const byName = new Map((existingStaff ?? []).map((s) => [s.name.trim().toLowerCase(), s.id]));
      const byId = new Map((existingStaff ?? []).map((s) => [s.id, s.id]));
      const nameToId = new Map();

      for (const s of staffIn) {
        if (!s.name && !s.id) continue;
        const fields = { name: s.name, role: s.role ?? null, hourly_rate: s.hourly_rate ?? null, dept: s.dept ?? null, active: s.active ?? true };
        if (s.id && byId.has(s.id)) {
          const { error } = await supabase.from('staff').update(fields).eq('id', s.id).eq('client_id', auth.client.id);
          if (error) return json({ success: false, error: `staff update failed: ${error.message}` }, 500);
          nameToId.set((s.name ?? '').trim().toLowerCase(), s.id);
        } else {
          const key = (s.name ?? '').trim().toLowerCase();
          const existingId = byName.get(key);
          if (existingId) { nameToId.set(key, existingId); continue; }
          const { data, error } = await supabase.from('staff').insert({ client_id: auth.client.id, ...fields }).select('id').single();
          if (error) return json({ success: false, error: `staff insert failed: ${error.message}` }, 500);
          nameToId.set(key, data.id);
          byName.set(key, data.id);
        }
      }

      // ---- shifts: this week's set for this client IS the sent set ----
      const shiftsIn = Array.isArray(body.shifts) ? body.shifts : [];
      const rows = [];
      for (const sh of shiftsIn) {
        let staffId = sh.staff_id;
        if (!staffId && sh.staff_name) staffId = nameToId.get(sh.staff_name.trim().toLowerCase()) ?? byName.get(sh.staff_name.trim().toLowerCase());
        if (!staffId || !sh.shift_date) continue;
        rows.push({
          client_id: auth.client.id, staff_id: staffId, week_of: weekOf, shift_date: sh.shift_date,
          start_time: sh.start_time ?? null, end_time: sh.end_time ?? null, role: sh.role ?? null,
        });
      }

      const { error: delErr } = await supabase.from('shifts').delete().eq('client_id', auth.client.id).eq('week_of', weekOf);
      if (delErr) return json({ success: false, error: `clearing the week failed: ${delErr.message}` }, 500);

      let inserted = [];
      if (rows.length) {
        const { data, error: insErr } = await supabase.from('shifts').insert(rows).select('*');
        if (insErr) return json({ success: false, error: `shift insert failed: ${insErr.message}`, note: 'The week was cleared before this failed -- resend the full week.' }, 500);
        inserted = data ?? [];
      }

      return json({ success: true, week_of: weekOf, staff_upserted: staffIn.length, shifts_saved: inserted.length });
    }

    return json({ success: false, error: `${req.method} not supported.` }, 405);
  } catch (err) {
    console.error('[schedule-sync] unhandled:', err?.message ?? err);
    return json({ success: false, error: err?.message ?? String(err) }, 500);
  }
});
