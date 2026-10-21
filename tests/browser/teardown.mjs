import { writeFile, access } from 'node:fs/promises';
import { setTimeout } from 'node:timers/promises';

export default async function teardown() {
  await writeFile('.local/browser-stop', 'stop');
  for (let i = 0; i < 40; i++) {
    try { await access('.local/browser-stopped'); return; } catch { await setTimeout(250); }
  }
  throw new Error('Browser test services did not confirm cleanup of their disposable database schema');
}
