// Single source for the website's public base URL and page list.
//
// OWNER-GATED: the production domain is not verified in this repository
// (issue #269: no hosting, DNS or deployment configuration is present).
// `.invalid` is a reserved top-level domain that can never resolve, so the
// placeholder cannot be mistaken for a live address. When the owner verifies
// the domain and hosting, change CANONICAL_BASE here and run
// `node scripts/website/build_site.mjs`, which rewrites every absolute self-URL
// in website/*.html and regenerates robots.txt and sitemap.xml.
export const CANONICAL_BASE = 'https://stickdeath-infinity.invalid/';
export const SITE_NAME = 'StickDeath Infinity';

// indexable: listed in sitemap.xml and must carry rel=canonical.
// Non-indexable pages must carry <meta name="robots" content="noindex">.
// Policy drafts stay non-indexable until legal review and owner approval.
export const PAGES = [
  { file: 'index.html', indexable: true, canonicalPath: '' },
  { file: '404.html', indexable: false, reason: 'error page' },
  { file: 'screens.html', indexable: false, reason: 'prerelease simulator captures; indexable once the app is released' },
  { file: 'account.html', indexable: false, reason: 'account page (config-gated shell)' },
  { file: 'admin.html', indexable: false, reason: 'command center shell (config-gated; server-authorized)' },
  { file: 'policies/terms-v1.html', indexable: false, reason: 'draft awaiting legal review' },
  { file: 'policies/privacy-v1.html', indexable: false, reason: 'draft awaiting legal review' },
  { file: 'policies/publishing-v1.html', indexable: false, reason: 'draft awaiting legal review' },
  { file: 'policies/attribution.html', indexable: false, reason: 'generated; indexable once the site is live and reviewed' }
];
