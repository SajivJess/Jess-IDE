import { randomUUID } from 'node:crypto';
import { spawn } from 'node:child_process';
import type { ChildProcess } from 'node:child_process';
import { once } from 'node:events';
import { createServer } from 'node:net';
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import type { FastifyInstance } from 'fastify';
import type pg from 'pg';
import { createPool } from '../src/db/pool.js';
import { migrate } from '../src/db/migrate.js';
import { Store } from '../src/db/store.js';
import type { Claim } from '../src/db/store.js';
import { buildApp } from '../src/api/app.js';
import { loadConfig } from '../src/config.js';
import { FakeAgent } from '../src/agents/fake.js';
import type { AgentAdapter, AgentInput, AgentUpdate } from '../src/agents/adapter.js';
import { LeaseLost } from '../src/domain.js';
import type { Project, Task, TaskEvent } from '../src/domain.js';
import { Worker } from '../src/worker/worker.js';

const databaseUrl = process.env.TEST_DATABASE_URL;
if (!databaseUrl && process.env.REQUIRE_DATABASE_TESTS === '1') throw new Error('TEST_DATABASE_URL required: real database tests cannot be skipped');
const schema = `jess_test_${randomUUID().replaceAll('-', '')}`;
const alice = '00000000-0000-4000-8000-000000000001';
const bob = '00000000-0000-4000-8000-000000000002';
const token = 'integration-test-token-not-a-real-secret-12345';
const auth = (user = alice) => ({ authorization: `Bearer ${token}`, 'x-dev-user-id': user });

describe.skipIf(!databaseUrl)('real PostgreSQL integration', () => {
  let admin: pg.Pool;
  let pool: pg.Pool;
  let store: Store;
  let app: FastifyInstance;

  beforeAll(async () => {
    admin = createPool(databaseUrl!);
    await admin.query(`CREATE SCHEMA "${schema}"`);
    pool = createPool(databaseUrl!, schema);
    store = new Store(pool);
    await migrate(pool);
  });
  beforeEach(async () => {
    await pool.query('TRUNCATE task_events,tasks,projects');
    app = buildApp(loadConfig({ NODE_ENV: 'test', AUTH_MODE: 'development', DEV_AUTH_TOKEN: token, DATABASE_URL: databaseUrl! }), pool, false);
    await app.ready();
  });
  afterEach(async () => { await app?.close(); });
  afterAll(async () => {
    await pool?.end();
    if (admin) { await admin.query(`DROP SCHEMA IF EXISTS "${schema}" CASCADE`); await admin.end(); }
  });

  async function createProject(): Promise<Project> {
    const response = await app.inject({ method: 'POST', url: '/projects', headers: auth(), payload: { name: 'Example project' } });
    expect(response.statusCode).toBe(201);
    return response.json<Project>();
  }
  async function submit(projectId: string, key: string = randomUUID(), prompt = 'Build a small example'): Promise<Task> {
    const response = await app.inject({ method: 'POST', url: '/tasks', headers: { ...auth(), 'idempotency-key': key }, payload: { projectId, prompt } });
    expect(response.statusCode).toBe(202);
    return response.json<{ task: Task }>().task;
  }
  async function expired(claim: Claim): Promise<void> {
    await pool.query("UPDATE tasks SET lease_expires_at=now()-interval '1 second' WHERE id=$1", [claim.task.id]);
  }

  it('applies migrations idempotently and reports database readiness', async () => {
    await migrate(pool);
    const migrations = await pool.query('SELECT * FROM schema_migrations');
    expect(migrations.rowCount).toBe(1);
    const response = await app.inject({ method: 'GET', url: '/ready', headers: auth() });
    expect(response.json()).toEqual({ status: 'ready' });
  });

  it('creates and retrieves a project and a queued task', async () => {
    const project = await createProject();
    expect((await app.inject({ method: 'GET', url: `/projects/${project.id}`, headers: auth() })).json()).toEqual(project);
    const task = await submit(project.id);
    expect(task.status).toBe('QUEUED');
    expect(task.attempt).toBe(0);
    const response = await app.inject({ method: 'GET', url: `/tasks/${task.id}`, headers: auth() });
    expect(response.json()).toEqual(task);
    expect(response.body).not.toContain('lease_token');
    expect(response.body).not.toContain('owner_id');
  });

  it('deduplicates concurrent submissions and rejects changed content for the same key', async () => {
    const project = await createProject();
    const request = { method: 'POST' as const, url: '/tasks', headers: { ...auth(), 'idempotency-key': 'same-key' }, payload: { projectId: project.id, prompt: 'First prompt' } };
    const responses = await Promise.all(Array.from({ length: 8 }, () => app.inject(request)));
    expect(responses.every(r => r.statusCode === 202)).toBe(true);
    expect(new Set(responses.map(r => r.json<{ task: Task }>().task.id)).size).toBe(1);
    expect(responses.filter(r => !r.json<{ replayed: boolean }>().replayed)).toHaveLength(1);
    expect((await pool.query('SELECT * FROM tasks')).rowCount).toBe(1);
    expect((await pool.query('SELECT * FROM task_events')).rowCount).toBe(1);
    const conflict = await app.inject({ ...request, payload: { ...request.payload, prompt: 'Different prompt' } });
    expect(conflict.statusCode).toBe(409);
    expect(conflict.json()).toEqual({ error: 'IDEMPOTENCY_CONFLICT' });
  });

  it('keeps idempotency keys scoped to the project', async () => {
    const a = await createProject();
    const b = await createProject();
    expect((await submit(a.id, 'same')).id).not.toBe((await submit(b.id, 'same')).id);
  });

  it('enforces ownership for projects, submissions, tasks, cancellation and both event endpoints', async () => {
    const project = await createProject();
    const task = await submit(project.id);
    for (const [method, url] of [
      ['GET', `/projects/${project.id}`], ['GET', `/tasks/${task.id}`],
      ['POST', `/tasks/${task.id}/cancel`], ['GET', `/tasks/${task.id}/events`], ['GET', `/tasks/${task.id}/events/stream`],
    ] as const) {
      const response = await app.inject({ method, url, headers: auth(bob) });
      expect(response.statusCode).toBe(404);
      expect(response.json()).toEqual({ error: 'NOT_FOUND' });
    }
    const denied = await app.inject({ method: 'POST', url: '/tasks', headers: { ...auth(bob), 'idempotency-key': 'secret' }, payload: { projectId: project.id, prompt: 'Unauthorized' } });
    expect(denied.statusCode).toBe(404);
  });

  it('validates input, rejects command-shaped extra fields and bounds request sizes', async () => {
    const project = await createProject();
    for (const payload of [
      { projectId: project.id, prompt: ' ' },
      { projectId: 'invalid', prompt: 'Hello' },
      { projectId: project.id, prompt: 'Hello', command: 'arbitrary-command' },
    ]) {
      expect((await app.inject({ method: 'POST', url: '/tasks', headers: { ...auth(), 'idempotency-key': 'valid' }, payload })).statusCode).toBe(400);
    }
    expect((await app.inject({ method: 'POST', url: '/tasks', headers: auth(), payload: { projectId: project.id, prompt: 'Hello' } })).statusCode).toBe(400);
    expect((await app.inject({ method: 'POST', url: '/projects', headers: auth(), payload: { name: ' ' } })).statusCode).toBe(400);
    expect((await app.inject({ method: 'POST', url: '/projects', headers: auth(), payload: { name: 'a'.repeat(20000) } })).statusCode).toBe(413);
    expect((await app.inject({ method: 'GET', url: `/tasks/${randomUUID()}`, headers: auth() })).statusCode).toBe(404);
  });

  it('runs the deterministic fake lifecycle and orders durable events', async () => {
    const task = await submit((await createProject()).id);
    expect(await new Worker(store, new FakeAgent(0)).runOnce()).toBe(true);
    expect(await new Worker(store, new FakeAgent(0)).runOnce()).toBe(false);
    const completed = await store.getTask(alice, task.id);
    expect(completed.status).toBe('COMPLETED');
    expect(completed.result?.simulated).toBe(true);
    expect(completed.result?.checks[0]?.status).toBe('simulated');
    const page = await store.events(alice, task.id, 0, 100);
    expect(page.events.map(e => e.type)).toEqual(['TASK_QUEUED', 'TASK_STARTED', 'AGENT_PROGRESS', 'AGENT_PROGRESS', 'AGENT_PROGRESS', 'TASK_COMPLETED']);
    expect(page.events.map(e => e.sequence)).toEqual([1, 2, 3, 4, 5, 6]);
    expect(page.hasMore).toBe(false);
  });

  it('replays paginated events without gaps after reconnection and rejects bad cursors', async () => {
    const task = await submit((await createProject()).id);
    await new Worker(store, new FakeAgent(0)).runOnce();
    const first = (await app.inject({ method: 'GET', url: `/tasks/${task.id}/events?after=0&limit=2`, headers: auth() })).json<{ events: TaskEvent[]; nextCursor: number; hasMore: boolean }>();
    expect(first.nextCursor).toBe(2);
    expect(first.hasMore).toBe(true);
    const second = (await app.inject({ method: 'GET', url: `/tasks/${task.id}/events?after=${first.nextCursor}`, headers: auth() })).json<{ events: TaskEvent[] }>();
    expect([...first.events, ...second.events].map(e => e.sequence)).toEqual([1, 2, 3, 4, 5, 6]);
    for (const query of ['after=-1', 'after=900', 'limit=101', 'after=word']) {
      expect((await app.inject({ method: 'GET', url: `/tasks/${task.id}/events?${query}`, headers: auth() })).statusCode).toBe(400);
    }
  });

  it('streams actual HTTP SSE and resumes with Last-Event-ID after disconnect', async () => {
    const task = await submit((await createProject()).id);
    const address = await app.listen({ host: '127.0.0.1', port: 0 });
    const controller = new AbortController();
    const response = await fetch(`${address}/tasks/${task.id}/events/stream`, { headers: auth(), signal: controller.signal });
    expect(response.headers.get('content-type')).toBe('text/event-stream');
    const reader = response.body!.getReader();
    let received = '';
    while (!received.includes('id: 1\n')) {
      const value = await reader.read();
      received += new TextDecoder().decode(value.value);
    }
    controller.abort();
    await reader.cancel().catch(() => undefined);
    await new Worker(store, new FakeAgent(0)).runOnce();
    const reconnected = await fetch(`${address}/tasks/${task.id}/events/stream`, { headers: { ...auth(), 'last-event-id': '1' } });
    const text = await reconnected.text();
    expect(text).not.toMatch(/^id: 1$/m);
    expect([...text.matchAll(/^id: (\d+)$/gm)].map(m => Number(m[1]))).toEqual([2, 3, 4, 5, 6]);
    expect(text).toContain('TASK_COMPLETED');
  });

  it('cancels queued tasks immediately and repeated cancellation is idempotent', async () => {
    const task = await submit((await createProject()).id);
    for (let i = 0; i < 2; i++) {
      const response = await app.inject({ method: 'POST', url: `/tasks/${task.id}/cancel`, headers: auth() });
      expect(response.json<Task>().status).toBe('CANCELLED');
    }
    expect(await new Worker(store, new FakeAgent(0)).runOnce()).toBe(false);
    expect((await store.events(alice, task.id, 0, 100)).events.map(e => e.type)).toEqual(['TASK_QUEUED', 'TASK_CANCELLED']);
  });

  it('cooperatively cancels a running task at a safe boundary', async () => {
    const task = await submit((await createProject()).id);
    const running = new Worker(store, new FakeAgent(80), 300).runOnce();
    await expect.poll(async () => (await store.getTask(alice, task.id)).status).toBe('RUNNING');
    await store.cancel(alice, task.id);
    await running;
    const final = await store.getTask(alice, task.id);
    expect(final.status).toBe('CANCELLED');
    expect(final.result).toBeNull();
    expect((await store.events(alice, task.id, 0, 100)).events.at(-1)?.type).toBe('TASK_CANCELLED');
  });

  it('does not mutate completed tasks on late cancellation', async () => {
    const task = await submit((await createProject()).id);
    await new Worker(store, new FakeAgent(0)).runOnce();
    expect((await store.cancel(alice, task.id)).status).toBe('COMPLETED');
    expect((await store.events(alice, task.id, 0, 100)).events).toHaveLength(6);
  });

  it('claims a job only once under competing workers', async () => {
    await submit((await createProject()).id);
    const claims = await Promise.all([store.claim(15000), store.claim(15000)]);
    expect(claims.filter(c => c !== null)).toHaveLength(1);
  });

  it('reclaims an expired lease and fences out writes from the old worker', async () => {
    const task = await submit((await createProject()).id);
    const old = await store.claim(15000) as Claim;
    await expired(old);
    await new Worker(store, new FakeAgent(0)).runOnce();
    expect((await store.getTask(alice, task.id)).attempt).toBe(2);
    expect((await store.getTask(alice, task.id)).status).toBe('COMPLETED');
    await expect(store.progress(old, { message: 'stale' })).rejects.toBeInstanceOf(LeaseLost);
    await expect(store.finish(old, null, true)).rejects.toBeInstanceOf(LeaseLost);
    expect((await store.events(alice, task.id, 0, 100)).events.map(e => e.type)).toContain('TASK_RETRYING');
  });

  it('bounds crash retries and records a terminal failure', async () => {
    const task = await submit((await createProject()).id);
    for (let i = 0; i < 3; i++) { const claim = await store.claim(15000) as Claim; await expired(claim); }
    expect(await store.claim(15000)).toBe('reconciled');
    const final = await store.getTask(alice, task.id);
    expect(final.status).toBe('FAILED');
    expect(final.error).toBe('RETRY_LIMIT_EXCEEDED');
    expect(await store.claim(15000)).toBeNull();
  });

  it('reconciles cancellation after the running worker crashes', async () => {
    const task = await submit((await createProject()).id);
    const claim = await store.claim(15000) as Claim;
    await store.cancel(alice, task.id);
    await expired(claim);
    expect(await store.claim(15000)).toBe('reconciled');
    expect((await store.getTask(alice, task.id)).status).toBe('CANCELLED');
  });

  it('renews leases while the agent is working', async () => {
    const task = await submit((await createProject()).id);
    const worker = new Worker(store, new FakeAgent(100), 150);
    await worker.runOnce();
    expect((await store.getTask(alice, task.id)).status).toBe('COMPLETED');
    expect((await store.getTask(alice, task.id)).attempt).toBe(1);
  });

  it('leaves an interrupted task recoverable on worker shutdown', async () => {
    const task = await submit((await createProject()).id);
    const shutdown = new AbortController();
    const running = new Worker(store, new FakeAgent(1000)).runOnce(shutdown.signal);
    await expect.poll(async () => (await store.getTask(alice, task.id)).status).toBe('RUNNING');
    shutdown.abort();
    await running;
    await new Worker(store, new FakeAgent(0)).runOnce();
    expect((await store.getTask(alice, task.id)).status).toBe('COMPLETED');
    expect((await store.getTask(alice, task.id)).attempt).toBe(2);
  });

  it('records sanitized agent failures without leaking exception details', async () => {
    const task = await submit((await createProject()).id);
    const broken: AgentAdapter = {
      id: 'test-failure', capabilities: { cancellation: true, approvals: false, workspaceExecution: false },
      // Test-only adapter: the failure is inside the provider boundary, not a mock database.
      async *run(input: AgentInput): AsyncGenerator<AgentUpdate, void, void> {
        yield { type: 'progress', percent: 1, message: 'Starting' };
        input.signal.throwIfAborted();
        throw new Error('sensitive provider diagnostic');
      },
    };
    await new Worker(store, broken).runOnce();
    const final = await store.getTask(alice, task.id);
    expect(final.status).toBe('FAILED');
    expect(final.error).toBe('AGENT_EXECUTION_FAILED');
    expect(JSON.stringify(await store.events(alice, task.id, 0, 100))).not.toContain('sensitive provider');
  });

  it('survives a real lost database connection and reclaims the persisted job', async () => {
    const task = await submit((await createProject()).id);
    const claim = await store.claim(15000) as Claim;
    const isolated = createPool(databaseUrl!, schema);
    const client = await isolated.connect();
    try {
      const pid = await client.query<{ pid: number }>('SELECT pg_backend_pid() AS pid');
      // This connection belongs solely to this test, and the durable job lives elsewhere.
      client.on('error', () => undefined);
      await admin.query('SELECT pg_terminate_backend($1)', [pid.rows[0]!.pid]);
      await expect(client.query('SELECT 1')).rejects.toThrow();
    } finally { client.release(true); await isolated.end(); }
    await expired(claim);
    await new Worker(store, new FakeAgent(0)).runOnce();
    expect((await store.getTask(alice, task.id)).status).toBe('COMPLETED');
  });

  it('recovers a worker after a real PostgreSQL lock timeout without committing partial progress', async () => {
    const task = await submit((await createProject()).id);
    const blocker = await pool.connect();
    const blocked: AgentAdapter = {
      id: 'test-lock-timeout', capabilities: { cancellation: true, approvals: false, workspaceExecution: false },
      async *run(): AsyncGenerator<AgentUpdate, void, void> {
        await blocker.query('BEGIN');
        await blocker.query('SELECT id FROM tasks WHERE id=$1 FOR UPDATE', [task.id]);
        yield { type: 'progress', message: 'Blocked progress', percent: 10 };
      },
    };
    try {
      await expect(new Worker(store, blocked, 15000).runOnce()).rejects.toMatchObject({ code: '55P03' });
    } finally { await blocker.query('ROLLBACK'); blocker.release(); }
    const interrupted = await store.getTask(alice, task.id);
    expect(interrupted.status).toBe('RUNNING');
    expect((await store.events(alice, task.id, 0, 100)).events.map(e => e.type)).toEqual(['TASK_QUEUED', 'TASK_STARTED']);
    await pool.query("UPDATE tasks SET lease_expires_at=now()-interval '1 second' WHERE id=$1", [task.id]);
    await new Worker(store, new FakeAgent(0)).runOnce();
    expect((await store.getTask(alice, task.id)).status).toBe('COMPLETED');
    expect((await store.getTask(alice, task.id)).attempt).toBe(2);
  });

  it('runs the real API and worker entry points as separate Node processes', async () => {
    const reservation = createServer();
    reservation.listen(0, '127.0.0.1');
    await once(reservation, 'listening');
    const address = reservation.address();
    if (!address || typeof address === 'string') throw new Error('Cannot reserve test port');
    const port = address.port;
    await new Promise<void>((resolve, reject) => reservation.close(error => error ? reject(error) : resolve()));
    const connection = new URL(databaseUrl!);
    connection.searchParams.set('options', `-c search_path=${schema}`);
    const env = { ...process.env, NODE_ENV: 'test', AUTH_MODE: 'development',
      DEV_AUTH_TOKEN: token, DATABASE_URL: connection.href, PORT: String(port),
      FAKE_AGENT_STEP_MS: '10', WORKER_POLL_MS: '50' };
    const children: ChildProcess[] = [];
    const exits: Promise<unknown>[] = [];
    const launch = (entry: string): void => {
      const child = spawn(process.execPath, ['--import', 'tsx', entry], { env, stdio: 'ignore' });
      children.push(child);
      exits.push(once(child, 'exit'));
    };
    try {
      launch('src/api/main.ts');
      const base = `http://127.0.0.1:${port}`;
      await expect.poll(async () => {
        try { return (await fetch(`${base}/health`)).status; } catch { return 0; }
      }, { timeout: 8000 }).toBe(200);
      const response = await fetch(`${base}/projects`, { method: 'POST', headers: { ...auth(), 'content-type': 'application/json' }, body: JSON.stringify({ name: 'Separate processes' }) });
      expect(response.status).toBe(201);
      const project = await response.json() as Project;
      const submission = await fetch(`${base}/tasks`, { method: 'POST', headers: { ...auth(), 'content-type': 'application/json', 'idempotency-key': 'separate-processes' }, body: JSON.stringify({ projectId: project.id, prompt: 'Run a simulated task' }) });
      expect(submission.status).toBe(202);
      const { task } = await submission.json() as { task: Task };
      launch('src/worker/main.ts');
      await expect.poll(async () => {
        const status = await fetch(`${base}/tasks/${task.id}`, { headers: auth() });
        return (await status.json() as Task).status;
      }, { timeout: 8000 }).toBe('COMPLETED');
      expect((await store.getTask(alice, task.id)).result?.simulated).toBe(true);
    } finally {
      for (const child of children) child.kill('SIGTERM');
      await Promise.all(exits);
    }
  });
});
