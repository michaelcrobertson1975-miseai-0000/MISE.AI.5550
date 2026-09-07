// @ts-nocheck
/**
 * MiseAI invoice drop page.
 *
 * Serves a single self-contained HTML page that posts an invoice photo or PDF to
 * the ingest-invoice function on the same origin (so no CORS, no preflight) and
 * renders the audit result. Works from a phone camera.
 *
 * verify_jwt is false because a browser cannot attach a bearer token to a plain
 * page load. The page itself carries only the anon key, which Supabase publishes
 * to every browser client by design; ingest-invoice still requires it.
 */
const ANON_KEY =
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InFoZm15d29udGR3d2ZhcG93cXBvIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODgzMjg1NTEsImV4cCI6MjEwMzkwNDU1MX0.O0JeiPQVUh2OQCTgTrVdHnkvkl2J9mGeFaLZorOJfVg';
const DEFAULT_CLIENT = '7d1f0a2e-6c44-4b9a-9f31-2ab8e5c07d10';

const PAGE = `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>MiseAI — Drop an Invoice</title>
<style>
:root{--bg:#12151a;--card:#1a1e26;--rec:#151920;--bd:#2a3038;--tx:#f0f4f8;--mut:#9aa5b1;--fnt:#6b7684;
--acc:#fde047;--dgr:#ff6b6b;--dgrw:rgba(255,107,107,.10);--ok:#5ddba0;--okw:rgba(93,219,160,.10);
--mono:ui-monospace,SFMono-Regular,Menlo,monospace;}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--tx);font:14px/1.5 system-ui,-apple-system,sans-serif;padding:20px}
.wrap{max-width:900px;margin:0 auto}
h1{font-family:var(--mono);font-size:14px;letter-spacing:.14em;text-transform:uppercase;color:var(--acc);margin:0 0 4px}
.sub{color:var(--mut);font-size:13px;margin-bottom:22px}
#drop{border:2px dashed var(--bd);border-radius:8px;padding:48px 20px;text-align:center;cursor:pointer;background:var(--card);transition:.15s}
#drop:hover,#drop.over{border-color:var(--acc);background:var(--rec)}
#drop b{display:block;font-size:17px;margin-bottom:6px}
#drop span{color:var(--fnt);font-size:13px}
input[type=file]{display:none}
.status{margin-top:18px;font-family:var(--mono);font-size:13px;color:var(--mut)}
.card{background:var(--card);border:1px solid var(--bd);border-radius:8px;margin-top:18px;overflow:hidden}
.hd{padding:14px 18px;border-bottom:1px solid var(--bd);display:flex;gap:14px;flex-wrap:wrap;align-items:baseline}
.hd .v{font-family:var(--mono);font-size:15px}
.pill{display:inline-block;font-family:var(--mono);font-size:11px;padding:3px 10px;border-radius:11px}
.pill.ok{background:var(--okw);color:var(--ok)}
.pill.bad{background:var(--dgrw);color:var(--dgr)}
.alert{background:var(--dgrw);border:1px solid var(--dgr);color:var(--dgr);border-radius:4px;padding:9px 14px;margin:12px 18px;font-size:13px;white-space:pre-wrap}
table{width:100%;border-collapse:collapse;font-family:var(--mono);font-size:12px}
th{text-align:left;padding:9px 10px;font-size:10px;letter-spacing:.07em;text-transform:uppercase;color:var(--fnt);background:var(--rec);border-bottom:1px solid var(--bd);white-space:nowrap}
td{padding:7px 10px;border-bottom:1px solid var(--bd);vertical-align:top}
td.n{text-align:right;white-space:nowrap}
tr.flag{background:var(--dgrw)}
.tw{overflow-x:auto}
.big{font-family:var(--mono);font-size:13px;color:var(--acc)}
.note{color:var(--fnt);font-size:11px;display:block;margin-top:3px;white-space:normal}
</style></head><body><div class="wrap">
<h1>MiseAI</h1>
<div class="sub">Drop a Sysco invoice — photo or PDF. It gets read, the math gets checked, and it lands in your database.</div>
<label id="drop">
  <b>Tap to take a photo or choose a file</b>
  <span>You can also drag a file here &middot; JPG, PNG or PDF</span>
  <input type="file" id="file" accept="image/*,application/pdf">
</label>
<div class="status" id="status"></div>
<div id="out"></div>
</div>
<script>
const KEY=${JSON.stringify(ANON_KEY)}, CLIENT=new URLSearchParams(location.search).get('client_id')||${JSON.stringify(DEFAULT_CLIENT)};
const drop=document.getElementById('drop'),file=document.getElementById('file'),status=document.getElementById('status'),out=document.getElementById('out');
const money=v=>v==null?'—':'$'+Number(v).toFixed(2);
const esc=s=>String(s??'').replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
['dragover','dragenter'].forEach(e=>drop.addEventListener(e,ev=>{ev.preventDefault();drop.classList.add('over')}));
['dragleave','drop'].forEach(e=>drop.addEventListener(e,ev=>{ev.preventDefault();drop.classList.remove('over')}));
drop.addEventListener('drop',ev=>{if(ev.dataTransfer.files[0])send(ev.dataTransfer.files[0])});
file.addEventListener('change',()=>{if(file.files[0])send(file.files[0])});

async function send(f){
  out.innerHTML='';
  status.textContent='Reading '+f.name+' ('+(f.size/1024|0)+' KB)… this takes 10–30 seconds.';
  try{
    const r=await fetch('/functions/v1/ingest-invoice?client_id='+encodeURIComponent(CLIENT),{
      method:'POST',headers:{'Authorization':'Bearer '+KEY,'Content-Type':f.type||'application/pdf'},body:f});
    const d=await r.json();
    if(!r.ok){status.textContent='';out.innerHTML='<div class="alert">'+esc(d.error||JSON.stringify(d))+'</div>';return;}
    status.textContent='Done in '+d.elapsed_seconds+'s using '+d.model_used+'.';
    render(d);
  }catch(e){status.textContent='';out.innerHTML='<div class="alert">'+esc(e.message)+'</div>';}
}

function render(d){
  const ok=d.math_is_correct;
  out.innerHTML='<div class="card">'
   +'<div class="hd"><span class="v">'+esc(d.vendor_name||'Unknown vendor')+'</span>'
   +'<span class="v">#'+esc(d.invoice_number||'—')+'</span>'
   +'<span class="v">'+esc(d.invoice_date||'—')+'</span>'
   +'<span class="big">'+money(d.printed.grand_total)+'</span>'
   +'<span class="pill '+(ok?'ok':'bad')+'">'+(ok?'VERIFIED → COMPLETED':d.flagged_lines+' ROW(S) NEED REVIEW')+'</span></div>'
   +(d.problems.length?'<div class="alert">'+esc(d.problems.join('\\n'))+'</div>':'')
   +'<div class="tw"><table><thead><tr><th>Item</th><th class="n">Qty</th><th>Pack</th>'
   +'<th class="n">Unit $</th><th class="n">Line $</th><th class="n">Base units</th><th class="n">Cost / unit</th></tr></thead><tbody>'
   +d.line_items.map(i=>'<tr class="'+(i.is_flagged?'flag':'')+'">'
     +'<td>'+esc(i.item)+(i.is_flagged?'<span class="note">'+esc((i.notes||[]).join(' '))+'</span>':'')+'</td>'
     +'<td class="n">'+(i.qty??'—')+'</td><td>'+esc(i.uom||'—')+(i.catch_weight?' <span class="note">catch wt</span>':'')+'</td>'
     +'<td class="n">'+money(i.unit_price)+'</td><td class="n">'+money(i.line_total)+'</td>'
     +'<td class="n">'+(i.total_base_units??'—')+' '+esc(i.base_unit||'')+'</td>'
     +'<td class="n">'+(i.cost_per_base_unit==null?'—':'$'+Number(i.cost_per_base_unit).toFixed(4))+'</td></tr>').join('')
   +'</tbody><tfoot><tr><td colspan="4"><b>Printed / recomputed</b></td>'
   +'<td class="n">'+money(d.printed.subtotal)+' / '+money(d.recomputed.subtotal_from_lines)+'</td><td colspan="2"></td></tr></tfoot></table></div></div>';
}
</script></body></html>`;

Deno.serve(() => new Response(PAGE, { headers: { 'Content-Type': 'text/html; charset=utf-8' } }));
