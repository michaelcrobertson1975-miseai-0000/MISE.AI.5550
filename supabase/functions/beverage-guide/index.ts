// @ts-nocheck
/**
 * beverage-guide - backs the app's "Order Beverage" tab.
 *
 * Reads and writes the REAL public.beverage_items table (5 real rows for
 * this client already, tied to real invoice cost data) -- not a parallel
 * demo-shaped table. The ordering-only columns (vendor, par_base_units,
 * purchase_unit_label, purchase_unit_price, approved, skipped) were added
 * to that same table so there is one row per beverage, not two.
 *
 * cost_per_base_unit and total_base_units_in_stock are OWNED by the
 * invoice-costing/depletion pipeline -- this endpoint never writes them,
 * only reads them alongside the ordering fields it does own.
 *
 * AUTH: custom, matching this project's other client-facing functions --
 * restaurant_id + api_token must match clients.api_token.
 *
 *   GET  /beverage-guide?restaurant_id=&api_token=
 *     -> { items: [...] }
 *
 *   POST /beverage-guide  { restaurant_id, api_token, action, ... }
 *     action 'update'  { id, patch: { vendor?, par_base_units?,
 *                          purchase_unit_label?, purchase_unit_price?,
 *                          approved?, skipped? } }
 *       -> patches ordering fields on one beverage item this client owns.
 *     action 'create'  { item: { name, category, base_unit, vendor?,
 *                          par_base_units?, purchase_unit_label?,
 *                          purchase_unit_price? } }
 *       -> a brand-new beverage the restaurant is adding by hand (not yet
 *          seen on an invoice). total_base_units_in_stock/cost_per_base_unit
 *          start null and fill in once a real invoice line gets matched to
 *          it, same as every other beverage_items row.
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

const PATCHABLE = ['vendor', 'par_base_units', 'purchase_unit_label', 'purchase_unit_price', 'approved', 'skipped'];
const CREATABLE = ['name', 'category', 'base_unit', 'vendor', 'par_base_units', 'purchase_unit_label', 'purchase_unit_price'];

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  const url = new URL(req.url);
  const supabase = db();

  try {
    if (req.method === 'GET') {
      const auth = await authClient(supabase, url.searchParams.get('restaurant_id'), url.searchParams.get('api_token'));
      if (auth.error) return json({ success: false, error: auth.error }, 401);

      const { data, error } = await supabase.from('beverage_items')
        .select('*').eq('client_id', auth.client.id)
        .order('category', { ascending: true }).order('name', { ascending: true });
      if (error) return json({ success: false, error: error.message }, 500);

      const items = (data ?? []).map((it) => ({
        ...it,
        below_par: it.par_base_units != null && it.total_base_units_in_stock != null
          ? it.total_base_units_in_stock < it.par_base_units : null,
      }));
      return json({ success: true, items });
    }

    if (req.method === 'POST') {
      let body;
      try { body = await req.json(); } catch (err) { return json({ success: false, error: `Unparseable body: ${err.message}` }, 400); }
      const auth = await authClient(supabase, body.restaurant_id, body.api_token);
      if (auth.error) return json({ success: false, error: auth.error }, 401);

      if (body.action === 'update') {
        if (!body.id) return json({ success: false, error: 'id is required.' }, 400);
        const patch = {};
        for (const f of PATCHABLE) if (Object.prototype.hasOwnProperty.call(body.patch ?? {}, f)) patch[f] = body.patch[f];
        if (Object.keys(patch).length === 0) return json({ success: false, error: `patch must include at least one of: ${PATCHABLE.join(', ')}` }, 400);
        patch.updated_at = new Date().toISOString();

        const { data, error } = await supabase.from('beverage_items')
          .update(patch).eq('id', body.id).eq('client_id', auth.client.id).select('*').maybeSingle();
        if (error) return json({ success: false, error: error.message }, 500);
        if (!data) return json({ success: false, error: 'That beverage item does not belong to this restaurant.' }, 404);
        return json({ success: true, item: data });
      }

      if (body.action === 'create') {
        const fields = {};
        for (const f of CREATABLE) if (Object.prototype.hasOwnProperty.call(body.item ?? {}, f)) fields[f] = body.item[f];
        if (!fields.name) return json({ success: false, error: 'name is required.' }, 400);
        fields.client_id = auth.client.id;

        const { data, error } = await supabase.from('beverage_items').insert(fields).select('*').single();
        if (error) return json({ success: false, error: error.message }, 500);
        return json({ success: true, item: data }, 201);
      }

      return json({ success: false, error: `Unknown action "${body.action}". Use "update" or "create".` }, 400);
    }

    return json({ success: false, error: `${req.method} not supported.` }, 405);
  } catch (err) {
    console.error('[beverage-guide] unhandled:', err?.message ?? err);
    return json({ success: false, error: err?.message ?? String(err) }, 500);
  }
});
