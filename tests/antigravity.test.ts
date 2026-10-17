import { mkdtemp, mkdir, readFile, writeFile, access } from 'node:fs/promises';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { describe, expect, it } from 'vitest';
import { AntigravityAgent } from '../src/agents/antigravity.js';
import type { AgentUpdate } from '../src/agents/adapter.js';
import { runProcess } from '../src/agents/process.js';
import { loadConfig } from '../src/config.js';

const gitPath = 'E:\\tools\\git\\cmd\\git.exe';
const root = 'E:\\local-data\\tmp';
const env = { ...process.env, TEMP: root, TMP: root, GIT_TERMINAL_PROMPT: '0' };
const signal = () => new AbortController().signal;
async function git(cwd: string, args: string[]): Promise<string> {
  const result = await runProcess(gitPath, args, { cwd, env, signal: signal() });
  if (result.code !== 0) throw new Error('Test fixture Git command failed');
  return result.stdout.trim();
}
async function fixture() {
  await mkdir(root, { recursive: true });
  const folder = await mkdtemp(path.join(root, 'jess-cli-test-'));
  const repository = path.join(folder, 'source');
  await mkdir(repository);
  await git(repository, ['init']);
  await writeFile(path.join(repository, 'package.json'), '{"name":"fixture","version":"1.0.0"}');
  await writeFile(path.join(repository, 'hello.txt'), 'before\n');
  await git(repository, ['add', '.']);
  await git(repository, ['-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '-m', 'fixture']);
  await writeFile(path.join(repository, '.env'), 'DEV_AUTH_TOKEN=do-not-copy');
  return { executable: path.join(folder, 'agy.exe'), git: gitPath, repository, workspaceRoot: path.join(folder, 'tasks'), profile: path.join(folder, 'profile'), node: process.execPath, npmCli: path.join(folder, 'npm-cli.js'), timeoutMs: 30000 };
}

describe('Antigravity local execution boundary', () => {
  it('captures actual clone changes and check outcomes without copying secrets or modifying source', async () => {
    const options = await fixture();
    const execute: typeof runProcess = async (file, args, request) => {
      if (file === options.git) return runProcess(file, args, request);
      expect(request.env.DATABASE_URL).toBeUndefined();
      expect(request.env.DEV_AUTH_TOKEN).toBeUndefined();
      expect(request.env.TEST_DATABASE_URL).toBeUndefined();
      if (file === options.executable) {
        const settings = JSON.parse(await readFile(path.join(options.profile, '.gemini', 'antigravity-cli', 'settings.json'), 'utf8')) as { permissions: { allow: string[]; deny: string[] } };
        expect(settings.permissions.allow).toEqual(['write_file(.)']);
        expect(settings.permissions.deny).toContain('command(*)');
        // A second invocation may not change the shared CLI profile's permissions.
        await expect(new AntigravityAgent(options, execute).run({ taskId: randomUUID(), prompt: 'Concurrent task', attempt: 1, signal: signal() }).next()).rejects.toThrow();
        await expect(access(path.join(request.cwd, '.env'))).rejects.toThrow();
        expect(args).not.toContain('--dangerously-skip-permissions');
        expect(args).toContain('--disable-slash-commands');
        expect(args[args.indexOf('--add-dir') + 1]).toBe(request.cwd);
        expect(args[args.indexOf('--mode') + 1]).toBe('accept-edits');
        expect(await git(request.cwd, ['remote'])).toBe('');
        await writeFile(path.join(request.cwd, 'hello.txt'), 'after\n');
        await writeFile(path.join(request.cwd, 'new.txt'), 'new\n');
        return { code: 0, stdout: JSON.stringify({ status: 'SUCCESS', response: 'Changed files' }) };
      }
      return { code: args.includes('--noEmit') ? 1 : 0, stdout: '' };
    };
    const updates: AgentUpdate[] = [];
    const taskId = randomUUID();
    for await (const update of new AntigravityAgent(options, execute).run({ taskId, prompt: 'Change a file', attempt: 1, signal: signal() })) updates.push(update);
    const result = updates.find(update => update.type === 'result');
    expect(result?.type).toBe('result');
    if (result?.type !== 'result') throw new Error('Missing result');
    expect(result.result.simulated).toBe(false);
    expect(result.result.execution?.diff).toContain('+after');
    expect(result.result.execution?.diff).toContain('+new');
    expect(result.result.files).toContainEqual({ path: 'new.txt', change: 'added' });
    expect(result.result.checks[0]?.status).toBe('failed');
    expect(await readFile(path.join(options.repository, 'hello.txt'), 'utf8')).toBe('before\n');
    const work = path.join(options.workspaceRoot, `${taskId}-1`);
    expect(await git(work, ['rev-parse', 'HEAD'])).toBe(await git(options.repository, ['rev-parse', 'HEAD']));
    await expect(access(path.join(options.profile, '.jess-cli.lock'))).rejects.toThrow();
    // An uncertain attempt cannot silently rerun over an existing modified clone.
    await expect(async () => { for await (const update of new AntigravityAgent(options, execute).run({ taskId, prompt: 'Retry', attempt: 1, signal: signal() })) void update; }).rejects.toThrow();
  });

  it('does not turn denied actions, malformed output, or provider failures into successful results', async () => {
    const options = await fixture();
    for (const stdout of ['not-json', '{"status":"ERROR"}', '{"status":"SUCCESS","denied_actions":["command(git push)"]}']) {
      const execute: typeof runProcess = async (file, args, request) => file === options.git ? runProcess(file, args, request) : { code: 0, stdout: file === options.executable ? stdout : '' };
      await expect(async () => { for await (const update of new AntigravityAgent(options, execute).run({ taskId: randomUUID(), prompt: 'Do work', attempt: 1, signal: signal() })) void update; }).rejects.toThrow();
    }
  });

  it('bounds process runtime/output and honors cancellation', async () => {
    const options = { cwd: root, env, signal: signal(), timeoutMs: 200 };
    await expect(runProcess(process.execPath, ['-e', 'setInterval(()=>{},1000)'], options)).rejects.toThrow('timed out');
    await expect(runProcess(process.execPath, ['-e', 'console.log("x".repeat(10000))'], { ...options, timeoutMs: 5000, maxBytes: 100 })).rejects.toThrow('output limit');
    const controller = new AbortController();
    const running = runProcess(process.execPath, ['-e', 'setInterval(()=>{},1000)'], { ...options, timeoutMs: 5000, signal: controller.signal });
    controller.abort();
    await expect(running).rejects.toThrow('cancelled');
  });

  it('does not hang when a native helper inherits the CLI output pipes', async () => {
    const result = await runProcess(process.execPath, ['-e', 'const {spawn}=require("node:child_process");spawn(process.execPath,["-e","setTimeout(()=>{},3000)"],{stdio:["ignore",process.stdout,process.stderr]});console.log("finished");process.exit(0);'], { cwd: root, env, signal: signal(), timeoutMs: 2000 });
    expect(result.code).toBe(0);
    expect(result.stdout).toContain('finished');
  });

  it('rejects unknown providers and missing E: drive executable configuration', () => {
    const base = { NODE_ENV: 'test', AUTH_MODE: 'development', DEV_AUTH_TOKEN: 'test-only-token-long-enough-for-config', DATABASE_URL: 'postgresql://unused@localhost/test' };
    expect(() => loadConfig({ ...base, AGENT_PROVIDER: 'unknown' })).toThrow();
    expect(() => loadConfig({ ...base, AGENT_PROVIDER: 'antigravity' })).toThrow();
    expect(() => loadConfig({ ...base, AGENT_PROVIDER: 'antigravity', ANTIGRAVITY_CLI_PATH: 'C:\\agy.exe' })).toThrow();
    expect(loadConfig(base).agentProvider).toBe('fake');
  });
});
