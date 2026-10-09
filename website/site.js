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
      details.append(answer); results.append(details);
    });
    count.textContent = `${matches.length} ${matches.length === 1 ? 'topic' : 'topics'}${tokens.length ? ' found' : ''}.`;
    if (!matches.length) results.append(node('p','No matching topic. Try fewer words, choose All topics, or prepare a local problem summary below.'));
  }
  input.addEventListener('input',render);
  document.querySelector('#help-search').addEventListener('submit',event => {event.preventDefault();render();});
  document.querySelector('#help-search').addEventListener('reset',() => { input.value=''; category='all'; filters.forEach(button => button.setAttribute('aria-pressed',String(button.dataset.filter==='all'))); render(); input.focus(); });
  filters.forEach(button => button.addEventListener('click',() => { category=button.dataset.filter; filters.forEach(other=>other.setAttribute('aria-pressed',String(other===button)));render(); }));
  function routeHelp() {
    if (!location.hash.startsWith('#help/')) return;
    const article = articles.find(item => `#help/${item.id}` === location.hash);
    if (!article) return;
    category='all'; input.value=''; filters.forEach(button=>button.setAttribute('aria-pressed',String(button.dataset.filter==='all')));render();
    const details=document.querySelector(`#article-${article.id}`);details.open=true;details.scrollIntoView({block:'start'});details.querySelector('summary').focus({preventScroll:true});
  }
  window.addEventListener('hashchange',routeHelp);render();routeHelp();
  document.querySelector('#support-form').addEventListener('submit',event=>{
    event.preventDefault();
    const text=document.querySelector('#problem').value.trim();
    const status=document.querySelector('#support-status');
    if(text.length<10){status.textContent='Add at least 10 characters describing what happened.';document.querySelector('#problem').focus();return;}
    const report=`StickDeath Infinity — local problem summary\nNot submitted to a support service.\n\nPlatform: ${document.querySelector('#platform').value}\nCreated: ${new Date().toISOString()}\n\n${text}\n\nBefore sending anywhere: remove passwords, payment data and private project contents.\n`;
    try {
      const url=URL.createObjectURL(new Blob([report],{type:'text/plain;charset=utf-8'}));
      const link=document.createElement('a');link.href=url;link.download='stickdeath-problem-summary.txt';document.body.append(link);link.click();link.remove();
      setTimeout(()=>URL.revokeObjectURL(url),30000);
      status.textContent='Download requested. Check your browser downloads. No report was submitted.';
    } catch (_) {status.textContent='This browser could not start a download. Copy your description to a local note instead. Nothing was submitted.';}
  });
})();
