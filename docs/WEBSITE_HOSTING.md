# Website hosting, domain, deployment and rollback (#269)

Status 2026-10-13: no hosting project, DNS record or deployment configuration exists in this
repository, and the production domain is **not verified** (owner gate). This document fixes the
procedure so the first deployment is reversible; it does not claim any deployment happened.

## What exists and is preserved

| Item | State | Rule |
| --- | --- | --- |
| Website source | `website/` (static, buildless, zero third-party requests) | the only source of truth; generated files (`help-data.js`, `robots.txt`, `sitemap.xml`, `policies/attribution.html`, `og-card.png`) are rebuilt by `scripts/website/*.mjs` |
| Canonical base | `scripts/website/site_constants.mjs` (`https://stickdeath-infinity.invalid/`) | `.invalid` cannot resolve, so a stray deployment can never pass for the live address; change it only after the domain is verified, then run `node scripts/website/build_site.mjs` |
| Owner-only review deployment (V59) | external host, source `e0ac4fe`, outside this repository | leave untouched; it is reference evidence, not the product site, and its link stays off public pages |
| Design reference (`sd-infinity-preview`) | moved to the owner's Mac SSD | owner keeps a private manifest (path, SHA-256, capture date) per `docs/OPERATING_RUNBOOK.md`; historical messaging, pricing and sample metrics in it are reference only |

## Hosting choice (reuse existing free capacity)

Preferred: **GitHub Pages from the repository** (free, already part of the existing GitHub control
plane, no new account). Alternative: the existing Vercel account connected to the workspace, static
output only, no serverless functions and no paid plan change. Either way:

- Deploy the `website/` folder as-is; there is no build step, so a deployment is a checksum-identical
  copy of a reviewed commit.
- HTTPS is provided by the host; HSTS is enabled only after the domain cutover is confirmed.
- Response headers to request from the host configuration: `Content-Security-Policy: default-src
  'self'; img-src 'self' data:; font-src 'self'; script-src 'self'; style-src 'self'; connect-src
  'self' <configured backend origin for admin.html and account.html only>; frame-ancestors 'none'`,
  `Referrer-Policy: strict-origin-when-cross-origin`, `X-Content-Type-Options: nosniff`.
- The admin shell (`website/admin.html`) and account page stay `noindex` and are gated by
  `admin-config.js` / `account-config.js`, both `null` in the repository.

## Procedure

1. **Review build.** Deploy a commit to a preview URL (Pages branch deployment or Vercel preview).
   Run against the preview: `node scripts/website/build_site.mjs --check`, `node
   scripts/website/check_help.mjs --check`, and `PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers node
   scripts/website/a11y_perf.mjs` (CI candidate `docs/ci-candidates/website-verify.yml`). Record the
   commit, the URL and the harness summary in `docs/WEBSITE_INVENTORY.md`.
2. **HTTPS check.** `curl -sSI https://<preview>/` shows a 200 with the host's certificate; the page
   makes no request to another origin (the harness fails otherwise).
3. **Domain (owner).** Verify ownership of the production domain in the registrar; add the host's
   verification record; only then point `CANONICAL_BASE` at it and rebuild. DNS changes are made by
   the owner, never by an agent, and never for unrelated sites or private service routes.
4. **Cutover.** Promote the reviewed deployment. Keep the previous deployment available (Pages: the
   previous commit; Vercel: the previous deployment stays listed) for at least 30 days.
5. **Rollback.** Re-deploy the previous commit (`git revert` of the website change, or promote the
   previous deployment in the host UI). Because the site is static and buildless, rollback is a copy
   of known bytes; no data migration is involved. Record the rollback in `docs/ROLLBACK.md` §3.

## Not done / blocked

- Domain verification, hosting project creation and the first deployment: owner actions.
- Private analytics (#275) stays off until the event allowlist in `docs/DIAGNOSTICS_DESIGN.md` is
  approved; the site currently sends nothing.
