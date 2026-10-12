'use strict';
// Help topics have one source: help/articles.json. Because fetch() of a local
// JSON file is blocked under file://, scripts/website/check_help.mjs validates
// the JSON against the Swift/Kotlin sources and embeds it as help/help-data.js
// (window.STUDIO_HELP_DATA). index.html loads help-data.js, then this file,
// then site.js. Edit articles.json, rerun the checker; never edit help-data.js.
(() => {
  const data = window.STUDIO_HELP_DATA;
  const valid = Boolean(data) && Array.isArray(data.articles) && data.articles.length > 0;
  const text = (value) => (typeof value === 'string' ? value : '');
  const list = (value) => (Array.isArray(value) ? value.filter((item) => typeof item === 'string') : []);
  window.STUDIO_HELP = valid ? data.articles.map((article) => ({
    id: text(article.id),
    category: text(article.category),
    platform: text(article.platform),
    title: text(article.title),
    keywords: list(article.keywords).join(' '),
    steps: list(article.steps),
    limits: list(article.limits),
    sources: list(article.sources),
    guideRevision: text(article.guideRevision),
    reviewed: text(article.reviewed),
    status: text(article.status)
  })).filter((article) => article.id && article.title && article.steps.length) : [];
  window.STUDIO_HELP_META = valid ? { guideRevision: text(data.guideRevision), statuses: data.statuses && typeof data.statuses === 'object' ? data.statuses : {} } : null;
})();
