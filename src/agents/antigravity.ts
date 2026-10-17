import { mkdir, readFile, writeFile } from 'node:fs/promises';
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
    const controller = new AbortController();
    const signal = AbortSignal.any([input.signal, controller.signal]);
    const deadline = setTimeout(() => controller.abort(), o.timeoutMs);
    const run = (file: string, args: string[], cwd = directory) => this.execute(file, args, { cwd, env, signal, timeoutMs: o.timeoutMs });
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
      const result = await run(o.node, [o.npmCli, 'ci', '--ignore-scripts', '--no-audit', '--no-fund']);
      if (result.code !== 0) throw new Error('Workspace dependency installation failed');
      yield { type: 'progress', message: 'Running Antigravity CLI; shell actions require permission and are not auto-approved', percent: 20 };
      const prompt = `Implement this task in the current workspace only. Do not commit, push, change Git configuration, install software, use subagents, or access files outside this workspace. Do not modify .git, dependencies, or agent settings. The host runner will run checks and capture the diff after you finish. Return an honest summary of changes and any limitations.\n\nTask:\n${input.prompt}`;
      const cli = await run(o.executable, ['--print', prompt, '--output-format', 'json', '--print-timeout', `${Math.floor(o.timeoutMs / 1000)}s`, '--disable-slash-commands', '--log-file', path.join(o.profile, `task-${input.taskId}-${input.attempt}.log`)]);
      let envelope: { status?: string; response?: string; denied_actions?: unknown[] };
      try { envelope = JSON.parse(cli.stdout) as typeof envelope; } catch { throw new Error('Antigravity returned invalid JSON'); }
      if (cli.code !== 0 || envelope.status !== 'SUCCESS' || envelope.denied_actions?.length) throw new Error('Antigravity could not complete the requested actions');
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
    } finally { clearTimeout(deadline); }
  }
}
