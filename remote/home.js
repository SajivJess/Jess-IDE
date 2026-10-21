export function mountHome(doc, win, api, expired, refreshState) {
  const $ = id => doc.getElementById(id), node = (tag, text, cls) => { const n = doc.createElement(tag); if (text !== undefined) n.textContent = text; if (cls) n.className = cls; return n; };
  const icon = name => { const n = doc.createElementNS('http://www.w3.org/2000/svg', 'svg'), use = doc.createElementNS(n.namespaceURI, 'use'); use.setAttribute('href', `#i-${name}`); n.setAttribute('aria-hidden', 'true'); n.append(use); return n; };
  let ready = false, active = false, busy = false, loading = false, generation = 0, loadSerial = 0, searchSerial = 0, searchTimer, stamp, loaded = false, projects = [], recent = null, total = 0, offset = null, connection = 'checking', profileDirty = false, partialProject = null;
  const date = value => new Date(value).toLocaleString(undefined, { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' });
  function message(text = '') { $('home-message').textContent = text; }
  function fail(error) { message(error.message); if (error.status === 401) expired(); }
  function controls() { for (const id of ['home-create', 'home-create-submit', 'home-more', 'home-refresh', 'home-sort', 'profile-save']) $(id).disabled = !ready || connection !== 'online' || busy || loading; if (partialProject) $('home-create-submit').disabled = true; doc.querySelectorAll('[data-home-project]').forEach(n => { n.disabled = !ready || connection !== 'online' || busy; }); }
  function availability(p) { return p.conversation?.lastStatus === 'DISPATCHING' ? 'Awaiting CLI reply' : p.conversation?.lastStatus === 'UNCERTAIN' ? 'Delivery needs review' : p.conversation?.hasNativeSession ? 'Session saved · local only' : 'CLI not attached'; }
  function card(p, resume = false) {
    const button = node('button', undefined, resume ? 'resume-project' : 'launch-project'); button.type = 'button'; button.dataset.homeProject = p.id; button.setAttribute('aria-label', `${resume ? 'Resume' : 'Open'} ${p.name}`);
    const badge = node('span', undefined, 'launch-icon'); badge.append(icon(resume ? 'chat' : 'folder'));
    const content = node('span', undefined, 'launch-content'); content.append(node('strong', resume ? p.conversation?.title ?? p.name : p.name, 'launch-title'));
    const repo = p.repository ? new URL(p.repository.githubUrl).pathname.slice(1) : 'No repository linked';
    content.append(node('span', resume ? p.name : repo, 'launch-subtitle'));
    const meta = node('span', undefined, 'launch-meta'); if (p.repository) { const branch = node('span', p.repository.branch, 'branch-tag'); meta.append(branch); }
    meta.append(node('span', `${p.lastOpenedAt ? 'Opened' : 'Active'} ${date(p.lastOpenedAt ?? p.lastActivityAt)}`)); content.append(meta);
    const state = node('span', `Antigravity · ${availability(p)}`, 'launch-agent'); content.append(state); const arrow = icon('arrow'); arrow.classList.add('launch-arrow'); button.append(badge, content, arrow);
    button.onclick = () => void open(p.id, resume ? p.conversation?.id : undefined); return button;
  }
  function draw() {
    const focused = doc.activeElement?.dataset.homeProject;
    $('home-count').textContent = `${total} ${total === 1 ? 'project' : 'projects'}`;
    $('home-projects').replaceChildren(...projects.map(p => card(p)));
    if (!projects.length && loaded) { const empty = node('div', undefined, 'launch-empty'); empty.append(icon('folder'), node('h3', 'A place for your next idea'), node('p', 'Create a project, then connect a registered repository or start with a workspace.')); $('home-projects').append(empty); }
    $('home-continue').hidden = !recent; $('home-recent').replaceChildren(...(recent ? [card(recent, true)] : [])); $('home-more').hidden = offset === null; $('home-skeleton').hidden = loaded;
    if (focused) doc.querySelector(`[data-home-project="${focused}"]`)?.focus({ preventScroll: true }); controls();
  }
  async function load(more = false) {
    if (!ready || connection !== 'online' || loading) return;
    const epoch = generation, serial = ++loadSerial, sort = $('home-sort').value; loading = true; controls(); if (!loaded) $('home-skeleton').hidden = false;
    try { const result = await api.home(sort, more ? offset : 0); if (epoch !== generation || serial !== loadSerial || sort !== $('home-sort').value) return; projects = more ? [...new Map([...projects, ...result.projects].map(p => [p.id, p])).values()] : result.projects; recent = result.recent; total = result.total; offset = result.nextOffset; loaded = true; draw(); }
    catch (error) { if (epoch === generation && serial === loadSerial) { $('home-skeleton').hidden = true; fail(error); } }
    finally { if (epoch === generation && serial === loadSerial) { loading = false; controls(); } }
  }
  async function open(projectId, conversationId) {
    if (!ready || busy || connection !== 'online') return;
    busy = true; controls(); const epoch = generation;
    try { const result = await api.openProject(projectId, conversationId); if (epoch !== generation) return; $('global-search-dialog').close(); loaded = false; win.location.hash = result.conversationId ? `chat/${result.conversationId}` : `chat/project/${result.projectId}`; }
    catch (error) { if (epoch === generation) { fail(error); $('global-search-status').textContent = error.message; } }
    finally { if (epoch === generation) { busy = false; controls(); } }
  }
  async function search() {
    const query = $('global-search-input').value.trim(), serial = ++searchSerial, epoch = generation; $('global-search-results').replaceChildren();
    if (!ready || query.length < 2) { $('global-search-status').textContent = 'Search with at least two characters.'; return; }
    $('global-search-status').textContent = 'Searching your workspace…';
    try { const result = await api.searchWorkspace(query); if (epoch !== generation || serial !== searchSerial) return;
      $('global-search-status').textContent = result.results.length ? `${result.results.length} ${result.results.length === 1 ? 'result' : 'results'}` : 'No matching projects or conversations.';
      for (const item of result.results) { const button = node('button', undefined, 'search-result'); button.type = 'button'; const badge = icon(item.kind === 'conversation' ? 'chat' : 'folder'), content = node('span'); content.append(node('strong', item.title), node('span', item.detail, 'fine')); button.append(badge, content); button.onclick = () => void open(item.projectId, item.conversationId ?? undefined); $('global-search-results').append(button); }
    } catch (error) { if (epoch === generation && serial === searchSerial) { $('global-search-status').textContent = error.message; if (error.status === 401) expired(); } }
  }
  function showSearch() { if (!ready) return; if (!$('global-search-dialog').open) $('global-search-dialog').showModal(); $('global-search-input').focus(); }
  $('global-search-open').onclick = showSearch;
  $('global-search-close').onclick = () => $('global-search-dialog').close();
  $('global-search-input').oninput = () => { win.clearTimeout(searchTimer); searchTimer = win.setTimeout(() => void search(), 300); };
  $('global-search-dialog').onkeydown = event => { if (event.key === 'ArrowDown' && doc.activeElement === $('global-search-input')) { event.preventDefault(); $('global-search-results').querySelector('button')?.focus(); } };
  const shortcut = event => { if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 'k' && ready && !event.isComposing) { event.preventDefault(); showSearch(); } };
  doc.addEventListener('keydown', shortcut);
  $('home-refresh').onclick = () => { message(); void load(); }; $('home-more').onclick = () => void load(true);
  $('home-sort').onchange = () => { void load(); };
  $('home-view').onchange = () => { $('home-projects').dataset.layout = $('home-view').value; };
  $('home-create-close').onclick = () => $('home-create-dialog').close();
  $('home-create').onclick = async () => {
    if (partialProject) $('home-create-name').value = ''; partialProject = null; controls();
    $('home-create-dialog').showModal(); $('home-create-name').focus(); $('home-create-message').textContent = ''; const epoch = generation;
    try { const result = await api.repositories(); if (epoch !== generation) return; const select = $('home-create-repository'); select.replaceChildren(); const empty = node('option', 'Start without a repository'); empty.value = ''; select.append(empty); for (const repo of result.repositories) { const option = node('option', `${repo.name} · ${repo.branch}`); option.value = repo.id; select.append(option); } }
    catch (error) { if (epoch === generation) $('home-create-message').textContent = error.message; }
  };
  $('home-create-form').onsubmit = async event => {
    event.preventDefault(); if (busy || partialProject || !ready || connection !== 'online') return; const epoch = generation; busy = true; controls(); let project;
    try { project = await api.createProject($('home-create-name').value.trim()); if (epoch !== generation) return;
      let conversation; if ($('home-create-repository').value) conversation = await api.createConversation(project.id, $('home-create-repository').value, 'Project conversation'); if (epoch !== generation) return;
      $('home-create-name').value = ''; $('home-create-dialog').close(); loaded = false; await refreshState(); if (epoch !== generation) return; busy = false; await open(project.id, conversation?.id);
    } catch (error) { if (epoch === generation) { partialProject = project ?? null; fail(error); $('home-create-message').textContent = project ? 'Project created, but the next step failed. Close this form and refresh Home to open it; do not create it again.' : error.status === 0 ? 'Creation could not be confirmed. Refresh Home before trying again.' : error.message; loaded = false; void load(); } }
    finally { if (epoch === generation) { busy = false; controls(); } }
  };
  $('profile-name').oninput = () => { profileDirty = true; };
  $('profile-form').onsubmit = async event => {
    event.preventDefault(); if (busy || !ready) return; const epoch = generation; busy = true; controls(); $('profile-status').textContent = 'Saving…';
    try { await api.saveProfile($('profile-name').value); if (epoch !== generation) return; profileDirty = false; $('profile-status').textContent = 'Profile saved.'; await refreshState(); }
    catch (error) { if (epoch === generation) { $('profile-status').textContent = error.message; if (error.status === 401) expired(); } }
    finally { if (epoch === generation) { busy = false; controls(); } }
  };
  return {
    update(state, visible) {
      if (active && !visible) { loadSerial++; loading = false; }
      if (!active && visible) loaded = false;
      active = visible; connection = state.connection; const authenticated = state.session === 'ready';
      if (!authenticated && ready) { generation++; searchSerial++; loaded = loading = busy = profileDirty = false; partialProject = null; projects = []; recent = null; total = 0; offset = null; stamp = undefined; $('home-create-dialog').close(); $('global-search-dialog').close(); for (const id of ['profile-name', 'home-create-name', 'global-search-input']) $(id).value = ''; $('home-create-repository').replaceChildren(); $('global-search-results').replaceChildren(); $('global-search-status').textContent = $('profile-status').textContent = $('home-create-message').textContent = ''; message(); draw(); }
      ready = authenticated; $('global-search-open').hidden = !ready;
      $('home-welcome').textContent = state.user?.displayName ? `Welcome back, ${state.user.displayName} 👋` : 'Welcome back 👋';
      if (!profileDirty && doc.activeElement !== $('profile-name')) $('profile-name').value = state.user?.displayName ?? '';
      $('home-date').textContent = new Date().toLocaleDateString(undefined, { weekday: 'long', month: 'long', day: 'numeric' });
      $('home-availability').textContent = connection === 'online' ? 'Laptop reachable · Antigravity remote messaging unavailable' : connection === 'offline' ? 'Laptop unreachable · Showing previously loaded projects' : 'Checking laptop connection…';
      controls(); if (ready && active && connection === 'online' && !loading && (!loaded || stamp !== state.lastSynced)) { stamp = state.lastSynced; void load(); }
    },
    destroy() { generation++; win.clearTimeout(searchTimer); doc.removeEventListener('keydown', shortcut); },
  };
}
