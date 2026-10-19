// Account page configuration (account.html). The values below are the backend's public
// origin and publishable key: they identify the project and grant nothing by themselves.
// Authorization is entirely server-side (row-level security and the sdi_* functions).
//   providers: identity providers that are enabled in the backend's Auth settings.
//              Leave [] until the owner configures Apple / Google / GitHub / Microsoft;
//              the page shows a provider button only for the names listed here.
//   billing:   web checkout (#271). null until the owner deploys the stripe-checkout
//              function (backend/billing/stripe_checkout.py) in test mode. Shape:
//              { checkoutURL: '<backendURL>/functions/v1/stripe-checkout',
//                products: { creator: 'sdi.creator.monthly.web', pro: 'sdi.pro.monthly.web' },
//                creditPacks: [{ id: '<approved Stripe credit pack id>', label: '100 Spatter credits' }] }
//              The function holds the Stripe secret key server-side; this file never does.
//              With billing null the page says web checkout is not available yet.
window.SDI_ACCOUNT_CONFIG = {
  backendURL: 'https://gwcqlbjdvxebkxizfxsx.supabase.co',
  publishableKey: 'sb_publishable_ESTaBouCYQb8AzPKGfS_5w_GNWI-otv',
  providers: [],
  billing: null
};
