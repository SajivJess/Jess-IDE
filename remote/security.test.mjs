import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createServer, request as httpRequest } from 'node:http';
import { once } from 'node:events';
import { buildPortal } from './server.mjs';

test('remote gateway requires login, checks origin, and isolates backend credentials', async () => {
  let captured;
  let capturedUrl;
  let capturedBody;
  let savedProfile;
  const backend = createServer((req, res) => {
    captured = req.headers; capturedUrl = req.url; capturedBody = '';
    req.on('data', chunk => { capturedBody += chunk; });
    req.on('end', () => { res.setHeader('content-type', 'application/json'); res.end('{"status":"ready"}'); });
  });
  backend.listen(0, '127.0.0.1'); await once(backend, 'listening');
  const origin = 'https://portal.example';
  const portal = buildPortal({ password: 'a-long-test-password-12345', token: 'private-backend-token', owner: 'fixed-test-owner', origin, displayName: 'Test user', onProfileChange: async name => { savedProfile = name; }, backend: `http://127.0.0.1:${backend.address().port}` });
  portal.listen(0, '127.0.0.1'); await once(portal, 'listening');
  const base = `http://127.0.0.1:${portal.address().port}`;
  const request = (path, init = {}) => new Promise((resolve, reject) => {
    const req = httpRequest(base + path, { method: init.method ?? 'GET', headers: { host: 'portal.example', ...init.headers } }, res => {
      let responseBody = ''; res.on('data', chunk => { responseBody += chunk; });
      res.on('end', () => resolve({ status: res.statusCode, body: responseBody, headers: { get: name => Array.isArray(res.headers[name]) ? res.headers[name].join(';') : res.headers[name] } }));
    });
    req.on('error', reject); req.end(init.body);
  });
  try {
    assert.equal((await request('/api/ready')).status, 401);
    assert.equal((await request('/login', { method: 'POST', headers: { 'content-type': 'application/json', origin: 'https://evil.example' }, body: '{}' })).status, 403);
    const login = await request('/login', { method: 'POST', headers: { 'content-type': 'application/json', origin }, body: JSON.stringify({ password: 'a-long-test-password-12345' }) });
    assert.equal(login.status, 200);
    const setCookie = login.headers.get('set-cookie');
    for (const flag of ['HttpOnly', 'Secure', 'SameSite=Strict', 'Path=/']) assert.ok(setCookie.includes(flag));
    const cookie = setCookie.split(';')[0];
    assert.equal(JSON.parse((await request('/session', { headers: { cookie } })).body).user.displayName, 'Test user');
    assert.equal((await request('/profile', { method: 'PUT', headers: { cookie, origin: 'https://evil.example', 'content-type': 'application/json' }, body: '{"displayName":"Changed"}' })).status, 403);
    assert.equal((await request('/profile', { method: 'PUT', headers: { cookie, origin, 'content-type': 'application/json' }, body: '{"displayName":"Avery","owner":"attacker"}' })).status, 400);
    assert.equal((await request('/profile', { method: 'PUT', headers: { cookie, origin, 'content-type': 'application/json' }, body: '{"displayName":"Avery"}' })).status, 200);
    assert.equal(savedProfile, 'Avery');
    assert.equal(JSON.parse((await request('/session', { headers: { cookie } })).body).user.displayName, 'Avery');
    assert.equal((await request('/api/workspace/home?sort=name&offset=50&owner=attacker', { headers: { cookie } })).status, 200);
    assert.equal(capturedUrl, '/workspace/home?sort=name&offset=50');
    assert.equal((await request('/api/projects/00000000-0000-4000-8000-000000000001/open', { method: 'POST', headers: { cookie, origin, 'content-type': 'application/json' }, body: '{"owner":"attacker"}' })).status, 200);
    assert.deepEqual(JSON.parse(capturedBody), {});
    const ready = await request('/api/ready', { headers: { cookie, authorization: 'Bearer attacker', 'x-dev-user-id': 'attacker' } });
    assert.equal(ready.status, 200);
    assert.equal(captured.authorization, 'Bearer private-backend-token');
    assert.equal(captured['x-dev-user-id'], 'fixed-test-owner');
    const conversationPath = '/api/conversations/00000000-0000-4000-8000-000000000001';
    assert.equal((await request(conversationPath + '/events?after=5&owner=attacker', { headers: { cookie } })).status, 200);
    assert.equal(capturedUrl, conversationPath.slice(4) + '/events?after=5');
    assert.equal((await request(conversationPath + '/messages', { method: 'POST', headers: { cookie, origin, 'content-type': 'application/json' }, body: '{"content":"run tools"}' })).status, 403);
    assert.equal((await request(conversationPath, { method: 'PUT', headers: { cookie, origin: 'https://evil.example', 'content-type': 'application/json' }, body: '{"revision":0,"title":"Other"}' })).status, 403);
    assert.equal((await request(conversationPath, { method: 'PUT', headers: { cookie, origin, 'content-type': 'application/json', 'x-dev-user-id': 'attacker' }, body: '{"revision":2,"title":"Renamed","owner":"attacker","nativeSessionId":"injected"}' })).status, 200);
    assert.deepEqual(JSON.parse(capturedBody), { revision: 2, title: 'Renamed' });
    assert.equal(captured['x-dev-user-id'], 'fixed-test-owner');
    const conversationsPath = '/api/projects/00000000-0000-4000-8000-000000000001/conversations';
    assert.equal((await request(conversationsPath + '?search=actual+message&archived=true&owner=attacker', { headers: { cookie } })).status, 200);
    assert.equal(capturedUrl, conversationsPath.slice(4) + '?search=actual+message&archived=true');
    const contextPath = '/api/projects/00000000-0000-4000-8000-000000000001/context';
    assert.equal((await request(contextPath, { method: 'PUT', headers: { cookie, 'content-type': 'application/json' }, body: '{}' })).status, 403);
    assert.equal((await request(contextPath, { method: 'PUT', headers: { cookie, origin, 'content-type': 'application/json' }, body: '{"revision":0,"summary":"notes","handoff":"next"}' })).status, 200);
    assert.equal(captured['x-dev-user-id'], 'fixed-test-owner');
    const filePath = '/api/workspaces/00000000-0000-4000-8000-000000000001/file';
    assert.equal((await request(filePath, { method: 'PUT', headers: { cookie, origin: 'https://evil.example', 'content-type': 'application/json' }, body: '{}' })).status, 403);
    assert.equal((await request(filePath, { method: 'PUT', headers: { cookie, origin, 'content-type': 'application/json', 'if-match': '"version-hash"', 'x-dev-user-id': 'attacker' }, body: JSON.stringify({ path: 'src/main.ts', content: 'edit', owner: 'attacker' }) })).status, 200);
    assert.equal(captured['if-match'], '"version-hash"');
    assert.equal(captured['x-dev-user-id'], 'fixed-test-owner');
    assert.equal((await request('/api/repositories', { method: 'POST', headers: { cookie, origin, 'content-type': 'application/json' }, body: '{}' })).status, 404);
    const html = await request('/');
    assert.match(html.headers.get('content-security-policy'), /style-src 'self' 'nonce-[A-Za-z0-9+/=]+'/);
    assert.ok(!html.headers.get('content-security-policy').includes('unsafe-inline'));
    for (const path of ['/api/projects', '/api/tasks']) {
      assert.equal((await request(path + '?limit=10&before=cursor&owner_id=attacker', { headers: { cookie } })).status, 200);
      assert.equal(capturedUrl, path.slice(4) + '?before=cursor&limit=10');
      assert.equal(captured['x-dev-user-id'], 'fixed-test-owner');
    }
    for (const path of ['/api/files', '/api/shell', '/api/tasks/00000000-0000-4000-8000-000000000001/approve']) {
      assert.equal((await request(path, { headers: { cookie } })).status, 404);
    }
    assert.equal((await request('/api/../../.env', { headers: { cookie } })).status, 404);
    assert.equal((await request('/api/tasks', { method: 'POST', headers: { cookie } })).status, 403);
    assert.equal((await request('/api/tasks/00000000-0000-4000-8000-000000000001/events/stream', { headers: { cookie } })).status, 404);
    assert.equal((await request('/logout', { method: 'POST', headers: { cookie, origin } })).status, 200);
    assert.equal((await request('/api/ready', { headers: { cookie } })).status, 401);
    for (let i = 0; i < 4; i++) assert.equal((await request('/login', { method: 'POST', headers: { origin, 'content-type': 'application/json' }, body: '{"password":"wrong"}' })).status, 401);
    assert.equal((await request('/login', { method: 'POST', headers: { origin, 'content-type': 'application/json' }, body: '{"password":"wrong"}' })).status, 429);
  } finally {
    portal.closeAllConnections(); backend.closeAllConnections();
    await Promise.all([new Promise(resolve => portal.close(resolve)), new Promise(resolve => backend.close(resolve))]);
  }
});

test('public task execution stays disabled for the real local adapter', async () => {
  const origin = 'https://portal.example';
  const portal = buildPortal({ password: 'a-long-test-password-12345', token: 'private-token', owner: 'owner', origin, allowTaskSubmission: false });
  portal.listen(0, '127.0.0.1'); await once(portal, 'listening');
  const base = `http://127.0.0.1:${portal.address().port}`;
  const request = (path, init = {}) => new Promise((resolve, reject) => {
    const req = httpRequest(base + path, { method: init.method ?? 'GET', headers: { host: 'portal.example', ...init.headers } }, res => {
      res.resume(); res.on('end', () => resolve({ status: res.statusCode, cookie: res.headers['set-cookie']?.[0]?.split(';')[0] }));
    });
    req.on('error', reject); req.end(init.body);
  });
  try {
    const login = await request('/login', { method: 'POST', headers: { origin, 'content-type': 'application/json' }, body: '{"password":"a-long-test-password-12345"}' });
    assert.equal(login.status, 200);
    assert.equal((await request('/api/tasks', { method: 'POST', headers: { origin, cookie: login.cookie, 'content-type': 'application/json' }, body: '{}' })).status, 403);
  } finally { portal.closeAllConnections(); await new Promise(resolve => portal.close(resolve)); }
});
