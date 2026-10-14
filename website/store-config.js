// Store configuration for store.html. Null = store not opened yet: the page shows the
// merchandise line-up without prices or checkout. When the owner opens the Shopify store,
// replace null with the public Storefront values (these are designed to be public; never put
// the Admin API token here):
//   window.SDI_STORE_CONFIG = {
//     domain: 'your-store.myshopify.com',          // the store's myshopify domain
//     storefrontAccessToken: 'public storefront token',
//     apiVersion: '2024-10',
//     collectionHandle: 'sdi-merch'               // optional: a collection to list; omit for all products
//   };
window.SDI_STORE_CONFIG = null;
