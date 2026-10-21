import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createController, mergeEvents } from './state.js';
import { createApi, ApiError } from './api.js';

const id = '00000000-0000-4000-8000-000000000001';
const project = { id, name: 'Real project', createdAt: '2026-10-17T12:00:00Z' };
const task = { id, projectId: id, prompt: 'A task', status: 'QUEUED', createdAt: project.createdAt };
function fixture(overrides = {}) {
  return { session: async () => ({ capabilities: { taskSubmission: true } }), ready: async () => ({}),
    projects: async () => ({ projects: [project], nextCursor: null }), tasks: async () => ({ tasks: [task], nextCursor: null }),
    task: async () => task, events: async () => ({ events: [], nextCursor: 0, hasMore: false }),
    login: async () => ({}), logout: async () => ({}), ...overrides };
}

test('restores projects and task history from the server on a fresh client', async () => {
  const c = createController(fixture()); await c.start();
  assert.equal(c.state.session, 'ready'); assert.equal(c.state.connection, 'online');
  assert.deepEqual(c.state.projects, [project]); assert.deepEqual(c.state.tasks, [task]);
});

test('uses the authenticated profile name and clears it when the session expires', async () => {
  const api = fixture({ session: async () => ({ user: { displayName: 'Avery' }, capabilities: { taskSubmission: false } }) });
  const controller = createController(api); await controller.start(); assert.equal(controller.state.user.displayName, 'Avery');
  controller.expire(); assert.equal(controller.state.user, null);
});
test('keeps a task idempotency key on ambiguous network failure and reuses it on explicit retry', async () => {
  const keys = []; let tries = 0;
  const c = createController(fixture({ submit: async (_project, _prompt, key) => { keys.push(key); if (++tries === 1) throw new ApiError(0, 'Offline'); return { task }; } }), () => 'stable-key');
  await c.start(); assert.equal(await c.submit(id, 'A task'), false);
  await c.refresh(); assert.equal(await c.submit(id, 'A task'), true);
  assert.deepEqual(keys, ['stable-key', 'stable-key']); assert.equal(c.state.tasks.length, 1);
});
test('never submits a public task when the capability is disabled', async () => {
  let called = false;
  const c = createController(fixture({ session: async () => ({ capabilities: { taskSubmission: false } }), submit: async () => { called = true; } }));
  await c.start(); assert.equal(await c.submit(id, 'A task'), false); assert.equal(called, false);
});
test('session expiry clears all project/task data and selection', async () => {
  const api = fixture(); const c = createController(api); await c.start(); await c.selectTask(id);
  api.session = async () => { throw new ApiError(401, 'Sign in again'); }; await c.refresh();
  assert.equal(c.state.session, 'locked'); assert.deepEqual(c.state.tasks, []); assert.deepEqual(c.state.projects, []); assert.equal(c.state.selectedId, null);
});
test('an in-flight detail response cannot repopulate state after logout', async () => {
  let resolve; const api = fixture({ task: () => new Promise(r => { resolve = r; }) });
  const c = createController(api); await c.start(); const selecting = c.selectTask(id);
  await c.logout(); resolve(task); await selecting;
  assert.equal(c.state.session, 'locked'); assert.deepEqual(c.state.tasks, []); assert.deepEqual(c.state.events, []);
});
test('out-of-order task selections cannot overwrite the latest selected task', async () => {
  let resolve; const second = { ...task, id: '00000000-0000-4000-8000-000000000002' };
  const c = createController(fixture({ task: key => key === id ? new Promise(r => { resolve = r; }) : Promise.resolve(second) }));
  await c.start(); const first = c.selectTask(id); await c.selectTask(second.id); resolve(task); await first;
  assert.equal(c.state.selectedId, second.id);
});
test('resumes event replay from the last cursor and deduplicates events', async () => {
  const cursors = [];
  const c = createController(fixture({ events: async (_id, after) => { cursors.push(after); return { events: [{ sequence: 1 }, { sequence: 2 }], nextCursor: 2, hasMore: false }; } }));
  await c.start(); await c.selectTask(id); await c.refresh();
  assert.deepEqual(cursors, [0, 2]); assert.equal(c.state.events.length, 2);
  assert.equal(mergeEvents([], Array.from({ length: 700 }, (_, sequence) => ({ sequence }))).length, 500);
});
test('retains current history while offline and recovers on refresh', async () => {
  const api = fixture(); const c = createController(api); await c.start();
  api.ready = async () => { throw new ApiError(0, 'Offline'); }; await c.refresh();
  assert.equal(c.state.connection, 'offline'); assert.equal(c.state.tasks.length, 1);
  api.ready = async () => ({}); await c.refresh(); assert.equal(c.state.connection, 'online'); assert.equal(c.state.notice, '');
});
test('cancellation displays the server state and pagination merges without duplicate rows', async () => {
  const api = fixture({ cancel: async () => ({ ...task, status: 'RUNNING', cancelRequested: true }), tasks: async before => ({ tasks: [task], nextCursor: before ? null : id }) });
  const c = createController(api); await c.start(); await c.cancel(id);
  assert.equal(c.state.tasks[0].cancelRequested, true); assert.match(c.state.notice, /Waiting for the worker/);
  await c.more('tasks'); assert.equal(c.state.tasks.length, 1); assert.equal(c.state.taskCursor, null);
});
test('refresh exposes pagination when new server history extends beyond the loaded page', async () => {
  let page = { tasks: [], nextCursor: null };
  const c = createController(fixture({ tasks: async () => page })); await c.start();
  page = { tasks: [task], nextCursor: id }; await c.refresh();
  assert.equal(c.state.taskCursor, id);
});
test('transport uses same-origin cookie auth and never attaches backend credentials', async () => {
  const calls = []; const api = createApi(async (path, init) => { calls.push({ path, init }); return { ok: true, json: async () => ({}) }; });
  await api.submit(id, '<script>unsafe</script>', 'request-key'); await api.events(id, 42);
  assert.equal(calls[0].init.credentials, 'same-origin'); assert.equal(calls[0].init.redirect, 'error');
  assert.equal(calls[0].init.headers['idempotency-key'], 'request-key');
  assert.equal(calls[0].init.headers.authorization, undefined); assert.equal(calls[0].init.headers['x-dev-user-id'], undefined);
  assert.equal(calls[1].path, `/api/tasks/${id}/events?after=42&limit=100`);
  assert.throws(() => api.task('../secret'), /Invalid task ID/);
});
test('transport converts malformed responses and failures to safe user-facing errors', async () => {
  await assert.rejects(createApi(async () => { throw new Error('secret internal detail'); }).ready(), error => error.status === 0 && !error.message.includes('secret'));
  await assert.rejects(createApi(async () => ({ ok: false, status: 401 })).ready(), error => error.status === 401);
  await assert.rejects(createApi(async () => ({ ok: true, json: async () => { throw new Error('bad JSON'); } })).ready(), error => error.status === 502);
});
