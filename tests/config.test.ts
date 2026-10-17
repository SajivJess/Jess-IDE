import { afterEach, describe, expect, it } from 'vitest';
import type { FastifyInstance } from 'fastify';
import { loadConfig } from '../src/config.js';
import { createPool } from '../src/db/pool.js';
import { buildApp } from '../src/api/app.js';

const testEnv = {
  NODE_ENV: 'test', AUTH_MODE: 'development', DEV_AUTH_TOKEN: 'test-only-token-that-is-not-a-secret-12345',
  DATABASE_URL: 'postgresql://unused:unused@127.0.0.1:1/unavailable',
};

describe('configuration guards', () => {
  it('requires explicit non-production authentication configuration', () => {
    for (const nodeEnv of [undefined, 'production', 'staging']) {
      expect(() => loadConfig({ ...testEnv, NODE_ENV: nodeEnv })).toThrow();
    }
    expect(() => loadConfig({ ...testEnv, AUTH_MODE: undefined })).toThrow();
    expect(() => loadConfig({ ...testEnv, DEV_AUTH_TOKEN: 'REPLACE_WITH_RANDOM_DEVELOPMENT_TOKEN' })).toThrow();
    expect(() => loadConfig({ ...testEnv, DEV_AUTH_TOKEN: 'short' })).toThrow();
    expect(() => loadConfig({ ...testEnv, DATABASE_URL: 'not-a-url' })).toThrow();
    expect(() => loadConfig({ ...testEnv, DATABASE_URL: 'http://example.com' })).toThrow();
  });

  it('checks bounded integer settings', () => {
    expect(() => loadConfig({ ...testEnv, PORT: 'not-a-number' })).toThrow();
    expect(() => loadConfig({ ...testEnv, WORKER_LEASE_MS: '0' })).toThrow();
    expect(loadConfig(testEnv).leaseMs).toBe(15000);
  });
});

describe('HTTP boundary without PostgreSQL', () => {
  let app: FastifyInstance | undefined;
  const pool = createPool(testEnv.DATABASE_URL);
  afterEach(async () => { await app?.close(); app = undefined; });

  it('serves liveness even when the database is unreachable', async () => {
    app = buildApp(loadConfig(testEnv), pool, false);
    const response = await app.inject({ method: 'GET', url: '/health' });
    expect(response.statusCode).toBe(200);
    expect(response.json()).toEqual({ status: 'ok' });
  });

  it('rejects missing, invalid and malformed development identities', async () => {
    app = buildApp(loadConfig(testEnv), pool, false);
    const users = [undefined, 'not-a-uuid', '00000000-0000-4000-8000-000000000001'];
    for (const user of users) {
      const response = await app.inject({ method: 'GET', url: '/ready', headers: user ? { 'x-dev-user-id': user } : {} });
      expect(response.statusCode).toBe(401);
      expect(response.json()).toEqual({ error: 'UNAUTHORIZED' });
    }
    for (const headers of [
      { authorization: `Bearer ${testEnv.DEV_AUTH_TOKEN}`, 'x-dev-user-id': 'not-a-uuid' },
      { authorization: `Bearer ${testEnv.DEV_AUTH_TOKEN}` },
      { authorization: 'Bearer invalid', 'x-dev-user-id': '00000000-0000-4000-8000-000000000001' },
    ]) expect((await app.inject({ method: 'GET', url: '/ready', headers })).statusCode).toBe(401);
  });

  it('returns a safe 503 on an actual refused database connection', async () => {
    app = buildApp(loadConfig(testEnv), pool, false);
    const response = await app.inject({ method: 'GET', url: '/ready', headers: {
      authorization: `Bearer ${testEnv.DEV_AUTH_TOKEN}`, 'x-dev-user-id': '00000000-0000-4000-8000-000000000001',
    } });
    expect(response.statusCode).toBe(503);
    expect(response.json()).toEqual({ error: 'SERVICE_UNAVAILABLE' });
    expect(response.body).not.toContain('postgresql');
    await pool.end();
  });
});
