import { setTimeout } from 'node:timers/promises';
import type { AgentAdapter, AgentInput, AgentUpdate } from './adapter.js';

// Deterministic simulation only: no filesystem, subprocess, network or model calls.
export class FakeAgent implements AgentAdapter {
  readonly id = 'fake-v1';
  readonly capabilities = { cancellation: true, approvals: false, workspaceExecution: false };
  constructor(private readonly stepMs = 250) {}

  async *run(input: AgentInput): AsyncGenerator<AgentUpdate, void, void> {
    for (const [message, percent] of [
      ['Reviewing the requested task (simulation)', 20],
      ['Preparing a sample change (simulation)', 60],
      ['Preparing check results (simulation)', 90],
    ] as const) {
      await setTimeout(this.stepMs, undefined, { signal: input.signal });
      yield { type: 'progress', message, percent };
    }
    input.signal.throwIfAborted();
    yield {
      type: 'result',
      result: {
        summary: 'Simulated task completed. No code was changed and no checks were executed.',
        simulated: true,
        files: [{ path: 'src/example.ts', change: 'added' }],
        checks: [{ name: 'Example project checks', status: 'simulated' }],
      },
    };
  }
}
