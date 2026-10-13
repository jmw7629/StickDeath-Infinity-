'use strict';
// OWNER-GATED configuration for admin.html (issue #277, #284, #255, #257).
// Leave null until the backend project, its PostgREST/GoTrue endpoints and the
// administrator roles (server-provisioned, MFA) are verified by the owner.
// This file is public: it may hold ONLY the backend origin and the publishable
// (anon) key, which grants nothing by itself; every operation is authorized
// server-side by the sdi_* RPCs (role row + MFA aal2 + live session + step-up).
// Never put a service key, a secret or a password here.
//
// Shape when connected:
// window.SDI_ADMIN_CONFIG = {
//   backendURL: 'https://<project>.supabase.co',   // https origin, no path
//   publishableKey: '<anon key>',                  // publishable key only
//   providers: ['apple', 'google', 'github', 'microsoft'] // optional sign-in buttons
// };
window.SDI_ADMIN_CONFIG = null;
