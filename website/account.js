'use strict';
// Account page: sign in, create an account, reset a password and see the account's
// status against the backend (GoTrue + PostgREST). The session lives only in this page's
// memory: closing the tab signs you out. No price is ever typed into this page; plan state
// comes from the server or is reported as not configured.
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
      $('profile-plan').textContent = row && row.subscription_tier && row.subscription_tier !== 'free' ? `Plan: ${row.subscription_tier} (as recorded by the server)` : 'Plan: Local Studio (free). Paid plans are not on sale yet.';
    } catch (error) { $('profile-plan').textContent = 'Plan status unavailable: the account profile service is not installed yet (the server answered: ' + error.message + ').'; }
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
  // Provider redirects and recovery links return with tokens in the URL fragment.
  const fragment = new URLSearchParams(location.hash.startsWith('#') ? location.hash.slice(1) : '');
  if (fragment.get('access_token')) {
    history.replaceState(null, '', location.pathname);
    (async () => { try { const user = await call('/auth/v1/user', { method: 'GET', token: fragment.get('access_token') }); adopt({ access_token: fragment.get('access_token'), refresh_token: fragment.get('refresh_token'), expires_in: fragment.get('expires_in'), user }); if (fragment.get('type') === 'recovery') { show('account-newpassword', true); say('Choose a new password.', 'You arrived from a reset link; set the new password below.'); } } catch (error) { renderSignedOut(`The sign-in link could not be used: ${error.message}`); } })();
  } else renderSignedOut();
  $('account-newpassword-form').addEventListener('submit', async (event) => {
    event.preventDefault(); const value = $('account-newpassword').value;
    if (value.length < 8) { $('account-newpassword-status').textContent = 'Use at least 8 characters.'; return; }
    try { await call('/auth/v1/user', { method: 'PUT', token: session.access_token, body: { password: value } }); $('account-newpassword').value = ''; show('account-newpassword', false); say('Password updated.', 'You are signed in with the new password.'); }
    catch (error) { $('account-newpassword-status').textContent = `Could not update the password: ${error.message}`; }
  });
  renderProviders();
})();
