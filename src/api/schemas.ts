export const uuid = { type: 'string', format: 'uuid' } as const;
const date = { type: 'string', format: 'date-time' } as const;
const text = { type: 'string' } as const;
const object = (properties: Record<string, unknown>, required = Object.keys(properties)) =>
  ({ type: 'object', properties, required, additionalProperties: false });

export const errorSchema = object({ error: text });
export const errors = Object.fromEntries([400, 401, 404, 409, 413, 429, 500, 503].map(n => [n, errorSchema]));
export const idParams = object({ id: uuid });
export const projectSchema = object({ id: uuid, name: text, createdAt: date });
export const resultSchema = object({
  summary: text, simulated: { type: 'boolean' },
  files: { type: 'array', items: object({ path: text, change: { enum: ['added', 'modified', 'deleted'] } }) },
  checks: { type: 'array', items: object({ name: text, status: { enum: ['simulated', 'passed', 'failed', 'skipped'] } }) },
  execution: object({ branch: text, baseCommit: text, diff: text, truncated: { type: 'boolean' } }),
});
// Existing simulated results do not contain workspace execution metadata.
resultSchema.required = ['summary', 'simulated', 'files', 'checks'];
export const statusSchema = { enum: ['QUEUED', 'RUNNING', 'COMPLETED', 'FAILED', 'CANCELLED'] };
export const taskSchema = object({
  id: uuid, projectId: uuid, prompt: text, status: statusSchema,
  attempt: { type: 'integer' }, maxAttempts: { type: 'integer' }, cancelRequested: { type: 'boolean' },
  result: { anyOf: [resultSchema, { type: 'null' }] },
  error: { anyOf: [text, { type: 'null' }] }, createdAt: date, updatedAt: date,
});
export const listQuery = {
  type: 'object', additionalProperties: false,
  properties: { before: uuid, limit: { type: 'integer', minimum: 1, maximum: 50, default: 20 } },
};
export const projectsPageSchema = object({ projects: { type: 'array', items: projectSchema }, nextCursor: { anyOf: [uuid, { type: 'null' }] } });
export const tasksPageSchema = object({ tasks: { type: 'array', items: taskSchema }, nextCursor: { anyOf: [uuid, { type: 'null' }] } });
export const eventSchema = object({
  version: { const: 1 }, taskId: uuid, sequence: { type: 'integer', minimum: 1 },
  type: { enum: ['TASK_QUEUED', 'TASK_STARTED', 'TASK_RETRYING', 'AGENT_PROGRESS',
    'CANCEL_REQUESTED', 'TASK_CANCELLED', 'TASK_COMPLETED', 'TASK_FAILED'] },
  timestamp: date, payload: { type: 'object', additionalProperties: true },
});
export const pageSchema = object({
  events: { type: 'array', items: eventSchema }, nextCursor: { type: 'integer', minimum: 0 },
  hasMore: { type: 'boolean' }, taskStatus: statusSchema,
});
export const createProjectBody = object({ name: { type: 'string', minLength: 1, maxLength: 100, pattern: '\\S' } });
export const submitBody = object({ projectId: uuid, prompt: { type: 'string', minLength: 1, maxLength: 8000, pattern: '\\S' } });
export const submitHeaders = {
  type: 'object', required: ['idempotency-key'],
  properties: { 'idempotency-key': { type: 'string', minLength: 1, maxLength: 128, pattern: '^[A-Za-z0-9._:-]+$' } },
};
export const replayQuery = {
  type: 'object', additionalProperties: false,
  properties: {
    after: { type: 'integer', minimum: 0, maximum: 2147483647, default: 0 },
    limit: { type: 'integer', minimum: 1, maximum: 100, default: 100 },
  },
};
