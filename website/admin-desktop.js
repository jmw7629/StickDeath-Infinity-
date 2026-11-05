'use strict';
/* Layout only. Authentication, RPCs, validation and sensitive confirmations stay in
 * admin.js. Nothing here reads form values, uses storage or sends a request. */
(() => {
  const workspace = document.getElementById('main');
  const consoleHost = document.getElementById('admin-console');
  const panelHost = document.getElementById('admin-panels');
  const status = document.getElementById('admin-status');
  const accessBody = document.querySelector('#desktop-access > .desktop-window-body');
  const dashboardStatus = document.getElementById('desktop-dashboard-status');
  if (!workspace || !consoleHost || !panelHost || !status || !accessBody || !dashboardStatus) return;

  // Records contain live elements and layout metadata only. Removed RPC elements
  // are discarded, never cached, cloned, reattached or restored across sessions.
  const windows = new Map();
  const menus = Array.from(document.querySelectorAll('[data-desktop-menu]'));
  const windowList = document.getElementById('desktop-window-list');
  const reportMenu = document.getElementById('desktop-report-menu');
  const announcer = document.getElementById('desktop-announcer');
  let activeKey = null;
  let stacking = 10;
  let signedIn = null;
  let drag = null;
  let resizeFrame = null;

  const announce = (text) => { if (announcer) announcer.textContent = text; };
  const closeMenus = () => { for (const menu of menus) menu.open = false; };
  const isPrivate = (record) => !record.element.hasAttribute('data-public-window');
  const isLive = (record) => record.element.isConnected && (!isPrivate(record) || consoleHost.contains(record.element))
    && (!record.dynamic || panelHost.contains(record.element));
  const isAvailable = (record) => isLive(record) && (!isPrivate(record) || !consoleHost.hidden);
  const visible = (record) => isAvailable(record) && record.open && !record.minimized;
  const clamp = (value, min, max) => Math.max(min, Math.min(max, value));

  function bounds() {
    return { width: Math.max(1, workspace.clientWidth), height: Math.max(1, workspace.clientHeight) };
  }
  function defaultGeometry(record, index = 0) {
    const area = bounds();
    const access = record.key === 'access';
    const dashboard = record.key === 'dashboard';
    return { x: Math.round(area.width * .055) + (index % 5) * 30,
      y: Math.round(area.height * .06) + (index % 4) * 25,
      width: access ? 550 : dashboard ? 620 : 680,
      height: access ? 620 : dashboard ? 510 : 650 };
  }
  function fitGeometry(geometry, maximized = false) {
    const area = bounds();
    const inset = area.width < 580 ? 6 : 12;
    const maxWidth = Math.max(1, area.width - inset * 2);
    const maxHeight = Math.max(1, area.height - inset * 2);
    if (maximized) return { x: inset, y: inset, width: maxWidth, height: maxHeight };
    const width = clamp(geometry.width, Math.min(320, maxWidth), maxWidth);
    const height = clamp(geometry.height, Math.min(240, maxHeight), maxHeight);
    return { x: clamp(geometry.x, inset, Math.max(inset, area.width - width - inset)),
      y: clamp(geometry.y, inset, Math.max(inset, area.height - height - inset)), width, height };
  }
  function applyGeometry(record) {
    record.geometry = fitGeometry(record.geometry, record.maximized);
    const { x, y, width, height } = record.geometry;
    Object.assign(record.element.style, { left: `${x}px`, top: `${y}px`, width: `${width}px`, height: `${height}px` });
    record.element.classList.toggle('is-maximized', record.maximized);
    const zoom = record.element.querySelector('[data-window-zoom]');
    if (zoom) {
      zoom.setAttribute('aria-pressed', String(record.maximized));
      zoom.setAttribute('aria-label', `${record.maximized ? 'Restore' : 'Maximize'} ${record.title}`);
    }
  }
  function addWindow(element, dynamic = false) {
    const key = element.dataset.desktopWindow;
    const heading = element.querySelector('.desktop-titlebar h2');
    if (!key || !heading) return;
    const record = { key, element, title: heading.textContent.trim(), dynamic, open: false,
      minimized: false, maximized: false, restoreGeometry: null, geometry: null, z: 0 };
    record.geometry = defaultGeometry(record, windows.size);
    element.setAttribute('role', 'region');
    heading.setAttribute('aria-describedby', 'desktop-window-help');
    element.hidden = true;
    windows.set(key, record);
    applyGeometry(record);
  }
  function refreshStacking() {
    if (stacking < 800) return;
    let next = 10;
    for (const record of Array.from(windows.values()).sort((a, b) => a.z - b.z)) {
      record.z = ++next; record.element.style.zIndex = String(record.z);
    }
    stacking = next;
  }
  function activate(record, focusHeading = false) {
    if (!visible(record)) return;
    if (activeKey !== record.key) {
      const previous = windows.get(activeKey);
      if (previous && isLive(previous)) previous.element.classList.remove('is-active');
      activeKey = record.key;
      refreshStacking(); record.z = ++stacking;
      record.element.style.zIndex = String(record.z);
      record.element.classList.add('is-active');
    }
    if (focusHeading) record.element.querySelector('.desktop-titlebar h2').focus({ preventScroll: true });
  }
  function renderWindowList() {
    if (!windowList) return;
    windowList.replaceChildren();
    for (const record of windows.values()) {
      if (!record.open || !isAvailable(record)) continue;
      const button = document.createElement('button'); button.type = 'button';
      button.dataset.openWindow = record.key;
      button.textContent = `${record.title}${record.minimized ? ' — minimized' : ''}`;
      windowList.append(button);
    }
    if (!windowList.childElementCount) {
      const text = document.createElement('p'); text.textContent = 'No open windows.'; windowList.append(text);
    }
  }
  function openWindow(key, focusHeading = true) {
    if (key === 'access' && !consoleHost.hidden) key = 'dashboard';
    const record = windows.get(key);
    if (!record || !isLive(record)) return;
    if (!isAvailable(record)) {
      announce('Sign in with an administrator account to open that subject.');
      openWindow('access', focusHeading); return;
    }
    record.open = true; record.minimized = false; record.element.hidden = false;
    applyGeometry(record); activate(record, focusHeading); renderWindowList();
  }
  function pauseMedia(record) {
    for (const media of record.element.querySelectorAll('video,audio')) media.pause();
  }
  function focusFallback() {
    const next = Array.from(windows.values()).filter(visible).sort((a, b) => b.z - a.z)[0];
    if (next) activate(next, true);
    else {
      activeKey = null;
      const summary = menus.find((menu) => menu.querySelector('#desktop-window-list'))?.querySelector('summary');
      if (summary) summary.focus();
    }
  }
  function hideWindow(record, minimize = false) {
    // Keep the real sign-in/status visible whenever the private console is hidden.
    if (!record || (record.key === 'access' && consoleHost.hidden)) return;
    const ownedFocus = record.element.contains(document.activeElement);
    pauseMedia(record);
    record.open = minimize; record.minimized = minimize; record.element.hidden = true;
    record.element.classList.remove('is-active');
    if (activeKey === record.key) activeKey = null;
    if (ownedFocus) focusFallback();
    renderWindowList(); announce(`${record.title} ${minimize ? 'minimized. Restore it from Window.' : 'closed. Reopen it from the menus.'}`);
  }
  function toggleMaximize(record) {
    if (!record || !visible(record)) return;
    if (record.maximized) {
      record.maximized = false;
      record.geometry = record.restoreGeometry || defaultGeometry(record);
      record.restoreGeometry = null;
    } else {
      record.restoreGeometry = { ...record.geometry };
      record.maximized = true;
    }
    applyGeometry(record); activate(record);
  }
  function endDrag() {
    if (!drag) return;
    const record = windows.get(drag.key);
    if (record && isLive(record)) record.element.classList.remove('is-dragging');
    const finished = drag; drag = null;
    try { if (finished.handle.hasPointerCapture(finished.pointerId)) finished.handle.releasePointerCapture(finished.pointerId); } catch (_) { /* Already released. */ }
  }

  function reconcileReports() {
    // admin.js owns replaceChildren() on #admin-panels. Do not keep removed data.
    for (const [key, record] of windows) {
      if (record.dynamic && !isLive(record)) {
        if (activeKey === key) activeKey = null;
        if (drag && drag.key === key) endDrag();
        windows.delete(key);
      }
    }
    Array.from(panelHost.children).forEach((element, index) => {
      if (element.tagName !== 'DETAILS' || element.dataset.desktopWindow) return;
      const summary = element.querySelector(':scope > summary');
      const answer = element.querySelector(':scope > .answer');
      if (!summary || !answer) return;
      const title = summary.textContent.trim();
      const key = `report-${index}`;
      const shell = document.createElement('section');
      shell.dataset.desktopWindow = key;
      shell.dataset.accent = ['blue', 'lilac', 'orange', 'lime'][index % 4];
      shell.id = `desktop-${key}`; shell.className = 'desktop-window'; element.open = true;
      const heading = document.createElement('h2'); heading.id = `desktop-${key}-title`; heading.tabIndex = -1;
      heading.textContent = title; shell.setAttribute('aria-labelledby', heading.id);
      // Keep the original details, summary, load button and answer together in
      // #admin-panels. A normal section provides reliable flex/scroll sizing.
      summary.hidden = true; summary.tabIndex = -1;
      const header = document.createElement('header'); header.className = 'desktop-titlebar'; header.dataset.windowHandle = '';
      const control = (action, label, symbol) => {
        const button = document.createElement('button'); button.type = 'button';
        button.className = `window-control window-${action}`;
        button.setAttribute(`data-window-${action}`, ''); button.setAttribute('aria-label', `${label} ${title}`);
        button.title = `${label} window`;
        const icon = document.createElement('span'); icon.setAttribute('aria-hidden', 'true'); icon.textContent = symbol;
        button.append(icon); return button;
      };
      const zoom = control('zoom', 'Maximize', '□'); zoom.setAttribute('aria-pressed', 'false');
      header.append(control('close', 'Close', '×'), heading, control('minimize', 'Minimize', '−'), zoom);
      const body = document.createElement('div'); body.className = 'desktop-window-body';
      element.replaceWith(shell); body.append(element); shell.append(header, body);
      addWindow(shell, true);
    });
    reportMenu.replaceChildren();
    for (const record of windows.values()) {
      if (!record.dynamic || !isAvailable(record)) continue;
      const button = document.createElement('button'); button.type = 'button'; button.dataset.openWindow = record.key;
      button.textContent = record.title; reportMenu.append(button);
    }
    if (!reportMenu.childElementCount) {
      const text = document.createElement('p');
      text.textContent = consoleHost.hidden ? 'Sign in to see available server reports.' : 'Reports appear after the permissions request completes. Refresh permissions to try again.';
      reportMenu.append(text);
    }
    renderWindowList();
  }
  function syncSession() {
    const nowSignedIn = !consoleHost.hidden;
    const changed = signedIn !== nowSignedIn;
    signedIn = nowSignedIn;
    document.body.classList.toggle('desktop-session-open', signedIn);
    document.getElementById('desktop-session-state').textContent = signedIn ? 'Session open' : 'Access locked';
    for (const link of document.querySelectorAll('#desktop-work-menu a,[data-private-menu]')) {
      link.setAttribute('aria-disabled', String(!signedIn));
    }
    // This is the original live status node, not a snapshot of server output.
    const statusParent = signedIn ? dashboardStatus : accessBody;
    if (status.parentElement !== statusParent) statusParent.prepend(status);
    const access = windows.get('access');
    if (access) {
      for (const button of access.element.querySelectorAll('[data-window-close],[data-window-minimize]')) button.disabled = true;
    }
    if (changed) {
      endDrag(); closeMenus(); activeKey = null;
      for (const record of windows.values()) {
        // Clear layout visibility across auth transitions. No private DOM is restored.
        record.open = false; record.minimized = false; record.element.hidden = true;
        record.element.classList.remove('is-active');
      }
      openWindow(signedIn ? 'dashboard' : 'access', false);
      if (document.activeElement && document.activeElement.closest('[data-desktop-window][hidden]')) {
        windows.get(signedIn ? 'dashboard' : 'access').element.querySelector('.desktop-titlebar h2').focus({ preventScroll: true });
      }
    }
    reconcileReports();
  }

  const keyboardHelp = document.createElement('p'); keyboardHelp.id = 'desktop-window-help'; keyboardHelp.className = 'sr-only';
  keyboardHelp.textContent = 'When a window title is focused, arrow keys move it; Shift moves farther. Control F6 cycles open windows. Alt Shift M minimizes; Alt Shift W closes. Reopen subjects from Work or Reports and minimized windows from Window.';
  workspace.append(keyboardHelp);
  document.body.classList.add('desktop-ready');
  for (const element of document.querySelectorAll('[data-desktop-window]')) addWindow(element);
  syncSession();

  document.addEventListener('click', (event) => {
    const target = event.target instanceof Element ? event.target : null;
    if (!target) return;
    const opener = target.closest('[data-open-window]');
    if (opener) { event.preventDefault(); openWindow(opener.dataset.openWindow); closeMenus(); return; }
    const element = target.closest('[data-desktop-window]');
    const record = element && windows.get(element.dataset.desktopWindow);
    if (target.closest('[data-window-close]')) { event.preventDefault(); hideWindow(record); return; }
    if (target.closest('[data-window-minimize]')) { event.preventDefault(); hideWindow(record, true); return; }
    if (target.closest('[data-window-zoom]')) { event.preventDefault(); toggleMaximize(record); return; }
    if (!target.closest('[data-desktop-menu]')) closeMenus();
  });
  workspace.addEventListener('pointerdown', (event) => {
    const target = event.target instanceof Element ? event.target : null;
    const element = target?.closest('[data-desktop-window]');
    const record = element && windows.get(element.dataset.desktopWindow);
    if (!record || !visible(record)) return;
    activate(record);
    const handle = target.closest('[data-window-handle]');
    if (!handle || target.closest('button,a,input,select,textarea,label') || event.button !== 0 || record.maximized) return;
    endDrag(); event.preventDefault();
    drag = { key: record.key, handle, pointerId: event.pointerId, startX: event.clientX, startY: event.clientY,
      x: record.geometry.x, y: record.geometry.y };
    record.element.classList.add('is-dragging');
    handle.setPointerCapture(event.pointerId);
  });
  workspace.addEventListener('pointermove', (event) => {
    if (!drag || event.pointerId !== drag.pointerId) return;
    const record = windows.get(drag.key);
    if (!record || !visible(record)) { endDrag(); return; }
    record.geometry = { ...record.geometry, x: drag.x + event.clientX - drag.startX, y: drag.y + event.clientY - drag.startY };
    applyGeometry(record);
  });
  workspace.addEventListener('pointerup', endDrag);
  workspace.addEventListener('pointercancel', endDrag);
  workspace.addEventListener('lostpointercapture', () => { if (drag) endDrag(); });
  window.addEventListener('blur', endDrag);
  workspace.addEventListener('dblclick', (event) => {
    const target = event.target instanceof Element ? event.target : null;
    if (!target?.closest('[data-window-handle]') || target.closest('button,a,input,select,textarea,label')) return;
    const element = target.closest('[data-desktop-window]');
    toggleMaximize(windows.get(element?.dataset.desktopWindow));
  });
  workspace.addEventListener('focusin', (event) => {
    const element = event.target.closest?.('[data-desktop-window]');
    if (element) { const record = windows.get(element.dataset.desktopWindow); if (record) activate(record); }
  });

  for (const menu of menus) {
    menu.addEventListener('toggle', () => {
      if (!menu.open) return;
      for (const other of menus) if (other !== menu) other.open = false;
    });
    menu.addEventListener('keydown', (event) => {
      const summary = menu.querySelector(':scope > summary');
      const items = Array.from(menu.querySelectorAll('.desktop-menu-popover a,.desktop-menu-popover button:not(:disabled)'));
      const index = items.indexOf(document.activeElement);
      if (event.key === 'Escape') { event.preventDefault(); menu.open = false; summary.focus(); return; }
      if (event.key === 'ArrowLeft' || event.key === 'ArrowRight') {
        event.preventDefault();
        const step = event.key === 'ArrowRight' ? 1 : -1;
        const next = menus[(menus.indexOf(menu) + step + menus.length) % menus.length];
        const wasOpen = menu.open; closeMenus(); next.open = wasOpen; next.querySelector('summary').focus(); return;
      }
      if (event.key === 'ArrowDown' || event.key === 'ArrowUp' || event.key === 'Home' || event.key === 'End') {
        event.preventDefault(); menu.open = true;
        if (!items.length) return;
        const next = event.key === 'Home' ? 0 : event.key === 'End' ? items.length - 1
          : event.key === 'ArrowDown' ? (index + 1) % items.length : index < 0 ? items.length - 1 : (index - 1 + items.length) % items.length;
        items[next].focus();
      }
    });
  }
  document.addEventListener('keydown', (event) => {
    if (event.ctrlKey && event.key === 'F6') {
      const available = Array.from(windows.values()).filter(visible);
      if (!available.length) return;
      event.preventDefault();
      const index = available.findIndex((record) => record.key === activeKey);
      activate(available[(index + (event.shiftKey ? -1 : 1) + available.length) % available.length], true); return;
    }
    const active = windows.get(activeKey);
    if (event.altKey && event.shiftKey && (event.key.toLowerCase() === 'm' || event.key.toLowerCase() === 'w')) {
      if (!active || !visible(active)) return;
      event.preventDefault(); hideWindow(active, event.key.toLowerCase() === 'm'); return;
    }
    const target = event.target instanceof Element ? event.target : null;
    if (!active || !target?.matches('.desktop-titlebar h2') || active.maximized || !visible(active)) return;
    const directions = { ArrowLeft: [-1, 0], ArrowRight: [1, 0], ArrowUp: [0, -1], ArrowDown: [0, 1] };
    const direction = directions[event.key];
    if (!direction) return;
    event.preventDefault(); const step = event.shiftKey ? 48 : 16;
    active.geometry = { ...active.geometry, x: active.geometry.x + direction[0] * step, y: active.geometry.y + direction[1] * step };
    applyGeometry(active);
  });
  document.getElementById('desktop-cascade').addEventListener('click', () => {
    let index = 0;
    for (const record of windows.values()) {
      if (!visible(record)) continue;
      record.maximized = false; record.restoreGeometry = null;
      record.geometry = defaultGeometry(record, index++); applyGeometry(record); activate(record);
    }
    closeMenus(); focusFallback(); announce('Open windows cascaded.');
  });
  document.getElementById('desktop-reset-layout').addEventListener('click', () => {
    let index = 0;
    for (const record of windows.values()) {
      record.maximized = false; record.restoreGeometry = null;
      record.geometry = defaultGeometry(record, index++); applyGeometry(record);
    }
    closeMenus(); focusFallback(); announce('Window positions reset. Form contents were not changed.');
  });
  document.getElementById('desktop-keyboard-help').addEventListener('click', () => {
    closeMenus(); openWindow('about'); announce(keyboardHelp.textContent);
    const body = windows.get('about').element.querySelector('.desktop-window-body');
    if (!document.getElementById('desktop-visible-shortcuts')) {
      const help = document.createElement('p'); help.id = 'desktop-visible-shortcuts'; help.className = 'note'; help.textContent = keyboardHelp.textContent;
      body.prepend(help);
    }
    body.scrollTop = 0;
  });
  function resizeWindows() {
    if (resizeFrame !== null) return;
    resizeFrame = requestAnimationFrame(() => {
      resizeFrame = null; endDrag();
      for (const record of windows.values()) if (isLive(record)) applyGeometry(record);
    });
  }
  window.addEventListener('resize', resizeWindows);
  if (window.visualViewport) window.visualViewport.addEventListener('resize', resizeWindows);
  new MutationObserver(syncSession).observe(consoleHost, { attributes: true, attributeFilter: ['hidden'] });
  new MutationObserver(() => { reconcileReports(); }).observe(panelHost, { childList: true });
  const clock = document.getElementById('desktop-clock');
  function updateClock() {
    const now = new Date(); clock.dateTime = now.toISOString();
    clock.textContent = now.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
  }
  updateClock(); setInterval(updateClock, 30000);
})();
