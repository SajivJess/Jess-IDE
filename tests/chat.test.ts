import { randomUUID } from 'node:crypto';
import { mkdtemp, mkdir, readFile, writeFile, symlink } from 'node:fs/promises';
import path from 'node:path';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import type pg from 'pg';
import type { FastifyInstance } from 'fastify';
import { createPool } from '../src/db/pool.js';
import { migrate } from '../src/db/migrate.js';
import { Store } from '../src/db/store.js';
import { WorkspaceStore } from '../src/workspaces/store.js';
import { ChatStore } from '../src/chat/store.js';
import { CliSession } from '../src/chat/cli-session.js';
import { redactor } from '../src/chat/privacy.js';
import { transcript, exportProject } from '../src/chat/markdown.js';
import { relayLocal } from '../src/chat/local-relay.js';
import type { SessionFactory } from '../src/chat/local-relay.js';
import { buildApp } from '../src/api/app.js';
import { loadConfig } from '../src/config.js';
const root = 'E:\\local-data\\tmp';
const owner = randomUUID(), other = randomUUID(), native = randomUUID();
const token = 'chat-test-token-not-a-real-secret-123456789';
const auth = (id = owner) => ({ authorization: `Bearer ${token}`, 'x-dev-user-id': id });
const databaseUrl = process.env.TEST_DATABASE_URL;
if (!databaseUrl && process.env.REQUIRE_DATABASE_TESTS === '1') throw new Error('Chat database tests required');

describe('structured CLI session transport', () => {
  async function transport() {
    const folder = await mkdtemp(path.join(root, 'jess-chat-protocol-')); const script = path.join(folder, 'cli.mjs');
    await writeFile(script, `import readline from 'node:readline';
const id='${native}'; const send=value=>process.stdout.write(JSON.stringify(value)+'\\n');
send({event:'init',conversation_id:id});let turns=0;
readline.createInterface({input:process.stdin}).on('line',line=>{const prompt=JSON.parse(line).message.content;turns++;
if(prompt==='hang')return;if(prompt==='bad-json'){process.stdout.write('bad\\n');return;}
if(prompt==='exit'){process.exit(1);return;}
send({event:'step_update',step_update:{conversation_id:id,step_type:'agent_response',state:'ACTIVE',step_index:turns,text_delta:'private internal fragment'}});
const result=Buffer.from(JSON.stringify({event:'result',result:{conversation_id:prompt==='mismatch'?'${randomUUID()}':id,status:'SUCCESS',response:'actual fixture '+turns+' café 🌿'}})+'\\n');
const index=result.indexOf(Buffer.from('é'))+1;process.stdout.write(result.subarray(0,index));setTimeout(()=>process.stdout.write(result.subarray(index)),5);
});`);
    const bound: string[] = [], steps: unknown[] = [];
    const session = new CliSession({ executable: process.execPath, cwd: folder, env: { ...process.env, TEMP: root, TMP: root }, argsPrefix: [script], timeoutMs: 1000 }, async id => { bound.push(id); }, async step => { steps.push(step); });
    return { session, bound, steps };
  }
  it('keeps one process across turns, decodes split UTF-8 and forwards status metadata only', async () => {
    const { session, bound, steps } = await transport();
    try {
      expect((await session.turn('first')).response).toBe('actual fixture 1 café 🌿');
      expect((await session.turn('second')).response).toBe('actual fixture 2 café 🌿');
      expect(bound).toEqual([native]); expect(JSON.stringify(steps)).not.toContain('private');
    } finally { await session.close(); }
  });
  it('refuses concurrent turns and rejects malformed/session-mismatched output and uncertain exits', async () => {
    for (const prompt of ['bad-json', 'mismatch', 'exit']) {
      const { session } = await transport(); try { await expect(session.turn(prompt)).rejects.toThrow(); } finally { await session.close(); }
    }
    const { session } = await transport(); const pending = session.turn('hang');
    await expect(session.turn('duplicate')).rejects.toThrow(); await expect(pending).rejects.toThrow('CLI_TIMEOUT'); await session.close();
  }, 10000);
  it('filters known credentials, common token formats and private key material', () => {
    const clean = redactor([token]);
    const result = clean(`${token}\nAuthorization: Bearer abcdef123456\npassword=hello123\nhttps://name:secret@host/path\n-----BEGIN PRIVATE KEY-----\nsecret\n-----END PRIVATE KEY-----`);
    expect(result).not.toContain(token); expect(result).not.toContain('hello123'); expect(result).not.toContain('name:secret'); expect(result).not.toContain('\nsecret\n');
  });
});

describe.skipIf(!databaseUrl)('owned durable chat and portable context', () => {
  const schema = `jess_chat_${randomUUID().replaceAll('-', '')}`;
  let admin: pg.Pool, pool: pg.Pool, app: FastifyInstance, store: ChatStore, project: string, repository: string, id: string, folder: string;
  beforeAll(async () => {
    admin = createPool(databaseUrl!); await admin.query(`CREATE SCHEMA "${schema}"`); pool = createPool(databaseUrl!, schema); await migrate(pool);
    app = buildApp(loadConfig({ NODE_ENV: 'test', AUTH_MODE: 'development', DEV_AUTH_TOKEN: token, DATABASE_URL: databaseUrl! }), pool, false); await app.ready(); store = new ChatStore(pool, [token]);
  });
  beforeEach(async () => {
    await pool.query('TRUNCATE conversation_events,conversation_turns,conversations,project_contexts,workspace_edits,workspace_files,review_workspaces,repository_files,registered_repositories,task_events,tasks,projects');
    folder = await mkdtemp(path.join(root, 'jess-chat-')); project = (await new Store(pool).createProject(owner, 'Chat project')).id;
    repository = await new WorkspaceStore(pool).register(owner, { name: 'Example', githubUrl: 'https://github.com/example/example', branch: 'main', sourceDirectory: folder, baseCommit: 'a'.repeat(40), files: [{ path: 'main.ts', content: 'text', size: 4, reason: null }] });
    id = (await store.create(owner, project, repository, 'Actual CLI conversation')).id;
  });
  afterAll(async () => { await app?.close(); await pool?.end(); if (admin) { await admin.query(`DROP SCHEMA IF EXISTS "${schema}" CASCADE`); await admin.end(); } });
  it('lists owned project metadata and resumes the explicitly visited conversation', async () => {
    const hidden = await new Store(pool).createProject(other, 'Hidden project');
    const second = await new Store(pool).createProject(owner, 'Second project');
    const secondChat = await store.create(owner, second.id, repository, 'Second conversation');
    await store.create(owner, project, repository, 'Newer conversation');
    const overview = () => app.inject({ url: '/workspace/home', headers: auth() });
    expect((await app.inject({ url: '/workspace/home' })).statusCode).toBe(401);
    expect((await overview()).json().projects.map((p: { id: string }) => p.id).sort()).toEqual([project, second.id].sort());
    expect((await app.inject({ method: 'POST', url: `/projects/${hidden.id}/open`, headers: auth(), payload: {} })).statusCode).toBe(404);
    expect((await app.inject({ method: 'POST', url: `/projects/${project}/open`, headers: auth(), payload: { conversationId: secondChat.id } })).statusCode).toBe(404);
    expect((await app.inject({ method: 'POST', url: `/projects/${project}/open`, headers: auth(), payload: { conversationId: id } })).json()).toEqual({ projectId: project, conversationId: id });
    const home = (await overview()).json();
    expect(home.recent.id).toBe(project); expect(home.recent.conversation.id).toBe(id); expect(home.recent.lastOpenedAt).toBeTruthy();
    expect(home.recent.repository.githubUrl).toBe('https://github.com/example/example');
    expect((await app.inject({ method: 'POST', url: `/projects/${project}/open`, headers: auth(), payload: {} })).json().conversationId).toBe(id);
  });
  it('searches owned projects, linked repositories and actual messages without exposing another owner', async () => {
    const hidden = await new Store(pool).createProject(other, 'Needle hidden project');
    const turn = await store.begin(owner, id, randomUUID(), 'Investigate needle message content', 'account-1');
    await store.finish(owner, id, turn.turnId, 'COMPLETED', 'Actual recorded result');
    const matches = (await app.inject({ url: '/workspace/search?q=needle', headers: auth() })).json().results;
    expect(matches.some((m: { conversationId: string }) => m.conversationId === id)).toBe(true);
    expect(matches.every((m: { projectId: string }) => m.projectId !== hidden.id)).toBe(true);
    const repos = (await app.inject({ url: '/workspace/search?q=example%2Fexample', headers: auth() })).json().results;
    expect(repos.some((m: { projectId: string; kind: string }) => m.projectId === project && m.kind === 'project')).toBe(true);
    expect((await app.inject({ url: '/workspace/search?q=needle', headers: auth(other) })).json().results.every((m: { projectId: string }) => m.projectId === hidden.id)).toBe(true);
    expect((await app.inject({ url: '/workspace/search?q=x', headers: auth() })).statusCode).toBe(400);
  });
  it('pages the complete authorized Home project list with stable name sorting', async () => {
    await pool.query("INSERT INTO projects(id,owner_id,name) SELECT gen_random_uuid(),$1,'Page project '||lpad(g::text,3,'0') FROM generate_series(1,52) g", [owner]);
    const first = (await app.inject({ url: '/workspace/home?sort=name', headers: auth() })).json();
    const last = (await app.inject({ url: '/workspace/home?sort=name&offset=50', headers: auth() })).json();
    expect(first.total).toBe(53); expect(first.projects).toHaveLength(50); expect(first.nextOffset).toBe(50);
    expect(last.projects).toHaveLength(3); expect(last.nextOffset).toBeNull();
    expect(new Set([...first.projects, ...last.projects].map(p => p.id)).size).toBe(53);
  });
  it('owns every route and refuses real dispatch through HTTP independently of the task simulator', async () => {
    for (const url of [`/projects/${project}/conversations`, `/projects/${project}/context`, `/projects/${project}/context/export`, `/conversations/${id}`, `/conversations/${id}/messages`, `/conversations/${id}/events`, `/conversations/${id}/transcript`]) {
      expect((await app.inject({ url, headers: auth(other) })).statusCode).toBe(404);
      expect((await app.inject({ url })).statusCode).toBe(401);
    }
    expect((await app.inject({ method: 'POST', url: `/conversations/${id}/messages`, headers: auth(), payload: { prompt: 'Run commands' } })).statusCode).toBe(403);
    expect((await app.inject({ method: 'POST', url: `/projects/${project}/conversations`, headers: auth(), payload: { repositoryId: repository, title: 'Oops', nativeSessionId: native } })).statusCode).toBe(400);
    expect((await app.inject({ method: 'PUT', url: `/projects/${project}/context`, headers: auth(other), payload: { revision: 0, summary: '', handoff: '' } })).statusCode).toBe(404);
  });
  it('serializes duplicate IDs, detects changed retry content and preserves native/project/profile bindings', async () => {
    const key = randomUUID(); const both = await Promise.all([store.begin(owner, id, key, 'Hello', 'account-1'), store.begin(owner, id, key, 'Hello', 'account-1')]);
    expect(both.filter(x => !x.replayed)).toHaveLength(1); expect(both[0]!.turnId).toBe(both[1]!.turnId);
    await store.bind(owner, id, native); await expect(store.bind(owner, id, randomUUID())).rejects.toThrow('mismatch');
    await store.finish(owner, id, both[0]!.turnId, 'COMPLETED', 'Actual returned reply');
    expect((await store.begin(owner, id, key, 'Hello', 'account-1')).response).toBe('Actual returned reply');
    await expect(store.begin(owner, id, key, 'different', 'account-1')).rejects.toThrow();
    await expect(store.begin(owner, id, randomUUID(), 'Next', 'account-2')).rejects.toThrow();
    const events = await store.events(owner, id); expect(events.events.filter(e => e.kind === 'USER_MESSAGE')).toHaveLength(1);
    expect(events.events.map(e => e.sequence)).toEqual(events.events.map((_, index) => index + 1));
  });
  it('marks crash-time delivery uncertain and never silently resends it', async () => {
    const key = randomUUID(); await store.begin(owner, id, key, 'Uncertain input', 'account-1'); await store.recoverInterrupted(owner, id);
    expect((await store.begin(owner, id, key, 'Uncertain input', 'account-1')).status).toBe('UNCERTAIN');
    await expect(store.begin(owner, id, randomUUID(), 'New input', 'account-1')).rejects.toThrow();
    expect((await store.history(owner, id)).messages[0]!.response).toBeNull();
  });
  it('searches actual content, versions metadata changes and preserves archived transcripts', async () => {
    const turn = await store.begin(owner, id, randomUUID(), 'Find a violet orchid', 'account-1');
    await store.finish(owner, id, turn.turnId, 'COMPLETED', 'Recorded search result');
    expect((await store.list(owner, project, 'violet')).conversations.map(c => c.id)).toEqual([id]);
    expect((await store.list(owner, project, 'missing phrase')).conversations).toHaveLength(0);
    const renamed = await store.update(owner, id, 0, { title: 'Renamed review' }); expect(renamed.revision).toBe(1);
    await expect(store.update(owner, id, 0, { title: 'stale name' })).rejects.toThrow();
    await expect(store.update(other, id, 1, { archived: true })).rejects.toThrow();
    expect((await app.inject({ method: 'PUT', url: `/conversations/${id}`, headers: auth(), payload: { revision: 1, title: 'both', archived: true } })).statusCode).toBe(400);
    await store.update(owner, id, 1, { archived: true });
    expect((await store.list(owner, project)).conversations).toHaveLength(0);
    expect((await store.list(owner, project, '', true)).conversations).toHaveLength(1);
    await expect(store.begin(owner, id, randomUUID(), 'new message', 'account-1')).rejects.toThrow();
    const markdown = await transcript(store, owner, id); expect(markdown).toContain('Conversation renamed'); expect(markdown).toContain('Conversation archived'); expect(markdown).toContain('Recorded search result');
    await store.update(owner, id, 2, { archived: false }); expect((await store.list(owner, project)).conversations).toHaveLength(1);
  });
  it('checks context revisions, rejects oversized/secret inputs and exports actual replies with secret filtering', async () => {
    await store.saveContext(owner, project, 0, 'Architecture decision', 'Continue testing');
    await expect(store.saveContext(owner, project, 0, 'stale', '')).rejects.toThrow();
    await expect(store.begin(owner, id, randomUUID(), token, 'account-1')).rejects.toThrow();
    await expect(store.begin(owner, id, randomUUID(), 'é'.repeat(9000), 'account-1')).rejects.toThrow();
    const turn = await store.begin(owner, id, randomUUID(), '<img src=x onerror=alert(1)>\n~~~', 'account-1');
    await store.bind(owner, id, native); await store.finish(owner, id, turn.turnId, 'COMPLETED', `Actual reply ${token}`);
    const markdown = await transcript(store, owner, id); expect(markdown).toContain('## Agent'); expect(markdown).toContain('Actual reply [REDACTED]'); expect(markdown).not.toContain(token);
    const target = await exportProject(store, owner, project, path.join(folder, 'exports'));
    expect(await readFile(path.join(target, `conversations/conversation-${id}.md`), 'utf8')).toBe(markdown);
    expect(await readFile(path.join(target, 'PROJECT_CONTEXT.md'), 'utf8')).toContain('Architecture decision');
    const outside = path.join(folder, 'outside'); await mkdir(outside); const linked = path.join(folder, 'linked'); await symlink(outside, linked, 'junction');
    await expect(exportProject(store, owner, project, linked)).rejects.toThrow('Redirected');
  });
  it('runs multiple messages through one transport and resumes by exact ID after a clean restart', async () => {
    const profile = path.join(folder, 'profile'); await mkdir(path.join(profile, '.gemini/antigravity-cli'), { recursive: true });
    const settings = path.join(profile, '.gemini/antigravity-cli/settings.json'); await writeFile(settings, '{"modelProvider":"google"}');
    await store.saveContext(owner, project, 0, 'Portable decision', 'Portable handoff');
    const prompts: string[] = [], resumeIds: (string | undefined)[] = [];
    const factory: SessionFactory = (options, bind, progress) => {
      resumeIds.push(options.sessionId); return { async turn(prompt) { prompts.push(prompt); await bind(native); await progress({ stepType: 'agent_response', state: 'ACTIVE' }); return { conversationId: native, status: 'SUCCESS', response: 'Actual fixture response', denied: false }; }, async close() {} };
    };
    const options = { executable: process.execPath, profile, profileBinding: 'account-1', exportRoot: path.join(folder, 'exports') };
    const messages = [{ id: randomUUID(), content: 'First prompt' }, { id: randomUUID(), content: 'Follow-up' }];
    await relayLocal(store, owner, id, messages, options, factory);
    expect(prompts[0]).toContain('Portable decision'); expect(prompts[1]).toBe('Follow-up'); expect(resumeIds).toEqual([undefined]);
    await relayLocal(store, owner, id, messages, options, factory); expect(prompts).toHaveLength(2);
    await relayLocal(store, owner, id, [{ id: randomUUID(), content: 'After restart' }], options, factory); expect(resumeIds).toEqual([undefined, native]);
    expect(await readFile(settings, 'utf8')).toBe('{"modelProvider":"google"}');
  });
  it('restores profile permissions after a transport failure and refuses an automatic resend', async () => {
    const profile = path.join(folder, 'profile'); await mkdir(path.join(profile, '.gemini/antigravity-cli'), { recursive: true });
    const settings = path.join(profile, '.gemini/antigravity-cli/settings.json'); await writeFile(settings, '{"original":true}');
    let sends = 0;
    const factory: SessionFactory = () => ({ async turn() { sends++; throw new Error('Disconnected after sending'); }, async close() {} });
    const messages = [{ id: randomUUID(), content: 'Possibly delivered' }];
    const options = { executable: process.execPath, profile, profileBinding: 'account-1', exportRoot: path.join(folder, 'exports') };
    await expect(relayLocal(store, owner, id, messages, options, factory)).rejects.toThrow();
    expect((await store.history(owner, id)).messages[0]!.status).toBe('UNCERTAIN');
    expect(await readFile(settings, 'utf8')).toBe('{"original":true}');
    await expect(relayLocal(store, owner, id, messages, options, factory)).rejects.toThrow(); expect(sends).toBe(1);
  });
});
