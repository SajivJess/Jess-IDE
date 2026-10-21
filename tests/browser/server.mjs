// Test-only local services against a disposable schema in TEST_DATABASE_URL.
// This process never starts the public tunnel or uses the production portal password.
import { randomUUID } from 'node:crypto';
import { once } from 'node:events';
import { mkdir, writeFile, unlink, access } from 'node:fs/promises';
import { buildApp } from '../../dist/api/app.js';
import { loadConfig } from '../../dist/config.js';
import { createPool } from '../../dist/db/pool.js';
import { migrate } from '../../dist/db/migrate.js';
import { Store } from '../../dist/db/store.js';
import { WorkspaceStore } from '../../dist/workspaces/store.js';
import { ChatStore } from '../../dist/chat/store.js';
import { Worker } from '../../dist/worker/worker.js';
import { FakeAgent } from '../../dist/agents/fake.js';
import { buildPortal } from '../../remote/server.mjs';

if (!process.env.TEST_DATABASE_URL) throw new Error('TEST_DATABASE_URL is required for browser tests');
await mkdir('.local', { recursive: true });
await unlink('.local/browser-stop').catch(() => {});
const schema = `jess_browser_${randomUUID().replaceAll('-', '')}`;
const admin = createPool(process.env.TEST_DATABASE_URL);
await admin.query(`CREATE SCHEMA "${schema}"`);
const pool = createPool(process.env.TEST_DATABASE_URL, schema);
await migrate(pool);
const token = randomUUID() + randomUUID();
const api = buildApp(loadConfig({ NODE_ENV: 'test', AUTH_MODE: 'development', DEV_AUTH_TOKEN: token, DATABASE_URL: process.env.TEST_DATABASE_URL }), pool, false);
const address = await api.listen({ port: 0, host: '127.0.0.1' });
const owner = randomUUID();
const source = 'export const greeting = "hello";\n';
const repositoryId = await new WorkspaceStore(pool).register(owner, { name: 'Browser fixture', githubUrl: 'https://github.com/example/fixture', branch: 'main', baseCommit: 'a'.repeat(40), sourceDirectory: 'E:\\test-fixture', files: [
  { path: 'src/main.ts', content: source, size: Buffer.byteLength(source), reason: null },
  { path: 'image.png', content: null, size: 42, reason: 'binary' },
] });
const chatProject = await new Store(pool).createProject(owner, 'Chat fixture project');
const chats = new ChatStore(pool);
const chat = await chats.create(owner, chatProject.id, repositoryId, 'Chat test fixture');
const turn = await chats.begin(owner, chat.id, randomUUID(), 'Browser fixture question', 'test-account');
await chats.bind(owner, chat.id, randomUUID());
await chats.finish(owner, chat.id, turn.turnId, 'COMPLETED', 'Recorded fixture reply <img src=x onerror=alert(1)>. Test fixture only; no real CLI invocation.\n\n## Review findings\n\n1. **Session validation** needs tests.\n2. Check ownership.\n\n```typescript\nexport const greeting: string = "hello";\n```\n\n| Check | Result |\n| --- | --- |\n| Fixture | Recorded |\n\n[Unsafe](javascript:alert(1)) ![tracking](https://attacker.example/pixel) <script>alert(1)</script>');
const portal = buildPortal({ password: 'browser-tests-only-password-12345', token, owner, displayName: 'Browser Tester', origin: 'http://localhost:4173', backend: address });
portal.listen(4173, '127.0.0.1'); await once(portal, 'listening');
const controller = new AbortController();
const worker = new Worker(new Store(pool), new FakeAgent(1000), 3000, 100).run(controller.signal, () => {});
let stopping = false;
const stopTimer = setInterval(() => { void access('.local/browser-stop').then(() => stop()).catch(() => {}); }, 300);
async function stop() {
  if (stopping) return; stopping = true;
  clearInterval(stopTimer);
  controller.abort(); await worker;
  portal.closeAllConnections(); await new Promise(resolve => portal.close(resolve));
  await api.close(); await pool.end();
  await admin.query(`DROP SCHEMA "${schema}" CASCADE`); await admin.end();
  await writeFile('.local/browser-stopped', 'clean');
}
await unlink('.local/browser-stopped').catch(() => {});
process.on('SIGINT', () => void stop()); process.on('SIGTERM', () => void stop());
console.log('Disposable local browser-test services ready');
