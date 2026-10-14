#!/usr/bin/env node
// Accessibility, behaviour and performance harness for website/ (Chromium only).
//
//   PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers node scripts/website/a11y_perf.mjs [--json report.json]
//
// Serves website/ from a tiny in-process HTTP server (no dependencies) and runs:
//   * every page × viewports 320×640 / 390×844 / 1440×900: console.error/pageerror = fail,
//     any non-same-origin request = fail, no horizontal overflow, ≥44×44 interactive targets
//     (inline links inside running text exempt, as in WCAG 2.5.8), exactly one h1 and no skipped
//     heading levels, main/nav/header landmarks, img alt, labelled form controls, visible focus
//     outline on the first Tab stop, text contrast ≥4.5:1 (≥3:1 for large text)
//   * index.html: skip link → #main, menu aria-expanded + Escape (compact viewports ≤700px),
//   * play.html: pointer drawing changes the canvas, Add frame + Duplicate + Play/Stop, GIF and PNG downloads fire download events,
//     help search "lasso" (expected count computed from help/articles.json), filter aria-pressed,
//     every #help/<id> fragment opens and focuses its topic, support form validation → Review →
//     Download event → clipboard → Reset
//   * reducedMotion: 'reduce' → scroll-behavior auto; javaScriptEnabled: false → noscript shown
//   * perf via CDP at 390×844: Slow-4G (150 ms RTT, ~1.6 Mbps down) and 4× CPU throttle;
//     LCP, CLS, request count and transfer bytes against budgets: total ≤420 KB, requests ≤12,
//     LCP ≤2.5 s, CLS ≤0.05
// Exit code 1 on any failure. Numbers printed are measured in this run, nothing is estimated.

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

// Default to the pre-installed browser bundle only where it exists (local review
// container); elsewhere Playwright uses its own cache (CI runs `playwright install`).
import { existsSync } from 'node:fs';
if (!process.env.PLAYWRIGHT_BROWSERS_PATH && existsSync('/opt/pw-browsers')) process.env.PLAYWRIGHT_BROWSERS_PATH = '/opt/pw-browsers';
const require = createRequire(import.meta.url);
function loadPlaywright() {
  for (const candidate of ['playwright', '/opt/node-tools/node_modules/playwright']) {
    try { return require(candidate); } catch (_) { /* try next */ }
  }
  throw new Error('playwright is not installed (expected /opt/node-tools/node_modules/playwright)');
}
const { chromium } = loadPlaywright();

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '..', '..');
const site = path.join(repo, 'website');
const jsonIndex = process.argv.indexOf('--json');
const jsonOut = jsonIndex > -1 ? process.argv[jsonIndex + 1] : null;

const PAGES = ['index.html', 'studio.html', 'community.html', 'screens.html', 'play.html', 'store.html', 'brand.html', '404.html', 'account.html', 'admin.html', 'policies/terms-v1.html', 'policies/privacy-v1.html', 'policies/publishing-v1.html', 'policies/attribution.html'];
const VIEWPORTS = [{ name: '320x640', width: 320, height: 640 }, { name: '390x844', width: 390, height: 844 }, { name: '1440x900', width: 1440, height: 900 }];
// 2026-10-14 rebuild: the home page shows real captures (lazy WebP) and the unmodified
// Special Elite TTF stays at 166 KB, so the transfer and request budgets moved from
// 250 KB / 8 to 420 KB / 12. LCP and CLS budgets are unchanged.
const BUDGET = { bytes: 420_000, requests: 12, lcpMs: 2500, cls: 0.05 };
const MIME = { '.html': 'text/html; charset=utf-8', '.css': 'text/css; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.json': 'application/json', '.svg': 'image/svg+xml', '.png': 'image/png', '.webp': 'image/webp', '.gif': 'image/gif', '.mp4': 'video/mp4', '.ttf': 'font/ttf', '.txt': 'text/plain; charset=utf-8', '.xml': 'application/xml' };

const results = [];
const measurements = {};
function record(name, ok, detail = '', scope = '') {
  results.push({ name, ok, detail, scope });
  console.log(`${ok ? 'PASS' : 'FAIL'} ${name}${scope ? ` [${scope}]` : ''}${detail ? ` — ${detail}` : ''}`);
}

function startServer() {
  const server = http.createServer((request, response) => {
    const url = new URL(request.url, 'http://localhost');
    let relative = decodeURIComponent(url.pathname);
    if (relative.endsWith('/')) relative += 'index.html';
    const target = path.normalize(path.join(site, relative));
    if (!target.startsWith(site) || !fs.existsSync(target) || fs.statSync(target).isDirectory()) {
      const notFound = fs.readFileSync(path.join(site, '404.html'));
      response.writeHead(404, { 'content-type': MIME['.html'], 'content-length': notFound.length });
      response.end(notFound); return;
    }
    const body = fs.readFileSync(target);
    response.writeHead(200, { 'content-type': MIME[path.extname(target)] || 'application/octet-stream', 'content-length': body.length, 'cache-control': 'no-store' });
    response.end(body);
  });
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve(server)));
}

// --- in-page audits -------------------------------------------------------
const auditScript = () => {
  const out = {};
  const visible = (el) => {
    if (!el.getClientRects().length) return false;
    const cs = getComputedStyle(el);
    return cs.visibility !== 'hidden' && cs.display !== 'none';
  };
  out.scrollWidth = document.documentElement.scrollWidth;
  out.innerWidth = window.innerWidth;
  out.h1Count = document.querySelectorAll('h1').length;
  const levels = [...document.querySelectorAll('h1,h2,h3,h4,h5,h6')].map((h) => Number(h.tagName[1]));
  out.skippedHeadings = levels.filter((level, index) => index > 0 && level > levels[index - 1] + 1).length;
  out.landmarks = { main: !!document.querySelector('main'), nav: !!document.querySelector('nav'), header: !!document.querySelector('header') };
  out.imagesWithoutAlt = [...document.querySelectorAll('img')].filter((img) => !img.hasAttribute('alt')).length;
  out.unlabelled = [...document.querySelectorAll('input,select,textarea')].filter((el) => visible(el) && !(el.labels && el.labels.length) && !el.getAttribute('aria-label') && !el.getAttribute('aria-labelledby')).map((el) => el.id || el.name || el.tagName);
  out.unnamedControls = [...document.querySelectorAll('a[href],button')].filter((el) => visible(el) && !(el.textContent || '').trim() && !el.getAttribute('aria-label') && !el.querySelector('img[alt]:not([alt=""])')).map((el) => el.outerHTML.slice(0, 60));
  out.smallTargets = [];
  for (const el of document.querySelectorAll('a[href],button,input,select,textarea,summary,[role=button]')) {
    if (!visible(el) || el.disabled) continue;
    const rect = el.getBoundingClientRect();
    if (!rect.width || !rect.height) continue;
    const cs = getComputedStyle(el);
    const parentText = el.parentElement ? el.parentElement.textContent.trim() : '';
    const inlineInText = el.tagName === 'A' && cs.display === 'inline' && parentText.length > el.textContent.trim().length;
    if (inlineInText) continue;
    if (rect.width < 44 || rect.height < 44) out.smallTargets.push({ tag: el.tagName, text: (el.textContent || el.value || '').trim().slice(0, 40), id: el.id, w: Math.round(rect.width), h: Math.round(rect.height) });
  }
  // Contrast walk over elements with direct text.
  const parse = (color) => { const m = color.match(/rgba?\(([^)]+)\)/); if (!m) return null; const p = m[1].split(',').map(Number); return { r: p[0], g: p[1], b: p[2], a: p.length > 3 ? p[3] : 1 }; };
  const over = (top, bottom) => ({ r: top.r * top.a + bottom.r * (1 - top.a), g: top.g * top.a + bottom.g * (1 - top.a), b: top.b * top.a + bottom.b * (1 - top.a), a: 1 });
  const lum = ({ r, g, b }) => { const f = (v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; }; return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b); };
  const bodyBg = parse(getComputedStyle(document.body).backgroundColor) || { r: 255, g: 255, b: 255, a: 1 };
  const backgroundOf = (el) => {
    let node = el; let acc = null;
    while (node && node.nodeType === 1) {
      const bg = parse(getComputedStyle(node).backgroundColor);
      if (bg && bg.a > 0) { acc = acc ? over(acc, bg) : bg; if (acc.a >= 1) return acc; }
      node = node.parentElement;
    }
    return acc ? over(acc, bodyBg) : bodyBg;
  };
  out.contrast = []; out.contrastChecked = 0;
  for (const el of document.body.querySelectorAll('*')) {
    if (['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE'].includes(el.tagName) || el.closest('svg')) continue;
    const text = [...el.childNodes].filter((n) => n.nodeType === 3).map((n) => n.textContent).join('').trim();
    if (!text || !visible(el)) continue;
    if (el.disabled) continue;
    const cs = getComputedStyle(el);
    if (Number(cs.opacity) === 0) continue;
    let fg = parse(cs.color); if (!fg) continue;
    const bg = backgroundOf(el);
    if (fg.a < 1) fg = over(fg, bg);
    const l1 = lum(fg), l2 = lum(bg);
    const ratio = (Math.max(l1, l2) + 0.05) / (Math.min(l1, l2) + 0.05);
    const size = parseFloat(cs.fontSize); const weight = parseInt(cs.fontWeight, 10) || 400;
    const large = size >= 24 || (size >= 18.66 && weight >= 700);
    out.contrastChecked += 1;
    if (ratio < (large ? 3 : 4.5)) out.contrast.push({ tag: el.tagName, cls: el.className, text: text.slice(0, 30), ratio: Math.round(ratio * 100) / 100, fg: cs.color, bg: `rgb(${Math.round(bg.r)},${Math.round(bg.g)},${Math.round(bg.b)})` });
  }
  return out;
};

async function auditPage(page, base, file, viewport) {
  const scope = `${file}@${viewport.name}`;
  const errors = []; const offsite = [];
  const onConsole = (m) => { if (m.type() === 'error') errors.push(m.text()); };
  const onError = (e) => errors.push(String(e));
  const onRequest = (r) => { if (!r.url().startsWith(base) && !r.url().startsWith('data:') && !r.url().startsWith('blob:')) offsite.push(r.url()); };
  page.on('console', onConsole); page.on('pageerror', onError); page.on('request', onRequest);
  await page.goto(base + file, { waitUntil: 'load' });
  await page.evaluate(() => document.fonts.ready);
  // Reveal every data-reveal section (scroll through once) so the audit covers the whole page.
  await page.evaluate(async () => { for (let y = 0; y <= document.body.scrollHeight; y += 400) { window.scrollTo(0, y); await new Promise((r) => setTimeout(r, 15)); } window.scrollTo(0, 0); });
  await page.waitForTimeout(900);
  if (file === 'index.html') await page.evaluate(() => document.querySelectorAll('details').forEach((d) => { d.open = true; }));
  const audit = await page.evaluate(auditScript);
  record('no console errors / page errors', errors.length === 0, errors.join(' | ').slice(0, 300), scope);
  record('zero third-party requests', offsite.length === 0, offsite.join(', ').slice(0, 300), scope);
  record('no horizontal overflow', audit.scrollWidth <= audit.innerWidth, `scrollWidth ${audit.scrollWidth} vs ${audit.innerWidth}`, scope);
  record('interactive targets ≥44×44', audit.smallTargets.length === 0, audit.smallTargets.map((t) => `${t.tag}#${t.id}"${t.text}" ${t.w}×${t.h}`).join('; ').slice(0, 400), scope);
  record('exactly one h1', audit.h1Count === 1, `h1 count ${audit.h1Count}`, scope);
  record('no skipped heading levels', audit.skippedHeadings === 0, `${audit.skippedHeadings} skips`, scope);
  record('main/nav/header landmarks', audit.landmarks.main && audit.landmarks.nav && audit.landmarks.header, JSON.stringify(audit.landmarks), scope);
  record('every img has alt', audit.imagesWithoutAlt === 0, `${audit.imagesWithoutAlt} missing`, scope);
  record('form controls labelled', audit.unlabelled.length === 0, audit.unlabelled.join(', '), scope);
  record('links/buttons have names', audit.unnamedControls.length === 0, audit.unnamedControls.join(' | '), scope);
  record('text contrast ≥4.5:1 (3:1 large)', audit.contrast.length === 0, audit.contrast.length ? audit.contrast.slice(0, 6).map((c) => `${c.tag}.${c.cls} "${c.text}" ${c.ratio} (${c.fg} on ${c.bg})`).join('; ') : `${audit.contrastChecked} text elements checked`, scope);
  // Keyboard: first Tab stop shows a visible focus outline.
  await page.goto(base + file, { waitUntil: 'load' });
  await page.keyboard.press('Tab');
  const focus = await page.evaluate(() => { const el = document.activeElement; const cs = getComputedStyle(el); return { tag: el.tagName, cls: el.className, outlineStyle: cs.outlineStyle, outlineWidth: parseFloat(cs.outlineWidth), focusVisible: el.matches(':focus-visible') }; });
  record('visible focus outline on first Tab stop', focus.outlineStyle !== 'none' && focus.outlineWidth > 0 && focus.focusVisible, `${focus.tag}.${focus.cls} outline ${focus.outlineStyle} ${focus.outlineWidth}px`, scope);
  page.off('console', onConsole); page.off('pageerror', onError); page.off('request', onRequest);
  return { errors, offsite };
}

async function indexBehaviour(context, base, viewport, articles) {
  const scope = `index.html@${viewport.name}`;
  const page = await context.newPage();
  const errors = []; page.on('pageerror', (e) => errors.push(String(e))); page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });
  await page.goto(base + 'index.html', { waitUntil: 'load' });
  // Skip link.
  await page.keyboard.press('Tab');
  const skip = await page.evaluate(() => { const el = document.activeElement; const r = el.getBoundingClientRect(); return { isSkip: el.classList.contains('skip'), href: el.getAttribute('href'), visible: r.top >= 0 && r.height > 0 }; });
  await page.keyboard.press('Enter');
  const afterSkip = await page.evaluate(() => ({ hash: location.hash, activeIsMain: document.activeElement === document.querySelector('#main') }));
  record('skip link is first Tab stop, visible, targets #main and focuses main', skip.isSkip && skip.visible && skip.href === '#main' && afterSkip.hash === '#main' && afterSkip.activeIsMain, JSON.stringify({ ...skip, ...afterSkip }), scope);
  // Menu (compact only).
  const compact = viewport.width <= 700;
  const menu = page.locator('.menu');
  if (compact) {
    const hiddenBefore = await menu.isHidden();
    await menu.click();
    const expanded = await menu.getAttribute('aria-expanded');
    const navVisible = await page.locator('#navigation').isVisible();
    await page.keyboard.press('Escape');
    const collapsed = await menu.getAttribute('aria-expanded');
    const focusOnMenu = await page.evaluate(() => document.activeElement.classList.contains('menu'));
    const navHidden = await page.locator('#navigation').isHidden();
    record('menu toggles aria-expanded, Escape closes and refocuses', !hiddenBefore && expanded === 'true' && navVisible && collapsed === 'false' && focusOnMenu && navHidden, `expanded=${expanded} collapsed=${collapsed} focus=${focusOnMenu}`, scope);
  } else {
    const menuHidden = await menu.isHidden(); const navVisible = await page.locator('#navigation').isVisible();
    record('menu button hidden and nav visible at desktop width', menuHidden && navVisible, '', scope);
  }
  // Help search.
  const term = 'lasso';
  const expected = articles.filter((a) => [a.title, a.platform, (a.keywords || []).join(' '), ...a.steps, ...(a.limits || [])].join(' ').toLocaleLowerCase().includes(term)).length;
  await page.fill('#query', term);
  const found = await page.evaluate(() => ({ rendered: document.querySelectorAll('#help-results details').length, count: document.querySelector('#help-count').textContent, allMatch: [...document.querySelectorAll('#help-results details')].every((d) => d.textContent.toLocaleLowerCase().includes('lasso')) }));
  record(`help search "lasso" renders ${expected} matching topic(s)`, found.rendered === expected && found.allMatch && found.count.startsWith(`${expected} `), `rendered ${found.rendered}, status "${found.count}"`, scope);
  await page.click('#help-search button[type=reset]');
  // Filters.
  await page.click('[data-filter="animate"]');
  const filter = await page.evaluate(() => ({ pressed: [...document.querySelectorAll('[data-filter]')].map((b) => `${b.dataset.filter}:${b.getAttribute('aria-pressed')}`).join(','), categories: [...new Set([...document.querySelectorAll('#help-results details')].map((d) => d.dataset.category))], rendered: document.querySelectorAll('#help-results details').length }));
  const expectedAnimate = articles.filter((a) => a.category === 'animate').length;
  record('category filter sets aria-pressed and narrows results', filter.pressed === 'all:false,create:false,animate:true,keep:false,account:false' && filter.categories.join() === 'animate' && filter.rendered === expectedAnimate, `${filter.pressed}; ${filter.rendered} rendered`, scope);
  await page.click('[data-filter="all"]');
  // Fragment routing for every article.
  const routeFailures = [];
  for (const article of articles) {
    await page.goto(base + 'index.html#help/' + article.id, { waitUntil: 'load' });
    try {
      await page.waitForSelector(`#article-${article.id}[open]`, { timeout: 3000 });
      const focused = await page.evaluate((id) => document.activeElement === document.querySelector(`#article-${id} summary`), article.id);
      if (!focused) routeFailures.push(`${article.id}: summary not focused`);
    } catch (_) { routeFailures.push(`${article.id}: not opened`); }
  }
  record(`every #help/<id> fragment opens and focuses its topic (${articles.length} ids)`, routeFailures.length === 0, routeFailures.join('; '), scope);
  // Support form flow.
  await page.goto(base + 'index.html', { waitUntil: 'load' });
  await page.click('#support-form button[type=submit]');
  const invalid = await page.textContent('#support-status');
  await page.fill('#problem', 'The exported GIF was silent even though the clip was audible.');
  await page.click('#support-form button[type=submit]');
  const reviewVisible = await page.locator('#support-review').isVisible();
  const preview = await page.inputValue('#support-preview');
  const downloadPromise = page.waitForEvent('download', { timeout: 5000 }).catch(() => null);
  await page.click('#support-download');
  const download = await downloadPromise;
  const downloadStatus = await page.textContent('#support-status');
  await page.click('#support-copy');
  await page.waitForTimeout(300);
  const copyStatus = await page.textContent('#support-status');
  let clipboardMatches = null;
  if (copyStatus.includes('copied')) clipboardMatches = await page.evaluate(async () => navigator.clipboard.readText()).then((t) => t === preview).catch(() => false);
  await page.click('#support-form button[type=reset]');
  const reset = await page.evaluate(() => ({ status: document.querySelector('#support-status').textContent, hidden: document.querySelector('#support-review').hidden, problem: document.querySelector('#problem').value }));
  record('support form rejects an empty report with the 10–2,000 character message', invalid.includes('10–2,000'), invalid, scope);
  record('Review prepares a local summary marked not submitted', reviewVisible && preview.includes('Not submitted to a support service'), '', scope);
  record('Download fires a browser download event', !!download && download.suggestedFilename() === 'stickdeath-problem-summary.txt' && downloadStatus.includes('Download requested'), download ? download.suggestedFilename() : 'no download event', scope);
  record('Copy writes the clipboard or shows the selection fallback', (copyStatus.includes('copied') && clipboardMatches === true) || copyStatus.includes('Automatic copying is unavailable'), copyStatus, scope);
  record('Reset clears the draft and says nothing was submitted', reset.status.includes('cleared') && reset.hidden && reset.problem === '', reset.status, scope);
  record('no page errors during index behaviour run', errors.length === 0, errors.join(' | ').slice(0, 300), scope);
  await page.close();
}

async function perf(browser, base) {
  const context = await browser.newContext({ viewport: { width: 390, height: 844 } });
  const page = await context.newPage();
  const cdp = await context.newCDPSession(page);
  await cdp.send('Network.enable');
  await cdp.send('Network.emulateNetworkConditions', { offline: false, latency: 150, downloadThroughput: 1.6 * 1024 * 1024 / 8, uploadThroughput: 750 * 1024 / 8 });
  await cdp.send('Emulation.setCPUThrottlingRate', { rate: 4 });
  await page.addInitScript(() => {
    window.__perf = { lcp: 0, cls: 0 };
    new PerformanceObserver((list) => { for (const entry of list.getEntries()) window.__perf.lcp = entry.renderTime || entry.loadTime; }).observe({ type: 'largest-contentful-paint', buffered: true });
    new PerformanceObserver((list) => { for (const entry of list.getEntries()) if (!entry.hadRecentInput) window.__perf.cls += entry.value; }).observe({ type: 'layout-shift', buffered: true });
  });
  const transfers = [];
  page.on('response', async (response) => { try { const sizes = await response.request().sizes(); transfers.push({ url: response.url().replace(base, '/'), bytes: sizes.responseBodySize + sizes.responseHeadersSize, status: response.status() }); } catch (_) { /* ignore */ } });
  const started = Date.now();
  await page.goto(base + 'index.html', { waitUntil: 'load' });
  await page.waitForTimeout(3000);
  const metrics = await page.evaluate(() => { const nav = performance.getEntriesByType('navigation')[0]; return { lcp: window.__perf.lcp, cls: window.__perf.cls, domContentLoaded: nav.domContentLoadedEventEnd, load: nav.loadEventEnd }; });
  const totalBytes = transfers.reduce((n, t) => n + t.bytes, 0);
  measurements.perf = { viewport: '390x844', network: 'Slow-4G emulation (150 ms RTT, 1.6 Mbps down, 750 kbps up)', cpuThrottle: 4, requests: transfers.length, transferBytes: totalBytes, lcpMs: Math.round(metrics.lcp), cls: Math.round(metrics.cls * 10000) / 10000, domContentLoadedMs: Math.round(metrics.domContentLoaded), loadMs: Math.round(metrics.load), wallMs: Date.now() - started, transfers };
  record(`perf: requests ≤${BUDGET.requests}`, transfers.length <= BUDGET.requests, `${transfers.length} requests`, 'index.html@390x844 slow-4g cpu×4');
  record(`perf: transfer ≤${BUDGET.bytes.toLocaleString('en-US')} bytes`, totalBytes <= BUDGET.bytes, `${totalBytes.toLocaleString('en-US')} bytes`, 'index.html@390x844 slow-4g cpu×4');
  record(`perf: LCP ≤${BUDGET.lcpMs} ms`, metrics.lcp > 0 && metrics.lcp <= BUDGET.lcpMs, `${Math.round(metrics.lcp)} ms`, 'index.html@390x844 slow-4g cpu×4');
  record(`perf: CLS ≤${BUDGET.cls}`, metrics.cls <= BUDGET.cls, `${metrics.cls.toFixed(4)}`, 'index.html@390x844 slow-4g cpu×4');
  await context.close();
}

async function main() {
  const server = await startServer();
  const base = `http://127.0.0.1:${server.address().port}/`;
  const articles = JSON.parse(fs.readFileSync(path.join(site, 'help', 'articles.json'), 'utf8')).articles;
  const browser = await chromium.launch({ headless: true });
  try {
    for (const viewport of VIEWPORTS) {
      const context = await browser.newContext({ viewport: { width: viewport.width, height: viewport.height }, permissions: ['clipboard-read', 'clipboard-write'], acceptDownloads: true });
      const page = await context.newPage();
      for (const file of PAGES) await auditPage(page, base, file, viewport);
      await page.close();
      await indexBehaviour(context, base, viewport, articles);
      await context.close();
    }
    // account.html with configuration: the sign-in form shows, the profile stays hidden, only own files load.
    const accountContext = await browser.newContext({ viewport: { width: 390, height: 844 } }); const accountPage = await accountContext.newPage();
    const accountRequests = []; accountPage.on('request', (r) => accountRequests.push(r.url()));
    await accountPage.goto(base + 'account.html', { waitUntil: 'load' }); await accountPage.waitForTimeout(400);
    const accountState = await accountPage.evaluate(() => ({ signin: !document.querySelector('#account-signin').hidden, profile: document.querySelector('#account-profile').hidden, title: document.querySelector('#account-status-title').textContent }));
    record('account page shows the sign-in form and hides the profile before a session', accountState.signin && accountState.profile && accountState.title.includes('Signed out'), JSON.stringify(accountState), 'account.html@390x844');
    record('account page requests only its own files on load', accountRequests.every((u) => u.startsWith(base)), `${accountRequests.length} requests`, 'account.html@390x844');
    await accountPage.fill('#account-email', 'nobody@example.invalid'); await accountPage.fill('#account-password', 'short');
    await accountPage.click('#account-form button[type=submit]');
    const formStatus = await accountPage.locator('#account-form-status').textContent();
    record('account sign-in validates locally before any request', formStatus.includes('at least 8 characters') && accountRequests.every((u) => u.startsWith(base)), formStatus, 'account.html@390x844');
    await accountContext.close();
    // store.html unconfigured: planned products without prices, no checkout, no external request.
    const storeContext = await browser.newContext({ viewport: { width: 390, height: 844 } }); const storePage = await storeContext.newPage();
    const storeRequests = []; storePage.on('request', (r) => storeRequests.push(r.url()));
    await storePage.goto(base + 'store.html', { waitUntil: 'load' }); await storePage.waitForTimeout(400);
    const storeState = await storePage.evaluate(() => ({ status: document.querySelector('#store-status').textContent, prices: [...document.querySelectorAll('.price')].map((p) => p.textContent), cartHidden: document.querySelector('#cart').hidden, products: document.querySelectorAll('.product').length }));
    record('store shows the planned line-up without prices or cart when unconfigured', storeState.products === 8 && storeState.cartHidden && storeState.prices.every((p) => p === 'Price on opening') && storeState.status.includes('not open yet'), JSON.stringify(storeState).slice(0, 200), 'store.html@390x844');
    record('store requests only its own files when unconfigured', storeRequests.every((u) => u.startsWith(base)), `${storeRequests.length} requests`, 'store.html@390x844');
    await storeContext.close();
    // index.html: splash is decorative and gone within three seconds; hero speed slider changes the animation.
    const splashContext = await browser.newContext({ viewport: { width: 390, height: 844 } }); const splashPage = await splashContext.newPage();
    await splashPage.goto(base + 'index.html', { waitUntil: 'load' });
    const splashEarly = await splashPage.evaluate(() => { const s = document.querySelector('#splash'); return s ? { present: true, ariaHidden: s.getAttribute('aria-hidden'), focusable: s.querySelectorAll('a,button,input,[tabindex]').length } : { present: false }; });
    await splashPage.waitForTimeout(3000);
    const splashLate = await splashPage.evaluate(() => Boolean(document.querySelector('#splash')));
    record('home splash is decorative (aria-hidden, no focusable controls) and removed within 3 s', splashEarly.present && splashEarly.ariaHidden === 'true' && splashEarly.focusable === 0 && !splashLate, JSON.stringify({ splashEarly, splashLate }), 'index.html@390x844');
    await splashPage.locator('#hero-fps').fill('24');
    const fpsState = await splashPage.evaluate(() => ({ out: document.querySelector('#hero-fps-value').textContent, dur: document.querySelector('.flipbook .pose').style.animationDuration }));
    record('hero speed slider retimes the flipbook', fpsState.out === '24 fps' && fpsState.dur === '0.25s', JSON.stringify(fpsState), 'index.html@390x844');
    await splashContext.close();
    // play.html: the browser flipbook draws, adds frames, plays and downloads.
    const playContext = await browser.newContext({ viewport: { width: 390, height: 844 }, acceptDownloads: true });
    const playPage = await playContext.newPage();
    const playErrors = []; playPage.on('pageerror', (e) => playErrors.push(String(e))); playPage.on('console', (m) => { if (m.type() === 'error') playErrors.push(m.text()); });
    await playPage.goto(base + 'play.html', { waitUntil: 'load' });
    const paper = playPage.locator('#play-canvas'); await paper.scrollIntoViewIfNeeded(); const box = await paper.boundingBox();
    const inkSum = () => playPage.evaluate(() => { const c = document.querySelector('#play-canvas'); const d = c.getContext('2d').getImageData(0, 0, c.width, c.height).data; let s = 0; for (let i = 0; i < d.length; i += 4) s += d[i]; return s; });
    const before = await inkSum();
    await playPage.mouse.move(box.x + box.width * 0.3, box.y + box.height * 0.3); await playPage.mouse.down();
    await playPage.mouse.move(box.x + box.width * 0.7, box.y + box.height * 0.6, { steps: 12 }); await playPage.mouse.up();
    const after = await inkSum();
    record('play: pointer stroke changes the canvas', after !== before, `red-channel sum ${before} → ${after}`, 'play.html@390x844');
    await playPage.click('#play-duplicate'); await playPage.click('#play-add');
    const label = await playPage.locator('#play-frame-label').textContent();
    record('play: duplicate + add frame → frame 3 of 3', label.trim() === 'Frame 3 of 3', label.trim(), 'play.html@390x844');
    await playPage.click('#play-toggle'); const playingText = await playPage.locator('#play-toggle').textContent();
    await playPage.click('#play-toggle'); const stoppedText = await playPage.locator('#play-toggle').textContent();
    record('play: Play toggles to Stop and back', playingText.trim() === 'Stop' && stoppedText.trim() === 'Play', `${playingText.trim()} / ${stoppedText.trim()}`, 'play.html@390x844');
    const gif = await Promise.all([playPage.waitForEvent('download', { timeout: 15000 }).catch(() => null), playPage.click('#play-gif')]);
    record('play: GIF download fires', Boolean(gif[0]) && gif[0].suggestedFilename().endsWith('.gif'), gif[0] ? gif[0].suggestedFilename() : 'no download', 'play.html@390x844');
    const png = await Promise.all([playPage.waitForEvent('download', { timeout: 15000 }).catch(() => null), playPage.click('#play-png')]);
    record('play: PNG spritesheet download fires', Boolean(png[0]) && png[0].suggestedFilename().endsWith('.png'), png[0] ? png[0].suggestedFilename() : 'no download', 'play.html@390x844');
    record('play: no page errors during the flipbook journey', playErrors.length === 0, playErrors.join(' | ').slice(0, 300), 'play.html@390x844');
    await playContext.close();
    // Missing path serves 404.html with status 404.
    const probe = await browser.newContext(); const probePage = await probe.newPage();
    const response = await probePage.goto(base + 'does-not-exist.html');
    record('missing path returns 404 status with the 404 page', response.status() === 404 && (await probePage.textContent('h1')).includes('never'), `status ${response.status()}`, 'server');
    await probe.close();
    // Reduced motion.
    const reduced = await browser.newContext({ reducedMotion: 'reduce', viewport: { width: 390, height: 844 } });
    const reducedPage = await reduced.newPage();
    await reducedPage.goto(base + 'index.html', { waitUntil: 'load' });
    const motion = await reducedPage.evaluate(() => ({ matches: matchMedia('(prefers-reduced-motion: reduce)').matches, scrollBehavior: getComputedStyle(document.documentElement).scrollBehavior }));
    record('prefers-reduced-motion → scroll-behavior auto', motion.matches && motion.scrollBehavior === 'auto', JSON.stringify(motion), 'index.html@390x844');
    await reduced.close();
    // No JavaScript.
    const nojs = await browser.newContext({ javaScriptEnabled: false, viewport: { width: 390, height: 844 } });
    const nojsPage = await nojs.newPage();
    await nojsPage.goto(base + 'index.html', { waitUntil: 'load' });
    // Playwright's isVisible() reports false for content rendered inside <noscript>, so measure in-page: the paragraph must have a box and non-hidden styles.
    const rendered = ({ text }) => { const el = [...document.querySelectorAll('noscript p, main p, main h2')].find((p) => p.textContent.includes(text)); if (!el) return false; const cs = getComputedStyle(el); return el.getClientRects().length > 0 && cs.display !== 'none' && cs.visibility !== 'hidden'; };
    const noscriptVisible = await nojsPage.evaluate(rendered, { text: 'Enable JavaScript for searchable help' });
    const accountStatic = await (async () => { await nojsPage.goto(base + 'account.html', { waitUntil: 'load' }); return nojsPage.evaluate(rendered, { text: 'Sign-in requires JavaScript' }); })();
    record('noscript guidance visible with JavaScript disabled', noscriptVisible, '', 'index.html@390x844 no-js');
    record('account page states that sign-in requires JavaScript when it is off', accountStatic, '', 'account.html@390x844 no-js');
    const storeStatic = await (async () => { await nojsPage.goto(base + 'store.html', { waitUntil: 'load' }); return nojsPage.evaluate(rendered, { text: 'Live prices and the cart need JavaScript' }); })();
    record('store page states that prices need JavaScript when it is off', storeStatic, '', 'store.html@390x844 no-js');
    const adminStatic = await (async () => { await nojsPage.goto(base + 'admin.html', { waitUntil: 'load' }); return nojsPage.evaluate(rendered, { text: 'The command center is not configured' }); })();
    record('admin shell states "not configured" without JavaScript', adminStatic, '', 'admin.html@390x844 no-js');
    await nojs.close();
    // Admin shell with JavaScript and the repository's null configuration: sign-in stays hidden, nothing is requested.
    const adminContext = await browser.newContext({ viewport: { width: 390, height: 844 } });
    const adminPage = await adminContext.newPage();
    const adminRequests = [];
    adminPage.on('request', (request) => adminRequests.push(request.url()));
    await adminPage.goto(base + 'admin.html', { waitUntil: 'load' });
    const adminState = await adminPage.evaluate(() => ({ configured: window.SDI_ADMIN_CONFIG !== null && window.SDI_ADMIN_CONFIG !== undefined, signinHidden: document.getElementById('admin-signin').hidden, consoleHidden: document.getElementById('admin-console').hidden, title: document.getElementById('admin-status-title').textContent }));
    const sameOrigin = adminRequests.every((url) => url.startsWith(base));
    // Unconfigured: nothing dynamic. Configured (admin-config.js holds the public backend origin and
    // publishable key): the sign-in form shows, the console stays hidden until the server verifies a
    // session, and loading the page still sends nothing anywhere.
    if (adminState.configured) {
      record('admin shell shows sign-in and keeps the console hidden before a verified session', !adminState.signinHidden && adminState.consoleHidden && adminState.title.includes('not signed in'), JSON.stringify(adminState), 'admin.html@390x844');
    } else {
      record('admin shell keeps sign-in and console hidden with null configuration', adminState.signinHidden && adminState.consoleHidden && adminState.title.includes('not configured'), JSON.stringify(adminState), 'admin.html@390x844');
    }
    record('admin shell requests only its own files on load', sameOrigin, `${adminRequests.length} requests`, 'admin.html@390x844');
    await adminContext.close();
    // file:// smoke: the help center must render from the embedded help-data.js without fetch().
    const local = await browser.newContext({ viewport: { width: 1440, height: 900 } });
    const localPage = await local.newPage();
    const localErrors = []; localPage.on('pageerror', (e) => localErrors.push(String(e))); localPage.on('console', (m) => { if (m.type() === 'error') localErrors.push(m.text()); });
    await localPage.goto('file://' + path.join(site, 'index.html'), { waitUntil: 'load' });
    const localCount = await localPage.evaluate(() => document.querySelectorAll('#help-results details').length);
    record(`file:// load renders all ${articles.length} help topics without errors`, localCount === articles.length && localErrors.length === 0, `${localCount} topics; ${localErrors.join(' | ').slice(0, 200)}`, 'index.html file://');
    await local.close();
    await perf(browser, base);
  } finally {
    await browser.close();
    server.close();
  }
  const failed = results.filter((r) => !r.ok);
  const summary = { passed: results.length - failed.length, failed: failed.length, total: results.length, pages: PAGES, viewports: VIEWPORTS.map((v) => v.name), budgets: BUDGET, measurements, failures: failed, playwright: require(require.resolve('playwright/package.json', { paths: [here, '/opt/node-tools'] })).version, node: process.version, ranAt: new Date().toISOString() };
  console.log(`\n${summary.passed}/${summary.total} checks passed${failed.length ? `, ${failed.length} failed` : ''}.`);
  console.log(`perf (390×844, Slow-4G, CPU×4): ${measurements.perf.requests} requests, ${measurements.perf.transferBytes.toLocaleString('en-US')} bytes, LCP ${measurements.perf.lcpMs} ms, CLS ${measurements.perf.cls}, load ${measurements.perf.loadMs} ms`);
  if (jsonOut) fs.writeFileSync(jsonOut, JSON.stringify(summary, null, 2));
  process.exit(failed.length ? 1 : 0);
}

main().catch((error) => { console.error(error); process.exit(1); });
