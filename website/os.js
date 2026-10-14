'use strict';
// StickDeath desktop (index.html): boot sequence, menu bar, window manager with close /
// minimize / maximize / restore / drag / resize / keyboard, taskbar for minimized windows,
// jukebox with a real Web Audio scope, captures and clips. Memory only; same-origin only.
(() => {
  const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const $ = (s, r = document) => r.querySelector(s);
  const narrow = () => innerWidth <= 700;
  // ---- boot ------------------------------------------------------------------------------
  const boot = $('#boot'); const bar = $('#boot-bar'); const log = $('#boot-log');
  const lines = ['Loading brushes… 30 tools, 13 families', 'Mounting sound library… 2,127 sounds', 'Counting layers… 18 blend modes', 'Onion skin… on', 'Ready.'];
  let booted = false;
  function finishBoot() { if (booted) return; booted = true; if (boot) boot.remove(); openWindow('about'); $('#main').focus({ preventScroll: true }); }
  if (!boot || reduced) finishBoot();
  else { let i = 0; const step = () => { if (booted) return; if (i < lines.length) { log.textContent = lines.slice(Math.max(0, i - 2), i + 1).join('\n'); bar.style.width = `${Math.round(((i + 1) / lines.length) * 100)}%`; i += 1; setTimeout(step, 300); } else setTimeout(finishBoot, 250); }; step(); setTimeout(finishBoot, 3200); }
  if ($('#boot-skip')) $('#boot-skip').addEventListener('click', finishBoot);
  document.addEventListener('keydown', (e) => { if (!booted && (e.key === 'Enter' || e.key === ' ')) { e.preventDefault(); finishBoot(); } });
  // ---- menubar ---------------------------------------------------------------------------
  const clock = $('#os-clock'); const frame = $('#os-frame'); let f = 1;
  const tick = () => { clock.textContent = new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }); };
  tick(); setInterval(tick, 15000);
  if (!reduced) setInterval(() => { f = (f % 9999) + 1; frame.textContent = String(f).padStart(4, '0'); }, 1000 / 12);
  // ---- window manager --------------------------------------------------------------------
  const windows = [...document.querySelectorAll('.window')]; let z = 10; let cascade = 0;
  const taskbar = $('#taskbar'); const status = $('#status-windows');
  const state = new Map(); // id → { normal: {left, top, width, height}, maximized: bool, minimized: bool, opener }
  const desk = () => $('#main').getBoundingClientRect();
  function geo(w) { return { left: w.offsetLeft, top: w.offsetTop, width: w.offsetWidth, height: w.offsetHeight }; }
  function apply(w, g) { w.style.left = `${g.left}px`; w.style.top = `${g.top}px`; w.style.width = g.width ? `${g.width}px` : ''; w.style.height = g.height ? `${g.height}px` : ''; }
  function updateStatus() { const open = windows.filter((w) => !w.hidden).length; const docked = [...taskbar.children].length; status.textContent = `${open} window${open === 1 ? '' : 's'} open${docked ? `, ${docked} in the dock` : ''}`; }
  function focusWindow(w) { windows.forEach((x) => x.classList.remove('active')); w.classList.add('active'); w.style.zIndex = String(++z); }
  function info(w) { if (!state.has(w.id)) { const [l, t, wd, h] = (w.dataset.geo || '80,60,420,0').split(',').map(Number); state.set(w.id, { normal: { left: l, top: t, width: wd, height: h }, maximized: false, half: false, minimized: false, opener: null }); } return state.get(w.id); }
  function place(w) {
    const s = info(w); const d = desk();
    if (narrow()) { const g = { left: 8 + (cascade % 3) * 10, top: 8 + (cascade % 4) * 18, width: Math.round(d.width * 0.92), height: Math.round(d.height * 0.66) }; cascade += 1; s.normal = g; apply(w, g); return; }
    const g = { ...s.normal }; const offset = (cascade % 6) * 24; cascade += 1;
    g.left = Math.max(8, Math.min(g.left + offset, d.width - Math.min(g.width || 420, d.width) - 8)); g.top = Math.max(8, Math.min(g.top + offset, d.height - 160));
    if (g.width > d.width - 16) g.width = d.width - 16; if (g.height > d.height - 16) g.height = d.height - 16;
    s.normal = g; apply(w, g);
  }
  function openWindow(name, opener) {
    const w = document.getElementById(`win-${name}`); if (!w) return;
    const s = info(w);
    const iframe = w.querySelector('iframe[data-src]'); if (iframe && !iframe.src) iframe.src = iframe.dataset.src;
    if (s.minimized) restoreFromTaskbar(w); else if (w.hidden) { w.hidden = false; if (s.maximized) maximize(w, true); else if (s.half) halfSize(w, true); else place(w); }
    s.opener = opener || s.opener; focusWindow(w); updateStatus();
    const title = w.querySelector('.titlebar h2'); title.tabIndex = -1; title.focus({ preventScroll: true });
  }
  function closeWindow(w) { const s = info(w); w.hidden = true; w.classList.remove('active'); s.minimized = false; removeTask(w); if (w.id === 'win-juke') pause(); if (w.id === 'win-clips') $('#clip-video').pause(); updateStatus(); const next = windows.filter((x) => !x.hidden).sort((a, b) => Number(b.style.zIndex) - Number(a.style.zIndex))[0]; if (next) focusWindow(next); if (s.opener && document.contains(s.opener)) s.opener.focus(); }
  function maximize(w, silent) { const s = info(w); if (!s.maximized && !s.half && !silent) s.normal = geo(w); s.maximized = true; s.half = false; const d = desk(); apply(w, { left: 0, top: 0, width: d.width, height: d.height }); w.classList.add('maximized'); w.classList.remove('half'); w.querySelector('[data-max]').setAttribute('aria-label', `Restore ${w.querySelector('h2').textContent} to its normal size`); w.querySelector('[data-half]').setAttribute('aria-label', `Half size ${w.querySelector('h2').textContent}`); }
  function halfSize(w, silent) { const s = info(w); if (!s.maximized && !s.half && !silent) s.normal = geo(w); s.half = true; s.maximized = false; const d = desk(); const width = Math.round(d.width / 2); const height = Math.round(d.height / 2); apply(w, { left: Math.round((d.width - width) / 2), top: Math.round((d.height - height) / 2), width, height }); w.classList.add('half'); w.classList.remove('maximized'); w.querySelector('[data-half]').setAttribute('aria-label', `Restore ${w.querySelector('h2').textContent} to its normal size`); w.querySelector('[data-max]').setAttribute('aria-label', `Maximize ${w.querySelector('h2').textContent}`); }
  function restore(w) { const s = info(w); s.maximized = false; s.half = false; w.classList.remove('maximized', 'half'); apply(w, s.normal); w.querySelector('[data-max]').setAttribute('aria-label', `Maximize ${w.querySelector('h2').textContent}`); w.querySelector('[data-half]').setAttribute('aria-label', `Half size ${w.querySelector('h2').textContent}`); }
  function toggleMax(w) { (info(w).maximized ? restore : maximize)(w); focusWindow(w); }
  function toggleHalf(w) { (info(w).half ? restore : halfSize)(w); focusWindow(w); }
  // "Save to the desktop": the window leaves the screen and sits in the dock until tapped.
  function dock(w) { const s = info(w); s.minimized = true; w.hidden = true; w.classList.remove('active'); const b = document.createElement('button'); b.type = 'button'; b.dataset.task = w.id; b.textContent = w.querySelector('h2').textContent; b.setAttribute('aria-label', `Bring ${b.textContent} back from the dock`); b.addEventListener('click', () => openWindow(w.id.replace('win-', ''), b)); taskbar.append(b); updateStatus(); const next = windows.filter((x) => !x.hidden)[0]; if (next) focusWindow(next); b.focus(); }
  function removeTask(w) { const b = taskbar.querySelector(`[data-task="${w.id}"]`); if (b) b.remove(); }
  function restoreFromTaskbar(w) { const s = info(w); s.minimized = false; removeTask(w); w.hidden = false; if (s.maximized) maximize(w, true); else if (s.half) halfSize(w, true); else apply(w, s.normal); }
  document.querySelectorAll('[data-open]').forEach((b) => b.addEventListener('click', () => openWindow(b.dataset.open, b)));
  windows.forEach((w) => {
    w.addEventListener('pointerdown', () => focusWindow(w));
    w.querySelector('[data-close]').addEventListener('click', () => closeWindow(w));
    w.querySelector('[data-half]').addEventListener('click', () => toggleHalf(w));
    w.querySelector('[data-max]').addEventListener('click', () => toggleMax(w));
    w.querySelector('[data-dock]').addEventListener('click', () => dock(w));
    const bar = w.querySelector('.titlebar'); bar.addEventListener('dblclick', (e) => { if (!e.target.closest('button')) toggleMax(w); });
    let drag = null;
    bar.addEventListener('pointerdown', (e) => { if (e.target.closest('button') || info(w).maximized) return; drag = { x: e.clientX - w.offsetLeft, y: e.clientY - w.offsetTop }; bar.setPointerCapture(e.pointerId); e.preventDefault(); });
    bar.addEventListener('pointermove', (e) => { if (!drag) return; const d = desk(); const left = Math.max(-w.offsetWidth + 80, Math.min(d.width - 80, e.clientX - drag.x)); const top = Math.max(0, Math.min(d.height - 44, e.clientY - drag.y)); w.style.left = `${left}px`; w.style.top = `${top}px`; });
    const endDrag = () => { if (drag) { if (!info(w).half) info(w).normal = geo(w); drag = null; } }; bar.addEventListener('pointerup', endDrag); bar.addEventListener('pointercancel', endDrag);
    const grip = w.querySelector('.grip'); let rs = null;
    if (grip) { grip.addEventListener('pointerdown', (e) => { if (info(w).maximized) return; rs = { x: e.clientX, y: e.clientY, w: w.offsetWidth, h: w.offsetHeight }; grip.setPointerCapture(e.pointerId); e.preventDefault(); }); grip.addEventListener('pointermove', (e) => { if (!rs) return; w.style.width = `${Math.max(280, rs.w + e.clientX - rs.x)}px`; w.style.height = `${Math.max(180, rs.h + e.clientY - rs.y)}px`; }); const endResize = () => { if (rs) { if (!info(w).half) info(w).normal = geo(w); rs = null; } }; grip.addEventListener('pointerup', endResize); grip.addEventListener('pointercancel', endResize); }
    bar.querySelector('h2').addEventListener('keydown', (e) => { if (info(w).maximized) return; const d = e.shiftKey ? 40 : 10; if (e.key === 'ArrowLeft') w.style.left = `${w.offsetLeft - d}px`; else if (e.key === 'ArrowRight') w.style.left = `${w.offsetLeft + d}px`; else if (e.key === 'ArrowUp') w.style.top = `${Math.max(0, w.offsetTop - d)}px`; else if (e.key === 'ArrowDown') w.style.top = `${w.offsetTop + d}px`; else return; info(w).normal = geo(w); e.preventDefault(); });
    w.addEventListener('keydown', (e) => { if (e.key === 'Escape') { e.stopPropagation(); closeWindow(w); } });
  });
  addEventListener('resize', () => windows.forEach((w) => { if (w.hidden) return; if (info(w).maximized) maximize(w, true); else if (info(w).half) halfSize(w, true); }));
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
