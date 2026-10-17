import { readFile, readdir } from 'node:fs/promises';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createHash } from 'node:crypto';
import type pg from 'pg';
import { createPool } from './pool.js';

// Run from the repository root; the same SQL files serve source and built entry points.
export async function migrate(pool: pg.Pool): Promise<void> {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query("SELECT pg_advisory_xact_lock(hashtext(current_schema()), hashtext('jess-migrations'))");
    await client.query(`CREATE TABLE IF NOT EXISTS schema_migrations (
      name text PRIMARY KEY, checksum text NOT NULL, applied_at timestamptz NOT NULL DEFAULT now()
    )`);
    const directory = resolve('migrations');
    for (const name of (await readdir(directory)).filter(n => /^\d+_.+\.sql$/.test(n)).sort()) {
      const sql = await readFile(resolve(directory, name), 'utf8');
      const checksum = createHash('sha256').update(sql).digest('hex');
      const existing = await client.query<{ checksum: string }>('SELECT checksum FROM schema_migrations WHERE name=$1', [name]);
      if (existing.rows[0]) {
        if (existing.rows[0].checksum !== checksum) throw new Error('Applied migration checksum mismatch');
        continue;
      }
      await client.query(sql);
      await client.query('INSERT INTO schema_migrations(name,checksum) VALUES($1,$2)', [name, checksum]);
    }
    await client.query('COMMIT');
  } catch (error) {
    await client.query('ROLLBACK').catch(() => undefined);
    throw error;
  } finally { client.release(); }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  if (!process.env.DATABASE_URL) {
    console.error('DATABASE_URL is required');
    process.exitCode = 1;
  } else {
    const pool = createPool(process.env.DATABASE_URL);
    try { await migrate(pool); console.log('Migrations applied'); }
    catch { console.error('Migration failed; verify database access and migration history'); process.exitCode = 1; }
    finally { await pool.end(); }
  }
}
