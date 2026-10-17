import { createServer } from 'node:http';
import { randomBytes, randomUUID, scryptSync, timingSafeEqual } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

const page = readFileSync(new URL('./index.html', import.meta.url));
export function buildPortal({ password, token, owner, origin, backend = 'http://127.0.0.1:3000' }) {
  if (!password || password.length < 20 || !token || !owner || !origin) throw new Error('Remote access configuration missing');
  const salt = randomBytes(32);
  const expected = scryptSync(password, salt, 32);
  const sessions = new Map();
  const attempts = new Map();
  const cookieName = '__Host-jess';
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
  async function body(req) {
    if (!(req.headers['content-type'] ?? '').startsWith('application/json')) throw new Error('Invalid content type');
    const chunks = []; let size = 0;
    for await (const chunk of req) {
      size += chunk.length;
      if (size > 16384) throw new Error('Body too large');
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
      if (!['GET', 'POST'].includes(req.method)) return json(res, 405, { error: 'Method not allowed' });
      if (req.method === 'POST' && req.headers.origin !== origin) return json(res, 403, { error: 'Invalid origin' });
      if (req.method === 'GET' && url.pathname === '/') {
        res.writeHead(200, { ...headers, 'content-type': 'text/html; charset=utf-8' }); return res.end(page);
      }
      if (req.method === 'GET' && ['/app.js', '/style.css'].includes(url.pathname)) {
        const file = url.pathname === '/app.js' ? 'app.js' : 'style.css';
        res.writeHead(200, { ...headers, 'content-type': file.endsWith('.js') ? 'application/javascript' : 'text/css' });
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
      if (req.method === 'POST' && url.pathname === '/logout') {
        sessions.delete(id);
        return json(res, 200, { ok: true }, { 'set-cookie': `${cookieName}=; HttpOnly; Secure; SameSite=Strict; Path=/; Max-Age=0` });
      }
      if (req.method === 'GET' && url.pathname === '/session') return json(res, 200, { ok: true });
      const uuid = '[0-9a-fA-F-]{36}';
      const allowed = (req.method === 'GET' && (url.pathname === '/api/ready' || new RegExp(`^/api/tasks/${uuid}(/events)?$`).test(url.pathname))) ||
        (req.method === 'POST' && (['/api/projects', '/api/tasks'].includes(url.pathname) || new RegExp(`^/api/tasks/${uuid}/cancel$`).test(url.pathname)));
      if (!allowed) return json(res, 404, { error: 'Not found' });
      const target = new URL(url.pathname.slice(4), backend);
      if (url.pathname.endsWith('/events')) {
        for (const key of ['after', 'limit']) if (url.searchParams.has(key)) target.searchParams.set(key, url.searchParams.get(key));
      }
      const forwardHeaders = { authorization: `Bearer ${token}`, 'x-dev-user-id': owner };
      let data;
      if (req.method === 'POST' && !url.pathname.endsWith('/cancel')) {
        const input = await body(req);
        data = JSON.stringify(url.pathname === '/api/projects' ? { name: input.name } : { projectId: input.projectId, prompt: input.prompt });
        forwardHeaders['content-type'] = 'application/json';
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
  buildPortal({ ...config, token: process.env.DEV_AUTH_TOKEN }).listen(3001, '127.0.0.1', () => console.log('Password-protected mobile portal listening on loopback port 3001'));
}
