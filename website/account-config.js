// Account page configuration (account.html). The values below are the backend's public
// origin and publishable key: they identify the project and grant nothing by themselves.
// Authorization is entirely server-side (row-level security and the sdi_* functions).
//   providers: identity providers that are enabled in the backend's Auth settings.
//              Leave [] until the owner configures Apple / Google / GitHub / Microsoft;
//              the page shows a provider button only for the names listed here.
//   portalURL: optional https link to a billing portal once one exists (none today).
window.SDI_ACCOUNT_CONFIG = {
  backendURL: 'https://gwcqlbjdvxebkxizfxsx.supabase.co',
  publishableKey: 'sb_publishable_ESTaBouCYQb8AzPKGfS_5w_GNWI-otv',
  providers: [],
  portalURL: null
};
