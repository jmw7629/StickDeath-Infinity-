#!/usr/bin/env node
// Renders website/assets/merch/templates/*.html (original SVG product mock-ups that
// use the repository's Special Elite font) to 800×800 WebP files in website/assets/merch/.
// Chromium only; no network. `--check` verifies that the rendered files are current.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
if (!process.env.PLAYWRIGHT_BROWSERS_PATH && fs.existsSync('/opt/pw-browsers')) process.env.PLAYWRIGHT_BROWSERS_PATH = '/opt/pw-browsers';
let chromium; for (const c of ['playwright', '/opt/node-tools/node_modules/playwright']) { try { ({ chromium } = require(c)); break; } catch (_) { /* next */ } }
if (!chromium) { console.error('playwright not found'); process.exit(1); }
const here = path.dirname(fileURLToPath(import.meta.url));
const dir = path.resolve(here, '..', '..', 'website', 'assets', 'merch');
const templates = fs.readdirSync(path.join(dir, 'templates')).filter((f) => f.endsWith('.html')).sort();
const checkOnly = process.argv.includes('--check');
const manifestPath = path.join(dir, 'manifest.json');
const previous = fs.existsSync(manifestPath) ? JSON.parse(fs.readFileSync(manifestPath, 'utf8')) : {};
const sha = (b) => crypto.createHash('sha256').update(b).digest('hex');
const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 800, height: 800 }, deviceScaleFactor: 1 });
const manifest = {}; const problems = [];
for (const file of templates) {
  const name = file.replace(/\.html$/, '');
  const source = sha(Buffer.concat([fs.readFileSync(path.join(dir, 'templates', file)), fs.readFileSync(path.join(dir, 'templates', '_base.css'))]));
  const target = path.join(dir, `${name}.webp`);
  if (checkOnly) { if (!fs.existsSync(target) || previous[name]?.source !== source) problems.push(`${name}.webp is missing or stale; run render_merch.mjs`); manifest[name] = previous[name]; continue; }
  await page.goto('file://' + path.join(dir, 'templates', file)); await page.evaluate(() => document.fonts.ready);
  const png = await page.screenshot({ type: 'png' });
  // Chromium cannot write WebP directly from screenshot(); convert in-page through a canvas.
  const dataURL = await page.evaluate(async (bytes) => { const blob = new Blob([new Uint8Array(bytes)], { type: 'image/png' }); const bmp = await createImageBitmap(blob); const c = document.createElement('canvas'); c.width = 800; c.height = 800; c.getContext('2d').drawImage(bmp, 0, 0); return c.toDataURL('image/webp', 0.86); }, [...png]);
  const webp = Buffer.from(dataURL.split(',')[1], 'base64');
  fs.writeFileSync(target, webp); manifest[name] = { source, bytes: webp.length, sha256: sha(webp) };
  console.log(`${name}.webp ${webp.length} bytes`);
}
await browser.close();
if (!checkOnly) fs.writeFileSync(manifestPath, JSON.stringify(manifest, null, 2) + '\n');
if (problems.length) { console.error(problems.join('\n')); process.exit(1); }
console.log(`render_merch: ${checkOnly ? 'OK' : 'rendered'} ${templates.length} products`);
