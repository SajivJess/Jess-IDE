import { loadConfig } from '../config.js';
import { createPool } from '../db/pool.js';
import { buildApp } from './app.js';

try {
  const config = loadConfig();
  const pool = createPool(config.databaseUrl);
  const app = buildApp(config, pool);
  pool.on('error', () => app.log.error('Database connection lost'));
  app.addHook('onClose', async () => { await pool.end(); });
  process.once('SIGINT', () => { void app.close(); });
  process.once('SIGTERM', () => { void app.close(); });
  // Deliberately not configurable to a public bind with development identity assertions.
  await app.listen({ host: '127.0.0.1', port: config.port });
} catch {
  console.error('API startup failed; check configuration and database setup');
  process.exitCode = 1;
}
