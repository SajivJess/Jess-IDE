import { renderMarkdown } from '/markdown.js';

export function mountChat(doc, win, api, expired) {
  const $ = id => doc.getElementById(id);
  const node = (tag, text, className) => { const n = doc.createElement(tag); if (text !== undefined) n.textContent = text; if (className) n.className = className; return n; };
  const icon = name => { const n = doc.createElementNS('http://www.w3.org/2000/svg', 'svg'), use = doc.createElementNS(n.namespaceURI, 'use'); use.setAttribute('href', `#i-${name}`); n.setAttribute('aria-hidden', 'true'); n.append(use); return n; };
  const drafts = new Map(), noteDrafts = new Map(), scrolls = new Map(), wide = win.matchMedia('(min-width:1100px)');
  let ready = false, active = false, busy = false, refreshing = false, operation = 0, generation = 0, loaded = false, project = '', selected = '', before = null, cursor = 0, notes = null, conversation = null, conversations = [], messages = [], projects = [], repositories = [], connection = 'checking', searchVersion = 0, searchTimer, desktopDrawer = true, creating = false;
  const scope = () => selected || `new:${project}`;
  const dirty = () => notes && ($('context-summary').value !== notes.summary || $('context-handoff').value !== notes.handoff);
  const time = value => value ? new Date(value).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' }) : '';
  function notice(text = '') { $('chat-notice').textContent = text; doc.querySelectorAll('[data-chat-error]').forEach(n => { n.textContent = text; }); }
  function keepNotes() { if (project && notes) noteDrafts.set(project, { base: notes, summary: $('context-summary').value, handoff: $('context-handoff').value }); }
  function keepDraft() { drafts.set(scope(), $('chat-input').value); keepNotes(); if (selected) scrolls.set(selected, $('chat-history').scrollTop); }
  function sizeInput() { const input = $('chat-input'); input.style.height = 'auto'; input.style.height = `${Math.min(160, Math.max(44, input.scrollHeight))}px`; }
  function restoreDraft() { $('chat-input').value = drafts.get(scope()) ?? ''; sizeInput(); }
  function addToDraft(text) {
    if (!ready || !active) return;
    const input = $('chat-input'), next = input.value ? `${input.value}\n\n${text}` : text;
    if (next.length > input.maxLength) { notice('This would exceed the 8,000-character draft limit. Shorten your draft before adding more.'); return; }
    input.value = next; input.oninput(); notice();
    if ($('chat-prompts-dialog').open) $('chat-prompts-dialog').close();
    input.focus(); input.setSelectionRange(next.length, next.length);
    $('chat-draft-state').textContent = 'Added to your draft · Not sent';
  }
  function modal(id) { $('chat-overflow').open = false; if (!$(id).open) $(id).showModal(); }
  function closeDrawer() { if ($('conversation-drawer').open) $('conversation-drawer').close(); $('drawer-toggle').setAttribute('aria-expanded', 'false'); doc.querySelector('.app-shell').classList.remove('drawer-visible'); }
  function openDrawer() { const drawer = $('conversation-drawer'); drawer.classList.toggle('desktop', wide.matches); if (!drawer.open) { if (wide.matches) drawer.show(); else drawer.showModal(); } $('drawer-toggle').setAttribute('aria-expanded', 'true'); doc.querySelector('.app-shell').classList.add('drawer-visible'); }
  function closePanels() { for (const id of ['chat-new-dialog', 'chat-details-dialog', 'chat-rename-dialog', 'chat-prompts-dialog']) if ($(id).open) $(id).close(); $('chat-overflow').open = false; closeDrawer(); }
  function controls() {
    doc.querySelectorAll('.conversation-item').forEach(button => { button.disabled = busy || !ready || connection !== 'online'; });
    for (const id of ['chat-project', 'chat-create', 'chat-refresh', 'chat-repository', 'chat-title', 'context-save', 'context-reload', 'rename-save']) $(id).disabled = busy || !ready || connection !== 'online';
    $('chat-download').disabled = !selected || busy || connection !== 'online';
    $('context-download').disabled = $('handoff-download').disabled = !project || busy || connection !== 'online';
    $('menu-rename').disabled = $('menu-archive').disabled = !selected || busy || connection !== 'online';
    $('menu-archive').textContent = conversation?.archived ? 'Restore conversation' : 'Archive conversation';
    $('context-state').textContent = notes ? dirty() ? `Unsaved notes · based on revision ${notes.revision}` : `Saved · revision ${notes.revision}` : '';
    // Draft editing never queues or dispatches a message to the host agent.
    $('composer-prompts').disabled = !ready;
    $('chat-send').disabled = true;
    $('chat-send-help').textContent = connection === 'offline' ? 'Offline · Draft not sent · Reconnect to refresh history' : conversation?.archived ? 'Archived conversation · Draft not sent' : 'Agent runs on your laptop · Remote sending is not enabled';
    $('chat-mobile-status').textContent = win.navigator.onLine ? 'Browser online' : 'Browser offline';
    $('chat-connection').textContent = ({ online: 'Laptop online', offline: 'Laptop unreachable', error: 'Laptop connection issue', checking: 'Connecting to laptop', unknown: 'Signed out' })[connection] ?? 'Connection stale';
    $('chat-connection').dataset.status = connection;
    $('chat-agent-status').textContent = messages.some(m => m.status === 'DISPATCHING') ? 'Awaiting CLI reply' : conversation?.lastStatus === 'UNCERTAIN' ? 'Delivery needs review' : conversation?.nativeSessionId ? 'Session recorded · local only' : 'CLI not attached';
    $('chat-heading').textContent = conversation?.title ?? 'New conversation';
    $('chat-project-name').textContent = repositories.find(r => r.id === conversation?.repositoryId)?.name ?? projects.find(p => p.id === project)?.name ?? 'Select a project';
  }
  function options(id, values, label, placeholder, chosen = $(id).value) {
    const signature = JSON.stringify(values.map(value => [value.id, label(value)]));
    if ($(id).dataset.options !== signature) { $(id).dataset.options = signature; $(id).replaceChildren(); const empty = node('option', placeholder); empty.value = ''; $(id).append(empty); for (const value of values) { const option = node('option', label(value)); option.value = value.id; $(id).append(option); } }
    $(id).value = values.some(v => v.id === chosen) ? chosen : '';
  }
  function projectOptions() { const values = [...projects]; if (project && !values.some(p => p.id === project)) values.push({ id: project, name: `Project ${project.slice(0, 8)}` }); options('chat-project', values, p => p.name, 'Choose a project', project); }
  function drawList() {
    $('conversation-list').replaceChildren();
    if (!conversations.length) $('conversation-list').append(node('p', project ? 'No matching conversations.' : 'Choose a project to get started.', 'drawer-empty'));
    for (const c of conversations) {
      const button = node('button', undefined, 'conversation-item'); button.type = 'button'; button.disabled = busy; button.dataset.conversationId = c.id; button.setAttribute('aria-pressed', String(c.id === selected));
      button.append(node('span', c.title, 'conversation-name'), node('span', `${c.archived ? 'Archived · ' : ''}${new Date(c.updatedAt).toLocaleDateString(undefined, { month: 'short', day: 'numeric' })}${c.lastStatus === 'DISPATCHING' ? ' · Awaiting reply' : c.lastStatus === 'UNCERTAIN' ? ' · Needs review' : ''}`, 'conversation-meta'));
      button.onclick = () => void run(current => select(c.id, current)); $('conversation-list').append(button);
    }
  }
  async function copy(text, button) { try { await win.navigator.clipboard.writeText(text); button.setAttribute('aria-label', 'Copied'); button.title = 'Copied'; $('chat-draft-state').textContent = 'Copied to clipboard'; } catch { notice('Copy is unavailable in this browser. Select the text to copy it.'); } }
  function latestButton() { const t = $('chat-history'); $('chat-latest').hidden = t.scrollHeight - t.scrollTop - t.clientHeight < 100; }
  function draw({ reset = false, earlier = false } = {}) {
    const timeline = $('chat-history'), nearEnd = timeline.scrollHeight - timeline.scrollTop - timeline.clientHeight < 80, oldHeight = timeline.scrollHeight, oldTop = timeline.scrollTop;
    timeline.querySelector('.earlier-messages')?.remove(); const existing = new Map([...timeline.querySelectorAll(':scope > .chat-turn')].map(n => [n.dataset.turn, n]));
    if (!messages.length) { timeline.replaceChildren(); const empty = node('div', undefined, 'chat-empty'); empty.append(icon('spark'), node('h2', selected ? 'Your conversation starts here' : 'What are we building?'), node('p', selected ? 'Actual CLI replies will appear here after a local session runs.' : project ? 'Choose a conversation or start a new one.' : 'Open the conversation menu to choose or create a project.', 'muted')); timeline.append(empty); }
    else {
      timeline.querySelector('.chat-empty')?.remove(); let previous = null;
      for (const m of messages) {
        const signature = JSON.stringify(m); let turn = existing.get(m.id);
        if (!turn || turn.dataset.signature !== signature) {
          const replacement = node('section', undefined, 'chat-turn'); replacement.dataset.turn = m.id; replacement.dataset.signature = signature;
          const user = node('article', undefined, 'chat-message chat-user'), userHeader = node('div', undefined, 'message-meta'); userHeader.append(node('strong', 'You'), node('time', time(m.createdAt))); user.append(userHeader, node('p', m.prompt, 'chat-text'));
          const actions = node('div', undefined, 'user-message-actions'), copyPrompt = node('button', undefined, 'icon-button'), reusePrompt = node('button', 'Reuse prompt', 'reuse-prompt');
          copyPrompt.type = reusePrompt.type = 'button'; copyPrompt.setAttribute('aria-label', 'Copy user message'); copyPrompt.title = 'Copy user message'; copyPrompt.append(icon('copy')); copyPrompt.onclick = () => void copy(m.prompt, copyPrompt);
          reusePrompt.title = 'Add this message to your current draft'; reusePrompt.onclick = () => addToDraft(m.prompt); actions.append(copyPrompt, reusePrompt); user.append(actions); replacement.append(user);
          if (m.response !== null) {
            const agent = node('article', undefined, 'chat-message chat-agent'), header = node('div', undefined, 'agent-heading'), badge = node('span', undefined, 'agent-mark'); badge.append(icon('spark')); header.append(badge, node('h2', 'Antigravity'), node('time', time(m.finishedAt)));
            const content = node('div', undefined, 'markdown-content'); content.append(renderMarkdown(doc, m.response, copy));
            const foot = node('div', undefined, 'agent-footer'), copied = node('button', undefined, 'icon-button'); copied.type = 'button'; copied.setAttribute('aria-label', 'Copy response'); copied.append(icon('copy')); copied.onclick = () => void copy(m.response, copied); foot.append(node('span', 'CLI response', 'fine'), copied); agent.append(header, content, foot); replacement.append(agent);
          }
          const labels = { COMPLETED: 'Reply recorded', DISPATCHING: 'Awaiting CLI reply', FAILED: 'Execution failed', UNCERTAIN: 'Delivery uncertain' }, status = node('p', `${labels[m.status] ?? m.status}${m.error ? ` · ${m.error}` : ''}`, 'turn-status'); status.dataset.status = m.status; replacement.append(status);
          if (m.status === 'UNCERTAIN') replacement.append(node('p', 'Delivery was interrupted. This message will not be resent automatically. Review it before starting a new conversation.', 'snapshot-note'));
          if (turn) turn.replaceWith(replacement); turn = replacement;
        }
        const expected = previous ? previous.nextElementSibling : timeline.firstElementChild; if (expected !== turn) timeline.insertBefore(turn, expected); previous = turn; existing.delete(m.id);
      }
      for (const leftover of existing.values()) leftover.remove();
    }
    if (before) { const button = node('button', 'Load earlier messages', 'secondary earlier-messages'); button.type = 'button'; button.onclick = () => void run(async current => { const result = await api.messages(selected, before); if (current()) { before = result.nextBefore; merge(result.messages, true); } }); timeline.prepend(button); }
    if (reset) timeline.scrollTop = scrolls.has(selected) ? scrolls.get(selected) : timeline.scrollHeight; else if (earlier) timeline.scrollTop = oldTop + timeline.scrollHeight - oldHeight; else if (nearEnd) timeline.scrollTop = timeline.scrollHeight; else timeline.scrollTop = oldTop; latestButton();
  }
  function merge(values, earlier = false) { const byId = new Map(messages.map(m => [m.id, m])); for (const value of values) byId.set(value.id, value); messages = [...byId.values()].sort((a, b) => a.sequence - b.sequence).slice(-200); draw({ earlier }); }
  async function run(fn, quiet = false) {
    if (!ready || busy || (quiet && refreshing)) return;
    const epoch = generation, serial = ++operation;
    if (quiet) refreshing = true; else { busy = true; controls(); notice('Loading…'); }
    const current = () => epoch === generation && serial === operation;
    try { await fn(current); if (current()) { if (!quiet) notice(); connection = 'online'; } }
    catch (error) { if (current()) { notice(error.message); if (error.status === 0) connection = 'offline'; else if (error.status >= 500) connection = 'error'; if (error.status === 401) expired(); } }
    finally { if (epoch === generation) { if (quiet) refreshing = false; else busy = false; controls(); } }
  }
  async function loadList(current) { if (!project) return; const result = await api.conversations(project, $('conversation-search').value.trim(), $('include-archived').checked); if (current()) { conversations = result.conversations; drawList(); } }
  async function search() {
    if (!ready || !project) return; const serial = ++searchVersion, epoch = generation, projectId = project; $('drawer-search-status').textContent = 'Searching…';
    try { const result = await api.conversations(projectId, $('conversation-search').value.trim(), $('include-archived').checked); if (serial !== searchVersion || epoch !== generation || projectId !== project) return; conversations = result.conversations; drawList(); $('drawer-search-status').textContent = `${conversations.length} conversation${conversations.length === 1 ? '' : 's'}`; }
    catch (error) { if (serial === searchVersion && epoch === generation) { $('drawer-search-status').textContent = error.message; if (error.status === 401) expired(); } }
  }
  async function loadProject(id, current) {
    keepDraft(); searchVersion++; const previousProject = project;
    if (!id) { project = selected = ''; conversation = notes = null; conversations = messages = []; before = null; $('context-summary').value = $('context-handoff').value = ''; drawList(); draw({ reset: true }); restoreDraft(); return; }
    const [list, context, repos] = await Promise.all([api.conversations(id), api.projectContext(id), api.repositories()]); if (!current()) return;
    project = id; selected = ''; conversation = null; repositories = repos.repositories; conversations = list.conversations; messages = []; before = null; cursor = 0;
    const saved = noteDrafts.get(id); notes = saved?.base ?? context; $('context-summary').value = saved?.summary ?? context.summary; $('context-handoff').value = saved?.handoff ?? context.handoff;
    if (!previousProject && drafts.get('new:') && !drafts.has(scope())) drafts.set(scope(), drafts.get('new:')); $('conversation-search').value = ''; $('include-archived').checked = false; $('drawer-search-status').textContent = '';
    options('chat-repository', repositories, r => `${r.name} · ${r.branch}`, 'Choose registered repository'); if (repositories.length === 1) $('chat-repository').value = repositories[0].id; projectOptions(); drawList(); draw({ reset: true }); restoreDraft(); loaded = true;
  }
  async function select(id, current) {
    keepDraft(); const [result, history] = await Promise.all([api.conversation(id), api.messages(id)]); if (!current()) return;
    if (!result.archived) { await api.openProject(result.projectId, result.id); if (!current()) return; }
    if (project !== result.projectId) { await loadProject(result.projectId, current); if (!current()) return; }
    selected = id; conversation = result; cursor = result.eventSequence; messages = history.messages; before = history.nextBefore; if (!conversations.some(c => c.id === id) && !result.archived) conversations.push(result);
    $('chat-session').textContent = `${result.provider} · ${result.nativeSessionId ? `Native session ${result.nativeSessionId}\nProfile ${result.profileBinding}` : 'No native session recorded'}\nConversation ${id}`;
    win.history.replaceState(null, '', `#chat/${id}`); drawList(); draw({ reset: true }); restoreDraft(); if (!wide.matches) closeDrawer(); controls();
  }
  async function refresh(current) {
    if (!selected) { if (project) await loadList(current); return; }
    const id = selected, page = await api.chatEvents(id, cursor); if (!current() || selected !== id) return;
    if (page.nextCursor !== cursor) { const [history, result] = await Promise.all([api.messages(id), api.conversation(id)]); if (!current()) return; merge(history.messages); cursor = page.nextCursor; conversation = result; await loadList(current); }
    const step = page.events.findLast(e => e.kind === 'CLI_STEP'); $('chat-progress').textContent = step && messages.some(m => m.status === 'DISPATCHING') ? `CLI ${step.payload.stepType} · ${step.payload.state}` : '';
  }
  function download(filename, text) { const url = win.URL.createObjectURL(new Blob([text], { type: 'text/markdown;charset=utf-8' })), link = node('a'); link.href = url; link.download = filename; doc.body.append(link); link.click(); link.remove(); win.setTimeout(() => win.URL.revokeObjectURL(url), 1000); }
  function newConversation() { closeDrawer(); creating = true; $('chat-title').value = ''; modal('chat-new-dialog'); }
  $('drawer-toggle').onclick = () => { if ($('conversation-drawer').open) { desktopDrawer = false; closeDrawer(); } else { desktopDrawer = true; openDrawer(); } };
  $('drawer-close').onclick = () => { desktopDrawer = false; closeDrawer(); $('drawer-toggle').focus(); }; $('project-switch').onclick = openDrawer;
  $('drawer-new').onclick = $('menu-new').onclick = newConversation; $('menu-details').onclick = $('composer-context').onclick = () => modal('chat-details-dialog');
  $('composer-prompts').onclick = () => { notice(); modal('chat-prompts-dialog'); };
  const promptShortcuts = [
    ['Explain code', 'Understand a file, function or unfamiliar module.', 'Explain the relevant code and how it fits into this project. Do not modify files.\n\nFocus:'],
    ['Debug a problem', 'Trace the cause before proposing a change.', 'Investigate this problem. Trace the likely cause, describe the evidence and propose a focused fix. Do not commit or push.\n\nProblem:'],
    ['Write tests', 'Cover behavior, edge cases and regressions.', 'Write focused tests for the behavior below. Follow the existing test conventions, run the relevant checks and report their actual results. Do not commit or push.\n\nBehavior:'],
    ['Review changes', 'Inspect the diff and identify concrete issues.', 'Review the current changes for bugs, regressions and missing tests. Cite relevant files and explain the impact. Do not modify files, commit or push.\n\nFocus:'],
  ];
  for (const [title, description, text] of promptShortcuts) {
    const button = node('button', undefined, 'prompt-shortcut'); button.type = 'button'; button.append(node('strong', title), node('span', description)); button.onclick = () => addToDraft(text); $('chat-prompt-list').append(button);
  }
  doc.querySelectorAll('[data-close]').forEach(button => { button.onclick = () => { $(button.dataset.close).close(); creating = false; }; });
  for (const id of ['conversation-drawer', 'chat-new-dialog', 'chat-details-dialog', 'chat-rename-dialog', 'chat-prompts-dialog']) $(id).addEventListener('click', event => { if (event.target === $(id)) { const r = $(id).getBoundingClientRect(); if (event.clientX < r.left || event.clientX > r.right || event.clientY < r.top || event.clientY > r.bottom) $(id).close(); } });
  $('conversation-drawer').addEventListener('close', () => { $('drawer-toggle').setAttribute('aria-expanded', 'false'); doc.querySelector('.app-shell').classList.remove('drawer-visible'); });
  $('chat-new-dialog').addEventListener('close', () => { creating = false; });
  $('conversation-search').oninput = () => { win.clearTimeout(searchTimer); searchTimer = win.setTimeout(() => void search(), 350); }; $('include-archived').onchange = () => void search();
  $('chat-project').onchange = () => void run(async current => { await loadProject($('chat-project').value, current); if (!current()) return; if (conversations[0]) await select(conversations[0].id, current); else win.history.replaceState(null, '', '#chat'); });
  $('chat-create-form').onsubmit = event => { event.preventDefault(); void run(async current => { if (!project || !$('chat-repository').value) throw new Error('Choose a project and registered repository first.'); const result = await api.createConversation(project, $('chat-repository').value, $('chat-title').value); if (!current()) return; const draft = drafts.get(`new:${project}`); if (draft) drafts.set(result.id, draft); conversations.unshift(result); $('chat-new-dialog').close(); creating = false; await select(result.id, current); }); };
  $('chat-refresh').onclick = () => { $('chat-overflow').open = false; void run(refresh); };
  $('menu-rename').onclick = () => { if (conversation) { $('rename-title').value = conversation.title; modal('chat-rename-dialog'); } };
  $('chat-rename-form').onsubmit = event => { event.preventDefault(); void run(async current => { const result = await api.updateConversation(selected, conversation.revision, { title: $('rename-title').value }); if (current()) { conversation = result; $('chat-rename-dialog').close(); await loadList(current); } }); };
  $('menu-archive').onclick = () => { if (!conversation || (!conversation.archived && !win.confirm('Archive this conversation? Its messages and transcript will be kept.'))) return; $('chat-overflow').open = false; void run(async current => { const result = await api.updateConversation(selected, conversation.revision, { archived: !conversation.archived }); if (current()) { conversation = result; await loadList(current); } }); };
  $('context-summary').oninput = $('context-handoff').oninput = () => { keepNotes(); controls(); };
  $('context-save').onclick = () => void run(async current => { if (!project || !notes) throw new Error('Choose a project first.'); const result = await api.saveContext(project, notes.revision, $('context-summary').value, $('context-handoff').value); if (current()) { notes = result; keepNotes(); } });
  $('context-reload').onclick = () => { if (project && (!dirty() || win.confirm('Discard your unsaved project context notes?'))) void run(async current => { const result = await api.projectContext(project); if (current()) { notes = result; $('context-summary').value = result.summary; $('context-handoff').value = result.handoff; keepNotes(); } }); };
  $('chat-download').onclick = () => { $('chat-overflow').open = false; void run(async current => { const result = await api.transcript(selected); if (current()) download(result.filename, result.markdown); }); };
  for (const [button, name, field] of [['context-download', 'PROJECT_CONTEXT.md', 'project'], ['handoff-download', 'latest-handoff.md', 'handoff']]) $(button).onclick = () => void run(async current => { const result = await api.exportContext(project); if (current()) download(name, result[field]); });
  let enter = 'newline'; try { enter = win.localStorage.getItem('jess-enter') ?? 'newline'; } catch { /* In-memory preference. */ } $('enter-behavior').value = enter;
  $('enter-behavior').onchange = () => { enter = $('enter-behavior').value; try { win.localStorage.setItem('jess-enter', enter); } catch { /* In-memory preference. */ } };
  $('chat-input').oninput = () => { drafts.set(scope(), $('chat-input').value); sizeInput(); $('chat-draft-state').textContent = 'Draft kept on this page · Not sent'; };
  $('chat-input').onkeydown = event => { if (enter === 'send' && event.key === 'Enter' && !event.shiftKey && !event.isComposing) { event.preventDefault(); $('chat-compose-form').requestSubmit(); } };
  $('chat-compose-form').onsubmit = event => { event.preventDefault(); notice('This is an unsent draft. Remote agent messaging is not enabled on this server.'); };
  $('chat-history').onscroll = latestButton; $('chat-latest').onclick = () => $('chat-history').scrollTo({ top: $('chat-history').scrollHeight, behavior: win.matchMedia('(prefers-reduced-motion:reduce)').matches ? 'instant' : 'smooth' });
  const viewport = () => { doc.documentElement.style.setProperty('--app-height', `${win.visualViewport?.height ?? win.innerHeight}px`); doc.documentElement.style.setProperty('--app-top', `${win.visualViewport?.offsetTop ?? 0}px`); };
  const resized = () => { viewport(); if (active && $('conversation-drawer').open) { const wasDesktop = $('conversation-drawer').classList.contains('desktop'); closeDrawer(); if (wide.matches || !wasDesktop) openDrawer(); } }, drawerKeyboard = event => { if (event.key === 'Escape' && $('conversation-drawer').open) { desktopDrawer = false; closeDrawer(); } };
  const online = () => { controls(); if (ready && active) void run(refresh, true); }, offline = () => { connection = 'offline'; controls(); }, leaving = event => { if ($('chat-input').value || dirty() || [...drafts.values()].some(Boolean) || [...noteDrafts.values()].some(d => d.summary !== d.base.summary || d.handoff !== d.base.handoff)) { event.preventDefault(); event.returnValue = ''; } };
  win.addEventListener('beforeunload', leaving); win.addEventListener('online', online); win.addEventListener('offline', offline); win.addEventListener('resize', resized); doc.addEventListener('keydown', drawerKeyboard); win.visualViewport?.addEventListener('resize', viewport); win.visualViewport?.addEventListener('scroll', viewport); viewport();
  // Background replay must not disable an editor action between pointer-down and click.
  const timer = win.setInterval(() => { if (ready && active && !doc.hidden && !doc.querySelector('.chat-dialog[open]') && win.navigator.onLine) void run(refresh, true); }, 3000);
  return {
    update(state, visible) {
      if (active && !visible) { keepDraft(); closePanels(); } active = visible; const authenticated = state.session === 'ready'; connection = state.connection;
      if (!authenticated && ready) { generation++; searchVersion++; busy = refreshing = loaded = false; project = selected = ''; conversations = messages = []; notes = conversation = null; cursor = 0; before = null; drafts.clear(); noteDrafts.clear(); scrolls.clear(); for (const id of ['context-summary', 'context-handoff', 'chat-title', 'chat-input', 'rename-title', 'conversation-search']) $(id).value = ''; $('chat-repository').replaceChildren(); $('chat-session').textContent = $('chat-progress').textContent = ''; notice(); closePanels(); draw(); drawList(); }
      ready = authenticated; projects = ready ? state.projects : []; projectOptions(); controls();
      if (ready && active && wide.matches && desktopDrawer && !$('conversation-drawer').open && !doc.querySelector('.chat-dialog[open]')) openDrawer();
      const requested = /^#chat\/([a-f0-9-]{36})$/i.exec(win.location.hash)?.[1];
      const requestedProject = /^#chat\/project\/([a-f0-9-]{36})$/i.exec(win.location.hash)?.[1];
      if (ready && active && !creating && !busy && (!loaded || (!project && projects.length) || (requested && requested !== selected) || (requestedProject && (requestedProject !== project || selected)))) void run(async current => { if (requested) { await select(requested, current); if (current()) loaded = true; } else if (requestedProject || projects.length) { await loadProject(requestedProject ?? projects[0].id, current); if (current() && conversations[0]) await select(conversations[0].id, current); } else { draw(); drawList(); loaded = true; } });
    },
    destroy() { generation++; win.clearInterval(timer); win.clearTimeout(searchTimer); win.removeEventListener('beforeunload', leaving); win.removeEventListener('online', online); win.removeEventListener('offline', offline); win.removeEventListener('resize', resized); doc.removeEventListener('keydown', drawerKeyboard); win.visualViewport?.removeEventListener('resize', viewport); win.visualViewport?.removeEventListener('scroll', viewport); closePanels(); },
  };
}
