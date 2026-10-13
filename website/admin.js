'use strict';
// Static command-center shell (issue #277). Calls the sdi_* RPCs through PostgREST
// with a GoTrue session held in page memory. Authorization is entirely server-side;
// this script only shows what the server answers. With SDI_ADMIN_CONFIG === null it
// renders nothing dynamic and makes no request.
(() => {
  const $ = (id) => document.getElementById(id);
  const statusTitle = $('admin-status-title');
  const statusDetail = $('admin-status-detail');
  if (!statusTitle || !statusDetail) return;
  const config = window.SDI_ADMIN_CONFIG;
  if (config === null || config === undefined) return;

  // --- configuration -------------------------------------------------------
  let base = null;
  try {
    if (typeof config === 'object' && typeof config.backendURL === 'string' && typeof config.publishableKey === 'string') {
      const url = new URL(config.backendURL);
      const keyOk = config.publishableKey.length >= 20 && config.publishableKey.length <= 2048 && /^[\x21-\x7e]+$/.test(config.publishableKey);
      if (url.protocol === 'https:' && url.hostname && (url.pathname === '/' || url.pathname === '') && !url.search && !url.hash && !url.username && keyOk) base = url.origin;
    }
  } catch (_) { base = null; }
  if (!base) {
    statusTitle.textContent = 'Command center configuration is present but invalid.';
    statusDetail.textContent = 'admin-config.js must provide an https backend origin without a path and a publishable key. Nothing was sent.';
    return;
  }
  const apikey = config.publishableKey;
  const providers = Array.isArray(config.providers) ? config.providers.filter((p) => ['apple', 'google', 'github', 'microsoft'].includes(p)) : [];

  // --- session (memory only) -------------------------------------------------
  let session = null;      // { access_token, refresh_token, expires_at, email, aal }
  let expiryTimer = null;
  let pendingFactor = null;
  const PANELS = [
    { title: 'Health and queues', rpc: 'sdi_admin_health', params: {} },
    { title: 'My permissions', rpc: 'sdi_admin_permissions', params: { action: 'mine' } },
    { title: 'Render approvals (pending)', rpc: 'sdi_review_action', params: { action: 'list' } },
    { title: 'Users (first page)', rpc: 'sdi_users_action', params: { action: 'list', page: 0 } },
    { title: 'Moderation queue', rpc: 'sdi_moderation_action', params: { action: 'list' } },
    { title: 'Publishing jobs', rpc: 'sdi_publishing_admin', params: { action: 'list' } },
    { title: 'Support queue', rpc: 'sdi_support_action', params: { action: 'list', page: 0 } },
    { title: 'Finance reconciliation (90 days)', rpc: 'sdi_finance_report', params: { action: 'reconciliation' } },
    { title: 'Agents', rpc: 'sdi_agent_admin', params: { action: 'list' } },
    { title: 'Agent proposals (inbox)', rpc: 'sdi_agent_proposal_admin', params: { action: 'inbox' } },
    { title: 'Announcements', rpc: 'sdi_announce_admin', params: { action: 'list' } },
    { title: 'Marketing workspace', rpc: 'sdi_marketing_action', params: { action: 'list' } },
    { title: 'Policy versions', rpc: 'sdi_consent_action', params: { action: 'list' } }
  ];

  const setStatus = (title, detail) => { statusTitle.textContent = title; statusDetail.textContent = detail; };
  const show = (id, visible) => { const el = $(id); if (el) el.hidden = !visible; };

  async function call(path, { method = 'POST', body, token, query } = {}) {
    const headers = { apikey, 'Content-Type': 'application/json', Accept: 'application/json' };
    if (token) headers.Authorization = `Bearer ${token}`;
    const url = new URL(path, base);
    if (query) for (const [k, v] of Object.entries(query)) url.searchParams.set(k, v);
    const response = await fetch(url.href, { method, headers, body: body === undefined ? undefined : JSON.stringify(body), credentials: 'omit', redirect: 'error', cache: 'no-store' });
    let data = null;
    try { data = await response.json(); } catch (_) { data = null; }
    return { ok: response.ok, status: response.status, data };
  }

  async function rpc(name, params) {
    if (!session) return { error: 'Not signed in.' };
    const result = await call(`/rest/v1/rpc/${name}`, { body: params, token: session.access_token });
    if (result.status === 401) { signOut('Session expired. Sign in again.'); return { error: 'Session expired.' }; }
    if (!result.ok) return { error: `The server refused the call (HTTP ${result.status}).` };
    return result.data;
  }

  function signOut(message) {
    const token = session && session.access_token;
    session = null; pendingFactor = null;
    if (expiryTimer) { clearTimeout(expiryTimer); expiryTimer = null; }
    show('admin-console', false); show('admin-signin', true); show('admin-mfa-form', false); show('admin-password-form', true);
    $('admin-panels').replaceChildren();
    setStatus('Signed out.', message || 'No session is held. Sign in to continue.');
    if (token) call('/auth/v1/logout', { token }).catch(() => {});
  }

  function adoptSession(data) {
    if (!data || typeof data.access_token !== 'string' || typeof data.expires_in !== 'number') return false;
    const user = data.user || {};
    session = { access_token: data.access_token, refresh_token: data.refresh_token || null, expires_at: Date.now() + data.expires_in * 1000, email: typeof user.email === 'string' ? user.email : '' };
    if (expiryTimer) clearTimeout(expiryTimer);
    expiryTimer = setTimeout(() => signOut('Session expired. Sign in again.'), Math.max(1000, data.expires_in * 1000 - 5000));
    return true;
  }

  // --- rendering (text only; never HTML from data) --------------------------------
  function renderValue(value) {
    if (Array.isArray(value) && value.length && value.every((row) => row && typeof row === 'object' && !Array.isArray(row))) {
      const keys = [...new Set(value.flatMap((row) => Object.keys(row)))].slice(0, 12);
      const table = document.createElement('table');
      const head = table.createTHead().insertRow();
      for (const key of keys) { const th = document.createElement('th'); th.scope = 'col'; th.textContent = key; head.append(th); }
      const body = table.createTBody();
      for (const row of value.slice(0, 50)) {
        const tr = body.insertRow();
        for (const key of keys) { const td = tr.insertCell(); const cell = row[key]; td.textContent = cell === null || cell === undefined ? '' : typeof cell === 'object' ? JSON.stringify(cell) : String(cell); }
      }
      if (value.length > 50) { const caption = table.createCaption(); caption.textContent = `Showing 50 of ${value.length} rows.`; }
      return table;
    }
    if (value && typeof value === 'object' && !Array.isArray(value)) {
      const list = document.createElement('dl');
      for (const [key, inner] of Object.entries(value)) {
        const dt = document.createElement('dt'); dt.textContent = key; list.append(dt);
        const dd = document.createElement('dd');
        if (inner && typeof inner === 'object') dd.append(renderValue(inner)); else dd.textContent = inner === null || inner === undefined ? '' : String(inner);
        list.append(dd);
      }
      return list;
    }
    const p = document.createElement('p');
    p.textContent = value === null || value === undefined ? '' : Array.isArray(value) ? (value.length ? JSON.stringify(value) : 'No rows.') : String(value);
    return p;
  }

  function buildPanels() {
    const host = $('admin-panels');
    host.replaceChildren();
    for (const panel of PANELS) {
      const details = document.createElement('details');
      const summary = document.createElement('summary'); summary.textContent = panel.title; details.append(summary);
      const answer = document.createElement('div'); answer.className = 'answer';
      const button = document.createElement('button'); button.type = 'button'; button.className = 'button'; button.textContent = `Load (${panel.rpc})`;
      const out = document.createElement('div'); out.setAttribute('aria-live', 'polite');
      button.addEventListener('click', async () => {
        button.disabled = true; out.replaceChildren(renderValue('Loading…'));
        try {
          const result = await rpc(panel.rpc, panel.params);
          if (result && typeof result === 'object' && (result.error || result.code)) {
            const p = document.createElement('p'); p.className = 'note'; p.textContent = `Server answer: ${result.error || result.code}${result.code && result.error ? '' : ''}`; out.replaceChildren(p);
          } else {
            out.replaceChildren(renderValue(result));
          }
        } catch (_) {
          out.replaceChildren(renderValue('The request did not complete. Nothing was changed.'));
        } finally { button.disabled = false; }
      });
      answer.append(button, out); details.append(answer); host.append(details);
    }
  }

  async function enterConsole() {
    show('admin-signin', false); show('admin-console', true);
    $('admin-identity').textContent = session.email ? `Signed in as ${session.email}. Session held in memory only.` : 'Signed in. Session held in memory only.';
    const mine = await rpc('sdi_admin_permissions', { action: 'mine' });
    if (!mine || mine.error || mine.code) {
      setStatus('Signed in without administrator access.', `The server answered: ${mine && (mine.error || mine.code) ? (mine.error || mine.code) : 'no permissions'}. Native navigation or this page cannot grant a role; roles are provisioned server-side with MFA.`);
    } else {
      const caps = Array.isArray(mine.capabilities) ? mine.capabilities.join(', ') : 'none';
      setStatus('Administrator session verified by the server.', `Capabilities: ${caps}. Owner: ${mine.owner ? 'yes' : 'no'}. Recent re-authentication: ${mine.step_up_current ? 'current' : 'not current (sensitive changes will ask for it)'}.`);
    }
    buildPanels();
  }

  // --- sign-in flows ---------------------------------------------------------------
  async function passwordSignIn(event) {
    event.preventDefault();
    const form = event.currentTarget;
    const email = form.email.value.trim(); const password = form.password.value;
    form.password.value = '';
    if (!email || !password) { setStatus('Email and password are required.', 'Nothing was sent.'); return; }
    setStatus('Signing in…', 'Contacting the configured backend.');
    try {
      const result = await call('/auth/v1/token', { query: { grant_type: 'password' }, body: { email, password } });
      if (!result.ok || !adoptSession(result.data)) { setStatus('Sign-in refused.', 'The backend did not issue a session. Check the account or provider status; this page cannot reset credentials.'); return; }
      await stepUp();
    } catch (_) { setStatus('Backend unreachable.', 'The sign-in request did not complete. Nothing is stored.'); }
  }

  async function stepUp() {
    // Administrators need aal2: list verified TOTP factors and challenge the first one.
    const factors = await call('/auth/v1/factors', { method: 'GET', token: session.access_token });
    const totp = factors.ok && factors.data && Array.isArray(factors.data.totp) ? factors.data.totp.find((f) => f.status === 'verified') : null;
    if (!totp) { setStatus('MFA is not enrolled on this account.', 'Administrator access requires a verified authenticator; enrol it in the native app first. Signed out.'); signOut(); return; }
    const challenge = await call(`/auth/v1/factors/${encodeURIComponent(totp.id)}/challenge`, { token: session.access_token });
    if (!challenge.ok || !challenge.data || typeof challenge.data.id !== 'string') { setStatus('MFA challenge failed.', 'The backend did not start a challenge. Signed out.'); signOut(); return; }
    pendingFactor = { factorId: totp.id, challengeId: challenge.data.id };
    show('admin-password-form', false); show('admin-mfa-form', true);
    setStatus('Enter your authenticator code.', 'A second factor is required for every administrator session.');
    $('admin-code').focus();
  }

  async function verifyCode(event) {
    event.preventDefault();
    const code = $('admin-code').value.trim(); $('admin-code').value = '';
    if (!pendingFactor || !/^[0-9]{6}$/.test(code)) { setStatus('Enter the six-digit code.', 'Nothing was sent.'); return; }
    try {
      const result = await call(`/auth/v1/factors/${encodeURIComponent(pendingFactor.factorId)}/verify`, { token: session.access_token, body: { challenge_id: pendingFactor.challengeId, code } });
      if (!result.ok || !adoptSession(result.data)) { setStatus('Code refused.', 'Try again or cancel to sign out.'); return; }
      pendingFactor = null; show('admin-mfa-form', false);
      await enterConsole();
    } catch (_) { setStatus('Backend unreachable.', 'The verification did not complete.'); }
  }

  function providerSignIn(provider) {
    // GoTrue redirects back to this page with the session in the URL fragment; the
    // fragment is read once below and removed from the address bar.
    const redirect = `${location.origin}${location.pathname}`;
    const url = new URL('/auth/v1/authorize', base);
    url.searchParams.set('provider', provider);
    url.searchParams.set('redirect_to', redirect);
    location.assign(url.href);
  }

  async function adoptFragment() {
    if (!location.hash || location.hash.length < 2) return false;
    const params = new URLSearchParams(location.hash.slice(1));
    const accessToken = params.get('access_token');
    const expiresIn = Number(params.get('expires_in'));
    history.replaceState(null, '', `${location.pathname}${location.search}`);
    if (!accessToken || !Number.isFinite(expiresIn)) return false;
    const user = await call('/auth/v1/user', { method: 'GET', token: accessToken });
    if (!adoptSession({ access_token: accessToken, refresh_token: params.get('refresh_token'), expires_in: expiresIn, user: user.ok ? user.data : {} })) return false;
    await stepUp();
    return true;
  }

  async function emergencyStop(event) {
    event.preventDefault();
    const submitter = event.submitter;
    const enabled = submitter && submitter.dataset.enabled === 'true';
    const reason = $('admin-stop-reason').value.trim();
    const out = $('admin-stop-result');
    if (!reason) { out.textContent = 'A reason is required; nothing was sent.'; return; }
    const result = await rpc('sdi_agent_admin', { action: 'emergency_stop', payload: { enabled }, reason });
    out.textContent = result && result.status === 'confirmed' ? `Emergency stop ${enabled ? 'engaged' : 'cleared'} and audited.` : `Server answer: ${(result && (result.error || result.code)) || 'no confirmation'}.`;
    if (result && result.status === 'confirmed') $('admin-stop-reason').value = '';
  }

  async function decideProposal(event) {
    event.preventDefault();
    const submitter = event.submitter;
    const action = submitter && submitter.dataset.decision === 'approve' ? 'approve' : 'reject';
    const proposal = $('admin-proposal-id').value.trim();
    const revision = Number.parseInt($('admin-proposal-revision').value.trim(), 10);
    const reason = $('admin-proposal-reason').value.trim();
    const out = $('admin-proposal-result');
    if (!/^[0-9a-f-]{36}$/i.test(proposal) || !Number.isInteger(revision) || revision < 1 || !reason) {
      out.textContent = 'Proposal id, the revision shown in the inbox and a reason are required; nothing was sent.'; return;
    }
    const result = await rpc('sdi_agent_proposal_admin', { action, proposal, revision, reason });
    out.textContent = result && result.status === 'confirmed'
      ? `Proposal ${result.state} and audited. The worker executes approved proposals; nothing runs on a rejection.`
      : `Server answer: ${(result && (result.error || result.code)) || 'no confirmation'}.`;
    if (result && result.status === 'confirmed') { $('admin-proposal-reason').value = ''; buildPanels(); }
  }

  // --- wire up ----------------------------------------------------------------------
  const providerHost = $('admin-providers');
  if (providers.length) {
    for (const provider of providers) {
      const button = document.createElement('button'); button.type = 'button'; button.className = 'button';
      button.textContent = `Continue with ${provider.charAt(0).toUpperCase()}${provider.slice(1)}`;
      button.addEventListener('click', () => providerSignIn(provider));
      providerHost.append(button);
    }
    providerHost.hidden = false;
  }
  $('admin-password-form').addEventListener('submit', passwordSignIn);
  $('admin-mfa-form').addEventListener('submit', verifyCode);
  $('admin-mfa-cancel').addEventListener('click', () => signOut('Sign-in cancelled before the second factor.'));
  $('admin-signout').addEventListener('click', () => signOut('Signed out.'));
  $('admin-refresh').addEventListener('click', () => enterConsole());
  $('admin-stop-form').addEventListener('submit', emergencyStop);
  $('admin-proposal-form').addEventListener('submit', decideProposal);
  show('admin-signin', true);
  setStatus('Backend configured; not signed in.', `Sign in to ${new URL(base).hostname}. Nothing is stored in this browser; the session ends on reload or expiry.`);
  adoptFragment().catch(() => setStatus('Sign-in redirect could not be read.', 'Sign in again.'));
})();
