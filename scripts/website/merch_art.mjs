#!/usr/bin/env node
// Writes website/assets/merch/templates/*.html: original SVG product mock-ups for the
// StickDeath Infinity store, themed on the classic StickDeath series (Super Beast,
// S.W.A.T., Escape from Greenville, Stickzilla, Anti-Auto Theft, Penitentiary, Stick
// Tour, Anger Management, Survivor). Every drawing here is new vector art made from
// primitives in this file; nothing is traced or copied from the original Flash files.
// Run this, then scripts/website/render_merch.mjs to produce the WebP images.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const out = path.resolve(here, '..', '..', 'website', 'assets', 'merch', 'templates');

// ---- palette ---------------------------------------------------------------------------
const C = { ink: '#101011', paper: '#efeae0', bone: '#d9d2c3', red: '#e0202a', blood: '#a3080f', green: '#4fd05a', toxic: '#9bf03c', grey: '#3b3b42', steel: '#6c7280', navy: '#16233d', gold: '#e2b23c', orange: '#ff7a1a', sky: '#2a3350' };

// ---- shared primitives -----------------------------------------------------------------
const defs = `<defs>
<filter id="rough" x="-5%" y="-5%" width="110%" height="110%"><feTurbulence type="fractalNoise" baseFrequency=".9" numOctaves="2" seed="7"/><feDisplacementMap in="SourceGraphic" scale="2.2"/></filter>
<filter id="distress"><feTurbulence type="fractalNoise" baseFrequency="1.6" numOctaves="1" seed="3" result="n"/><feColorMatrix in="n" type="matrix" values="0 0 0 0 0  0 0 0 0 0  0 0 0 0 0  0 0 0 -0.9 1.32" result="m"/><feComposite in="SourceGraphic" in2="m" operator="in"/></filter>
<filter id="glow" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="2.4" result="b"/><feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge></filter>
<filter id="shadow" x="-20%" y="-20%" width="140%" height="140%"><feDropShadow dx="0" dy="10" stdDeviation="9" flood-color="#000" flood-opacity=".55"/></filter>
<linearGradient id="fold" x1="0" x2="1"><stop offset="0" stop-color="#000" stop-opacity=".35"/><stop offset=".18" stop-color="#000" stop-opacity="0"/><stop offset=".82" stop-color="#000" stop-opacity="0"/><stop offset="1" stop-color="#000" stop-opacity=".35"/></linearGradient>
<linearGradient id="sheen" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".10"/><stop offset=".5" stop-color="#fff" stop-opacity="0"/><stop offset="1" stop-color="#000" stop-opacity=".25"/></linearGradient>
<radialGradient id="spot" cx=".5" cy=".42" r=".6"><stop offset="0" stop-color="#2b2b31"/><stop offset="1" stop-color="#0c0c0e"/></radialGradient>
</defs>`;

// Blood splatter: a lumpy blob with droplets and drips; deterministic from a seed.
function splat(cx, cy, r, color = C.red, seed = 1, drips = 3) {
  let s = seed * 9301 + 49297; const rnd = () => ((s = (s * 9301 + 49297) % 233280) / 233280);
  const n = 14; let d = '';
  for (let i = 0; i <= n; i++) { const a = (i / n) * Math.PI * 2; const rr = r * (0.7 + rnd() * 0.55); const x = cx + Math.cos(a) * rr; const y = cy + Math.sin(a) * rr; d += (i ? ' L' : 'M') + x.toFixed(1) + ' ' + y.toFixed(1); }
  let dots = '';
  for (let i = 0; i < 9; i++) { const a = rnd() * Math.PI * 2; const dist = r * (1.25 + rnd() * 0.9); dots += `<circle cx="${(cx + Math.cos(a) * dist).toFixed(1)}" cy="${(cy + Math.sin(a) * dist).toFixed(1)}" r="${(r * (0.05 + rnd() * 0.11)).toFixed(1)}"/>`; }
  let dr = '';
  for (let i = 0; i < drips; i++) { const x = cx - r * 0.6 + rnd() * r * 1.2; const len = r * (0.6 + rnd() * 1.1); const w = r * (0.07 + rnd() * 0.06); dr += `<path d="M${(x - w).toFixed(1)} ${cy} L${(x - w).toFixed(1)} ${(cy + len).toFixed(1)} A${w.toFixed(1)} ${w.toFixed(1)} 0 0 0 ${(x + w).toFixed(1)} ${(cy + len).toFixed(1)} L${(x + w).toFixed(1)} ${cy} Z"/>`; }
  return `<g fill="${color}" filter="url(#rough)"><path d="${d} Z"/>${dots}${dr}</g>`;
}

// Classic victim stick figure; pose: 'stand' | 'run' | 'fall' | 'walk' | 'wave'.
function stickman(x, y, s = 1, pose = 'stand', color = C.paper, w = 5) {
  const P = {
    stand: 'M0 -40v38m0-28-16 14m16-14 16 14m-16 14-12 26m12-26 12 26',
    walk: 'M0 -40v38m0-28-14 18m14-18 12 16m-12 12-16 24m16-24 8 26',
    run: 'M2 -40l-4 36m3-26-20 4m20-4 14-14m-17 26-20 18m20-18 16 22',
    wave: 'M0 -40v38m0-28-16 14m16-14 14-24m-14 38-12 26m12-26 12 26',
    fall: 'M-34 -6l40 4m-30-4-8-20m8 20 2 18m24-14 12-18m-12 18 18 10',
  };
  const head = pose === 'fall' ? '<circle cx="-44" cy="-8" r="10"/>' : '<circle cx="0" cy="-50" r="10"/>';
  return `<g transform="translate(${x} ${y}) scale(${s})" fill="none" stroke="${color}" stroke-width="${w}" stroke-linecap="round" stroke-linejoin="round">${head}<path d="${P[pose]}"/></g>`;
}

// SUPER BEAST: a hulking horned stick brute with claws, spine spikes and burning eyes.
function superBeast(x, y, s = 1, ink = C.ink, eye = C.red) {
  return `<g transform="translate(${x} ${y}) scale(${s})" stroke-linecap="round" stroke-linejoin="round">
<g fill="none" stroke="${ink}" stroke-width="11">
<path d="M-6 -62 C-2 -30 4 -4 0 34"/>
<path d="M-4 -40 C-40 -40 -66 -14 -74 18 M-4 -40 C30 -46 58 -26 70 4"/>
<path d="M0 34 C-14 58 -30 70 -34 100 M0 34 C18 56 34 66 40 100"/>
<path d="M-34 100 l-18 4 M40 100 l20 2"/>
</g>
<g fill="${ink}"><path d="M-74 18 l-14 26 l10 -6 l2 20 l8 -16 l10 14 l-2 -24 l12 4z"/><path d="M70 4 l18 20 l-10 -2 l2 20 l-10 -14 l-8 14 l-2 -22 l-10 6z"/>
<path d="M-6 -50 l-14 -6 l10 -8 l-16 -8 l14 -4z" opacity=".9"/><path d="M-2 -18 l-16 -4 l12 -8 z M0 8 l-15 -2 l11 -8 z"/>
<ellipse cx="-8" cy="-84" rx="25" ry="22"/>
<path d="M-26 -98 C-46 -112 -50 -130 -40 -146 C-38 -128 -30 -116 -16 -106 Z"/><path d="M8 -100 C24 -116 22 -134 10 -148 C14 -128 6 -116 -4 -106 Z"/></g>
<g fill="${eye}" filter="url(#glow)"><path d="M-22 -90 l12 4 l-12 4 z"/><path d="M6 -90 l-12 4 l12 4 z"/></g>
<path d="M-24 -74 l6 6 l6 -6 l6 6 l6 -6 l6 6" fill="none" stroke="${C.paper}" stroke-width="3"/>
</g>`;
}

// Super Beast head alone (pins and stickers): horns, burning eyes and teeth.
function beastHead(x, y, s = 1, ink = C.paper, eye = C.red) {
  return `<g transform="translate(${x} ${y}) scale(${s})"><g fill="${ink}"><ellipse cx="0" cy="6" rx="30" ry="26"/>
<path d="M-20 -10 C-44 -26 -48 -48 -36 -66 C-34 -44 -24 -30 -8 -18 Z"/><path d="M20 -10 C44 -26 48 -48 36 -66 C34 -44 24 -30 8 -18 Z"/></g>
<g fill="${eye}" filter="url(#glow)"><path d="M-18 0 l14 5 l-14 5 z"/><path d="M18 0 l-14 5 l14 5 z"/></g>
<path d="M-16 20 l5 7 l5 -7 l5 7 l5 -7 l5 7 l5 -7" fill="none" stroke="#1a0506" stroke-width="3" stroke-linejoin="round"/></g>`;
}

// S.W.A.T. trooper: helmet, visor, vest, riot shield and a blocky rifle.
function swat(x, y, s = 1, ink = C.ink, accent = C.paper) {
  return `<g transform="translate(${x} ${y}) scale(${s})" stroke-linecap="round" stroke-linejoin="round">
<g fill="none" stroke="${ink}" stroke-width="9"><path d="M0 -44v50m0 0-16 46m16-46 16 46m-16-80 -26 22m26-22 30 8"/></g>
<rect x="-14" y="-40" width="28" height="36" rx="5" fill="${ink}"/><rect x="-10" y="-34" width="8" height="10" fill="${accent}" opacity=".5"/><rect x="2" y="-34" width="8" height="10" fill="${accent}" opacity=".5"/>
<path d="M-18 -60 a18 18 0 0 1 36 0 v6 h-36z" fill="${ink}"/><circle cx="0" cy="-56" r="14" fill="${ink}"/><rect x="-12" y="-60" width="22" height="7" rx="2" fill="${accent}" opacity=".85"/>
<path d="M30 -40 h46 v8 h-28 l-4 10 h-8 l2 -10 h-8z" fill="${ink}"/>
<g transform="translate(-60 -40)"><path d="M0 0 h40 v62 q-20 14 -40 0z" fill="${ink}"/><path d="M5 6 h30 v24 h-30z" fill="${accent}" opacity=".15"/><text x="20" y="48" text-anchor="middle" font-size="11" fill="${accent}" letter-spacing="1">SWAT</text></g>
</g>`;
}

// Green Gene: a cheerful green stick resident of Greenville in a ball cap.
function greenGene(x, y, s = 1) {
  return `<g transform="translate(${x} ${y}) scale(${s})" stroke-linecap="round" stroke-linejoin="round">
<g fill="none" stroke="${C.green}" stroke-width="8"><circle cx="0" cy="-52" r="13"/><path d="M0 -39v38m0-26-18 12m18-12 16-22m-16 48-14 28m14-28 14 28"/></g>
<path d="M-15 -60 a15 15 0 0 1 30 0z" fill="${C.ink}"/><path d="M12 -62 h16 v5 h-16z" fill="${C.ink}"/>
<path d="M-6 -48 q6 6 12 0" fill="none" stroke="${C.green}" stroke-width="3"/><circle cx="-5" cy="-55" r="2" fill="${C.green}"/><circle cx="5" cy="-55" r="2" fill="${C.green}"/></g>`;
}

// Stickzilla: a towering stick lizard with a spiked back and a tail.
function stickzilla(x, y, s = 1, ink = C.ink) {
  return `<g transform="translate(${x} ${y}) scale(${s})" stroke-linecap="round" stroke-linejoin="round">
<g fill="none" stroke="${ink}" stroke-width="12"><path d="M0 -70 C6 -30 4 10 -6 50 C-30 70 -70 70 -100 60"/><path d="M-4 50 -18 100 M-4 50 18 100"/><path d="M2 -40 30 -30 42 -44 M0 -24 26 -6 40 -14"/></g>
<g fill="${ink}"><path d="M-14 -100 C-14 -122 22 -124 30 -104 L44 -96 L28 -88 L30 -80 L4 -78 C-10 -78 -16 -90 -14 -100z"/>
<path d="M-6 -66 l-18 -6 l14 -10z M-4 -36 l-20 -2 l14 -12z M-6 -6 l-20 2 l12 -14z M-10 26 l-20 6 l10 -16z M-40 62 l-10 -20 l18 6z M-70 64 l-12 -18 l18 6z"/></g>
<circle cx="18" cy="-104" r="4" fill="${C.orange}" filter="url(#glow)"/></g>`;
}

const city = (y, color = '#1b1b20', w = 400) => {
  let g = ''; let x = 0; let i = 0; const hs = [70, 110, 52, 140, 90, 120, 60, 100, 80, 130, 66, 104];
  while (x < w) { const bw = 26 + (i % 3) * 10; const h = hs[i % hs.length]; g += `<rect x="${x}" y="${y - h}" width="${bw}" height="${h}" fill="${color}"/>`; for (let r = y - h + 10; r < y - 8; r += 16) for (let c = x + 5; c < x + bw - 6; c += 9) if ((r + c + i) % 3) g += `<rect x="${c}" y="${r}" width="4" height="6" fill="${C.gold}" opacity=".35"/>`; x += bw + 3; i += 1; }
  return g;
};

// Distressed headline text; returns a <text> with the distress filter.
const title = (x, y, txt, size, fill = C.paper, extra = '') => `<text x="${x}" y="${y}" text-anchor="middle" font-size="${size}" fill="${fill}" letter-spacing="${Math.round(size / 10)}" filter="url(#distress)" ${extra}>${txt}</text>`;
const small = (x, y, txt, size = 9, fill = C.bone, ls = 3) => `<text x="${x}" y="${y}" text-anchor="middle" font-size="${size}" fill="${fill}" letter-spacing="${ls}">${txt}</text>`;
const mark = (x, y, s, color = C.red, w = 2.6) => `<g transform="translate(${x} ${y}) scale(${s})" fill="none" stroke="${color}" stroke-width="${w}" stroke-linecap="round" stroke-linejoin="round"><circle cx="0" cy="-28" r="9"/><path d="M0 -17v26m0-18-20 8m20-8 20 8m-20 18-15 20m15-20 15 20"/></g>`;
const dripLogo = (x, y, size = 30, fill = C.red) => `<g>${title(x, y, 'STICKDEATH', size, fill)}${[-0.32, -0.08, 0.2, 0.36].map((f, i) => `<path d="M${x + f * size * 6} ${y + 2} v${8 + i * 5} a3 3 0 0 0 6 0 v-${8 + i * 5}z" fill="${fill}"/>`).join('')}<text x="${x}" y="${y + size * 0.9}" text-anchor="middle" font-size="${size * 0.9}" fill="${fill}">∞</text></g>`;

// ---- product mock-ups (each returns SVG for a 400×400 artboard) -------------------------
const tee = (shirt, art, opts = {}) => `<g filter="url(#shadow)"><path d="M118 68 L166 46 Q200 78 234 46 L282 68 L344 136 L290 166 L290 356 L110 356 L110 166 L56 136 Z" fill="${shirt}"/><path d="M118 68 L166 46 Q200 78 234 46 L282 68 L344 136 L290 166 L290 356 L110 356 L110 166 L56 136 Z" fill="url(#fold)"/><path d="M166 46 Q200 92 234 46" fill="none" stroke="#000" stroke-opacity=".35" stroke-width="4"/>${opts.sleeves ? '' : ''}</g><g transform="translate(0 ${opts.dy || 0})">${art}</g>`;
const hoodie = (cloth, art) => `<g filter="url(#shadow)"><path d="M120 92 Q150 40 200 38 Q250 40 280 92 L346 170 L346 346 L318 352 L304 190 L300 362 L100 362 L96 190 L82 352 L54 346 L54 170 Z" fill="${cloth}"/><path d="M120 92 Q150 40 200 38 Q250 40 280 92 L346 170 L346 346 L318 352 L304 190 L300 362 L100 362 L96 190 L82 352 L54 346 L54 170 Z" fill="url(#fold)"/><path d="M150 80 Q200 130 250 80 Q240 50 200 48 Q160 50 150 80Z" fill="#000" opacity=".35"/><path d="M188 120 v30 M212 120 v30" stroke="#ddd" stroke-width="2"/><path d="M140 290 h120 l14 60 h-148z" fill="#000" opacity=".22"/></g>${art}`;
const poster = (bg, art, frame = '#0a0a0b') => `<g filter="url(#shadow)"><rect x="80" y="20" width="240" height="360" fill="${frame}"/><rect x="88" y="28" width="224" height="344" fill="${bg}"/><svg x="88" y="28" width="224" height="344" viewBox="0 0 224 344">${art}</svg></g>`;
const mug = (body, art) => `<g filter="url(#shadow)"><path d="M290 160 q70 0 70 70 q0 70 -70 70" fill="none" stroke="${body}" stroke-width="24"/><rect x="100" y="110" width="200" height="240" rx="18" fill="${body}"/><ellipse cx="200" cy="112" rx="100" ry="16" fill="#000" opacity=".5"/><rect x="100" y="110" width="200" height="240" rx="18" fill="url(#fold)"/></g><svg x="110" y="140" width="180" height="200" viewBox="0 0 180 200">${art}</svg>`;
const tote = (cloth, art) => `<g filter="url(#shadow)"><path d="M150 120 C150 30 250 30 250 120" fill="none" stroke="${cloth}" stroke-width="14"/><rect x="90" y="110" width="220" height="260" rx="6" fill="${cloth}"/><rect x="90" y="110" width="220" height="260" fill="url(#fold)"/></g><svg x="100" y="130" width="200" height="220" viewBox="0 0 200 220">${art}</svg>`;
const cap = (cloth, art, brim = '#000') => `<g filter="url(#shadow)"><path d="M90 250 C90 130 310 130 310 250 Z" fill="${cloth}"/><path d="M90 250 C40 262 30 300 70 302 C150 306 250 300 330 280 C350 270 330 252 310 250 Z" fill="${brim}"/><path d="M200 132 V250" stroke="#000" stroke-opacity=".3" stroke-width="2"/><circle cx="200" cy="132" r="6" fill="${cloth}" stroke="#000" stroke-opacity=".3"/><path d="M90 250 C90 130 310 130 310 250 Z" fill="url(#sheen)"/></g>${art}`;
const beanie = (cloth, art) => `<g filter="url(#shadow)"><path d="M100 270 C96 120 304 120 300 270 Z" fill="${cloth}"/>${Array.from({ length: 12 }, (_, i) => `<path d="M${112 + i * 16} 260 C${112 + i * 16} 200 ${116 + i * 16} 160 ${120 + i * 16} 140" stroke="#000" stroke-opacity=".18" stroke-width="3" fill="none"/>`).join('')}<rect x="92" y="250" width="216" height="70" rx="10" fill="${cloth}"/>${Array.from({ length: 14 }, (_, i) => `<path d="M${100 + i * 15} 254 v62" stroke="#000" stroke-opacity=".22" stroke-width="3"/>`).join('')}<circle cx="200" cy="118" r="26" fill="${cloth}"/></g>${art}`;
const deck = (art, base = '#121214') => `<g filter="url(#shadow)" transform="rotate(-12 200 200)"><rect x="150" y="10" width="100" height="380" rx="50" fill="${base}"/><svg x="150" y="10" width="100" height="380" viewBox="0 0 100 380"><clipPath id="dk"><rect width="100" height="380" rx="50"/></clipPath><g clip-path="url(#dk)">${art}</g></svg><rect x="150" y="10" width="100" height="380" rx="50" fill="url(#sheen)"/></g>`;
const phone = (art, base = '#121214') => `<g filter="url(#shadow)"><rect x="128" y="30" width="144" height="300" rx="26" fill="${base}"/><svg x="128" y="30" width="144" height="300" viewBox="0 0 144 300"><clipPath id="ph"><rect width="144" height="300" rx="26"/></clipPath><g clip-path="url(#ph)">${art}</g></svg><rect x="140" y="42" width="46" height="64" rx="14" fill="#050505"/><circle cx="154" cy="58" r="8" fill="#1d2230"/><circle cx="172" cy="58" r="8" fill="#1d2230"/><circle cx="154" cy="82" r="8" fill="#1d2230"/></g>`;

const write = (name, tag, label, svg, bg = 'url(#spot)') => {
  const html = `<!doctype html><html><head><meta charset="utf-8"><link rel="stylesheet" href="_base.css"></head><body><div class="grid"></div><span class="tag">${tag}</span>
<div class="card"><svg viewBox="0 0 400 400">${defs}<rect width="400" height="400" fill="${bg}" opacity=".85"/>${svg}</svg></div>
<span class="label">${label}</span></body></html>\n`;
  fs.writeFileSync(path.join(out, `${name}.html`), html);
};

// ---- the line-up ------------------------------------------------------------------------
export const PRODUCTS = [];
const add = (name, tag, label, alt, svg) => { write(name, tag, label, svg); PRODUCTS.push({ name, tag, label, alt }); };

add('super-beast-tee', 'Super Beast', 'Black tee · front print',
  'Black t-shirt with a horned, clawed Super Beast stick brute with glowing red eyes over a blood splatter, and the words SUPER BEAST, NEVER DIES',
  tee('#121214', `${splat(200, 196, 60, C.blood, 4, 4)}${superBeast(200, 214, 0.62, C.paper, C.red)}${title(200, 300, 'SUPER BEAST', 26, C.paper)}${small(200, 320, 'THE ONLY ONE WHO NEVER DIES', 8, C.red)}`));

add('walk-in-the-park-poster', 'Walk in the Park', '18 × 24 poster',
  'Poster: a stick figure strolls past a park bench at night while Super Beast lurks behind a tree, titled A WALK IN THE PARK, Parts I to V',
  poster('#1a2418', `<rect width="224" height="344" fill="#0f1712"/><circle cx="170" cy="60" r="26" fill="${C.bone}" opacity=".9"/><path d="M0 260 Q112 236 224 262 V344 H0z" fill="#0b120d"/>
<path d="M40 262 V150" stroke="#000" stroke-width="12"/><circle cx="40" cy="128" r="40" fill="#07100a"/><circle cx="18" cy="150" r="28" fill="#07100a"/><circle cx="64" cy="148" r="26" fill="#07100a"/>
<g transform="translate(130 250)"><rect x="-30" y="-14" width="60" height="5" fill="#2a2a2a"/><rect x="-30" y="-4" width="60" height="4" fill="#2a2a2a"/><path d="M-26 0 v14 M26 0 v14" stroke="#2a2a2a" stroke-width="4"/></g>
${superBeast(62, 228, 0.42, '#000', C.red)}${stickman(160, 262, 0.62, 'walk', C.paper, 5)}
${title(112, 300, 'A WALK IN', 22, C.paper)}${title(112, 324, 'THE PARK', 24, C.red)}${small(112, 338, 'PARTS I – V · STICKDEATH ∞', 7)}`));

add('summoning-the-beast-hoodie', 'Summoning the Beast', 'Heavyweight hoodie · back print',
  'Charcoal hoodie printed with a ring of candles and runes around Super Beast rising from the floor, titled SUMMONING THE BEAST',
  hoodie('#1f1f24', `<circle cx="200" cy="226" r="62" fill="none" stroke="${C.red}" stroke-width="3" filter="url(#glow)"/><circle cx="200" cy="226" r="52" fill="none" stroke="${C.red}" stroke-width="1.5" stroke-dasharray="4 6"/>
${[0, 60, 120, 180, 240, 300].map((a) => { const r = (a * Math.PI) / 180; const x = 200 + Math.cos(r) * 62; const y = 226 + Math.sin(r) * 62; return `<rect x="${x - 3}" y="${y - 10}" width="6" height="12" fill="${C.bone}"/><path d="M${x} ${y - 10} q-4 -6 0 -12 q4 6 0 12z" fill="${C.orange}" filter="url(#glow)"/>`; }).join('')}
${superBeast(200, 250, 0.5, '#000', C.red)}${title(200, 320, 'SUMMONING', 22, C.paper)}${title(200, 342, 'THE BEAST', 22, C.red)}`));

add('body-count-tee', 'Body Count', 'Bone tee · front print',
  'Bone-coloured t-shirt with a tally of stick-mark body counts crossed out in red and the words BODY COUNT, SUPER BEAST CHECK',
  tee(C.bone, `${Array.from({ length: 4 }, (_, row) => Array.from({ length: 4 }, (_, i) => `<path d="M${142 + i * 30} ${150 + row * 34} v26 m6 -26 v26 m6 -26 v26 m6 -26 v26" stroke="${C.ink}" stroke-width="3.4" stroke-linecap="round"/><path d="M${138 + i * 30} ${170 + row * 34} l30 -18" stroke="${C.red}" stroke-width="3.4" stroke-linecap="round"/>`).join('')).join('')}${title(200, 300, 'BODY COUNT', 28, C.ink)}${small(200, 320, 'SUPER BEAST CHECK · STILL COUNTING', 8, C.blood)}`));

add('swat-tee', 'S.W.A.T.', 'Navy tee · front print',
  'Navy t-shirt with a S.W.A.T. stick trooper in helmet and vest behind a riot shield, a stencil S.W.A.T. title and the line HOSTAGE? WHAT HOSTAGE',
  tee(C.navy, `<rect x="140" y="132" width="120" height="120" fill="none" stroke="${C.paper}" stroke-width="2" stroke-dasharray="6 5" opacity=".6"/>${swat(206, 228, 0.92, C.paper, C.navy)}${title(200, 296, 'S.W.A.T.', 34, C.paper)}${small(200, 318, 'HOSTAGE? WHAT HOSTAGE.', 8, C.gold)}`));

add('swat-cap', 'S.W.A.T.', 'Black cap · embroidered patch',
  'Black cap with an embroidered S.W.A.T. shield patch and a small red stick mark on the side',
  cap('#141416', `<g filter="url(#rough)"><path d="M166 176 h68 v44 q-34 26 -68 0z" fill="${C.navy}" stroke="${C.gold}" stroke-width="3"/>${small(200, 202, 'S.W.A.T.', 13, C.gold, 2)}${small(200, 216, 'STICKDEATH', 6, C.paper, 2)}</g>${mark(270, 238, 0.6, C.red, 3)}`));

add('swat-patch', 'S.W.A.T.', 'Hook-and-loop morale patch',
  'Olive morale patch with a stitched border, a crossed rifle and riot shield, and the text STICKDEATH S.W.A.T. NO HOSTAGES WERE HARMED (MUCH)',
  `<g filter="url(#shadow)"><rect x="70" y="110" width="260" height="180" rx="24" fill="#3c4426"/><rect x="80" y="120" width="240" height="160" rx="18" fill="none" stroke="#c8c19a" stroke-width="3" stroke-dasharray="5 4"/></g>
<g transform="rotate(-24 200 200)"><rect x="120" y="194" width="160" height="12" rx="3" fill="#20240f"/><rect x="250" y="186" width="30" height="8" fill="#20240f"/></g><path d="M176 160 h48 v60 q-24 18 -48 0z" fill="#20240f" stroke="#c8c19a" stroke-width="2"/>${small(200, 196, 'SWAT', 10, '#c8c19a', 1)}
${title(200, 252, 'STICKDEATH S.W.A.T.', 18, '#e8e0b8')}${small(200, 270, 'NO HOSTAGES WERE HARMED (MUCH)', 7, '#c8c19a', 2)}`);

add('escape-from-greenville-tee', 'Escape from Greenville', 'Heather tee · front print',
  'Heather grey t-shirt with a bullet-holed green road sign reading WELCOME TO GREENVILLE, POPULATION DROPPING, and Green Gene waving beside it',
  tee('#5a5d63', `<g filter="url(#rough)"><rect x="132" y="150" width="136" height="80" rx="8" fill="#1f7a34" stroke="${C.paper}" stroke-width="3"/><rect x="190" y="230" width="8" height="60" fill="${C.steel}"/></g>${small(200, 176, 'WELCOME TO', 9, C.paper, 3)}${title(200, 200, 'GREENVILLE', 21, C.paper)}${small(200, 218, 'POP. DROPPING', 8, C.paper, 3)}${[[150, 168], [246, 206], [222, 166]].map(([x, y]) => `<circle cx="${x}" cy="${y}" r="3.4" fill="#0b0b0b"/>`).join('')}${greenGene(260, 300, 0.7)}${title(200, 322, 'ESCAPE FROM GREENVILLE', 14, C.toxic)}`));

add('greenville-mug', 'Escape from Greenville', '11 oz mug',
  'White mug printed with the Greenville town sign, a getaway car with smoke and the line I ESCAPED FROM GREENVILLE',
  mug(C.paper, `<g filter="url(#rough)"><rect x="40" y="20" width="100" height="56" rx="6" fill="#1f7a34"/></g>${small(90, 40, 'WELCOME TO', 7, C.paper, 2)}${small(90, 58, 'GREENVILLE', 13, C.paper, 2)}${small(90, 70, 'POP. 3 … 2 …', 6, C.paper, 2)}
<g transform="translate(90 130)"><path d="M-50 0 h100 l-10 -20 h-56z" fill="${C.ink}"/><rect x="-50" y="0" width="100" height="16" rx="4" fill="${C.ink}"/><circle cx="-28" cy="18" r="9" fill="#333"/><circle cx="28" cy="18" r="9" fill="#333"/><circle cx="-70" cy="6" r="10" fill="#bbb" opacity=".6"/><circle cx="-86" cy="0" r="7" fill="#bbb" opacity=".4"/></g>
${title(90, 186, 'I ESCAPED', 16, C.ink)}`));

add('green-gene-pin', 'Green Gene', 'Hard enamel pin · 1.5 in',
  'Hard enamel pin of Green Gene, a green stick figure in a black ball cap, on a gold-edged round badge reading GREEN GENE, GREENVILLE',
  `<g filter="url(#shadow)"><circle cx="200" cy="200" r="120" fill="${C.gold}"/><circle cx="200" cy="200" r="108" fill="#123018"/><circle cx="200" cy="200" r="108" fill="url(#sheen)"/></g>${greenGene(200, 252, 1.7)}<path d="M120 268 a80 80 0 0 0 160 0" fill="none"/>${small(200, 300, 'GREEN GENE', 14, C.gold, 3)}${small(200, 116, 'GREENVILLE', 10, C.gold, 4)}`);

add('anti-auto-theft-tee', 'Anti-Auto Theft', 'Black tee · front print',
  'Black t-shirt with a car fitted with roof spikes and side blades, a car thief stick figure flying off it, and the words ANTI-AUTO THEFT DEVICE, 2005 MODEL',
  tee('#121214', `<g transform="translate(200 220)"><path d="M-80 0 h160 l-16 -34 h-112z" fill="${C.paper}"/><rect x="-80" y="0" width="160" height="24" rx="6" fill="${C.paper}"/><path d="M-50 -30 h36 v24 h-48z M-6 -30 h40 l12 24 h-52z" fill="#121214"/>${[-60, -40, -20, 0, 20, 40].map((x) => `<path d="M${x} -34 l6 -20 l6 20z" fill="${C.steel}"/>`).join('')}<path d="M80 10 l36 -6 l-36 14z M-80 10 l-36 -6 l36 14z" fill="${C.steel}"/><circle cx="-46" cy="26" r="13" fill="#2b2b2f" stroke="${C.paper}" stroke-width="3"/><circle cx="46" cy="26" r="13" fill="#2b2b2f" stroke="${C.paper}" stroke-width="3"/></g>${stickman(286, 162, 0.55, 'fall', C.paper, 5)}${splat(256, 176, 14, C.red, 9, 2)}${title(200, 290, 'ANTI-AUTO THEFT', 22, C.red)}${small(200, 310, 'DEVICE · 2005 MODEL · NOW WITH BLADES', 7)}`));

add('stickzilla-poster', 'Stickzilla', '18 × 24 poster',
  'Poster: a giant spiked stick lizard named Stickzilla towers over a night city skyline with tiny stick figures running, in orange and black',
  poster('#130b06', `<rect width="224" height="344" fill="#1b0d05"/><circle cx="112" cy="120" r="90" fill="${C.orange}" opacity=".25"/>${stickzilla(120, 230, 1.15, '#000')}<g>${city(300, '#0b0605', 224)}</g><rect y="300" width="224" height="44" fill="#070403"/>${stickman(40, 330, 0.32, 'run', C.paper, 5)}${stickman(70, 332, 0.3, 'run', C.paper, 5)}${stickman(180, 330, 0.32, 'run', C.paper, 5)}${title(112, 40, 'STICKZILLA', 30, C.orange)}${small(112, 56, 'KING OF THE STICKS', 7, C.bone)}`));

add('penitentiary-tee', 'StickDeath Penitentiary', 'Striped tee · front print',
  'Black and white striped t-shirt with a mugshot board reading STICKDEATH PENITENTIARY, INMATE 0001, held by a scowling stick figure',
  tee('#141416', `<clipPath id="tc"><path d="M118 68 L166 46 Q200 78 234 46 L282 68 L344 136 L290 166 L290 356 L110 356 L110 166 L56 136 Z"/></clipPath><g clip-path="url(#tc)">${Array.from({ length: 14 }, (_, i) => `<rect x="40" y="${50 + i * 24}" width="320" height="12" fill="${C.paper}" opacity=".9"/>`).join('')}</g><rect x="142" y="140" width="116" height="110" fill="#141416"/>${stickman(200, 214, 0.9, 'stand', C.paper, 5)}<path d="M186 160 l8 4 M214 160 l-8 4" stroke="${C.paper}" stroke-width="3"/><rect x="150" y="214" width="100" height="32" fill="${C.ink}" stroke="${C.paper}" stroke-width="2"/>${small(200, 228, 'STICKDEATH PEN.', 8, C.paper, 2)}${small(200, 241, 'INMATE 0001', 8, C.red, 2)}`, { dy: 0 }));

add('stick-tour-tote', 'Stick Tour', 'Canvas tote',
  'Natural canvas tote with a wooden stick man road-tripping across a hand-drawn United States map with seven numbered stops, titled STICK TOUR',
  tote('#e7dcc3', `<path d="M14 70 C30 40 70 34 100 40 C130 30 170 40 186 70 C196 100 180 130 160 150 C140 170 110 168 90 160 C60 168 30 150 20 120 C10 100 8 86 14 70Z" fill="none" stroke="${C.ink}" stroke-width="2.4" filter="url(#rough)"/>
<path d="M30 110 C60 70 90 120 120 80 C140 60 160 110 176 96" fill="none" stroke="${C.red}" stroke-width="2.4" stroke-dasharray="5 4"/>${[[30, 110], [55, 88], [80, 108], [104, 96], [126, 76], [150, 98], [176, 96]].map(([x, y], i) => `<circle cx="${x}" cy="${y}" r="7" fill="${C.red}"/><text x="${x}" y="${y + 3}" text-anchor="middle" font-size="8" fill="${C.paper}">${i + 1}</text>`).join('')}
${stickman(100, 196, 0.62, 'wave', '#8a5a2b', 6)}${title(100, 30, 'STICK TOUR', 22, C.ink)}${small(100, 214, 'COAST TO COAST · ONE STICK', 6, C.ink, 2)}`));

add('anger-management-mug', 'Anger Management', '11 oz mug',
  'Black mug with a calm smiling stick figure on one side and the same figure smashing a desk on the other, captioned ANGER MANAGEMENT, I AM CALM',
  mug('#141416', `${stickman(48, 112, 0.7, 'stand', C.paper, 5)}<path d="M42 72 q6 5 12 0" stroke="${C.paper}" stroke-width="2" fill="none"/>${small(48, 136, 'BEFORE', 7)}<path d="M84 40 v100" stroke="${C.red}" stroke-width="2" stroke-dasharray="4 4"/>
<g transform="translate(134 112)"><rect x="-30" y="0" width="60" height="6" fill="${C.steel}" transform="rotate(14)"/><path d="M-8 -6 l-14 -20 M10 -8 l18 -16" stroke="${C.steel}" stroke-width="3"/></g>${stickman(134, 104, 0.7, 'wave', C.paper, 5)}<path d="M126 66 l6 4 l6 -4" stroke="${C.red}" stroke-width="2.4" fill="none"/>${small(134, 136, 'AFTER', 7, C.red)}
${title(90, 170, 'ANGER MANAGEMENT', 13, C.red)}${small(90, 186, 'I AM CALM. I AM CALM. I AM CALM.', 6)}`));

add('survivor-beanie', 'Survivor', 'Knit beanie · woven label',
  'Black knit beanie with a woven red label reading SURVIVOR, DAY 7, and a small stick mark',
  beanie('#1a1a1d', `<rect x="152" y="262" width="96" height="44" rx="4" fill="${C.red}"/>${small(200, 282, 'SURVIVOR', 13, C.paper, 2)}${small(200, 297, 'DAY 7 · STILL HERE', 6, C.paper, 2)}`));

add('super-beast-deck', 'Super Beast', 'Skateboard deck · 8.25 in',
  'Skateboard deck printed with Super Beast climbing up out of a pool of blood, claws first, under a dripping STICKDEATH logo',
  deck(`<rect width="100" height="380" fill="#121214"/><rect y="250" width="100" height="130" fill="${C.blood}"/>${splat(50, 252, 40, C.blood, 11, 5)}${superBeast(50, 220, 0.42, C.paper, C.red)}<g transform="rotate(90 50 90)">${title(50, 98, 'SUPER BEAST', 22, C.red)}</g>${small(50, 360, 'STICKDEATH ∞', 7, C.paper, 2)}`));

add('swat-phone-case', 'S.W.A.T.', 'Phone case',
  'Black phone case styled as a riot shield with a viewport window and S.W.A.T. stencil lettering, with a small stick mark',
  phone(`<rect width="144" height="300" fill="#121418"/><rect x="18" y="108" width="108" height="56" rx="6" fill="#2c3646" opacity=".8"/><rect x="18" y="108" width="108" height="56" rx="6" fill="url(#sheen)"/>${title(72, 214, 'S.W.A.T.', 28, C.paper)}${small(72, 236, 'STICKDEATH TACTICAL', 7, C.gold, 2)}${mark(72, 290, 0.5, C.red, 3)}`));

add('stickdeath-drip-hoodie', 'StickDeath ∞', 'Black hoodie · front print',
  'Black hoodie with a dripping red STICKDEATH logo over an infinity symbol and a stick figure mid-fall',
  hoodie('#121214', `${stickman(200, 214, 0.7, 'fall', C.paper, 5)}${splat(172, 214, 18, C.red, 21, 2)}${dripLogo(200, 266, 30, C.red)}`));

add('classic-splatter-tee', 'StickDeath ∞', 'White tee · front print',
  'White t-shirt with a large red blood splatter behind the black stick mark and the STICKDEATH INFINITY wordmark',
  tee(C.paper, `${splat(200, 196, 64, C.red, 31, 5)}${mark(200, 214, 2.2, C.paper, 4)}${title(200, 300, 'STICKDEATH ∞', 19, C.ink, 'font-weight="700"')}${small(200, 320, 'REBORN IN SWIFT', 7, C.blood)}`));

add('character-sticker-sheet', 'Sticker sheet', 'Die-cut vinyl · 6 stickers',
  'Sheet of six die-cut stickers: Super Beast head, S.W.A.T. shield, Green Gene, Stickzilla, a blood splat with the stick mark, and a GREENVILLE road sign',
  `<g filter="url(#shadow)"><rect x="40" y="40" width="320" height="320" rx="12" fill="#efe9dc"/></g>
<g transform="translate(110 130)"><circle r="56" fill="#fff" stroke="#ddd"/>${beastHead(0, 6, 1.05, C.ink, C.red)}</g>
<g transform="translate(290 130)"><circle r="56" fill="#fff" stroke="#ddd"/><path d="M-30 -36 h60 v60 q-30 22 -60 0z" fill="${C.navy}"/>${small(0, 6, 'S.W.A.T.', 12, C.gold, 1)}</g>
<g transform="translate(110 280)"><circle r="56" fill="#fff" stroke="#ddd"/>${greenGene(0, 36, 0.8)}</g>
<g transform="translate(200 210)"><circle r="40" fill="#fff" stroke="#ddd"/>${splat(0, 0, 24, C.red, 41, 2)}${mark(0, 10, 0.9, C.ink, 3)}</g>
<g transform="translate(290 280)"><circle r="56" fill="#fff" stroke="#ddd"/>${stickzilla(10, 40, 0.42, C.ink)}</g>
<g transform="translate(200 330)"><rect x="-46" y="-16" width="92" height="30" rx="4" fill="#1f7a34" stroke="#fff" stroke-width="3"/>${small(0, 4, 'GREENVILLE', 10, C.paper, 2)}</g>`);

add('series-enamel-pins', 'Pin set', 'Hard enamel · set of 4',
  'Set of four hard enamel pins on a backing card: Super Beast head, S.W.A.T. shield, a red splat with the stick mark, and the infinity symbol',
  `<g filter="url(#shadow)"><rect x="70" y="40" width="260" height="320" rx="10" fill="#1a1a1d"/></g>${small(200, 74, 'STICKDEATH ∞ · SERIES ONE', 9, C.bone, 3)}
<g transform="translate(140 150)"><circle r="44" fill="${C.gold}"/><circle r="38" fill="#2a0a0c"/>${beastHead(0, 6, 0.78, C.paper, C.red)}</g>
<g transform="translate(260 150)"><path d="M-36 -40 h72 v66 q-36 26 -72 0z" fill="${C.gold}"/><path d="M-30 -34 h60 v56 q-30 22 -60 0z" fill="${C.navy}"/>${small(0, 4, 'S.W.A.T.', 12, C.gold, 1)}</g>
<g transform="translate(140 280)"><circle r="44" fill="${C.gold}"/><circle r="38" fill="${C.paper}"/>${splat(0, 0, 22, C.red, 51, 2)}${mark(0, 10, 0.8, C.ink, 3)}</g>
<g transform="translate(260 280)"><rect x="-44" y="-30" width="88" height="60" rx="30" fill="${C.gold}"/><rect x="-38" y="-24" width="76" height="48" rx="24" fill="${C.red}"/><text x="0" y="14" text-anchor="middle" font-size="40" fill="${C.paper}">∞</text></g>`);

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  fs.mkdirSync(out, { recursive: true });
  for (const f of fs.readdirSync(out)) if (f.endsWith('.html') && !PRODUCTS.some((p) => `${p.name}.html` === f)) fs.rmSync(path.join(out, f));
  fs.writeFileSync(path.join(out, 'products.json'), JSON.stringify(PRODUCTS, null, 2) + '\n');
  console.log(`merch_art: wrote ${PRODUCTS.length} templates`);
}
