// Single source for the website's public base URL and page list.
//
// The owner named the production address on 2026-10-14
// (https://stickdeathinfinity.com). Hosting and DNS for it are still owner
// actions (docs/WEBSITE_HOSTING.md); this constant only decides what the pages
// declare as their canonical origin. Change it here and run
// `node scripts/website/build_site.mjs`, which rewrites every absolute self-URL
// in website/*.html and regenerates robots.txt and sitemap.xml.
export const CANONICAL_BASE = 'https://stickdeathinfinity.com/';
export const SITE_NAME = 'StickDeath Infinity';

// indexable: listed in sitemap.xml and must carry rel=canonical.
// Non-indexable pages must carry <meta name="robots" content="noindex">.
// Policy drafts stay non-indexable until legal review and owner approval.
export const PAGES = [
  { file: 'index.html', indexable: true, canonicalPath: '' },
  { file: 'studio.html', indexable: true },
  { file: 'community.html', indexable: true },
  { file: 'screens.html', indexable: true },
  { file: 'play.html', indexable: true },
  { file: '404.html', indexable: false, reason: 'error page' },
  { file: 'account.html', indexable: false, reason: 'account page (config-gated shell)' },
  { file: 'admin.html', indexable: false, reason: 'command center shell (config-gated; server-authorized)' },
  { file: 'policies/terms-v1.html', indexable: false, reason: 'draft awaiting legal review' },
  { file: 'policies/privacy-v1.html', indexable: false, reason: 'draft awaiting legal review' },
  { file: 'policies/publishing-v1.html', indexable: false, reason: 'draft awaiting legal review' },
  { file: 'policies/attribution.html', indexable: false, reason: 'generated; indexable once the site is live and reviewed' }
];
