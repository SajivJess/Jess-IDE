import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createServer, request as httpRequest } from 'node:http';
import { once } from 'node:events';
import { buildPortal } from './server.mjs';

test('remote gateway requires login, checks origin, and isolates backend credentials', async () => {
  let captured;
  const backend = createServer((req, res) => { captured = req.headers; res.setHeader('content-type', 'application/json'); res.end('{"status":"ready"}'); });
  backend.listen(0, '127.0.0.1'); await once(backend, 'listening');
  const origin = 'https://portal.example';
  const portal = buildPortal({ password: 'a-long-test-password-12345', token: 'private-backend-token', owner: 'fixed-test-owner', origin, backend: `http://127.0.0.1:${backend.address().port}` });
  portal.listen(0, '127.0.0.1'); await once(portal, 'listening');
  const base = `http://127.0.0.1:${portal.address().port}`;
  const request = (path, init = {}) => new Promise((resolve, reject) => {
    const req = httpRequest(base + path, { method: init.method ?? 'GET', headers: { host: 'portal.example', ...init.headers } }, res => {
      res.resume();
      res.on('end', () => resolve({ status: res.statusCode, headers: { get: name => Array.isArray(res.headers[name]) ? res.headers[name].join(';') : res.headers[name] } }));
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
    const ready = await request('/api/ready', { headers: { cookie, authorization: 'Bearer attacker', 'x-dev-user-id': 'attacker' } });
    assert.equal(ready.status, 200);
    assert.equal(captured.authorization, 'Bearer private-backend-token');
    assert.equal(captured['x-dev-user-id'], 'fixed-test-owner');
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
