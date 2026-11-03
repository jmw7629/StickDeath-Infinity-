// Controlled response ordering through the actual admin.js event handlers.
// DOM/network are offline adapters, not a second implementation of session logic.
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import assert from 'node:assert/strict';
import { fileURLToPath, pathToFileURL } from 'node:url';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const tick = async () => { for (let i = 0; i < 18; i += 1) await Promise.resolve(); };
const deferred = () => { let resolve; let reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no; }); return { promise, resolve, reject }; };
class Element {
  constructor(id = '') { this.id = id; this.children = []; this.events = {}; this.value = ''; this.checked = false; this.hidden = false; this.disabled = false; this.dataset = {}; this.attributes = {}; this._text = ''; }
  set textContent(value) { this._text = String(value); this.children = []; }
  get textContent() { return this._text + this.children.map((x) => typeof x === 'string' ? x : x.textContent).join(' '); }
  append(...items) { this.children.push(...items); }
  replaceChildren(...items) { this._text = ''; this.children = items; }
  addEventListener(name, handler) { (this.events[name] ||= []).push(handler); }
  async fire(name, extra = {}) { for (const fn of this.events[name] || []) await fn({ preventDefault() {}, currentTarget: this, ...extra }); }
  setAttribute(name, value) { this.attributes[name] = value; }
  removeAttribute(name) { delete this.attributes[name]; }
  focus() {}
  reset() { for (const element of this.formElements || []) { element.value = element.defaultValue; element.checked = element.defaultChecked; } }
  createTHead() { const e = new Element(); e.insertRow = () => { const row = new Element(); e.append(row); return row; }; this.append(e); return e; }
  createTBody() { const e = new Element(); e.insertRow = () => { const row = new Element(); row.insertCell = () => { const c = new Element(); row.append(c); return c; }; e.append(row); return row; }; this.append(e); return e; }
  createCaption() { const c = new Element(); this.append(c); return c; }
  click() { return this.fire('click'); }
  remove() {}
}
function harness(source, { configured = true, hash = '' } = {}) {
  const html = fs.readFileSync(path.join(repo, 'website/admin.html'), 'utf8');
  const elements = new Map();
  for (const match of html.matchAll(/\bid="([^"]+)"/g)) elements.set(match[1], new Element(match[1]));
  for (const match of html.matchAll(/<(input|select|textarea)\b[^>]*id="([^"]+)"[^>]*>([\s\S]*?)(?:<\/\1>|(?=<))/g)) {
    const element = elements.get(match[2]);
    const tag = match[0].split('>')[0];
    element.value = /\bvalue="([^"]*)"/.exec(tag)?.[1] || (match[1] === 'select' ? /<option[^>]*value="([^"]*)"/.exec(match[3])?.[1] || '' : '');
    element.checked = /\bchecked\b/.test(tag);
  }
  const consoleForms = [];
  for (const match of html.matchAll(/<form\b[^>]*id="([^"]+)"[^>]*>([\s\S]*?)<\/form>/g)) {
    const form = elements.get(match[1]); form.formElements = [...match[2].matchAll(/\bid="([^"]+)"/g)].map((m) => elements.get(m[1]));
    for (const field of form.formElements) { field.defaultValue = field.value; field.defaultChecked = field.checked; }
    if (!['admin-password-form', 'admin-mfa-form', 'admin-enrol-form', 'admin-newpassword-form'].includes(form.id)) consoleForms.push(form);
  }
  const get = (id) => { const e = elements.get(id); assert(e, 'Unknown real DOM id: ' + id); return e; };
  get('admin-password-form').email = get('admin-email'); get('admin-password-form').password = get('admin-password');
  const requests = []; const holds = []; const timers = [];
  const response = (data, status = 200) => ({ ok: status >= 200 && status < 300, status, json: async () => data });
  const fetch = async (url, options) => {
    const request = { url: new URL(url), body: options.body ? JSON.parse(options.body) : null, token: options.headers.Authorization || '', method: options.method };
    requests.push(request);
    const hold = holds.find((item) => !item.used && item.match(request));
    if (hold) { hold.used = true; hold.request = request; return hold.gate.promise; }
    const p = request.url.pathname;
    if (p === '/auth/v1/token') return response({ access_token: 'password:' + request.body.email, expires_in: 3600, user: { email: request.body.email } });
    if (p === '/auth/v1/user') return response({ email: request.token.slice(7).split(':').slice(1).join(':'), factors: [{ id: 'totp', factor_type: 'totp', status: 'verified' }] });
    if (p.endsWith('/challenge')) return response({ id: 'challenge' });
    if (p.endsWith('/verify')) return response({ access_token: request.token.slice(7).replace('password:', 'mfa:'), expires_in: 3600, user: { email: request.token.slice(7).split(':').slice(1).join(':') } });
    if (p === '/rest/v1/rpc/sdi_admin_permissions') return response({ capabilities: ['users'], owner: false, step_up_current: true });
    if (p.startsWith('/rest/v1/rpc/')) return response({ status: 'confirmed', revision: 2, users: [], runs: [], jobs: [], instructions: [] });
    return response({});
  };
  const location = { hash, origin: 'https://admin.example.invalid', pathname: '/admin.html', search: '', assign() {} };
  const context = vm.createContext({ document: { getElementById: get, createElement: () => new Element(), body: new Element(), querySelectorAll: (selector) => { assert.equal(selector, '#admin-console form'); return consoleForms; } },
    window: { SDI_ADMIN_CONFIG: configured ? { backendURL: 'https://backend.example.invalid', publishableKey: 'synthetic-publishable-key-1234', providers: [] } : null },
    location, history: { replaceState() { location.hash = ''; } }, URL, URLSearchParams, Blob,
    setTimeout(fn) { timers.push(fn); return timers.length; }, clearTimeout() {}, fetch, confirm: () => true, console });
  vm.runInContext(source, context, { filename: 'website/admin.js' });
  const hold = (match) => { const item = { match, gate: deferred(), used: false }; holds.push(item); return { get used() { return item.used; }, get request() { return item.request; }, release(data, status = 200) { item.gate.resolve(response(data, status)); }, fail() { item.gate.reject(new Error('controlled transport failure')); } }; };
  const rpc = (name, action) => hold((r) => r.url.pathname === '/rest/v1/rpc/' + name && (!action || r.body.action === action));
  const signin = async (email) => {
    get('admin-email').value = email; get('admin-password').value = 'synthetic-password';
    await get('admin-password-form').fire('submit');
    get('admin-code').value = '123456'; await get('admin-mfa-form').fire('submit'); await tick();
    assert.equal(get('admin-console').hidden, false, 'Normal password/MFA flow must still open console');
    assert.match(get('admin-identity').textContent, new RegExp(email.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  };
  return { get, requests, hold, rpc, signin, timers, response, signout: () => get('admin-signout').fire('click') };
}

export async function runAdminEpochScenarios(sourcePath = path.join(repo, 'website/admin.js')) {
  const source = fs.readFileSync(sourcePath, 'utf8'); const results = [];
  const test = async (name, body) => { try { await body(); results.push({ name, ok: true }); } catch (error) { results.push({ name, ok: false, detail: error.message }); } };
  await test('null admin configuration sends nothing', async () => { const h = harness(source, { configured: false }); await tick(); assert.equal(h.requests.length, 0); });
  await test('old directory success cannot refill signed-out or replacement session', async () => {
    const h = harness(source); await h.signin('a@example.invalid'); const old = h.rpc('sdi_users_action', 'list');
    h.get('admin-users-page').value = '1'; const pending = h.get('admin-users-form').fire('submit'); await tick(); assert(old.used);
    await h.signout(); await h.signin('b@example.invalid'); old.release({ users: [{ email: 'private-A' }] }); await pending;
    assert.equal(h.get('admin-users-result').textContent, ''); assert(!h.get('admin-console').hidden);
  });
  await test('old 401 cannot sign out replacement account or revoke it', async () => {
    const h = harness(source); await h.signin('a@example.invalid'); const old = h.rpc('sdi_users_action', 'list');
    h.get('admin-users-page').value = '1'; const pending = h.get('admin-users-form').fire('submit'); await tick(); await h.signout(); await h.signin('b@example.invalid');
    const before = h.requests.length; old.release({ error: 'expired' }, 401); await pending;
    assert.match(h.get('admin-identity').textContent, /b@example/); assert(!h.get('admin-console').hidden); assert.equal(h.requests.length, before);
  });
  for (const kind of ['users', 'history']) await test('latest ' + kind + ' query owns result even when replies reverse', async () => {
    const h = harness(source); await h.signin('a@example.invalid'); const isUsers = kind === 'users';
    h.get('admin-' + kind + '-page').value = '1'; if (!isUsers) h.get('admin-history-kind').value = 'runs';
    const old = h.rpc(isUsers ? 'sdi_users_action' : 'sdi_agent_admin', isUsers ? 'list' : 'runs');
    const first = h.get('admin-' + kind + '-form').fire('submit'); await tick();
    const fresh = h.rpc(isUsers ? 'sdi_users_action' : 'sdi_agent_admin', isUsers ? 'list' : 'runs');
    h.get('admin-' + kind + '-query').value = 'new'; const second = h.get('admin-' + kind + '-form').fire('submit'); await tick();
    fresh.release({ [isUsers ? 'users' : 'runs']: [{ value: 'newest-result' }] }); await second;
    old.release({ [isUsers ? 'users' : 'runs']: [{ value: 'old-private-result' }] }); await first;
    assert.match(h.get('admin-' + kind + '-result').textContent, /newest-result/); assert.doesNotMatch(h.get('admin-' + kind + '-result').textContent, /old-private/);
  });
  await test('new invalid search invalidates old valid response', async () => {
    const h = harness(source); await h.signin('a@example.invalid'); h.get('admin-users-page').value = '1';
    const old = h.rpc('sdi_users_action', 'list'); const first = h.get('admin-users-form').fire('submit'); await tick();
    h.get('admin-users-query').value = 'x'.repeat(101); await h.get('admin-users-form').fire('submit');
    old.release({ users: [{ value: 'old-result' }] }); await first; assert.match(h.get('admin-users-result').textContent, /100 characters/);
  });
  const actions = [
    ['account', 'sdi_users_action', 'ban', (h) => { h.get('admin-account-subject').value = '11111111-1111-4111-8111-111111111111'; h.get('admin-account-action').value = 'ban'; h.get('admin-account-reason').value = 'reasonA'; h.get('admin-account-confirm').checked = true; }, {}, { status: 'confirmed' }],
    ['stop', 'sdi_agent_admin', 'emergency_stop', (h) => { h.get('admin-stop-reason').value = 'reasonA'; }, { submitter: { dataset: { enabled: 'true' } } }, { status: 'confirmed' }],
    ['proposal', 'sdi_agent_proposal_admin', 'approve', (h) => { h.get('admin-proposal-id').value = '11111111-1111-4111-8111-111111111111'; h.get('admin-proposal-revision').value = '1'; h.get('admin-proposal-reason').value = 'reasonA'; }, { submitter: { dataset: { decision: 'approve' } } }, { status: 'confirmed', state: 'approved' }],
    ['announce', 'sdi_announce_admin', 'compose', (h) => { h.get('admin-announce-title').value = 'title'; h.get('admin-announce-body').value = 'body'; h.get('admin-announce-category').value = 'product'; h.get('admin-announce-audience').value = 'all'; h.get('admin-announce-inapp').checked = true; h.get('admin-announce-reason').value = 'reasonA'; }, {}, { status: 'draft', announcement: 'private-A', revision: 3 }],
    ['announce-change', 'sdi_announce_admin', 'cancel', (h) => { h.get('admin-announce-id').value = '11111111-1111-4111-8111-111111111111'; h.get('admin-announce-revision').value = '1'; h.get('admin-announce-change-reason').value = 'reasonA'; }, { submitter: { dataset: { change: 'cancel' } } }, { status: 'confirmed', revision: 8 }],
    ['agent', 'sdi_agent_admin', 'pause', (h) => { h.get('admin-agent-key').value = 'spatter'; h.get('admin-agent-action').value = 'pause'; h.get('admin-agent-revision').value = '1'; h.get('admin-agent-reason').value = 'reasonA'; }, {}, { status: 'confirmed', revision: 9 }],
    ['finance', 'sdi_finance_record', 'reconcile', (h) => { h.get('admin-finance-action').value = 'reconcile'; h.get('admin-finance-entry').value = '11111111-1111-4111-8111-111111111111'; h.get('admin-finance-reason').value = 'reasonA'; }, {}, { status: 'confirmed' }]
  ];
  for (const [form, rpc, action, setup, event, answer] of actions) await test('late ' + form + ' action outcome cannot clear/show in another admin session or replay', async () => {
    const h = harness(source); await h.signin('a@example.invalid'); setup(h); const old = h.rpc(rpc, action);
    const pending = h.get('admin-' + form + '-form').fire('submit', event); await tick(); assert(old.used, 'Mutation was not sent');
    await h.signout(); await h.signin('b@example.invalid'); h.get('admin-' + form + '-reason').value = 'new-B-reason';
    old.release(answer); await pending;
    assert.equal(h.get('admin-' + form + '-result').textContent, ''); assert.equal(h.get('admin-' + form + '-reason').value, 'new-B-reason');
    assert.equal(h.requests.filter((r) => r.url.pathname.endsWith('/' + rpc) && r.body?.action === action).length, 1);
  });
  await test('late finance export cannot restore downloadable private rows', async () => {
    const h = harness(source); await h.signin('a@example.invalid'); h.get('admin-report-view').value = 'export'; h.get('admin-report-page').value = '1';
    const old = h.rpc('sdi_finance_report', 'export'); const pending = h.get('admin-finance-report-form').fire('submit'); await tick(); assert(old.used);
    await h.signout(); await h.signin('b@example.invalid');
    old.release({ period_start: '2026-01-01T00:00:00Z', period_end: '2026-02-01T00:00:00Z', columns: ['private'], rows: [{ private: 'A-finance' }] }); await pending;
    assert(h.get('admin-report-download').disabled); assert.equal(h.get('admin-report-result').textContent, '');
  });
  await test('late caps prefill cannot restore previous admin fields', async () => {
    const h = harness(source); await h.signin('a@example.invalid'); h.get('admin-agent-key').value = 'spatter'; h.get('admin-agent-action').value = 'set_caps'; h.get('admin-agent-revision').value = '1';
    const old = h.rpc('sdi_agent_admin', 'list'); const pending = h.get('admin-agent-form').fire('submit'); await tick(); assert(old.used);
    await h.signout(); await h.signin('b@example.invalid'); h.get('admin-agent-daily').value = '22';
    old.release({ agents: [{ key: 'spatter', revision: 9, daily_run_cap: 999, per_run_item_cap: 999, monthly_cost_cap_minor: 999 }] }); await pending;
    assert.equal(h.get('admin-agent-daily').value, '22'); assert.equal(h.get('admin-agent-result').textContent, '');
  });
  await test('canceled MFA verification cannot adopt its delayed session', async () => {
    const h = harness(source); h.get('admin-email').value = 'a@example.invalid'; h.get('admin-password').value = 'synthetic'; await h.get('admin-password-form').fire('submit');
    const old = h.hold((r) => r.url.pathname.endsWith('/verify')); h.get('admin-code').value = '123456'; const pending = h.get('admin-mfa-form').fire('submit'); await tick();
    await h.get('admin-mfa-cancel').fire('click'); await h.signin('b@example.invalid');
    old.release({ access_token: 'late-A', expires_in: 3600, user: { email: 'a@example.invalid' } }); await pending;
    assert.match(h.get('admin-identity').textContent, /b@example/); assert.doesNotMatch(h.get('admin-status-title').textContent, /refused/);
  });
  await test('new password sign-in intent wins before either response adopted', async () => {
    const h = harness(source); const old = h.hold((r) => r.url.pathname === '/auth/v1/token');
    h.get('admin-email').value = 'a@example.invalid'; h.get('admin-password').value = 'synthetic'; const pending = h.get('admin-password-form').fire('submit'); await tick();
    await h.signin('b@example.invalid'); old.release({ access_token: 'late-A', expires_in: 3600, user: { email: 'a@example.invalid' } }); await pending;
    assert.match(h.get('admin-identity').textContent, /b@example/);
  });
  await test('old session timer and delayed local logout cannot invalidate same-user relogin', async () => {
    const h = harness(source); await h.signin('a@example.invalid'); const timer = h.timers.at(-1);
    const old = h.hold((r) => r.url.pathname === '/auth/v1/logout'); await h.signout(); await tick(); assert(old.used);
    assert.equal(old.request.url.searchParams.get('scope'), 'local'); await h.signin('a@example.invalid'); timer(); old.release({}); await tick();
    assert(!h.get('admin-console').hidden); assert.match(h.get('admin-identity').textContent, /a@example/);
  });
  await test('current 401 really signs out and clears private controls', async () => {
    const h = harness(source); await h.signin('a@example.invalid'); h.get('admin-enrol-secret').value = 'sensitive'; h.get('admin-account-reason').value = 'private'; h.get('admin-users-page').value = '1';
    const old = h.rpc('sdi_users_action', 'list'); const pending = h.get('admin-users-form').fire('submit'); await tick(); old.release({}, 401); await pending;
    assert(h.get('admin-console').hidden); assert.equal(h.get('admin-users-result').textContent, ''); assert.equal(h.get('admin-enrol-secret').value, ''); assert.equal(h.get('admin-account-reason').value, '');
  });
  await test('old permissions result cannot replace the current identity capabilities or panels', async () => {
    const h = harness(source); await h.signin('a@example.invalid'); const old = h.rpc('sdi_admin_permissions', 'mine');
    const pending = h.get('admin-refresh').fire('click'); await tick(); assert(old.used);
    await h.signout(); await h.signin('b@example.invalid'); const before = h.get('admin-status-detail').textContent;
    old.release({ capabilities: ['private-owner-A'], owner: true, step_up_current: true }); await pending;
    assert.equal(h.get('admin-status-detail').textContent, before); assert.match(h.get('admin-identity').textContent, /b@example/);
  });
  await test('detached old panel load never renders private returned data after account change', async () => {
    const h = harness(source); await h.signin('a@example.invalid');
    const visit = (e) => [e, ...e.children.flatMap((child) => child instanceof Element ? visit(child) : [])];
    const button = visit(h.get('admin-panels')).find((e) => e.textContent === 'Load (sdi_users_action)'); assert(button);
    const answer = visit(h.get('admin-panels')).find((e) => e.children.includes(button));
    const oldOut = answer.children[1];
    const old = h.rpc('sdi_users_action', 'list'); const pending = button.fire('click'); await tick(); assert(old.used);
    await h.signout(); await h.signin('b@example.invalid'); old.release({ users: [{ private: 'private-panel-A' }] }); await pending;
    assert.doesNotMatch(h.get('admin-panels').textContent, /private-panel-A/);
    // Include detached references: the stale request cannot write private DOM
    // merely because a surrounding RPC promise happened to resolve first.
    assert.doesNotMatch(oldOut.textContent, /private-panel-A/);
  });
  await test('old recovery failure cannot show stale feedback after another login', async () => {
    const h = harness(source); h.get('admin-email').value = 'a@example.invalid';
    const old = h.hold((r) => r.url.pathname === '/auth/v1/recover'); const pending = h.get('admin-recover').fire('click'); await tick(); assert(old.used);
    await h.signin('b@example.invalid'); old.fail(); await pending;
    assert.equal(h.get('admin-recover-result').textContent, ''); assert.match(h.get('admin-identity').textContent, /b@example/);
  });
  const supportRow = () => ({ id: '11111111-1111-4111-8111-111111111111', user_id: '22222222-2222-4222-8222-222222222222',
    receipt: 'SDI-ABCDEFGHIJ', category: 'studio', platform: 'ios', app_version: '1.0', subject: 'Synthetic save question <img src=x>',
    body: 'Synthetic private support body', admin_note: 'Synthetic internal note', status: 'open', revision: 4,
    created_at: '2026-11-03T12:00:00Z', updated_at: '2026-11-03T12:00:00Z' });
  const supportButton = (h) => {
    const visit = (e) => [e, ...e.children.flatMap((child) => child instanceof Element ? visit(child) : [])];
    return visit(h.get('admin-support-queue')).find((e) => e.textContent === 'Select SDI-ABCDEFGHIJ');
  };
  const loadSupport = async (h, rows = [supportRow()], hasMore = false) => {
    const reply = h.rpc('sdi_support_action', 'list'); const pending = h.get('admin-support-form').fire('submit'); await tick();
    assert(reply.used); reply.release({ requests: rows, has_more: hasMore }); await pending; return reply;
  };
  await test('support queue selects a genuine row revision and confirms an audited status exactly once', async () => {
    const h = harness(source); await h.signin('a@example.invalid'); h.get('admin-support-filter').value = 'open'; h.get('admin-support-page').value = '2';
    const listed = await loadSupport(h, [supportRow()], true);
    assert.deepEqual(listed.request.body, { action: 'list', status: 'open', page: 1 });
    assert(!h.get('admin-support-prev').disabled && !h.get('admin-support-next').disabled);
    assert.match(h.get('admin-support-queue').textContent, /Synthetic save question <img src=x>/);
    const choose = supportButton(h); assert(choose); await choose.fire('click');
    assert(!h.get('admin-support-fields').disabled); assert.match(h.get('admin-support-selected').textContent, /revision 4/);
    h.get('admin-support-status').value = 'in_progress'; h.get('admin-support-note').value = 'Synthetic private triage reason'; h.get('admin-support-confirm').checked = true;
    const changed = h.rpc('sdi_support_action', 'update_status'); const pending = h.get('admin-support-update-form').fire('submit'); await tick(); assert(changed.used);
    assert.deepEqual(changed.request.body, { action: 'update_status', request: supportRow().id, revision: 4, status: 'in_progress', note: 'Synthetic private triage reason' });
    changed.release({ status: 'confirmed', revision: 5 }); await pending;
    assert.match(h.get('admin-support-result').textContent, /confirmed revision 5/); assert.match(h.get('admin-support-result').textContent, /private/);
    assert.equal(h.get('admin-support-note').value, ''); assert(h.get('admin-support-fields').disabled);
    const calls = h.requests.length; await h.get('admin-support-update-form').fire('submit'); assert.equal(h.requests.length, calls, 'Consumed status action replayed');
  });
  await test('support refuses missing confirmation invalid pages malformed revisions and withdrawn targets without mutation calls', async () => {
    const h = harness(source); await h.signin('a@example.invalid'); h.get('admin-support-page').value = '1x';
    const before = h.requests.length; await h.get('admin-support-form').fire('submit'); assert.equal(h.requests.length, before);
    h.get('admin-support-page').value = '1'; await loadSupport(h, [{ ...supportRow(), revision: Number.MAX_SAFE_INTEGER + 1 }]);
    assert.equal(supportButton(h), undefined); assert(h.get('admin-support-fields').disabled);
    await loadSupport(h, [{ ...supportRow(), status: 'withdrawn' }]); assert.equal(supportButton(h), undefined);
    const denied = h.rpc('sdi_support_action', 'list'); const pending = h.get('admin-support-form').fire('submit'); await tick(); denied.release({ code: 'forbidden' }); await pending;
    assert.match(h.get('admin-support-queue').textContent, /forbidden/); assert(h.get('admin-support-fields').disabled);
    await loadSupport(h); await supportButton(h).fire('click'); h.get('admin-support-note').value = 'Synthetic reason';
    const calls = h.requests.length; await h.get('admin-support-update-form').fire('submit'); assert.equal(h.requests.length, calls, 'Unchecked support decision sent');
  });
  await test('support list and consumed status responses cannot restore a prior admin or detached target', async () => {
    const h = harness(source); await h.signin('a@example.invalid'); await loadSupport(h); const oldButton = supportButton(h); await oldButton.fire('click');
    h.get('admin-support-note').value = 'private-A-note'; h.get('admin-support-confirm').checked = true; h.get('admin-support-status').value = 'resolved';
    const changed = h.rpc('sdi_support_action', 'update_status'); const pending = h.get('admin-support-update-form').fire('submit'); await tick(); assert(changed.used);
    await h.signout(); await h.signin('b@example.invalid'); changed.release({ status: 'confirmed', revision: 5 }); await pending;
    assert.equal(h.get('admin-support-result').textContent, ''); assert.equal(h.get('admin-support-selected').textContent, '');
    assert.equal(h.get('admin-support-note').value, ''); assert(h.get('admin-support-fields').disabled);
    const calls = h.requests.length; await oldButton.fire('click'); await h.get('admin-support-update-form').fire('submit'); assert.equal(h.requests.length, calls);
    const listed = h.rpc('sdi_support_action', 'list'); const loading = h.get('admin-support-form').fire('submit'); await tick(); assert(listed.used);
    await h.signout(); await h.signin('c@example.invalid'); listed.release({ requests: [supportRow()], has_more: false }); await loading;
    assert.equal(h.get('admin-support-queue').textContent, ''); assert(h.get('admin-support-fields').disabled);
  });
  await test('support transport and revision conflicts require a fresh list and never invent success or replay', async () => {
    for (const transportFailure of [false, true]) {
      const h = harness(source); await h.signin('a@example.invalid'); await loadSupport(h); await supportButton(h).fire('click');
      h.get('admin-support-note').value = 'Synthetic reason'; h.get('admin-support-confirm').checked = true;
      const changed = h.rpc('sdi_support_action', 'update_status'); const pending = h.get('admin-support-update-form').fire('submit'); await tick();
      if (transportFailure) changed.fail(); else changed.release({ error: 'Request changed or closed. Refresh the queue.' }); await pending;
      assert.doesNotMatch(h.get('admin-support-result').textContent, /Updated SDI/);
      assert.match(h.get('admin-support-result').textContent, /Reload the queue/); assert(h.get('admin-support-fields').disabled);
      const calls = h.requests.length; await h.get('admin-support-update-form').fire('submit'); assert.equal(h.requests.length, calls);
    }
  });
  await test('support accepts SQL-valid Unicode subject body staff note and a full 2000-code-point decision', async () => {
    const supplementary = '\u{1F4A5}';
    assert.match(fs.readFileSync(path.join(repo, 'website/admin.html'), 'utf8'), /id="admin-support-note"[^>]*maxlength="4000"/, 'HTML blocked a valid supplementary-character note');
    for (const count of [1001, 2000]) {
      const h = harness(source); await h.signin('unicode@example.invalid');
      const row = { ...supportRow(), subject: supplementary.repeat(120), body: supplementary.repeat(count),
        admin_note: supplementary.repeat(2000), app_version: supplementary.repeat(50) };
      await loadSupport(h, [row]); const choose = supportButton(h); assert(choose, 'A valid Unicode row rejected its whole page');
      assert.match(h.get('admin-support-queue').textContent, new RegExp(supplementary.repeat(120))); await choose.fire('click');
      assert(!h.get('admin-support-fields').disabled);
      const note = supplementary.repeat(2000); assert.equal(note.length, 4000);
      h.get('admin-support-note').value = note; h.get('admin-support-confirm').checked = true;
      const changed = h.rpc('sdi_support_action', 'update_status'); const pending = h.get('admin-support-update-form').fire('submit'); await tick();
      assert(changed.used, 'Valid 2000-code-point note was refused'); assert.equal(changed.request.body.note, note);
      assert.equal(changed.request.body.revision, row.revision); changed.release({ status: 'confirmed', revision: row.revision + 1 }); await pending;
      assert.match(h.get('admin-support-result').textContent, /confirmed revision 5/); assert.equal(h.get('admin-support-note').value, '');
    }
  });
  await test('support refuses over-limit Unicode rows and Unicode or ASCII notes without sending a decision', async () => {
    const supplementary = '\u{1F4A5}'; const h = harness(source); await h.signin('unicode@example.invalid');
    for (const [field, limit] of [['subject', 120], ['body', 2000], ['admin_note', 2000], ['app_version', 50]]) {
      await loadSupport(h, [{ ...supportRow(), [field]: supplementary.repeat(limit + 1) }]);
      assert.equal(supportButton(h), undefined, `Over-limit ${field} became actionable`); assert(h.get('admin-support-fields').disabled);
    }
    await loadSupport(h); await supportButton(h).fire('click'); h.get('admin-support-confirm').checked = true;
    for (const note of ['a'.repeat(2001), supplementary.repeat(2001), 'a'.repeat(1999) + supplementary.repeat(2)]) {
      h.get('admin-support-note').value = note; const calls = h.requests.length;
      await h.get('admin-support-update-form').fire('submit'); assert.equal(h.requests.length, calls, 'An over-limit private note reached the server');
      assert.match(h.get('admin-support-result').textContent, /2,000 characters/); assert(!h.get('admin-support-fields').disabled);
    }
  });
  return results;
}
if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  const results = await runAdminEpochScenarios(process.argv[2]);
  console.log(JSON.stringify({ total: results.length, passed: results.filter((r) => r.ok).length, results }, null, 2));
  process.exitCode = results.every((r) => r.ok) ? 0 : 1;
}
