'use strict';
// Static command-center shell (issue #277; finance #254, agent controls #284,
// publishing stages #245, diagnostics #291, announcements #290, reset flags #285). Calls the sdi_* RPCs through PostgREST
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
    { title: 'Backups, releases and retention', rpc: 'sdi_admin_operations', params: {} },
    { title: 'Provider configuration (presence only)', rpc: 'sdi_admin_configuration', params: {} },
    { title: 'Provider health (configured yes/no, last success/failure, error class)', rpc: 'sdi_admin_provider_health', params: {} },
    { title: 'My permissions', rpc: 'sdi_admin_permissions', params: { action: 'mine' } },
    { title: 'Render approvals (pending)', rpc: 'sdi_review_action', params: { action: 'list' } },
    { title: 'Users (first page)', rpc: 'sdi_users_action', params: { action: 'list', page: 0 } },
    { title: 'Moderation queue', rpc: 'sdi_moderation_action', params: { action: 'list' } },
    { title: 'Publishing jobs', rpc: 'sdi_publishing_admin', params: { action: 'list' } },
    { title: 'Support queue', rpc: 'sdi_support_action', params: { action: 'list', page: 0 } },
    { title: 'Finance reconciliation (90 days)', rpc: 'sdi_finance_report', params: { action: 'reconciliation' } },
    { title: 'Agents', rpc: 'sdi_agent_admin', params: { action: 'list' } },
    { title: 'Agent proposals (inbox)', rpc: 'sdi_agent_proposal_admin', params: { action: 'inbox' } },
    { title: 'Agent audit log (latest 50)', rpc: 'sdi_agent_admin', params: { action: 'audit' } },
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
    show('admin-enrol-form', false); show('admin-newpassword-form', false);
    $('admin-panels').replaceChildren();
    for (const id of ['admin-users-result', 'admin-history-result', 'admin-publish-result', 'admin-diagnostics-result', 'admin-announce-change-result', 'admin-agent-result', 'admin-finance-result', 'admin-report-result']) { const el = $(id); if (el) el.replaceChildren(); }
    for (const id of ['admin-account-result', 'admin-proposal-result', 'admin-stop-result', 'admin-announce-result']) { const el = $(id); if (el) el.textContent = ''; }
    lastExport = null; capsLoaded = null; { const d = $('admin-report-download'); if (d) d.disabled = true; }
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
    // Administrators need aal2: GoTrue lists factors on the user record (there is no
    // GET /factors); challenge the first verified TOTP factor.
    const user = await call('/auth/v1/user', { method: 'GET', token: session.access_token });
    if (!user.ok || !user.data) { setStatus('Account lookup failed.', `The backend answered ${user.status}. Signed out.`); signOut(); return; }
    const factors = Array.isArray(user.data.factors) ? user.data.factors.filter((f) => f && f.factor_type === 'totp') : [];
    const totp = factors.find((f) => f.status === 'verified');
    if (!totp) {
      // An abandoned enrolment leaves an unverified factor whose friendly name blocks a new one.
      for (const stale of factors) await call(`/auth/v1/factors/${encodeURIComponent(stale.id)}`, { method: 'DELETE', token: session.access_token });
      await beginEnrolment(); return;
    }
    const challenge = await call(`/auth/v1/factors/${encodeURIComponent(totp.id)}/challenge`, { token: session.access_token });
    if (!challenge.ok || !challenge.data || typeof challenge.data.id !== 'string') { setStatus('MFA challenge failed.', 'The backend did not start a challenge. Signed out.'); signOut(); return; }
    pendingFactor = { factorId: totp.id, challengeId: challenge.data.id };
    show('admin-password-form', false); show('admin-mfa-form', true);
    setStatus('Enter your authenticator code.', 'A second factor is required for every administrator session.');
    $('admin-code').focus();
  }

  // --- authenticator enrolment (first administrator sign-in) --------------------------
  // GoTrue enrols a TOTP factor for the signed-in account and returns the otpauth
  // secret and a QR image; the factor becomes verified only when a code from the
  // authenticator passes a challenge. Owner provisioning requires that verified factor.
  async function beginEnrolment() {
    const result = await call('/auth/v1/factors', { token: session.access_token, body: { factor_type: 'totp', friendly_name: 'SDI command center' } });
    const totp = result.ok && result.data && result.data.totp;
    if (!totp || typeof result.data.id !== 'string' || typeof totp.secret !== 'string') {
      setStatus('Authenticator enrolment could not start.', `The backend answered ${result.status}${result.data && result.data.msg ? `: ${result.data.msg}` : ''}. Signed out.`);
      signOut(); return;
    }
    pendingFactor = { factorId: result.data.id, challengeId: null };
    const qr = $('admin-enrol-qr');
    if (typeof totp.qr_code === 'string' && totp.qr_code.startsWith('data:image/svg+xml')) { qr.src = totp.qr_code; qr.hidden = false; } else { qr.hidden = true; }
    $('admin-enrol-secret').value = totp.secret;
    show('admin-password-form', false); show('admin-mfa-form', false); show('admin-enrol-form', true);
    setStatus('Enrol an authenticator to continue.', 'This account has no verified second factor; administrator sessions require one. Scan the code or enter the secret, then verify a code.');
    $('admin-enrol-code').focus();
  }

  async function finishEnrolment(event) {
    event.preventDefault();
    const code = $('admin-enrol-code').value.trim(); $('admin-enrol-code').value = '';
    if (!pendingFactor || !/^[0-9]{6}$/.test(code)) { setStatus('Enter the six-digit code.', 'Nothing was sent.'); return; }
    try {
      const challenge = await call(`/auth/v1/factors/${encodeURIComponent(pendingFactor.factorId)}/challenge`, { token: session.access_token });
      if (!challenge.ok || !challenge.data || typeof challenge.data.id !== 'string') { setStatus('Enrolment challenge failed.', 'The backend did not start a challenge. Try again or cancel.'); return; }
      const result = await call(`/auth/v1/factors/${encodeURIComponent(pendingFactor.factorId)}/verify`, { token: session.access_token, body: { challenge_id: challenge.data.id, code } });
      if (!result.ok || !adoptSession(result.data)) { setStatus('Code refused.', 'The factor is not verified yet. Check the authenticator clock and try again, or cancel to sign out.'); return; }
      pendingFactor = null; show('admin-enrol-form', false); $('admin-enrol-secret').value = ''; $('admin-enrol-qr').removeAttribute('src');
      await enterConsole();
    } catch (_) { setStatus('Backend unreachable.', 'The enrolment did not complete.'); }
  }

  // --- password reset by email -------------------------------------------------------
  async function requestRecovery() {
    const email = $('admin-email').value.trim();
    const out = $('admin-recover-result');
    if (!email) { out.textContent = 'Enter the account email first; nothing was sent.'; return; }
    try {
      const result = await call('/auth/v1/recover', { body: { email }, query: { redirect_to: `${location.origin}${location.pathname}` } });
      out.textContent = result.ok
        ? 'If that account exists, a reset link was emailed. Open it on this page to set a new password; this page must be an allowed redirect URL in the backend auth settings.'
        : `The backend answered ${result.status}; no link was sent.`;
    } catch (_) { out.textContent = 'The request did not complete.'; }
  }

  async function saveNewPassword(event) {
    event.preventDefault();
    const password = $('admin-newpassword').value; $('admin-newpassword').value = '';
    if (!session || password.length < 6 || password.length > 128) { setStatus('Choose a password of 6 to 128 characters.', 'Nothing was sent.'); return; }
    try {
      const result = await call('/auth/v1/user', { method: 'PUT', token: session.access_token, body: { password } });
      if (!result.ok) { setStatus('Password not saved.', `The backend answered ${result.status}${result.data && result.data.msg ? `: ${result.data.msg}` : ''}.`); return; }
      show('admin-newpassword-form', false);
      setStatus('Password saved.', 'Continuing with the second factor.');
      await stepUp();
    } catch (_) { setStatus('Backend unreachable.', 'The password change did not complete.'); }
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
    if (params.get('type') === 'recovery') {
      // A password reset link lands here with a session; set the password before the second factor.
      show('admin-signin', true); show('admin-password-form', false); show('admin-newpassword-form', true);
      setStatus('Set a new password.', 'The reset link signed you in for this step only.');
      $('admin-newpassword').focus();
      return true;
    }
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

  // Shows a server answer in `out`: a refusal verbatim, otherwise the rows.
  function showAnswer(out, result, rowsKey) {
    if (!result || typeof result !== 'object') { out.replaceChildren(renderValue('No answer. Nothing was changed.')); return; }
    if (result.error || result.code) { const p = document.createElement('p'); p.className = 'note'; p.textContent = `Server answer: ${result.error || result.code}`; out.replaceChildren(p); return; }
    const rows = Array.isArray(result[rowsKey]) ? result[rowsKey] : [];
    const parts = [rows.length ? renderValue(rows) : renderValue('No matching rows.')];
    if (result.has_more) parts.push(renderValue('More results exist: open the next page.'));
    out.replaceChildren(...parts);
  }
  const pageNumber = (raw) => { const n = Number.parseInt(String(raw).trim() || '1', 10); return Number.isInteger(n) && n >= 1 && n <= 200 ? n - 1 : null; };
  const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

  async function searchUsers(event) {
    event.preventDefault();
    const out = $('admin-users-result');
    const query = $('admin-users-query').value.trim();
    const page = pageNumber($('admin-users-page').value);
    if (query.length > 100 || page === null) { out.replaceChildren(renderValue('Use at most 100 characters and a page from 1 to 200; nothing was sent.')); return; }
    out.replaceChildren(renderValue('Loading…'));
    try { showAnswer(out, await rpc('sdi_users_action', { action: 'list', query, page }), 'users'); }
    catch (_) { out.replaceChildren(renderValue('The request did not complete.')); }
  }

  async function accountAction(event) {
    event.preventDefault();
    const out = $('admin-account-result');
    const subject = $('admin-account-subject').value.trim();
    const action = $('admin-account-action').value;
    const reason = $('admin-account-reason').value.trim();
    if (!UUID_RE.test(subject) || !['note', 'signout', 'suspend', 'ban', 'restore', 'reset_flags'].includes(action) || !reason || reason.length > 2000 || !$('admin-account-confirm').checked) {
      out.textContent = 'An account id, an action, a reason and the confirmation are required; nothing was sent.'; return;
    }
    try {
      const result = await rpc('sdi_users_action', { action, subject, reason });
      if (result && result.status === 'unchanged') {
        out.textContent = 'No open reports on this member\'s posts; nothing was changed or audited.';
      } else if (result && result.status === 'confirmed') {
        out.textContent = action === 'reset_flags' ? `Flags reset and audited: ${Number(result.dismissed) || 0} open reports dismissed.` : `${action} confirmed and audited.`;
        $('admin-account-reason').value = ''; $('admin-account-confirm').checked = false;
      } else if (result && result.code === 'step_up_required') {
        out.textContent = 'The server requires a recent second factor: sign out and sign in again with your authenticator, then retry. Nothing was changed.';
      } else {
        out.textContent = `Server answer: ${(result && (result.error || result.code)) || 'no confirmation'}. Nothing was changed.`;
      }
    } catch (_) { out.textContent = 'The request did not complete. Refresh the directory before retrying.'; }
  }

  async function searchHistory(event) {
    event.preventDefault();
    const out = $('admin-history-result');
    const kind = $('admin-history-kind').value === 'audit' ? 'audit' : 'runs';
    const agent = $('admin-history-agent').value.trim();
    const state = $('admin-history-state').value;
    const query = $('admin-history-query').value.trim();
    const page = pageNumber($('admin-history-page').value);
    if ((agent && !/^[a-z0-9_]{1,40}$/.test(agent)) || query.length > 100 || page === null || (state && !['running', 'succeeded', 'failed', 'stopped'].includes(state))) {
      out.replaceChildren(renderValue('Check the agent key, search text (100 characters) and page (1 to 200); nothing was sent.')); return;
    }
    const payload = { query, page: String(page) };
    if (kind === 'runs' && state) payload.state = state;
    out.replaceChildren(renderValue('Loading…'));
    try { showAnswer(out, await rpc('sdi_agent_admin', { action: kind, agent: agent || null, payload }), kind); }
    catch (_) { out.replaceChildren(renderValue('The request did not complete.')); }
  }

  // --- shared helpers for the action forms -----------------------------------------
  const refusal = (result) => `Server answer: ${(result && (result.error || result.code)) || 'no confirmation'}.${result && result.code === 'step_up_required' ? ' Sign out and sign in again with your authenticator, then retry.' : ''} Nothing was changed.`;
  const say = (out, text) => { out.replaceChildren(renderValue(text)); };
  const wholeNumber = (raw, { min = 0, max = Number.MAX_SAFE_INTEGER, signed = false } = {}) => {
    const text = String(raw).trim();
    if (!(signed ? /^-?[0-9]{1,15}$/ : /^[0-9]{1,15}$/).test(text)) return null;
    const n = Number(text); return n >= min && n <= max ? n : null;
  };
  const dayStart = (value) => (value ? `${value}T00:00:00Z` : null);

  // --- publishing stages (#245) --------------------------------------------------------
  // The stage a person reads, computed exactly as sdi_private.publish_stage(state, phase,
  // attempts, provider_id) in upload-retention.sql, with the iOS AdminPublishStage words.
  // The server's own state, phase and stored failure text are shown beside it, unchanged.
  const PUBLISH_STAGE_TITLE = {
    queued: 'Queued', transferring: 'Transferring to provider', provider_processing: 'Provider processing',
    releasing: 'Setting visibility', published: 'Published (provider confirmed)', failed: 'Failed',
    needs_reconciliation: 'Needs reconciliation (provider outcome uncertain)', cancelling: 'Cancelling',
    removal_in_progress: 'Removal in progress', removed: 'Removed from provider', cancelled: 'Cancelled before upload',
  };
  function publishStageKey(job) {
    const state = job.state; const phase = job.phase;
    if (state === 'published') return 'published';
    if (state === 'failed') return 'failed';
    if (state === 'reconcile') return 'needs_reconciliation';
    if (state === 'cancel_requested') return 'cancelling';
    if (state === 'removal_pending') return 'removal_in_progress';
    if (state === 'cancelled') return job.provider_id !== null && job.provider_id !== undefined ? 'removed' : 'cancelled';
    if (phase === 'processing') return 'provider_processing';
    if (phase === 'release') return 'releasing';
    if (state === 'queued' && job.attempts === 0) return 'queued';
    return 'transferring';
  }
  const publishStage = (job) => PUBLISH_STAGE_TITLE[publishStageKey(job)];
  async function showPublishing(event) {
    event.preventDefault();
    const out = $('admin-publish-result');
    const page = pageNumber($('admin-publish-page').value);
    const job = $('admin-publish-job').value.trim();
    if (page === null || (job && !UUID_RE.test(job))) { say(out, 'Use a page from 1 to 200 and, optionally, a job id; nothing was sent.'); return; }
    say(out, 'Loading…');
    try {
      if (job) { showAnswer(out, await rpc('sdi_publishing_admin', { action: 'history', job }), 'history'); return; }
      const result = await rpc('sdi_publishing_admin', { action: 'list', page });
      if (result && Array.isArray(result.jobs)) result.jobs = result.jobs.map((row) => ({ stage: publishStage(row), title: row.title, destination: row.destination, link: row.result_url || '', failure: row.last_error || '', state: row.state, phase: row.phase, attempts: row.attempts, revision: row.revision, updated_at: row.updated_at, id: row.id }));
      showAnswer(out, result, 'jobs');
    } catch (_) { say(out, 'The request did not complete.'); }
  }

  // --- diagnostics read model (#291) ---------------------------------------------------
  async function showDiagnostics(event) {
    event.preventDefault();
    const out = $('admin-diagnostics-result');
    const days = wholeNumber($('admin-diagnostics-days').value, { min: 1, max: 90 });
    if (days === null) { say(out, 'Choose between 1 and 90 days; nothing was sent.'); return; }
    say(out, 'Loading…');
    try {
      const result = await rpc('sdi_diagnostics_admin', { action: 'summary', days });
      if (!result || result.error || result.code) { const p = document.createElement('p'); p.className = 'note'; p.textContent = refusal(result).replace(' Nothing was changed.', ''); out.replaceChildren(p); return; }
      out.replaceChildren(spikeAlert(result), renderValue(result));
    } catch (_) { say(out, 'The request did not complete.'); }
  }
  // Crash-spike alert from the server's rule (at least 5 and over five times the prior
  // 7-day mean, per platform and build). Real counts only; with no reports there is
  // nothing to alert on, and the text says so rather than implying stability.
  function spikeAlert(result) {
    const p = document.createElement('p'); p.className = 'note';
    const spikes = Array.isArray(result.crash_spikes) ? result.crash_spikes : [];
    if (spikes.length) {
      p.setAttribute('role', 'alert');
      p.textContent = 'Crash spike alert for ' + String(result.latest_complete_day) + ': ' + spikes.map((s) =>
        `${String(s.platform)} build ${String(s.build)}: ${Number(s.latest_total)} crashes vs ${Number(s.prior_daily_mean)}/day over the prior week`).join('; ') + '.';
    } else if (!Number(result.reports)) {
      p.textContent = 'No opt-in diagnostics reports in this window, so no crash-spike alert can be computed.';
    } else {
      p.textContent = 'No crash spike on the latest complete day.';
    }
    return p;
  }

  // --- announcements (#290) ------------------------------------------------------------
  async function composeAnnouncement(event) {
    event.preventDefault();
    const out = $('admin-announce-result');
    const title = $('admin-announce-title').value.trim(); const body = $('admin-announce-body').value.trim();
    const category = $('admin-announce-category').value; const audience = $('admin-announce-audience').value;
    const channels = [...($('admin-announce-inapp').checked ? ['in_app'] : []), ...($('admin-announce-push').checked ? ['push'] : [])];
    const reason = $('admin-announce-reason').value.trim();
    if (!title || title.length > 120 || !body || body.length > 1000 || !channels.length || !reason
      || !['product', 'marketing', 'transactional'].includes(category) || !['all', 'subscribers'].includes(audience)) {
      out.textContent = 'Title (120), text (1000), at least one channel and a reason are required; nothing was sent.'; return;
    }
    try {
      const result = await rpc('sdi_announce_admin', { action: 'compose', payload: { title, body, category, audience, channels }, reason });
      if (result && result.status === 'draft') {
        out.textContent = `Draft saved: id ${result.announcement}, revision ${result.revision}. Nothing is sent until it is scheduled.`;
        $('admin-announce-id').value = result.announcement; $('admin-announce-revision').value = String(result.revision);
        $('admin-announce-reason').value = '';
      } else out.textContent = refusal(result);
    } catch (_) { out.textContent = 'The request did not complete. Refresh the Announcements panel before retrying.'; }
  }
  async function changeAnnouncement(event) {
    event.preventDefault();
    const out = $('admin-announce-change-result');
    const change = event.submitter && event.submitter.dataset.change;
    const announcement = $('admin-announce-id').value.trim();
    if (!UUID_RE.test(announcement) || !['schedule', 'cancel', 'results'].includes(change)) { say(out, 'An announcement id is required; nothing was sent.'); return; }
    try {
      if (change === 'results') { showAnswer(out, await rpc('sdi_announce_admin', { action: 'results', announcement }), 'results'); return; }
      const revision = wholeNumber($('admin-announce-revision').value, { min: 1 });
      const reason = $('admin-announce-change-reason').value.trim();
      const payload = {};
      if (change === 'schedule' && $('admin-announce-when').value) {
        const when = new Date($('admin-announce-when').value);
        if (Number.isNaN(when.getTime())) { say(out, 'The send time is not a valid date; nothing was sent.'); return; }
        payload.scheduled_for = when.toISOString();
      }
      if (revision === null || !reason || reason.length > 2000) { say(out, 'The revision shown and a reason are required; nothing was sent.'); return; }
      if (change === 'schedule' && !confirm(`Schedule this announcement${payload.scheduled_for ? ` for ${new Date(payload.scheduled_for).toLocaleString()}` : ' for the next delivery run'}? It goes to every eligible member.`)) return;
      const result = await rpc('sdi_announce_admin', { action: change, announcement, revision, payload, reason });
      if (result && result.status === 'confirmed') {
        $('admin-announce-revision').value = String(result.revision); $('admin-announce-change-reason').value = '';
        say(out, change === 'schedule' ? `Scheduled and audited (revision ${result.revision}). The delivery worker sends it when due.` : `Cancelled and audited (revision ${result.revision}). Queued deliveries were suppressed.`);
      } else say(out, refusal(result));
    } catch (_) { say(out, 'The request did not complete. Refresh before retrying.'); }
  }

  // --- agent controls (#284) ------------------------------------------------------------
  let capsLoaded = null;   // { agent, revision } whose current caps fill the form
  async function agentControl(event) {
    event.preventDefault();
    const out = $('admin-agent-result');
    const agent = $('admin-agent-key').value.trim(); const action = $('admin-agent-action').value;
    if (!/^[a-z0-9_]{1,40}$/.test(agent)) { say(out, 'Enter the agent key shown in the Agents panel; nothing was sent.'); return; }
    if (action === 'instructions') {
      say(out, 'Loading…');
      try { showAnswer(out, await rpc('sdi_agent_admin', { action, agent }), 'instructions'); } catch (_) { say(out, 'The request did not complete.'); }
      return;
    }
    const ACTIONS = ['pause', 'resume', 'set_caps', 'set_permissions', 'publish_instructions', 'rollback_instructions'];
    const revision = wholeNumber($('admin-agent-revision').value, { min: 1 });
    // An empty per-run cost cap clears it on the server, so caps are sent only
    // after the agent's current values were read into the form (as on iOS).
    if (action === 'set_caps' && !(capsLoaded && capsLoaded.agent === agent && capsLoaded.revision === revision)) {
      capsLoaded = null; say(out, 'Reading the current caps…');
      try {
        const list = await rpc('sdi_agent_admin', { action: 'list' });
        const row = list && Array.isArray(list.agents) ? list.agents.find((a) => a && a.key === agent) : null;
        if (!row || !Number.isInteger(row.revision)) { say(out, list && (list.error || list.code) ? refusal(list) : 'That agent is not in the registry; nothing was sent.'); return; }
        $('admin-agent-daily').value = String(row.daily_run_cap); $('admin-agent-items').value = String(row.per_run_item_cap);
        $('admin-agent-monthly').value = String(row.monthly_cost_cap_minor);
        $('admin-agent-perrun').value = row.per_run_cost_cap_minor === null || row.per_run_cost_cap_minor === undefined ? '' : String(row.per_run_cost_cap_minor);
        $('admin-agent-revision').value = String(row.revision);
        capsLoaded = { agent, revision: row.revision };
        say(out, `Current caps for ${agent} loaded at revision ${row.revision}. Edit them and apply again; an empty per-run cost cap means none. Nothing was sent.`);
      } catch (_) { say(out, 'The current caps could not be read; nothing was sent.'); }
      return;
    }
    const reason = $('admin-agent-reason').value.trim();
    if (!ACTIONS.includes(action) || revision === null || !reason || reason.length > 2000) { say(out, 'The revision shown in the Agents panel and a reason are required; nothing was sent.'); return; }
    let payload = {};
    if (action === 'set_caps') {
      const daily = $('admin-agent-daily').value.trim(); const items = $('admin-agent-items').value.trim();
      const monthly = $('admin-agent-monthly').value.trim(); const perRun = $('admin-agent-perrun').value.trim();
      if (!/^[0-9]{1,4}$/.test(daily) || !/^[0-9]{1,5}$/.test(items) || !/^[0-9]{1,12}$/.test(monthly) || !/^([0-9]{1,12})?$/.test(perRun)) { say(out, 'Caps are whole numbers (per-run cost cap may be empty); nothing was sent.'); return; }
      payload = { daily_run_cap: daily, per_run_item_cap: items, monthly_cost_cap_minor: monthly, per_run_cost_cap_minor: perRun };
    } else if (action === 'set_permissions') {
      payload = { permissions: ['read', 'propose', 'write'].filter((p) => $(`admin-agent-perm-${p}`).checked) };
    } else if (action === 'publish_instructions') {
      const body = $('admin-agent-body').value;
      if (!body.trim() || body.length > 20000) { say(out, 'Instruction text of 1 to 20000 characters is required; nothing was sent.'); return; }
      payload = { body };
    } else if (action === 'rollback_instructions') {
      const version = wholeNumber($('admin-agent-version').value, { min: 1, max: 999999 });
      if (version === null) { say(out, 'Enter the instruction version to restore; nothing was sent.'); return; }
      payload = { version };
    }
    if (['pause', 'publish_instructions', 'rollback_instructions'].includes(action) && !confirm(`Apply "${action.replace('_', ' ')}" to ${agent}?`)) return;
    try {
      const result = await rpc('sdi_agent_admin', { action, agent, revision, payload, reason });
      if (result && result.status === 'confirmed') {
        $('admin-agent-revision').value = String(result.revision); $('admin-agent-reason').value = '';
        capsLoaded = action === 'set_caps' ? { agent, revision: result.revision } : null;
        say(out, `${action.replace(/_/g, ' ')} confirmed and audited; ${agent} is now at revision ${result.revision}.`);
      } else say(out, refusal(result));
    } catch (_) { say(out, 'The request did not complete. Refresh the Agents panel before retrying.'); }
  }

  // --- finance records and reports (#254) -------------------------------------------------
  // CSV with optional double quotes; no formula evaluation, values are sent as text.
  function parseCSV(text) {
    const rows = []; let row = []; let field = ''; let quoted = false;
    for (let i = 0; i < text.length; i += 1) {
      const c = text[i];
      if (quoted) { if (c === '"' && text[i + 1] === '"') { field += '"'; i += 1; } else if (c === '"') quoted = false; else field += c; continue; }
      if (c === '"' && field === '') quoted = true;
      else if (c === ',') { row.push(field); field = ''; }
      else if (c === '\n' || c === '\r') { if (c === '\r' && text[i + 1] === '\n') i += 1; row.push(field); field = ''; if (row.some((v) => v.trim())) rows.push(row); row = []; }
      else field += c;
    }
    row.push(field); if (row.some((v) => v.trim())) rows.push(row);
    return rows;
  }
  async function recordFinance(event) {
    event.preventDefault();
    const out = $('admin-finance-result');
    const action = $('admin-finance-action').value; const reason = $('admin-finance-reason').value.trim();
    if (!reason || reason.length > 2000) { say(out, 'A reason is required; nothing was sent.'); return; }
    const params = { action, reason };
    const currency = $('admin-finance-currency').value.trim().toUpperCase(); const note = $('admin-finance-note').value.trim();
    const entry = $('admin-finance-entry').value.trim();
    if (action === 'expense') {
      const ref = $('admin-finance-ref').value.trim(); const amount = wholeNumber($('admin-finance-amount').value, { min: 1, max: 999999999999999 }); const date = $('admin-finance-date').value;
      if (!ref || ref.length > 200 || amount === null || !/^[A-Z]{3}$/.test(currency) || !/^[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(date) || note.length > 500) { say(out, 'A reference, a positive amount in minor units, an ISO currency and the date are required; nothing was sent.'); return; }
      Object.assign(params, { ref, amount_minor: amount, currency, occurred_at: dayStart(date), note });
    } else if (action === 'import') {
      const lines = parseCSV($('admin-finance-csv').value);
      if (lines.length && /^ref$/i.test((lines[0][0] || '').trim())) lines.shift();
      if (lines.length < 1 || lines.length > 500) { say(out, 'Paste 1 to 500 CSV rows; nothing was sent.'); return; }
      params.rows = lines.map(([ref = '', kind = '', amount = '', cur = '', occurred = '', rowNote = '']) => ({ ref: ref.trim(), kind: kind.trim(), amount_minor: amount.trim(), currency: cur.trim().toUpperCase(), occurred_at: occurred.trim(), note: rowNote.trim() }));
    } else if (action === 'correct') {
      const amount = wholeNumber($('admin-finance-amount').value, { min: -999999999999999, max: 999999999999999, signed: true });
      if (!UUID_RE.test(entry) || amount === null || amount === 0 || !note || note.length > 500) { say(out, 'The entry id, a non-zero signed amount and a note are required; nothing was sent.'); return; }
      Object.assign(params, { entry, amount_minor: amount, note });
    } else if (action === 'reconcile') {
      if (!UUID_RE.test(entry)) { say(out, 'The entry id is required; nothing was sent.'); return; }
      params.entry = entry;
    } else { say(out, 'Unknown record type; nothing was sent.'); return; }
    try {
      const result = await rpc('sdi_finance_record', params);
      if (result && ['recorded', 'imported', 'confirmed', 'duplicate'].includes(result.status)) {
        $('admin-finance-reason').value = '';
        const lines = [];
        if (result.status === 'recorded') lines.push(`Recorded and audited: entry ${result.entry}.${result.possible_duplicate ? ' An expense with the same amount, currency and day already exists: check it is not a duplicate.' : ''}`);
        if (result.status === 'imported') lines.push(`Imported and audited: ${result.added} added, ${result.duplicates} already present, ${Array.isArray(result.rejected) ? result.rejected.length : 0} rejected.`);
        if (result.status === 'confirmed') lines.push('Marked reconciled and audited.');
        if (result.status === 'duplicate') lines.push('Already recorded; nothing was added.');
        const parts = [renderValue(lines.join(' '))];
        if (Array.isArray(result.rejected) && result.rejected.length) parts.push(renderValue(result.rejected.map((r) => ({ rejected_row: r }))));
        out.replaceChildren(...parts);
      } else say(out, refusal(result));
    } catch (_) { say(out, 'The request did not complete. Check the export before retrying.'); }
  }
  let lastExport = null;
  const csvCell = (value) => {
    let text = value === null || value === undefined ? '' : typeof value === 'object' ? JSON.stringify(value) : String(value);
    // Keep spreadsheet formulas inert, but leave plain numbers (negative ledger amounts) numeric.
    if (/^[=+\-@\t\r]/.test(text) && !/^-?[0-9]+(\.[0-9]+)?$/.test(text)) text = `'${text}`;
    return /[",\n\r]/.test(text) ? `"${text.replace(/"/g, '""')}"` : text;
  };
  async function financeReport(event) {
    event.preventDefault();
    const out = $('admin-report-result'); const download = $('admin-report-download');
    const view = $('admin-report-view').value; const provider = $('admin-report-provider').value || null;
    const currency = $('admin-report-currency').value.trim().toUpperCase() || null;
    const start = $('admin-report-start').value; const end = $('admin-report-end').value;
    const page = pageNumber($('admin-report-page').value);
    lastExport = null; download.disabled = true;
    if (!['period_summary', 'reconciliation', 'export', 'agent_costs'].includes(view) || (currency && !/^[A-Z]{3}$/.test(currency)) || page === null || page > 49
      || (start && !/^[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(start)) || (end && !/^[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(end))) { say(out, 'Check the dates, currency and page (1 to 50); nothing was sent.'); return; }
    say(out, 'Loading…');
    try {
      const result = await rpc('sdi_finance_report', { action: view, period_start: dayStart(start), period_end: dayStart(end), provider, currency, page });
      if (!result || result.error || result.code) { const p = document.createElement('p'); p.className = 'note'; p.textContent = refusal(result).replace(' Nothing was changed.', ''); out.replaceChildren(p); return; }
      const parts = [];
      if (result.label) parts.push(renderValue(result.label));
      if (view === 'agent_costs') parts.push(renderValue(result.agents || []));
      else {
        parts.push(renderValue(`Period ${new Date(result.period_start).toISOString().slice(0, 10)} to ${new Date(result.period_end).toISOString().slice(0, 10)} (end exclusive).`));
        if (view === 'reconciliation') { parts.push(renderValue(result.totals || []), renderValue(`${result.discrepancy_count} discrepancies`), renderValue(result.discrepancies || [])); }
        else parts.push(renderValue((result.rows || []).length ? result.rows : 'No entries in this period.'));
        if (view === 'export') {
          if (result.has_more) parts.push(renderValue('More rows exist: open the next export page.'));
          if (Array.isArray(result.columns) && Array.isArray(result.rows) && result.rows.length) { lastExport = { columns: result.columns, rows: result.rows, name: `sdi-ledger-${(start || 'last90')}-${(end || 'now')}-p${page + 1}.csv` }; download.disabled = false; }
        }
      }
      out.replaceChildren(...parts);
    } catch (_) { say(out, 'The request did not complete.'); }
  }
  function downloadExport() {
    if (!lastExport) return;
    const lines = [lastExport.columns.map(csvCell).join(','), ...lastExport.rows.map((row) => lastExport.columns.map((c) => csvCell(row[c])).join(','))];
    const url = URL.createObjectURL(new Blob([`${lines.join('\r\n')}\r\n`], { type: 'text/csv' }));
    const a = document.createElement('a'); a.href = url; a.download = lastExport.name; document.body.append(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
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
  $('admin-enrol-form').addEventListener('submit', finishEnrolment);
  $('admin-enrol-cancel').addEventListener('click', () => signOut('Enrolment cancelled; no factor was verified.'));
  $('admin-newpassword-form').addEventListener('submit', saveNewPassword);
  $('admin-newpassword-cancel').addEventListener('click', () => signOut('Password change cancelled.'));
  $('admin-recover').addEventListener('click', requestRecovery);
  $('admin-signout').addEventListener('click', () => signOut('Signed out.'));
  $('admin-refresh').addEventListener('click', () => enterConsole());
  $('admin-stop-form').addEventListener('submit', emergencyStop);
  $('admin-proposal-form').addEventListener('submit', decideProposal);
  $('admin-users-form').addEventListener('submit', searchUsers);
  $('admin-account-form').addEventListener('submit', accountAction);
  $('admin-history-form').addEventListener('submit', searchHistory);
  $('admin-publish-form').addEventListener('submit', showPublishing);
  $('admin-diagnostics-form').addEventListener('submit', showDiagnostics);
  $('admin-announce-form').addEventListener('submit', composeAnnouncement);
  $('admin-announce-change-form').addEventListener('submit', changeAnnouncement);
  $('admin-agent-form').addEventListener('submit', agentControl);
  $('admin-finance-form').addEventListener('submit', recordFinance);
  $('admin-finance-report-form').addEventListener('submit', financeReport);
  $('admin-report-download').addEventListener('click', downloadExport);
  show('admin-signin', true);
  setStatus('Backend configured; not signed in.', `Sign in to ${new URL(base).hostname}. Nothing is stored in this browser; the session ends on reload or expiry.`);
  adoptFragment().catch(() => setStatus('Sign-in redirect could not be read.', 'Sign in again.'));
})();
