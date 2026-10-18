'use strict';
// Account page: sign in, create an account, reset a password and see the account's
// status against the backend (GoTrue + PostgREST). The session lives only in this page's
// memory: closing the tab signs you out. Plan state comes from the server. Signed in, the
// page also shows account notices, policy versions to accept (#273), support requests with
// receipts (#272) and, when account-config.js configures it, web checkout (#271).
(() => {
  const $ = (id) => document.getElementById(id);
  const title = $('account-status-title'), detail = $('account-status-detail'), note = $('account-status-note');
  if (!title || !detail) return;
  const config = window.SDI_ACCOUNT_CONFIG;
  const say = (t, d) => { title.textContent = t; if (d !== undefined) detail.textContent = d; };
  const show = (id, visible) => { const el = $(id); if (el) el.hidden = !visible; };
  if (config === null || config === undefined) { say('Accounts and billing are not connected to this website.', 'No backend is configured in account-config.js, so there is no sign-in here. No prices are listed and no payment is collected.'); return; }
  let base = null;
  try {
    if (typeof config === 'object' && typeof config.backendURL === 'string' && typeof config.publishableKey === 'string') {
      const url = new URL(config.backendURL);
      const keyOk = config.publishableKey.length >= 20 && config.publishableKey.length <= 2048 && /^[\x21-\x7e]+$/.test(config.publishableKey);
      if (url.protocol === 'https:' && url.hostname && (url.pathname === '/' || url.pathname === '') && !url.search && !url.hash && !url.username && keyOk) base = url.origin;
    }
  } catch (_) { base = null; }
  if (!base) { say('Account configuration is present but invalid.', 'account-config.js must provide an https backend origin without a path and a publishable key. Nothing was sent.'); return; }
  const apikey = config.publishableKey;
  const providers = Array.isArray(config.providers) ? config.providers.filter((p) => ['apple', 'google', 'github', 'microsoft'].includes(p)) : [];
  const PROVIDER_LABEL = { apple: 'Continue with Apple', google: 'Continue with Google', github: 'Continue with GitHub', microsoft: 'Continue with Microsoft' };
  const PROVIDER_ID = { apple: 'apple', google: 'google', github: 'github', microsoft: 'azure' };
  let session = null; let timer = null;
  async function call(path, { method = 'POST', body, token, query } = {}) {
    const headers = { apikey, 'Content-Type': 'application/json', Accept: 'application/json' };
    if (token) headers.Authorization = `Bearer ${token}`;
    const url = new URL(path, base); if (query) for (const [k, v] of Object.entries(query)) url.searchParams.set(k, v);
    const response = await fetch(url.href, { method, headers, body: body === undefined ? undefined : JSON.stringify(body), credentials: 'omit', redirect: 'error', cache: 'no-store' });
    const text = await response.text(); let json = null; try { json = text ? JSON.parse(text) : null; } catch (_) { json = null; }
    if (!response.ok) { const message = json && (json.msg || json.error_description || json.message || json.error) ? (json.msg || json.error_description || json.message || json.error) : `HTTP ${response.status}`; const error = new Error(String(message).slice(0, 240)); error.status = response.status; throw error; }
    return json;
  }
  const email = () => $('account-email').value.trim();
  const password = () => $('account-password').value;
  const form = $('account-form'), formStatus = $('account-form-status');
  const tell = (t) => { formStatus.textContent = t; };
  function renderProviders() {
    const box = $('account-providers'); box.replaceChildren();
    if (!providers.length) { const p = document.createElement('p'); p.className = 'quiet'; p.textContent = 'Apple, Google, GitHub and Microsoft sign-in appear here once the owner enables them in the backend.'; box.append(p); return; }
    providers.forEach((p) => { const a = document.createElement('a'); a.className = 'button ghost'; a.textContent = PROVIDER_LABEL[p]; const u = new URL('/auth/v1/authorize', base); u.searchParams.set('provider', PROVIDER_ID[p]); u.searchParams.set('redirect_to', location.origin + location.pathname); a.href = u.href; box.append(a); });
  }
  function adopt(data) {
    session = { access_token: data.access_token, refresh_token: data.refresh_token, expires_at: Date.now() + (Number(data.expires_in) || 3600) * 1000, user: data.user || null };
    if (timer) clearTimeout(timer);
    timer = setTimeout(() => { session = null; renderSignedOut('Your session expired. Sign in again.'); }, Math.max(10000, session.expires_at - Date.now() - 5000));
    renderSignedIn();
  }
  function renderSignedOut(message) {
    show('account-signin', true); show('account-profile', false);
    for (const id of ['account-notices', 'account-consents', 'account-support']) show(id, false);
    for (const id of ['notices-list', 'consents-list', 'support-request-list']) $(id).replaceChildren();
    $('consents-status').textContent = ''; $('support-request-status').textContent = '';
    renderPlans(false);
    say('Signed out.', message || 'Sign in with your StickDeath Infinity account, or create one. Sessions are held in this page only.');
    note.textContent = 'This page stores nothing in your browser. Requests go only to the configured backend when you submit a form.';
  }
  async function renderSignedIn() {
    show('account-signin', false); show('account-profile', true);
    const user = session.user || {};
    $('profile-email').textContent = user.email || '(no email)';
    $('profile-confirmed').textContent = user.email_confirmed_at ? `Email confirmed ${new Date(user.email_confirmed_at).toLocaleDateString()}` : 'Email not confirmed yet: check your inbox for the confirmation link.';
    $('profile-created').textContent = user.created_at ? `Account created ${new Date(user.created_at).toLocaleDateString()}` : '';
    say(`Signed in as ${user.email || 'your account'}.`, 'Projects stay on your devices; this account carries only identity, access, votes, consents, billing status and job metadata.');
    $('profile-plan').textContent = 'Checking plan status…'; $('profile-handle').textContent = '';
    try {
      const rows = await call('/rest/v1/users', { method: 'GET', token: session.access_token, query: { select: 'username,role,subscription_tier,onboarded', limit: '1' } });
      const row = Array.isArray(rows) && rows[0] ? rows[0] : null;
      $('profile-handle').textContent = row && row.username ? `Handle: ${row.username}` : 'No handle yet: set it in the app during onboarding.';
      $('profile-plan').textContent = row && row.subscription_tier && row.subscription_tier !== 'free' ? `Plan: ${row.subscription_tier} (as recorded by the server)` : 'Plan: Free (as recorded by the server).';
    } catch (error) { $('profile-plan').textContent = 'Plan status unavailable: the account profile service is not installed yet (the server answered: ' + error.message + ').'; }
    renderPlans(true);
    loadNotices(); loadConsents(); loadSupport();
  }
  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    if (!email() || password().length < 8) { tell('Enter your email and a password of at least 8 characters.'); return; }
    tell('Signing in…');
    try { const data = await call('/auth/v1/token', { body: { email: email(), password: password() }, query: { grant_type: 'password' } }); $('account-password').value = ''; tell(''); adopt(data); }
    catch (error) { tell(error.status === 400 ? 'Email or password not recognised, or the email is not confirmed yet.' : `Sign-in failed: ${error.message}`); }
  });
  $('account-create').addEventListener('click', async () => {
    if (!email() || password().length < 8) { tell('Enter your email and choose a password of at least 8 characters.'); return; }
    tell('Creating your account…');
    try {
      const data = await call('/auth/v1/signup', { body: { email: email(), password: password(), data: { source: 'website' } }, query: { redirect_to: location.origin + location.pathname } });
      $('account-password').value = '';
      if (data && data.access_token) { adopt(data); tell(''); } else tell('Account created. Check your inbox and confirm your email, then sign in.');
    } catch (error) { tell(`Could not create the account: ${error.message}`); }
  });
  $('account-recover').addEventListener('click', async () => {
    if (!email()) { tell('Enter your email first, then request the reset link.'); return; }
    try { await call('/auth/v1/recover', { body: { email: email() }, query: { redirect_to: location.origin + location.pathname } }); tell('If that email has an account, a reset link is on its way.'); }
    catch (error) { tell(`Could not request a reset: ${error.message}`); }
  });
  $('profile-signout').addEventListener('click', async () => {
    const token = session && session.access_token; session = null; if (timer) clearTimeout(timer);
    try { if (token) await call('/auth/v1/logout', { token }); } catch (_) { /* local sign-out still applies */ }
    renderSignedOut('Signed out. Nothing about you stays in this browser.');
  });
  $('profile-delete').addEventListener('click', async () => {
    if (!session) return;
    if (!confirm('Request deletion of this account? The service completes it after a seven-day cooling-off period during which you can cancel from the app.')) return;
    try { const result = await call('/rest/v1/rpc/sdi_account_lifecycle', { token: session.access_token, body: { action: 'request_deletion' } }); $('profile-delete-status').textContent = `Deletion requested. ${typeof result === 'object' && result && result.scheduled_for ? `Scheduled for ${new Date(result.scheduled_for).toLocaleDateString()}.` : ''}`; }
    catch (error) { $('profile-delete-status').textContent = `Deletion could not be requested here: ${error.message}. Use Profile or Settings in the app.`; }
  });
  // --- signed-in services: notices, policies, support, plans ------------------------
  // Each reads or writes only through the sdi_* RPCs with the member's own session. A
  // refusal or a missing service is shown as the server's answer, never as success.
  const rpc = (name, body) => call(`/rest/v1/rpc/${name}`, { token: session.access_token, body });
  const para = (text, cls) => { const p = document.createElement('p'); if (cls) p.className = cls; p.textContent = text; return p; };
  const unavailable = (what, error) => para(`${what} unavailable: ${error && error.status === 404 ? 'the service is not installed on the backend yet' : (error && error.message) || 'no answer'}.`, 'quiet');
  const when = (iso) => { const d = iso ? new Date(iso) : null; return d && !Number.isNaN(d.getTime()) ? d.toLocaleString() : ''; };

  async function loadNotices() {
    const box = $('notices-list'); show('account-notices', true); box.replaceChildren(para('Loading notices…', 'quiet'));
    try {
      const result = await rpc('sdi_account_notices', { action: 'list' });
      if (!result || result.error) { box.replaceChildren(para(`Notices: ${(result && result.error) || 'no answer'}`, 'quiet')); return; }
      const notices = Array.isArray(result.notices) ? result.notices : [];
      if (!notices.length) { box.replaceChildren(para('No account notices.', 'quiet')); return; }
      const list = document.createElement('ul');
      for (const n of notices) {
        const li = document.createElement('li');
        const strong = document.createElement('strong'); strong.textContent = `${n.read ? '' : 'New: '}${n.title}`;
        li.append(strong, document.createTextNode(` — ${n.body} (${when(n.created_at)})`));
        if (!n.read) {
          const b = document.createElement('button'); b.type = 'button'; b.textContent = 'Mark read';
          b.addEventListener('click', async () => { b.disabled = true; try { await rpc('sdi_account_notices', { action: 'mark_read', notice: n.id }); } catch (_) { /* list reload shows the server state */ } loadNotices(); });
          li.append(' ', b);
        }
        list.append(li);
      }
      box.replaceChildren(list);
    } catch (error) { box.replaceChildren(unavailable('Account notices', error)); }
  }

  const POLICY_LABEL = { terms: 'Terms of service', privacy: 'Privacy policy', content: 'Content and age policy', publishing: 'Official-channel publishing permission', marketing: 'Marketing reuse permission' };
  const consentStatus = (t) => { $('consents-status').textContent = t; };
  async function loadConsents() {
    const box = $('consents-list'); show('account-consents', true); box.replaceChildren(para('Loading policy versions…', 'quiet'));
    try {
      const [current, mine] = await Promise.all([rpc('sdi_consent_action', { action: 'current' }), rpc('sdi_consent_action', { action: 'mine' })]);
      if (!current || current.error || !mine || mine.error) { box.replaceChildren(para(`Policies: ${(current && current.error) || (mine && mine.error) || 'no answer'}`, 'quiet')); return; }
      const policies = Array.isArray(current.policies) ? current.policies : [];
      if (!policies.length) { box.replaceChildren(para('No policy version has been published by the owner yet, so there is nothing to accept here.', 'quiet')); return; }
      const records = Array.isArray(mine.consents) ? mine.consents : [];
      const list = document.createElement('ul');
      for (const policy of policies) {
        const li = document.createElement('li');
        const accepted = records.find((r) => r.policy === policy.policy && r.version === policy.version && !r.withdrawn_at);
        const strong = document.createElement('strong'); strong.textContent = `${POLICY_LABEL[policy.policy] || policy.policy}, version ${policy.version}`;
        li.append(strong, document.createTextNode(` (in force since ${when(policy.effective_at)}): ${policy.summary} `));
        li.append(para(accepted ? `Accepted ${when(accepted.accepted_at)} from ${accepted.source}.` : 'Not accepted for this version.', 'quiet'));
        const minAge = policy.metadata && policy.metadata.min_age;
        let ageBox = null;
        if (!accepted && minAge) {
          const label = document.createElement('label'); ageBox = document.createElement('input'); ageBox.type = 'checkbox';
          label.append(ageBox, ` I am at least ${String(minAge)} years old.`); li.append(label);
        }
        const row = document.createElement('div'); row.className = 'row';
        if (!accepted) {
          const b = document.createElement('button'); b.type = 'button'; b.className = 'button'; b.textContent = `Accept version ${policy.version}`;
          b.addEventListener('click', async () => {
            if (ageBox && !ageBox.checked) { consentStatus(`Confirm the minimum age (${minAge}) first; nothing was sent.`); return; }
            b.disabled = true;
            try {
              const r = await rpc('sdi_consent_action', { action: 'accept', policy: policy.policy, version: policy.version, source: 'web', attestation: ageBox ? { age_ok: true } : {} });
              consentStatus(r && r.status === 'accepted' ? `Accepted ${POLICY_LABEL[policy.policy] || policy.policy} version ${r.version}.` : `Not recorded: ${(r && r.error) || 'no answer'}`);
            } catch (error) { consentStatus(`Not recorded: ${error.message}`); }
            loadConsents();
          });
          row.append(b);
        } else if (['publishing', 'marketing'].includes(policy.policy)) {
          const b = document.createElement('button'); b.type = 'button'; b.textContent = 'Withdraw permission';
          b.addEventListener('click', async () => {
            const effect = policy.policy === 'publishing' ? 'Pending official-channel publications stop and published copies are sent for removal (copies others already shared cannot be recalled).' : 'Your work is no longer used in new marketing.';
            if (!confirm(`Withdraw ${POLICY_LABEL[policy.policy]}? ${effect}`)) return;
            b.disabled = true;
            try { const r = await rpc('sdi_consent_action', { action: 'withdraw', policy: policy.policy }); consentStatus(r && r.status === 'withdrawn' ? 'Permission withdrawn and recorded.' : `Not withdrawn: ${(r && r.error) || 'no answer'}`); }
            catch (error) { consentStatus(`Not withdrawn: ${error.message}`); }
            loadConsents();
          });
          row.append(b);
        }
        li.append(row); list.append(li);
      }
      box.replaceChildren(list);
    } catch (error) { box.replaceChildren(unavailable('Policies', error)); }
  }

  const SUPPORT_STATUS = { open: 'Open', in_progress: 'In progress', waiting_on_member: 'Waiting for you', resolved: 'Resolved', withdrawn: 'Withdrawn' };
  let supportKey = null;   // reused until the server confirms, so a retried send cannot file twice
  const supportStatus = (t) => { $('support-request-status').textContent = t; };
  async function loadSupport() {
    const box = $('support-request-list'); show('account-support', true); box.replaceChildren(para('Loading your requests…', 'quiet'));
    try {
      const result = await rpc('sdi_support_action', { action: 'list_mine' });
      if (!result || result.error) { box.replaceChildren(para(`Support: ${(result && result.error) || 'no answer'}`, 'quiet')); return; }
      const rows = Array.isArray(result.requests) ? result.requests : [];
      if (!rows.length) { box.replaceChildren(para('No requests yet.', 'quiet')); return; }
      const list = document.createElement('ul');
      for (const r of rows) {
        const li = document.createElement('li');
        const strong = document.createElement('strong'); strong.textContent = `${r.receipt} · ${SUPPORT_STATUS[r.status] || r.status}`;
        li.append(strong, document.createTextNode(` — ${r.subject} (${r.category}, sent ${when(r.created_at)}, updated ${when(r.updated_at)})`));
        const row = document.createElement('div'); row.className = 'row';
        if (['open', 'in_progress', 'waiting_on_member'].includes(r.status)) {
          const w = document.createElement('button'); w.type = 'button'; w.textContent = 'Withdraw';
          w.addEventListener('click', async () => { w.disabled = true; try { const a = await rpc('sdi_support_action', { action: 'withdraw', request: r.id }); supportStatus(a && a.status === 'confirmed' ? `${r.receipt} withdrawn.` : `Not withdrawn: ${(a && a.error) || 'no answer'}`); } catch (error) { supportStatus(`Not withdrawn: ${error.message}`); } loadSupport(); });
          row.append(w);
        }
        const d = document.createElement('button'); d.type = 'button'; d.textContent = 'Delete text';
        d.addEventListener('click', async () => { if (!confirm(`Delete the text of ${r.receipt}? The receipt stays for 30 days.`)) return; d.disabled = true; try { const a = await rpc('sdi_support_action', { action: 'delete', request: r.id }); supportStatus(a && a.status === 'confirmed' ? `${r.receipt} deleted.` : `Not deleted: ${(a && a.error) || 'no answer'}`); } catch (error) { supportStatus(`Not deleted: ${error.message}`); } loadSupport(); });
        row.append(d); li.append(row); list.append(li);
      }
      box.replaceChildren(list);
    } catch (error) { box.replaceChildren(unavailable('Support requests', error)); }
  }
  $('support-request-form').addEventListener('submit', async (event) => {
    event.preventDefault();
    if (!session) return;
    const subject = $('support-request-subject').value.trim(); const body = $('support-request-body').value.trim();
    const appVersion = $('support-request-version').value.trim();
    if (!subject || subject.length > 120 || !body || body.length > 2000 || appVersion.length > 50) { supportStatus('Add a subject (120 characters) and describe the issue (2000 characters); nothing was sent.'); return; }
    if (!supportKey) supportKey = (crypto.randomUUID ? crypto.randomUUID() : null);
    if (!supportKey) { supportStatus('This browser cannot create a request id; use Settings → Support in the app.'); return; }
    supportStatus('Sending…');
    try {
      const r = await rpc('sdi_support_action', { action: 'create', category: $('support-request-category').value, platform: $('support-request-platform').value, app_version: appVersion, subject, body, idempotency: supportKey });
      if (r && (r.status === 'created' || r.status === 'duplicate')) {
        supportKey = null; $('support-request-subject').value = ''; $('support-request-body').value = '';
        supportStatus(`Received. Your receipt is ${r.receipt}; quote it if you write again.`);
      } else supportStatus(`Not sent: ${(r && r.error) || 'no answer'}`);
    } catch (error) { supportStatus(`Not sent: ${error.message}. Retrying sends the same request, never a second one.`); }
    loadSupport();
  });
  ['support-request-subject', 'support-request-body'].forEach((id) => $(id).addEventListener('input', () => { supportKey = null; }));

  // Web checkout (#271): only through the configured stripe-checkout function on the
  // same backend origin; the page receives a hosted Stripe URL and nothing else.
  const billing = (() => {
    const b = config.billing;
    if (!b || typeof b !== 'object' || typeof b.checkoutURL !== 'string') return null;
    try {
      const u = new URL(b.checkoutURL);
      const idOk = (v) => typeof v === 'string' && /^[a-z0-9._-]{1,200}$/.test(v);
      if (u.origin !== base || u.search || u.hash || !b.products || !idOk(b.products.creator) || !idOk(b.products.pro)) return null;
      const packs = Array.isArray(b.creditPacks) ? b.creditPacks.filter((p) => p && idOk(p.id) && typeof p.label === 'string' && p.label.length <= 60) : [];
      return { url: u.href, creator: b.products.creator, pro: b.products.pro, packs };
    } catch (_) { return null; }
  })();
  const plansStatus = (t) => { $('plans-status').textContent = t; };
  async function startCheckout(body, button) {
    if (!session || !billing) return;
    button.disabled = true; plansStatus('Opening the payment page…');
    try {
      const data = await call(billing.url, { token: session.access_token, body: { ...body, return_url: location.origin + location.pathname } });
      let target = null; try { target = data && typeof data.url === 'string' ? new URL(data.url) : null; } catch (_) { target = null; }
      if (target && target.protocol === 'https:' && (target.hostname === 'checkout.stripe.com' || target.hostname === 'billing.stripe.com')) { location.assign(target.href); return; }
      plansStatus('The checkout service did not return a payment page. Nothing was charged.');
    } catch (error) { plansStatus(`Checkout is not available right now (${error.message}). Nothing was charged.`); }
    button.disabled = false;
  }
  function renderPlans(signedIn) {
    show('plans-actions', signedIn && !!billing);
    if (!billing) { plansStatus('Web checkout is not available yet. Nothing is charged from this website; plans will be sold in the app stores and here once the owner connects them.'); return; }
    if (!signedIn) { plansStatus('Sign in to choose a plan or buy Spatter credits. The payment page shows the price before you pay.'); return; }
    plansStatus('Payment happens on Stripe\'s page, which shows the price before you pay. Your plan changes only after the payment provider confirms it.');
    const credits = $('plans-credits'); credits.replaceChildren();
    billing.packs.forEach((pack) => { const b = document.createElement('button'); b.type = 'button'; b.textContent = `Buy ${pack.label}`; b.addEventListener('click', () => startCheckout({ action: 'credits', pack_id: pack.id }, b)); credits.append(b); });
  }
  $('plans-creator').addEventListener('click', (e) => startCheckout({ action: 'checkout', product_id: billing && billing.creator }, e.currentTarget));
  $('plans-pro').addEventListener('click', (e) => startCheckout({ action: 'checkout', product_id: billing && billing.pro }, e.currentTarget));
  $('plans-portal').addEventListener('click', (e) => startCheckout({ action: 'portal' }, e.currentTarget));
  const checkoutReturn = new URLSearchParams(location.search).get('checkout');
  if (checkoutReturn) history.replaceState(null, '', location.pathname + location.hash);

  // Provider redirects and recovery links return with tokens in the URL fragment.
  const fragment = new URLSearchParams(location.hash.startsWith('#') ? location.hash.slice(1) : '');
  if (fragment.get('access_token')) {
    history.replaceState(null, '', location.pathname);
    (async () => { try { const user = await call('/auth/v1/user', { method: 'GET', token: fragment.get('access_token') }); adopt({ access_token: fragment.get('access_token'), refresh_token: fragment.get('refresh_token'), expires_in: fragment.get('expires_in'), user }); if (fragment.get('type') === 'recovery') { show('account-newpassword', true); say('Choose a new password.', 'You arrived from a reset link; set the new password below.'); } } catch (error) { renderSignedOut(`The sign-in link could not be used: ${error.message}`); } })();
  } else renderSignedOut(checkoutReturn === 'success' ? 'You returned from the payment page. Sign in to see your plan: it changes only after the payment provider confirms the payment.'
    : checkoutReturn === 'cancelled' ? 'Checkout was cancelled. Nothing was charged.' : undefined);
  $('account-newpassword-form').addEventListener('submit', async (event) => {
    event.preventDefault(); const value = $('account-newpassword').value;
    if (value.length < 8) { $('account-newpassword-status').textContent = 'Use at least 8 characters.'; return; }
    try { await call('/auth/v1/user', { method: 'PUT', token: session.access_token, body: { password: value } }); $('account-newpassword').value = ''; show('account-newpassword', false); say('Password updated.', 'You are signed in with the new password.'); }
    catch (error) { $('account-newpassword-status').textContent = `Could not update the password: ${error.message}`; }
  });
  renderProviders();
})();
