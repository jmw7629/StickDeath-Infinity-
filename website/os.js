'use strict';
// StickDeath OS: boot sequence, menu bar clock and frame counter, draggable windows,
// jukebox with a real Web Audio scope, captures and clips. Memory only; no storage, no network
// beyond this origin.
(() => {
  const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const $ = (s, r = document) => r.querySelector(s);
  // ---- boot ----------------------------------------------------------------------------
  const boot = $('#boot'); const bar = $('#boot-bar'); const log = $('#boot-log');
  const lines = ['Loading brushes… 30 tools, 13 families', 'Mounting sound library… 2,127 sounds', 'Counting layers… 18 blend modes', 'Onion skin… on', 'Ready.'];
  let booted = false;
  function finishBoot() { if (booted) return; booted = true; boot.remove(); openWindow('about'); openWindow('juke'); $('#main').focus({ preventScroll: true }); }
  if (reduced) finishBoot();
  else { let i = 0; const step = () => { if (booted) return; if (i < lines.length) { log.textContent = lines.slice(Math.max(0, i - 2), i + 1).join('\n'); bar.style.width = `${Math.round(((i + 1) / lines.length) * 100)}%`; i += 1; setTimeout(step, 420); } else setTimeout(finishBoot, 350); }; step(); setTimeout(finishBoot, 4500); }
  $('#boot-skip').addEventListener('click', finishBoot);
  document.addEventListener('keydown', (e) => { if (!booted && (e.key === 'Enter' || e.key === ' ')) { e.preventDefault(); finishBoot(); } });
  // ---- menubar ----------------------------------------------------------------------------
  const clock = $('#os-clock'); const frame = $('#os-frame'); let f = 1;
  const tick = () => { clock.textContent = new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }); };
  tick(); setInterval(tick, 15000);
  if (!reduced) setInterval(() => { f = (f % 9999) + 1; frame.textContent = String(f).padStart(4, '0'); }, 1000 / 12);
  // ---- windows ---------------------------------------------------------------------------
  const windows = [...document.querySelectorAll('.window')]; let z = 10; let lastOpener = null;
  const status = $('#status-windows');
  const updateStatus = () => { const n = windows.filter((w) => !w.hidden).length; status.textContent = `${n} window${n === 1 ? '' : 's'} open`; };
  function focusWindow(w) { windows.forEach((x) => x.classList.remove('active')); w.classList.add('active'); w.style.zIndex = String(++z); }
  function openWindow(name, opener) {
    const w = document.getElementById(`win-${name}`); if (!w) return;
    const iframe = w.querySelector('iframe[data-src]'); if (iframe && !iframe.src) iframe.src = iframe.dataset.src;
    if (innerWidth > 700) { const r = w.getBoundingClientRect(); if (w.hidden) { const left = Math.min(parseInt(w.style.left, 10) || 40, Math.max(8, innerWidth - 320)); w.style.left = `${left}px`; } }
    w.hidden = false; focusWindow(w); lastOpener = opener || null; updateStatus();
    const first = w.querySelector('.titlebar h2'); first.tabIndex = -1; first.focus({ preventScroll: true });
  }
  function closeWindow(w) { w.hidden = true; w.classList.remove('active'); if (w.id === 'win-juke') pause(); if (w.id === 'win-clips') $('#clip-video').pause(); updateStatus(); const next = windows.filter((x) => !x.hidden).sort((a, b) => Number(b.style.zIndex) - Number(a.style.zIndex))[0]; if (next) focusWindow(next); if (lastOpener) lastOpener.focus(); }
  document.querySelectorAll('[data-open]').forEach((b) => b.addEventListener('click', () => openWindow(b.dataset.open, b)));
  windows.forEach((w) => {
    w.addEventListener('pointerdown', () => focusWindow(w));
    w.querySelector('[data-close]').addEventListener('click', () => closeWindow(w));
    const zoom = () => { if (w.dataset.zoomed) { Object.assign(w.style, JSON.parse(w.dataset.zoomed)); delete w.dataset.zoomed; } else { w.dataset.zoomed = JSON.stringify({ left: w.style.left, top: w.style.top, width: w.style.width, height: w.style.height }); Object.assign(w.style, { left: '8px', top: '8px', width: `${innerWidth - 16}px`, height: `${innerHeight - 90}px` }); } };
    w.querySelector('[data-zoom]').addEventListener('click', zoom);
    const bar = w.querySelector('.titlebar'); bar.addEventListener('dblclick', zoom);
    let drag = null;
    bar.addEventListener('pointerdown', (e) => { if (e.target.closest('button') || innerWidth <= 700) return; drag = { x: e.clientX - w.offsetLeft, y: e.clientY - w.offsetTop }; bar.setPointerCapture(e.pointerId); });
    bar.addEventListener('pointermove', (e) => { if (!drag) return; const left = Math.max(-w.offsetWidth + 80, Math.min(innerWidth - 80, e.clientX - drag.x)); const top = Math.max(0, Math.min(innerHeight - 110, e.clientY - drag.y)); w.style.left = `${left}px`; w.style.top = `${top}px`; });
    const end = () => { drag = null; }; bar.addEventListener('pointerup', end); bar.addEventListener('pointercancel', end);
    // Keyboard: arrows on the title move the window; Escape closes.
    bar.querySelector('h2').addEventListener('keydown', (e) => { const d = e.shiftKey ? 40 : 10; if (e.key === 'ArrowLeft') w.style.left = `${w.offsetLeft - d}px`; else if (e.key === 'ArrowRight') w.style.left = `${w.offsetLeft + d}px`; else if (e.key === 'ArrowUp') w.style.top = `${Math.max(0, w.offsetTop - d)}px`; else if (e.key === 'ArrowDown') w.style.top = `${w.offsetTop + d}px`; else return; e.preventDefault(); });
    w.addEventListener('keydown', (e) => { if (e.key === 'Escape') { e.stopPropagation(); closeWindow(w); } });
  });
  // ---- jukebox --------------------------------------------------------------------------
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
  // ---- screens ----------------------------------------------------------------------------
  const shots = [['splash', 'Splash'], ['library', 'Project library'], ['new-project', 'New Animation'], ['canvas', 'Canvas'], ['first-stroke', 'First stroke'], ['brush-popup', 'Brush options'], ['color-picker', 'Colour'], ['lasso', 'Lasso'], ['selection-handles', 'Selection handles'], ['layers', 'Layers'], ['layer-options', 'Layer options'], ['frame-strip', 'Frame strip'], ['studio-menu', 'Studio menu'], ['sound-library', 'Sound Library'], ['audio-timeline', 'Audio timeline'], ['rotoscope', 'Rotoscope'], ['spatter-ai', 'Spatter'], ['export-mp4', 'Export MP4'], ['export-ready', 'Export ready'], ['welcome', 'Welcome']];
  const grid = $('#shots-grid'); const big = $('#shot-big');
  shots.forEach(([name, label]) => { const b = document.createElement('button'); b.type = 'button'; const img = document.createElement('img'); img.src = `screens/${name}.webp`; img.width = 480; img.height = 1044; img.loading = 'lazy'; img.alt = label; b.append(img); b.addEventListener('click', () => { big.hidden = false; big.querySelector('img').src = `screens/${name}.webp`; big.querySelector('img').alt = label; big.querySelector('figcaption').textContent = `${label} · simulator capture`; }); grid.append(b); });
  // ---- clips ------------------------------------------------------------------------------
  const clips = [['create-project', 'Create a project'], ['draw-and-layers', 'Draw, layers, timeline'], ['sound-library', 'Sound Library'], ['brush-and-colour', 'Brush, colour, dropper'], ['lasso-and-spatter', 'Lasso, then Spatter'], ['rotoscope', 'Rotoscope reference'], ['export-png', 'Export PNG']];
  const select = $('#clip-select'); const video = $('#clip-video');
  clips.forEach(([name, label]) => { const o = document.createElement('option'); o.value = name; o.textContent = label; select.append(o); });
  const loadClip = () => { video.pause(); video.poster = `clips/${select.value}.webp`; video.src = `clips/${select.value}.mp4`; };
  select.addEventListener('change', loadClip); loadClip();
  updateStatus();
})();
