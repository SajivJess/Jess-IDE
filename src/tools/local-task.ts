import { readFile } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import { loadConfig } from '../config.js';
import { AntigravityAgent } from '../agents/antigravity.js';

try {
  const filename = process.argv[2] ?? '';
  if (!/^E:[\\/]/i.test(filename)) throw new Error('An E: drive prompt file is required');
  const prompt = await readFile(filename, 'utf8');
  if (!prompt.trim() || prompt.length > 8000) throw new Error('Prompt must contain 1–8000 characters');
  const config = loadConfig();
  if (!config.antigravity) throw new Error('Antigravity provider configuration required');
  const controller = new AbortController();
  process.once('SIGINT', () => controller.abort());
  process.once('SIGTERM', () => controller.abort());
  const taskId = randomUUID();
  console.log(`Local task ${taskId}; no API, public tunnel, commits or pushes`);
  for await (const update of new AntigravityAgent(config.antigravity).run({ taskId, prompt, attempt: 1, signal: controller.signal })) {
    if (update.type === 'progress') console.log(update.message);
    else console.log(JSON.stringify(update.result, null, 2));
  }
} catch {
  console.error('Local Antigravity task failed. Check CLI authentication, configured paths and permissions. No success is assumed.');
  process.exitCode = 1;
}
