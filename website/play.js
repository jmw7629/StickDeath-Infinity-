'use strict';
// Browser flipbook toy for play.html. Everything happens in this page: frames are
// canvases in memory, nothing is stored or uploaded, and the only outputs are the
// files the visitor downloads (GIF or PNG spritesheet). This is a toy, not Studio.
(() => {
  const W = 360, H = 480, MAX_FRAMES = 12, MAX_UNDO = 24;
  const canvas = document.querySelector('#play-canvas');
  const onion = document.querySelector('#play-onion');
  const status = document.querySelector('#play-status');
  const bar = document.querySelector('#frames-bar');
  const fpsInput = document.querySelector('#play-fps');
  const fpsOut = document.querySelector('#play-fps-value');
  const sizeInput = document.querySelector('#play-size');
  const sizeOut = document.querySelector('#play-size-value');
  const colorInput = document.querySelector('#play-color');
  const onionToggle = document.querySelector('#play-onion-toggle');
  const playButton = document.querySelector('#play-toggle');
  const frameLabel = document.querySelector('#play-frame-label');
  if (!canvas) return;
  canvas.width = W; canvas.height = H; onion.width = W; onion.height = H;
  const ctx = canvas.getContext('2d'), octx = onion.getContext('2d');
  const PAPER = '#f3efe6';
  let frames = [], current = 0, tool = 'pen', color = '#101011', size = 6, playing = null, drawing = false, last = null;
  const reduced = matchMedia('(prefers-reduced-motion: reduce)');
  const blank = () => { const c = document.createElement('canvas'); c.width = W; c.height = H; const x = c.getContext('2d'); x.fillStyle = PAPER; x.fillRect(0, 0, W, H); return { canvas: c, undo: [] }; };
  const say = (text) => { status.textContent = text; };
  function snapshot(frame) { if (frame.undo.length >= MAX_UNDO) frame.undo.shift(); frame.undo.push(frame.canvas.getContext('2d').getImageData(0, 0, W, H)); }
  function show() {
    ctx.drawImage(frames[current].canvas, 0, 0);
    octx.clearRect(0, 0, W, H);
    if (onionToggle.getAttribute('aria-pressed') === 'true' && current > 0 && !playing) octx.drawImage(frames[current - 1].canvas, 0, 0);
    frameLabel.textContent = `Frame ${current + 1} of ${frames.length}`;
    renderBar();
  }
  function renderBar() {
    bar.replaceChildren();
    frames.forEach((frame, index) => {
      const button = document.createElement('button'); button.type = 'button'; button.setAttribute('aria-label', `Go to frame ${index + 1}`);
      if (index === current) button.setAttribute('aria-current', 'true');
      const thumb = document.createElement('canvas'); thumb.width = 48; thumb.height = 64; thumb.getContext('2d').drawImage(frame.canvas, 0, 0, 48, 64);
      const n = document.createElement('span'); n.textContent = String(index + 1).padStart(2, '0'); n.setAttribute('aria-hidden', 'true');
      button.append(thumb, n); button.addEventListener('click', () => { stop(); current = index; show(); });
      bar.append(button);
    });
  }
  function point(event) { const r = canvas.getBoundingClientRect(); return { x: (event.clientX - r.left) * W / r.width, y: (event.clientY - r.top) * H / r.height, p: event.pressure && event.pointerType === 'pen' ? event.pressure : 1 }; }
  function stroke(a, b) {
    const x = frames[current].canvas.getContext('2d');
    x.lineCap = 'round'; x.lineJoin = 'round';
    x.strokeStyle = tool === 'eraser' ? PAPER : color; x.lineWidth = (tool === 'eraser' ? size * 2.5 : size) * (0.5 + b.p * 0.5);
    x.beginPath(); x.moveTo(a.x, a.y); x.lineTo(b.x, b.y); x.stroke();
  }
  canvas.addEventListener('pointerdown', (event) => { if (playing) stop(); drawing = true; canvas.setPointerCapture(event.pointerId); snapshot(frames[current]); last = point(event); stroke(last, { ...last, x: last.x + 0.01 }); show(); });
  canvas.addEventListener('pointermove', (event) => { if (!drawing) return; const p = point(event); stroke(last, p); last = p; ctx.drawImage(frames[current].canvas, 0, 0); });
  const end = () => { if (!drawing) return; drawing = false; last = null; renderBar(); };
  canvas.addEventListener('pointerup', end); canvas.addEventListener('pointercancel', end); canvas.addEventListener('pointerleave', end);
  // Keyboard drawing: arrows move a cursor, Enter stamps a dot, so the toy is usable without a pointer.
  let cursor = { x: W / 2, y: H / 2 };
  canvas.addEventListener('keydown', (event) => {
    const step = event.shiftKey ? 24 : 8;
    if (event.key === 'ArrowLeft') cursor.x = Math.max(0, cursor.x - step); else if (event.key === 'ArrowRight') cursor.x = Math.min(W, cursor.x + step);
    else if (event.key === 'ArrowUp') cursor.y = Math.max(0, cursor.y - step); else if (event.key === 'ArrowDown') cursor.y = Math.min(H, cursor.y + step);
    else if (event.key === 'Enter' || event.key === ' ') { snapshot(frames[current]); stroke(cursor, { ...cursor, x: cursor.x + 0.01, p: 1 }); show(); say(`Mark at ${Math.round(cursor.x)}, ${Math.round(cursor.y)}.`); }
    else return;
    event.preventDefault();
  });
  document.querySelectorAll('[data-tool]').forEach((button) => button.addEventListener('click', () => { tool = button.dataset.tool; document.querySelectorAll('[data-tool]').forEach((b) => b.setAttribute('aria-pressed', String(b === button))); say(`${button.textContent.trim()} selected.`); }));
  document.querySelectorAll('[data-swatch]').forEach((button) => button.addEventListener('click', () => { color = button.dataset.swatch; colorInput.value = color; document.querySelectorAll('[data-swatch]').forEach((b) => b.setAttribute('aria-pressed', String(b === button))); }));
  colorInput.addEventListener('input', () => { color = colorInput.value; document.querySelectorAll('[data-swatch]').forEach((b) => b.setAttribute('aria-pressed', 'false')); });
  sizeInput.addEventListener('input', () => { size = Number(sizeInput.value); sizeOut.textContent = `${size} px`; });
  fpsInput.addEventListener('input', () => { fpsOut.textContent = `${fpsInput.value} fps`; if (playing) { stop(); play(); } });
  onionToggle.addEventListener('click', () => { onionToggle.setAttribute('aria-pressed', String(onionToggle.getAttribute('aria-pressed') !== 'true')); show(); });
  document.querySelector('#play-undo').addEventListener('click', () => { const frame = frames[current]; const data = frame.undo.pop(); if (!data) { say('Nothing to undo on this frame.'); return; } frame.canvas.getContext('2d').putImageData(data, 0, 0); show(); say('Undone.'); });
  document.querySelector('#play-clear').addEventListener('click', () => { snapshot(frames[current]); const x = frames[current].canvas.getContext('2d'); x.fillStyle = PAPER; x.fillRect(0, 0, W, H); show(); say('Frame cleared. Undo brings it back.'); });
  document.querySelector('#play-add').addEventListener('click', () => { if (frames.length >= MAX_FRAMES) { say(`This toy keeps ${MAX_FRAMES} frames at most.`); return; } stop(); frames.splice(current + 1, 0, blank()); current += 1; show(); say(`Added blank frame ${current + 1}.`); });
  document.querySelector('#play-duplicate').addEventListener('click', () => { if (frames.length >= MAX_FRAMES) { say(`This toy keeps ${MAX_FRAMES} frames at most.`); return; } stop(); const copy = blank(); copy.canvas.getContext('2d').drawImage(frames[current].canvas, 0, 0); frames.splice(current + 1, 0, copy); current += 1; show(); say(`Duplicated into frame ${current + 1}.`); });
  document.querySelector('#play-delete').addEventListener('click', () => { if (frames.length === 1) { say('Keep at least one frame.'); return; } stop(); frames.splice(current, 1); current = Math.min(current, frames.length - 1); show(); say('Frame removed.'); });
  document.querySelector('#play-prev').addEventListener('click', () => { stop(); current = (current - 1 + frames.length) % frames.length; show(); });
  document.querySelector('#play-next').addEventListener('click', () => { stop(); current = (current + 1) % frames.length; show(); });
  function play() {
    if (frames.length < 2) { say('Add a second frame to play.'); return; }
    if (reduced.matches) { say('Playback is paused because your system prefers reduced motion. Step through frames with Previous and Next.'); return; }
    playing = setInterval(() => { current = (current + 1) % frames.length; ctx.drawImage(frames[current].canvas, 0, 0); octx.clearRect(0, 0, W, H); frameLabel.textContent = `Frame ${current + 1} of ${frames.length}`; }, 1000 / Number(fpsInput.value));
    playButton.textContent = 'Stop'; playButton.setAttribute('aria-pressed', 'true');
  }
  function stop() { if (!playing) return; clearInterval(playing); playing = null; playButton.textContent = 'Play'; playButton.setAttribute('aria-pressed', 'false'); show(); }
  playButton.addEventListener('click', () => (playing ? stop() : play()));
  document.addEventListener('keydown', (event) => { if (event.target.matches('input,textarea,select,button,canvas')) return; if (event.key === ',') { stop(); current = (current - 1 + frames.length) % frames.length; show(); } else if (event.key === '.') { stop(); current = (current + 1) % frames.length; show(); } });
  // Downloads. Object URLs are revoked after the click so nothing lingers.
  function download(blob, name) { const url = URL.createObjectURL(blob); const link = document.createElement('a'); link.href = url; link.download = name; document.body.append(link); link.click(); link.remove(); setTimeout(() => URL.revokeObjectURL(url), 30000); }
  document.querySelector('#play-png').addEventListener('click', () => {
    const sheet = document.createElement('canvas'); sheet.width = W * frames.length; sheet.height = H; const x = sheet.getContext('2d');
    frames.forEach((frame, index) => x.drawImage(frame.canvas, index * W, 0));
    sheet.toBlob((blob) => { if (!blob) { say('This browser could not create the PNG.'); return; } download(blob, `stickdeath-flipbook-${frames.length}-frames.png`); say(`Spritesheet downloaded: ${frames.length} frames side by side, ${W}×${H} each.`); }, 'image/png');
  });
  document.querySelector('#play-gif').addEventListener('click', () => {
    try { const bytes = encodeGIF(frames.map((f) => f.canvas.getContext('2d').getImageData(0, 0, W, H).data), W, H, Math.round(100 / Number(fpsInput.value))); download(new Blob([bytes], { type: 'image/gif' }), `stickdeath-flipbook-${frames.length}-frames.gif`); say(`GIF downloaded: ${frames.length} frames at ${fpsInput.value} fps, looping.`); }
    catch (error) { say(`GIF export failed in this browser: ${error.message}`); }
  });
  // Minimal GIF89a writer: 6-level-per-channel palette (216 colours), LZW per frame, infinite loop.
  function encodeGIF(frameData, width, height, delayCentiseconds) {
    const palette = []; for (let r = 0; r < 6; r++) for (let g = 0; g < 6; g++) for (let b = 0; b < 6; b++) palette.push(r * 51, g * 51, b * 51);
    while (palette.length < 256 * 3) palette.push(0);
    const out = []; const byte = (v) => out.push(v & 255); const word = (v) => { byte(v); byte(v >> 8); };
    'GIF89a'.split('').forEach((c) => byte(c.charCodeAt(0))); word(width); word(height); byte(0xF7); byte(0); byte(0); palette.forEach(byte);
    byte(0x21); byte(0xFF); byte(11); 'NETSCAPE2.0'.split('').forEach((c) => byte(c.charCodeAt(0))); byte(3); byte(1); word(0); byte(0);
    const q = (v) => Math.round(v / 51);
    for (const data of frameData) {
      byte(0x21); byte(0xF9); byte(4); byte(0); word(delayCentiseconds); byte(0); byte(0);
      byte(0x2C); word(0); word(0); word(width); word(height); byte(0); byte(8);
      const indices = new Uint8Array(width * height);
      for (let i = 0, p = 0; i < data.length; i += 4, p++) indices[p] = q(data[i]) * 36 + q(data[i + 1]) * 6 + q(data[i + 2]);
      lzw(indices, out);
      byte(0);
    }
    byte(0x3B);
    return new Uint8Array(out);
  }
  function lzw(indices, out) {
    const CLEAR = 256, EOI = 257; let codeSize = 9, next = 258, dict = new Map();
    let buffer = 0, bits = 0; const block = [];
    const emit = (code) => { buffer |= code << bits; bits += codeSize; while (bits >= 8) { block.push(buffer & 255); buffer >>= 8; bits -= 8; if (block.length === 255) { out.push(255, ...block); block.length = 0; } } };
    emit(CLEAR);
    let prefix = indices[0];
    for (let i = 1; i < indices.length; i++) {
      const k = indices[i]; const key = prefix * 256 + k;
      if (dict.has(key)) { prefix = dict.get(key); continue; }
      emit(prefix);
      if (next < 4096) { dict.set(key, next++); if (next === (1 << codeSize) + 1 && codeSize < 12) codeSize++; }
      else { emit(CLEAR); dict = new Map(); next = 258; codeSize = 9; }
      prefix = k;
    }
    emit(prefix); emit(EOI);
    if (bits > 0) block.push(buffer & 255);
    if (block.length) out.push(block.length, ...block);
  }
  frames = [blank()]; sizeOut.textContent = `${size} px`; fpsOut.textContent = `${fpsInput.value} fps`; show();
  say('Draw on the paper, add a frame, draw the next pose, then press Play.');
})();
