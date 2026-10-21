import { readFile } from 'node:fs/promises';
import { createPool } from '../db/pool.js';
import { loadConfig } from '../config.js';
import { ChatStore } from '../chat/store.js';
import { environmentSecrets } from '../chat/privacy.js';
import { relayLocal } from '../chat/local-relay.js';
import type { LocalMessage } from '../chat/local-relay.js';

// Explicit local action only. Never watches a public queue or forwards browser
// messages to the host account. Stable message IDs are required in the input file.
const [conversationId, messageFile, profileBinding = 'laptop-account-1'] = process.argv.slice(2);
if (!conversationId || !/^[a-f0-9-]{36}$/i.test(conversationId) || !messageFile || !/^E:[\\/]/i.test(messageFile)) throw new Error('Usage: chat-local <conversation UUID> <E: messages.json> [profile binding]');
const config = loadConfig(); const pool = createPool(config.databaseUrl);
try {
  const local = JSON.parse((await readFile('.local/remote-config.json', 'utf8')).replace(/^\uFEFF/, '')) as { owner: string; password: string };
  const raw = await readFile(messageFile, 'utf8'); if (Buffer.byteLength(raw) > 350000) throw new Error('Message batch too large');
  const messages = JSON.parse(raw.replace(/^\uFEFF/, '')) as LocalMessage[];
  if (!Array.isArray(messages) || messages.some(message => typeof message?.id !== 'string' || typeof message?.content !== 'string' || Object.keys(message).some(key => !['id', 'content'].includes(key)))) throw new Error('Invalid message batch');
  const store = new ChatStore(pool, [...environmentSecrets(process.env), local.password]);
  const reports = await relayLocal(store, local.owner, conversationId, messages, { executable: 'E:\\tools\\antigravity-cli\\agy.exe', profile: 'E:\\local-data\\antigravity-home', profileBinding, exportRoot: 'E:\\local-data\\jess\\contexts' });
  console.log(JSON.stringify({ conversationId, reports, markdownRoot: 'E:\\local-data\\jess\\contexts' }));
} catch { console.error('Local chat failed. Check delivery status before retrying; uncertain turns are never automatically resent.'); process.exitCode = 1; }
finally { await pool.end(); }
