import { randomUUID } from 'node:crypto';
import type pg from 'pg';
import { HttpError, LeaseLost } from '../domain.js';
import type { AgentResult, EventType, Project, Task, TaskEvent, TaskStatus } from '../domain.js';

interface TaskRow {
  id: string; project_id: string; prompt: string; status: TaskStatus; attempts: number;
  max_attempts: number; cancel_requested: boolean; result: AgentResult | null;
  error: string | null; created_at: Date; updated_at: Date; event_sequence: number;
  lease_token: string | null; lease_expires_at: Date | null;
}
interface ProjectRow { id: string; name: string; created_at: Date }

function task(row: TaskRow): Task {
  return {
    id: row.id, projectId: row.project_id, prompt: row.prompt, status: row.status,
    attempt: row.attempts, maxAttempts: row.max_attempts, cancelRequested: row.cancel_requested,
    result: row.result, error: row.error, createdAt: row.created_at.toISOString(), updatedAt: row.updated_at.toISOString(),
  };
}
function project(row: ProjectRow): Project {
  return { id: row.id, name: row.name, createdAt: row.created_at.toISOString() };
}

export interface Claim { task: Task; leaseToken: string }

export class Store {
  constructor(public readonly pool: pg.Pool) {}

  private async transaction<T>(fn: (client: pg.PoolClient) => Promise<T>): Promise<T> {
    const c = await this.pool.connect();
    try {
      await c.query('BEGIN');
      await c.query("SET LOCAL lock_timeout = '2s'");
      const result = await fn(c);
      await c.query('COMMIT');
      return result;
    } catch (error) {
      await c.query('ROLLBACK').catch(() => undefined);
      throw error;
    } finally { c.release(); }
  }

  // Call only while holding this task's row lock. Sequence allocation and insertion commit together.
  private async event(c: pg.PoolClient, id: string, type: EventType, payload: Record<string, unknown> = {}): Promise<void> {
    const r = await c.query<{ event_sequence: number }>(
      'UPDATE tasks SET event_sequence=event_sequence+1, updated_at=now() WHERE id=$1 RETURNING event_sequence', [id]);
    await c.query('INSERT INTO task_events(task_id,sequence,type,payload) VALUES($1,$2,$3,$4)',
      [id, r.rows[0]!.event_sequence, type, JSON.stringify(payload)]);
  }

  async createProject(owner: string, name: string): Promise<Project> {
    const r = await this.pool.query<ProjectRow>(
      'INSERT INTO projects(id,owner_id,name) VALUES($1,$2,$3) RETURNING *', [randomUUID(), owner, name]);
    return project(r.rows[0]!);
  }

  async getProject(owner: string, id: string): Promise<Project> {
    const r = await this.pool.query<ProjectRow>('SELECT * FROM projects WHERE id=$1 AND owner_id=$2', [id, owner]);
    if (!r.rows[0]) throw new HttpError(404, 'NOT_FOUND');
    return project(r.rows[0]);
  }

  async listProjects(owner: string, limit: number, before?: string): Promise<{ projects: Project[]; nextCursor: string | null }> {
    if (before) await this.getProject(owner, before);
    const r = await this.pool.query<ProjectRow>(`SELECT * FROM projects WHERE owner_id=$1
      AND ($3::uuid IS NULL OR (created_at,id)<(SELECT created_at,id FROM projects WHERE id=$3 AND owner_id=$1))
      ORDER BY created_at DESC,id DESC LIMIT $2`, [owner, limit + 1, before ?? null]);
    const rows = r.rows.slice(0, limit);
    return { projects: rows.map(project), nextCursor: r.rows.length > limit ? rows.at(-1)!.id : null };
  }

  async listTasks(owner: string, limit: number, before?: string): Promise<{ tasks: Task[]; nextCursor: string | null }> {
    if (before) await this.getTask(owner, before);
    const r = await this.pool.query<TaskRow>(`SELECT t.* FROM tasks t JOIN projects p ON p.id=t.project_id
      WHERE p.owner_id=$1 AND ($3::uuid IS NULL OR (t.created_at,t.id)<(SELECT created_at,id FROM tasks WHERE id=$3))
      ORDER BY t.created_at DESC,t.id DESC LIMIT $2`, [owner, limit + 1, before ?? null]);
    const rows = r.rows.slice(0, limit);
    return { tasks: rows.map(task), nextCursor: r.rows.length > limit ? rows.at(-1)!.id : null };
  }

  async submit(owner: string, projectId: string, prompt: string, key: string): Promise<{ task: Task; replayed: boolean }> {
    return this.transaction(async c => {
      const p = await c.query('SELECT id FROM projects WHERE id=$1 AND owner_id=$2', [projectId, owner]);
      if (!p.rowCount) throw new HttpError(404, 'NOT_FOUND');
      const r = await c.query<TaskRow>(`INSERT INTO tasks(id,project_id,prompt,idempotency_key)
        VALUES($1,$2,$3,$4) ON CONFLICT(project_id,idempotency_key) DO NOTHING RETURNING *`,
      [randomUUID(), projectId, prompt, key]);
      if (r.rows[0]) {
        await this.event(c, r.rows[0].id, 'TASK_QUEUED');
        return { task: task(r.rows[0]), replayed: false };
      }
      const old = await c.query<TaskRow>('SELECT * FROM tasks WHERE project_id=$1 AND idempotency_key=$2', [projectId, key]);
      const row = old.rows[0]!;
      if (row.prompt !== prompt) throw new HttpError(409, 'IDEMPOTENCY_CONFLICT');
      return { task: task(row), replayed: true };
    });
  }

  async getTask(owner: string, id: string): Promise<Task> {
    const r = await this.pool.query<TaskRow>(`SELECT t.* FROM tasks t JOIN projects p ON p.id=t.project_id
      WHERE t.id=$1 AND p.owner_id=$2`, [id, owner]);
    if (!r.rows[0]) throw new HttpError(404, 'NOT_FOUND');
    return task(r.rows[0]);
  }

  async cancel(owner: string, id: string): Promise<Task> {
    return this.transaction(async c => {
      const r = await c.query<TaskRow>(`SELECT t.* FROM tasks t JOIN projects p ON p.id=t.project_id
        WHERE t.id=$1 AND p.owner_id=$2 FOR UPDATE OF t`, [id, owner]);
      const row = r.rows[0];
      if (!row) throw new HttpError(404, 'NOT_FOUND');
      if (row.status === 'QUEUED') {
        await c.query("UPDATE tasks SET status='CANCELLED', cancel_requested=true WHERE id=$1", [id]);
        await this.event(c, id, 'TASK_CANCELLED');
      } else if (row.status === 'RUNNING' && !row.cancel_requested) {
        await c.query('UPDATE tasks SET cancel_requested=true WHERE id=$1', [id]);
        await this.event(c, id, 'CANCEL_REQUESTED');
      }
      const updated = await c.query<TaskRow>('SELECT * FROM tasks WHERE id=$1', [id]);
      return task(updated.rows[0]!);
    });
  }

  async events(owner: string, id: string, after: number, limit: number): Promise<{
    events: TaskEvent[]; nextCursor: number; hasMore: boolean; taskStatus: TaskStatus;
  }> {
    // One statement/snapshot guarantees metadata and event page describe the same committed state.
    const r = await this.pool.query<{
      status: TaskStatus; event_sequence: number; events: TaskEvent[];
    }>(`SELECT t.status,t.event_sequence,COALESCE((SELECT jsonb_agg(e.item ORDER BY e.seq) FROM (
      SELECT sequence AS seq,jsonb_build_object('version',1,'taskId',task_id,'sequence',sequence,
        'type',type,'timestamp',created_at,'payload',payload) AS item
      FROM task_events WHERE task_id=t.id AND sequence>$3 ORDER BY sequence LIMIT $4
    ) e),'[]'::jsonb) AS events FROM tasks t JOIN projects p ON p.id=t.project_id
      WHERE t.id=$1 AND p.owner_id=$2`, [id, owner, after, limit]);
    const row = r.rows[0];
    if (!row) throw new HttpError(404, 'NOT_FOUND');
    if (after > row.event_sequence) throw new HttpError(400, 'INVALID_CURSOR');
    const nextCursor = row.events.at(-1)?.sequence ?? after;
    return { events: row.events, nextCursor, hasMore: nextCursor < row.event_sequence, taskStatus: row.status };
  }

  async claim(leaseMs: number): Promise<Claim | 'reconciled' | null> {
    return this.transaction(async c => {
      const r = await c.query<TaskRow>(`SELECT * FROM tasks
        WHERE status='QUEUED' OR (status='RUNNING' AND lease_expires_at<=now())
        ORDER BY created_at,id FOR UPDATE SKIP LOCKED LIMIT 1`);
      const row = r.rows[0];
      if (!row) return null;
      if (row.cancel_requested || row.attempts >= row.max_attempts) {
        const status = row.cancel_requested ? 'CANCELLED' : 'FAILED';
        await c.query(`UPDATE tasks SET status=$2,lease_token=NULL,lease_expires_at=NULL,error=$3 WHERE id=$1`,
          [row.id, status, status === 'FAILED' ? 'RETRY_LIMIT_EXCEEDED' : null]);
        await this.event(c, row.id, status === 'CANCELLED' ? 'TASK_CANCELLED' : 'TASK_FAILED',
          status === 'FAILED' ? { code: 'RETRY_LIMIT_EXCEEDED' } : {});
        return 'reconciled';
      }
      const token = randomUUID();
      const updated = await c.query<TaskRow>(`UPDATE tasks SET status='RUNNING',attempts=attempts+1,
        lease_token=$2,lease_expires_at=now()+($3 * interval '1 millisecond') WHERE id=$1 RETURNING *`, [row.id, token, leaseMs]);
      if (row.status === 'RUNNING') await this.event(c, row.id, 'TASK_RETRYING', { previousAttempt: row.attempts });
      await this.event(c, row.id, 'TASK_STARTED', { attempt: updated.rows[0]!.attempts });
      return { task: task(updated.rows[0]!), leaseToken: token };
    });
  }

  private async lockedClaim(c: pg.PoolClient, claim: Claim): Promise<TaskRow> {
    const r = await c.query<TaskRow>(`SELECT * FROM tasks WHERE id=$1 AND status='RUNNING'
      AND lease_token=$2 AND lease_expires_at>now() FOR UPDATE`, [claim.task.id, claim.leaseToken]);
    if (!r.rows[0]) throw new LeaseLost();
    return r.rows[0];
  }

  async renew(claim: Claim, leaseMs: number): Promise<boolean> {
    return this.transaction(async c => {
      const row = await this.lockedClaim(c, claim);
      await c.query("UPDATE tasks SET lease_expires_at=now()+($2 * interval '1 millisecond') WHERE id=$1", [row.id, leaseMs]);
      return row.cancel_requested;
    });
  }

  async progress(claim: Claim, payload: Record<string, unknown>): Promise<boolean> {
    return this.transaction(async c => {
      const row = await this.lockedClaim(c, claim);
      if (!row.cancel_requested) await this.event(c, row.id, 'AGENT_PROGRESS', { ...payload, attempt: row.attempts });
      return row.cancel_requested;
    });
  }

  async finish(claim: Claim, result: AgentResult | null, failed = false): Promise<void> {
    await this.transaction(async c => {
      const row = await this.lockedClaim(c, claim);
      const status = row.cancel_requested ? 'CANCELLED' : failed ? 'FAILED' : 'COMPLETED';
      await c.query(`UPDATE tasks SET status=$2,result=$3,error=$4,lease_token=NULL,lease_expires_at=NULL WHERE id=$1`,
        [row.id, status, status === 'COMPLETED' ? JSON.stringify(result) : null, status === 'FAILED' ? 'AGENT_EXECUTION_FAILED' : null]);
      const eventType = status === 'COMPLETED' ? 'TASK_COMPLETED' : status === 'FAILED' ? 'TASK_FAILED' : 'TASK_CANCELLED';
      await this.event(c, row.id, eventType, status === 'COMPLETED' ? { simulated: result?.simulated ?? false } : {});
    });
  }

  async abandon(claim: Claim): Promise<void> {
    await this.pool.query(`UPDATE tasks SET lease_expires_at=now() WHERE id=$1 AND status='RUNNING' AND lease_token=$2`,
      [claim.task.id, claim.leaseToken]);
  }
}
