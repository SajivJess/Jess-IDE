import { readFile } from 'node:fs/promises';
import { createPool } from '../db/pool.js';
import { loadConfig } from '../config.js';
import { importRepository } from '../workspaces/import.js';
import type { ImportConfig } from '../workspaces/import.js';
import { WorkspaceStore } from '../workspaces/store.js';

// Explicit local configuration only; never invoked from HTTP or by an agent.
const [configuration, owner] = process.argv.slice(2);
if (!configuration || !/^E:[\\/]/i.test(configuration) || !owner || !/^[a-f0-9-]{36}$/i.test(owner)) throw new Error('Usage: register-repository <E: configuration.json> <owner UUID>');
const config = loadConfig();
const pool = createPool(config.databaseUrl);
try {
  const registration = JSON.parse((await readFile(configuration, 'utf8')).replace(/^\uFEFF/, '')) as ImportConfig;
  const snapshot = await importRepository(registration);
  const id = await new WorkspaceStore(pool).register(owner, snapshot);
  console.log(JSON.stringify({ repositoryId: id, name: snapshot.name, branch: snapshot.branch, baseCommit: snapshot.baseCommit, files: snapshot.files.length, mode: 'review-only' }));
} catch { console.error('Repository registration failed. Check the local configuration, repository policy and database migrations.'); process.exitCode = 1; }
finally { await pool.end(); }
