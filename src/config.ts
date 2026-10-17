import type { AntigravityOptions } from './agents/antigravity.js';

export interface Config {
  nodeEnv: 'development' | 'test';
  databaseUrl: string;
  devAuthToken: string;
  port: number;
  pollMs: number;
  leaseMs: number;
  fakeStepMs: number;
  agentProvider: 'fake' | 'antigravity';
  antigravity?: AntigravityOptions;
}

function integer(value: string | undefined, fallback: number, min: number, max: number): number {
  const n = value === undefined ? fallback : Number(value);
  if (!Number.isInteger(n) || n < min || n > max) throw new Error('Invalid numeric configuration');
  return n;
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  if ((env.NODE_ENV !== 'development' && env.NODE_ENV !== 'test') || env.AUTH_MODE !== 'development') {
    throw new Error('Only explicitly configured development/test authentication is implemented; production startup is disabled');
  }
  const token = env.DEV_AUTH_TOKEN ?? '';
  if (token.length < 32 || token.length > 256 || token.startsWith('REPLACE_') || /\s/.test(token)) {
    throw new Error('A random DEV_AUTH_TOKEN of 32–256 non-whitespace characters is required');
  }
  const databaseUrl = env.DATABASE_URL ?? '';
  let parsed: URL;
  try { parsed = new URL(databaseUrl); } catch { throw new Error('A valid PostgreSQL DATABASE_URL is required'); }
  if (!['postgres:', 'postgresql:'].includes(parsed.protocol)) throw new Error('DATABASE_URL must use PostgreSQL');
  const agentProvider = env.AGENT_PROVIDER ?? 'fake';
  if (!['fake', 'antigravity'].includes(agentProvider)) throw new Error('Unknown agent provider');
  const diskPath = (key: string): string => {
    const value = env[key] ?? '';
    if (!/^E:[\\/]/i.test(value) || value.includes('..') || /[\r\n]/.test(value)) throw new Error(`${key} must be an absolute E: drive path`);
    return value;
  };
  const antigravity: AntigravityOptions | undefined = agentProvider === 'antigravity' ? {
    executable: diskPath('ANTIGRAVITY_CLI_PATH'), git: diskPath('AGENT_GIT_PATH'), node: diskPath('AGENT_NODE_PATH'),
    npmCli: diskPath('AGENT_NPM_CLI_PATH'), repository: diskPath('AGENT_SOURCE_REPO'),
    workspaceRoot: diskPath('AGENT_WORKSPACE_ROOT'), profile: diskPath('AGENT_PROFILE'),
    timeoutMs: integer(env.AGENT_TIMEOUT_MS, 600000, 30000, 1800000),
  } : undefined;
  return {
    nodeEnv: env.NODE_ENV,
    databaseUrl,
    devAuthToken: token,
    port: integer(env.PORT, 3000, 1, 65535),
    pollMs: integer(env.WORKER_POLL_MS, 500, 50, 10000),
    leaseMs: integer(env.WORKER_LEASE_MS, 15000, 3000, 120000),
    fakeStepMs: integer(env.FAKE_AGENT_STEP_MS, 250, 0, 5000),
    agentProvider: agentProvider as Config['agentProvider'],
    ...(antigravity ? { antigravity } : {}),
  };
}
