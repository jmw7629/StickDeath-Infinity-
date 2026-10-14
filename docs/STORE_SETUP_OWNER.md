# Store setup (owner runbook, 2026-10-14)

`website/store.html` sells nothing by itself. It reads the owner's Shopify store through the
public Storefront API and hands checkout to Shopify. This page lists the owner steps; none of them
can be done from the repository.

## 1. Create the Shopify store

1. Open a Shopify account for StickDeath Infinity (any plan that includes the Storefront API; the
   Basic plan does). Use the business email, not a personal one.
2. Settings → Store details: name "StickDeath Infinity", currency USD, the legal address that
   appears on receipts.
3. Settings → Payments: enable Shopify Payments (or the processor you prefer). Taxes and shipping
   rates are configured here too; the website never computes them.

## 2. Add the eight products

Use the rendered mock-ups in `website/assets/merch/` as the product images until real photos exist
(they are 800 × 800 WebP; Shopify accepts WebP). Suggested handles match the website cards:

| Handle | Title | Image | Options |
| --- | --- | --- | --- |
| `classic-tee` | Classic tee | `classic-tee.webp` | Size S–3XL |
| `hoodie` | Hoodie | `hoodie.webp` | Size S–3XL |
| `dad-cap` | Dad cap | `cap.webp` | — |
| `sticker-pack` | Sticker pack | `sticker-pack.webp` | — |
| `poster` | Poster 18 × 24 in | `poster.webp` | — |
| `mug` | Mug 11 oz | `mug.webp` | — |
| `tote` | Tote | `tote.webp` | — |
| `enamel-pin` | Enamel pin | `enamel-pin.webp` | — |

Give every product the tag `sdi-merch` (the website can filter on it) and set prices in Shopify.
Prices are never typed into the website.

## 3. Create the public Storefront token

1. Settings → Apps and sales channels → Develop apps → Create an app ("SDI website").
2. Configuration → Storefront API: enable `unauthenticated_read_product_listings`,
   `unauthenticated_read_product_inventory` and `unauthenticated_write_checkouts`
   (cart create / add / remove). Nothing else.
3. Install the app and copy the **Storefront API access token**. This token is public by design
   (it only reads published products and creates carts). Never copy the Admin API token anywhere
   near the website.

## 4. Connect the website

Edit `website/store-config.js`:

```js
window.SDI_STORE_CONFIG = {
  domain: 'your-store.myshopify.com',
  storefrontAccessToken: 'the storefront token from step 3',
  apiVersion: '2024-10',
  collectionHandle: 'sdi-merch'
};
```

Commit it (the token is public; the repository is public) and deploy. The page then loads live
products and prices, keeps a cart on Shopify and opens Shopify's hosted checkout. If the store is
unreachable it falls back to the planned line-up without prices and says so.

Also add the website origin (`https://stickdeathinfinity.com`) under Settings → Domains or the
app's allowed origins if Shopify asks for it, so browsers can call the Storefront API from the site.

## 5. Verify

- Open `store.html` on the deployed site: products and prices appear; the cart counter updates;
  Checkout opens a `checkout.shopify.com`/your-domain page.
- `scripts/website/a11y_perf.mjs` only checks the unconfigured state (it has no store); run it
  before and after the config change to confirm nothing else regressed.
- The harness rule "zero third-party requests" is relaxed only for `store.html` once configured;
  document the measured request list in `docs/WEBSITE_INVENTORY.md` when you deploy.

## What stays off

No pre-orders, no invented prices, no "limited drop" timers and no customer data on the website.
Returns, shipping and taxes follow the Shopify policies you set; link them from the store's
Shopify policy pages, not from the drafts in `website/policies/`.
