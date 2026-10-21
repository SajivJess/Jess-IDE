/** Framework-independent state/controller. API contracts are documented in docs/mobile-web.md. */
export const isActive = task => ['QUEUED', 'RUNNING'].includes(task.status);
export function mergeById(previous, incoming) {
  const values = new Map(previous.map(item => [item.id, item]));
  for (const item of incoming) values.set(item.id, item);
  return [...values.values()].sort((a, b) => b.createdAt.localeCompare(a.createdAt) || b.id.localeCompare(a.id));
}
export function mergeEvents(previous, incoming) {
  const values = new Map(previous.map(item => [item.sequence, item]));
  for (const item of incoming) values.set(item.sequence, item);
  return [...values.values()].sort((a, b) => a.sequence - b.sequence).slice(-500);
}
const initial = () => ({ session: 'checking', connection: 'checking', busy: false, notice: '', capabilities: {}, user: null, projects: [], tasks: [], projectCursor: null, taskCursor: null, selectedId: null, events: [], eventCursor: 0, eventMore: false, lastSynced: null });

export function createController(api, uuid = () => crypto.randomUUID()) {
  let state = initial();
  let generation = 0;
  let refreshing = false;
  let selecting = 0;
  let pending = null;
  const listeners = new Set();
  const emit = patch => { state = { ...state, ...patch }; for (const listener of listeners) listener(state); };
  function lock(notice = '') {
    generation++; selecting++; pending = null; refreshing = false;
    state = initial(); emit({ session: 'locked', connection: 'unknown', notice });
  }
  function failure(error) {
    if (error.status === 401) return lock(error.message);
    emit({ notice: error.message || 'Something went wrong. Please retry.', connection: error.status === 0 ? 'offline' : 'error' });
  }
  async function action(fn) {
    if (state.busy) return false;
    const current = generation;
    emit({ busy: true, notice: '' });
    try { await fn(current); return current === generation; }
    catch (error) { if (current === generation) failure(error); return false; }
    finally { if (current === generation) emit({ busy: false }); }
  }
  async function refresh() {
    if (refreshing || state.session !== 'ready' || state.busy) return;
    refreshing = true;
    const current = generation;
    try {
      const session = await api.session();
      await api.ready();
      const [projects, tasks] = await Promise.all([api.projects(), api.tasks()]);
      if (current !== generation) return;
      const first = !state.lastSynced;
      // If new records push the first page past everything previously loaded,
      // expose that page's cursor. Preserve an older cursor after Load more.
      const cursor = (previous, incoming, next, existing) => {
        if (first || !previous.length || (incoming.length && !previous.some(item => item.id === incoming.at(-1).id))) return next;
        return existing;
      };
      emit({ projects: mergeById(state.projects, projects.projects), tasks: mergeById(state.tasks, tasks.tasks),
        projectCursor: cursor(state.projects, projects.projects, projects.nextCursor, state.projectCursor),
        taskCursor: cursor(state.tasks, tasks.tasks, tasks.nextCursor, state.taskCursor),
        capabilities: session.capabilities, user: session.user ?? null, connection: 'online', notice: '', lastSynced: Date.now() });
      if (state.selectedId) await selectTask(state.selectedId, true);
    } catch (error) { if (current === generation) failure(error); }
    finally { if (current === generation) refreshing = false; }
  }
  async function enter(current) {
    const session = await api.session();
    if (current !== generation) return;
    emit({ session: 'ready', capabilities: session.capabilities, user: session.user ?? null, connection: 'checking' });
  }
  async function selectTask(id, keep = false) {
    const current = generation;
    const selection = ++selecting;
    const after = keep && state.selectedId === id ? state.eventCursor : 0;
    if (!keep) emit({ selectedId: id, events: [], eventCursor: 0, eventMore: false, notice: '' });
    try {
      const [task, page] = await Promise.all([api.task(id), api.events(id, after)]);
      if (current !== generation || selection !== selecting) return;
      emit({ tasks: mergeById(state.tasks, [task]), events: mergeEvents(keep ? state.events : [], page.events), eventCursor: page.nextCursor, eventMore: page.hasMore });
    } catch (error) { if (current === generation && selection === selecting) failure(error); }
  }
  return {
    get state() { return state; },
    subscribe(listener) { listeners.add(listener); listener(state); return () => listeners.delete(listener); },
    async start() {
      const current = generation;
      try { await enter(current); await refresh(); }
      catch (error) { if (current === generation) { lock(); if (error.status !== 401) failure(error); } }
    },
    async login(password) {
      const ok = await action(async current => { await api.login(password); await enter(current); });
      if (ok) await refresh();
      return ok;
    },
    async logout() {
      // Keep the screen locked even when the server cannot be reached; report revocation failure.
      const result = await action(async current => {
        await api.logout(); if (current === generation) lock('Signed out.');
      });
      if (!result && state.session !== 'locked') lock('Locked on this screen. Server sign-out failed; reconnect and sign out to revoke the session.');
    },
    refresh, selectTask,
    expire() { lock('Your session has expired. Sign in again.'); },
    closeTask() { selecting++; emit({ selectedId: null, events: [], eventCursor: 0, eventMore: false }); },
    offline() { emit({ connection: 'offline', notice: 'You are offline. Updates will resume when you reconnect.' }); },
    createProject(name) {
      name = name.trim();
      if (!name || name.length > 100) { emit({ notice: 'Enter a project name between 1 and 100 characters.' }); return Promise.resolve(false); }
      return action(async current => { const project = await api.createProject(name); if (current === generation) emit({ projects: mergeById(state.projects, [project]), notice: 'Project created.' }); });
    },
    submit(projectId, prompt) {
      prompt = prompt.trim();
      if (state.session !== 'ready' || !state.capabilities.taskSubmission) { emit({ notice: 'Public task submission is disabled for the real agent.' }); return Promise.resolve(false); }
      if (!state.projects.some(p => p.id === projectId) || !prompt || prompt.length > 8000) { emit({ notice: 'Choose a project and enter a task of up to 8,000 characters.' }); return Promise.resolve(false); }
      if (!pending || pending.projectId !== projectId || pending.prompt !== prompt) pending = { projectId, prompt, key: uuid() };
      const request = pending;
      return action(async current => {
        const { task } = await api.submit(request.projectId, request.prompt, request.key);
        if (current !== generation) return;
        pending = null;
        emit({ tasks: mergeById(state.tasks, [task]), notice: 'Task submitted.' });
        await selectTask(task.id);
      });
    },
    cancel(id) {
      return action(async current => { const task = await api.cancel(id); if (current === generation) emit({ tasks: mergeById(state.tasks, [task]), notice: task.cancelRequested && isActive(task) ? 'Cancellation requested. Waiting for the worker.' : 'Task cancelled.' }); });
    },
    more(kind) {
      const cursor = kind === 'projects' ? state.projectCursor : state.taskCursor;
      if (!cursor) return Promise.resolve(false);
      return action(async current => {
        const page = await api[kind](cursor);
        if (current === generation) emit(kind === 'projects' ? { projects: mergeById(state.projects, page.projects), projectCursor: page.nextCursor } : { tasks: mergeById(state.tasks, page.tasks), taskCursor: page.nextCursor });
      });
    },
  };
}
