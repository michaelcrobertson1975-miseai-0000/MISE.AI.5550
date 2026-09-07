// @ts-nocheck
/**
 * product-mix - backs the app's "Product Mix" tab.
 *
 * The tab already says "Auto-synced from POS + invoices" but nothing fed it
 * -- no fetch call existed anywhere in the app. This is that wiring, reading
 * REAL public.nightly_product_mix / nightly_reports (populated today by
 * ingest-nightly-report), which had RLS disabled and no reader at all.
 *
 * HONESTY ABOUT WHAT'S REAL: nightly_product_mix only ever stored qty_sold
 * per POS button -- no price was ever captured anywhere in this schema, so
 * Revenue and Food Cost % cannot be computed without a real menu price.
 * Rather than invent numbers, this joins the new (empty until populated)
 * menu_items table: units sold is always real, revenue/food-cost% are null
 * per item until the restaurant's real menu price is entered there. Same
 * rule this project already applies to beverage_boms waiting on real names.
 *
 * AUTH: restaurant_id + api_token must match clients.api_token. No anon
 * PostgREST access exists to either underlying table -- this function (with
 * service_role) is the only reader.
 *
 *   GET /product-mix?restaurant_id=&api_token=&days=30
 *     -> { success, days, count, items: [{ pos_button, display_name,
 *            category, units_sold, pct_of_units, menu_price,
 *            food_cost_per_unit, revenue, food_cost_pct }],
 *          totals: { units_sold, revenue } }
 */
import { createClient } from 'jsr:@supabase/supabase-js@2';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'GET, OPTIONS',
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

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'GET') return json({ success: false, error: 'GET only.' }, 405);

  const url = new URL(req.url);
  const supabase = db();
  const auth = await authClient(supabase, url.searchParams.get('restaurant_id'), url.searchParams.get('api_token'));
  if (auth.error) return json({ success: false, error: auth.error }, 401);

  const days = Math.max(1, Math.min(365, Number(url.searchParams.get('days') ?? '30') || 30));
  const since = new Date(Date.now() - days * 86400000).toISOString().slice(0, 10);

  try {
    const { data: reports, error: repErr } = await supabase.from('nightly_reports')
      .select('id, report_date').eq('client_id', auth.client.id).gte('report_date', since);
    if (repErr) return json({ success: false, error: repErr.message }, 500);

    const reportIds = (reports ?? []).map((r) => r.id);
    if (reportIds.length === 0) return json({ success: true, days, count: 0, items: [], totals: { units_sold: 0, revenue: null }, note: 'No nightly reports in this window yet.' });

    const { data: mix, error: mixErr } = await supabase.from('nightly_product_mix')
      .select('pos_button, qty_sold').in('nightly_report_id', reportIds);
    if (mixErr) return json({ success: false, error: mixErr.message }, 500);

    const { data: menuRows, error: menuErr } = await supabase.from('menu_items')
      .select('pos_button, display_name, category, menu_price, food_cost_per_unit').eq('client_id', auth.client.id);
    if (menuErr) return json({ success: false, error: menuErr.message }, 500);
    const menuByButton = new Map((menuRows ?? []).map((m) => [m.pos_button, m]));

    const byButton = new Map();
    for (const row of mix ?? []) {
      const qty = Number(row.qty_sold) || 0;
      const cur = byButton.get(row.pos_button) ?? 0;
      byButton.set(row.pos_button, cur + qty);
    }

    const totalUnits = [...byButton.values()].reduce((a, b) => a + b, 0);
    let totalRevenue = 0, haveAnyRevenue = false;

    const items = [...byButton.entries()].map(([posButton, unitsSold]) => {
      const menu = menuByButton.get(posButton);
      const price = menu?.menu_price != null ? Number(menu.menu_price) : null;
      const foodCost = menu?.food_cost_per_unit != null ? Number(menu.food_cost_per_unit) : null;
      const revenue = price != null ? Math.round(price * unitsSold * 100) / 100 : null;
      if (revenue != null) { totalRevenue += revenue; haveAnyRevenue = true; }
      const foodCostPct = price != null && foodCost != null && price > 0
        ? Math.round((foodCost / price) * 10000) / 100 : null;
      return {
        pos_button: posButton,
        display_name: menu?.display_name ?? posButton,
        category: menu?.category ?? null,
        units_sold: unitsSold,
        pct_of_units: totalUnits > 0 ? Math.round((unitsSold / totalUnits) * 10000) / 100 : null,
        menu_price: price,
        food_cost_per_unit: foodCost,
        revenue,
        food_cost_pct: foodCostPct,
        has_menu_price: price != null,
      };
    }).sort((a, b) => b.units_sold - a.units_sold);

    return json({
      success: true,
      days,
      count: items.length,
      items,
      totals: { units_sold: totalUnits, revenue: haveAnyRevenue ? Math.round(totalRevenue * 100) / 100 : null },
      note: items.some((i) => !i.has_menu_price)
        ? 'Some POS buttons have no menu_items price yet -- their revenue/food cost % are null, not estimated.'
        : undefined,
    });
  } catch (err) {
    console.error('[product-mix] unhandled:', err?.message ?? err);
    return json({ success: false, error: err?.message ?? String(err) }, 500);
  }
});
