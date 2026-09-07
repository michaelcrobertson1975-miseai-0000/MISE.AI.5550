// @ts-nocheck
/**
 * PREP PROBE - throwaway. Does a WASM image library boot and run in THIS
 * project's edge runtime, and what does one invoice page cost?
 *
 * Supabase's documented snippet reads 'magick.wasm' next to the module. In
 * 0.0.43 the binary is at dist/x64/magick.wasm - which is why the documented
 * path 404s and the CDN fetch returned an HTML error page that the initializer
 * then choked on. Correct paths first, CDN as the fallback.
 *
 * GET returns 200 whatever happens, so a failure is readable.
 */
import { ImageMagick, initializeImageMagick, MagickFormat, Magick } from 'npm:@imagemagick/magick-wasm@0.0.43';

const json = (b, s = 200) =>
  new Response(JSON.stringify(b, null, 2), { status: s, headers: { 'Content-Type': 'application/json' } });

const attempts = [];
let ready = false;
let bootMs = null;

async function boot() {
  const t0 = Date.now();
  const base = import.meta.resolve('npm:@imagemagick/magick-wasm@0.0.43');

  for (const rel of ['x64/magick.wasm', 'magick.wasm', 'x86/magick.wasm']) {
    try {
      const url = new URL(rel, base);
      attempts.push({ strategy: `Deno.readFile ${rel}`, from: String(url) });
      const bytes = await Deno.readFile(url);
      await initializeImageMagick(bytes);
      attempts[attempts.length - 1].result = `ok, ${(bytes.length / 1048576).toFixed(1)} MB`;
      bootMs = Date.now() - t0;
      return true;
    } catch (err) {
      attempts[attempts.length - 1].result = `${err?.name}: ${String(err?.message).slice(0, 140)}`;
    }
  }

  for (const href of [
    'https://cdn.jsdelivr.net/npm/@imagemagick/magick-wasm@0.0.43/dist/x64/magick.wasm',
    'https://cdn.jsdelivr.net/npm/@imagemagick/magick-wasm@0.0.43/dist/x86/magick.wasm',
  ]) {
    try {
      attempts.push({ strategy: `fetch ${href.split('/').slice(-2).join('/')}` });
      const res = await fetch(href);
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const type = res.headers.get('content-type') ?? '';
      const bytes = new Uint8Array(await res.arrayBuffer());
      // A CDN error page is HTML, not wasm; wasm starts with \0asm.
      if (!(bytes[0] === 0x00 && bytes[1] === 0x61 && bytes[2] === 0x73 && bytes[3] === 0x6d)) {
        throw new Error(`not a wasm binary (content-type ${type}, first bytes ${bytes.slice(0, 4)})`);
      }
      await initializeImageMagick(bytes);
      attempts[attempts.length - 1].result = `ok, ${(bytes.length / 1048576).toFixed(1)} MB`;
      bootMs = Date.now() - t0;
      return true;
    } catch (err) {
      attempts[attempts.length - 1].result = `${err?.name}: ${String(err?.message).slice(0, 140)}`;
    }
  }

  bootMs = Date.now() - t0;
  return false;
}

try { ready = await boot(); } catch (err) { attempts.push({ strategy: 'boot()', result: `${err?.name}: ${err?.message}` }); }

Deno.serve(async (req) => {
  if (req.method === 'GET') {
    let version = null;
    if (ready) { try { version = String(Magick.imageMagickVersion); } catch (e) { version = `unavailable: ${e.message}`; } }
    return json({
      wasm_ready: ready,
      boot_ms: bootMs,
      magick_version: version,
      attempts,
      verdict: ready
        ? 'Image prep runs here. POST an invoice photo to measure a real page.'
        : 'Image prep does NOT run here - see attempts.',
    });
  }

  if (req.method !== 'POST') return json({ error: 'GET to check boot, POST bytes to process.' }, 405);
  if (!ready) return json({ error: 'wasm never initialized', attempts }, 503);

  const input = new Uint8Array(await req.arrayBuffer());
  if (input.length === 0) return json({ error: 'Empty body.' }, 400);

  const started = Date.now();
  const report = { input_bytes: input.length };

  try {
    const out = ImageMagick.read(input, (img) => {
      report.detected_format = String(img.format);
      report.input_width = img.width;
      report.input_height = img.height;
      const steps = [];

      try { img.autoOrient(); steps.push('autoOrient'); } catch (e) { steps.push(`autoOrient FAILED: ${e.message}`); }

      // Gemini downscales past ~3072px anyway; more than this is upload time and
      // tokens for no extra detail.
      const longest = Math.max(img.width, img.height);
      if (longest > 2048) {
        const scale = 2048 / longest;
        try {
          img.resize(Math.round(img.width * scale), Math.round(img.height * scale));
          steps.push(`resize ${longest} -> 2048`);
        } catch (e) { steps.push(`resize FAILED: ${e.message}`); }
      } else steps.push('resize skipped (already under 2048)');

      // Stretch the histogram so faint thermal print and shadowed paper both
      // land in a readable range.
      try { img.normalize(); steps.push('normalize'); } catch (e) { steps.push(`normalize FAILED: ${e.message}`); }
      try { img.sharpen(0, 1); steps.push('sharpen'); } catch (e) { steps.push(`sharpen FAILED: ${e.message}`); }

      report.steps = steps;
      report.output_width = img.width;
      report.output_height = img.height;
      img.quality = 88;
      return img.write(MagickFormat.Jpeg, (data) => new Uint8Array(data));
    });

    report.output_bytes = out.length;
    report.size_change = `${((out.length / input.length - 1) * 100).toFixed(0)}%`;
    report.process_ms = Date.now() - started;
    report.verdict = 'processed';
    return json(report);
  } catch (err) {
    report.process_ms = Date.now() - started;
    report.verdict = 'FAILED';
    report.error = `${err?.name}: ${err?.message}`;
    return json(report, 500);
  }
});
