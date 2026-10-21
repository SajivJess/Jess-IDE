import { createApi } from './api.js';
import { createController, isActive } from './state.js';
import { mountFiles } from './files.js';
import { mountChat } from './chat.js';
import { mountHome } from './home.js';

export function mountApp(doc = document, win = window, controller = createController(createApi())) {
  const $ = id => doc.getElementById(id);
  const node = (tag, text, className) => {
    const element = doc.createElement(tag);
    if (text !== undefined) element.textContent = text;
    if (className) element.className = className;
    return element;
  };
  const icon = name => {
    const svg = doc.createElementNS('http://www.w3.org/2000/svg', 'svg');
    const use = doc.createElementNS('http://www.w3.org/2000/svg', 'use');
    use.setAttribute('href', `#i-${name}`); svg.setAttribute('aria-hidden', 'true'); svg.append(use); return svg;
  };
  const button = (text, action, className = 'secondary') => {
    const element = node('button', text, className); element.type = 'button'; element.onclick = action; return element;
  };
  const date = value => {
    const time = new Date(value);
    return Number.isNaN(time.getTime()) ? '' : time.toLocaleString(undefined, { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' });
  };
  const empty = (title, description, symbol = 'folder') => {
    const element = node('div', undefined, 'empty-state');
    element.append(icon(symbol), node('h2', title), node('p', description)); return element;
  };
  const status = task => {
    const label = node('span', task.cancelRequested && isActive(task) ? 'CANCELLING' : task.status, 'status');
    label.dataset.status = task.status; return label;
  };
  let detailTab = 'Activity';
  let projectSignature = '';
  let previousSession = 'checking';
  let installPrompt = null;
  let selectedTask = null;
  const files = mountFiles(doc, win, createApi(), () => controller.expire());
  const chat = mountChat(doc, win, createApi(), () => controller.expire());
  const home = mountHome(doc, win, createApi(), () => controller.expire(), () => controller.refresh());

  function navigate(focus = false) {
    const page = win.location.hash.slice(1).split('/')[0];
    const current = ['home', 'compose', 'projects', 'tasks', 'files', 'settings', 'chat'].includes(page) ? page : 'home';
    doc.querySelector('.app-shell').dataset.view = current;
    doc.body.dataset.view = current;
    files.update(controller.state, current === 'files');
    chat.update(controller.state, current === 'chat');
    home.update(controller.state, current === 'home');
    $('navigation').hidden = controller.state.session !== 'ready' || current === 'home';
    doc.querySelectorAll('.page').forEach(section => { section.hidden = section.id !== `page-${current}`; });
    doc.querySelectorAll('[data-page]').forEach(link => {
      if (link.dataset.page === current) link.setAttribute('aria-current', 'page'); else link.removeAttribute('aria-current');
    });
    if (focus && controller.state.session === 'ready') $('main').focus({ preventScroll: true });
  }
  function openTask(id) {
    detailTab = 'Activity'; win.location.hash = 'tasks'; navigate();
    void controller.selectTask(id).then(() => $('task-detail').scrollIntoView?.({ block: 'start', behavior: 'instant' }));
  }
  function projectCard(project) {
    const element = button('', () => { $('project').value = project.id; win.location.hash = 'compose'; navigate(); $('prompt').focus(); }, 'panel project-card');
    const badge = node('span', undefined, 'project-icon'); badge.append(icon('folder'));
    const arrow = icon('arrow'); arrow.classList.add('card-arrow');
    element.append(badge, arrow, node('h3', project.name), node('p', 'Task workspace', 'muted'), node('p', `Created ${date(project.createdAt)}`, 'fine'));
    return element;
  }
  function taskCard(task, state, prefix) {
    const element = button('', () => openTask(task.id), 'task-card');
    element.id = `${prefix}-${task.id}`;
    element.setAttribute('aria-pressed', String(task.id === state.selectedId));
    const heading = node('div', undefined, 'task-card-header');
    heading.append(status(task), node('time', date(task.createdAt), 'task-meta'));
    const project = state.projects.find(p => p.id === task.projectId);
    element.append(heading, node('h3', task.prompt), node('p', project?.name ?? `Project ${task.projectId.slice(0, 8)}`, 'fine'));
    return element;
  }
  function drawDetail(state) {
    const container = $('task-detail');
    const oldScroll = container.querySelector('.event-list')?.scrollTop ?? 0;
    container.replaceChildren();
    if (!state.selectedId) { container.append(empty('The full story, in one place.', 'Select a task to see its activity, file changes and checks.', 'tasks')); return; }
    const task = state.tasks.find(item => item.id === state.selectedId);
    if (!task) { container.append(empty(state.notice ? 'Task unavailable' : 'Loading task…', state.notice ? 'Refresh or select another task to try again.' : 'Retrieving the latest state from your laptop.', 'tasks')); return; }
    if (selectedTask !== task.id) { detailTab = 'Activity'; selectedTask = task.id; }
    const header = node('div', undefined, 'detail-header');
    header.append(status(task), button('Close', () => controller.closeTask()));
    container.append(header, node('h2', task.prompt, 'detail-title'), node('p', `Attempt ${task.attempt} of ${task.maxAttempts} · Updated ${date(task.updatedAt)}`, 'fine'));
    if (task.error) container.append(node('p', task.error, 'detail-description'));
    if (task.result) {
      container.append(node('p', task.result.simulated ? 'SIMULATED RESULT · No real files were edited' : 'WORKSPACE RESULT', 'section-kicker'), node('p', task.result.summary, 'detail-description'));
    }
    if (isActive(task)) {
      const cancel = button(task.cancelRequested ? 'Cancellation requested' : 'Cancel task', () => void controller.cancel(task.id));
      cancel.id = 'cancel-task'; cancel.disabled = state.busy || task.cancelRequested || state.connection !== 'online'; container.append(cancel);
    }
    const tabs = node('div', undefined, 'detail-tabs'); tabs.setAttribute('role', 'tablist'); tabs.setAttribute('aria-label', 'Task detail');
    for (const title of ['Activity', 'Changes', 'Checks']) {
      const tab = button(title, () => { detailTab = title; drawDetail(controller.state); $(`tab-${title}`).focus(); }, '');
      tab.id = `tab-${title}`; tab.setAttribute('role', 'tab'); tab.setAttribute('aria-selected', String(detailTab === title));
      tab.setAttribute('aria-controls', 'detail-content'); tab.tabIndex = detailTab === title ? 0 : -1;
      tab.onkeydown = event => {
        if (!['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) return;
        event.preventDefault();
        const titles = ['Activity', 'Changes', 'Checks'];
        detailTab = event.key === 'Home' ? titles[0] : event.key === 'End' ? titles[2] : titles[(titles.indexOf(title) + (event.key === 'ArrowRight' ? 1 : 2)) % 3];
        drawDetail(controller.state); $(`tab-${detailTab}`).focus();
      };
      tabs.append(tab);
    }
    const content = node('div'); content.id = 'detail-content'; content.setAttribute('role', 'tabpanel'); content.setAttribute('aria-labelledby', `tab-${detailTab}`);
    container.append(tabs, content);
    if (detailTab === 'Activity') {
      const list = node('ol', undefined, 'event-list');
      for (const event of state.events) {
        const item = node('li', undefined, 'event-item');
        item.append(node('strong', event.type.replaceAll('_', ' ').toLowerCase()), node('time', ` · ${date(event.timestamp)}`));
        const message = event.payload.message ?? event.payload.summary ?? event.payload.phase;
        if (typeof message === 'string') item.append(node('p', message));
        list.append(item);
      }
      content.append(list); list.scrollTop = oldScroll;
      if (!state.events.length) content.append(node('p', 'No activity loaded yet. Refresh to retrieve events.', 'muted'));
      if (state.eventMore) content.append(button('Load more activity', () => void controller.selectTask(task.id, true)));
      content.append(node('p', `Showing up to 500 recent events. Cursor ${state.eventCursor}.`, 'fine'));
    } else if (detailTab === 'Changes') {
      if (!task.result) { content.append(node('p', 'File changes will appear when this task returns a result.', 'muted')); return; }
      for (const file of task.result.files) {
        const row = node('div', undefined, 'result-row'); row.append(node('code', file.path), node('span', file.change)); content.append(row);
      }
      const execution = task.result.execution;
      if (execution) {
        content.append(node('p', `Branch: ${execution.branch}`, 'fine'), node('p', `Base: ${execution.baseCommit}`, 'fine'));
        const diff = node('pre', undefined, 'diff'); diff.tabIndex = 0; diff.setAttribute('aria-label', 'Unified diff');
        // Text nodes only: repository contents can contain arbitrary HTML.
        for (const line of execution.diff.split('\n')) diff.append(node('span', line, `diff-line ${line.startsWith('+') ? 'added' : line.startsWith('-') ? 'deleted' : line.startsWith('@@') ? 'hunk' : ''}`));
        content.append(diff);
        if (execution.truncated) content.append(node('p', 'This diff was truncated by the server. Review the full diff on the laptop before approval.', 'fine'));
      } else content.append(node('p', task.result.simulated ? 'These are simulated file names. No Git diff was produced.' : 'No Git diff was returned for this task.', 'fine'));
      content.append(node('p', 'Commit and push approvals are not available yet.', 'fine'));
    } else {
      if (!task.result?.checks.length) content.append(node('p', 'No check results available yet.', 'muted'));
      for (const check of task.result?.checks ?? []) {
        const row = node('div', undefined, 'result-row'); row.append(node('span', check.name), node('strong', check.status)); content.append(row);
      }
    }
  }
  function render(state) {
    const activeId = doc.activeElement?.id;
    $('boot').hidden = state.session !== 'checking';
    $('login').hidden = state.session !== 'locked';
    $('workspace').hidden = $('navigation').hidden = state.session !== 'ready';
    $('notice').hidden = !state.notice; $('notice').textContent = state.notice;
    $('connection').dataset.status = state.connection;
    $('connection-label').textContent = ({ online: 'Laptop online', offline: 'Offline', error: 'Connection issue', checking: 'Connecting', unknown: 'Signed out' })[state.connection];
    $('login-button').disabled = state.busy;
    $('login-button').firstChild.textContent = state.busy ? 'Signing in… ' : 'Sign in ';
    if (state.session !== 'ready' && previousSession === 'ready') {
      $('prompt').value = ''; $('prompt-count').textContent = '0 / 8,000'; $('project-name').value = ''; projectSignature = ''; selectedTask = null;
    }
    previousSession = state.session;
    const available = state.capabilities.taskSubmission === true;
    const mode = available ? 'Simulated agent' : 'Real agent · local only';
    $('mode-badge').textContent = mode;
    const explanation = available ? 'Development preview: tasks simulate progress and results. They do not edit files or run checks.' : 'Real-agent tasks are available only on the laptop. Public submission is disabled until workspace isolation and authorization are ready.';
    $('task-mode').textContent = $('settings-agent').textContent = explanation;
    $('submit-task').disabled = state.busy || !available || !state.projects.length || state.connection !== 'online';
    $('submit-task').firstChild.textContent = state.busy ? 'Working… ' : available ? 'Run simulated task ' : 'Submission unavailable ';
    $('create-project').disabled = state.busy || state.connection !== 'online';
    $('logout').disabled = state.busy; $('refresh').disabled = state.busy;
    const signature = JSON.stringify(state.projects.map(p => [p.id, p.name]));
    if (signature !== projectSignature) {
      const chosen = $('project').value; projectSignature = signature;
      $('project').replaceChildren();
      if (!state.projects.length) { const option = node('option', 'Create a project to begin'); option.value = ''; $('project').append(option); }
      for (const project of state.projects) { const option = node('option', project.name); option.value = project.id; $('project').append(option); }
      if (state.projects.some(p => p.id === chosen)) $('project').value = chosen;
    }
    $('project-help').textContent = state.projects.length ? 'Choose a project. Load more projects on the Projects tab if needed.' : 'Create your first project in the Projects tab to begin.';
    $('active-count').textContent = String(state.tasks.filter(isActive).length);
    const activeTask = state.tasks.find(isActive);
    $('active-summary').textContent = activeTask ? `${activeTask.status} · ${activeTask.prompt.slice(0, 120)}` : state.lastSynced ? 'No active tasks in loaded history.' : 'Waiting for task activity.';
    for (const [id, projects] of [['projects', state.projects]]) {
      $(id).replaceChildren(...projects.map(projectCard));
      if (!projects.length) $(id).append(empty(state.lastSynced ? 'Room for your next idea' : 'Waiting for your projects', state.lastSynced ? 'Create a project to organize your first task.' : 'Connect to your laptop to load projects.'));
    }
    for (const [id, tasks] of [['tasks', state.tasks.filter(task => (!$('task-filter').value || task.status === $('task-filter').value) && task.prompt.toLowerCase().includes($('task-search').value.toLowerCase()))]]) {
      $(id).replaceChildren(...tasks.map(task => taskCard(task, state, id)));
      if (!tasks.length) $(id).append(empty(state.lastSynced ? 'Your first task starts here' : 'Waiting for task history', state.lastSynced ? 'Describe a task on Home and follow its progress here.' : 'Task history will load when the laptop is reachable.', 'tasks'));
    }
    $('more-projects').hidden = !state.projectCursor; $('more-tasks').hidden = !state.taskCursor;
    $('more-projects').disabled = $('more-tasks').disabled = state.busy;
    $('last-sync').textContent = state.lastSynced ? date(state.lastSynced) : 'Not yet connected';
    drawDetail(state);
    if (activeId && $(activeId) && doc.activeElement !== $(activeId) && !$(activeId).disabled) $(activeId).focus({ preventScroll: true });
    navigate();
  }

  $('server-origin').textContent = win.location.origin;
  $('greeting').textContent = 'Task composer';
  let storedTheme = 'dark';
  try { storedTheme = win.localStorage.getItem('jess-theme') ?? 'dark'; } catch { /* Private browsing can disable storage. */ }
  const theme = value => {
    value = ['dark', 'light'].includes(value) ? value : 'system';
    if (value === 'system') delete doc.documentElement.dataset.theme; else doc.documentElement.dataset.theme = value;
    $('theme').value = value;
    try { win.localStorage.setItem('jess-theme', value); } catch { /* Theme still works in memory. */ }
  };
  theme(storedTheme);
  // Retire the original portal's browser-local task content; PostgreSQL is the source of truth.
  try { win.localStorage.removeItem('jess-tasks'); win.localStorage.removeItem('jess-projects'); } catch { /* No persistent storage available. */ }
  $('theme').onchange = event => theme(event.target.value);
  $('login-form').onsubmit = async event => { event.preventDefault(); const password = $('password').value; $('password').value = ''; await controller.login(password); };
  $('logout').onclick = () => void controller.logout();
  $('refresh').onclick = () => void controller.refresh();
  $('project-form').onsubmit = async event => { event.preventDefault(); if (await controller.createProject($('project-name').value)) $('project-name').value = ''; };
  $('task-form').onsubmit = async event => {
    event.preventDefault();
    if (await controller.submit($('project').value, $('prompt').value)) { $('prompt').value = ''; $('prompt-count').textContent = '0 / 8,000'; win.location.hash = 'tasks'; navigate(); }
  };
  $('prompt').oninput = () => { $('prompt-count').textContent = `${$('prompt').value.length.toLocaleString()} / 8,000`; };
  doc.querySelectorAll('[data-prompt]').forEach(button => { button.onclick = () => { if (!$('prompt').value || win.confirm('Replace the current task draft?')) { $('prompt').value = button.dataset.prompt; $('prompt').oninput(); $('prompt').focus(); } }; });
  $('task-search').oninput = () => render(controller.state);
  $('task-filter').onchange = () => render(controller.state);
  $('more-projects').onclick = () => void controller.more('projects');
  $('more-tasks').onclick = () => void controller.more('tasks');
  const hashChanged = () => navigate(true);
  const visible = () => { if (!doc.hidden) void controller.refresh(); };
  const online = () => void controller.refresh();
  const offline = () => controller.offline();
  const install = event => { event.preventDefault(); installPrompt = event; $('install').hidden = false; };
  win.addEventListener('hashchange', hashChanged); doc.addEventListener('visibilitychange', visible);
  win.addEventListener('online', online); win.addEventListener('offline', offline); win.addEventListener('beforeinstallprompt', install);
  $('install').onclick = async () => { if (installPrompt) { await installPrompt.prompt(); installPrompt = null; $('install').hidden = true; } };
  const timer = win.setInterval(() => { if (!doc.hidden && win.navigator.onLine) void controller.refresh(); }, 10000);
  if ('serviceWorker' in win.navigator && win.isSecureContext) void win.navigator.serviceWorker.register('/sw.js').catch(() => { $('install-help').textContent = 'Home-screen installation is not available in this browser session. Jess still works in your browser.'; });
  const unsubscribe = controller.subscribe(render);
  void controller.start();
  return () => {
    files.destroy(); chat.destroy(); home.destroy();
    unsubscribe(); win.clearInterval(timer);
    win.removeEventListener('hashchange', hashChanged); doc.removeEventListener('visibilitychange', visible);
    win.removeEventListener('online', online); win.removeEventListener('offline', offline); win.removeEventListener('beforeinstallprompt', install);
  };
}

if (typeof document !== 'undefined') mountApp();
