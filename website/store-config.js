// Merch interest poll configuration for store.html (owner decision 2026-10-15: the store is
// "coming soon"; Shopify is not started because it bills from the start).
// enabled:false keeps the page offline: "Voting opens soon", controls disabled, no request
// leaves the page. Set enabled:true only after backend/sql/merch-interest.sql is installed
// on this project (docs/STORE_SETUP_OWNER.md). The two values below are the backend's
// public origin and publishable key, the same ones account-config.js uses: they identify
// the project and grant nothing by themselves. Never put a service key or secret here.
window.SDI_MERCH_CONFIG = {
  enabled: false,
  backendURL: 'https://gwcqlbjdvxebkxizfxsx.supabase.co',
  publishableKey: 'sb_publishable_ESTaBouCYQb8AzPKGfS_5w_GNWI-otv'
};
