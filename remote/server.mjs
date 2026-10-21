import { createServer } from 'node:http';
import { randomBytes, randomUUID, scryptSync, timingSafeEqual } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { lstat, readFile, writeFile, rename } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';

const page = readFileSync(new URL('./index.html', import.meta.url));
export function buildPortal({ password, token, owner, origin, backend = 'http://127.0.0.1:3000', allowTaskSubmission = true, displayName = null, onProfileChange = async () => {} }) {
  if (!password || password.length < 20 || !token || !owner || !origin) throw new Error('Remote access configuration missing');
  const salt = randomBytes(32);
  const expected = scryptSync(password, salt, 32);
  const sessions = new Map();
  const attempts = new Map();
  const cookieName = '__Host-jess';
  let profileName = typeof displayName === 'string' && /^[\p{L}\p{N} .'-]{1,80}$/u.test(displayName) ? displayName : null;
  const headers = {
    'cache-control': 'no-store', 'x-content-type-options': 'nosniff',
    'referrer-policy': 'no-referrer', 'x-frame-options': 'DENY',
    'strict-transport-security': 'max-age=86400',
    'content-security-policy': "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; frame-ancestors 'none'; form-action 'self'; base-uri 'none'",
    'permissions-policy': 'camera=(), microphone=(), geolocation=()',
  };
  const json = (res, status, value, extra = {}) => {
    res.writeHead(status, { ...headers, 'content-type': 'application/json', ...extra });
    res.end(JSON.stringify(value));
  };
  async function body(req, maxSize = 16384) {
    if (!(req.headers['content-type'] ?? '').startsWith('application/json')) throw new Error('Invalid content type');
    const chunks = []; let size = 0;
    for await (const chunk of req) {
      size += chunk.length;
      if (size > maxSize) throw new Error('Body too large');
      chunks.push(chunk);
    }
    return JSON.parse(Buffer.concat(chunks).toString());
  }
  const clean = setInterval(() => {
    const now = Date.now();
    for (const [key, expiry] of sessions) if (expiry <= now) sessions.delete(key);
    for (const [key, value] of attempts) if (value.until <= now) attempts.delete(key);
  }, 60000);
  clean.unref();
  const server = createServer({ requestTimeout: 15000, headersTimeout: 15000, maxHeaderSize: 8192 }, async (req, res) => {
    try {
      if (req.headers.host !== new URL(origin).host) return json(res, 403, { error: 'Invalid host' });
      const url = new URL(req.url, origin);
      if (!['GET', 'POST', 'PUT'].includes(req.method)) return json(res, 405, { error: 'Method not allowed' });
      if (['POST', 'PUT'].includes(req.method) && req.headers.origin !== origin) return json(res, 403, { error: 'Invalid origin' });
      if (req.method === 'GET' && url.pathname === '/') {
        const nonce = randomBytes(24).toString('base64');
        res.writeHead(200, { ...headers, 'content-security-policy': headers['content-security-policy'].replace("style-src 'self'", `style-src 'self' 'nonce-${nonce}'`), 'content-type': 'text/html; charset=utf-8' });
        return res.end(page.toString().replace('</head>', `<meta name="jess-style-nonce" content="${nonce}"></head>`));
      }
      const assets = { '/home.js': 'application/javascript', '/home.css': 'text/css', '/app.js': 'application/javascript', '/files.js': 'application/javascript', '/chat.js': 'application/javascript', '/markdown.js': 'application/javascript', '/editor.js': 'application/javascript', '/editor-licenses.txt': 'text/plain; charset=utf-8', '/api.js': 'application/javascript', '/state.js': 'application/javascript', '/style.css': 'text/css', '/chat.css': 'text/css', '/manifest.webmanifest': 'application/manifest+json', '/icon.svg': 'image/svg+xml', '/sw.js': 'application/javascript', '/offline.html': 'text/html; charset=utf-8' };
      if (req.method === 'GET' && Object.hasOwn(assets, url.pathname)) {
        const file = ['/editor.js', '/editor-licenses.txt', '/markdown.js'].includes(url.pathname) ? `../dist/remote${url.pathname}` : url.pathname.slice(1);
        res.writeHead(200, { ...headers, 'content-type': assets[url.pathname] });
        return res.end(readFileSync(new URL(file, import.meta.url)));
      }
      if (req.method === 'POST' && url.pathname === '/login') {
        const now = Date.now();
        const key = String(req.headers['cf-connecting-ip'] ?? req.socket.remoteAddress).slice(0, 100);
        const limit = attempts.get(key) ?? { count: 0, until: now + 600000 };
        const global = attempts.get('*') ?? { count: 0, until: now + 600000 };
        if (limit.until <= now) { limit.count = 0; limit.until = now + 600000; }
        if (global.until <= now) { global.count = 0; global.until = now + 600000; }
        if (limit.count >= 5 || global.count >= 40) return json(res, 429, { error: 'Too many attempts. Wait 10 minutes.' });
        limit.count++; global.count++; attempts.set(key, limit); attempts.set('*', global);
        const value = await body(req);
        const input = typeof value.password === 'string' && value.password.length <= 256 ? value.password : '';
        if (!timingSafeEqual(scryptSync(input, salt, 32), expected)) return json(res, 401, { error: 'Incorrect password' });
        if (sessions.size >= 100) return json(res, 429, { error: 'Too many sessions' });
        const id = randomBytes(32).toString('hex');
        sessions.set(id, now + 8 * 3600000);
        return json(res, 200, { ok: true }, { 'set-cookie': `${cookieName}=${id}; HttpOnly; Secure; SameSite=Strict; Path=/; Max-Age=28800` });
      }
      const id = String(req.headers.cookie ?? '').split(';').map(s => s.trim()).find(s => s.startsWith(cookieName + '='))?.slice(cookieName.length + 1);
      if (!id || (sessions.get(id) ?? 0) <= Date.now()) return json(res, 401, { error: 'Please sign in' });
      if (req.method === 'PUT' && url.pathname === '/profile') {
        const input = await body(req, 1024);
        if (!input || Object.keys(input).some(key => key !== 'displayName') || typeof input.displayName !== 'string' || !/^[\p{L}\p{N} .'-]{0,80}$/u.test(input.displayName) || [password, token].some(secret => input.displayName.includes(secret))) return json(res, 400, { error: 'Enter a display name up to 80 characters.' });
        const name = input.displayName.trim() || null; await onProfileChange(name); profileName = name;
        return json(res, 200, { user: { displayName: profileName } });
      }
      if (req.method === 'POST' && url.pathname === '/logout') {
        sessions.delete(id);
        return json(res, 200, { ok: true }, { 'set-cookie': `${cookieName}=; HttpOnly; Secure; SameSite=Strict; Path=/; Max-Age=0` });
      }
      if (req.method === 'GET' && url.pathname === '/session') return json(res, 200, { ok: true, user: { displayName: profileName }, capabilities: { taskSubmission: allowTaskSubmission, agentMode: allowTaskSubmission ? 'simulated' : 'local-only', files: true, fileStorage: 'review-snapshot', chatHistory: true, chatSubmission: false, gitApprovals: false, eventTransport: 'replay' } });
      const uuid = '[0-9a-fA-F-]{36}';
      const workspaceRead = new RegExp(`^/api/workspaces/${uuid}(/files|/file|/diff)?$`).test(url.pathname);
      const workspaceWrite = req.method === 'PUT' && new RegExp(`^/api/workspaces/${uuid}/file$`).test(url.pathname);
      const workspaceCreate = req.method === 'POST' && new RegExp(`^/api/tasks/${uuid}/workspace$`).test(url.pathname);
      const chatRead = req.method === 'GET' && (new RegExp(`^/api/projects/${uuid}/(conversations|context|context/export)$`).test(url.pathname) || new RegExp(`^/api/conversations/${uuid}(/messages|/events|/transcript)?$`).test(url.pathname));
      const chatCreate = req.method === 'POST' && new RegExp(`^/api/projects/${uuid}/conversations$`).test(url.pathname);
      const chatMetadataWrite = req.method === 'PUT' && new RegExp(`^/api/conversations/${uuid}$`).test(url.pathname);
      const contextWrite = req.method === 'PUT' && new RegExp(`^/api/projects/${uuid}/context$`).test(url.pathname);
      const homeRead = req.method === 'GET' && ['/api/workspace/home', '/api/workspace/search'].includes(url.pathname);
      const projectOpen = req.method === 'POST' && new RegExp(`^/api/projects/${uuid}/open$`).test(url.pathname);
      if (req.method === 'POST' && new RegExp(`^/api/conversations/${uuid}/messages$`).test(url.pathname)) return json(res, 403, { error: 'Public agent messaging is disabled until execution isolation is available' });
      const allowed = (req.method === 'GET' && (['/api/ready', '/api/projects', '/api/tasks', '/api/repositories', '/api/workspaces'].includes(url.pathname) || workspaceRead || new RegExp(`^/api/tasks/${uuid}(/events)?$`).test(url.pathname))) ||
        (req.method === 'POST' && (['/api/projects', '/api/tasks'].includes(url.pathname) || new RegExp(`^/api/tasks/${uuid}/cancel$`).test(url.pathname))) || workspaceCreate || workspaceWrite || chatRead || chatCreate || contextWrite || chatMetadataWrite || homeRead || projectOpen;
      if (!allowed) return json(res, 404, { error: 'Not found' });
      if (!allowTaskSubmission && req.method === 'POST' && url.pathname === '/api/tasks') return json(res, 403, { error: 'Real agent execution is available only locally during development' });
      const target = new URL(url.pathname.slice(4), backend);
      if (url.pathname.endsWith('/events')) {
        for (const key of ['after', 'limit']) if (url.searchParams.has(key)) target.searchParams.set(key, url.searchParams.get(key));
      }
      if (req.method === 'GET' && ['/api/projects', '/api/tasks'].includes(url.pathname)) {
        for (const key of ['before', 'limit']) if (url.searchParams.has(key)) target.searchParams.set(key, url.searchParams.get(key));
      }
      if (req.method === 'GET' && workspaceRead) {
        for (const key of ['path', 'offset']) if (url.searchParams.has(key)) target.searchParams.set(key, url.searchParams.get(key));
      }
      if (chatRead) for (const key of ['after', 'before', 'search', 'archived']) if (url.searchParams.has(key)) target.searchParams.set(key, url.searchParams.get(key));
      if (homeRead) for (const key of ['sort', 'offset', 'q']) if (url.searchParams.has(key)) target.searchParams.set(key, url.searchParams.get(key));
      const forwardHeaders = { authorization: `Bearer ${token}`, 'x-dev-user-id': owner };
      let data;
      if ((req.method === 'POST' && !url.pathname.endsWith('/cancel')) || workspaceWrite || contextWrite || chatMetadataWrite) {
        const input = await body(req, workspaceWrite ? 400000 : contextWrite ? 200000 : 16384);
        data = JSON.stringify(projectOpen ? (input.conversationId ? { conversationId: input.conversationId } : {}) : chatMetadataWrite ? { revision: input.revision, ...(input.title !== undefined ? { title: input.title } : {}), ...(input.archived !== undefined ? { archived: input.archived } : {}) } : contextWrite ? { revision: input.revision, summary: input.summary, handoff: input.handoff } : chatCreate ? { repositoryId: input.repositoryId, title: input.title } : workspaceWrite ? { path: input.path, content: input.content } : workspaceCreate ? { repositoryId: input.repositoryId } : url.pathname === '/api/projects' ? { name: input.name } : { projectId: input.projectId, prompt: input.prompt });
        forwardHeaders['content-type'] = 'application/json';
        if (workspaceWrite && typeof req.headers['if-match'] === 'string') forwardHeaders['if-match'] = req.headers['if-match'].slice(0, 100);
        if (url.pathname === '/api/tasks') forwardHeaders['idempotency-key'] = String(req.headers['idempotency-key'] ?? randomUUID()).slice(0, 128);
      }
      const result = await fetch(target, { method: req.method, headers: forwardHeaders, body: data, signal: AbortSignal.timeout(12000), redirect: 'error' });
      json(res, result.status, await result.json());
    } catch { if (!res.headersSent) json(res, 400, { error: 'Request failed. Check the laptop connection.' }); else res.end(); }
  });
  server.on('close', () => clearInterval(clean));
  return server;
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const config = JSON.parse(readFileSync(new URL('../.local/remote-config.json', import.meta.url)));
  const onProfileChange = async displayName => {
    const destination = new URL('../.local/remote-config.json', import.meta.url), info = await lstat(destination);
    if (!info.isFile() || info.isSymbolicLink() || info.nlink !== 1) throw new Error('Unsafe profile configuration');
    const latest = JSON.parse((await readFile(destination, 'utf8')).replace(/^\uFEFF/, ''));
    const temporary = new URL(`../.local/remote-config-${randomUUID()}.tmp`, import.meta.url);
    await writeFile(temporary, JSON.stringify({ ...latest, displayName }, null, 2), { flag: 'wx', mode: 0o600 }); await rename(temporary, destination);
  };
  buildPortal({ ...config, onProfileChange, token: process.env.DEV_AUTH_TOKEN, allowTaskSubmission: (process.env.AGENT_PROVIDER ?? 'fake') === 'fake' }).listen(3001, '127.0.0.1', () => console.log('Password-protected mobile portal listening on loopback port 3001'));
}
