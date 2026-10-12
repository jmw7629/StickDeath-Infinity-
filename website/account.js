'use strict';
// Renders the account shell from window.SDI_ACCOUNT_CONFIG (account-config.js).
// Default (null) keeps the static "not connected" text. A valid object shows a
// link to the configured portal and nothing else: no prices, no entitlements.
(() => {
  const title = document.getElementById('account-status-title');
  const detail = document.getElementById('account-status-detail');
  const note = document.getElementById('account-status-note');
  if (!title || !detail || !note) return;
  const config = window.SDI_ACCOUNT_CONFIG;
  if (config === null || config === undefined) return;
  const shortText = (value, max) => typeof value === 'string' && value.trim().length > 0 && value.length <= max ? value.trim() : null;
  let portal = null;
  try {
    if (typeof config === 'object' && typeof config.portalURL === 'string') {
      const url = new URL(config.portalURL);
      if (url.protocol === 'https:' && url.hostname) portal = url;
    }
  } catch (_) { portal = null; }
  if (!portal) {
    title.textContent = 'Account configuration is present but invalid.';
    detail.textContent = 'The portal link stays hidden until account-config.js provides an https portal URL. No prices are listed and no payment is collected.';
    return;
  }
  const provider = shortText(config.provider, 80);
  const terms = shortText(config.termsVersion, 100);
  title.textContent = provider ? `Account portal connected through ${provider}.` : 'An account portal is connected.';
  detail.replaceChildren();
  const link = document.createElement('a');
  link.className = 'button';
  link.href = portal.href;
  link.rel = 'noreferrer noopener';
  link.textContent = 'Open the account portal';
  detail.append(link);
  const host = document.createElement('p');
  host.className = 'quiet';
  host.textContent = `Opens ${portal.hostname}. Plans, prices, invoices and cancellation are handled inside the portal; this page lists none of them.${terms ? ` Terms version shown in the portal: ${terms}.` : ''}`;
  detail.after(host);
  note.textContent = 'This page still stores nothing and sends no request until you follow the link.';
})();
