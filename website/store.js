'use strict';
// Store page. Two modes:
//  • unconfigured (SDI_STORE_CONFIG = null): the eight planned products render from the
//    static cards in store.html with no price and no checkout; the status says so.
//  • configured: products, variants and prices are read live from the owner's Shopify
//    Storefront API (public token) and the cart is a Shopify cart; Checkout opens the
//    Shopify-hosted checkout URL. Prices are never typed into this page.
(() => {
  const config = window.SDI_STORE_CONFIG;
  const status = document.querySelector('#store-status');
  const grid = document.querySelector('#store-grid');
  const cartPanel = document.querySelector('#cart');
  const cartList = document.querySelector('#cart-lines');
  const cartTotal = document.querySelector('#cart-total');
  const checkout = document.querySelector('#cart-checkout');
  const cartCount = document.querySelector('#cart-count');
  if (!grid) return;
  const say = (text) => { status.textContent = text; };
  const money = (m) => { try { return new Intl.NumberFormat(undefined, { style: 'currency', currency: m.currencyCode }).format(Number(m.amount)); } catch (_) { return `${m.amount} ${m.currencyCode}`; } };
  const valid = config && typeof config.domain === 'string' && /^[a-z0-9-]+\.myshopify\.com$/i.test(config.domain) && typeof config.storefrontAccessToken === 'string' && config.storefrontAccessToken.length > 10;
  if (!valid) {
    say('The store is not open yet. These are the planned products; prices and checkout appear here once the owner connects the Shopify store.');
    grid.querySelectorAll('.price').forEach((p) => { p.textContent = 'Price on opening'; });
    return;
  }
  const endpoint = `https://${config.domain}/api/${config.apiVersion || '2024-10'}/graphql.json`;
  async function gql(query, variables) {
    const response = await fetch(endpoint, { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Shopify-Storefront-Access-Token': config.storefrontAccessToken }, body: JSON.stringify({ query, variables }) });
    if (!response.ok) throw new Error(`Storefront API ${response.status}`);
    const json = await response.json(); if (json.errors) throw new Error(json.errors.map((e) => e.message).join('; '));
    return json.data;
  }
  const PRODUCTS = `query($first:Int!,$handle:String){ products(first:$first, query:$handle){ edges{ node{ id title handle description featuredImage{ url altText } variants(first:10){ edges{ node{ id title availableForSale price{ amount currencyCode } } } } } } } }`;
  const CART_CREATE = `mutation($lines:[CartLineInput!]!){ cartCreate(input:{lines:$lines}){ cart{ id checkoutUrl totalQuantity cost{ totalAmount{ amount currencyCode } } lines(first:50){ edges{ node{ id quantity merchandise{ ... on ProductVariant{ title product{ title } price{ amount currencyCode } } } } } } } userErrors{ message } } }`;
  const CART_ADD = `mutation($cartId:ID!,$lines:[CartLineInput!]!){ cartLinesAdd(cartId:$cartId, lines:$lines){ cart{ id checkoutUrl totalQuantity cost{ totalAmount{ amount currencyCode } } lines(first:50){ edges{ node{ id quantity merchandise{ ... on ProductVariant{ title product{ title } price{ amount currencyCode } } } } } } } userErrors{ message } } }`;
  const CART_REMOVE = `mutation($cartId:ID!,$lineIds:[ID!]!){ cartLinesRemove(cartId:$cartId, lineIds:$lineIds){ cart{ id checkoutUrl totalQuantity cost{ totalAmount{ amount currencyCode } } lines(first:50){ edges{ node{ id quantity merchandise{ ... on ProductVariant{ title product{ title } price{ amount currencyCode } } } } } } } userErrors{ message } } }`;
  let cart = null; // memory only; Shopify keeps the cart server-side by id
  function renderCart() {
    cartList.replaceChildren();
    const lines = cart ? cart.lines.edges.map((e) => e.node) : [];
    cartCount.textContent = cart ? String(cart.totalQuantity) : '0';
    cartPanel.hidden = lines.length === 0;
    lines.forEach((line) => {
      const li = document.createElement('li');
      const text = document.createElement('span'); text.textContent = `${line.quantity} × ${line.merchandise.product.title}${line.merchandise.title !== 'Default Title' ? ` (${line.merchandise.title})` : ''} · ${money(line.merchandise.price)}`;
      const remove = document.createElement('button'); remove.type = 'button'; remove.textContent = 'Remove'; remove.setAttribute('aria-label', `Remove ${line.merchandise.product.title} from the cart`);
      remove.addEventListener('click', async () => { try { const data = await gql(CART_REMOVE, { cartId: cart.id, lineIds: [line.id] }); cart = data.cartLinesRemove.cart; renderCart(); say('Removed from the cart.'); } catch (error) { say(`Could not update the cart: ${error.message}`); } });
      li.append(text, remove); cartList.append(li);
    });
    cartTotal.textContent = cart ? `Subtotal ${money(cart.cost.totalAmount)} · taxes and shipping are shown at checkout` : '';
    checkout.href = cart ? cart.checkoutUrl : '#';
  }
  async function add(variantId, title) {
    try {
      const data = cart ? await gql(CART_ADD, { cartId: cart.id, lines: [{ merchandiseId: variantId, quantity: 1 }] }) : await gql(CART_CREATE, { lines: [{ merchandiseId: variantId, quantity: 1 }] });
      const payload = data.cartLinesAdd || data.cartCreate;
      if (payload.userErrors && payload.userErrors.length) throw new Error(payload.userErrors.map((e) => e.message).join('; '));
      cart = payload.cart; renderCart(); say(`${title} added to the cart.`);
    } catch (error) { say(`Could not add ${title}: ${error.message}`); }
  }
  (async () => {
    say('Loading products from the store…');
    try {
      const data = await gql(PRODUCTS, { first: 24, handle: config.collectionHandle ? `tag:${config.collectionHandle}` : null });
      const products = data.products.edges.map((e) => e.node);
      if (!products.length) { say('The store is connected but has no published products yet.'); return; }
      grid.replaceChildren();
      products.forEach((product) => {
        const card = document.createElement('article'); card.className = 'product';
        const img = document.createElement('img'); img.loading = 'lazy'; img.decoding = 'async'; img.width = 800; img.height = 800;
        if (product.featuredImage) { img.src = product.featuredImage.url; img.alt = product.featuredImage.altText || product.title; } else { img.src = 'assets/merch/sticker-pack.webp'; img.alt = `${product.title} (no store image yet)`; }
        const h3 = document.createElement('h2'); h3.textContent = product.title;
        const desc = document.createElement('p'); desc.textContent = product.description.slice(0, 160);
        const variants = product.variants.edges.map((e) => e.node);
        const price = document.createElement('p'); price.className = 'price'; price.textContent = variants.length ? money(variants[0].price) : 'Unavailable';
        card.append(img, h3, desc, price);
        if (variants.length > 1) {
          const label = document.createElement('label'); label.textContent = 'Option'; const select = document.createElement('select');
          variants.forEach((v) => { const o = document.createElement('option'); o.value = v.id; o.textContent = `${v.title} · ${money(v.price)}`; o.disabled = !v.availableForSale; select.append(o); });
          label.append(select); card.append(label);
          const button = document.createElement('button'); button.type = 'button'; button.className = 'button'; button.textContent = 'Add to cart';
          button.addEventListener('click', () => add(select.value, product.title)); card.append(button);
        } else if (variants.length) {
          const button = document.createElement('button'); button.type = 'button'; button.className = 'button'; button.textContent = variants[0].availableForSale ? 'Add to cart' : 'Sold out'; button.disabled = !variants[0].availableForSale;
          button.addEventListener('click', () => add(variants[0].id, product.title)); card.append(button);
        }
        grid.append(card);
      });
      say(`${products.length} products loaded from the store. Checkout is handled by Shopify.`);
    } catch (error) { say(`The store could not be reached (${error.message}). The planned line-up is shown without prices.`); grid.querySelectorAll('.price').forEach((p) => { p.textContent = 'Price unavailable'; }); }
  })();
})();
