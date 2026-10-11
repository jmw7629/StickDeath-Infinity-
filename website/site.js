'use strict';
(() => {
  const menu = document.querySelector('.menu');
  const nav = document.querySelector('#navigation');
  const compact = matchMedia('(max-width:580px)');
  function layoutNav() { menu.hidden = !compact.matches; nav.hidden = compact.matches && menu.getAttribute('aria-expanded') !== 'true'; }
  menu.addEventListener('click', () => { menu.setAttribute('aria-expanded', String(menu.getAttribute('aria-expanded') !== 'true')); layoutNav(); });
  nav.addEventListener('click', event => { if (event.target.closest('a') && compact.matches) { menu.setAttribute('aria-expanded','false'); layoutNav(); } });
  document.addEventListener('keydown', event => { if (event.key === 'Escape' && compact.matches && !nav.hidden) { menu.setAttribute('aria-expanded','false'); layoutNav(); menu.focus(); } });
  compact.addEventListener('change', layoutNav); layoutNav();
  const input = document.querySelector('#query');
  const results = document.querySelector('#help-results');
  const count = document.querySelector('#help-count');
  const filters = [...document.querySelectorAll('[data-filter]')];
  let category = 'all';
  const articles = window.STUDIO_HELP || [];
  function node(tag, text, className) { const element = document.createElement(tag); element.textContent = text; if(className) element.className = className; return element; }
  function render() {
    const tokens = input.value.trim().toLocaleLowerCase().split(/\s+/).filter(Boolean);
    const matches = articles.filter(article => (category === 'all' || article.category === category) && tokens.every(token => [article.title,article.platform,article.terms,...article.steps,article.note].join(' ').toLocaleLowerCase().includes(token)));
    results.replaceChildren();
    matches.forEach(article => {
      const details = document.createElement('details'); details.id = `article-${article.id}`;
      details.append(node('summary',article.title));
      const answer = node('div','','answer'); answer.append(node('p',article.platform,'eyebrow'));
      const steps = document.createElement('ol'); article.steps.forEach(step => steps.append(node('li',step))); answer.append(steps,node('p',article.note),node('p','Source: native Studio and Android foundation source · Editorial date: October 9, 2026. Prerelease guidance; not a runtime verification receipt.','source'));
      const permalink = node('a','Link to this topic'); permalink.href = `#help/${article.id}`;
      answer.append(permalink);
      details.append(answer); results.append(details);
    });
    count.textContent = `${matches.length} ${matches.length === 1 ? 'topic' : 'topics'}${tokens.length ? ' found' : ''}.`;
    if (!matches.length) results.append(node('p','No matching topic. Try fewer words, choose All topics, or prepare a local problem summary below.'));
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
