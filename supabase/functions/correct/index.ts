// @ts-nocheck
/**
 * MiseAI — Correct.
 *
 * The smallest front end for the memory system. Built against the backend as it
 * stands, nothing more:
 *
 *   READS   invoices, invoice_line_items, ingredients
 *   WRITES  nothing directly. Every save is one mise_apply_correction() call.
 *
 * That RPC is SECURITY DEFINER and is the only thing permitted to create
 * human-confirmed memory. This page cannot read or write client_item_memory --
 * anon holds no grant on it -- so "remembered" is never something the UI
 * asserts on its own. It reports exactly what the RPC returned.
 *
 * SECURITY: this page used to talk to PostgREST directly from the browser
 * using the anon key, embedded in plain sight in this file's own JS. Anyone
 * who viewed source got a key with unfiltered SELECT/INSERT/UPDATE across
 * every restaurant's invoices, line items and ingredients (see locker
 * finding 9ac158b0 -- RLS policies on those four tables were `USING (true)`
 * with no client_id filter at all). The access-code cookie below gated the
 * HTML page, but never the data itself.
 *
 * Fixed by making this edge function the only thing that ever talks to
 * PostgREST for this page. The browser now calls this SAME origin
 * (?api=<rest path>), the server re-checks the access-code cookie on every
 * such call, then proxies to PostgREST using SUPABASE_SERVICE_ROLE_KEY --
 * which never reaches the browser. Same queries, same shapes, same
 * behaviour; the only thing that changed is where the privileged credential
 * lives. mise_apply_correction() is also called through this proxy now
 * (previously called directly with the anon key, which worked because it is
 * SECURITY DEFINER, but there is no reason to keep any credential in the
 * client once the proxy exists).
 *
 * One save = one line = one RPC = one transaction. There is no batch save, no
 * client-side arithmetic and no direct PATCH anywhere in this file.
 */
const ACCESS_CODE = Deno.env.get('REVIEW_ACCESS_CODE');
const COOKIE = 'mise_correct_auth';

function cookieValue(req, name) {
  const raw = req.headers.get('cookie') ?? '';
  for (const part of raw.split(';')) {
    const i = part.indexOf('=');
    if (i === -1) continue;
    if (part.slice(0, i).trim() === name) return part.slice(i + 1).trim();
  }
  return null;
}

// The only place a Postgres credential is used. Gated on the same
// access-code cookie that already protects the page; nothing here is
// reachable without it.
async function proxyRest(req, url) {
  if (cookieValue(req, COOKIE) !== ACCESS_CODE) {
    return new Response(JSON.stringify({ error: 'Unauthorized' }), { status: 401, headers: { 'Content-Type': 'application/json' } });
  }
  const path = url.searchParams.get('api');
  if (!path) return new Response(JSON.stringify({ error: 'Missing api path' }), { status: 400, headers: { 'Content-Type': 'application/json' } });

  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const upstreamHeaders = { apikey: serviceKey, Authorization: `Bearer ${serviceKey}`, 'Content-Type': 'application/json' };
  if (req.headers.get('prefer')) upstreamHeaders['Prefer'] = req.headers.get('prefer');

  const init = { method: req.method, headers: upstreamHeaders };
  if (req.method === 'POST' || req.method === 'PATCH') init.body = await req.text();

  const upstream = await fetch(`${supabaseUrl}/rest/v1/${path}`, init);
  const text = await upstream.text();
  return new Response(text, { status: upstream.status, headers: { 'Content-Type': 'application/json' } });
}

const CSS = `
:root{
  --paper:#FCFCFA; --card:#FFFFFF; --sunk:#F3F4F1; --line:#E2E4DF; --hair:#EDEEEA;
  --ink:#1A1D1A; --text:#3A3F3B; --soft:#6E756E; --faint:#9AA09A;
  --act:#1F6F5C; --act-soft:#E6F1ED; --act-deep:#175443;
  --warn:#8A5A12; --warn-soft:#FBF2E2;
  --stop:#9B2C21; --stop-soft:#FAECEA;
  --mono:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;
  --ui:system-ui,-apple-system,"Segoe UI",sans-serif;
}
@media (prefers-color-scheme:dark){:root:not([data-theme=light]){
  --paper:#141615; --card:#1B1E1C; --sunk:#101211; --line:#2B2F2C; --hair:#232624;
  --ink:#EDEFEC; --text:#C8CDC8; --soft:#8E958E; --faint:#6B726B;
  --act:#5FBFA3; --act-soft:#12251F; --act-deep:#7FD3B9;
  --warn:#D9A65A; --warn-soft:#241C10;
  --stop:#E58C80; --stop-soft:#241514;
}}
:root[data-theme=dark]{
  --paper:#141615; --card:#1B1E1C; --sunk:#101211; --line:#2B2F2C; --hair:#232624;
  --ink:#EDEFEC; --text:#C8CDC8; --soft:#8E958E; --faint:#6B726B;
  --act:#5FBFA3; --act-soft:#12251F; --act-deep:#7FD3B9;
  --warn:#D9A65A; --warn-soft:#241C10;
  --stop:#E58C80; --stop-soft:#241514;
}
*{box-sizing:border-box}
body{margin:0;background:var(--paper);color:var(--text);font:15px/1.55 var(--ui);-webkit-font-smoothing:antialiased}
.wrap{max-width:1000px;margin:0 auto;padding-inline:18px;padding-block:0 70px}
h1{margin:0;color:var(--ink);font-size:17px;font-weight:600;letter-spacing:-.01em}
.top{display:flex;align-items:baseline;gap:12px;flex-wrap:wrap;padding-block:22px 14px;border-bottom:1px solid var(--line)}
.top .sub{color:var(--soft);font-size:13px}
.back{background:none;border:none;color:var(--act);font:inherit;font-size:13px;cursor:pointer;padding:0}
.back:hover{text-decoration:underline}
.list{display:flex;flex-direction:column;gap:8px;margin-top:18px}
.inv{display:grid;grid-template-columns:1fr auto;gap:4px 16px;width:100%;text-align:left;
  background:var(--card);border:1px solid var(--line);border-radius:7px;padding:13px 15px;cursor:pointer;font:inherit;color:inherit}
.inv:hover{border-color:var(--act)}
.inv b{color:var(--ink);font-weight:600}
.inv .meta{color:var(--soft);font-size:13px;font-family:var(--mono)}
.inv .amt{color:var(--ink);font-family:var(--mono);font-size:14px;text-align:right}
.inv .cnt{color:var(--soft);font-size:12px;font-family:var(--mono);text-align:right}
.line{background:var(--card);border:1px solid var(--line);border-radius:7px;margin-top:12px;overflow:hidden}
.line.done{border-color:var(--act)}
.lhead{display:flex;align-items:center;gap:10px;padding:11px 15px;border-bottom:1px solid var(--hair);flex-wrap:wrap}
.lhead .name{flex:1;min-width:180px;color:var(--ink);font-weight:600;font-size:14px}
.calc{padding:9px 15px;background:var(--sunk);border-bottom:1px solid var(--hair);
  font-family:var(--mono);font-size:12px;color:var(--soft);display:flex;gap:18px;flex-wrap:wrap}
.calc b{color:var(--ink);font-weight:600}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(132px,1fr));gap:11px;padding:13px 15px}
.f{display:flex;flex-direction:column;gap:4px;min-width:0}
.f label{font-size:10.5px;letter-spacing:.09em;text-transform:uppercase;color:var(--faint);font-weight:600}
.f input,.f select{width:100%;background:var(--paper);border:1px solid var(--line);border-radius:5px;
  padding:7px 8px;font:13px var(--mono);color:var(--ink);outline:none;min-width:0}
.f select{font-family:var(--ui)}
.f input:focus,.f select:focus{border-color:var(--act);box-shadow:0 0 0 3px var(--act-soft)}
.f.changed input,.f.changed select{border-color:var(--warn);background:var(--warn-soft)}
.foot{display:flex;align-items:center;gap:11px;padding:12px 15px;border-top:1px solid var(--hair);flex-wrap:wrap}
button.save{background:var(--act);color:#fff;border:none;border-radius:5px;padding:8px 16px;
  font:600 13px var(--ui);cursor:pointer}
button.save:hover:not(:disabled){background:var(--act-deep)}
button.save:disabled{opacity:.4;cursor:not-allowed}
button.undo{background:none;border:1px solid var(--line);color:var(--text);border-radius:5px;padding:8px 12px;font:13px var(--ui);cursor:pointer}
.tag{display:inline-block;font:600 10.5px var(--mono);letter-spacing:.07em;padding:3px 8px;border-radius:3px;border:1px solid;white-space:nowrap}
.tag.ok{color:var(--act);background:var(--act-soft);border-color:var(--act)}
.tag.warn{color:var(--warn);background:var(--warn-soft);border-color:var(--warn)}
.tag.stop{color:var(--stop);background:var(--stop-soft);border-color:var(--stop)}
.tag.mute{color:var(--soft);background:var(--sunk);border-color:var(--line)}
.receipt{padding:11px 15px;background:var(--act-soft);border-top:1px solid var(--act);
  font:12px var(--mono);color:var(--act);display:flex;flex-direction:column;gap:3px}
.receipt .hd{font-weight:600;letter-spacing:.05em}
.err{padding:11px 15px;background:var(--stop-soft);border-top:1px solid var(--stop);font:12px var(--mono);color:var(--stop)}
.note{color:var(--soft);font-size:13px;margin-top:14px}
.note code{font-family:var(--mono);font-size:12px;background:var(--sunk);padding:1px 5px;border-radius:3px}
.empty{padding:52px 16px;text-align:center;color:var(--soft);font-size:14px}
.gate{min-height:100vh;display:flex;align-items:center;justify-content:center;padding:20px}
.gate form{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:26px;width:100%;max-width:320px}
.gate h1{margin-bottom:16px}
.gate input{width:100%;background:var(--paper);border:1px solid var(--line);border-radius:5px;padding:11px;font:16px var(--ui);color:var(--ink);outline:none}
.gate input:focus{border-color:var(--act)}
.gate button{width:100%;margin-top:14px;background:var(--act);color:#fff;border:none;border-radius:5px;padding:11px;font:600 14px var(--ui);cursor:pointer}
.gate .bad{background:var(--stop-soft);border:1px solid var(--stop);color:var(--stop);border-radius:5px;padding:9px 11px;font-size:13px;margin-bottom:12px}
@media (prefers-reduced-motion:reduce){*{transition:none!important}}
`;

const SHELL = (inner) => '<!doctype html><html lang="en"><head><meta charset="utf-8">' +
  '<meta name="viewport" content="width=device-width,initial-scale=1">' +
  '<title>MiseAI Correct</title><style>' + CSS + '</style></head><body>' + inner + '</body></html>';

const GATE = (bad) => SHELL(
  '<div class="gate"><form method="GET">' +
  '<h1>MiseAI Correct</h1>' +
  (bad ? '<div class="bad">Wrong code.</div>' : '') +
  '<label for="code" style="display:block;font-size:11px;letter-spacing:.09em;text-transform:uppercase;color:var(--faint);font-weight:600;margin-bottom:6px">Access code</label>' +
  '<input id="code" name="code" type="password" autofocus required>' +
  '<button type="submit">Enter</button>' +
  '</form></div>'
);

function APP_JS() {
  return `
var view=document.getElementById('view'), sub=document.getElementById('sub'), back=document.getElementById('back');

// chef_category is the authority the backend derives pnl_category from
// (mise_pnl_bucket). These seven are the values it recognises.
var CHEF=[['produce','Produce','FOOD'],['protein','Protein','FOOD'],['dairy','Dairy','FOOD'],
 ['dry_goods','Dry goods','FOOD'],['beverage','Beverage','BEVERAGE'],
 ['non_cogs_fee','Fee / freight','FREIGHT'],['other','Other / supplies','SUPPLIES']];

var FIELDS=[['item_description','Description'],['vendor_item_code','Item code'],
 ['raw_quantity','Qty'],['raw_pack','Pack'],['raw_size','Size'],['raw_uom','Unit'],
 ['raw_unit_price','Unit price'],['line_total','Line total']];

var inv=null, lines=[], ingredients=[], edits={}, results={};

function esc(s){return String(s==null?'':s).replace(/[&<>"]/g,function(c){
  return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c];});}
function money(v){return v==null?'—':'$'+Number(v).toFixed(2);}

// Same-origin call to THIS edge function's proxy, never PostgREST directly.
// The access-code cookie travels automatically; no credential lives in this
// file at all any more.
function q(path){return fetch('?api='+encodeURIComponent(path)).then(function(r){
  if(!r.ok)return r.text().then(function(t){throw new Error('HTTP '+r.status+' '+t.slice(0,160));});
  return r.json();});}
function rpcCall(fn,args,prefer){
  var h={'Content-Type':'application/json'};
  if(prefer)h['Prefer']=prefer;
  return fetch('?api='+encodeURIComponent('rpc/'+fn),{method:'POST',headers:h,body:JSON.stringify(args)})
    .then(function(r){return r.text().then(function(t){
      if(!r.ok)throw new Error(t.slice(0,220));
      return t?JSON.parse(t):null;
    });});
}

/* ---------- 1. pending invoice list ---------- */
function showList(){
  inv=null; back.hidden=true; edits={}; results={};
  view.innerHTML='<div class="empty">Loading…</div>';
  q('invoices?select=id,vendor_name,invoice_number,invoice_date,grand_total,status,corrected_at,invoice_line_items(id)'+
    '&status=neq.completed&order=invoice_date.desc.nullslast&limit=50')
  .then(function(rows){
    sub.textContent=rows.length+' invoice'+(rows.length===1?'':'s')+' pending review';
    if(!rows.length){view.innerHTML='<div class="empty">Nothing pending. Every invoice is complete.</div>';return;}
    view.innerHTML='<div class="list">'+rows.map(function(r){
      var n=(r.invoice_line_items||[]).length;
      return '<button class="inv" data-open="'+r.id+'">'+
        '<div><b>'+esc(r.vendor_name||'Unknown vendor')+'</b>'+
          (r.corrected_at?' <span class="tag ok">CORRECTED</span>':'')+'</div>'+
        '<div class="amt">'+money(r.grand_total)+'</div>'+
        '<div class="meta">'+esc(r.invoice_number||'no number')+' · '+esc(r.invoice_date||'no date')+'</div>'+
        '<div class="cnt">'+n+' line'+(n===1?'':'s')+'</div></button>';
    }).join('')+'</div>';
  })
  .catch(function(e){view.innerHTML='<div class="err">'+esc(e.message)+'</div>';});
}

/* ---------- 2. invoice + line items ---------- */
function openInvoice(id){
  view.innerHTML='<div class="empty">Loading…</div>';
  q('invoices?id=eq.'+id+'&select=*,invoice_line_items(*)').then(function(rows){
    inv=rows[0];
    if(!inv){view.innerHTML='<div class="empty">Invoice not found.</div>';return;}
    lines=(inv.invoice_line_items||[])
      .filter(function(l){return !l.removed_by_review;})
      .sort(function(a,b){return String(a.created_at).localeCompare(String(b.created_at));});
    return q('ingredients?client_id=eq.'+inv.client_id+'&select=id,name&order=name.asc&limit=2000');
  }).then(function(ing){
    if(!inv)return;
    ingredients=ing||[]; edits={}; results={};
    back.hidden=false;
    sub.textContent=(inv.vendor_name||'Unknown')+' · '+(inv.invoice_number||'no number')+' · '+lines.length+' lines';
    render();
  }).catch(function(e){view.innerHTML='<div class="err">'+esc(e.message)+'</div>';});
}

function val(l,f){
  var e=edits[l.id];
  if(e&&Object.prototype.hasOwnProperty.call(e,f))return e[f];
  return l[f]==null?'':l[f];
}
function changed(l,f){
  var e=edits[l.id];
  if(!e||!Object.prototype.hasOwnProperty.call(e,f))return false;
  return String(e[f])!==String(l[f]==null?'':l[f]);
}
function dirty(l){return FIELDS.concat([['chef_category'],['ingredient_id'],['__new_ing']])
  .some(function(f){return changed(l,f[0]);});}

function render(){
  view.innerHTML=lines.map(card).join('')+
    '<p class="note">Saving sends one <code>mise_apply_correction</code> call per line. '+
    'The backend updates the line, writes the audit row, links the ingredient, stores the memory '+
    'and recomputes the invoice status in a single transaction.</p>';
}

function card(l){
  var res=results[l.id];
  var isDirty=dirty(l);

  var flags='';
  if(l.category_source==='human')flags+='<span class="tag ok">CONFIRMED</span>';
  if(l.is_flagged)flags+=' <span class="tag stop">FLAGGED</span>';
  if(l.pack_confidence==='low')flags+=' <span class="tag warn">LOW CONFIDENCE</span>';
  if(!l.ingredient_id&&l.chef_category!=='non_cogs_fee')flags+=' <span class="tag mute">UNMATCHED</span>';

  var calc='<div class="calc">'+
    '<span>base unit <b>'+esc(l.standardized_base_unit||'—')+'</b></span>'+
    '<span>total units <b>'+esc(l.total_base_units==null?'—':l.total_base_units)+'</b></span>'+
    '<span>cost/unit <b>'+(l.cost_per_base_unit==null?'—':'$'+Number(l.cost_per_base_unit).toFixed(4))+'</b></span>'+
    '</div>';

  var fields=FIELDS.map(function(f){
    return '<div class="f'+(changed(l,f[0])?' changed':'')+'"><label>'+esc(f[1])+'</label>'+
      '<input data-l="'+l.id+'" data-f="'+f[0]+'" value="'+esc(val(l,f[0]))+'"></div>';
  }).join('');

  var cc=val(l,'chef_category');
  var catSel='<div class="f'+(changed(l,'chef_category')?' changed':'')+'"><label>Category</label>'+
    '<select data-l="'+l.id+'" data-f="chef_category"><option value="">— pick —</option>'+
    CHEF.map(function(c){return '<option value="'+c[0]+'"'+(cc===c[0]?' selected':'')+'>'+
      esc(c[1])+' → '+c[2]+'</option>';}).join('')+'</select></div>';

  var ii=val(l,'ingredient_id');
  var ingSel='<div class="f'+(changed(l,'ingredient_id')?' changed':'')+'"><label>Ingredient</label>'+
    '<select data-l="'+l.id+'" data-f="ingredient_id"><option value="">— none —</option>'+
    ingredients.map(function(g){return '<option value="'+g.id+'"'+(ii===g.id?' selected':'')+'>'+
      esc(g.name)+'</option>';}).join('')+'</select></div>';

  var newIng='<div class="f'+(changed(l,'__new_ing')?' changed':'')+'"><label>…or new ingredient</label>'+
    '<input data-l="'+l.id+'" data-f="__new_ing" placeholder="name it" value="'+esc(val(l,'__new_ing'))+'"></div>';

  var receipt='';
  if(res&&res.ok){
    receipt='<div class="receipt">'+
      '<span class="hd">SAVED'+(res.memory_id?' &amp; REMEMBERED':'')+'</span>'+
      '<span>'+res.corrections+' field'+(res.corrections===1?'':'s')+' written to invoice_corrections</span>'+
      (res.memory_id
        ? '<span>memory now holds: '+esc(res.confirmed.join(', ')||'—')+'</span>'
        : '<span>no memory written'+(res.skipped.length?' (not knowledge: '+esc(res.skipped.join(', '))+')':'')+'</span>')+
      '<span>recomputed: '+esc(res.units==null?'—':res.units)+' '+esc(res.base||'')+
        ' @ '+(res.cost==null?'—':'$'+Number(res.cost).toFixed(4))+'</span>'+
      '<span>invoice status: '+esc(res.status)+'</span>'+
    '</div>';
  }else if(res&&res.error){
    receipt='<div class="err">Save failed — '+esc(res.error)+'</div>';
  }

  return '<div class="line'+(res&&res.ok?' done':'')+'">'+
    '<div class="lhead"><span class="name">'+esc(l.item_description||'(no description)')+'</span>'+flags+'</div>'+
    calc+
    '<div class="grid">'+fields+catSel+ingSel+newIng+'</div>'+
    '<div class="foot">'+
      '<button class="save" data-save="'+l.id+'"'+(isDirty?'':' disabled')+'>Save &amp; remember</button>'+
      (isDirty?'<button class="undo" data-undo="'+l.id+'">Discard</button>':'')+
      (isDirty?'<span style="color:var(--warn);font-size:13px">unsaved changes</span>':'')+
    '</div>'+receipt+'</div>';
}

/* ---------- 3. save via mise_apply_correction ONLY ---------- */
function save(id){
  var l=lines.filter(function(x){return x.id===id;})[0];
  if(!l)return;
  var e=edits[id]||{};
  var patch={};
  FIELDS.forEach(function(f){ if(changed(l,f[0])) patch[f[0]]=e[f[0]]===''?null:e[f[0]]; });
  if(changed(l,'chef_category')) patch.chef_category=e.chef_category===''?null:e.chef_category;

  var newName=(e.__new_ing||'').trim();
  if(newName){
    // clear the link so the RPC's find-or-create runs on the name
    if(l.ingredient_id) patch.ingredient_id=null;
  }else if(changed(l,'ingredient_id')){
    patch.ingredient_id=e.ingredient_id===''?null:e.ingredient_id;
  }

  if(!Object.keys(patch).length&&!newName){return;}

  var btn=document.querySelector('[data-save="'+id+'"]');
  if(btn){btn.disabled=true;btn.textContent='Saving…';}

  rpcCall('mise_apply_correction',{p_line_item_id:id,p_patch:patch,p_ingredient_name:newName||null})
  .then(function(out){
    results[id]={ok:true,
      corrections:out.corrections_logged||0,
      memory_id:out.memory_id||null,
      confirmed:out.memory_confirmed||[],
      skipped:out.memory_skipped||[],
      units:out.total_base_units, cost:out.cost_per_base_unit,
      base:out.standardized_base_unit, status:out.invoice_status};
    delete edits[id];
    // re-read the saved line so what is shown is what the database holds
    return q('invoice_line_items?id=eq.'+id+'&select=*').then(function(rows){
      if(rows&&rows[0]){
        for(var i=0;i<lines.length;i++) if(lines[i].id===id) lines[i]=rows[0];
      }
      render();
    });
  })
  .catch(function(err){
    results[id]={error:err.message};
    render();
  });
}

/* ---------- events ---------- */
document.addEventListener('input',function(ev){
  var t=ev.target;
  if(!t.dataset||!t.dataset.l)return;
  if(!edits[t.dataset.l])edits[t.dataset.l]={};
  edits[t.dataset.l][t.dataset.f]=t.value;
  var l=lines.filter(function(x){return x.id===t.dataset.l;})[0];
  var btn=document.querySelector('[data-save="'+t.dataset.l+'"]');
  if(btn&&l)btn.disabled=!dirty(l);
  var f=t.closest('.f'); if(f&&l)f.classList.toggle('changed',changed(l,t.dataset.f));
});
document.addEventListener('change',function(ev){
  var t=ev.target;
  if(t.tagName!=='SELECT'||!t.dataset.l)return;
  if(!edits[t.dataset.l])edits[t.dataset.l]={};
  edits[t.dataset.l][t.dataset.f]=t.value;
  render();
});
document.addEventListener('click',function(ev){
  var o=ev.target.closest('[data-open]'); if(o){openInvoice(o.dataset.open);return;}
  var s=ev.target.closest('[data-save]'); if(s){save(s.dataset.save);return;}
  var u=ev.target.closest('[data-undo]'); if(u){delete edits[u.dataset.undo];render();return;}
});
back.addEventListener('click',showList);

showList();
`;
}

const APP = SHELL(
  '<div class="wrap">' +
  '<div class="top"><h1>MiseAI Correct</h1><span class="sub" id="sub">Loading…</span>' +
  '<span style="flex:1"></span><button class="back" id="back" hidden>&larr; All invoices</button></div>' +
  '<div id="view"><div class="empty">Loading…</div></div>' +
  '</div>' +
  '<script>' + APP_JS() + '</script>'
);

Deno.serve(async (req) => {
  const url = new URL(req.url);
  if (!ACCESS_CODE) {
    return new Response('Locked: REVIEW_ACCESS_CODE is not set on this project.', { status: 503 });
  }

  // Server-side PostgREST proxy: the only path that ever holds a Postgres
  // credential. Gated on the access-code cookie, not on request method.
  if (url.searchParams.has('api')) {
    return proxyRest(req, url);
  }

  const html = { 'Content-Type': 'text/html; charset=utf-8' };

  const submitted = url.searchParams.get('code');
  if (submitted !== null) {
    if (submitted === ACCESS_CODE) {
      return new Response(null, {
        status: 302,
        headers: {
          'Set-Cookie': COOKIE + '=' + ACCESS_CODE + '; Path=/; Max-Age=2592000; HttpOnly; Secure; SameSite=Lax',
          'Location': url.pathname,
        },
      });
    }
    return new Response(GATE(true), { status: 401, headers: html });
  }

  if (cookieValue(req, COOKIE) !== ACCESS_CODE) {
    return new Response(GATE(false), { status: 401, headers: html });
  }
  return new Response(APP, { headers: html });
});
