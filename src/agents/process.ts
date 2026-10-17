import { spawn } from 'node:child_process';
import { appendFileSync } from 'node:fs';

export interface ProcessResult { code: number; stdout: string }
export interface ProcessOptions { cwd: string; env: NodeJS.ProcessEnv; signal: AbortSignal; timeoutMs?: number; maxBytes?: number; stdoutFile?: string }

// No shell expansion. Child output and lifetime are bounded; never return stderr to clients.
export function runProcess(file: string, args: string[], options: ProcessOptions): Promise<ProcessResult> {
  options.signal.throwIfAborted();
  return new Promise((resolve, reject) => {
    const child = spawn(file, args, { cwd: options.cwd, env: options.env, shell: false, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
    const chunks: Buffer[] = [];
    let bytes = 0;
    let failure: Error | undefined;
    let drainTimer: ReturnType<typeof setTimeout> | undefined;
    const stop = (): void => {
      if (child.pid && process.platform === 'win32') {
        const killer = spawn('C:\\Windows\\System32\\taskkill.exe', ['/PID', String(child.pid), '/T', '/F'], { windowsHide: true, stdio: 'ignore', shell: false });
        killer.on('error', () => { child.kill('SIGKILL'); });
      } else { child.kill('SIGKILL'); }
    };
    const abort = (): void => { failure = new Error('Execution cancelled'); stop(); };
    const timer = setTimeout(() => { failure = new Error('Execution timed out'); stop(); }, options.timeoutMs ?? 120000);
    const onData = (data: Buffer, stdout: boolean): void => {
      bytes += data.length;
      if (bytes > (options.maxBytes ?? 2 * 1024 * 1024)) { failure = new Error('Execution output limit exceeded'); stop(); }
      else if (stdout) {
        chunks.push(data);
        if (options.stdoutFile) {
          try { appendFileSync(options.stdoutFile, data); }
          catch { failure = new Error('Could not save local execution trace'); stop(); }
        }
      }
    };
    child.stdout.on('data', (data: Buffer) => onData(data, true));
    child.stderr.on('data', (data: Buffer) => onData(data, false));
    options.signal.addEventListener('abort', abort, { once: true });
    if (options.signal.aborted) abort();
    // Some native Windows helpers inherit stdout handles and keep the pipe open
    // after the CLI exits. Bound final draining rather than waiting indefinitely.
    child.once('exit', () => {
      drainTimer = setTimeout(() => { child.stdout.destroy(); child.stderr.destroy(); }, 250);
    });
    const cleanup = (): void => { clearTimeout(timer); clearTimeout(drainTimer); options.signal.removeEventListener('abort', abort); };
    child.once('error', () => { cleanup(); reject(new Error('Could not start configured executable')); });
    child.once('close', code => { cleanup(); if (failure) reject(failure); else resolve({ code: code ?? -1, stdout: Buffer.concat(chunks).toString('utf8') }); });
  });
}
