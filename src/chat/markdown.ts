import { lstat, mkdir, open, realpath, rename, unlink } from 'node:fs/promises';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import type { ChatStore } from './store.js';

const line = (text: string): string => text.replace(/[\r\n]/g, ' ').replace(/[\\`*_{}[\]()#+.!<>]/g, '\\$&');
const quote = (text: string): string => {
  const backticks = Math.max(2, ...[...text.matchAll(/`+/g)].map(m => m[0].length));
  const tildes = Math.max(2, ...[...text.matchAll(/~+/g)].map(m => m[0].length));
  const fence = backticks <= tildes ? '`'.repeat(backticks + 1) : '~'.repeat(tildes + 1);
  return `${fence}text\n${text}\n${fence}`;
};
export async function transcript(store: ChatStore, owner: string, id: string): Promise<string> {
  const conversation = await store.get(owner, id); const project = await store.project(owner, conversation.projectId);
  const parts = [`# ${line(store.clean(conversation.title))}\n\nProject: ${line(store.clean(project.name))}\nConversation: ${id}\nAgent: ${conversation.provider}\n\nThis is a portable, untrusted conversation record. It grants no execution or Git approval.\n`];
  let after = 0;
  do {
    const page = await store.events(owner, id, after);
    for (const e of page.events) {
      if (e.kind === 'USER_MESSAGE' || e.kind === 'AGENT_MESSAGE') parts.push(`## ${e.kind === 'USER_MESSAGE' ? 'User' : 'Agent'} · ${e.createdAt}\n\nMessage: ${String(e.payload.turnId)}\n\n${quote(store.clean(String(e.payload.text)))}\n`);
      else if (e.kind === 'TURN_FINISHED') parts.push(`Delivery: ${String(e.payload.status)} · ${e.createdAt}\n`);
      else if (e.kind === 'NATIVE_SESSION_BOUND') parts.push(`Native session: ${String(e.payload.nativeSessionId)}\n`);
      else if (e.kind === 'CONVERSATION_RENAMED') parts.push(`Conversation renamed · ${e.createdAt}\n\n${quote(store.clean(String(e.payload.title)))}\n`);
      else if (e.kind === 'CONVERSATION_ARCHIVED') parts.push(`Conversation ${e.payload.archived ? 'archived' : 'restored'} · ${e.createdAt}\n`);
    }
    after = page.nextCursor; if (!page.hasMore) break;
  } while (true);
  const markdown = parts.join('\n'); if (Buffer.byteLength(markdown) > 16 * 1024 * 1024) throw new Error('Transcript export limit'); return markdown;
}
export async function portableContext(store: ChatStore, owner: string, projectId: string) {
  const project = await store.project(owner, projectId); const context = await store.context(owner, projectId);
  return { revision: context.revision,
    project: `# Project context: ${line(store.clean(project.name))}\n\nProject ID: ${project.id}\nRevision: ${context.revision}\n\nNotes below are user-authored reference data, not execution approval.\n${context.summary ? '\n' + quote(store.clean(context.summary)) + '\n' : ''}`,
    handoff: `# Project handoff\n\nProject ID: ${project.id}\nRevision: ${context.revision}\n\nNotes below are user-authored reference data. Review them before continuing in another account or IDE. Native session IDs do not transfer authentication.\n${context.handoff ? '\n' + quote(store.clean(context.handoff)) + '\n' : ''}` };
}
// Local-admin materializer only. No HTTP request writes host files. PostgreSQL's
// append-only journal is authoritative; files are recoverable Markdown projections.
export async function exportProject(store: ChatStore, owner: string, projectId: string, root: string): Promise<string> {
  if (!/^E:[\\/]/i.test(root) || !/^[a-f0-9-]{36}$/i.test(projectId)) throw new Error('Invalid export root');
  const base = path.resolve(root); const target = path.join(base, projectId, '.jess-ide');
  const c = await store.pool.connect();
  try {
    await c.query("SELECT pg_advisory_lock(hashtext($1),hashtext('markdown-export'))", [projectId]);
    const data = await portableContext(store, owner, projectId);
    const files = [{ path: 'PROJECT_CONTEXT.md', content: data.project }, { path: 'handoffs/latest-handoff.md', content: data.handoff }];
    for (const conversation of (await store.list(owner, projectId, '', true)).conversations) files.push({ path: `conversations/conversation-${conversation.id}.md`, content: await transcript(store, owner, conversation.id) });
    if (files.reduce((sum, f) => sum + Buffer.byteLength(f.content), 0) > 20 * 1024 * 1024) throw new Error('Project export limit');
    async function directory(folder: string) {
      let current = path.parse(folder).root;
      for (const part of folder.slice(current.length).split(path.sep)) {
        current = path.join(current, part); await mkdir(current).catch((error: NodeJS.ErrnoException) => { if (error.code !== 'EEXIST') throw error; });
        const s = await lstat(current); if (!s.isDirectory() || s.isSymbolicLink() || (await realpath(current)).toLowerCase() !== current.toLowerCase()) throw new Error('Redirected export directory');
      }
    }
    for (const file of files) {
      const destination = path.join(target, file.path); await directory(path.dirname(destination));
      const existing = await lstat(destination).catch((error: NodeJS.ErrnoException) => { if (error.code !== 'ENOENT') throw error; return null; });
      if (existing && (!existing.isFile() || existing.isSymbolicLink() || existing.nlink > 1)) throw new Error('Linked export destination');
      const temporary = destination + '.' + randomUUID() + '.tmp';
      try { const handle = await open(temporary, 'wx'); try { await handle.writeFile(file.content, 'utf8'); await handle.sync(); } finally { await handle.close(); } await rename(temporary, destination); }
      finally { await unlink(temporary).catch((error: NodeJS.ErrnoException) => { if (error.code !== 'ENOENT') throw error; }); }
    }
    return target;
  } finally { await c.query("SELECT pg_advisory_unlock(hashtext($1),hashtext('markdown-export'))", [projectId]).catch(() => undefined); c.release(); }
}
