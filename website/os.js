'use strict';
// StickDeath desktop (index.html): boot sequence, menu bar with a Desktop menu, window manager with
// close / half / maximize / restore / drag / edge snapping / resize / keyboard, a flame dock for windows
// saved to the desktop, draggable icons, a screensaver, CRT scanlines, privacy choices, jukebox with a
// real Web Audio scope, captures and clips. Layout memory is localStorage in this browser only;
// nothing is sent anywhere and every read/write is guarded. Same-origin only.
(() => {
  const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const $ = (s, r = document) => r.querySelector(s);
  const narrow = () => innerWidth <= 700;
  // ---- storage (per-browser conveniences; fails closed) --------------------------------
  const KEY = 'sdi-os';
  const load = () => { try { return JSON.parse(localStorage.getItem(KEY) || '{}') || {}; } catch (_) { return {}; } };
  let store = load();
  const prefs = Object.assign({ layout: true, diagnostics: false, crt: false }, store.prefs || {});
  function save() { try { const out = { prefs }; if (prefs.layout) { out.windows = store.windows; out.icons = store.icons; } if (prefs.diagnostics) out.counts = store.counts; localStorage.setItem(KEY, JSON.stringify(out)); } catch (_) { /* private mode or blocked storage */ } }
  function forgetAll() { try { localStorage.clear(); sessionStorage.clear(); } catch (_) { /* ignore */ } store = {}; }
  // ---- boot ------------------------------------------------------------------------------
  const boot = $('#boot'); const bar = $('#boot-bar'); const log = $('#boot-log');
  const lines = ['Loading brushes… 30 tools, 13 families', 'Mounting sound library… 2,127 sounds', 'Counting layers… 18 blend modes', 'Onion skin… on', 'Ready.'];
  let booted = false;
  function finishBoot() { if (booted) return; booted = true; if (boot) boot.remove(); if (!restoreLayout()) { openWindow('about'); $('#main').focus({ preventScroll: true }); } }
  if (!boot || reduced) finishBoot();
  else { let i = 0; const step = () => { if (booted) return; if (i < lines.length) { log.textContent = lines.slice(Math.max(0, i - 2), i + 1).join('\n'); bar.style.width = `${Math.round(((i + 1) / lines.length) * 100)}%`; i += 1; setTimeout(step, 300); } else setTimeout(finishBoot, 250); }; step(); setTimeout(finishBoot, 3200); }
  if ($('#boot-skip')) $('#boot-skip').addEventListener('click', finishBoot);
  document.addEventListener('keydown', (e) => { if (!booted && (e.key === 'Enter' || e.key === ' ')) { e.preventDefault(); finishBoot(); } });
  // ---- menubar ---------------------------------------------------------------------------
  const clock = $('#os-clock'); const frame = $('#os-frame'); let f = 1;
  const tick = () => { clock.textContent = new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }); };
  tick(); setInterval(tick, 15000);
  if (!reduced) setInterval(() => { f = (f % 9999) + 1; frame.textContent = String(f).padStart(4, '0'); const sf = $('#saver-frame'); if (sf && !$('#saver').hidden) sf.textContent = frame.textContent; }, 1000 / 12);
  // ---- window manager --------------------------------------------------------------------
  const windows = [...document.querySelectorAll('.window')]; let z = 10; let cascade = 0;
  const taskbar = $('#taskbar'); const status = $('#status-windows'); const main = $('#main');
  const state = new Map(); // id → { normal: {left, top, width, height}, maximized, half, snapped: null|'left'|'right', minimized, opener }
  const desk = () => main.getBoundingClientRect();
  const nameOf = (w) => w.id.replace('win-', '');
  function geo(w) { return { left: w.offsetLeft, top: w.offsetTop, width: w.offsetWidth, height: w.offsetHeight }; }
  function apply(w, g) { w.style.left = `${g.left}px`; w.style.top = `${g.top}px`; w.style.width = g.width ? `${g.width}px` : ''; w.style.height = g.height ? `${g.height}px` : ''; }
  function updateStatus() { const open = windows.filter((w) => !w.hidden).length; const docked = [...taskbar.children].length; status.textContent = `${open} window${open === 1 ? '' : 's'} open${docked ? `, ${docked} in the dock` : ''}`; persistLayout(); }
  function focusWindow(w) { windows.forEach((x) => x.classList.remove('active')); w.classList.add('active'); w.style.zIndex = String(++z); }
  function info(w) { if (!state.has(w.id)) { const [l, t, wd, h] = (w.dataset.geo || '80,60,420,0').split(',').map(Number); state.set(w.id, { normal: { left: l, top: t, width: wd, height: h }, maximized: false, half: false, snapped: null, minimized: false, opener: null }); } return state.get(w.id); }
  function place(w) {
    const s = info(w); const d = desk();
    if (narrow()) { const g = { left: 8 + (cascade % 3) * 10, top: 8 + (cascade % 4) * 18, width: Math.round(d.width * 0.92), height: Math.round(d.height * 0.66) }; cascade += 1; s.normal = g; apply(w, g); return; }
    const g = { ...s.normal }; const offset = (cascade % 6) * 24; cascade += 1;
    g.left = Math.max(8, Math.min(g.left + offset, d.width - Math.min(g.width || 420, d.width) - 8)); g.top = Math.max(8, Math.min(g.top + offset, d.height - 160));
    if (g.width > d.width - 16) g.width = d.width - 16; if (g.height > d.height - 16) g.height = d.height - 16;
    s.normal = g; apply(w, g);
  }
  function count(name) { if (!prefs.diagnostics) return; store.counts = store.counts || {}; store.counts[name] = (store.counts[name] || 0) + 1; renderCounts(); save(); }
  function openWindow(name, opener) {
    const w = document.getElementById(`win-${name}`); if (!w) return;
    const s = info(w);
    const iframe = w.querySelector('iframe[data-src]'); if (iframe && !iframe.src) iframe.src = iframe.dataset.src;
    if (s.minimized) restoreFromTaskbar(w); else if (w.hidden) { w.hidden = false; if (s.maximized) maximize(w, true); else if (s.half) halfSize(w, true); else if (s.snapped) snap(w, s.snapped, true); else place(w); count(name); }
    s.opener = opener || s.opener; focusWindow(w); updateStatus();
    const title = w.querySelector('.titlebar h2'); title.tabIndex = -1; title.focus({ preventScroll: true });
  }
  function closeWindow(w) { const s = info(w); w.hidden = true; w.classList.remove('active'); s.minimized = false; removeTask(w); if (w.id === 'win-juke') pause(); if (w.id === 'win-clips') $('#clip-video').pause(); updateStatus(); const next = windows.filter((x) => !x.hidden).sort((a, b) => Number(b.style.zIndex) - Number(a.style.zIndex))[0]; if (next) focusWindow(next); if (s.opener && document.contains(s.opener)) s.opener.focus(); }
  function labels(w, max, half) { const t = w.querySelector('h2').textContent; w.querySelector('[data-max]').setAttribute('aria-label', `${max ? 'Restore' : 'Maximize'} ${t}${max ? ' to its normal size' : ''}`); w.querySelector('[data-half]').setAttribute('aria-label', `${half ? 'Restore' : 'Half size'} ${t}${half ? ' to its normal size' : ''}`); }
  function remember(w, silent) { const s = info(w); if (!s.maximized && !s.half && !s.snapped && !silent) s.normal = geo(w); }
  function maximize(w, silent) { const s = info(w); remember(w, silent); s.maximized = true; s.half = false; s.snapped = null; const d = desk(); apply(w, { left: 0, top: 0, width: d.width, height: d.height }); w.classList.add('maximized'); w.classList.remove('half', 'snapped'); labels(w, true, false); persistLayout(); }
  function halfSize(w, silent) { const s = info(w); remember(w, silent); s.half = true; s.maximized = false; s.snapped = null; const d = desk(); const width = Math.round(d.width / 2); const height = Math.round(d.height / 2); apply(w, { left: Math.round((d.width - width) / 2), top: Math.round((d.height - height) / 2), width, height }); w.classList.add('half'); w.classList.remove('maximized', 'snapped'); labels(w, false, true); persistLayout(); }
  // Edge snap: left/right half of the desktop at full height (Aero/Stage style).
  function snap(w, side, silent) { const s = info(w); remember(w, silent); s.snapped = side; s.maximized = false; s.half = false; const d = desk(); const width = Math.round(d.width / 2); apply(w, { left: side === 'left' ? 0 : d.width - width, top: 0, width, height: d.height }); w.classList.add('snapped'); w.classList.remove('maximized', 'half'); labels(w, false, false); persistLayout(); }
  function restore(w) { const s = info(w); s.maximized = false; s.half = false; s.snapped = null; w.classList.remove('maximized', 'half', 'snapped'); apply(w, s.normal); labels(w, false, false); persistLayout(); }
  function toggleMax(w) { (info(w).maximized ? restore : maximize)(w); focusWindow(w); }
  function toggleHalf(w) { (info(w).half ? restore : halfSize)(w); focusWindow(w); }
  // "Save to the desktop": the window leaves the screen and sits in the dock until tapped.
  function dock(w, silent) { const s = info(w); s.minimized = true; w.hidden = true; w.classList.remove('active'); const b = document.createElement('button'); b.type = 'button'; b.dataset.task = w.id; b.textContent = w.querySelector('h2').textContent; b.setAttribute('aria-label', `Bring ${b.textContent} back from the dock`); b.addEventListener('click', () => openWindow(nameOf(w), b)); taskbar.append(b); updateStatus(); if (silent) return; const next = windows.filter((x) => !x.hidden)[0]; if (next) focusWindow(next); b.focus(); }
  function removeTask(w) { const b = taskbar.querySelector(`[data-task="${w.id}"]`); if (b) b.remove(); }
  function restoreFromTaskbar(w) { const s = info(w); s.minimized = false; removeTask(w); w.hidden = false; if (s.maximized) maximize(w, true); else if (s.half) halfSize(w, true); else if (s.snapped) snap(w, s.snapped, true); else apply(w, s.normal); }
  function tidy() { cascade = 0; windows.filter((w) => !w.hidden).sort((a, b) => Number(a.style.zIndex) - Number(b.style.zIndex)).forEach((w) => { const s = info(w); s.maximized = false; s.half = false; s.snapped = null; w.classList.remove('maximized', 'half', 'snapped'); const [l, t, wd, h] = (w.dataset.geo || '80,60,420,0').split(',').map(Number); s.normal = { left: l, top: t, width: wd, height: h }; place(w); labels(w, false, false); }); persistLayout(); }
  function closeAll() { windows.forEach((w) => { if (!w.hidden || info(w).minimized) { info(w).minimized = false; removeTask(w); w.hidden = true; w.classList.remove('active'); } }); pause(); updateStatus(); }
  // ---- layout memory ---------------------------------------------------------------------
  let restoring = false;
  function persistLayout() { if (restoring || !booted) return; if (!prefs.layout) return; store.windows = windows.map((w) => { const s = info(w); const open = !w.hidden || s.minimized; return open ? { id: w.id, normal: s.normal, maximized: s.maximized, half: s.half, snapped: s.snapped, minimized: s.minimized, z: Number(w.style.zIndex) || 0 } : null; }).filter(Boolean); save(); }
  function restoreLayout() {
    if (!prefs.layout || !Array.isArray(store.windows) || !store.windows.length || narrow()) return false;
    restoring = true; const d = desk(); let opened = 0;
    store.windows.sort((a, b) => a.z - b.z).forEach((r) => { const w = document.getElementById(r.id); if (!w) return; const s = info(w); const n = r.normal || s.normal; s.normal = { left: Math.max(0, Math.min(n.left, d.width - 120)), top: Math.max(0, Math.min(n.top, d.height - 60)), width: n.width, height: n.height }; s.maximized = !!r.maximized; s.half = !!r.half; s.snapped = r.snapped || null; const iframe = w.querySelector('iframe[data-src]'); if (iframe && !iframe.src) iframe.src = iframe.dataset.src; if (r.minimized) { w.hidden = false; dock(w, true); } else { w.hidden = false; if (s.maximized) maximize(w, true); else if (s.half) halfSize(w, true); else if (s.snapped) snap(w, s.snapped, true); else apply(w, s.normal); focusWindow(w); } opened += 1; });
    restoring = false; updateStatus(); const top = windows.filter((w) => !w.hidden).sort((a, b) => Number(b.style.zIndex) - Number(a.style.zIndex))[0]; if (top) { const t = top.querySelector('.titlebar h2'); t.tabIndex = -1; t.focus({ preventScroll: true }); } return opened > 0;
  }
  // ---- controls, drag with edge snapping, resize, keyboard -------------------------------
  const ghost = document.createElement('div'); ghost.className = 'snap-ghost'; ghost.hidden = true; main.append(ghost);
  function snapTarget(x, y) { if (narrow()) return null; const d = desk(); if (y <= 2) return 'max'; if (x <= 2) return 'left'; if (x >= d.width - 3) return 'right'; return null; }
  function showGhost(target) { if (!target) { ghost.hidden = true; return; } const d = desk(); const half = Math.round(d.width / 2); const g = target === 'max' ? { left: 0, top: 0, width: d.width, height: d.height } : { left: target === 'left' ? 0 : d.width - half, top: 0, width: half, height: d.height }; apply(ghost, g); ghost.hidden = false; }
  document.querySelectorAll('[data-open]').forEach((b) => b.addEventListener('click', () => openWindow(b.dataset.open, b)));
  windows.forEach((w) => {
    w.addEventListener('pointerdown', () => focusWindow(w));
    w.querySelector('[data-close]').addEventListener('click', () => closeWindow(w));
    w.querySelector('[data-half]').addEventListener('click', () => toggleHalf(w));
    w.querySelector('[data-max]').addEventListener('click', () => toggleMax(w));
    w.querySelector('[data-dock]').addEventListener('click', () => dock(w));
    const bar = w.querySelector('.titlebar'); bar.addEventListener('dblclick', (e) => { if (!e.target.closest('button')) toggleMax(w); });
    let drag = null;
    bar.addEventListener('pointerdown', (e) => { if (e.target.closest('button') || info(w).maximized) return; drag = { x: e.clientX - w.offsetLeft, y: e.clientY - w.offsetTop, target: null, moved: false }; bar.setPointerCapture(e.pointerId); e.preventDefault(); });
    bar.addEventListener('pointermove', (e) => {
      if (!drag) return; const s = info(w); const d = desk();
      // Dragging a snapped or half window un-snaps it under the pointer first.
      if ((s.snapped || s.half) && !drag.moved) { const ratio = (e.clientX - w.offsetLeft) / w.offsetWidth; s.snapped = null; s.half = false; w.classList.remove('snapped', 'half'); labels(w, false, false); apply(w, { ...s.normal, left: w.offsetLeft, top: w.offsetTop }); drag.x = Math.round(w.offsetWidth * ratio); drag.y = Math.min(drag.y, 20); }
      drag.moved = true;
      const left = Math.max(-w.offsetWidth + 80, Math.min(d.width - 80, e.clientX - drag.x)); const top = Math.max(0, Math.min(d.height - 44, e.clientY - drag.y));
      w.style.left = `${left}px`; w.style.top = `${top}px`;
      drag.target = snapTarget(e.clientX - d.left, e.clientY - d.top); showGhost(drag.target);
    });
    const endDrag = () => { if (!drag) return; const t = drag.target; drag = null; ghost.hidden = true; if (t === 'max') { info(w).normal = { ...info(w).normal, left: w.offsetLeft, top: w.offsetTop }; maximize(w); } else if (t) { info(w).normal = { ...info(w).normal, left: w.offsetLeft, top: w.offsetTop }; snap(w, t); } else { info(w).normal = geo(w); persistLayout(); } }; bar.addEventListener('pointerup', endDrag); bar.addEventListener('pointercancel', endDrag);
    const grip = w.querySelector('.grip'); let rs = null;
    if (grip) { grip.addEventListener('pointerdown', (e) => { if (info(w).maximized) return; rs = { x: e.clientX, y: e.clientY, w: w.offsetWidth, h: w.offsetHeight }; grip.setPointerCapture(e.pointerId); e.preventDefault(); }); grip.addEventListener('pointermove', (e) => { if (!rs) return; w.style.width = `${Math.max(280, rs.w + e.clientX - rs.x)}px`; w.style.height = `${Math.max(180, rs.h + e.clientY - rs.y)}px`; }); const endResize = () => { if (rs) { if (!info(w).half) info(w).normal = geo(w); rs = null; persistLayout(); } }; grip.addEventListener('pointerup', endResize); grip.addEventListener('pointercancel', endResize); }
    bar.querySelector('h2').addEventListener('keydown', (e) => {
      if (e.altKey) { if (e.key === 'ArrowLeft') snap(w, 'left'); else if (e.key === 'ArrowRight') snap(w, 'right'); else if (e.key === 'ArrowUp') maximize(w); else if (e.key === 'ArrowDown') restore(w); else return; e.preventDefault(); return; }
      if (info(w).maximized) return; const d = e.shiftKey ? 40 : 10;
      if (e.key === 'ArrowLeft') w.style.left = `${w.offsetLeft - d}px`; else if (e.key === 'ArrowRight') w.style.left = `${w.offsetLeft + d}px`; else if (e.key === 'ArrowUp') w.style.top = `${Math.max(0, w.offsetTop - d)}px`; else if (e.key === 'ArrowDown') w.style.top = `${w.offsetTop + d}px`; else return;
      info(w).normal = geo(w); persistLayout(); e.preventDefault();
    });
    w.addEventListener('keydown', (e) => { if (e.key === 'Escape') { e.stopPropagation(); closeWindow(w); } });
  });
  addEventListener('resize', () => windows.forEach((w) => { if (w.hidden) return; const s = info(w); if (s.maximized) maximize(w, true); else if (s.half) halfSize(w, true); else if (s.snapped) snap(w, s.snapped, true); }));
  // ---- desktop icons: click opens, drag moves (positions remembered) ----------------------
  const iconList = $('.icons'); let resetIcons = () => {};
  if (iconList) {
    const items = [...iconList.querySelectorAll('li')];
    const saved = (prefs.layout && store.icons) || {};
    let frozen = false;
    const freezeIcons = () => { if (frozen || narrow()) return; const base = iconList.getBoundingClientRect(); const spots = items.map((li) => { const r = li.getBoundingClientRect(); return { left: r.left - base.left, top: r.top - base.top }; }); items.forEach((li, i) => { li.style.position = 'absolute'; li.style.left = `${spots[i].left}px`; li.style.top = `${spots[i].top}px`; }); frozen = true; };
    const placeIcons = () => { if (narrow()) { frozen = false; items.forEach((li) => { li.style.position = ''; li.style.left = ''; li.style.top = ''; }); return; } if (!Object.keys(saved).length) return; frozen = false; items.forEach((li) => { li.style.position = ''; li.style.left = ''; li.style.top = ''; }); freezeIcons(); items.forEach((li) => { const p = saved[li.querySelector('button').dataset.open]; if (p) { li.style.left = `${p.left}px`; li.style.top = `${p.top}px`; } }); };
    placeIcons();
    items.forEach((li) => {
      const b = li.querySelector('button'); let d = null;
      b.addEventListener('pointerdown', (e) => { if (narrow()) return; const r = li.getBoundingClientRect(); const base = iconList.getBoundingClientRect(); d = { sx: e.clientX, sy: e.clientY, ox: r.left - base.left, oy: r.top - base.top, moved: false, id: e.pointerId }; });
      b.addEventListener('pointermove', (e) => { if (!d) return; const dx = e.clientX - d.sx; const dy = e.clientY - d.sy; if (!d.moved && Math.hypot(dx, dy) < 6) return; if (!d.moved) { d.moved = true; freezeIcons(); b.setPointerCapture(d.id); b.classList.add('dragging'); } const dk = desk(); li.style.left = `${Math.max(0, Math.min(dk.width - li.offsetWidth - 14, d.ox + dx))}px`; li.style.top = `${Math.max(0, Math.min(dk.height - li.offsetHeight - 14, d.oy + dy))}px`; });
      const end = (e) => { if (!d) return; const moved = d.moved; d = null; b.classList.remove('dragging'); if (moved) { saved[b.dataset.open] = { left: li.offsetLeft, top: li.offsetTop }; store.icons = saved; save(); e.preventDefault(); b.addEventListener('click', (c) => c.stopImmediatePropagation(), { capture: true, once: true }); } };
      b.addEventListener('pointerup', end); b.addEventListener('pointercancel', end);
    });
    addEventListener('resize', placeIcons);
    resetIcons = () => { Object.keys(saved).forEach((k) => delete saved[k]); frozen = false; items.forEach((li) => { li.style.position = ''; li.style.left = ''; li.style.top = ''; }); };
  }
  // ---- Desktop menu ------------------------------------------------------------------------
  const menuBtn = $('#desk-menu'); const menuList = $('#desk-menu-list');
  function setMenu(open) { menuList.hidden = !open; menuBtn.setAttribute('aria-expanded', String(open)); if (open) menuList.querySelector('button').focus(); }
  if (menuBtn) {
    menuBtn.addEventListener('click', () => setMenu(menuList.hidden));
    document.addEventListener('pointerdown', (e) => { if (!menuList.hidden && !e.target.closest('.menu-wrap')) setMenu(false); });
    menuList.addEventListener('keydown', (e) => { const items = [...menuList.querySelectorAll('button')]; const i = items.indexOf(document.activeElement); if (e.key === 'Escape') { setMenu(false); menuBtn.focus(); } else if (e.key === 'ArrowDown') { items[(i + 1) % items.length].focus(); e.preventDefault(); } else if (e.key === 'ArrowUp') { items[(i - 1 + items.length) % items.length].focus(); e.preventDefault(); } });
    menuList.addEventListener('click', (e) => {
      const b = e.target.closest('[data-act]'); if (!b) return; const act = b.dataset.act; setMenu(false); menuBtn.focus();
      if (act === 'tidy') tidy(); else if (act === 'closeall') closeAll(); else if (act === 'saver') startSaver(); else if (act === 'keys') openWindow('keys', menuBtn); else if (act === 'privacy') openWindow('privacy', menuBtn);
      else if (act === 'crt') setCRT(!prefs.crt); else if (act === 'reset') { prefs.layout = true; prefs.crt = false; delete store.windows; delete store.icons; closeAll(); state.clear(); windows.forEach((x) => x.classList.remove('maximized', 'half', 'snapped')); resetIcons(); setCRT(false); cascade = 0; openWindow('about', menuBtn); save(); }
    });
  }
  function setCRT(on) { prefs.crt = on; document.documentElement.classList.toggle('crt', on); const b = menuList && menuList.querySelector('[data-act=crt]'); if (b) b.setAttribute('aria-checked', String(on)); save(); }
  setCRT(!!prefs.crt);
  // ---- Privacy window --------------------------------------------------------------------
  const diagSwitch = $('#priv-diag'); const layoutSwitch = $('#priv-layout'); const countsEl = $('#priv-counts');
  function renderCounts() { if (!countsEl) return; if (!prefs.diagnostics) { countsEl.textContent = 'Counters are off.'; return; } const c = store.counts || {}; const rows = Object.entries(c).sort((a, b) => b[1] - a[1]).map(([k, v]) => `${k} ×${v}`); countsEl.textContent = rows.length ? `Opened in this browser: ${rows.join(', ')}. Not sent anywhere.` : 'Counting from now. Nothing opened yet.'; }
  function syncSwitches() { if (diagSwitch) diagSwitch.setAttribute('aria-checked', String(!!prefs.diagnostics)); if (layoutSwitch) layoutSwitch.setAttribute('aria-checked', String(!!prefs.layout)); renderCounts(); }
  if (diagSwitch) diagSwitch.addEventListener('click', () => { prefs.diagnostics = !prefs.diagnostics; if (!prefs.diagnostics) delete store.counts; syncSwitches(); save(); });
  if (layoutSwitch) layoutSwitch.addEventListener('click', () => { prefs.layout = !prefs.layout; if (!prefs.layout) { delete store.windows; delete store.icons; } else persistLayout(); syncSwitches(); save(); });
  if ($('#priv-forget')) $('#priv-forget').addEventListener('click', () => { forgetAll(); prefs.layout = true; prefs.diagnostics = false; prefs.crt = false; setCRT(false); syncSwitches(); try { localStorage.removeItem(KEY); } catch (_) { /* ignore */ } $('#priv-forget-status').textContent = 'Cleared: saved choices, window layout, icon places, counters and the splash flag were removed from this browser. The splash shows again on your next visit.'; });
  syncSwitches();
  // ---- screensaver: bouncing mark after 2 minutes idle (not with reduced motion) -----------
  const saver = $('#saver'); const mark = $('#saver-mark'); let idleTimer = null; let saverRaf = null; let lastFocus = null;
  const IDLE_MS = 120000;
  function armIdle() { if (reduced || !saver) return; clearTimeout(idleTimer); if (saver.hidden) idleTimer = setTimeout(startSaver, IDLE_MS); }
  function startSaver() { if (!saver || !saver.hidden) return; lastFocus = document.activeElement; saver.hidden = false; $('#saver-back').focus({ preventScroll: true }); let x = 40; let y = 40; let vx = 2.2; let vy = 1.7; let last = performance.now(); const stepSaver = (t) => { if (saver.hidden) return; const dt = Math.min(48, t - last) / 16; last = t; const W = innerWidth - 96; const H = innerHeight - 96; x += vx * dt; y += vy * dt; if (x <= 0 || x >= W) { vx = -vx; x = Math.max(0, Math.min(W, x)); } if (y <= 0 || y >= H) { vy = -vy; y = Math.max(0, Math.min(H, y)); } mark.style.transform = `translate(${x}px, ${y}px)`; saverRaf = requestAnimationFrame(stepSaver); }; if (!reduced) saverRaf = requestAnimationFrame(stepSaver); else mark.style.transform = 'translate(40px, 40px)'; }
  function stopSaver() { if (!saver || saver.hidden) return; saver.hidden = true; cancelAnimationFrame(saverRaf); if (lastFocus && document.contains(lastFocus)) lastFocus.focus({ preventScroll: true }); else main.focus({ preventScroll: true }); armIdle(); }
  if (saver) { ['pointerdown', 'pointermove', 'keydown', 'touchstart', 'wheel'].forEach((ev) => document.addEventListener(ev, (e) => { if (!saver.hidden) { if (ev === 'pointermove') return; if (ev === 'keydown' || ev === 'pointerdown') e.preventDefault(); stopSaver(); return; } armIdle(); }, { passive: ev !== 'keydown' && ev !== 'pointerdown' })); $('#saver-back').addEventListener('click', stopSaver); armIdle(); }
  // ---- jukebox ---------------------------------------------------------------------------
  const list = $('#juke-list'); const now = $('#juke-now'); const playBtn = $('#juke-play'); const loopBtn = $('#juke-loop'); const scope = $('#juke-scope');
  let tracks = []; let index = -1; let audio = null; let ctx = null; let analyser = null; let raf = null;
  const credit = (t) => `${t.title} · ${t.author} · ${t.license}`;
  function renderList() { list.replaceChildren(); tracks.forEach((t, i) => { const li = document.createElement('li'); if (i === index) li.className = 'playing'; const b = document.createElement('button'); b.type = 'button'; b.textContent = i === index && audio && !audio.paused ? '❚❚' : '▶'; b.setAttribute('aria-label', `Play ${t.title}`); b.addEventListener('click', () => (i === index && audio && !audio.paused ? pause() : play(i))); const m = document.createElement('div'); m.className = 'meta'; const title = document.createElement('b'); title.textContent = t.title; const sub = document.createElement('span'); sub.textContent = `${t.category} · ${t.duration}s · ${t.author} (${t.license})`; m.append(title, sub); li.append(b, m); list.append(li); }); }
  function draw() { if (!analyser) return; const data = new Uint8Array(analyser.frequencyBinCount); analyser.getByteFrequencyData(data); const c = scope.getContext('2d'); c.fillStyle = '#101011'; c.fillRect(0, 0, scope.width, scope.height); const bars = 40; const w = scope.width / bars; for (let i = 0; i < bars; i++) { const v = data[Math.floor(i * data.length / bars / 2)] / 255; const h = Math.max(2, v * scope.height); c.fillStyle = i % 5 === 4 ? '#ff454c' : '#efeae0'; c.fillRect(i * w + 1, scope.height - h, w - 2, h); } raf = requestAnimationFrame(draw); }
  function ensureAudio() { if (audio) return; audio = new Audio(); audio.preload = 'auto'; audio.addEventListener('ended', () => { if (loopBtn.getAttribute('aria-pressed') === 'true') play((index + 1) % tracks.length); else { playBtn.textContent = '▶'; playBtn.setAttribute('aria-pressed', 'false'); renderList(); } }); try { ctx = new (window.AudioContext || window.webkitAudioContext)(); const src = ctx.createMediaElementSource(audio); analyser = ctx.createAnalyser(); analyser.fftSize = 256; src.connect(analyser); analyser.connect(ctx.destination); } catch (_) { analyser = null; } }
  async function play(i) { if (!tracks.length) return; ensureAudio(); if (i !== index) { index = i; audio.src = tracks[i].file; } try { if (ctx && ctx.state === 'suspended') await ctx.resume(); await audio.play(); now.textContent = `Now playing: ${credit(tracks[index])}`; playBtn.textContent = '❚❚'; playBtn.setAttribute('aria-pressed', 'true'); if (analyser && !reduced) { cancelAnimationFrame(raf); draw(); } } catch (error) { now.textContent = `Could not play ${tracks[index].title}: ${error.message}`; } renderList(); }
  function pause() { if (!audio) return; audio.pause(); playBtn.textContent = '▶'; playBtn.setAttribute('aria-pressed', 'false'); cancelAnimationFrame(raf); now.textContent = index >= 0 ? `Paused: ${credit(tracks[index])}` : now.textContent; renderList(); }
  playBtn.addEventListener('click', () => (audio && !audio.paused ? pause() : play(index < 0 ? 0 : index)));
  $('#juke-next').addEventListener('click', () => play((index + 1 + tracks.length) % tracks.length));
  $('#juke-prev').addEventListener('click', () => play((index - 1 + tracks.length) % tracks.length));
  loopBtn.addEventListener('click', () => loopBtn.setAttribute('aria-pressed', String(loopBtn.getAttribute('aria-pressed') !== 'true')));
  fetch('sounds/credits.json').then((r) => r.json()).then((d) => { tracks = d.sounds; renderList(); }).catch(() => { now.textContent = 'The jukebox list could not be loaded (open this page from a web server, not file://).'; });
  // ---- screens ---------------------------------------------------------------------------
  const shots = [['splash', 'Splash'], ['library', 'Project library'], ['new-project', 'New Animation'], ['canvas', 'Canvas'], ['first-stroke', 'First stroke'], ['brush-popup', 'Brush options'], ['color-picker', 'Colour'], ['lasso', 'Lasso'], ['selection-handles', 'Selection handles'], ['layers', 'Layers'], ['layer-options', 'Layer options'], ['frame-strip', 'Frame strip'], ['studio-menu', 'Studio menu'], ['sound-library', 'Sound Library'], ['audio-timeline', 'Audio timeline'], ['rotoscope', 'Rotoscope'], ['spatter-ai', 'Spatter'], ['export-mp4', 'Export MP4'], ['export-ready', 'Export ready'], ['welcome', 'Welcome']];
  const grid = $('#shots-grid'); const big = $('#shot-big');
  shots.forEach(([name, label]) => { const b = document.createElement('button'); b.type = 'button'; const img = document.createElement('img'); img.src = `screens/${name}.webp`; img.width = 480; img.height = 1044; img.loading = 'lazy'; img.alt = label; b.append(img); b.addEventListener('click', () => { big.hidden = false; big.querySelector('img').src = `screens/${name}.webp`; big.querySelector('img').alt = label; big.querySelector('figcaption').textContent = `${label} · simulator capture`; }); grid.append(b); });
  // ---- clips -----------------------------------------------------------------------------
  const clips = [['create-project', 'Create a project'], ['draw-and-layers', 'Draw, layers, timeline'], ['sound-library', 'Sound Library'], ['brush-and-colour', 'Brush, colour, dropper'], ['lasso-and-spatter', 'Lasso, then Spatter'], ['rotoscope', 'Rotoscope reference'], ['export-png', 'Export PNG']];
  const select = $('#clip-select'); const video = $('#clip-video');
  clips.forEach(([name, label]) => { const o = document.createElement('option'); o.value = name; o.textContent = label; select.append(o); });
  const loadClip = () => { video.pause(); video.poster = `clips/${select.value}.webp`; video.src = `clips/${select.value}.mp4`; };
  select.addEventListener('change', loadClip); loadClip();
  // Deep links: index.html#open=store opens that window after boot.
  const wanted = new URLSearchParams(location.hash.replace(/^#/, '')).get('open');
  if (wanted) { const tryOpen = () => (booted ? openWindow(wanted) : setTimeout(tryOpen, 200)); tryOpen(); }
  updateStatus();
})();
