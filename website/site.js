'use strict';
(() => {
  const menu = document.querySelector('.menu');
  const nav = document.querySelector('#navigation');
  const compact = matchMedia('(max-width:700px)');
  // Menu/nav visibility is CSS-driven per viewport (styles.css), so this script never changes layout on load.
  const expanded = () => menu.getAttribute('aria-expanded') === 'true';
  function setExpanded(open) { menu.setAttribute('aria-expanded', String(open)); nav.classList.toggle('open', open); }
  menu.addEventListener('click', () => setExpanded(!expanded()));
  nav.addEventListener('click', event => { if (event.target.closest('a') && compact.matches) setExpanded(false); });
  document.addEventListener('keydown', event => { if (event.key === 'Escape' && compact.matches && expanded()) { setExpanded(false); menu.focus(); } });
  compact.addEventListener('change', () => setExpanded(false));
  // Hero flipbook frame counter (index.html only). Fixed-width text, so no layout shift.
  const counter = document.querySelector('.flipbook .counter b');
  if (counter && !matchMedia('(prefers-reduced-motion: reduce)').matches) {
    const frames = Number(counter.dataset.frames) || 6; let frame = 0;
    setInterval(() => { frame = (frame + 1) % frames; counter.textContent = String(frame + 1).padStart(2, '0'); }, 200);
  }
  const input = document.querySelector('#query');
  const results = document.querySelector('#help-results');
  const count = document.querySelector('#help-count');
  const filters = [...document.querySelectorAll('[data-filter]')];
  if (!input || !results) return; // pages without the help desk stop here
  let category = 'all';
  // Articles come from help/articles.json through help/help-data.js and help.js.
  const articles = window.STUDIO_HELP || [];
  const STATUS_LABELS = {
    'source-implemented': 'Source-implemented · device verification deferred',
    'verified-on-device': 'Verified on device',
    'unavailable': 'Unavailable until configured'
  };
  function node(tag, text, className) { const element = document.createElement(tag); element.textContent = text; if(className) element.className = className; return element; }
  function render() {
    const tokens = input.value.trim().toLocaleLowerCase().split(/\s+/).filter(Boolean);
    const matches = articles.filter(article => (category === 'all' || article.category === category) && tokens.every(token => [article.title,article.platform,article.keywords,...article.steps,...article.limits].join(' ').toLocaleLowerCase().includes(token)));
    results.replaceChildren();
    matches.forEach(article => {
      const details = document.createElement('details'); details.id = `article-${article.id}`; details.dataset.category = article.category;
      details.append(node('summary',article.title));
      const answer = node('div','','answer');
      const head = node('p','','eyebrow'); head.append(node('span',article.platform), node('span',STATUS_LABELS[article.status] || article.status,`badge badge-${article.status}`)); answer.append(head);
      const steps = document.createElement('ol'); article.steps.forEach(step => steps.append(node('li',step))); answer.append(steps);
      if (article.limits.length) { answer.append(node('p','Limits','limits-title')); const limits = document.createElement('ul'); limits.className = 'limits'; article.limits.forEach(limit => limits.append(node('li',limit))); answer.append(limits); }
      const source = node('p','','source');
      source.append(`Reviewed ${article.reviewed} against guide revision ${article.guideRevision}. Current source behavior, not a runtime verification receipt. Sources: `);
      article.sources.forEach((path,index) => { if (index) source.append(', '); source.append(node('code',path)); });
      answer.append(source);
      const permalink = node('a','Link to this topic','permalink'); permalink.href = `#help/${article.id}`;
      answer.append(permalink);
      details.append(answer); results.append(details);
    });
    count.textContent = articles.length ? `${matches.length} ${matches.length === 1 ? 'topic' : 'topics'}${tokens.length ? ' found' : ''}.` : 'Help topics could not be loaded. Reload the page, or use the native Studio notes below.';
    if (articles.length && !matches.length) results.append(node('p','No matching topic. Try fewer words, choose All topics, or prepare a local problem summary below.'));
  }
  input.addEventListener('input',render);
  document.querySelector('#help-search').addEventListener('submit',event => {event.preventDefault();render();});
  document.querySelector('#help-search').addEventListener('reset',() => { input.value=''; category='all'; filters.forEach(button => button.setAttribute('aria-pressed',String(button.dataset.filter==='all'))); render(); input.focus(); });
  filters.forEach(button => button.addEventListener('click',() => { category=button.dataset.filter; filters.forEach(other=>other.setAttribute('aria-pressed',String(other===button)));render(); }));
  function routeHelp(hash = location.hash) {
    if (!hash.startsWith('#help/')) return;
    const article = articles.find(item => `#help/${item.id}` === hash);
    if (!article) return;
    category='all'; input.value=''; filters.forEach(button=>button.setAttribute('aria-pressed',String(button.dataset.filter==='all')));render();
    const details=document.querySelector(`#article-${article.id}`);details.open=true;details.scrollIntoView({block:'start'});details.querySelector('summary').focus({preventScroll:true});
  }
  window.addEventListener('hashchange',() => routeHelp());
  // A repeated link must reopen its topic even after search removed it from the DOM.
  // Browser history and modified-click behavior remain native for other links.
  document.addEventListener('click',event => {
    const link = event.target.closest('a[href^="#help/"]');
    if (!link || event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    if (link.hash === location.hash) { event.preventDefault(); routeHelp(link.hash); }
  });
  render();routeHelp();
  const supportForm = document.querySelector('#support-form');
  if (!supportForm) return;
  const supportStatus = document.querySelector('#support-status');
  const supportReview = document.querySelector('#support-review');
  const supportPreview = document.querySelector('#support-preview');
  const reportFields = ['platform','support-category','app-version','problem','expected','reproduce'];
  const downloads = new Map();
  let reportRevision = 0;
  let preparedInputs = null;
  const reportInputs = () => JSON.stringify(reportFields.map(id => document.getElementById(id).value));
  function discardPreview() {
    reportRevision += 1;
    preparedInputs = null;
    supportPreview.value = '';
    supportReview.hidden = true;
  }
  function releaseDownloads() {
    downloads.forEach((timer,url) => { clearTimeout(timer); URL.revokeObjectURL(url); });
    downloads.clear();
  }
  function reportEdited(event) {
    if (!reportFields.includes(event.target.id)) return;
    const hadPreview = !supportReview.hidden;
    discardPreview();
    supportStatus.textContent = hadPreview ? 'Report changed. Review the updated summary before downloading or copying.' : '';
  }
  supportForm.addEventListener('input', reportEdited);
  supportForm.addEventListener('change', reportEdited);
  function reportReady() {
    if (supportReview.hidden || !supportPreview.value) return false;
    if (preparedInputs !== reportInputs()) {
      discardPreview();
      supportStatus.textContent = 'Report changed. Review the updated summary before downloading or copying.';
      return false;
    }
    return true;
  }
  supportForm.addEventListener('reset', () => {
    discardPreview(); releaseDownloads();
    supportStatus.textContent = 'Report cleared from this page. Previously downloaded files and clipboard copies are unchanged. Nothing was submitted.';
  });
  supportForm.addEventListener('submit', event => {
    event.preventDefault();
    const limits = {'app-version':80,problem:2000,expected:1000,reproduce:2000};
    for (const [id,limit] of Object.entries(limits)) {
      const field = document.getElementById(id);
      if (field.value.trim().length > limit || (id === 'problem' && field.value.trim().length < 10)) {
        discardPreview();
        supportStatus.textContent = id === 'problem' ? 'Describe what happened in 10–2,000 characters.' : `Keep ${field.labels[0].textContent.toLowerCase()} to ${limit} characters.`;
        field.focus(); return;
      }
    }
    const value = id => document.getElementById(id).value.trim() || 'Not provided';
    reportRevision += 1;
    supportPreview.value = `StickDeath Infinity — local problem summary
Not submitted to a support service. No ticket has been created.

Platform: ${value('platform')}
Category: ${value('support-category')}
App version/build: ${value('app-version')}
Prepared: ${new Date().toISOString()}

What happened:
${value('problem')}

Expected result:
${value('expected')}

Steps to reproduce:
${value('reproduce')}

Before sending anywhere: remove passwords, payment data and private project contents.
`;
    preparedInputs = reportInputs();
    supportReview.hidden = false;
    supportStatus.textContent = 'Summary ready for your review. Nothing has been submitted, downloaded or copied.';
    supportPreview.focus();
  });
  document.querySelector('#support-download').addEventListener('click', () => {
    if (!reportReady()) return;
    let url, link;
    try {
      url = URL.createObjectURL(new Blob([supportPreview.value],{type:'text/plain;charset=utf-8'}));
      link = document.createElement('a'); link.href=url; link.download='stickdeath-problem-summary.txt';
      document.body.append(link); link.click();
      downloads.set(url,setTimeout(() => { URL.revokeObjectURL(url); downloads.delete(url); },30000));
      supportStatus.textContent = 'Download requested. Check your browser downloads. No report was submitted.';
    } catch (_) {
      if (url) URL.revokeObjectURL(url);
      supportStatus.textContent = 'This browser could not start a download. Copy the reviewed summary below instead. Nothing was submitted.';
      supportPreview.focus(); supportPreview.select();
    } finally { if (link) link.remove(); }
  });
  document.querySelector('#support-copy').addEventListener('click', async () => {
    if (!reportReady()) return;
    const revision = reportRevision;
    try {
      if (!navigator.clipboard || !navigator.clipboard.writeText) throw new Error('Clipboard unavailable');
      await navigator.clipboard.writeText(supportPreview.value);
      if (revision === reportRevision) supportStatus.textContent = 'Summary copied to your clipboard. No report was submitted.';
    } catch (_) {
      if (revision !== reportRevision) return;
      supportPreview.focus(); supportPreview.select();
      supportStatus.textContent = 'Automatic copying is unavailable. The summary is selected; use your device’s Copy command. Nothing was submitted.';
    }
  });
  window.addEventListener('pagehide', () => { releaseDownloads(); discardPreview(); supportForm.reset(); });
})();

// ---- Wave 2 (2026-10-14): splash, scroll reveal, hero scrub and speed, tabs -----------------
(() => {
  const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;
  // Splash on the home page: decorative, non-focusable, removed after its animation. Shown once
  // per browser session (sessionStorage is a per-viewer convenience; every read is guarded).
  const splash = document.querySelector('#splash');
  if (splash) {
    let seen = false; try { seen = sessionStorage.getItem('sdi-splash') === '1'; } catch (_) { seen = false; }
    if (reduced || seen) splash.remove();
    else { try { sessionStorage.setItem('sdi-splash', '1'); } catch (_) { /* ignore */ } splash.addEventListener('animationend', (e) => { if (e.target === splash) splash.remove(); }); setTimeout(() => splash.remove(), 2600); }
  }
  // Scroll reveal: without JavaScript everything is visible; with it, sections fade in as they
  // enter the viewport. Reduced motion skips the effect entirely.
  const targets = [...document.querySelectorAll('[data-reveal]')];
  if (targets.length && !reduced && 'IntersectionObserver' in window) {
    const io = new IntersectionObserver((entries) => entries.forEach((entry) => { if (entry.isIntersecting) { entry.target.classList.add('in'); io.unobserve(entry.target); } }), { rootMargin: '0px 0px -8% 0px', threshold: 0.08 });
    targets.forEach((el) => { const r = el.getBoundingClientRect(); if (r.top < innerHeight) { el.classList.add('reveal', 'in'); } else { el.classList.add('reveal'); io.observe(el); } });
  }
  // Hero flipbook: a speed slider sets the frame rate; dragging across the stage scrubs frames.
  const stage = document.querySelector('.flipbook .stage'); const fps = document.querySelector('#hero-fps'); const fpsOut = document.querySelector('#hero-fps-value');
  if (stage && fps) {
    const poses = [...stage.querySelectorAll('.pose')]; const counter = stage.querySelector('.counter b');
    const apply = () => { const v = Number(fps.value); const d = (poses.length / v).toFixed(3) + 's'; poses.forEach((p, i) => { p.style.animationDuration = d; p.style.animationDelay = (i / v).toFixed(3) + 's'; }); fpsOut.textContent = `${v} fps`; };
    fps.addEventListener('input', apply); apply();
    let resume = null;
    const scrub = (event) => { const r = stage.getBoundingClientRect(); const i = Math.max(0, Math.min(poses.length - 1, Math.floor((event.clientX - r.left) / r.width * poses.length))); stage.classList.add('manual'); poses.forEach((p, k) => p.classList.toggle('show', k === i)); if (counter) counter.textContent = String(i + 1).padStart(2, '0'); if (resume) clearTimeout(resume); resume = setTimeout(() => { stage.classList.remove('manual'); poses.forEach((p) => p.classList.remove('show')); }, 1800); };
    stage.addEventListener('pointerdown', (e) => { scrub(e); stage.setPointerCapture(e.pointerId); });
    stage.addEventListener('pointermove', (e) => { if (e.buttons) scrub(e); });
  }
  // Tabs: buttons with role=tab control panels by aria-controls.
  document.querySelectorAll('[role=tablist]').forEach((list) => {
    const tabs = [...list.querySelectorAll('[role=tab]')];
    const select = (tab) => { tabs.forEach((t) => { const on = t === tab; t.setAttribute('aria-selected', String(on)); t.tabIndex = on ? 0 : -1; const panel = document.getElementById(t.getAttribute('aria-controls')); if (panel) panel.hidden = !on; }); };
    tabs.forEach((tab, i) => { tab.addEventListener('click', () => select(tab)); tab.addEventListener('keydown', (e) => { if (e.key === 'ArrowRight' || e.key === 'ArrowLeft') { e.preventDefault(); const next = tabs[(i + (e.key === 'ArrowRight' ? 1 : tabs.length - 1)) % tabs.length]; select(next); next.focus(); } }); });
  });
})();
