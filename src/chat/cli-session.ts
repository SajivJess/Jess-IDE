import { spawn } from 'node:child_process';
import { StringDecoder } from 'node:string_decoder';

export interface CliSessionOptions { executable: string; cwd: string; env: NodeJS.ProcessEnv; sessionId?: string; timeoutMs?: number; argsPrefix?: string[] }
export interface CliResult { conversationId: string; status: string; response: string; denied: boolean }
export interface CliProgress { stepType: string; state: string }
const uuid = (value: unknown): value is string => typeof value === 'string' && /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(value);

/** Owns one headless stdin/stdout conversation, not an interactive terminal. */
export class CliSession {
  private readonly child;
  private pending: { resolve: (value: CliResult) => void; reject: (error: Error) => void } | undefined;
  private deadline: ReturnType<typeof setTimeout> | undefined;
  private nativeId: string | undefined;
  private ended = false;
  private initialized = false;
  private bytes = 0;
  private steps = new Set<string>();
  private processing = Promise.resolve();
  private failure: Error | undefined;
  constructor(private readonly options: CliSessionOptions, private readonly bind: (id: string) => Promise<void>, private readonly progress: (value: CliProgress) => Promise<void>) {
    this.nativeId = options.sessionId;
    const args = [...options.argsPrefix ?? [], '--input-format', 'stream-json', '--output-format', 'stream-json', '--mode', 'plan', '--disable-slash-commands', '--print-timeout', `${Math.ceil((options.timeoutMs ?? 120000) / 1000)}s`, '--add-dir', options.cwd,
      ...(options.sessionId ? ['--conversation', options.sessionId] : [])];
    if (options.sessionId && !uuid(options.sessionId)) throw new Error('Invalid native session');
    this.child = spawn(options.executable, args, { cwd: options.cwd, env: options.env, windowsHide: true, shell: false, stdio: ['pipe', 'pipe', 'pipe'] });
    const decoder = new StringDecoder('utf8'); let buffer = '';
    this.child.stdout.on('data', (chunk: Buffer) => {
      this.bytes += chunk.length;
      if (this.bytes > 2 * 1024 * 1024) { this.fail('CLI_OUTPUT_LIMIT'); return; }
      buffer += decoder.write(chunk);
      let end: number;
      while ((end = buffer.indexOf('\n')) >= 0) {
        const line = buffer.slice(0, end); buffer = buffer.slice(end + 1);
        this.processing = this.processing.then(async () => { if (line.trim() && !this.failure) await this.frame(line); }).catch(() => this.fail('CLI_PROTOCOL_ERROR'));
      }
    });
    this.child.stderr.on('data', (chunk: Buffer) => { this.bytes += chunk.length; if (this.bytes > 2 * 1024 * 1024) this.fail('CLI_OUTPUT_LIMIT'); });
    this.child.stdin.on('error', () => this.fail('CLI_INPUT_CLOSED'));
    this.child.once('error', () => this.fail('CLI_START_FAILED'));
    this.child.once('exit', () => {
      // Bound inherited Windows pipe handles after the native parent exits.
      setTimeout(() => { this.child.stdout.destroy(); this.child.stderr.destroy(); }, 250).unref();
      void this.processing.then(() => { this.ended = true; if (this.pending) this.fail('CLI_EXITED_WITHOUT_RESULT'); });
    });
  }
  private async frame(line: string): Promise<void> {
    const frame = JSON.parse(line) as Record<string, unknown>;
    if (frame.event === 'init') {
      if (this.initialized || !uuid(frame.conversation_id) || (this.nativeId && this.nativeId !== frame.conversation_id)) throw new Error('Session mismatch');
      this.nativeId = frame.conversation_id; await this.bind(this.nativeId); this.initialized = true;
    } else if (frame.event === 'step_update') {
      const step = frame.step_update as Record<string, unknown>;
      if (!this.initialized || step.conversation_id !== this.nativeId) throw new Error('Step session mismatch');
      if (!this.pending) throw new Error('Unexpected turn output');
      const stepType = String(step.step_type), state = String(step.state);
      const key = `${step.step_index}:${stepType}:${state}`;
      // Persist only bounded status metadata, never thoughts, tool arguments,
      // raw text fragments or stderr. Final response filtering sees whole secrets.
      if (this.steps.size < 64 && !this.steps.has(key) && ['user_input', 'agent_response', 'tool', 'checkpoint'].includes(stepType) && ['ACTIVE', 'DONE'].includes(state)) {
        this.steps.add(key); await this.progress({ stepType, state });
      }
    } else if (frame.event === 'result') {
      const r = frame.result as Record<string, unknown>;
      if (!this.initialized || !this.pending || r.conversation_id !== this.nativeId || typeof r.status !== 'string' || (r.response !== undefined && typeof r.response !== 'string')) throw new Error('Invalid turn result');
      const response = String(r.response ?? ''); if (Buffer.byteLength(response) > 65536) throw new Error('Response too large');
      clearTimeout(this.deadline); const pending = this.pending; this.pending = undefined;
      pending.resolve({ conversationId: this.nativeId!, status: r.status, response, denied: Array.isArray(r.denied_actions) && r.denied_actions.length > 0 });
    }
  }
  private fail(code: string): void {
    if (this.failure) return;
    this.failure = new Error(code); clearTimeout(this.deadline); this.pending?.reject(this.failure); this.pending = undefined; this.kill();
  }
  private kill(): void {
    if (this.child.pid && process.platform === 'win32') {
      const killer = spawn('C:\\Windows\\System32\\taskkill.exe', ['/PID', String(this.child.pid), '/T', '/F'], { windowsHide: true, shell: false, stdio: 'ignore' });
      killer.on('error', () => { this.child.kill(); });
    } else this.child.kill('SIGKILL');
  }
  turn(prompt: string): Promise<CliResult> {
    if (this.pending || this.ended || this.failure) return Promise.reject(this.failure ?? new Error('CLI_SESSION_UNAVAILABLE'));
    if (Buffer.byteLength(prompt) > 50000) return Promise.reject(new Error('INPUT_TOO_LARGE'));
    this.bytes = 0; this.steps.clear();
    return new Promise((resolve, reject) => {
      this.pending = { resolve, reject };
      this.deadline = setTimeout(() => this.fail('CLI_TIMEOUT'), this.options.timeoutMs ?? 120000);
      this.child.stdin.write(JSON.stringify({ event: 'user', message: { content: prompt } }) + '\n');
    });
  }
  async close(): Promise<void> {
    if (this.pending) this.fail('CLI_CANCELLED');
    if (this.ended) return;
    await new Promise<void>(resolve => {
      const timeout = setTimeout(() => { this.kill(); resolve(); }, 1500);
      this.child.once('exit', () => { clearTimeout(timeout); resolve(); });
      this.child.stdin.end();
    });
  }
}
