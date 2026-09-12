// @ts-nocheck
/**
 * MiseAI Review Queue - fix OCR'd invoice lines, match them to ingredients.
 *
 * Gated by a single shared access code (REVIEW_ACCESS_CODE secret), checked
 * via a simple cookie. This is an internal ops tool across all clients, not a
 * per-restaurant login -- the code just keeps random visitors out.
 *
 * CORRECTIONS GO THROUGH ONE TRUSTED PATH.
 * Line edits are no longer PATCHed straight at PostgREST. They are sent to
 * mise_apply_correction(), which in ONE transaction:
 *   1. updates the line,
 *   2. writes the invoice_corrections audit rows (unchanged contract),
 *   3. links or creates the ingredient,
 *   4. upserts client_item_memory so the NEXT invoice for the same
 *      vendor + item code gets it right with no human,
 *   5. recomputes invoice status so a finished invoice leaves this queue.
 *
 * The browser has no direct access to client_item_memory at all -- the table
 * grants nothing to anon. Only an owner correction can create memory.
 *
 * SECURITY: everything below used to reach PostgREST directly from the
 * browser using an anon key embedded in this file's own JS -- readable by
 * anyone who viewed source. invoices/invoice_line_items/ingredients/
 * invoice_corrections all had `USING (true)` RLS policies with no client_id
 * filter, so that key gave unrestricted read/write across every restaurant
 * (locker finding 9ac158b0). The cookie below gated the page; it never
 * gated the data.
 *
 * Fixed the same way as Correct: every remaining direct PostgREST call
 * (load, new-line insert, line removal, the header patch, the corrections
 * insert, new-ingredient creation) now goes through this function's own
 * ?api= proxy, which re-checks the access-code cookie and only then talks to
 * PostgREST using SUPABASE_SERVICE_ROLE_KEY server-side. No Postgres
 * credential reaches the browser any more. Behaviour and request shapes are
 * unchanged -- only where the privileged call happens.
 *
 * PACK and SIZE are editable here now. They are what the pack maths actually
 * reads, and they are what was wrong on the Feta line: a printed "2/5 LB"
 * arrived as pack "25" size "LB", which is a 2.5x error in cost per pound.
 *
 * Categories come from the pnl_categories table, never from a list in here, so
 * adding TO_GO or splitting PAPER is an INSERT rather than a redeploy.
 */
const ACCESS_CODE = Deno.env.get('REVIEW_ACCESS_CODE');
const COOKIE_NAME = 'mise_review_auth';

function getCookie(req, name) {
  const header = req.headers.get('cookie') ?? '';
  for (const part of header.split(';')) {
    const eq = part.indexOf('=');
    if (eq === -1) continue;
    const k = part.slice(0, eq).trim();
    const v = part.slice(eq + 1).trim();
    if (k === name) return v;
  }
  return null;
}

// The only place a Postgres credential is used. Gated on the same
// access-code cookie that already protects the page.
async function proxyRest(req, url) {
  if (getCookie(req, COOKIE_NAME) !== ACCESS_CODE) {
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

const LOGIN_PAGE = (showError) => `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>MiseAI - Review Queue</title>
<style>
:root{--bg:#12151a;--card:#1a1e26;--rec:#151920;--bd:#2a3038;--tx:#f0f4f8;--mut:#9aa5b1;--acc:#fde047;--dgr:#ff6b6b;--dgrw:rgba(255,107,107,.10);}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--tx);font:14px/1.5 system-ui,-apple-system,sans-serif;padding:20px;display:flex;min-height:100vh;align-items:center;justify-content:center;}
.card{background:var(--card);border:1px solid var(--bd);border-radius:8px;padding:28px;max-width:340px;width:100%;}
h1{font-family:ui-monospace,monospace;font-size:14px;letter-spacing:.14em;text-transform:uppercase;color:var(--acc);margin:0 0 16px;}
label{display:block;font-size:11px;letter-spacing:.1em;text-transform:uppercase;color:var(--mut);margin-bottom:6px;}
input{width:100%;background:var(--rec);border:1px solid var(--bd);border-radius:5px;padding:12px;font-size:16px;color:var(--tx);outline:none;box-sizing:border-box;}
input:focus{border-color:var(--acc);}
button{width:100%;margin-top:16px;background:var(--acc);color:var(--bg);border:none;border-radius:5px;padding:13px;font-size:13px;letter-spacing:.08em;text-transform:uppercase;cursor:pointer;}
.err{background:var(--dgrw);border:1px solid var(--dgr);color:var(--dgr);border-radius:5px;padding:10px 12px;font-size:13px;margin-bottom:14px;}
</style></head><body>
<form class="card" method="GET">
  <h1>MiseAI &middot; Review Queue</h1>
  ${showError ? '<div class="err">Wrong code. Try again.</div>' : ''}
  <label for="code">Access code</label>
  <input type="password" id="code" name="code" autofocus required>
  <button type="submit">Enter</button>
</form>
</body></html>`;

const PAGE = `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>MiseAI - Review Queue</title>
<style>
:root{
  --bg-page:#12151a;--bg-card:#1a1e26;--bg-recessed:#151920;--border-subtle:#2a3038;
  --text-hero:#f0f4f8;--text-muted:#9aa5b1;--text-faint:#6b7684;
  --brand-accent:#fde047;--brand-accent-hover:#fce96a;
  --alert-danger:#ff6b6b;--alert-danger-wash:rgba(255,107,107,0.10);
  --alert-success:#5ddba0;--alert-success-wash:rgba(93,219,160,0.10);
  --shadow-softer:rgba(0,0,0,0.35);
  --font-mono:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;
  --font-serif:system-ui,-apple-system,Segoe UI,sans-serif;
}
*{box-sizing:border-box}
body{margin:0;background:var(--bg-page);color:var(--text-hero);font:14px/1.5 var(--font-serif);}
.hdr{max-width:1100px;margin:0 auto;padding:26px 16px 0;}
.hdr h1{font-family:var(--font-mono);font-size:15px;letter-spacing:.14em;text-transform:uppercase;color:var(--brand-accent);margin:0 0 5px;}
.hdr .sub{color:var(--text-muted);font-size:13px;}
.tabs{max-width:1100px;margin:18px auto 0;padding:0 16px;display:flex;gap:8px;flex-wrap:wrap;}
.tab{background:transparent;color:var(--text-muted);border:1px solid var(--border-subtle);border-radius:4px;padding:6px 14px;font-family:var(--font-mono);font-size:11px;letter-spacing:.06em;cursor:pointer;}
.tab:hover{border-color:var(--text-muted);}
.tab.on{color:var(--brand-accent);border-color:var(--brand-accent);}
.tab .dot{display:inline-block;width:7px;height:7px;border-radius:50%;margin-right:6px;vertical-align:middle;}
.tab .dot.high{background:var(--alert-danger);}
.tab .dot.medium{background:var(--brand-accent);}
.tab .dot.low{background:var(--text-faint);}
.footnote{max-width:1100px;margin:0 auto;padding:0 16px 60px;font-family:var(--font-mono);font-size:11px;color:var(--text-faint);text-align:center;}

/* REVIEW QUEUE (invoice line corrections) */
.corr-wrap{max-width:1100px;margin:0 auto;padding:24px 16px 40px;}
.corr-card{background:var(--bg-card);border:1px solid var(--border-subtle);border-radius:6px;margin-bottom:12px;overflow:hidden;box-shadow:0 2px 8px var(--shadow-softer);}
.corr-card-head{display:flex;align-items:center;gap:14px;padding:14px 18px;cursor:pointer;user-select:none;flex-wrap:wrap;}
.corr-card-head:hover{background:var(--bg-recessed);}
.corr-chevron{font-size:11px;color:var(--text-faint);transition:transform .15s;flex-shrink:0;}
.corr-chevron.open{transform:rotate(90deg);}
.corr-dot{width:9px;height:9px;border-radius:50%;flex-shrink:0;}
.corr-dot.high{background:var(--alert-danger);}
.corr-dot.medium{background:var(--brand-accent);}
.corr-dot.low{background:var(--text-faint);}
.corr-meta{flex:1;display:flex;gap:26px;flex-wrap:wrap;align-items:center;}
.corr-lbl{font-family:var(--font-mono);font-size:10px;color:var(--text-faint);text-transform:uppercase;letter-spacing:.08em;margin-bottom:2px;}
.corr-val{font-family:var(--font-mono);font-size:13px;color:var(--text-hero);}
.corr-badge-unsaved{font-family:var(--font-mono);font-size:10px;color:var(--brand-accent);font-weight:400;letter-spacing:.06em;}
.corr-badge-saved{font-family:var(--font-mono);font-size:10px;color:var(--alert-success);font-weight:400;letter-spacing:.06em;}
.corr-alert{background:var(--alert-danger-wash);border:1px solid var(--alert-danger);border-radius:4px;padding:7px 14px;font-size:12px;color:var(--alert-danger);margin:0 18px 10px;font-family:var(--font-serif);}
.corr-alert:first-of-type{margin-top:12px;}
.corr-body{border-top:1px solid var(--border-subtle);}
.corr-hdr-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:1px;background:var(--border-subtle);border-bottom:1px solid var(--border-subtle);}
.corr-hdr-cell{background:var(--bg-card);padding:10px 16px;}
.corr-hdr-cell input{width:100%;background:var(--bg-recessed);border:1px solid var(--brand-accent);border-radius:3px;padding:5px 7px;font-family:var(--font-mono);font-size:12px;color:var(--text-hero);outline:none;margin-top:4px;box-sizing:border-box;}
.corr-table-wrap{overflow-x:auto;}
.corr-table{width:100%;border-collapse:collapse;font-family:var(--font-mono);font-size:12px;}
.corr-table th{text-align:left;padding:8px 10px;font-size:10px;letter-spacing:.07em;text-transform:uppercase;color:var(--text-faint);background:var(--bg-recessed);border-bottom:1px solid var(--border-subtle);white-space:nowrap;}
.corr-table td{padding:6px 10px;border-bottom:1px solid var(--border-subtle);vertical-align:middle;}
.corr-table input,.corr-table select{width:100%;background:var(--bg-recessed);border:1px solid var(--brand-accent);border-radius:3px;padding:4px 7px;font-family:var(--font-mono);font-size:12px;color:var(--text-hero);outline:none;box-sizing:border-box;}
.corr-table select{font-family:var(--font-serif);}
.corr-row-changed{background:rgba(253,224,71,0.06);}
.corr-row-flagged{background:rgba(255,107,107,0.06);}
.corr-pill{display:inline-block;font-size:10px;font-weight:400;padding:2px 8px;border-radius:10px;font-family:var(--font-mono);white-space:nowrap;}
.corr-pill.matched{background:var(--alert-success-wash);color:var(--alert-success);}
.corr-pill.needsfix{background:var(--alert-danger-wash);color:var(--alert-danger);}
.corr-pill.excluded{background:rgba(240,244,248,0.10);color:var(--text-faint);}
.corr-pill.remembered{background:rgba(93,219,160,0.10);color:var(--alert-success);}
.corr-rm{background:none;border:none;color:var(--alert-danger);cursor:pointer;font-size:16px;line-height:1;padding:0 4px;}
.corr-total-row td{font-weight:400;background:var(--bg-recessed);}
.corr-actions{display:flex;gap:10px;align-items:center;padding:14px 18px;border-top:1px solid var(--border-subtle);background:var(--bg-recessed);flex-wrap:wrap;}
.corr-btn-primary{background:var(--brand-accent);color:var(--bg-card);border:none;border-radius:4px;padding:9px 20px;font-family:var(--font-mono);font-size:11px;letter-spacing:.08em;text-transform:uppercase;font-weight:400;cursor:pointer;}
.corr-btn-primary:hover{background:var(--brand-accent-hover);}
.corr-btn-primary:disabled{opacity:.4;cursor:not-allowed;}
.corr-btn-secondary{background:transparent;color:var(--text-hero);border:1px solid var(--border-subtle);border-radius:4px;padding:9px 16px;font-family:var(--font-mono);font-size:11px;letter-spacing:.08em;text-transform:uppercase;cursor:pointer;}
.corr-btn-secondary:hover{border-color:var(--text-hero);}
.corr-success{font-family:var(--font-mono);font-size:11px;color:var(--alert-success);}
.corr-empty{padding:60px 20px;text-align:center;font-family:var(--font-serif);font-style:italic;color:var(--text-muted);font-size:13px;}
.corr-note{font-family:var(--font-mono);font-size:10px;color:var(--text-faint);display:block;margin-top:3px;white-space:normal;max-width:300px;}
.corr-ro{color:var(--text-muted);white-space:nowrap;}
.corr-na{font-family:var(--font-mono);font-size:11px;color:var(--text-faint);}
</style></head><body>
<div class="hdr">
  <h1>Review Queue</h1>
  <div class="sub">Fix OCR'd invoice lines &middot; a saved correction is remembered for the next invoice from the same vendor and item code</div>
</div>
<div class="tabs" id="tabs"></div>
<div class="corr-wrap" id="wrap"><div class="corr-empty">Loading...</div></div>
<div class="footnote">Every correction logged &middot; Corrections become reusable data, not a one-off edit</div>
<script>
var TOL=0.02;
var FEE_RE=/FUEL|SURCHARGE|DELIVERY|FREIGHT|SPLIT\\s*CASE|MIN(IMUM)?\\s*ORDER|PICKUP|CREDIT|DEPOSIT/i;

var wrap=document.getElementById('wrap');
var tabsEl=document.getElementById('tabs');
var filter='all';
var invoices=[],ingredients=[],categories=[],edits={},removed={},added={},open={};

var HEADER_FIELDS=[['invoice_number','Invoice #'],['invoice_date','Date received'],['subtotal','Subtotal ($)'],['grand_total','Total ($)']];
// raw_pack / raw_size are what the pack maths actually reads. They were not
// editable before, which is why the Feta line could not be fixed at all.
var LINE_COLS=[
  ['item_description','Description',230],
  ['vendor_item_code','SKU',90],
  ['raw_quantity','Qty',64],
  ['raw_pack','Pack',64],
  ['raw_size','Size',80],
  ['raw_uom','Unit',96],
  ['raw_unit_price','Unit Price',84],
  ['line_total','Extended',90]
];
// Sent to mise_apply_correction. Quantity/price/total are invoice facts and are
// never remembered; pack/size/unit/category/ingredient are.
var RPC_FIELDS={item_description:1,vendor_item_code:1,raw_quantity:1,raw_uom:1,raw_pack:1,
  raw_size:1,raw_unit_price:1,line_total:1,chef_category:1,pnl_category:1,ingredient_id:1};

function esc(s){return String(s==null?'':s).replace(/[&<>"]/g,function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c];});}
function num(v){if(v===''||v==null)return null;var n=Number(v);return isFinite(n)?n:null;}
function money(v){return v==null?'-':'$'+Number(v).toFixed(2);}
function cents(v){return Math.round(Number(v)*100);}
function uid(){return 'new-'+Math.random().toString(36).slice(2,10);}

// Same-origin call to THIS edge function's proxy, never PostgREST directly
// with an exposed key. The access-code cookie travels automatically.
function q(path,init){
  return fetch('?api='+encodeURIComponent(path),init).then(function(r){
    return r.text().then(function(t){
      if(!r.ok)throw new Error('HTTP '+r.status+' '+t.slice(0,200));
      return t?JSON.parse(t):null;
    });
  });
}
function qWrite(path,method,body,prefer){
  var h={'Content-Type':'application/json'};
  if(prefer)h['Prefer']=prefer;
  return q(path,{method:method,headers:h,body:JSON.stringify(body)});
}
function rpc(fn,args){return q('rpc/'+fn,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(args)});}

function allLines(inv){return (inv.invoice_line_items||[]).concat(added[inv.id]||[]);}
function isNew(li){return String(li.id).indexOf('new-')===0;}
function isFee(inv,li){
  var d=cur(inv.id,li.id,'item_description',li.item_description)||'';
  if(FEE_RE.test(d))return true;
  var q=num(cur(inv.id,li.id,'raw_quantity',li.raw_quantity));
  var p=num(cur(inv.id,li.id,'raw_unit_price',li.raw_unit_price));
  return q==null&&p==null;
}

function cur(invId,lineId,field,stored){
  var e=edits[invId];
  if(!e)return stored;
  var bag=lineId?(e.lines&&e.lines[lineId]):e.header;
  if(bag&&Object.prototype.hasOwnProperty.call(bag,field))return bag[field];
  return stored;
}
function setEdit(invId,lineId,field,value){
  if(!edits[invId])edits[invId]={header:{},lines:{}};
  if(lineId){
    if(!edits[invId].lines[lineId])edits[invId].lines[lineId]={};
    edits[invId].lines[lineId][field]=value;
  }else edits[invId].header[field]=value;
}
function isDirty(invId){
  if(removed[invId]&&Object.keys(removed[invId]).length)return true;
  if(added[invId]&&added[invId].length)return true;
  var e=edits[invId];
  if(!e)return false;
  if(Object.keys(e.header).length)return true;
  var ids=Object.keys(e.lines);
  for(var i=0;i<ids.length;i++)if(Object.keys(e.lines[ids[i]]).length)return true;
  return false;
}
function isRemoved(invId,lineId){return !!(removed[invId]&&removed[invId][lineId]);}

function lineMath(inv,li){
  var q=num(cur(inv.id,li.id,'raw_quantity',li.raw_quantity));
  var p=num(cur(inv.id,li.id,'raw_unit_price',li.raw_unit_price));
  var t=num(cur(inv.id,li.id,'line_total',li.line_total));
  if(q==null||p==null||t==null)return {calc:null,state:'excluded'};
  var calc=Math.round(q*p*100)/100;
  return {calc:calc,state:Math.abs(cents(calc)-cents(t))<=cents(TOL)?'matched':'needsfix'};
}
function lineSum(inv){
  var c=0,ls=allLines(inv);
  for(var i=0;i<ls.length;i++){
    if(isRemoved(inv.id,ls[i].id))continue;
    var t=num(cur(inv.id,ls[i].id,'line_total',ls[i].line_total));
    if(t!=null)c+=cents(t);
  }
  return c/100;
}
function unmatchedCount(inv){
  var n=0,ls=allLines(inv);
  for(var i=0;i<ls.length;i++){
    var li=ls[i];
    if(isRemoved(inv.id,li.id)||isFee(inv,li))continue;
    if(!cur(inv.id,li.id,'ingredient_id',li.ingredient_id))n++;
  }
  return n;
}
function uncategorized(inv){
  var n=0,ls=allLines(inv);
  for(var i=0;i<ls.length;i++){
    var li=ls[i];
    if(isRemoved(inv.id,li.id)||isFee(inv,li))continue;
    if(!cur(inv.id,li.id,'pnl_category',li.pnl_category))n++;
  }
  return n;
}
function lowConfidence(inv){
  var ls=inv.invoice_line_items||[];
  for(var i=0;i<ls.length;i++)if(ls[i].pack_confidence==='low')return true;
  return false;
}
function severity(inv){
  var st=num(cur(inv.id,null,'subtotal',inv.subtotal));
  var sum=lineSum(inv);
  if(st!=null&&Math.abs(sum-st)>=100)return 'high';
  var ls=allLines(inv);
  for(var i=0;i<ls.length;i++){
    if(isRemoved(inv.id,ls[i].id))continue;
    if(lineMath(inv,ls[i]).state==='needsfix')return (st!=null&&Math.abs(sum-st)>TOL)?'high':'medium';
  }
  if(unmatchedCount(inv)>0||uncategorized(inv)>0||lowConfidence(inv))return 'medium';
  return 'low';
}

async function load(){
  wrap.innerHTML='<div class="corr-empty">Loading...</div>';
  try{
    invoices=await q('invoices?select=*,invoice_line_items(*)&status=neq.completed'+
      '&invoice_line_items.removed_by_review=is.false&order=created_at.desc&limit=50');

    categories=await q('pnl_categories?select=code,label,sort_order&order=sort_order.asc').catch(function(){return [];});

    ingredients=await q('ingredients?select=*&order=name.asc&limit=2000').catch(function(){return [];});

    edits={};removed={};added={};
    render();
  }catch(err){
    wrap.innerHTML='<div class="corr-alert">Could not load the queue: '+esc(err.message)+'</div>';
  }
}

function render(){
  var counts={all:invoices.length,high:0,medium:0,low:0};
  invoices.forEach(function(i){counts[severity(i)]++;});
  tabsEl.innerHTML=tab('all','All',counts.all)+tab('high','High',counts.high)+
    tab('medium','Medium',counts.medium)+tab('low','Low',counts.low);
  var list=invoices.filter(function(i){return filter==='all'||severity(i)===filter;});
  wrap.innerHTML=list.length?list.map(card).join('')
    :'<div class="corr-empty">Nothing here. Every invoice in this bucket reconciles.</div>';
}
function tab(id,label,n){
  var dot=id==='all'?'':'<span class="dot '+id+'"></span>';
  return '<button class="tab'+(filter===id?' on':'')+'" data-tab="'+id+'">'+dot+esc(label)+' ('+n+')</button>';
}

function card(inv){
  var isOpen=!!open[inv.id];
  var badge=isDirty(inv.id)?'<span class="corr-badge-unsaved">UNSAVED</span>'
    :(inv.corrected_at?'<span class="corr-badge-saved">CORRECTED</span>':'');
  var head='<div class="corr-card-head" data-toggle="'+inv.id+'">'+
    '<span class="corr-chevron'+(isOpen?' open':'')+'">&#9654;</span>'+
    '<span class="corr-dot '+severity(inv)+'"></span><div class="corr-meta">'+
    meta('Vendor',cur(inv.id,null,'vendor_name',inv.vendor_name)||'Unknown')+
    meta('Invoice',cur(inv.id,null,'invoice_number',inv.invoice_number)||'-')+
    meta('Date',cur(inv.id,null,'invoice_date',inv.invoice_date)||'-')+
    meta('Total',money(num(cur(inv.id,null,'grand_total',inv.grand_total))))+
    meta('Lines',String(allLines(inv).length))+
    '</div>'+badge+'</div>';
  return '<div class="corr-card" data-inv="'+inv.id+'">'+head+(isOpen?body(inv):'')+'</div>';
}
function meta(l,v){return '<div><div class="corr-lbl">'+esc(l)+'</div><div class="corr-val">'+esc(v)+'</div></div>';}

function body(inv){
  var alerts='';
  var um=unmatchedCount(inv);
  if(um)alerts+='<div class="corr-alert">&#9888; '+um+' ingredient line'+(um===1?'':'s')+
    ' could not be matched &mdash; pick a category or fix the description below</div>';
  if(lowConfidence(inv))alerts+='<div class="corr-alert">&#9888; OCR confidence was low on this scan &mdash; check pack, size and quantities carefully</div>';
  if(inv.flag_reason&&!um&&!lowConfidence(inv))alerts+='<div class="corr-alert">&#9888; '+esc(String(inv.flag_reason).split('\\n')[0])+'</div>';

  var hdr='<div class="corr-hdr-grid">'+HEADER_FIELDS.map(function(f){
    return '<div class="corr-hdr-cell"><div class="corr-lbl">'+esc(f[1])+'</div>'+
      '<input data-inv="'+inv.id+'" data-field="'+f[0]+'" value="'+esc(cur(inv.id,null,f[0],inv[f[0]]))+'"></div>';
  }).join('')+'</div>';

  var rows=allLines(inv).map(function(li){return row(inv,li);}).join('');
  var table='<div class="corr-table-wrap"><table class="corr-table"><thead><tr>'+
    LINE_COLS.map(function(c){return '<th>'+esc(c[1])+'</th>';}).join('')+
    '<th>Category</th><th>Ingredient ID</th><th>Status</th><th></th></tr></thead>'+
    '<tbody>'+rows+'</tbody><tfoot><tr class="corr-total-row">'+
    '<td colspan="'+(LINE_COLS.length-1)+'">Line total</td><td>'+money(lineSum(inv))+'</td><td colspan="4"></td>'+
    '</tr></tfoot></table></div>';

  var actions='<div class="corr-actions">'+
    '<button class="corr-btn-secondary" data-add="'+inv.id+'">+ Add line</button>'+
    '<button class="corr-btn-primary" data-save="'+inv.id+'"'+(isDirty(inv.id)?'':' disabled')+'>Save &amp; remember</button>'+
    '<button class="corr-btn-secondary" data-reset="'+inv.id+'">Discard</button>'+
    '<span class="corr-success" id="msg-'+inv.id+'"></span></div>';

  return '<div class="corr-body">'+alerts+hdr+table+actions+'</div>';
}

function row(inv,li){
  var gone=isRemoved(inv.id,li.id);
  var fee=isFee(inv,li);
  var m=lineMath(inv,li);
  var e=edits[inv.id]&&edits[inv.id].lines[li.id];
  var changed=(e&&Object.keys(e).length>0)||isNew(li);
  var cls=gone?'corr-row-flagged':(changed?'corr-row-changed':(li.is_flagged?'corr-row-flagged':''));

  var cells=LINE_COLS.map(function(c){
    var v=cur(inv.id,li.id,c[0],li[c[0]]);
    var note=(c[0]==='item_description'&&li.flag_notes&&li.flag_notes.length)
      ?'<span class="corr-note">'+esc(li.flag_notes.join(' '))+'</span>':'';
    return '<td style="min-width:'+c[2]+'px"><input data-inv="'+inv.id+'" data-line="'+li.id+'" data-field="'+c[0]+'" value="'+esc(v)+'"'+(gone?' disabled':'')+'>'+note+'</td>';
  }).join('');

  var catCell,ingCell;
  if(fee){
    catCell='<td><span class="corr-na">n/a &mdash; fee</span></td>';
    ingCell='<td><span class="corr-na">n/a &mdash; fee</span></td>';
  }else{
    var cat=cur(inv.id,li.id,'pnl_category',li.pnl_category)||'';
    catCell='<td style="min-width:130px"><select data-inv="'+inv.id+'" data-line="'+li.id+'" data-field="pnl_category"'+(gone?' disabled':'')+'>'+
      '<option value=""'+(cat?'':' selected')+'>&mdash; pick &mdash;</option>'+
      categories.map(function(c){return '<option value="'+esc(c.code)+'"'+(cat===c.code?' selected':'')+'>'+esc(c.label||c.code)+'</option>';}).join('')+
      '</select></td>';
    var ing=cur(inv.id,li.id,'ingredient_id',li.ingredient_id)||'';
    var mine=ingredients.filter(function(g){return g.client_id===inv.client_id;});
    ingCell='<td style="min-width:170px"><select data-inv="'+inv.id+'" data-line="'+li.id+'" data-field="ingredient_id" data-ing="1"'+(gone?' disabled':'')+'>'+
      '<option value=""'+(ing?'':' selected')+'>&mdash; unmatched &mdash;</option>'+
      mine.map(function(g){return '<option value="'+g.id+'"'+(ing===g.id?' selected':'')+'>'+esc(g.name)+'</option>';}).join('')+
      '<option value="__new">+ Create new&hellip;</option></select></td>';
  }

  var pill=fee?'<span class="corr-pill excluded">excluded</span>'
    :(m.state==='matched'?'<span class="corr-pill matched">matched</span>'
    :(m.state==='needsfix'?'<span class="corr-pill needsfix">needs fix</span>'
    :'<span class="corr-pill excluded">no line math</span>'));
  if(!fee&&li.category_source==='human'&&!changed)pill='<span class="corr-pill remembered">remembered</span>';
  if(gone)pill='<span class="corr-pill excluded">removed</span>';

  return '<tr class="'+cls+'">'+cells+catCell+ingCell+'<td>'+pill+'</td>'+
    '<td><button class="corr-rm" data-rm="'+li.id+'" data-inv="'+inv.id+'">'+(gone?'&#8630;':'&times;')+'</button></td></tr>';
}

tabsEl.addEventListener('click',function(ev){
  var b=ev.target.closest('[data-tab]');
  if(!b)return;
  filter=b.dataset.tab;render();
});
wrap.addEventListener('click',function(ev){
  var t=ev.target;
  if(t.dataset&&t.dataset.rm){toggleRemove(t.dataset.inv,t.dataset.rm);return;}
  if(t.dataset&&t.dataset.add){addLine(t.dataset.add);return;}
  if(t.dataset&&t.dataset.save){save(t.dataset.save);return;}
  if(t.dataset&&t.dataset.reset){delete edits[t.dataset.reset];delete removed[t.dataset.reset];delete added[t.dataset.reset];render();return;}
  var head=t.closest?t.closest('[data-toggle]'):null;
  if(head&&!t.matches('input,select,button')){open[head.dataset.toggle]=!open[head.dataset.toggle];render();}
});
wrap.addEventListener('input',function(ev){
  var t=ev.target;
  if(t.tagName!=='INPUT'||!t.dataset.field)return;
  setEdit(t.dataset.inv,t.dataset.line||null,t.dataset.field,t.value);
  live(t);
});
wrap.addEventListener('change',async function(ev){
  var t=ev.target;
  if(t.tagName!=='SELECT')return;
  if(t.dataset.ing&&t.value==='__new'){
    var inv=invoices.filter(function(i){return i.id===t.dataset.inv;})[0];
    var name=prompt('Name this ingredient (it becomes the key Price Moves tracks):');
    if(!name){t.value=cur(t.dataset.inv,t.dataset.line,'ingredient_id','')||'';return;}
    try{
      var created=(await qWrite('ingredients','POST',[{client_id:inv.client_id,name:name.trim()}],'return=representation'))[0];
      ingredients.push(created);
      setEdit(t.dataset.inv,t.dataset.line,'ingredient_id',created.id);
      render();
    }catch(err){alert('Could not create ingredient: '+err.message);}
    return;
  }
  setEdit(t.dataset.inv,t.dataset.line||null,t.dataset.field,t.value);
  var card=document.querySelector('[data-inv="'+t.dataset.inv+'"]');
  var btn=card&&card.querySelector('[data-save]');
  if(btn)btn.disabled=!isDirty(t.dataset.inv);
  var tr=t.closest('tr');if(tr)tr.className='corr-row-changed';
});

function live(el){
  var invId=el.dataset.inv;
  var inv=invoices.filter(function(i){return i.id===invId;})[0];
  if(!inv)return;
  var card=document.querySelector('[data-inv="'+invId+'"]');
  if(!card)return;
  var btn=card.querySelector('[data-save]');
  if(btn)btn.disabled=!isDirty(invId);
  var tr=el.closest('tr');
  if(tr&&el.dataset.line){
    var li=allLines(inv).filter(function(l){return l.id===el.dataset.line;})[0];
    if(li){
      var m=lineMath(inv,li),fee=isFee(inv,li);
      var tds=tr.querySelectorAll('td');
      tds[LINE_COLS.length+2].innerHTML=fee?'<span class="corr-pill excluded">excluded</span>'
        :(m.state==='matched'?'<span class="corr-pill matched">matched</span>'
        :(m.state==='needsfix'?'<span class="corr-pill needsfix">needs fix</span>'
        :'<span class="corr-pill excluded">no line math</span>'));
      tr.className='corr-row-changed';
    }
  }
  var foot=card.querySelector('.corr-total-row');
  if(foot)foot.querySelectorAll('td')[1].textContent=money(lineSum(inv));
}

function toggleRemove(invId,lineId){
  if(!removed[invId])removed[invId]={};
  if(removed[invId][lineId])delete removed[invId][lineId];else removed[invId][lineId]=true;
  render();
}
function addLine(invId){
  if(!added[invId])added[invId]=[];
  added[invId].push({id:uid(),item_description:'',vendor_item_code:null,raw_quantity:null,
    raw_pack:null,raw_size:null,raw_uom:null,raw_unit_price:null,line_total:null,
    pnl_category:null,ingredient_id:null,flag_notes:[]});
  open[invId]=true;render();
}

var NUMERIC={raw_quantity:1,raw_unit_price:1,line_total:1,subtotal:1,tax:1,grand_total:1};
function coerce(f,v){if(NUMERIC[f])return num(v);return v===''?null:v;}

async function rpcApply(fn,args){
  var out=await rpc(fn,args);
  return out;
}

/**
 * Save order matters.
 *   1. header edits, removals and brand-new lines -> direct writes + audit rows
 *   2. edited existing lines -> mise_apply_correction, one call per line
 * The RPC increments correction_count and sets invoice status itself, so the
 * header patch is done FIRST and never overwrites what the RPC then records.
 */
async function save(invId){
  var inv=invoices.filter(function(i){return i.id===invId;})[0];
  if(!inv)return;
  var msg=document.getElementById('msg-'+invId);
  msg.textContent='Saving\\u2026';
  var e=edits[invId]||{header:{},lines:{}};
  var corrections=[];
  var remembered=0,rpcCorrections=0;
  try{
    var hPatch={};
    Object.keys(e.header).forEach(function(f){
      var next=coerce(f,e.header[f]);
      if(String(inv[f]==null?'':inv[f])===String(next==null?'':next))return;
      hPatch[f]=next;
      corrections.push({invoice_id:invId,line_item_id:null,field_name:f,
        old_value:inv[f]==null?null:String(inv[f]),new_value:next==null?null:String(next),
        model_used:inv.model_used||null});
    });

    var newRows=(added[invId]||[]);
    for(var n=0;n<newRows.length;n++){
      var nr=newRows[n],payload={invoice_id:invId,is_flagged:false};
      ['item_description','vendor_item_code','raw_quantity','raw_pack','raw_size','raw_uom','raw_unit_price','line_total','pnl_category','ingredient_id'].forEach(function(f){
        payload[f]=coerce(f,cur(invId,nr.id,f,nr[f]));
      });
      if(!payload.item_description)continue;
      if(payload.ingredient_id)payload.matched_at=new Date().toISOString();
      await qWrite('invoice_line_items','POST',[payload]);
      corrections.push({invoice_id:invId,line_item_id:null,field_name:'line_added',
        old_value:null,new_value:payload.item_description,model_used:inv.model_used||null});
    }

    var rm=Object.keys(removed[invId]||{});
    for(var k=0;k<rm.length;k++){
      if(String(rm[k]).indexOf('new-')===0)continue;
      await qWrite('invoice_line_items?id=eq.'+rm[k],'PATCH',{removed_by_review:true,is_flagged:false});
      corrections.push({invoice_id:invId,line_item_id:rm[k],field_name:'removed_by_review',
        old_value:'false',new_value:'true',model_used:inv.model_used||null});
    }

    if(corrections.length){
      await qWrite('invoice_corrections','POST',corrections);
    }

    hPatch.corrected_at=new Date().toISOString();
    hPatch.correction_count=(inv.correction_count||0)+corrections.length;
    await qWrite('invoices?id=eq.'+invId,'PATCH',hPatch);

    // the one trusted correction path
    var stored=inv.invoice_line_items||[];
    var ids=Object.keys(e.lines);
    for(var i=0;i<ids.length;i++){
      var lid=ids[i];
      if(String(lid).indexOf('new-')===0)continue;
      var li=stored.filter(function(l){return l.id===lid;})[0];
      if(!li)continue;
      var patch={},fields=Object.keys(e.lines[lid]);
      for(var j=0;j<fields.length;j++){
        var f=fields[j];
        if(!RPC_FIELDS[f])continue;
        var next=coerce(f,e.lines[lid][f]);
        if(String(li[f]==null?'':li[f])===String(next==null?'':next))continue;
        patch[f]=next;
      }
      if(!Object.keys(patch).length)continue;
      var res=await rpcApply('mise_apply_correction',{p_line_item_id:lid,p_patch:patch});
      rpcCorrections+=(res&&res.corrections_logged)||0;
      if(res&&res.memory_id)remembered++;
    }

    var total=corrections.length+rpcCorrections;
    msg.textContent=total+' correction'+(total===1?'':'s')+' saved'+
      (remembered?' \\u00b7 '+remembered+' item'+(remembered===1?'':'s')+' remembered for next time':'')+'.';
    delete edits[invId];delete removed[invId];delete added[invId];
    setTimeout(load,900);
  }catch(err){
    msg.textContent='';
    alert('Save failed: '+err.message);
  }
}

load();
</script></body></html>`;

Deno.serve(async (req) => {
  const url = new URL(req.url);

  if (!ACCESS_CODE) {
    return new Response(
      'Review Queue is locked because the REVIEW_ACCESS_CODE secret is not set. Set it in your project to enable access.',
      { status: 503 }
    );
  }

  // Server-side PostgREST proxy: the only path that ever holds a Postgres
  // credential. Gated on the access-code cookie, not on request method.
  if (url.searchParams.has('api')) {
    return proxyRest(req, url);
  }

  const submitted = url.searchParams.get('code');
  if (submitted !== null) {
    if (submitted === ACCESS_CODE) {
      return new Response(null, {
        status: 302,
        headers: {
          'Set-Cookie': `${COOKIE_NAME}=${ACCESS_CODE}; Path=/; Max-Age=2592000; HttpOnly; Secure; SameSite=Lax`,
          'Location': url.pathname,
        },
      });
    }
    return new Response(LOGIN_PAGE(true), { status: 401, headers: { 'Content-Type': 'text/html; charset=utf-8' } });
  }

  const cookieValue = getCookie(req, COOKIE_NAME);
  if (cookieValue !== ACCESS_CODE) {
    return new Response(LOGIN_PAGE(false), { status: 401, headers: { 'Content-Type': 'text/html; charset=utf-8' } });
  }

  return new Response(PAGE, { headers: { 'Content-Type': 'text/html; charset=utf-8' } });
});
