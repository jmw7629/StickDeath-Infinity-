# Website hosting, domain, deployment and rollback (#269)

Status 2026-10-14 (see the 2026-10-18 section below for the current state): the owner named the production address, `https://stickdeathinfinity.com/`, and the
pages now declare it as their canonical origin (`scripts/website/site_constants.mjs`). No hosting
project, DNS record or deployment configuration exists in this repository yet, and no deployment has
happened. The Vercel account connected to the workspace holds no project or domain for it (checked
2026-10-14). This document fixes the procedure so the first deployment is reversible.

## Current state and owner decision (2026-10-18)

- **Serving today:** Netlify serves `stickdeathinfinity.com`. The domain's DNS is hosted on Netlify's
  NS1 nameservers. The same zone carries the Microsoft 365 mail records (MX, SPF, autodiscover,
  DMARC); they must be preserved through any move, or mail for the domain stops.
- **Chosen host: GoDaddy** (owner decision, 2026-10-18; it replaces the earlier GoDaddy-or-Vercel
  question and the GitHub Pages / Vercel preference below). No Vercel configuration is added.
  Whether the owner already has a GoDaddy Web Hosting (cPanel) plan is **unconfirmed**; a plan is a
  paid product and buying one is an owner decision.
- Nothing below has been performed by an agent. DNS, hosting and Netlify changes are owner actions.

### Migration to GoDaddy (owner, in this order)

1. **Upload.** Upload the contents of `website/` from a reviewed commit to the cPanel `public_html`
   folder (File Manager or SFTP). The site is static and buildless, so the upload is a byte copy of
   the commit; record the commit in `docs/WEBSITE_INVENTORY.md`. Check it on the temporary or
   hosting-IP URL GoDaddy provides before touching DNS.
   - Done 2026-10-19: commit `57d88a5` is live on the temporary URL `16t.23b.mytemp.website`
     (hosting IP `107.180.113.95`). Static files match the commit byte-for-byte.
   - GoDaddy appends a performance-monitoring script (`img1.wsimg.com/traffic-assets/js/tccl.min.js`
     plus an inline loader) to every HTML response. That contradicts the privacy policy ("every
     request stays on this origin"). `website/.htaccess` sends `Content-Security-Policy:
     script-src 'self'`, so browsers refuse both scripts. It also serves `404.html` for missing
     pages. The owner should still ask GoDaddy hosting support to opt the account out of the
     injection.
2. **Record the current zone.** Export or screenshot every record in the Netlify DNS zone first; it
   is the rollback reference.
3. **Nameservers.** Switch the domain's nameservers from Netlify NS1 back to GoDaddy's, and in the
   GoDaddy zone recreate:

   | Type | Name | Value |
   | --- | --- | --- |
   | A | `@` | the GoDaddy hosting IP shown in cPanel |
   | CNAME | `www` | `@` |
   | MX | `@` | priority 0, `stickdeathinfinity-com.mail.protection.outlook.com` |
   | TXT | `@` | `v=spf1 include:spf.protection.outlook.com -all` |
   | CNAME | `autodiscover` | `autodiscover.outlook.com` |
   | TXT | `_dmarc` | `v=DMARC1; p=quarantine; ruf=mailto:joe@stickdeathinfinity.com` |

   Recreate any other record found in step 2 (for example Microsoft 365 verification TXT records).
   Create the records in the GoDaddy zone before the nameserver switch where GoDaddy allows it, so
   mail keeps resolving during propagation.
4. **SSL.** Turn on SSL for the domain in GoDaddy and confirm `https://stickdeathinfinity.com/` and
   `https://www.stickdeathinfinity.com/` load with a valid certificate. Send and receive a test email
   to confirm the Microsoft 365 records.
5. **Only then** remove the domain from Netlify and delete the Netlify site.

### Rollback

- Before step 5: switch the nameservers back to Netlify NS1; the Netlify site and zone are untouched
  and serve again once DNS propagates.
- After step 5: re-upload the previous reviewed commit's `website/` to `public_html` (the site is
  static, so rollback is a copy of known bytes). If GoDaddy hosting itself fails, recreate a static
  site on the previous host from the same commit and point the A/CNAME records at it; keep the mail
  records unchanged throughout.
- Record any rollback in `docs/ROLLBACK.md` §3.

## What exists and is preserved

| Item | State | Rule |
| --- | --- | --- |
| Website source | `website/` (static, buildless, zero third-party requests) | the only source of truth; generated files (`help-data.js`, `robots.txt`, `sitemap.xml`, `policies/attribution.html`, `og-card.png`) are rebuilt by `scripts/website/*.mjs` |
| Canonical base | `scripts/website/site_constants.mjs` (`https://stickdeathinfinity.com/`) | set on 2026-10-14 from the owner's instruction; `node scripts/website/build_site.mjs` rewrites every self-URL, `robots.txt` and `sitemap.xml` from it |
| Owner-only review deployment (V59) | external host, source `e0ac4fe`, outside this repository | leave untouched; it is reference evidence, not the product site, and its link stays off public pages |
| Design reference (`sd-infinity-preview`) | moved to the owner's Mac SSD | owner keeps a private manifest (path, SHA-256, capture date) per `docs/OPERATING_RUNBOOK.md`; historical messaging, pricing and sample metrics in it are reference only |

## Earlier hosting preference (superseded 2026-10-18 by the GoDaddy decision above)

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

## Deploy workflow (added 2026-10-14; not used for GoDaddy hosting)

`.github/workflows/website-deploy.yml` verifies the help centre and discovery files, writes the
`CNAME` file for `stickdeathinfinity.com` and deploys `website/` to GitHub Pages. It is
`workflow_dispatch` only until the owner: (1) enables Pages with Source = GitHub Actions in the
repository settings, (2) adds the custom domain there, (3) creates the DNS records at the registrar
(`A` records for the apex to GitHub Pages' addresses and a `CNAME` for `www`, per GitHub's current
docs), and (4) uncomments the `push` trigger so merges to `main` redeploy. The two Pages actions are
referenced by version tag until the owner reviews and pins them by SHA like the other workflows.

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

- GoDaddy hosting plan (unconfirmed), upload, nameserver switch, SSL and Netlify removal: owner
  actions, in the order above.
- Private analytics (#275) stays off until the event allowlist in `docs/DIAGNOSTICS_DESIGN.md` is
  approved; the site currently sends nothing.
