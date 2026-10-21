import { lstat, mkdir, open, readFile, realpath, unlink, writeFile } from 'node:fs/promises';
import path from 'node:path';
import type { ChatStore } from './store.js';
import { CliSession } from './cli-session.js';
import type { CliResult, CliProgress, CliSessionOptions } from './cli-session.js';
import { exportProject } from './markdown.js';

export interface LocalRelayOptions { executable: string; profile: string; profileBinding: string; exportRoot: string; timeoutMs?: number }
export interface LocalMessage { id: string; content: string }
export interface SessionTransport { turn(prompt: string): Promise<CliResult>; close(): Promise<void> }
export type SessionFactory = (options: CliSessionOptions, bind: (id: string) => Promise<void>, progress: (step: CliProgress) => Promise<void>) => SessionTransport;

async function permittedDirectory(value: string): Promise<string> {
  const absolute = path.resolve(value); if (!/^E:\\/i.test(absolute)) throw new Error('An E-drive directory is required');
  let current = path.parse(absolute).root;
  for (const part of absolute.slice(current.length).split(path.sep)) {
    current = path.join(current, part); const info = await lstat(current);
    if (!info.isDirectory() || info.isSymbolicLink() || (await realpath(current)).toLowerCase() !== current.toLowerCase()) throw new Error('Redirected local directory');
  }
  return absolute;
}
export async function relayLocal(store: ChatStore, owner: string, id: string, messages: LocalMessage[], options: LocalRelayOptions,
  factory: SessionFactory = (config, bind, progress) => new CliSession(config, bind, progress)) {
  if (!messages.length || messages.length > 20 || !/^[a-zA-Z0-9_-]{1,100}$/.test(options.profileBinding) || !/^E:[\\/]/i.test(options.executable)) throw new Error('Invalid local relay configuration');
  const conversation = await store.get(owner, id);
  const workspace = await permittedDirectory(await store.workspace(owner, id));
  const profile = await permittedDirectory(options.profile);
  const mutex = await store.pool.connect(); let locked = false, fileLocked = false, session: SessionTransport | undefined, turnId: string | undefined;
  const lockPath = path.join(profile, '.jess-cli.lock'); const settingsPath = path.join(profile, '.gemini', 'antigravity-cli', 'settings.json');
  let originalSettings: Buffer | undefined; let settingsChanged = false;
  const reports: { messageId: string; status: string; replayed: boolean }[] = [];
  try {
    const result = await mutex.query<{ locked: boolean }>("SELECT pg_try_advisory_lock(hashtext($1),hashtext('native-chat')) AS locked", [id]);
    locked = result.rows[0]!.locked; if (!locked) throw new Error('Conversation already has a local runner');
    const handle = await open(lockPath, 'wx'); await handle.close(); fileLocked = true;
    await store.recoverInterrupted(owner, id); // Never resend an uncertain native turn.
    const env: NodeJS.ProcessEnv = { SystemRoot: process.env.SystemRoot ?? 'C:\\Windows', WINDIR: process.env.WINDIR ?? 'C:\\Windows',
      PATH: 'E:\\tools\\node-v24.22.0-win-x64;E:\\tools\\git\\cmd;C:\\Windows\\System32', USERPROFILE: profile, APPDATA: path.join(profile, 'appdata'), LOCALAPPDATA: path.join(profile, 'localappdata'),
      TEMP: path.join(profile, 'tmp'), TMP: path.join(profile, 'tmp'), NO_COLOR: '1', GIT_TERMINAL_PROMPT: '0', GIT_CONFIG_GLOBAL: 'NUL', GIT_CONFIG_NOSYSTEM: '1' };
    for (const folder of [env.APPDATA!, env.LOCALAPPDATA!, env.TEMP!]) { await mkdir(folder, { recursive: true }); await permittedDirectory(folder); }
    await permittedDirectory(path.dirname(settingsPath));
    const info = await lstat(settingsPath); if (!info.isFile() || info.isSymbolicLink() || info.nlink > 1) throw new Error('Unsafe profile settings');
    originalSettings = await readFile(settingsPath);
    const settings = JSON.parse(originalSettings.toString('utf8')) as Record<string, unknown>;
    await writeFile(settingsPath, JSON.stringify({ ...settings, toolPermission: 'request-review', permissions: { allow: ['read_file(.)'], deny: ['command(*)', 'unsandboxed(*)', 'mcp(*)', 'read_url(*)', 'execute_url(*)', 'write_file(*)', 'read_file(.git/)', 'read_file(.env*)', 'read_file(node_modules/)', 'read_file(.local/)', 'read_file(.gemini/)'] } })); settingsChanged = true;
    for (const message of messages) {
      const delivery = await store.begin(owner, id, message.id, message.content, options.profileBinding);
      reports.push({ messageId: message.id, status: delivery.status, replayed: delivery.replayed });
      if (delivery.replayed) { if (delivery.status !== 'COMPLETED') throw new Error('Previous delivery is unresolved or failed; use a new reviewed message or conversation'); continue; }
      turnId = delivery.turnId;
      // Journaled before stdin write: a crash can lose an answer, never silently
      // cause the same instruction to be dispatched again on retry.
      await exportProject(store, owner, conversation.projectId, options.exportRoot);
      session ??= factory({ executable: options.executable, cwd: workspace, env, ...(conversation.nativeSessionId ? { sessionId: conversation.nativeSessionId } : {}), ...(options.timeoutMs ? { timeoutMs: options.timeoutMs } : {}) }, nativeId => store.bind(owner, id, nativeId), step => store.step(owner, id, turnId!, step));
      const result = await session.turn(delivery.input);
      await store.bind(owner, id, result.conversationId);
      const success = result.status === 'SUCCESS' && !result.denied;
      await store.finish(owner, id, turnId, success ? 'COMPLETED' : 'FAILED', result.response);
      turnId = undefined; reports.at(-1)!.status = success ? 'COMPLETED' : 'FAILED';
      await exportProject(store, owner, conversation.projectId, options.exportRoot);
      if (!success) throw new Error('CLI turn failed; actual returned text was recorded');
    }
    return reports;
  } catch (error) {
    if (turnId) await store.finish(owner, id, turnId, 'UNCERTAIN').catch(() => undefined);
    await exportProject(store, owner, conversation.projectId, options.exportRoot).catch(() => undefined);
    throw error;
  } finally {
    try { await session?.close(); }
    finally {
      try { if (settingsChanged && originalSettings) await writeFile(settingsPath, originalSettings); }
      finally {
        try { if (fileLocked) await unlink(lockPath); }
        finally { try { if (locked) await mutex.query("SELECT pg_advisory_unlock(hashtext($1),hashtext('native-chat'))", [id]); } finally { mutex.release(); } }
      }
    }
  }
}
