'use strict';
// Public same-origin client configuration. This is not an administrator key.
// The isolated HTTPS gateway must be installed before this client is deployed.
// No password, service-role key, provider token or signing secret belongs here.
// GoTrue verifies credentials and MFA; PostgREST checks the live administrator
// role, capabilities and recent authentication for every sensitive operation.
// Hosted Supabase deployments may instead use a verified HTTPS backendURL plus
// publishableKey, without transport or apiPrefix.
window.SDI_ADMIN_CONFIG = {
  backendURL: window.location.origin,
  transport: 'same-origin-gateway',
  apiPrefix: '/_sdi_admin_api',
  providers: []
};
