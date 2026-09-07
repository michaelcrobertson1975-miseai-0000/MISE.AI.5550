// @ts-nocheck
import { createClient } from 'jsr:@supabase/supabase-js@2';
const json = (b) => new Response(JSON.stringify(b, null, 2), { status: 200, headers: { 'Content-Type': 'application/json' } });
const db = () => createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));

Deno.serve(async (req) => {
  const url = new URL(req.url);
  const restaurantId = url.searchParams.get('restaurant_id');
  const supabase = db();

  const { data: client, error: clientErr } = await supabase.from('clients').select('id, status, api_token').eq('id', restaurantId).maybeSingle();
  if (clientErr) return json({ step: 'client', error: clientErr });

  const steps = [
    ['stations', () => supabase.from('prep_stations').select('*').order('sort_order', { ascending: true })],
    ['units', () => supabase.from('prep_units').select('*')],
    ['items', () => supabase.from('prep_items').select('*').eq('client_id', client.id)],
    ['recipes', () => supabase.from('prep_recipes').select('*')],
    ['day', () => supabase.from('prep_day').select('*').eq('client_id', client.id).eq('service_date', new Date().toISOString().slice(0,10))],
  ];
  const out = {};
  for (const [key, run] of steps) {
    try {
      const { data, error, status, statusText } = await run();
      out[key] = error ? { error, status, statusText } : { count: (data ?? []).length, sample: (data ?? [])[0] ?? null };
    } catch (err) {
      out[key] = { thrown: String(err?.message ?? err), stack: err?.stack };
    }
  }
  return json({ client, out });
});
