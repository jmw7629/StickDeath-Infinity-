#!/usr/bin/env node
// Writes docs/shopify-products.csv: a Shopify product-import file for the merch line-up in
// website/assets/merch/templates/products.json. Products import as DRAFTS with no price:
// the owner sets prices in Shopify (nothing here invents one). Images are fetched by Shopify
// from jsDelivr's mirror of this public repository, pinned to a commit so the URL never moves.
//   node scripts/website/shopify_csv.mjs [commit-sha]
import fs from 'node:fs';
import path from 'node:path';
import { execSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const products = JSON.parse(fs.readFileSync(path.join(root, 'website/assets/merch/templates/products.json'), 'utf8'));
const commit = process.argv[2] || execSync('git log -1 --format=%H -- website/assets/merch', { cwd: root }).toString().trim();
const imageURL = (name) => `https://cdn.jsdelivr.net/gh/jmw7629/StickDeath-Infinity-@${commit}/website/assets/merch/${name}.webp`;
const APPAREL = ['S', 'M', 'L', 'XL', '2XL', '3XL'];
const kind = (name) => (/tee$/.test(name) ? ['T-Shirt', APPAREL] : /hoodie$/.test(name) ? ['Hoodie', APPAREL] : /cap$/.test(name) ? ['Hat', null] : /beanie$/.test(name) ? ['Beanie', null] : /poster$/.test(name) ? ['Poster', null] : /mug$/.test(name) ? ['Mug', null] : /tote$/.test(name) ? ['Tote Bag', null] : /pins?$/.test(name) ? ['Enamel Pin', null] : /patch$/.test(name) ? ['Patch', null] : /deck$/.test(name) ? ['Skateboard Deck', null] : /case$/.test(name) ? ['Phone Case', null] : /sheet$/.test(name) ? ['Stickers', null] : ['Merch', null]);
const titleCase = (s) => s.replace(/-/g, ' ').replace(/\b\w/g, (c) => c.toUpperCase()).replace(/\bSwat\b/g, 'S.W.A.T.');
const header = ['Handle', 'Title', 'Body (HTML)', 'Vendor', 'Type', 'Tags', 'Published', 'Option1 Name', 'Option1 Value', 'Variant Inventory Policy', 'Variant Fulfillment Service', 'Variant Price', 'Variant Requires Shipping', 'Variant Taxable', 'Image Src', 'Image Position', 'Image Alt Text', 'Status'];
const cell = (v) => (/[",\n]/.test(String(v)) ? `"${String(v).replace(/"/g, '""')}"` : String(v));
const rows = [header];
for (const p of products) {
  const [type, sizes] = kind(p.name);
  const series = p.tag.replace(/[^A-Za-z0-9 ]/g, '').trim();
  const tags = ['sdi-merch', series, type].join(', ');
  const body = `<p>${p.label}. Original StickDeath Infinity artwork from the ${p.tag} series.</p>`;
  const variants = sizes || ['Default Title'];
  variants.forEach((v, i) => {
    rows.push([p.name, i ? '' : titleCase(p.name), i ? '' : body, i ? '' : 'StickDeath Infinity', i ? '' : type, i ? '' : tags, i ? '' : 'FALSE', i ? '' : (sizes ? 'Size' : 'Title'), v, 'deny', 'manual', '', 'TRUE', 'TRUE', i ? '' : imageURL(p.name), i ? '' : 1, i ? '' : p.alt, i ? '' : 'draft']);
  });
}
const out = path.join(root, 'docs', 'shopify-products.csv');
fs.writeFileSync(out, rows.map((r) => r.map(cell).join(',')).join('\n') + '\n');
console.log(`shopify_csv: ${products.length} products, ${rows.length - 1} rows → docs/shopify-products.csv (images @ ${commit.slice(0, 7)})`);
