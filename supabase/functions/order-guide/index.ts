// @ts-nocheck
/**
 * order-guide - backs the app's "Order Food" tab.
 *
 * CORRECTED DESIGN: this reads and writes the REAL public.ingredients table
 * (63 rows for this client already, each tied to real invoice history) --
 * not a parallel table shaped after the app's old hardcoded 44-item demo
 * array. Supabase's existing schema is the source of truth; the app follows
 * it, not the other way around.
 *
 * Vendor and price are never stored here -- they are read live from
 * v_ingredient_last_price (latest completed invoice line per ingredient),
 * the same real data Price Moves uses, so there is exactly one place cost
 * data can drift from and this is not it. Only par / on_hand / grouping /
 * approve-skip state -- things that do not exist anywhere else -- live on
 * ingredients itself.
 *
 * AUTH: custom, matching this project's other client-facing functions
 * (review, api, upload-scan) -- no Supabase JWT, restaurant_id + api_token
 * must match clients.api_token instead.
 *
 *   GET  /order-guide?restaurant_id=&api_token=
 *     -> { items: [{ id, name, base_unit, pnl_category, order_category,
 *                     par, on_hand, approved, skipped,
 *                     vendor, last_unit_price, last_purchase_unit,
 *                     cost_per_base_unit, last_invoice_date }] }
 *
 *   POST /order-guide  { restaurant_id, api_token, action, ... }
 *     action 'update'  { id, patch: { par?, on_hand?, order_category?,
 *                                     approved?, skipped? } }
 *       -> patches ONLY those ordering fields on one ingredient this
 *          client owns. Cannot touch name/base_unit/pnl_category/cost --
 *          those belong to the invoice pipeline.
 *     action 'create'  { item: { name, base_unit, pnl_category?,
 *                          order_category?, par?, on_hand? } }
 *       -> a brand-new ingredient the restaurant is adding by hand (not yet
 *          seen on an invoice). vendor/last_unit_price/cost_per_base_unit
 *          start null and fill in once a real invoice line gets matched to
 *          it, same as every other ingredients row -- this never fabricates
 *          a price.
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

const PATCHABLE = ['par', 'on_hand', 'order_category', 'approved', 'skipped'];
const CREATABLE = ['name', 'base_unit', 'pnl_category', 'order_category', 'par', 'on_hand'];

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  const url = new URL(req.url);
  const supabase = db();

  try {
    if (req.method === 'GET') {
      const auth = await authClient(supabase, url.searchParams.get('restaurant_id'), url.searchParams.get('api_token'));
      if (auth.error) return json({ success: false, error: auth.error }, 401);

      const { data: ingredients, error } = await supabase.from('ingredients')
        .select('id, name, base_unit, pnl_category, order_category, par, on_hand, approved, skipped, on_hand_updated_at')
        .eq('client_id', auth.client.id)
        .order('order_category', { ascending: true, nullsFirst: false })
        .order('name', { ascending: true });
      if (error) return json({ success: false, error: error.message }, 500);

      const { data: prices, error: priceErr } = await supabase.from('v_ingredient_last_price')
        .select('*').in('ingredient_id', (ingredients ?? []).map((i) => i.id));
      if (priceErr) return json({ success: false, error: priceErr.message }, 500);
      const priceById = new Map((prices ?? []).map((p) => [p.ingredient_id, p]));

      const items = (ingredients ?? []).map((ing) => {
        const p = priceById.get(ing.id);
        return {
          ...ing,
          vendor: p?.vendor_name ?? null,
          last_unit_price: p?.last_unit_price ?? null,
          last_purchase_unit: p?.last_purchase_unit ?? null,
          cost_per_base_unit: p?.cost_per_base_unit ?? null,
          last_invoice_date: p?.last_invoice_date ?? null,
          below_par: ing.par != null && ing.on_hand != null ? ing.on_hand < ing.par : null,
        };
      });
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
        if ('on_hand' in patch) patch.on_hand_updated_at = new Date().toISOString();

        const { data, error } = await supabase.from('ingredients')
          .update(patch).eq('id', body.id).eq('client_id', auth.client.id)
          .select('id, name, base_unit, pnl_category, order_category, par, on_hand, approved, skipped, on_hand_updated_at')
          .maybeSingle();
        if (error) return json({ success: false, error: error.message }, 500);
        if (!data) return json({ success: false, error: 'That ingredient does not belong to this restaurant.' }, 404);
        return json({ success: true, item: data });
      }

      if (body.action === 'create') {
        const fields = {};
        for (const f of CREATABLE) if (Object.prototype.hasOwnProperty.call(body.item ?? {}, f)) fields[f] = body.item[f];
        if (!fields.name) return json({ success: false, error: 'name is required.' }, 400);
        fields.client_id = auth.client.id;

        const { data, error } = await supabase.from('ingredients').insert(fields)
          .select('id, name, base_unit, pnl_category, order_category, par, on_hand, approved, skipped, on_hand_updated_at')
          .single();
        if (error) return json({ success: false, error: error.message }, 500);
        return json({ success: true, item: { ...data, vendor: null, last_unit_price: null, last_purchase_unit: null, cost_per_base_unit: null, last_invoice_date: null } }, 201);
      }

      return json({ success: false, error: `Unknown action "${body.action}". Use "update" or "create".` }, 400);
    }

    return json({ success: false, error: `${req.method} not supported.` }, 405);
  } catch (err) {
    console.error('[order-guide] unhandled:', err?.message ?? err);
    return json({ success: false, error: err?.message ?? String(err) }, 500);
  }
});
