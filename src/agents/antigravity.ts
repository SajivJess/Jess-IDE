import { mkdir, open, readFile, rm, writeFile } from 'node:fs/promises';
import path from 'node:path';
import type { AgentAdapter, AgentInput, AgentUpdate } from './adapter.js';
import type { AgentResult } from '../domain.js';
import { runProcess } from './process.js';

export interface AntigravityOptions {
  executable: string; git: string; repository: string; workspaceRoot: string;
  profile: string; node: string; npmCli: string; timeoutMs: number;
}

// A development runner for the owner's configured repository. A separate clone is
// not an OS security sandbox. Public task execution stays disabled for this adapter.
export class AntigravityAgent implements AgentAdapter {
  readonly id = 'antigravity-cli-v1';
  readonly capabilities = { cancellation: true, approvals: false, workspaceExecution: true };
  constructor(private readonly options: AntigravityOptions, private readonly execute = runProcess) {}

  async *run(input: AgentInput): AsyncGenerator<AgentUpdate, void, void> {
    if (!/^[0-9a-f-]{36}$/i.test(input.taskId) || !Number.isInteger(input.attempt) || input.attempt < 1) throw new Error('Invalid task workspace');
    const o = this.options;
    const directory = path.join(o.workspaceRoot, `${input.taskId}-${input.attempt}`);
    const branch = `jess/task-${input.taskId}-${input.attempt}`;
    const env: NodeJS.ProcessEnv = {
      SystemRoot: process.env.SystemRoot ?? 'C:\\Windows', WINDIR: process.env.WINDIR ?? 'C:\\Windows',
      ComSpec: process.env.ComSpec ?? 'C:\\Windows\\System32\\cmd.exe',
      PATH: [path.dirname(o.node), path.dirname(o.git), 'C:\\Windows\\System32', 'C:\\Windows\\System32\\WindowsPowerShell\\v1.0'].join(path.delimiter),
      USERPROFILE: o.profile, APPDATA: path.join(o.profile, 'appdata'), LOCALAPPDATA: path.join(o.profile, 'localappdata'),
      TEMP: path.join(o.profile, 'tmp'), TMP: path.join(o.profile, 'tmp'),
      npm_config_cache: path.join(o.profile, 'npm-cache'), npm_config_prefix: path.join(o.profile, 'npm-global'),
      GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: path.join(o.profile, 'empty-gitconfig'), GIT_TERMINAL_PROMPT: '0',
      NODE_ENV: 'test', CI: '1', NO_COLOR: '1',
    };
    for (const dir of [o.workspaceRoot, o.profile, env.APPDATA!, env.LOCALAPPDATA!, env.TEMP!, env.npm_config_cache!]) await mkdir(dir, { recursive: true });
    await writeFile(env.GIT_CONFIG_GLOBAL!, '', { flag: 'a' });
    // The dedicated CLI profile has mutable permission settings. Serialize its use
    // and grant file edits only to this exact attempt, never all workspaces.
    const lockPath = path.join(o.profile, '.jess-cli.lock');
    const lock = await open(lockPath, 'wx');
    await lock.close();
    const controller = new AbortController();
    const signal = AbortSignal.any([input.signal, controller.signal]);
    const deadline = setTimeout(() => controller.abort(), o.timeoutMs);
    const run = (file: string, args: string[], cwd = directory, stdoutFile?: string) => this.execute(file, args, { cwd, env, signal, timeoutMs: o.timeoutMs, ...(stdoutFile ? { stdoutFile } : {}) });
    const git = async (args: string[], cwd = directory): Promise<string> => {
      const result = await run(o.git, ['-c', 'core.hooksPath=NUL', ...args], cwd);
      if (result.code !== 0) throw new Error('Workspace Git operation failed');
      return result.stdout.trimEnd();
    };
    try {
      yield { type: 'progress', message: 'Creating a separate local Git clone for this attempt', percent: 5 };
      // Fails if the attempt directory already exists: uncertain retries never reuse it.
      await git(['clone', '--no-local', '--no-hardlinks', '--no-checkout', '--', o.repository, directory], o.workspaceRoot);
      await git(['remote', 'remove', 'origin']);
      const baseCommit = await git(['rev-parse', 'HEAD']);
      await git(['checkout', '-b', branch, baseCommit]);
      const result = await run(o.node, [o.npmCli, 'ci', '--prefer-offline', '--ignore-scripts', '--no-audit', '--no-fund']);
      if (result.code !== 0) throw new Error('Workspace dependency installation failed');
      yield { type: 'progress', message: 'Running Antigravity CLI; shell actions require permission and are not auto-approved', percent: 20 };
      const settingsFolder = path.join(o.profile, '.gemini', 'antigravity-cli');
      await mkdir(settingsFolder, { recursive: true });
      await writeFile(path.join(settingsFolder, 'settings.json'), JSON.stringify({ toolPermission: 'request-review', permissions: {
        // Relative paths are resolved by the CLI against the explicitly supplied
        // workspace root. Drive-qualified permission targets differ on Windows.
        allow: ['write_file(.)'],
        deny: ['command(*)', 'unsandboxed(*)', 'mcp(*)', 'read_url(*)', 'execute_url(*)', 'read_file(.git/)', 'read_file(node_modules/)', 'write_file(.agents/)', 'write_file(.gemini/)', 'write_file(AGENTS.md)'],
      } }, null, 2));
      const prompt = `Implement this task in the current workspace only. Use native file tools such as write_to_file and replace_file_content. Shell commands are not permitted. If an action is denied, stop immediately and report the limitation; do not keep retrying denied actions. Do not commit, push, change Git configuration, install software, use subagents, or access files outside this workspace. Do not modify .git, dependencies, or agent settings. The host runner will run checks and capture the diff after you finish. Return an honest summary of changes and any limitations.\n\nTask:\n${input.prompt}`;
      const cli = await run(o.executable, ['--print', prompt, '--add-dir', directory, '--mode', 'accept-edits', '--output-format', 'stream-json', '--print-timeout', `${Math.floor(o.timeoutMs / 1000)}s`, '--disable-slash-commands', '--log-file', path.join(o.profile, `task-${input.taskId}-${input.attempt}.log`)], directory, path.join(o.profile, `events-${input.taskId}-${input.attempt}.jsonl`));
      let envelope: { status?: string; response?: string; denied_actions?: unknown[] };
      try {
        const frames = cli.stdout.trim().split(/\r?\n/).filter(Boolean).map(line => JSON.parse(line) as { event?: string; result?: typeof envelope } & typeof envelope);
        const final = frames.findLast(frame => frame.event === 'result')?.result ?? (frames.length === 1 ? frames[0] : undefined);
        if (!final) throw new Error('Missing final result');
        envelope = final;
      } catch { throw new Error('Antigravity returned invalid JSON'); }
      if (cli.code !== 0 || envelope.status !== 'SUCCESS' || envelope.denied_actions?.length) {
        await writeFile(path.join(o.profile, `failure-${input.taskId}-${input.attempt}.json`), JSON.stringify({ exitCode: cli.code, status: envelope.status, deniedActions: envelope.denied_actions ?? [] }));
        throw new Error('Antigravity could not complete the requested actions');
      }
      if (await git(['rev-parse', 'HEAD']) !== baseCommit || await git(['branch', '--show-current']) !== branch) throw new Error('Unexpected Git history changes');
      yield { type: 'progress', message: 'Running type checks, lint, tests, and build in the task clone', percent: 75 };
      const checks: AgentResult['checks'] = [];
      const commands = [
        ['TypeScript', 'node_modules/typescript/bin/tsc', '--noEmit'],
        ['Lint', 'node_modules/eslint/bin/eslint.js', '.', '--max-warnings', '0'],
        ['Tests (without database credentials)', 'node_modules/vitest/vitest.mjs', 'run'],
        ['Build', 'node_modules/typescript/bin/tsc', '-p', 'tsconfig.build.json'],
      ];
      for (const [name, ...args] of commands) {
        const check = await run(o.node, args);
        checks.push({ name: name!, status: check.code === 0 ? 'passed' : 'failed' });
      }
      await git(['add', '--intent-to-add', '--all']);
      const changed = await git(['diff', '--name-status', '--no-renames', 'HEAD']);
      const files: AgentResult['files'] = changed.split('\n').filter(Boolean).map(line => {
        const [status, ...name] = line.split('\t');
        return { path: name.join('\t'), change: status === 'A' ? 'added' : status === 'D' ? 'deleted' : 'modified' };
      });
      const diff = await git(['diff', '--no-ext-diff', '--no-textconv', '--no-renames', 'HEAD']);
      const report = {
        summary: String(envelope.response ?? 'Antigravity finished').slice(0, 12000), simulated: false,
        files, checks, execution: { branch, baseCommit, diff: diff.slice(0, 200000), truncated: diff.length > 200000 },
      } satisfies AgentResult;
      await writeFile(path.join(o.profile, `result-${input.taskId}-${input.attempt}.json`), JSON.stringify(report, null, 2));
      // Ensure package metadata remains readable; no claims of passed checks come from the model.
      await readFile(path.join(directory, 'package.json'));
      signal.throwIfAborted();
      yield { type: 'result', result: report };
    } finally { clearTimeout(deadline); await rm(lockPath, { force: true }); }
  }
}
