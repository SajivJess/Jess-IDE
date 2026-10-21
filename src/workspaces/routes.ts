import type { FastifyInstance } from 'fastify';
import type pg from 'pg';
import { WorkspaceStore } from './store.js';
import { errors, idParams, uuid } from '../api/schemas.js';

const text = { type: 'string' };
const object = (properties: Record<string, unknown>, required = Object.keys(properties)) => ({ type: 'object', additionalProperties: false, properties, required });
const ws = object({ id: uuid, taskId: uuid, repositoryId: uuid, revision: { type: 'integer' }, name: text, githubUrl: text, branch: text, baseCommit: text, createdAt: text, mode: { const: 'review-only' } });
const fileQuery = object({ path: { type: 'string', minLength: 1, maxLength: 300 } });
const file = object({ path: text, content: text, etag: text, version: { type: 'integer' }, size: { type: 'integer' } });
const fileErrors = { ...errors, 403: errors[400], 415: errors[400], 428: errors[400] };
interface Id { id: string }

export function installWorkspaceRoutes(app: FastifyInstance, pool: pg.Pool): void {
  const store = new WorkspaceStore(pool);
  app.get('/repositories', { schema: { response: { 200: object({ repositories: { type: 'array', items: object({ id: uuid, name: text, githubUrl: text, branch: text, baseCommit: text }) } }), ...errors } } }, async req => store.repositories(req.ownerId));
  app.get('/workspaces', { schema: { response: { 200: object({ workspaces: { type: 'array', items: ws } }), ...errors } } }, async req => store.list(req.ownerId));
  app.post<{ Params: Id; Body: { repositoryId: string } }>('/tasks/:id/workspace', {
    schema: { params: idParams, body: object({ repositoryId: uuid }), response: { 200: ws, ...fileErrors } },
  }, async req => store.create(req.ownerId, req.params.id, req.body.repositoryId));
  app.get<{ Params: Id }>('/workspaces/:id', { schema: { params: idParams, response: { 200: ws, ...errors } } }, async req => store.get(req.ownerId, req.params.id));
  app.get<{ Params: Id; Querystring: { path: string; offset: number } }>('/workspaces/:id/files', {
    schema: { params: idParams, querystring: object({ path: { type: 'string', maxLength: 300, default: '' }, offset: { type: 'integer', minimum: 0, maximum: 500, default: 0 } }, []),
      response: { 200: object({ entries: { type: 'array', items: object({ name: text, path: text, kind: { enum: ['directory', 'text', 'unavailable'] }, size: { type: 'integer' }, reason: { anyOf: [text, { type: 'null' }] } }) }, nextOffset: { anyOf: [{ type: 'integer' }, { type: 'null' }] } }), ...fileErrors } },
  }, async req => store.files(req.ownerId, req.params.id, req.query.path, req.query.offset));
  app.get<{ Params: Id; Querystring: { path: string } }>('/workspaces/:id/file', {
    schema: { params: idParams, querystring: fileQuery, response: { 200: file, ...fileErrors } },
  }, async req => store.read(req.ownerId, req.params.id, req.query.path));
  app.put<{ Params: Id; Body: { path: string; content: string }; Headers: { 'if-match'?: string } }>('/workspaces/:id/file', {
    bodyLimit: 400000,
    schema: { params: idParams, body: object({ path: { type: 'string', minLength: 1, maxLength: 300 }, content: { type: 'string', maxLength: 65536 } }),
      headers: { type: 'object', properties: { 'if-match': { type: 'string', maxLength: 100 } } }, response: { 200: { ...file, properties: { ...file.properties, revision: { type: 'integer' } } }, ...fileErrors } },
  }, async req => store.write(req.ownerId, req.params.id, req.body.path, req.body.content, req.headers['if-match']));
  app.get<{ Params: Id; Querystring: { path: string } }>('/workspaces/:id/diff', {
    schema: { params: idParams, querystring: fileQuery, response: { 200: object({ path: text, branch: text, baseCommit: text, etag: text, diff: text, truncated: { type: 'boolean' }, changed: { type: 'boolean' }, approvalAvailable: { const: false } }), ...fileErrors } },
  }, async req => store.diff(req.ownerId, req.params.id, req.query.path));
}
