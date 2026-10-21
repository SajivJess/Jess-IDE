import { randomUUID } from 'node:crypto';
import type pg from 'pg';
import { createTwoFilesPatch } from 'diff';
import { HttpError } from '../domain.js';
import { MAX_FILES, MAX_SNAPSHOT_BYTES, etag, hash, textContent, workspacePath } from './policy.js';
import type { RepositorySnapshot } from './policy.js';

interface WorkspaceRow { id: string; task_id: string; repository_id: string; revision: number; name: string; github_url: string; branch: string; base_commit: string; created_at: Date }
const view = (row: WorkspaceRow) => ({ id: row.id, taskId: row.task_id, repositoryId: row.repository_id, revision: row.revision, name: row.name,
  githubUrl: row.github_url, branch: row.branch, baseCommit: row.base_commit, createdAt: row.created_at.toISOString(), mode: 'review-only' as const });
const joined = `SELECT w.*,r.name,r.github_url,r.branch,r.base_commit FROM review_workspaces w
  JOIN registered_repositories r ON r.id=w.repository_id JOIN tasks t ON t.id=w.task_id JOIN projects p ON p.id=t.project_id`;

export class WorkspaceStore {
  constructor(private readonly pool: pg.Pool) {}
  private async transaction<T>(fn: (client: pg.PoolClient) => Promise<T>): Promise<T> {
    const c = await this.pool.connect();
    try { await c.query('BEGIN'); await c.query("SET LOCAL lock_timeout='2s'"); const result = await fn(c); await c.query('COMMIT'); return result; }
    catch (error) { await c.query('ROLLBACK'); throw error; } finally { c.release(); }
  }
  // Local-admin import only. There is intentionally no HTTP registration/import endpoint.
  async register(owner: string, snapshot: RepositorySnapshot): Promise<string> {
    if (!/^[0-9a-f-]{36}$/i.test(owner) || !snapshot.name.trim() || snapshot.name.length > 100 ||
      !/^https:\/\/github\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(snapshot.githubUrl) ||
      !/^[A-Za-z0-9][A-Za-z0-9_./-]{0,199}$/.test(snapshot.branch) || snapshot.branch.includes('..') ||
      !/^[a-f0-9]{40,64}$/.test(snapshot.baseCommit) || !/^E:[\\/]/i.test(snapshot.sourceDirectory)) throw new HttpError(400, 'INVALID_REGISTRATION');
    if (!snapshot.files.length || snapshot.files.length > MAX_FILES) throw new HttpError(413, 'SNAPSHOT_TOO_LARGE');
    let bytes = 0; const names = new Set<string>(); const components = new Map<string, string>();
    for (const file of snapshot.files) {
      workspacePath(file.path);
      if (names.has(file.path.toLowerCase())) throw new HttpError(400, 'AMBIGUOUS_PATH');
      names.add(file.path.toLowerCase());
      const parts = file.path.split('/');
      for (let index = 1; index <= parts.length; index++) {
        const component = parts.slice(0, index).join('/'); const key = component.toLowerCase();
        if (components.has(key) && components.get(key) !== component) throw new HttpError(400, 'AMBIGUOUS_PATH');
        components.set(key, component);
      }
      if (!Number.isInteger(file.size) || file.size < 0 || file.size > 2147483647 || (file.content !== null && file.size !== Buffer.byteLength(file.content))) throw new HttpError(400, 'INVALID_FILE');
      if (file.content !== null) { textContent(file.content); bytes += Buffer.byteLength(file.content); if (file.reason !== null) throw new HttpError(400, 'INVALID_FILE'); }
      else if (!['binary', 'too-large', 'link-or-submodule', 'unsupported-text'].includes(file.reason ?? '')) throw new HttpError(400, 'INVALID_FILE');
    }
    for (const name of names) for (const other of names) if (other.startsWith(name + '/')) throw new HttpError(400, 'AMBIGUOUS_PATH');
    if (bytes > MAX_SNAPSHOT_BYTES) throw new HttpError(413, 'SNAPSHOT_TOO_LARGE');
    return this.transaction(async c => {
      await c.query("SELECT pg_advisory_xact_lock(hashtext($1),hashtext('repository-registration'))", [owner]);
      const quota = await c.query<{ count: string }>('SELECT count(*) FROM registered_repositories WHERE owner_id=$1', [owner]);
      if (Number(quota.rows[0]!.count) >= 10) throw new HttpError(409, 'REPOSITORY_LIMIT');
      const id = randomUUID();
      await c.query('INSERT INTO registered_repositories(id,owner_id,name,github_url,branch,base_commit,source_directory) VALUES($1,$2,$3,$4,$5,$6,$7)',
        [id, owner, snapshot.name, snapshot.githubUrl, snapshot.branch, snapshot.baseCommit, snapshot.sourceDirectory]);
      for (const f of snapshot.files) await c.query('INSERT INTO repository_files(repository_id,path,content,reason,size) VALUES($1,$2,$3,$4,$5)', [id, f.path, f.content, f.reason, f.size]);
      return id;
    });
  }
  async repositories(owner: string) {
    const r = await this.pool.query<{ id: string; name: string; github_url: string; branch: string; base_commit: string }>('SELECT id,name,github_url,branch,base_commit FROM registered_repositories WHERE owner_id=$1 ORDER BY created_at DESC,id DESC LIMIT 50', [owner]);
    return { repositories: r.rows.map(row => ({ id: row.id, name: row.name, githubUrl: row.github_url, branch: row.branch, baseCommit: row.base_commit })) };
  }
  async list(owner: string) {
    const r = await this.pool.query<WorkspaceRow>(joined + ' WHERE p.owner_id=$1 AND r.owner_id=$1 ORDER BY w.created_at DESC,w.id DESC LIMIT 50', [owner]);
    return { workspaces: r.rows.map(view) };
  }
  async get(owner: string, id: string) {
    const r = await this.pool.query<WorkspaceRow>(joined + ' WHERE w.id=$2 AND p.owner_id=$1 AND r.owner_id=$1', [owner, id]);
    if (!r.rows[0]) throw new HttpError(404, 'NOT_FOUND');
    return view(r.rows[0]);
  }
  async create(owner: string, taskId: string, repositoryId: string) {
    const id = await this.transaction(async c => {
      await c.query("SELECT pg_advisory_xact_lock(hashtext($1),hashtext('review-workspaces'))", [owner]);
      const task = await c.query<{ status: string }>('SELECT t.status FROM tasks t JOIN projects p ON p.id=t.project_id WHERE t.id=$1 AND p.owner_id=$2 FOR UPDATE OF t', [taskId, owner]);
      const repository = await c.query('SELECT id FROM registered_repositories WHERE id=$1 AND owner_id=$2', [repositoryId, owner]);
      if (!task.rowCount || !repository.rowCount) throw new HttpError(404, 'NOT_FOUND');
      if (!['COMPLETED', 'FAILED', 'CANCELLED'].includes(task.rows[0]!.status)) throw new HttpError(409, 'TASK_NOT_FINISHED');
      const prior = await c.query<{ id: string; repository_id: string }>('SELECT id,repository_id FROM review_workspaces WHERE task_id=$1', [taskId]);
      if (prior.rows[0]) {
        if (prior.rows[0].repository_id !== repositoryId) throw new HttpError(409, 'WORKSPACE_EXISTS');
        return prior.rows[0].id;
      }
      const quota = await c.query<{ count: string }>('SELECT count(*) FROM review_workspaces w JOIN registered_repositories r ON r.id=w.repository_id WHERE r.owner_id=$1', [owner]);
      if (Number(quota.rows[0]!.count) >= 50) throw new HttpError(409, 'WORKSPACE_LIMIT');
      const workspace = randomUUID();
      await c.query('INSERT INTO review_workspaces(id,task_id,repository_id) VALUES($1,$2,$3)', [workspace, taskId, repositoryId]);
      await c.query('INSERT INTO workspace_files(workspace_id,path,content) SELECT $1,path,content FROM repository_files WHERE repository_id=$2', [workspace, repositoryId]);
      return workspace;
    });
    return this.get(owner, id);
  }
  async files(owner: string, id: string, path: string, offset: number) {
    await this.get(owner, id); workspacePath(path, true);
    const r = await this.pool.query<{ path: string; content: string | null; reason: string | null; size: number }>(`SELECT f.path,CASE WHEN f.content IS NULL THEN NULL ELSE '' END AS content,b.reason,
      COALESCE(octet_length(f.content),b.size) AS size FROM workspace_files f JOIN review_workspaces w ON w.id=f.workspace_id
      JOIN repository_files b ON b.repository_id=w.repository_id AND b.path=f.path WHERE f.workspace_id=$1 ORDER BY f.path`, [id]);
    const prefix = path ? path + '/' : '';
    const entries = new Map<string, { name: string; path: string; kind: string; size: number; reason: string | null }>();
    for (const file of r.rows) {
      if (!file.path.startsWith(prefix)) continue;
      const rest = file.path.slice(prefix.length); const name = rest.split('/')[0]!;
      if (rest.includes('/')) entries.set(name, { name, path: prefix + name, kind: 'directory', size: 0, reason: null });
      else entries.set(name, { name, path: file.path, kind: file.content === null ? 'unavailable' : 'text', size: file.size, reason: file.reason });
    }
    const all = [...entries.values()].sort((a, b) => a.name.localeCompare(b.name));
    return { entries: all.slice(offset, offset + 100), nextOffset: offset + 100 < all.length ? offset + 100 : null };
  }
  async read(owner: string, id: string, path: string) {
    await this.get(owner, id); workspacePath(path);
    const r = await this.pool.query<{ content: string | null; version: number }>('SELECT content,version FROM workspace_files WHERE workspace_id=$1 AND path=$2', [id, path]);
    const file = r.rows[0]; if (!file) throw new HttpError(404, 'NOT_FOUND');
    if (file.content === null) throw new HttpError(415, 'UNSUPPORTED_FILE');
    return { path, content: file.content, etag: etag(file.version, file.content), version: file.version, size: Buffer.byteLength(file.content) };
  }
  async write(owner: string, id: string, path: string, content: string, match: string | undefined) {
    await this.get(owner, id); workspacePath(path); textContent(content);
    if (!match) throw new HttpError(428, 'REVISION_REQUIRED');
    return this.transaction(async c => {
      const workspace = await c.query<{ revision: number }>('SELECT revision FROM review_workspaces WHERE id=$1 FOR UPDATE', [id]);
      if (workspace.rows[0]!.revision >= 1000) throw new HttpError(409, 'EDIT_LIMIT');
      const r = await c.query<{ content: string | null; version: number }>('SELECT content,version FROM workspace_files WHERE workspace_id=$1 AND path=$2 FOR UPDATE', [id, path]);
      const file = r.rows[0]; if (!file) throw new HttpError(404, 'NOT_FOUND');
      if (file.content === null) throw new HttpError(415, 'UNSUPPORTED_FILE');
      if (etag(file.version, file.content) !== match) throw new HttpError(409, 'FILE_CHANGED');
      const total = await c.query<{ size: string }>('SELECT COALESCE(sum(octet_length(content)),0) AS size FROM workspace_files WHERE workspace_id=$1', [id]);
      if (Number(total.rows[0]!.size) - Buffer.byteLength(file.content) + Buffer.byteLength(content) > MAX_SNAPSHOT_BYTES) throw new HttpError(413, 'SNAPSHOT_TOO_LARGE');
      const revision = workspace.rows[0]!.revision + 1; const version = file.version + 1;
      await c.query('UPDATE workspace_files SET content=$3,version=$4 WHERE workspace_id=$1 AND path=$2', [id, path, content, version]);
      await c.query('UPDATE review_workspaces SET revision=$2 WHERE id=$1', [id, revision]);
      await c.query('INSERT INTO workspace_edits(workspace_id,revision,owner_id,path,before_hash,after_hash) VALUES($1,$2,$3,$4,$5,$6)', [id, revision, owner, path, hash(file.content), hash(content)]);
      return { path, content, etag: etag(version, content), version, size: Buffer.byteLength(content), revision };
    });
  }
  async diff(owner: string, id: string, path: string) {
    const workspace = await this.get(owner, id); workspacePath(path);
    const r = await this.pool.query<{ base: string | null; content: string | null; version: number }>(`SELECT b.content AS base,f.content,f.version FROM workspace_files f
      JOIN repository_files b ON b.repository_id=$3 AND b.path=f.path WHERE f.workspace_id=$1 AND f.path=$2`, [id, path, workspace.repositoryId]);
    const file = r.rows[0]; if (!file) throw new HttpError(404, 'NOT_FOUND');
    if (file.base === null || file.content === null) throw new HttpError(415, 'UNSUPPORTED_FILE');
    // Bound both CPU and output; pathological inputs produce an honest unavailable diff.
    const patch = createTwoFilesPatch(`a/${path}`, `b/${path}`, file.base, file.content, '', '', { context: 3, timeout: 100, maxEditLength: 4000 });
    return { path, branch: workspace.branch, baseCommit: workspace.baseCommit, etag: etag(file.version, file.content),
      diff: (patch ?? '').slice(0, 200000), truncated: patch === undefined || patch.length > 200000, changed: file.base !== file.content, approvalAvailable: false };
  }
}
