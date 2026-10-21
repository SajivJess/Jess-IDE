import type pg from 'pg';
import type { FastifyInstance } from 'fastify';
import { errors, idParams, uuid } from '../api/schemas.js';
import { HttpError } from '../domain.js';

interface HomeRow { id: string; name: string; created_at: Date; last_opened_at: Date | null; activity: Date; conversation_id: string | null; title: string | null; conversation_updated: Date | null; native_session_id: string | null; last_status: string | null; repository_id: string | null; repository_name: string | null; github_url: string | null; branch: string | null }
const source = `SELECT p.id,p.name,p.created_at,p.last_opened_at,
  GREATEST(p.created_at,p.last_opened_at,(SELECT max(updated_at) FROM conversations WHERE project_id=p.id),(SELECT max(updated_at) FROM tasks WHERE project_id=p.id)) AS activity,
  c.id AS conversation_id,c.title,c.updated_at AS conversation_updated,c.native_session_id,c.repository_id,
  (SELECT status FROM conversation_turns WHERE conversation_id=c.id ORDER BY sequence DESC LIMIT 1) AS last_status,
  r.name AS repository_name,r.github_url,r.branch
  FROM projects p LEFT JOIN LATERAL (SELECT c.* FROM conversations c JOIN registered_repositories r ON r.id=c.repository_id
  WHERE c.project_id=p.id AND r.owner_id=$1 AND c.archived_at IS NULL ORDER BY (c.id=p.last_conversation_id) DESC NULLS LAST,c.updated_at DESC,c.id DESC LIMIT 1) c ON true
  LEFT JOIN registered_repositories r ON r.id=c.repository_id AND r.owner_id=$1 WHERE p.owner_id=$1`;
const view = (r: HomeRow) => ({ id: r.id, name: r.name, createdAt: r.created_at.toISOString(), lastOpenedAt: r.last_opened_at?.toISOString() ?? null, lastActivityAt: r.activity.toISOString(),
  repository: r.repository_id ? { id: r.repository_id, name: r.repository_name!, githubUrl: r.github_url!, branch: r.branch! } : null,
  conversation: r.conversation_id ? { id: r.conversation_id, title: r.title!, updatedAt: r.conversation_updated!.toISOString(), hasNativeSession: !!r.native_session_id, lastStatus: r.last_status } : null });
const text = { type: 'string' }, nullable = (schema: object) => ({ anyOf: [schema, { type: 'null' }] });
const object = (properties: Record<string, unknown>, required = Object.keys(properties)) => ({ type: 'object', additionalProperties: false, properties, required });
const project = object({ id: uuid, name: text, createdAt: text, lastOpenedAt: nullable(text), lastActivityAt: text,
  repository: nullable(object({ id: uuid, name: text, githubUrl: text, branch: text })), conversation: nullable(object({ id: uuid, title: text, updatedAt: text, hasNativeSession: { type: 'boolean' }, lastStatus: nullable(text) })) });

export function installHomeRoutes(app: FastifyInstance, pool: pg.Pool): void {
  app.get<{ Querystring: { sort: 'recent' | 'name'; offset: number } }>('/workspace/home', { schema: {
    querystring: object({ sort: { type: 'string', enum: ['recent', 'name'], default: 'recent' }, offset: { type: 'integer', minimum: 0, maximum: 100000, default: 0 } }, []),
    response: { 200: object({ projects: { type: 'array', items: project }, nextOffset: nullable({ type: 'integer' }), total: { type: 'integer' }, recent: nullable(project) }), ...errors },
  } }, async req => {
    const order = req.query.sort === 'name' ? 'lower(p.name),p.id' : 'activity DESC,p.id DESC';
    const [rows, count, recent] = await Promise.all([
      pool.query<HomeRow>(source + ` ORDER BY ${order} LIMIT 51 OFFSET $2`, [req.ownerId, req.query.offset]),
      pool.query<{ count: string }>('SELECT count(*) FROM projects WHERE owner_id=$1', [req.ownerId]),
      pool.query<HomeRow>(source + ' AND (p.last_opened_at IS NOT NULL OR c.id IS NOT NULL) ORDER BY p.last_opened_at DESC NULLS LAST,activity DESC,p.id DESC LIMIT 1', [req.ownerId]),
    ]);
    return { projects: rows.rows.slice(0, 50).map(view), nextOffset: rows.rows.length > 50 ? req.query.offset + 50 : null, total: Number(count.rows[0]!.count), recent: recent.rows[0] ? view(recent.rows[0]) : null };
  });
  app.post<{ Params: { id: string }; Body: { conversationId?: string } }>('/projects/:id/open', { schema: { params: idParams,
    body: object({ conversationId: uuid }, []), response: { 200: object({ projectId: uuid, conversationId: nullable(uuid) }), ...errors },
  } }, async req => {
    const client = await pool.connect();
    try {
      await client.query('BEGIN');
      const owned = await client.query<{ last_conversation_id: string | null }>('SELECT last_conversation_id FROM projects WHERE id=$1 AND owner_id=$2 FOR UPDATE', [req.params.id, req.ownerId]);
      if (!owned.rows[0]) throw new HttpError(404, 'NOT_FOUND');
      const conversation = await client.query<{ id: string }>(`SELECT c.id FROM conversations c JOIN registered_repositories r ON r.id=c.repository_id
        WHERE c.project_id=$1 AND r.owner_id=$2 AND c.archived_at IS NULL AND ($3::uuid IS NULL OR c.id=$3)
        ORDER BY (c.id=$4::uuid) DESC NULLS LAST,c.updated_at DESC,c.id DESC LIMIT 1`, [req.params.id, req.ownerId, req.body.conversationId ?? null, owned.rows[0].last_conversation_id]);
      if (req.body.conversationId && !conversation.rows[0]) throw new HttpError(404, 'NOT_FOUND');
      const id = conversation.rows[0]?.id ?? null;
      await client.query('UPDATE projects SET last_opened_at=now(),last_conversation_id=$2 WHERE id=$1', [req.params.id, id]);
      await client.query('COMMIT'); return { projectId: req.params.id, conversationId: id };
    } catch (error) { await client.query('ROLLBACK'); throw error; } finally { client.release(); }
  });
  app.get<{ Querystring: { q: string } }>('/workspace/search', { schema: { querystring: object({ q: { type: 'string', minLength: 2, maxLength: 100 } }),
    response: { 200: object({ results: { type: 'array', items: object({ kind: text, projectId: uuid, conversationId: nullable(uuid), title: text, detail: text }) } }), ...errors },
  } }, async req => {
    if (req.query.q.trim().length < 2) throw new HttpError(400, 'INVALID_SEARCH');
    const results = await pool.query<{ kind: string; project_id: string; conversation_id: string | null; title: string; detail: string }>(`SELECT * FROM (
      SELECT 'project' AS kind,p.id AS project_id,NULL::uuid AS conversation_id,p.name AS title,
        COALESCE(string_agg(DISTINCT r.github_url,' · '),'Project workspace') AS detail,p.created_at AS activity
        FROM projects p LEFT JOIN conversations c ON c.project_id=p.id LEFT JOIN registered_repositories r ON r.id=c.repository_id AND r.owner_id=$1
        WHERE p.owner_id=$1 GROUP BY p.id HAVING position(lower($2) IN lower(p.name||' '||COALESCE(string_agg(r.name||' '||r.github_url,' '),'')))>0
      UNION ALL SELECT 'conversation',c.project_id,c.id,c.title,p.name,c.updated_at FROM conversations c JOIN projects p ON p.id=c.project_id JOIN registered_repositories r ON r.id=c.repository_id
        WHERE p.owner_id=$1 AND r.owner_id=$1 AND c.archived_at IS NULL AND (position(lower($2) IN lower(c.title))>0 OR EXISTS(SELECT 1 FROM conversation_turns t WHERE t.conversation_id=c.id AND position(lower($2) IN lower(t.prompt||' '||COALESCE(t.response,'')))>0))
      ) matches ORDER BY activity DESC,title,project_id,conversation_id LIMIT 20`, [req.ownerId, req.query.q.trim()]);
    return { results: results.rows.map(r => ({ kind: r.kind, projectId: r.project_id, conversationId: r.conversation_id, title: r.title, detail: r.detail })) };
  });
}
