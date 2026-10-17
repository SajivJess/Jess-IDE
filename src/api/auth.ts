import { timingSafeEqual } from 'node:crypto';
import type { FastifyInstance } from 'fastify';
import { HttpError } from '../domain.js';

declare module 'fastify' {
  interface FastifyRequest { ownerId: string }
}

// A local test identity assertion, not a production identity provider.
export function installDevAuth(app: FastifyInstance, token: string): void {
  app.decorateRequest('ownerId', '');
  const expected = Buffer.from(`Bearer ${token}`);
  app.addHook('onRequest', async request => {
    if (request.routeOptions.url === '/health') return;
    const provided = Buffer.from(request.headers.authorization ?? '');
    const owner = request.headers['x-dev-user-id'];
    if (provided.length !== expected.length || !timingSafeEqual(provided, expected) ||
      typeof owner !== 'string' || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(owner)) {
      throw new HttpError(401, 'UNAUTHORIZED');
    }
    request.ownerId = owner.toLowerCase();
  });
}
