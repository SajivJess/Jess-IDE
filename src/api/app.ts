import Fastify from 'fastify';
import rateLimit from '@fastify/rate-limit';
import { once } from 'node:events';
import { setTimeout } from 'node:timers/promises';
import pg from 'pg';
import type { Config } from '../config.js';
import { HttpError, terminal } from '../domain.js';
import { Store } from '../db/store.js';
import { installDevAuth } from './auth.js';
import * as s from './schemas.js';

interface Id { id: string }
interface Replay { after: number; limit: number }

function databaseError(error: unknown): boolean {
  if (error instanceof pg.DatabaseError) return true;
  if (!(error instanceof Error)) return false;
  const code = 'code' in error ? String(error.code) : '';
  return ['ECONNREFUSED', 'ECONNRESET', 'EPIPE', 'ETIMEDOUT', 'ENOTFOUND'].includes(code) ||
    /connection terminated|timeout exceeded|connection timeout|query read timeout/i.test(error.message);
}

export function buildApp(config: Config, pool: pg.Pool, logging = true) {
  const app = Fastify({
    logger: logging ? {
      level: 'info',
      redact: ['req.headers.authorization', 'req.headers.cookie', 'req.headers["x-dev-user-id"]'],
      serializers: { req: req => ({ method: req.method, route: req.routeOptions?.url }) },
    } : false,
    bodyLimit: 16384,
    requestTimeout: 10000,
    connectionTimeout: 10000,
    keepAliveTimeout: 5000,
    ajv: { customOptions: { removeAdditional: false } },
  });
  const store = new Store(pool);
  installDevAuth(app, config.devAuthToken);
  app.register(rateLimit, { max: 120, timeWindow: '1 minute', errorResponseBuilder: () => ({ error: 'RATE_LIMITED' }) });
  app.setErrorHandler((error, _request, reply) => {
    if (error instanceof HttpError) return reply.code(error.statusCode).send({ error: error.code });
    if (error instanceof Error && 'validation' in error && error.validation) return reply.code(400).send({ error: 'INVALID_REQUEST' });
    const status = error instanceof Error && 'statusCode' in error ? Number(error.statusCode) : 0;
    if (status === 413) return reply.code(413).send({ error: 'BODY_TOO_LARGE' });
    if (status === 429) return reply.code(429).send({ error: 'RATE_LIMITED' });
    if (status === 400 || status === 415) return reply.code(400).send({ error: 'INVALID_REQUEST' });
    const isDb = databaseError(error);
    app.log.error({ category: isDb ? 'database_unavailable' : 'internal_error' }, 'Request failed');
    return reply.code(isDb ? 503 : 500).send({ error: isDb ? 'SERVICE_UNAVAILABLE' : 'INTERNAL_ERROR' });
  });
  app.setNotFoundHandler((_req, reply) => reply.code(404).send({ error: 'NOT_FOUND' }));
  app.get('/health', {
    schema: { response: { 200: { type: 'object', required: ['status'], properties: { status: { const: 'ok' } }, additionalProperties: false } } },
  }, async () => ({ status: 'ok' }));
  app.get('/ready', {
    schema: { response: { 200: { type: 'object', required: ['status'], properties: { status: { const: 'ready' } }, additionalProperties: false }, ...s.errors } },
  }, async () => { await pool.query('SELECT 1'); return { status: 'ready' }; });
  app.post<{ Body: { name: string } }>('/projects', {
    schema: { body: s.createProjectBody, response: { 201: s.projectSchema, ...s.errors } },
  }, async (req, reply) => reply.code(201).send(await store.createProject(req.ownerId, req.body.name.trim())));
  app.get<{ Params: Id }>('/projects/:id', {
    schema: { params: s.idParams, response: { 200: s.projectSchema, ...s.errors } },
  }, async req => store.getProject(req.ownerId, req.params.id));
  app.post<{ Body: { projectId: string; prompt: string }; Headers: { 'idempotency-key': string } }>('/tasks', {
    schema: { body: s.submitBody, headers: s.submitHeaders, response: {
      202: { type: 'object', required: ['task', 'replayed'], properties: { task: s.taskSchema, replayed: { type: 'boolean' } }, additionalProperties: false },
      ...s.errors,
    } },
  }, async (req, reply) => reply.code(202).send(await store.submit(req.ownerId, req.body.projectId, req.body.prompt, req.headers['idempotency-key'])));
  app.get<{ Params: Id }>('/tasks/:id', {
    schema: { params: s.idParams, response: { 200: s.taskSchema, ...s.errors } },
  }, async req => store.getTask(req.ownerId, req.params.id));
  app.post<{ Params: Id }>('/tasks/:id/cancel', {
    schema: { params: s.idParams, response: { 200: s.taskSchema, ...s.errors } },
  }, async req => store.cancel(req.ownerId, req.params.id));
  app.get<{ Params: Id; Querystring: Replay }>('/tasks/:id/events', {
    schema: { params: s.idParams, querystring: s.replayQuery, response: { 200: s.pageSchema, ...s.errors } },
  }, async req => store.events(req.ownerId, req.params.id, req.query.after, req.query.limit));

  const streams = new Set<AbortController>();
  const owners = new Map<string, number>();
  app.addHook('preClose', async () => { for (const stream of streams) stream.abort(); });
  app.get<{ Params: Id; Querystring: Replay }>('/tasks/:id/events/stream', {
    schema: { params: s.idParams, querystring: s.replayQuery, response: { 200: { type: 'string' }, ...s.errors } },
  }, async (req, reply) => {
    const last = req.headers['last-event-id'];
    if (last !== undefined && (typeof last !== 'string' || !/^\d{1,10}$/.test(last) || Number(last) > 2147483647)) {
      throw new HttpError(400, 'INVALID_CURSOR');
    }
    let cursor = last === undefined ? req.query.after : Number(last);
    let page = await store.events(req.ownerId, req.params.id, cursor, 100);
    if ((owners.get(req.ownerId) ?? 0) >= 3 || streams.size >= 20) throw new HttpError(429, 'TOO_MANY_STREAMS');
    const controller = new AbortController();
    const { signal } = controller;
    streams.add(controller);
    owners.set(req.ownerId, (owners.get(req.ownerId) ?? 0) + 1);
    // Bound stream lifetime; clients reconnect using Last-Event-ID.
    const timeout = globalThis.setTimeout(() => controller.abort(), 30000);
    timeout.unref();
    reply.hijack();
    reply.raw.on('close', () => controller.abort());
    reply.raw.writeHead(200, {
      'content-type': 'text/event-stream', 'cache-control': 'no-store',
      connection: 'keep-alive', 'x-accel-buffering': 'no',
    });
    const write = async (chunk: string): Promise<void> => {
      signal.throwIfAborted();
      if (!reply.raw.write(chunk)) await once(reply.raw, 'drain', { signal });
    };
    try {
      await write('retry: 1000\n\n');
      while (!signal.aborted) {
        for (const event of page.events) {
          await write(`id: ${event.sequence}\nevent: task_event\ndata: ${JSON.stringify(event)}\n\n`);
          cursor = event.sequence;
        }
        if (!page.hasMore && terminal(page.taskStatus)) break;
        if (!page.hasMore) {
          await write(': heartbeat\n\n');
          await setTimeout(500, undefined, { signal });
        }
        page = await store.events(req.ownerId, req.params.id, cursor, 100);
      }
    } catch {
      if (!signal.aborted && !reply.raw.destroyed) reply.raw.write('event: stream_error\ndata: {"error":"STREAM_INTERRUPTED"}\n\n');
    } finally {
      clearTimeout(timeout);
      controller.abort();
      streams.delete(controller);
      const count = (owners.get(req.ownerId) ?? 1) - 1;
      if (count === 0) owners.delete(req.ownerId); else owners.set(req.ownerId, count);
      reply.raw.end();
    }
  });
  return app;
}
