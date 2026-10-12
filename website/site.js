'use strict';
(() => {
  const menu = document.querySelector('.menu');
  const nav = document.querySelector('#navigation');
  const compact = matchMedia('(max-width:580px)');
  // Menu/nav visibility is CSS-driven per viewport (styles.css), so this script never changes layout on load.
  const expanded = () => menu.getAttribute('aria-expanded') === 'true';
  function setExpanded(open) { menu.setAttribute('aria-expanded', String(open)); nav.classList.toggle('open', open); }
  menu.addEventListener('click', () => setExpanded(!expanded()));
  nav.addEventListener('click', event => { if (event.target.closest('a') && compact.matches) setExpanded(false); });
  document.addEventListener('keydown', event => { if (event.key === 'Escape' && compact.matches && expanded()) { setExpanded(false); menu.focus(); } });
  compact.addEventListener('change', () => setExpanded(false));
  const input = document.querySelector('#query');
  const results = document.querySelector('#help-results');
  const count = document.querySelector('#help-count');
  const filters = [...document.querySelectorAll('[data-filter]')];
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
