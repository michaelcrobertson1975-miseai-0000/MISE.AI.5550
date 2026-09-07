// @ts-nocheck
/**
 * prep-sync-v2 - backs both the Chef App's "Prep & Cook" manager tab and
 * the Cook App (cookapp5.html) -- the actual tablet-in-the-kitchen app this
 * schema was built for. Both read/write the SAME real prep_items /
 * prep_recipes / prep_day / prep_yield_log rows, so a recipe or par set in
 * one is immediately what the other sees -- no separate sync step needed.
 * (Named -v2: the plain prep-sync slug got stuck returning 500 from its
 * very first, buggy deployment during development and never recovered even
 * after the code was fixed -- abandoned rather than fought further burning
 * session time.)
 *
 * prep_stations and prep_units are GLOBAL lookup tables (code/label/i18n,
 * no client_id) -- same pattern as units/pnl_categories elsewhere in this
 * schema -- prep_items/prep_recipes/prep_day/prep_yield_log are the
 * per-client tables. prep_recipes and prep_items both carry i18n jsonb for
 * the Spanish translations already on file for this client's two
 * written-up recipes, and prep_recipes.is_butchery distinguishes a
 * breakdown item (weigh-in/weigh-out) from a fixed-batch recipe (portion
 * target).
 *
 * AUTH: restaurant_id + api_token must match clients.api_token.
 *
 *   GET /prep-sync-v2?restaurant_id=&api_token=&service_date=YYYY-MM-DD&yield_days=14
 *     -> { stations, units, items (with their recipe if any, and today's
 *          prep_day row), yield_log: last `yield_days` days of
 *          prep_yield_log rows for this client, newest first }
 *
 *   POST /prep-sync-v2  { restaurant_id, api_token, action, ... }
 *     action 'log_day'   { service_date, entries: [{ prep_item_id, on_hand?,
 *                            prepped?, status?, note? }] }
 *       -> upsert one prep_day row per (client, prep_item, service_date).
 *     action 'complete'  { prep_day_id, completed_by? }
 *       -> marks one prep_day row completed_at = now().
 *     action 'log_yield' { prep_item_id, entry_type, status?,
 *                          expected_portions?, actual_portions?,
 *                          weight_in?, weight_out?, raw_cost_per_lb? }
 *       -> inserts one prep_yield_log row (append-only -- never updates a
 *          past entry). For a butchery weight-in, send status:'pending'
 *          with just weight_in (+ raw_cost_per_lb if known).
 *     action 'finish_yield' { related_entry_id, weight_out }
 *       -> inserts a SECOND row that finishes a pending weight-in entry
 *          (rather than mutating the original, keeping the append-only
 *          design intact). Copies weight_in/raw_cost_per_lb forward from
 *          the entry it finishes so the finished row is self-contained.
 *     action 'create_item' { item: { name, station, unit, par? } }
 *       -> a brand-new prep item the chef is adding by hand (the AI
 *          suggestion list missed it). No recipe attached -- that's a
 *          separate, deliberate write-up step, never invented here.
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

function todayStr() { return new Date().toISOString().slice(0, 10); }
const ITEM_CREATABLE = ['name', 'station', 'unit', 'par'];

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  const url = new URL(req.url);
  const supabase = db();

  try {
    if (req.method === 'GET') {
      const auth = await authClient(supabase, url.searchParams.get('restaurant_id'), url.searchParams.get('api_token'));
      if (auth.error) return json({ success: false, error: auth.error }, 401);
      const serviceDate = url.searchParams.get('service_date') || todayStr();
      const yieldDays = Math.max(1, Math.min(90, Number(url.searchParams.get('yield_days') ?? '14') || 14));
      const yieldSince = new Date(Date.now() - yieldDays * 86400000).toISOString();

      const [{ data: stations, error: stErr }, { data: units, error: unErr },
             { data: items, error: itErr }, { data: recipes, error: rcErr },
             { data: day, error: dayErr }, { data: yieldLog, error: ylErr }] = await Promise.all([
        supabase.from('prep_stations').select('*').order('sort_order', { ascending: true }),
        supabase.from('prep_units').select('*'),
        supabase.from('prep_items').select('*').eq('client_id', auth.client.id),
        supabase.from('prep_recipes').select('*'),
        supabase.from('prep_day').select('*').eq('client_id', auth.client.id).eq('service_date', serviceDate),
        supabase.from('prep_yield_log').select('*').eq('client_id', auth.client.id).gte('logged_at', yieldSince).order('logged_at', { ascending: false }),
      ]);
      const firstErr = stErr || unErr || itErr || rcErr || dayErr || ylErr;
      if (firstErr) return json({ success: false, error: firstErr.message }, 500);

      const recipeByItem = new Map((recipes ?? []).map((r) => [r.prep_item_id, r]));
      const dayByItem = new Map((day ?? []).map((d) => [d.prep_item_id, d]));
      const itemsOut = (items ?? []).map((it) => ({
        ...it,
        recipe: recipeByItem.get(it.id) ?? null,
        today: dayByItem.get(it.id) ?? null,
      }));

      return json({ success: true, service_date: serviceDate, stations: stations ?? [], units: units ?? [], items: itemsOut, yield_log: yieldLog ?? [] });
    }

    if (req.method === 'POST') {
      let body;
      try { body = await req.json(); } catch (err) { return json({ success: false, error: `Unparseable body: ${err.message}` }, 400); }
      const auth = await authClient(supabase, body.restaurant_id, body.api_token);
      if (auth.error) return json({ success: false, error: auth.error }, 401);

      if (body.action === 'log_day') {
        const serviceDate = body.service_date || todayStr();
        const entries = Array.isArray(body.entries) ? body.entries : [];
        if (!entries.length) return json({ success: false, error: 'entries[] is required.' }, 400);

        const results = [];
        for (const e of entries) {
          if (!e.prep_item_id) { results.push({ error: 'prep_item_id missing on an entry', entry: e }); continue; }
          const { data: owned } = await supabase.from('prep_items').select('id').eq('id', e.prep_item_id).eq('client_id', auth.client.id).maybeSingle();
          if (!owned) { results.push({ error: 'prep_item_id not found for this restaurant', prep_item_id: e.prep_item_id }); continue; }

          const row = {
            client_id: auth.client.id, prep_item_id: e.prep_item_id, service_date: serviceDate,
            on_hand: e.on_hand ?? null, prepped: e.prepped ?? null, status: e.status ?? null, note: e.note ?? null,
          };
          const { data: existing } = await supabase.from('prep_day').select('id')
            .eq('client_id', auth.client.id).eq('prep_item_id', e.prep_item_id).eq('service_date', serviceDate).maybeSingle();
          if (existing) {
            const { data, error } = await supabase.from('prep_day').update(row).eq('id', existing.id).select('*').single();
            if (error) results.push({ error: error.message, prep_item_id: e.prep_item_id }); else results.push({ ok: true, row: data });
          } else {
            const { data, error } = await supabase.from('prep_day').insert(row).select('*').single();
            if (error) results.push({ error: error.message, prep_item_id: e.prep_item_id }); else results.push({ ok: true, row: data });
          }
        }
        return json({ success: true, service_date: serviceDate, results });
      }

      if (body.action === 'complete') {
        if (!body.prep_day_id) return json({ success: false, error: 'prep_day_id is required.' }, 400);
        const { data, error } = await supabase.from('prep_day')
          .update({ status: 'completed', completed_at: new Date().toISOString(), completed_by: body.completed_by ?? null })
          .eq('id', body.prep_day_id).eq('client_id', auth.client.id).select('*').maybeSingle();
        if (error) return json({ success: false, error: error.message }, 500);
        if (!data) return json({ success: false, error: 'That prep_day row does not belong to this restaurant.' }, 404);
        return json({ success: true, row: data });
      }

      if (body.action === 'log_yield') {
        if (!body.prep_item_id || !body.entry_type) return json({ success: false, error: 'prep_item_id and entry_type are required.' }, 400);
        const { data: owned } = await supabase.from('prep_items').select('id').eq('id', body.prep_item_id).eq('client_id', auth.client.id).maybeSingle();
        if (!owned) return json({ success: false, error: 'prep_item_id not found for this restaurant.' }, 404);

        const row = {
          client_id: auth.client.id, prep_item_id: body.prep_item_id, entry_type: body.entry_type,
          status: body.status ?? null, expected_portions: body.expected_portions ?? null,
          actual_portions: body.actual_portions ?? null, weight_in: body.weight_in ?? null,
          weight_out: body.weight_out ?? null, raw_cost_per_lb: body.raw_cost_per_lb ?? null,
          logged_at: new Date().toISOString(),
        };
        const { data, error } = await supabase.from('prep_yield_log').insert(row).select('*').single();
        if (error) return json({ success: false, error: error.message }, 500);
        return json({ success: true, row: data }, 201);
      }

      if (body.action === 'finish_yield') {
        if (!body.related_entry_id || body.weight_out == null) return json({ success: false, error: 'related_entry_id and weight_out are required.' }, 400);
        const { data: pending, error: findErr } = await supabase.from('prep_yield_log').select('*')
          .eq('id', body.related_entry_id).eq('client_id', auth.client.id).maybeSingle();
        if (findErr) return json({ success: false, error: findErr.message }, 500);
        if (!pending) return json({ success: false, error: 'That entry does not belong to this restaurant.' }, 404);
        if (pending.weight_in == null) return json({ success: false, error: 'That entry has no weight_in to finish.' }, 400);
        if (Number(body.weight_out) > Number(pending.weight_in)) return json({ success: false, error: 'weight_out cannot exceed the original weight_in.' }, 400);

        const row = {
          client_id: auth.client.id, prep_item_id: pending.prep_item_id, entry_type: 'weight',
          status: 'finished', weight_in: pending.weight_in, weight_out: body.weight_out,
          raw_cost_per_lb: pending.raw_cost_per_lb, related_entry_id: pending.id,
          logged_at: new Date().toISOString(),
        };
        const { data, error } = await supabase.from('prep_yield_log').insert(row).select('*').single();
        if (error) return json({ success: false, error: error.message }, 500);

        // Mark the original pending entry so it stops showing as "awaiting finish".
        await supabase.from('prep_yield_log').update({ status: 'closed' }).eq('id', pending.id);

        return json({ success: true, row: data }, 201);
      }

      if (body.action === 'create_item') {
        const fields = {};
        for (const f of ITEM_CREATABLE) if (Object.prototype.hasOwnProperty.call(body.item ?? {}, f)) fields[f] = body.item[f];
        if (!fields.name) return json({ success: false, error: 'name is required.' }, 400);
        if (!fields.station) return json({ success: false, error: 'station is required.' }, 400);
        fields.client_id = auth.client.id;

        const { data, error } = await supabase.from('prep_items').insert(fields).select('*').single();
        if (error) return json({ success: false, error: error.message }, 500);
        return json({ success: true, item: { ...data, recipe: null, today: null } }, 201);
      }

      return json({ success: false, error: `Unknown action "${body.action}". Use "log_day", "complete", "log_yield", "finish_yield", or "create_item".` }, 400);
    }

    return json({ success: false, error: `${req.method} not supported.` }, 405);
  } catch (err) {
    console.error('[prep-sync-v2] unhandled:', err?.message ?? err);
    return json({ success: false, error: err?.message ?? String(err) }, 500);
  }
});
