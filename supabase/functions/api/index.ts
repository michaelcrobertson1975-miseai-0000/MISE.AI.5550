// @ts-nocheck
/**
 * MiseAI chef-app API.
 *
 * Routes (the app's own paths, verbatim):
 *   GET   /api/invoices/review-queue?restaurant_id=
 *   PATCH /api/invoices/lines
 *   GET   /api/invoices/price-moves?restaurant_id=&threshold=
 *   GET   /api/health
 *
 * TRANSLATION. The app speaks document_id / description / vendor_sku / extended;
 * Postgres speaks id / item_description / vendor_item_code / line_total. All of
 * that mapping happens here, in one place, so neither side has to bend.
 *
 * MATH. This file computes nothing. A brand-new line a reviewer types with no
 * total given gets its total from mise_manual_line_total() in Postgres, the
 * same place every other invoice number gets checked - not from qty * price
 * in JS. An existing line's printed total is never touched here at all.
 *
 * ONE CORRECTION PATH. Edits to an existing line are no longer written with a
 * direct .update(). They go to mise_apply_correction(), the same function the
 * ops Review Queue calls, which in one transaction updates the line, writes the
 * invoice_corrections audit rows, links or creates the ingredient, and upserts
 * client_item_memory so the NEXT invoice carrying the same vendor + item code
 * is right without anyone touching it.
 *
 * WHY SAVING MATTERS BEYOND THE ROW: an invoice whose lines are all mapped is
 * set to status='completed', and v_item_price_variance only reads completed
 * invoices. Finishing a review is literally what feeds Price Moves.
 */
import { createClient } from 'jsr:@supabase/supabase-js@2';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'GET, POST, PATCH, OPTIONS',
};

const json = (body, status = 200) =>
  new Response(JSON.stringify(body, null, 2), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });

const db = () => createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));

const num = (v) => {
  if (v === '' || v === null || v === undefined) return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
};

/** A fee needs no ingredient; everything else is unmapped until one is set. */
const isMapped = (line) =>
  line.chef_category === 'non_cogs_fee' ? true : Boolean(line.ingredient_id);

/** Postgres row -> the shape the app's Review Queue renders. */
function toAppLine(li) {
  return {
    id: li.id,
    description: li.item_description ?? '',
    vendor_sku: li.vendor_item_code ?? '',
    quantity: li.raw_quantity ?? '',
    unit: li.raw_uom ?? '',
    pack: li.raw_pack ?? '',
    size: li.raw_size ?? '',
    unit_price: li.raw_unit_price ?? '',
    extended: li.line_total ?? '',
    category: li.chef_category ?? 'uncategorized',
    ingredient_id: li.ingredient_id ?? null,
    beverage_type: li.beverage_type ?? null,
    beverage_class: li.beverage_class ?? null,
    mapped: isMapped(li),
    // Extra context the app ignores today but the reviewer benefits from.
    cost_per_base_unit: li.cost_per_base_unit ?? null,
    base_unit: li.standardized_base_unit ?? null,
    pack_confidence: li.pack_confidence ?? null,
    // True when this line carries a human-authoritative decision - either made
    // here, or applied from what the restaurant taught MiseAI on an earlier
    // invoice. The app uses it to show the line as already settled.
    human_confirmed: li.category_source === 'human',
    flag_notes: li.flag_notes ?? [],
  };
}

/**
 * Severity drives which cards open first, so it has to mean something.
 *   high   - the money is wrong, or a big chunk of the invoice is unreadable
 *   medium - readable but unmapped, or a case size the parser guessed at
 *   low    - just needs a look
 */
function assess(inv, lines) {
  const kinds = [];
  const reason = String(inv.flag_reason ?? '');
  const moneyProblem = reason.includes('[MONEY]');
  const unmapped = lines.filter((l) => !l.mapped).length;
  const lowConfidence = lines.some((l) => l.pack_confidence === 'low');

  if (moneyProblem) kinds.push('math_mismatch');
  if (unmapped > 0) kinds.push('unmapped_ingredients');
  if (lowConfidence) kinds.push('low_ocr_confidence');

  let severity = 'low';
  if (moneyProblem) severity = 'high';
  else if (unmapped > 0 || lowConfidence) severity = 'medium';

  return { severity, kinds, unmapped };
}

/* GET /api/invoices/review-queue */
async function reviewQueue(url) {
  const restaurantId = url.searchParams.get('restaurant_id');
  if (!restaurantId) return json({ success: false, error: 'restaurant_id is required' }, 400);

  const supabase = db();
  const { data, error } = await supabase
    .from('invoices')
    .select('*, invoice_line_items(*)')
    .eq('client_id', restaurantId)
    .neq('status', 'completed')
    .eq('invoice_line_items.removed_by_review', false)
    .order('invoice_date', { ascending: false, nullsFirst: false })
    .limit(100);
  if (error) return json({ success: false, error: error.message }, 500);

  const queue = (data ?? []).map((inv) => {
    const lines = (inv.invoice_line_items ?? [])
      .sort((a, b) => String(a.created_at).localeCompare(String(b.created_at)))
      .map(toAppLine);
    const { severity, kinds } = assess(inv, lines);
    return {
      document_id: inv.id,
      invoice_id: inv.id,
      invoice_number: inv.invoice_number ?? '',
      vendor_name: inv.vendor_name ?? 'Unknown vendor',
      received_on: inv.invoice_date ?? '',
      total: inv.grand_total ?? null,
      top_alert_severity: severity,
      open_alert_kinds: kinds,
      page_count: inv.page_count ?? 1,
      model_used: inv.model_used ?? null,
      flag_reason: inv.flag_reason ?? null,
      header: {
        invoice_number: inv.invoice_number ?? '',
        received_on: inv.invoice_date ?? '',
        subtotal: inv.subtotal ?? '',
        total: inv.grand_total ?? '',
      },
      lines,
    };
  });

  return json({ success: true, count: queue.length, queue });
}

/* PATCH /api/invoices/lines */
async function saveLines(req) {
  let payload;
  try { payload = await req.json(); }
  catch (err) { return json({ success: false, error: `Unparseable body: ${err.message}` }, 400); }

  const invoiceId = payload.invoice_id ?? payload.document_id;
  const restaurantId = payload.restaurant_id;
  if (!invoiceId) return json({ success: false, error: 'invoice_id (or document_id) is required' }, 400);

  const supabase = db();

  // Read the current state first: corrections are only meaningful against what
  // the model originally produced.
  const { data: before, error: readErr } = await supabase
    .from('invoices').select('*, invoice_line_items(*)').eq('id', invoiceId).single();
  if (readErr) return json({ success: false, error: `Invoice not found: ${readErr.message}` }, 404);
  if (restaurantId && before.client_id !== restaurantId) {
    return json({ success: false, error: 'Invoice does not belong to that restaurant.' }, 403);
  }

  const existing = new Map((before.invoice_line_items ?? []).map((l) => [l.id, l]));
  const corrections = [];
  const note = (lineId, field, oldV, newV) => {
    if (String(oldV ?? '') === String(newV ?? '')) return;
    corrections.push({
      invoice_id: invoiceId, line_item_id: lineId, field_name: field,
      old_value: oldV == null ? null : String(oldV),
      new_value: newV == null ? null : String(newV),
      model_used: before.model_used ?? null,
    });
  };

  // ---- header ----
  const h = payload.header ?? {};
  const headerPatch = {
    invoice_number: h.invoice_number ?? before.invoice_number,
    invoice_date: h.received_on || null,
    subtotal: num(h.subtotal),
    grand_total: num(h.total),
  };
  note(null, 'invoice_number', before.invoice_number, headerPatch.invoice_number);
  note(null, 'invoice_date', before.invoice_date, headerPatch.invoice_date);
  note(null, 'subtotal', before.subtotal, headerPatch.subtotal);
  note(null, 'grand_total', before.grand_total, headerPatch.grand_total);

  // ---- lines ----
  const seen = new Set();
  const sent = Array.isArray(payload.lines) ? payload.lines : [];
  let rpcCorrections = 0;
  let remembered = 0;

  for (const line of sent) {
    const quantity = num(line.quantity);
    const unitPrice = num(line.unit_price);
    const category = line.category || 'uncategorized';
    const ingredientId = category === 'non_cogs_fee' ? null : (line.ingredient_id || null);

    if (line.id && existing.has(line.id)) {
      // EXISTING LINE -> the one trusted correction path. mise_apply_correction
      // updates the line, logs the audit rows, links the ingredient, upserts
      // memory and recomputes status, all in one transaction.
      seen.add(line.id);
      const prev = existing.get(line.id);
      const patch = {};
      const put = (field, value) => {
        if (String(prev[field] ?? '') === String(value ?? '')) return;
        patch[field] = value;
      };
      put('item_description', line.description ?? '');
      put('vendor_item_code', line.vendor_sku || null);
      put('raw_quantity', quantity);
      put('raw_unit_price', unitPrice);
      put('raw_uom', line.unit || null);
      if (line.pack !== undefined) put('raw_pack', line.pack || null);
      if (line.size !== undefined) put('raw_size', line.size || null);
      put('chef_category', category);
      put('ingredient_id', ingredientId);

      if (Object.keys(patch).length === 0) continue;

      const { data: res, error } = await supabase.rpc('mise_apply_correction', {
        p_line_item_id: line.id,
        p_patch: patch,
        p_ingredient_name: line.ingredient_name || null,
      });
      if (error) return json({ success: false, error: `Line update failed: ${error.message}` }, 500);
      rpcCorrections += res?.corrections_logged ?? 0;
      if (res?.memory_id) remembered += 1;

      // beverage_* are not part of the correction contract; keep them as a
      // plain attribute write so the chef app's drink fields still save.
      if (line.beverage_type || line.beverage_class) {
        await supabase.from('invoice_line_items')
          .update({ beverage_type: line.beverage_type || null, beverage_class: line.beverage_class || null })
          .eq('id', line.id);
      }
    } else {
      // A line the model missed entirely, typed in by the reviewer. There is
      // no printed total to preserve here, so Postgres fills one in from
      // qty x price only when the app didn't send `extended` itself.
      const { data: lineTotal, error: totalErr } = await supabase.rpc('mise_manual_line_total', {
        p_quantity: quantity, p_unit_price: unitPrice, p_provided: num(line.extended),
      });
      if (totalErr) return json({ success: false, error: `Could not total that line: ${totalErr.message}` }, 500);

      const row = {
        invoice_id: invoiceId,
        item_description: line.description ?? '',
        vendor_item_code: line.vendor_sku || null,
        raw_quantity: quantity,
        raw_uom: line.unit || null,
        raw_pack: line.pack || null,
        raw_size: line.size || null,
        raw_unit_price: unitPrice,
        chef_category: category,
        category_source: 'human',
        ingredient_id: ingredientId,
        beverage_type: line.beverage_type || null,
        beverage_class: line.beverage_class || null,
        matched_at: ingredientId ? new Date().toISOString() : null,
        line_total: lineTotal,
      };

      const { data: created, error } = await supabase.from('invoice_line_items').insert(row).select('id').single();
      if (error) return json({ success: false, error: `Line insert failed: ${error.message}` }, 500);
      if (created) seen.add(created.id);
      corrections.push({
        invoice_id: invoiceId, line_item_id: created?.id ?? null, field_name: 'line_added',
        old_value: null, new_value: row.item_description, model_used: before.model_used ?? null,
      });
    }
  }

  // Anything the reviewer deleted is marked, never dropped - a line the model
  // invented is itself a measurement.
  for (const [id, prev] of existing) {
    if (seen.has(id) || prev.removed_by_review) continue;
    const { error } = await supabase.from('invoice_line_items')
      .update({ removed_by_review: true, is_flagged: false }).eq('id', id);
    if (error) return json({ success: false, error: `Line removal failed: ${error.message}` }, 500);
    corrections.push({
      invoice_id: invoiceId, line_item_id: id, field_name: 'removed_by_review',
      old_value: 'false', new_value: 'true', model_used: before.model_used ?? null,
    });
  }

  if (corrections.length) {
    const { error } = await supabase.from('invoice_corrections').insert(corrections);
    if (error) console.warn(`[api] correction log failed (save kept): ${error.message}`);
  }

  // ---- did this finish the invoice? ----
  const { data: after, error: afterErr } = await supabase
    .from('invoice_line_items').select('*').eq('invoice_id', invoiceId).eq('removed_by_review', false);
  if (afterErr) return json({ success: false, error: afterErr.message }, 500);

  const unmapped = (after ?? []).filter((l) => !isMapped(l)).length;
  const resolved = unmapped === 0 && (after ?? []).length > 0;

  // correction_count is SET, not incremented, so it must include what the RPC
  // already added on top of the header/removal rows counted here.
  const { error: invErr } = await supabase.from('invoices').update({
    ...headerPatch,
    status: resolved ? 'completed' : 'requires_human_review',
    corrected_at: new Date().toISOString(),
    correction_count: (before.correction_count ?? 0) + corrections.length + rpcCorrections,
  }).eq('id', invoiceId);
  if (invErr) return json({ success: false, error: `Invoice update failed: ${invErr.message}` }, 500);

  console.log(`[api] saved invoice=${invoiceId} corrections=${corrections.length + rpcCorrections} remembered=${remembered} unmapped=${unmapped} resolved=${resolved}`);

  return json({
    success: true,
    resolved,
    lines_unmapped: unmapped,
    lines_total: (after ?? []).length,
    corrections_logged: corrections.length + rpcCorrections,
    items_remembered: remembered,
  });
}

/* GET /api/invoices/price-moves */
async function priceMoves(url) {
  const restaurantId = url.searchParams.get('restaurant_id');
  if (!restaurantId) return json({ success: false, error: 'restaurant_id is required' }, 400);
  const threshold = Number(url.searchParams.get('threshold') ?? '8');

  const supabase = db();
  const { data, error } = await supabase
    .from('v_item_price_variance')
    .select('*')
    .eq('client_id', restaurantId)
    .order('invoice_date', { ascending: false })
    .limit(500);
  if (error) return json({ success: false, error: error.message }, 500);

  // Newest move per item, plus a short history for the sparkline.
  const byItem = new Map();
  for (const row of data ?? []) {
    const key = row.vendor_item_code;
    if (!byItem.has(key)) byItem.set(key, { latest: row, history: [] });
    byItem.get(key).history.push(Number(row.cost_per_base_unit));
  }

  const items = [...byItem.entries()].map(([sku, { latest, history }]) => {
    const pct = latest.unit_cost_delta_pct === null ? null : Number(latest.unit_cost_delta_pct);
    return {
      id: sku,
      name: latest.item_description,
      vendor_sku: sku,
      unit: latest.standardized_base_unit,
      oldPrice: latest.prev_cost_per_base_unit === null ? null : Number(latest.prev_cost_per_base_unit),
      newPrice: Number(latest.cost_per_base_unit),
      pct_change: pct,
      dollar_impact: latest.dollar_impact === null ? null : Number(latest.dollar_impact),
      last_seen: latest.invoice_date,
      last_invoice: latest.invoice_number,
      history: history.slice(0, 4).reverse(),
      status: pct !== null && Math.abs(pct) >= threshold ? 'review' : 'accepted',
    };
  }).sort((a, b) => Math.abs(b.pct_change ?? 0) - Math.abs(a.pct_change ?? 0));

  const flagged = items.filter((i) => i.status === 'review');
  const netShift = items.reduce((sum, i) => sum + (i.dollar_impact ?? 0), 0);

  return json({
    success: true,
    threshold,
    count: items.length,
    net_spend_shift: Math.round(netShift * 100) / 100,
    top_red_flag: flagged.length ? { name: flagged[0].name, pct: flagged[0].pct_change } : null,
    items,
  });
}

/* router */
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });

  const url = new URL(req.url);
  // Supabase serves this at /functions/v1/api/... ; the app asks for /api/... .
  const path = url.pathname.replace(/^\/functions\/v1\/api/, '').replace(/^\/api/, '') || '/';

  try {
    if (path === '/health' || path === '/') {
      return json({
        success: true,
        service: 'miseai chef-app api',
        correction_path: 'mise_apply_correction (line + audit + ingredient + memory + status, one transaction)',
        routes: ['GET /api/invoices/review-queue?restaurant_id=',
                 'PATCH /api/invoices/lines',
                 'GET /api/invoices/price-moves?restaurant_id=&threshold='],
        database: Boolean(Deno.env.get('SUPABASE_URL')),
      });
    }
    if (path === '/invoices/review-queue' && req.method === 'GET') return await reviewQueue(url);
    if (path === '/invoices/lines' && (req.method === 'PATCH' || req.method === 'POST')) return await saveLines(req);
    if (path === '/invoices/price-moves' && req.method === 'GET') return await priceMoves(url);

    return json({ success: false, error: `No route for ${req.method} ${path}` }, 404);
  } catch (err) {
    console.error('[api] unhandled:', err?.message ?? err);
    return json({ success: false, error: err?.message ?? String(err) }, 500);
  }
});
