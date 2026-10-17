import type { AgentResult } from '../domain.js';

export interface AgentInput { taskId: string; prompt: string; attempt: number; signal: AbortSignal }
export type AgentUpdate = { type: 'progress'; message: string; percent: number } |
  { type: 'result'; result: AgentResult };

export interface AgentAdapter {
  readonly id: string;
  readonly capabilities: { cancellation: boolean; approvals: boolean; workspaceExecution: boolean };
  run(input: AgentInput): AsyncGenerator<AgentUpdate, void, void>;
}
