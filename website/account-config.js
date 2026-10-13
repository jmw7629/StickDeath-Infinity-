'use strict';
// OWNER-GATED configuration for account.html (issue #271).
// Leave null until the canonical identity and billing portal are verified.
// When set, account.js validates the object and only then shows a link.
// Never put prices, keys, tokens or secrets here; this file is public.
//
// Shape when connected:
// window.SDI_ACCOUNT_CONFIG = {
//   portalURL: 'https://<verified-portal-host>/',   // https only
//   provider: 'Short provider name shown to the user', // optional, <= 80 characters
//   termsVersion: 'policy version id'                   // optional, <= 100 characters
// };
window.SDI_ACCOUNT_CONFIG = null;
