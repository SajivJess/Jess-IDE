import { mkdir, writeFile, readFile, readdir } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import path from 'node:path';
import OpenAI from 'openai';
import type { AgentAdapter, AgentInput, AgentUpdate } from './adapter.js';
import type { AgentResult } from '../domain.js';
import { runProcess } from './process.js';

export interface MetaOptions {
  apiKey: string;
  baseUrl: string;
  modelId: string;
  timeoutMs: number;
  maxRetries: number;
  maxOutputTokens: number;
  maxToolIterations: number;
  maxRepairAttempts: number;
  workspaceRoot: string;
  gitPath: string;
  nodePath: string;
  sourceRepo: string;
}

// ─── Workspace path guard ────────────────────────────────────────────────────
export function assertWorkspacePath(workspaceDir: string, filePath: string): string {
  if (path.isAbsolute(filePath)) throw new Error(`Absolute paths are not permitted: ${filePath}`);
  if (filePath.includes('..')) throw new Error(`Path traversal is not permitted: ${filePath}`);
  const resolved = path.resolve(workspaceDir, filePath);
  if (!resolved.startsWith(workspaceDir + path.sep) && resolved !== workspaceDir) {
    throw new Error(`Path escapes workspace boundary: ${filePath}`);
  }
  const dangerous = /^(\.env|\.git|node_modules)/i;
  const base = filePath.split(/[\\/]/)[0] ?? '';
  if (dangerous.test(base)) throw new Error(`Protected path is not writable: ${filePath}`);
  return resolved;
}

// ─── Tool definitions for the model ─────────────────────────────────────────
export const TOOLS: OpenAI.Chat.Completions.ChatCompletionTool[] = [
  {
    type: 'function',
    function: {
      name: 'list_files',
      description: 'List files in the workspace (or a subdirectory). Returns relative paths.',
      parameters: {
        type: 'object',
        properties: { directory: { type: 'string', description: 'Subdirectory to list, relative to workspace root. Defaults to root.' } },
        required: [],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'read_file',
      description: 'Read a file from the workspace. Maximum 100 KB.',
      parameters: {
        type: 'object',
        properties: { path: { type: 'string', description: 'File path relative to workspace root.' } },
        required: ['path'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'write_file',
      description: 'Create or overwrite a file in the workspace. Cannot write to .env, .git, or node_modules.',
      parameters: {
        type: 'object',
        properties: {
          path: { type: 'string', description: 'File path relative to workspace root.' },
          content: { type: 'string', description: 'Complete file content to write.' },
        },
        required: ['path', 'content'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'run_check',
      description: 'Run an approved project check inside the workspace. Returns exit code, output and duration.',
      parameters: {
        type: 'object',
        properties: {
          command: {
            type: 'string',
            enum: ['typecheck', 'lint', 'test', 'build'],
            description: 'Which check to run.',
          },
        },
        required: ['command'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'get_git_diff',
      description: 'Return the current diff of all changes made in the workspace relative to the base commit.',
      parameters: { type: 'object', properties: {}, required: [] },
    },
  },
];

// ─── Tool executor ───────────────────────────────────────────────────────────
export type CheckCommand = 'typecheck' | 'lint' | 'test' | 'build';
export const CHECK_COMMANDS: Record<CheckCommand, string[]> = {
  typecheck: ['node_modules/typescript/bin/tsc', '--noEmit'],
  lint:      ['node_modules/eslint/bin/eslint.js', '.', '--max-warnings', '0'],
  test:      ['node_modules/vitest/vitest.mjs', 'run'],
  build:     ['node_modules/typescript/bin/tsc', '-p', 'tsconfig.build.json'],
};

export async function executeTool(
  name: string,
  rawArgs: unknown,
  workspaceDir: string,
  nodePath: string,
  signal: AbortSignal,
  timeoutMs: number,
): Promise<string> {
  const args = (typeof rawArgs === 'object' && rawArgs !== null ? rawArgs : {}) as Record<string, unknown>;

  if (name === 'list_files') {
    const sub = typeof args['directory'] === 'string' ? args['directory'] : '.';
    const dir = assertWorkspacePath(workspaceDir, sub === '.' ? '' : sub);
    const entries = await readdir(existsSync(dir) ? dir : workspaceDir, { withFileTypes: true });
    return JSON.stringify(entries.map(e => (e.isDirectory() ? `${e.name}/` : e.name)));
  }

  if (name === 'read_file') {
    if (typeof args['path'] !== 'string') return JSON.stringify({ error: 'path is required' });
    const abs = assertWorkspacePath(workspaceDir, args['path']);
    const stat = await readFile(abs, 'utf8').catch(() => null);
    if (stat === null) return JSON.stringify({ error: 'File not found' });
    if (Buffer.byteLength(stat, 'utf8') > 100 * 1024) return JSON.stringify({ error: 'File too large (>100 KB)' });
    return JSON.stringify({ content: stat });
  }

  if (name === 'write_file') {
    if (typeof args['path'] !== 'string' || typeof args['content'] !== 'string') {
      return JSON.stringify({ error: 'path and content are required' });
    }
    const abs = assertWorkspacePath(workspaceDir, args['path']);
    await mkdir(path.dirname(abs), { recursive: true });
    await writeFile(abs, args['content'], 'utf8');
    return JSON.stringify({ ok: true, path: args['path'] });
  }

  if (name === 'run_check') {
    const cmd = args['command'];
    if (typeof cmd !== 'string' || !(cmd in CHECK_COMMANDS)) {
      return JSON.stringify({ error: `Unknown command. Allowed: ${Object.keys(CHECK_COMMANDS).join(', ')}` });
    }
    const [bin, ...rest] = CHECK_COMMANDS[cmd as CheckCommand]!;
    const start = Date.now();
    const result = await runProcess(nodePath, [bin!, ...rest], {
      cwd: workspaceDir, env: { ...process.env, NODE_ENV: 'test', CI: '1', NO_COLOR: '1' },
      signal, timeoutMs, maxBytes: 512 * 1024,
    });
    return JSON.stringify({ exitCode: result.code, output: result.stdout.slice(0, 8000), durationMs: Date.now() - start });
  }

  if (name === 'get_git_diff') {
    const result = await runProcess(nodePath, ['-e', 'process.stdout.write(require("child_process").execSync("git diff HEAD", { cwd: process.argv[1], maxBuffer: 512*1024 }).toString())'],
      { cwd: workspaceDir, env: process.env, signal, timeoutMs: 10000 });
    const diff = result.stdout.slice(0, 200 * 1024);
    return JSON.stringify({ diff, truncated: result.stdout.length > 200 * 1024 });
  }

  return JSON.stringify({ error: `Unknown tool: ${name}` });
}

// ─── MetaAgent ───────────────────────────────────────────────────────────────
export class MetaAgent implements AgentAdapter {
  readonly id = 'meta-v1';
  readonly capabilities = { cancellation: true, approvals: true, workspaceExecution: true };

  private readonly client: OpenAI;

  constructor(private readonly options: MetaOptions) {
    this.client = new OpenAI({
      apiKey: options.apiKey,
      baseURL: options.baseUrl,
      timeout: options.timeoutMs,
      maxRetries: options.maxRetries,
    });
  }

  async *run(input: AgentInput): AsyncGenerator<AgentUpdate, void, void> {
    const o = this.options;
    const workspaceDir = path.join(o.workspaceRoot, `${input.taskId}-${input.attempt}`);

    // ── 1. Workspace setup ──────────────────────────────────────────────────
    input.signal.throwIfAborted();
    yield { type: 'progress', message: '[Meta] Setting up workspace for this attempt', percent: 3 };
    await mkdir(o.workspaceRoot, { recursive: true });

    // Clone source repo into isolated workspace dir
    const git = async (args: string[], cwd = workspaceDir): Promise<string> => {
      const r = await runProcess(o.gitPath, ['-c', 'core.hooksPath=NUL', ...args], {
        cwd, env: {
          ...process.env,
          GIT_CONFIG_NOSYSTEM: '1', GIT_TERMINAL_PROMPT: '0', CI: '1',
        },
        signal: input.signal, timeoutMs: 60000,
      });
      if (r.code !== 0) throw new Error(`Git operation failed: git ${args.join(' ')}`);
      return r.stdout.trimEnd();
    };

    yield { type: 'progress', message: '[Meta] Cloning workspace from source repository', percent: 6 };
    await git(['clone', '--no-local', '--no-hardlinks', '--no-checkout', '--', o.sourceRepo, workspaceDir], o.workspaceRoot);
    await git(['remote', 'remove', 'origin']);
    const baseCommit = await git(['rev-parse', 'HEAD']);
    const branch = `meta/task-${input.taskId}-${input.attempt}`;
    await git(['checkout', '-b', branch, baseCommit]);

    input.signal.throwIfAborted();
    yield { type: 'progress', message: '[Meta] Installing workspace dependencies', percent: 10 };
    const installResult = await runProcess(o.nodePath, [
      'node_modules/npm/bin/npm-cli.js', 'ci', '--prefer-offline', '--ignore-scripts', '--no-audit', '--no-fund',
    ], { cwd: workspaceDir, env: process.env, signal: input.signal, timeoutMs: 300000 });
    if (installResult.code !== 0) throw new Error('Workspace dependency installation failed');

    const checks: AgentResult['checks'] = [];
    const usageData = { promptTokens: 0, completionTokens: 0, totalTokens: 0 };

    const systemPrompt = `You are an autonomous coding agent running inside Jess IDE.
You are working in an isolated Git workspace. Your job is to implement the requested coding task.

Rules:
- Use only the provided tools: list_files, read_file, write_file, run_check, get_git_diff.
- Never reference paths outside the workspace.
- Never fabricate test results. If you run a check, use run_check and report its actual exit code.
- After making changes, always run run_check to verify them.
- If a check fails, read the output carefully and apply a targeted repair.
- Do not loop more than ${o.maxToolIterations} tool calls total.
- Stop when the task is complete or you have exhausted your repair budget.
- Your final message (when you stop calling tools) must be a concise summary of what changed and the final check status.`;

    const messages: OpenAI.Chat.Completions.ChatCompletionMessageParam[] = [
      { role: 'system', content: systemPrompt },
      { role: 'user', content: `Implement this task in the current workspace. Do not commit or push.\n\nTask:\n${input.prompt}` },
    ];

    // ── 2. Agentic tool-call loop ────────────────────────────────────────────
    yield { type: 'progress', message: '[Meta] Calling Meta model for implementation plan', percent: 15 };
    input.signal.throwIfAborted();

    let iteration = 0;
    let finalSummary = 'Meta agent completed without a final summary.';
    let repairAttempt = 0;

    while (iteration < o.maxToolIterations) {
      input.signal.throwIfAborted();

      const response = await this.client.chat.completions.create({
        model: o.modelId,
        messages,
        tools: TOOLS,
        tool_choice: 'auto',
        max_tokens: o.maxOutputTokens,
      });

      // Accumulate usage
      if (response.usage) {
        usageData.promptTokens += response.usage.prompt_tokens;
        usageData.completionTokens += response.usage.completion_tokens;
        usageData.totalTokens += response.usage.total_tokens;
      }

      const choice = response.choices[0];
      if (!choice) throw new Error('Meta API returned no choices');

      if (choice.finish_reason === 'stop' || !choice.message.tool_calls?.length) {
        finalSummary = choice.message.content ?? finalSummary;
        break;
      }

      messages.push(choice.message);

      // Execute each tool call
      for (const tc of choice.message.tool_calls as Array<{ id: string; function: { name: string; arguments: string } }>) {
        let rawArgs: unknown;
        try { rawArgs = JSON.parse(tc.function.arguments); } catch {
          rawArgs = {};
        }

        const progressMsg = `[Meta] Tool call: ${tc.function.name}`;
        const pct = Math.min(20 + Math.floor((iteration / o.maxToolIterations) * 50), 69);
        yield { type: 'progress', message: progressMsg, percent: pct };

        let toolResult: string;
        try {
          toolResult = await executeTool(tc.function.name, rawArgs, workspaceDir, o.nodePath, input.signal, o.timeoutMs);
        } catch (err) {
          toolResult = JSON.stringify({ error: err instanceof Error ? err.message : String(err) });
        }

        // Track check results
        if (tc.function.name === 'run_check') {
          try {
            const parsed = JSON.parse(toolResult) as { exitCode?: number; output?: string };
            const checkName = (rawArgs as Record<string, unknown>)['command'] as string ?? 'check';
            const status = parsed.exitCode === 0 ? 'passed' : 'failed';
            checks.push({ name: checkName, status });

            // Trigger repair if check failed and budget remains
            if (status === 'failed' && repairAttempt < o.maxRepairAttempts) {
              repairAttempt++;
              yield { type: 'progress', message: `[Meta] Check failed — requesting repair (attempt ${repairAttempt} of ${o.maxRepairAttempts})`, percent: pct };
              messages.push({ role: 'tool', tool_call_id: tc.id, content: toolResult });
              messages.push({ role: 'user', content: `The check failed (exit code ${parsed.exitCode ?? '?'}). Output:\n${(parsed.output ?? '').slice(0, 4000)}\n\nPlease repair the code and re-run the check.` });
              continue;
            }
          } catch { /* non-JSON tool result, ignore */ }
        }

        messages.push({ role: 'tool', tool_call_id: tc.id, content: toolResult });
      }

      iteration++;
    }

    // ── 3. Capture diff ──────────────────────────────────────────────────────
    yield { type: 'progress', message: '[Meta] Collecting workspace diff', percent: 80 };
    input.signal.throwIfAborted();

    let diff = '';
    let diffTruncated = false;
    try {
      const diffResult = await git(['diff', '--no-ext-diff', '--no-textconv', '--no-renames', 'HEAD']);
      diff = diffResult.slice(0, 200 * 1024);
      diffTruncated = diffResult.length > 200 * 1024;
    } catch { diff = ''; }

    // Changed files
    let changedFiles: AgentResult['files'] = [];
    try {
      await git(['add', '--intent-to-add', '--all']);
      const changed = await git(['diff', '--name-status', '--no-renames', 'HEAD']);
      changedFiles = changed.split('\n').filter(Boolean).map(line => {
        const [status, ...nameParts] = line.split('\t');
        return {
          path: nameParts.join('\t'),
          change: status === 'A' ? 'added' : status === 'D' ? 'deleted' : 'modified',
        } as AgentResult['files'][number];
      });
    } catch { changedFiles = []; }

    yield { type: 'progress', message: '[Meta] Task complete — building evidence report', percent: 95 };

    const result: AgentResult = {
      summary: finalSummary.slice(0, 4000),
      simulated: false,
      files: changedFiles,
      checks: checks.length > 0 ? checks : [{ name: 'No checks run', status: 'skipped' }],
      execution: { branch, baseCommit, diff, truncated: diffTruncated },
      meta: {
        provider: 'meta-v1',
        modelId: o.modelId,
        repairAttempts: repairAttempt,
        toolIterations: iteration,
        usage: usageData,
      },
    } as AgentResult & { meta: Record<string, unknown> };

    yield { type: 'result', result };
  }
}
