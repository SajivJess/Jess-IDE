import { mkdtemp, rm } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { describe, expect, it } from 'vitest';
import { assertWorkspacePath, executeTool, TOOLS, MetaAgent } from '../src/agents/meta.js';
import { loadConfig } from '../src/config.js';

const baseEnv = {
  NODE_ENV: 'test',
  AUTH_MODE: 'development',
  DEV_AUTH_TOKEN: '0123456789abcdef0123456789abcdef0123456789abcdef',
  DATABASE_URL: 'postgresql://user:pass@127.0.0.1:5432/jess_test',
};

describe('Meta provider configuration', () => {
  it('rejects meta provider without MODEL_API_KEY', () => {
    expect(() =>
      loadConfig({
        ...baseEnv,
        AGENT_PROVIDER: 'meta',
        META_MODEL_ID: 'muse-spark-1.3',
      }),
    ).toThrow('MODEL_API_KEY is required');
  });

  it('rejects meta provider without META_MODEL_ID', () => {
    expect(() =>
      loadConfig({
        ...baseEnv,
        AGENT_PROVIDER: 'meta',
        MODEL_API_KEY: 'test-api-key-12345',
      }),
    ).toThrow('META_MODEL_ID is required');
  });

  it('correctly loads meta configuration with custom options and disk paths', () => {
    const config = loadConfig({
      ...baseEnv,
      AGENT_PROVIDER: 'meta',
      MODEL_API_KEY: 'test-api-key-12345',
      META_MODEL_ID: 'muse-spark-1.3',
      META_MODEL_BASE_URL: 'https://api.meta.ai/v1',
      META_AGENT_WORKSPACE_ROOT: 'D:\\test\\workspaces',
      META_AGENT_GIT_PATH: 'D:\\tools\\git.exe',
      META_AGENT_NODE_PATH: 'D:\\tools\\node.exe',
      META_AGENT_SOURCE_REPO: 'D:\\repo\\source',
      META_MODEL_MAX_RETRIES: '5',
      META_AGENT_MAX_REPAIR_ATTEMPTS: '2',
    });

    expect(config.agentProvider).toBe('meta');
    expect(config.meta).toBeDefined();
    expect(config.meta?.modelId).toBe('muse-spark-1.3');
    expect(config.meta?.apiKey).toBe('test-api-key-12345');
    expect(config.meta?.maxRetries).toBe(5);
    expect(config.meta?.maxRepairAttempts).toBe(2);
    expect(config.meta?.workspaceRoot).toBe('D:\\test\\workspaces');
  });
});

describe('MetaAgent workspace boundary guards', () => {
  const wsDir = path.resolve(os.tmpdir(), 'jess-meta-test-ws');

  it('allows safe relative paths inside workspace', () => {
    const resolved = assertWorkspacePath(wsDir, 'src/index.ts');
    expect(resolved).toBe(path.join(wsDir, 'src', 'index.ts'));
  });

  it('rejects absolute paths', () => {
    expect(() => assertWorkspacePath(wsDir, 'C:\\Windows\\System32\\calc.exe')).toThrow(
      'Absolute paths are not permitted',
    );
  });

  it('rejects path traversal attempts', () => {
    expect(() => assertWorkspacePath(wsDir, '../outside.txt')).toThrow('Path traversal is not permitted');
    expect(() => assertWorkspacePath(wsDir, 'subdir/../../secret.txt')).toThrow('Path traversal is not permitted');
  });

  it('protects .env, .git, and node_modules from being written/accessed', () => {
    expect(() => assertWorkspacePath(wsDir, '.env')).toThrow('Protected path is not writable');
    expect(() => assertWorkspacePath(wsDir, '.git/config')).toThrow('Protected path is not writable');
    expect(() => assertWorkspacePath(wsDir, 'node_modules/pkg/index.js')).toThrow('Protected path is not writable');
  });
});

describe('MetaAgent tools executor', () => {
  it('exposes approved tool schemas', () => {
    const names = TOOLS.map(t => ('function' in t ? t.function.name : ''));
    expect(names).toContain('list_files');
    expect(names).toContain('read_file');
    expect(names).toContain('write_file');
    expect(names).toContain('run_check');
    expect(names).toContain('get_git_diff');
  });

  it('executes write_file, read_file, and list_files in isolated directory', async () => {
    const tmpDir = await mkdtemp(path.join(os.tmpdir(), 'jess-meta-tool-'));
    const signal = new AbortController().signal;

    try {
      // 1. write_file
      const writeRes = await executeTool(
        'write_file',
        { path: 'test.txt', content: 'hello from meta agent' },
        tmpDir,
        process.execPath,
        signal,
        10000,
      );
      expect(JSON.parse(writeRes)).toEqual({ ok: true, path: 'test.txt' });

      // 2. read_file
      const readRes = await executeTool(
        'read_file',
        { path: 'test.txt' },
        tmpDir,
        process.execPath,
        signal,
        10000,
      );
      expect(JSON.parse(readRes)).toEqual({ content: 'hello from meta agent' });

      // 3. list_files
      const listRes = await executeTool(
        'list_files',
        {},
        tmpDir,
        process.execPath,
        signal,
        10000,
      );
      const list = JSON.parse(listRes) as string[];
      expect(list).toContain('test.txt');

      // 4. non-existent file read
      const notFoundRes = await executeTool(
        'read_file',
        { path: 'missing.txt' },
        tmpDir,
        process.execPath,
        signal,
        10000,
      );
      expect(JSON.parse(notFoundRes)).toEqual({ error: 'File not found' });
    } finally {
      await rm(tmpDir, { recursive: true, force: true }).catch(() => {});
    }
  });

  it('rejects invalid or unknown tools and arguments gracefully', async () => {
    const tmpDir = await mkdtemp(path.join(os.tmpdir(), 'jess-meta-unknown-'));
    const signal = new AbortController().signal;

    try {
      const unknownRes = await executeTool('unapproved_command', {}, tmpDir, process.execPath, signal, 5000);
      expect(JSON.parse(unknownRes)).toEqual({ error: 'Unknown tool: unapproved_command' });

      const missingArgs = await executeTool('write_file', {}, tmpDir, process.execPath, signal, 5000);
      expect(JSON.parse(missingArgs)).toEqual({ error: 'path and content are required' });
    } finally {
      await rm(tmpDir, { recursive: true, force: true }).catch(() => {});
    }
  });
});

describe('MetaAgent instance', () => {
  it('instantiates with expected id and capabilities', () => {
    const agent = new MetaAgent({
      apiKey: 'test-key',
      baseUrl: 'https://api.meta.ai/v1',
      modelId: 'muse-spark-1.3',
      timeoutMs: 30000,
      maxRetries: 2,
      maxOutputTokens: 2048,
      maxToolIterations: 10,
      maxRepairAttempts: 2,
      workspaceRoot: 'D:\\tmp\\ws',
      gitPath: 'git',
      nodePath: 'node',
      sourceRepo: 'D:\\repo',
    });

    expect(agent.id).toBe('meta-v1');
    expect(agent.capabilities).toEqual({
      cancellation: true,
      approvals: true,
      workspaceExecution: true,
    });
  });
});
