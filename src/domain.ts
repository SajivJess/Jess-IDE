export type TaskStatus = 'QUEUED' | 'RUNNING' | 'COMPLETED' | 'FAILED' | 'CANCELLED';
export const terminal = (status: TaskStatus): boolean => ['COMPLETED', 'FAILED', 'CANCELLED'].includes(status);

export interface Project {
  id: string;
  name: string;
  createdAt: string;
}

export interface AgentResult {
  summary: string;
  simulated: boolean;
  files: { path: string; change: 'added' | 'modified' | 'deleted' }[];
  checks: { name: string; status: 'simulated' | 'passed' | 'failed' | 'skipped'; exitCode?: number; durationMs?: number }[];
  execution?: { branch: string; baseCommit: string; diff: string; truncated: boolean };
  /** Present only when a real provider adapter ran. Never contains credentials. */
  meta?: {
    provider: string;
    modelId: string;
    repairAttempts: number;
    toolIterations: number;
    usage?: { promptTokens: number; completionTokens: number; totalTokens: number };
  };
}

export interface Task {
  id: string;
  projectId: string;
  prompt: string;
  status: TaskStatus;
  attempt: number;
  maxAttempts: number;
  cancelRequested: boolean;
  result: AgentResult | null;
  error: string | null;
  createdAt: string;
  updatedAt: string;
}

export type EventType = 'TASK_QUEUED' | 'TASK_STARTED' | 'TASK_RETRYING' | 'AGENT_PROGRESS' |
  'CANCEL_REQUESTED' | 'TASK_CANCELLED' | 'TASK_COMPLETED' | 'TASK_FAILED';

export interface TaskEvent {
  version: 1;
  taskId: string;
  sequence: number;
  type: EventType;
  timestamp: string;
  payload: Record<string, unknown>;
}

export class HttpError extends Error {
  constructor(public readonly statusCode: number, public readonly code: string) { super(code); }
}

export class LeaseLost extends Error {
  constructor() { super('Worker lease is no longer valid'); }
}
