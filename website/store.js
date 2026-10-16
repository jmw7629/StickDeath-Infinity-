'use strict';
// Merch store "coming soon" page: a store poll, thumbs up/down per concept design and a
// moderated idea box, all backed by backend/sql/merch-interest.sql through Supabase REST
// RPCs (sdi_merch_totals, sdi_merch_vote, sdi_merch_suggest) with the public publishable key.
//  • SDI_MERCH_CONFIG missing or enabled:false: "Voting opens soon", every control disabled,
//    no request leaves the page and no number is shown.
//  • enabled but unreachable or not installed: the same honest state, with the reason.
//  • connected: counts come only from the server response; nothing is counted locally.
// Without a session the browser keeps a random voter key in localStorage (created on the first
// vote or idea, never on page load); the server stores only a salted hash of it.
(() => {
  const config = window.SDI_MERCH_CONFIG;
  const status = document.querySelector('#merch-status');
  const groups = [...document.querySelectorAll('.votes[data-target]')];
  const form = document.querySelector('#idea-form');
  const submit = document.querySelector('#idea-submit');
  const ideaStatus = document.querySelector('#idea-status');
  const ideaList = document.querySelector('#idea-list');
  const ideaEmpty = document.querySelector('#idea-empty');
  const pollMembers = document.querySelector('#poll-members');
  if (!status || !form) return;
  const KEY = 'sdi.merch.voter';
  const say = (text) => { status.textContent = text; };
  const THUMB = '<svg viewBox="0 0 24 24" width="20" height="20" aria-hidden="true" focusable="false"><path fill="currentColor" d="M2 21h4V9H2v12zm20-11a2 2 0 0 0-2-2h-6.3l1-4.6v-.3a1.5 1.5 0 0 0-.4-1.1L13.2 1 6.6 7.6A2 2 0 0 0 6 9v10a2 2 0 0 0 2 2h9a2 2 0 0 0 1.8-1.2l3-7.1c.1-.2.2-.5.2-.7v-2z"/></svg>';

  // Build the up/down pair for every target (poll, concepts, approved ideas).
  function buildGroup(group) {
    group.replaceChildren();
    for (const dir of ['up', 'down']) {
      const button = document.createElement('button');
      button.type = 'button'; button.className = `vote vote-${dir}`; button.dataset.dir = dir; button.disabled = true;
      button.setAttribute('aria-pressed', 'false');
      button.innerHTML = THUMB;
      const word = group.dataset[dir];
      if (word) { const label = document.createElement('span'); label.className = 'vote-word'; label.textContent = word; button.append(label); }
      const count = document.createElement('span'); count.className = 'vote-count'; count.textContent = '–';
      button.append(count);
      button.addEventListener('click', () => vote(group, dir));
      group.append(button);
    }
    describe(group, null, null);
  }
  function describe(group, counts, mine) {
    for (const button of group.querySelectorAll('button.vote')) {
      const dir = button.dataset.dir; const n = counts ? Number(counts[dir]) || 0 : null;
      button.querySelector('.vote-count').textContent = n === null ? '–' : String(n);
      button.setAttribute('aria-pressed', String(mine === (dir === 'up' ? 1 : -1)));
      const verb = dir === 'up' ? 'Thumbs up' : 'Thumbs down';
      button.setAttribute('aria-label', `${verb} for ${group.dataset.name}${n === null ? '' : `: ${n} ${n === 1 ? 'vote' : 'votes'}`}${mine === (dir === 'up' ? 1 : -1) ? ', your vote (press again to clear)' : ''}`);
    }
    if (group.dataset.target === 'store:open-store' && pollMembers) {
      pollMembers.textContent = counts ? `${counts.member_up || 0} yes and ${counts.member_down || 0} not yet come from signed-in accounts; the rest are browser votes.` : '';
    }
  }
  groups.forEach(buildGroup);

  const state = { live: false, votingOpen: false, suggestionsOpen: false, mine: {}, counts: {} };
  function setControls() {
    document.querySelectorAll('.votes button.vote').forEach((b) => { b.disabled = !(state.live && state.votingOpen); });
    submit.disabled = !(state.live && state.suggestionsOpen);
    form.querySelectorAll('input,textarea').forEach((el) => { el.disabled = !(state.live && state.suggestionsOpen); });
  }
  setControls();

  const offline = (reason) => {
    state.live = false; setControls();
    say(`Voting opens soon. ${reason}`);
    ideaEmpty.textContent = 'Approved ideas appear here once voting opens.'; ideaEmpty.hidden = false;
  };
  const valid = config && config.enabled === true && typeof config.backendURL === 'string' && /^https:\/\/[a-z0-9.-]+(:\d+)?$/i.test(config.backendURL)
    && typeof config.publishableKey === 'string' && config.publishableKey.length > 10;
  if (!valid) { offline('The poll, concept votes and idea box switch on once the vote service is connected.'); return; }

  let memoryKey = null;
  function readKey() { try { const v = localStorage.getItem(KEY); return /^[0-9a-f-]{36}$/.test(v || '') ? v : null; } catch (_) { return memoryKey; } }
  function uuid() {
    if (crypto.randomUUID) return crypto.randomUUID();
    const b = crypto.getRandomValues(new Uint8Array(16)); b[6] = (b[6] & 15) | 64; b[8] = (b[8] & 63) | 128;
    const h = [...b].map((x) => x.toString(16).padStart(2, '0')).join('');
    return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
  }
  function voterKey() {
    let key = readKey();
    if (!key) { key = uuid(); memoryKey = key; try { localStorage.setItem(KEY, key); } catch (_) { /* storage blocked: key lasts this page only */ } }
    return key;
  }
  async function rpc(name, body) {
    const controller = new AbortController(); const timer = setTimeout(() => controller.abort(), 8000);
    try {
      const response = await fetch(`${config.backendURL}/rest/v1/rpc/${name}`, { method: 'POST', signal: controller.signal, headers: { 'Content-Type': 'application/json', apikey: config.publishableKey, Authorization: `Bearer ${config.publishableKey}` }, body: JSON.stringify(body) });
      if (!response.ok) throw new Error(response.status === 404 ? 'the vote service is not installed yet' : `the vote service answered ${response.status}`);
      const data = await response.json();
      if (!data || typeof data !== 'object') throw new Error('the vote service sent an unexpected reply');
      return data;
    } catch (error) {
      throw new Error(error.name === 'AbortError' ? 'the vote service did not answer in time' : error instanceof TypeError ? 'the vote service could not be reached' : (error.message || 'the vote service could not be reached'));
    } finally { clearTimeout(timer); }
  }
  const groupFor = (target) => document.querySelector(`.votes[data-target="${CSS.escape(target)}"]`);

  function renderIdeas(ideas) {
    ideaList.replaceChildren();
    for (const idea of ideas) {
      if (!idea || typeof idea.id !== 'string') continue;
      const li = document.createElement('li'); li.className = 'idea';
      const h3 = document.createElement('h3'); h3.textContent = String(idea.title || '');
      const p = document.createElement('p'); p.textContent = String(idea.description || '');
      li.append(h3, p);
      if (idea.handle) { const by = document.createElement('p'); by.className = 'quiet'; by.textContent = `Suggested by @${idea.handle}`; li.append(by); }
      const group = document.createElement('div'); group.className = 'votes'; group.dataset.target = `idea:${idea.id}`; group.dataset.name = `the idea “${idea.title}”`;
      li.append(group); ideaList.append(li); buildGroup(group);
      state.counts[`idea:${idea.id}`] = idea;
    }
    ideaEmpty.hidden = ideas.length > 0;
    ideaEmpty.textContent = 'No approved ideas yet. Send one!';
  }
  function paint() {
    document.querySelectorAll('.votes[data-target]').forEach((group) => {
      const target = group.dataset.target;
      describe(group, state.counts[target] || { up: 0, down: 0, member_up: 0, member_down: 0 }, state.mine[target] || 0);
    });
    setControls();
  }

  async function load() {
    say('Loading the votes…');
    try {
      const data = await rpc('sdi_merch_totals', { voter_key: readKey() });
      if (data.error || !Array.isArray(data.targets)) throw new Error(data.error || 'the vote service sent an unexpected reply');
      state.live = true; state.votingOpen = data.voting_open === true; state.suggestionsOpen = data.suggestions_open === true;
      state.mine = data.mine && typeof data.mine === 'object' ? data.mine : {};
      state.counts = {};
      data.targets.forEach((t) => { if (t && t.kind && t.key) state.counts[`${t.kind}:${t.key}`] = t; });
      renderIdeas(Array.isArray(data.ideas) ? data.ideas : []);
      paint();
      say(state.votingOpen ? 'Voting is open. Counts are live from the server.' : 'Voting is closed right now. Counts shown are the final stored votes.');
      if (!state.suggestionsOpen) ideaStatus.textContent = 'The idea box is closed right now.';
    } catch (error) { offline(`Right now ${error.message}.`); }
  }

  async function vote(group, dir) {
    if (!state.live || !state.votingOpen) return;
    const target = group.dataset.target; const [kind, ...rest] = target.split(':'); const key = rest.join(':');
    const want = dir === 'up' ? 1 : -1; const value = state.mine[target] === want ? 0 : want;
    const buttons = group.querySelectorAll('button.vote'); buttons.forEach((b) => { b.disabled = true; });
    try {
      const data = await rpc('sdi_merch_vote', { target_kind: kind, target_key: key, value, voter_key: voterKey() });
      if (data.error) { say(data.error); return; }
      if (data.counts) state.counts[target] = data.counts;
      state.mine[target] = Number(data.mine) || 0;
      describe(group, state.counts[target], state.mine[target]);
      say(value === 0 ? `Vote cleared for ${group.dataset.name}.` : `Vote saved for ${group.dataset.name}.`);
    } catch (error) { say(`The vote was not saved: ${error.message}.`); }
    finally { buttons.forEach((b) => { b.disabled = !(state.live && state.votingOpen); }); }
  }

  let pendingIdea = null; // { signature, idempotency } so a retry of the same text is not duplicated
  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    if (!state.live || !state.suggestionsOpen) return;
    const field = (name) => form.elements.namedItem(name);
    const title = field('title').value.trim(); const description = field('description').value.trim();
    const handle = field('handle').value.trim().replace(/^@/, '');
    let problem = '';
    if (title.length < 3 || title.length > 80) problem = 'Give the idea a title of 3 to 80 characters.';
    else if (description.length < 10 || description.length > 500) problem = 'Describe the idea in 10 to 500 characters.';
    else if (/[<>]/.test(title + description) || /[\u0000-\u0008\u000b-\u001f\u007f]/.test(title + description)) problem = 'Use plain text without angle brackets.';
    else if (/(https?:|www\.|mailto:|@[a-z0-9-]+\.[a-z]{2,})/i.test(`${title} ${description}`)) problem = 'Leave out links and email addresses; describe the design in words.';
    else if (handle && !/^[A-Za-z0-9_.]{2,30}$/.test(handle)) problem = 'A handle is 2 to 30 letters, digits, dots or underscores.';
    if (problem) { ideaStatus.textContent = problem; return; }
    const signature = JSON.stringify([title, description, handle]);
    if (!pendingIdea || pendingIdea.signature !== signature) pendingIdea = { signature, idempotency: uuid() };
    submit.disabled = true; ideaStatus.textContent = 'Sending…';
    try {
      const data = await rpc('sdi_merch_suggest', { title, description, handle: handle || null, idempotency: pendingIdea.idempotency, voter_key: voterKey() });
      if (data.error) { ideaStatus.textContent = data.error; return; }
      ideaStatus.textContent = data.status === 'duplicate' ? 'Already received. A moderator reviews every idea before it appears here.' : 'Thanks! A moderator reviews every idea before it appears here.';
      form.reset(); pendingIdea = null;
    } catch (error) { ideaStatus.textContent = `The idea was not sent: ${error.message}. Try again.`; }
    finally { submit.disabled = !(state.live && state.suggestionsOpen); }
  });

  load();
})();
