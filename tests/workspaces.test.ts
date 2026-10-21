import { randomUUID } from 'node:crypto';
import { beforeAll, beforeEach, afterAll, describe, expect, it } from 'vitest';
import type pg from 'pg';
import type { FastifyInstance } from 'fastify';
import { createPool } from '../src/db/pool.js';
import { migrate } from '../src/db/migrate.js';
import { Store } from '../src/db/store.js';
import { WorkspaceStore } from '../src/workspaces/store.js';
import { workspacePath, textContent } from '../src/workspaces/policy.js';
import { buildApp } from '../src/api/app.js';
import { loadConfig } from '../src/config.js';

const owner = randomUUID(), stranger = randomUUID();
const token = 'workspace-test-token-not-real-secret-123456';
const auth = (id = owner) => ({ authorization: `Bearer ${token}`, 'x-dev-user-id': id });
const databaseUrl = process.env.TEST_DATABASE_URL;
if (!databaseUrl && process.env.REQUIRE_DATABASE_TESTS === '1') throw new Error('Workspace database tests required');

describe('portable snapshot paths', () => {
  it('rejects traversal, encodings, Windows device paths, credential files and aliases', () => {
    for (const value of ['../x', 'a/../b', '/etc/passwd', 'E:/secret', '\\\\host\\share', 'a\\b', 'a%2fb', '%252e%252e/x', 'x:stream', 'NUL.txt', 'com1', 'src/x.', 'src/x ', './x', 'a//b', '.git/config', '.env', '.env.local', '.ssh/id_rsa', 'secret.key', 'a\0b']) expect(() => workspacePath(value)).toThrow();
    expect(workspacePath('src/main.ts')).toBe('src/main.ts'); expect(workspacePath('', true)).toBe('');
  });
  it('bounds UTF-8 bytes and rejects binary/unpaired-surrogate data', () => {
    expect(() => textContent('é'.repeat(32769))).toThrow();
    expect(() => textContent('\0binary')).toThrow(); expect(() => textContent('\ud800')).toThrow();
    expect(textContent('hello\n')).toBe('hello\n');
  });
});

describe.skipIf(!databaseUrl)('review workspace ownership and atomic storage', () => {
  const schema = `jess_workspace_${randomUUID().replaceAll('-', '')}`;
  let admin: pg.Pool, pool: pg.Pool, app: FastifyInstance, store: WorkspaceStore, taskId: string, repositoryId: string, workspaceId: string;
  beforeAll(async () => {
    admin = createPool(databaseUrl!); await admin.query(`CREATE SCHEMA "${schema}"`); pool = createPool(databaseUrl!, schema); await migrate(pool);
    app = buildApp(loadConfig({ NODE_ENV: 'test', AUTH_MODE: 'development', DEV_AUTH_TOKEN: token, DATABASE_URL: databaseUrl! }), pool, false); await app.ready(); store = new WorkspaceStore(pool);
  });
  beforeEach(async () => {
    await pool.query('TRUNCATE conversation_events,conversation_turns,conversations,project_contexts,workspace_edits,workspace_files,review_workspaces,repository_files,registered_repositories,task_events,tasks,projects');
    const tasks = new Store(pool); const project = await tasks.createProject(owner, 'Example'); taskId = (await tasks.submit(owner, project.id, 'Review', randomUUID())).task.id; await tasks.cancel(owner, taskId);
    repositoryId = await store.register(owner, { name: 'Example', githubUrl: 'https://github.com/example/example', branch: 'main', sourceDirectory: 'E:\\permitted', baseCommit: 'a'.repeat(40), files: [
      { path: 'src/main.ts', content: 'const value = 1;\n', size: 17, reason: null },
      { path: 'image.png', content: null, size: 123, reason: 'binary' },
      { path: 'link.txt', content: null, size: 20, reason: 'link-or-submodule' },
    ] });
    workspaceId = (await store.create(owner, taskId, repositoryId)).id;
  });
  afterAll(async () => { await app?.close(); await pool?.end(); if (admin) { await admin.query(`DROP SCHEMA IF EXISTS "${schema}" CASCADE`); await admin.end(); } });
  it('keeps every endpoint owner scoped and excludes host paths', async () => {
    for (const suffix of ['', '/files?path=src', '/file?path=src/main.ts', '/diff?path=src/main.ts']) expect((await app.inject({ url: `/workspaces/${workspaceId}${suffix}`, headers: auth(stranger) })).statusCode).toBe(404);
    expect((await app.inject({ method: 'PUT', url: `/workspaces/${workspaceId}/file`, headers: auth(stranger), payload: { path: 'src/main.ts', content: 'hack' } })).statusCode).toBe(404);
    expect((await app.inject({ method: 'POST', url: `/tasks/${taskId}/workspace`, headers: auth(stranger), payload: { repositoryId } })).statusCode).toBe(404);
    for (const url of ['/repositories', '/workspaces']) {
      const result = await app.inject({ url, headers: auth() }); expect(result.body).not.toContain('permitted'); expect(result.body).not.toContain('owner_id');
      expect((await app.inject({ url, headers: auth(stranger) })).body).not.toContain(repositoryId);
      expect((await app.inject({ url })).statusCode).toBe(401);
    }
  });
  it('lists directories and reads actual snapshot contents but refuses binary and link payloads', async () => {
    expect((await store.files(owner, workspaceId, '', 0)).entries.map(x => x.name)).toEqual(['image.png', 'link.txt', 'src']);
    expect((await store.read(owner, workspaceId, 'src/main.ts')).content).toBe('const value = 1;\n');
    for (const path of ['image.png', 'link.txt']) expect((await app.inject({ url: `/workspaces/${workspaceId}/file?path=${path}`, headers: auth() })).statusCode).toBe(415);
  });
  it('rejects malicious HTTP paths, extra command fields and oversize writes', async () => {
    for (const path of ['../.env', 'C:/Windows/win.ini', 'src\\main.ts', '.git/config', '%2e%2e/secret', 'a:stream', 'NUL']) {
      const response = await app.inject({ url: `/workspaces/${workspaceId}/file?path=${encodeURIComponent(path)}`, headers: auth() }); expect([400, 403]).toContain(response.statusCode);
    }
    const url = `/workspaces/${workspaceId}/file`;
    expect((await app.inject({ method: 'PUT', url, headers: auth(), payload: { path: 'src/main.ts', content: 'text', command: 'arbitrary' } })).statusCode).toBe(400);
    expect((await app.inject({ method: 'PUT', url, headers: auth(), payload: { path: 'src/main.ts', content: 'é'.repeat(40000) } })).statusCode).toBe(413);
    expect((await app.inject({ method: 'PUT', url, headers: auth(), payload: { path: 'src/main.ts', content: 'x'.repeat(410000) } })).statusCode).toBe(413);
  });
  it('requires revision matching, preserves conflicts and audits only successful atomic edits', async () => {
    const file = await store.read(owner, workspaceId, 'src/main.ts');
    const request = { method: 'PUT' as const, url: `/workspaces/${workspaceId}/file`, headers: { ...auth(), 'if-match': file.etag }, payload: { path: file.path, content: 'const value = 2;\n' } };
    expect((await app.inject({ ...request, headers: auth() })).statusCode).toBe(428);
    const results = await Promise.all([app.inject(request), app.inject({ ...request, payload: { ...request.payload, content: 'const value = 3;\n' } })]);
    expect(results.map(x => x.statusCode).sort()).toEqual([200, 409]);
    expect((await pool.query('SELECT * FROM workspace_edits')).rowCount).toBe(1);
    expect((await store.read(owner, workspaceId, file.path)).version).toBe(1);
    const diff = await store.diff(owner, workspaceId, file.path); expect(diff.diff).toContain('-const value = 1;'); expect(diff.changed).toBe(true); expect(diff.approvalAvailable).toBe(false);
    expect((await pool.query('SELECT content FROM repository_files WHERE path=$1', [file.path])).rows[0].content).toBe(file.content);
  });
  it('makes workspace creation idempotent and rejects active tasks and arbitrary registry arguments', async () => {
    expect((await store.create(owner, taskId, repositoryId)).id).toBe(workspaceId);
    await pool.query("UPDATE tasks SET status='QUEUED' WHERE id=$1", [taskId]);
    expect((await app.inject({ method: 'POST', url: `/tasks/${taskId}/workspace`, headers: auth(), payload: { repositoryId } })).statusCode).toBe(409);
    expect((await app.inject({ method: 'POST', url: '/repositories', headers: auth(), payload: { path: 'C:\\' } })).statusCode).toBe(404);
    expect((await app.inject({ method: 'POST', url: `/tasks/${taskId}/workspace`, headers: auth(), payload: { repositoryId, sourceDirectory: 'E:\\' } })).statusCode).toBe(400);
    expect((await app.inject({ method: 'POST', url: `/workspaces/${workspaceId}/approve`, headers: auth() })).statusCode).toBe(404);
  });
  it('rejects case aliases, file-directory collisions and inconsistent size metadata', async () => {
    const snapshot = { name: 'Test', githubUrl: 'https://github.com/example/test', branch: 'main', sourceDirectory: 'E:\\permitted', baseCommit: 'a'.repeat(40) };
    const file = (path: string) => ({ path, content: 'x', size: 1, reason: null });
    for (const files of [[file('Src/a.ts'), file('src/b.ts')], [file('src'), file('src/a.ts')], [{ ...file('main.ts'), size: 20 }]]) await expect(store.register(owner, { ...snapshot, files })).rejects.toThrow();
  });
});
