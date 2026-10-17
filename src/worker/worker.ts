import { setTimeout } from 'node:timers/promises';
import type { AgentAdapter, AgentUpdate } from '../agents/adapter.js';
import type { AgentResult } from '../domain.js';
import { LeaseLost } from '../domain.js';
import { Store } from '../db/store.js';

export class Worker {
  constructor(private readonly store: Store, private readonly agent: AgentAdapter,
    private readonly leaseMs = 15000, private readonly pollMs = 500) {}

  async runOnce(shutdown?: AbortSignal): Promise<boolean> {
    if (shutdown?.aborted) return false;
    const claim = await this.store.claim(this.leaseMs);
    if (!claim) return false;
    if (claim === 'reconciled') return true;
    const controller = new AbortController();
    const onShutdown = (): void => controller.abort();
    shutdown?.addEventListener('abort', onShutdown, { once: true });
    if (shutdown?.aborted) controller.abort();
    let cancelled = false;
    let heartbeatError: unknown;
    let heartbeat: Promise<void> | undefined;
    const timer = setInterval(() => {
      if (heartbeat) return;
      heartbeat = this.store.renew(claim, this.leaseMs).then(requested => {
        cancelled ||= requested;
        if (requested) controller.abort();
      }).catch((error: unknown) => {
        heartbeatError = error;
        controller.abort();
      }).finally(() => { heartbeat = undefined; });
    }, Math.max(10, Math.floor(this.leaseMs / 3)));
    const iterator = this.agent.run({
      taskId: claim.task.id, prompt: claim.task.prompt, attempt: claim.task.attempt, signal: controller.signal,
    });
    try {
      let result: AgentResult | null = null;
      while (true) {
        let next: IteratorResult<AgentUpdate, void>;
        try { next = await iterator.next(); }
        catch {
          if (heartbeatError) throw heartbeatError;
          if (shutdown?.aborted) { await this.store.abandon(claim); return true; }
          await this.store.finish(claim, null, !cancelled);
          return true;
        }
        if (heartbeatError) throw heartbeatError;
        if (shutdown?.aborted) { await this.store.abandon(claim); return true; }
        if (next.done) {
          await this.store.finish(claim, result, result === null);
          return true;
        }
        if (next.value.type === 'result') result = next.value.result;
        else {
          cancelled ||= await this.store.progress(claim, { message: next.value.message, percent: next.value.percent });
          if (cancelled) controller.abort();
        }
      }
    } catch (error) {
      if (error instanceof LeaseLost) return true; // A stale worker cannot overwrite a new attempt.
      throw error; // DB errors leave the durable RUNNING job for lease-expiry reconciliation.
    } finally {
      clearInterval(timer);
      shutdown?.removeEventListener('abort', onShutdown);
      controller.abort();
      await heartbeat;
      await iterator.return().catch(() => undefined);
    }
  }

  async run(signal: AbortSignal, onError: () => void): Promise<void> {
    while (!signal.aborted) {
      let worked = false;
      try { worked = await this.runOnce(signal); } catch { onError(); }
      if (!worked && !signal.aborted) await setTimeout(this.pollMs, undefined, { signal }).catch(() => undefined);
    }
  }
}
