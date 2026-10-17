import { loadConfig } from '../config.js';
import { createPool } from '../db/pool.js';
import { Store } from '../db/store.js';
import { FakeAgent } from '../agents/fake.js';
import { Worker } from './worker.js';

try {
  const config = loadConfig();
  const pool = createPool(config.databaseUrl);
  pool.on('error', () => console.error('Database connection lost; worker will retry'));
  const controller = new AbortController();
  process.once('SIGINT', () => controller.abort());
  process.once('SIGTERM', () => controller.abort());
  console.log('Jess Ide Dev worker starting with fake-v1; no real execution');
  try {
    await new Worker(new Store(pool), new FakeAgent(config.fakeStepMs), config.leaseMs, config.pollMs)
      .run(controller.signal, () => console.error('Worker iteration failed; durable job will be reconciled'));
  } finally { await pool.end(); }
} catch {
  console.error('Worker startup failed; check configuration and database setup');
  process.exitCode = 1;
}
