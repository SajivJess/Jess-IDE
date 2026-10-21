import { execFile } from 'node:child_process';
import { lstat, readdir, realpath } from 'node:fs/promises';
import path from 'node:path';
import { promisify } from 'node:util';
import { MAX_FILE_BYTES, MAX_FILES, MAX_SNAPSHOT_BYTES, textContent, workspacePath } from './policy.js';
import type { RepositorySnapshot, SnapshotFile } from './policy.js';

const execute = promisify(execFile);
export interface ImportConfig { name: string; githubUrl: string; branch: string; sourceDirectory: string }

export async function importRepository(config: ImportConfig): Promise<RepositorySnapshot> {
  const source = path.resolve(config.sourceDirectory);
  if (!/^E:\\/i.test(source) || !/^https:\/\/github\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(config.githubUrl) ||
    !/^[A-Za-z0-9][A-Za-z0-9_./-]{0,199}$/.test(config.branch) || config.branch.includes('..')) throw new Error('Invalid local registration configuration');
  // Admin-only import: no network requests and no working-tree file reads.
  // Reject redirected Git databases; ignore global config, replacements, hooks,
  // lazy fetches and external protocols. Keep untrusted checkout content inert.
  let current = path.parse(source).root;
  for (const part of source.slice(current.length).split(path.sep)) {
    current = path.join(current, part);
    if ((await lstat(current)).isSymbolicLink() || (await realpath(current)).toLowerCase() !== current.toLowerCase()) throw new Error('Redirected source directory');
  }
  const gitDir = path.join(source, '.git');
  const stat = await lstat(gitDir);
  if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error('A standalone Git directory is required');
  let visited = 0;
  async function inspect(folder: string): Promise<void> {
    for (const entry of await readdir(folder, { withFileTypes: true })) {
      if (++visited > 20000) throw new Error('Git database is too large for this importer');
      const name = path.join(folder, entry.name); const info = await lstat(name);
      if (info.isSymbolicLink() || (!info.isDirectory() && !info.isFile()) || (info.isFile() && info.nlink > 1)) throw new Error('Linked Git metadata is not supported');
      if (entry.name === 'alternates' || entry.name === 'commondir') throw new Error('External Git object directories are not permitted');
      if (info.isDirectory()) await inspect(name);
    }
  }
  await inspect(gitDir);
  const git = async (args: string[], maxBuffer = 1024 * 1024): Promise<Buffer> => {
    const result = await execute('E:\\tools\\git\\cmd\\git.exe', ['--no-pager', '--no-replace-objects', `--git-dir=${gitDir}`,
      '-c', 'core.hooksPath=NUL', '-c', 'core.fsmonitor=false', '-c', 'protocol.allow=never', ...args], {
      cwd: source, windowsHide: true, timeout: 10000, maxBuffer, encoding: 'buffer',
      env: { SystemRoot: process.env.SystemRoot ?? 'C:\\Windows', PATH: 'E:\\tools\\git\\cmd;C:\\Windows\\System32',
        TEMP: 'E:\\local-data\\tmp', TMP: 'E:\\local-data\\tmp', GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: 'NUL',
        GIT_TERMINAL_PROMPT: '0', GIT_NO_LAZY_FETCH: '1', GIT_OPTIONAL_LOCKS: '0' },
    });
    return result.stdout;
  };
  const localConfig = (await git(['config', '--no-includes', '--local', '--list'])).toString('utf8');
  if (/^(include|includeif\.|extensions\.partialclone|remote\..*\.promisor)/im.test(localConfig)) throw new Error('Included or partial-clone Git configuration is not supported');
  const origin = (await git(['config', '--no-includes', '--local', '--get', 'remote.origin.url'])).toString('utf8').trim().replace(/^git@github\.com:/, 'https://github.com/').replace(/\.git$/, '');
  if (origin.toLowerCase() !== config.githubUrl.toLowerCase()) throw new Error('Configured GitHub repository does not match origin');
  await git(['check-ref-format', `refs/heads/${config.branch}`]);
  const baseCommit = (await git(['rev-parse', '--verify', `refs/heads/${config.branch}^{commit}`])).toString('ascii').trim();
  if (!/^[a-f0-9]{40}$/.test(baseCommit)) throw new Error('Unsupported Git object format');
  const records = (await git(['ls-tree', '-rlz', baseCommit])).toString('utf8').split('\0').filter(Boolean);
  if (records.length > MAX_FILES) throw new Error('Snapshot file-count limit exceeded');
  const files: SnapshotFile[] = []; let total = 0;
  for (const record of records) {
    const match = /^(\d+) (blob|commit) ([a-f0-9]{40}) +([\d-]+)\t(.+)$/.exec(record);
    if (!match) throw new Error('Unexpected Git tree entry');
    const [, mode, , objectId, length, filename] = match;
    try { workspacePath(filename!); } catch { continue; } // Protected or nonportable names are never imported.
    const size = length === '-' ? 0 : Number(length);
    const file: SnapshotFile = { path: filename!, content: null, reason: null, size };
    if (!['100644', '100755'].includes(mode!)) file.reason = 'link-or-submodule';
    else if (size > MAX_FILE_BYTES) file.reason = 'too-large';
    else {
      const bytes = await git(['cat-file', 'blob', objectId!], MAX_FILE_BYTES + 1024);
      if (bytes.length !== size) throw new Error('Unexpected Git object length');
      try { const text = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(bytes); textContent(text); file.content = text; }
      catch { file.reason = bytes.includes(0) ? 'binary' : 'unsupported-text'; }
      if (file.content !== null) total += bytes.length;
    }
    if (total > MAX_SNAPSHOT_BYTES) throw new Error('Snapshot byte limit exceeded');
    files.push(file);
  }
  return { ...config, sourceDirectory: source, baseCommit, files };
}
