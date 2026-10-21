import { mkdtemp, mkdir, writeFile, symlink } from 'node:fs/promises';
import path from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { describe, it, expect } from 'vitest';
import { importRepository } from '../src/workspaces/import.js';
const execute = promisify(execFile);
const root = 'E:\\local-data\\tmp';
async function fixture() {
  const sourceDirectory = await mkdtemp(path.join(root, 'jess-import-'));
  const git = async (...args: string[]) => (await execute('E:\\tools\\git\\cmd\\git.exe', args, { cwd: sourceDirectory, windowsHide: true, env: { ...process.env, TEMP: root, TMP: root, GIT_CONFIG_GLOBAL: 'NUL', GIT_CONFIG_NOSYSTEM: '1' } })).stdout.trim();
  await git('init', '-b', 'main'); await git('remote', 'add', 'origin', 'https://github.com/example/fixture.git');
  await mkdir(path.join(sourceDirectory, 'src'));
  await writeFile(path.join(sourceDirectory, 'src/main.ts'), 'const base = 1;\n');
  await writeFile(path.join(sourceDirectory, '.env'), 'NEVER_IMPORT=this-secret');
  await writeFile(path.join(sourceDirectory, 'binary.bin'), Buffer.from([0, 1, 2]));
  await writeFile(path.join(sourceDirectory, 'large.txt'), 'x'.repeat(65537));
  await git('add', '.');
  await git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', '-c', 'core.hooksPath=NUL', 'commit', '-m', 'fixture');
  return { config: { name: 'Fixture', githubUrl: 'https://github.com/example/fixture', branch: 'main', sourceDirectory }, git };
}
describe('local committed-object import', () => {
  it('imports committed content only, excludes protected names and bounds binary and large files', async () => {
    const { config } = await fixture();
    await writeFile(path.join(config.sourceDirectory, 'src/main.ts'), 'uncommitted');
    await writeFile(path.join(config.sourceDirectory, 'untracked.txt'), 'not part of revision');
    const snapshot = await importRepository(config);
    expect(snapshot.files.find(f => f.path === 'src/main.ts')?.content).toBe('const base = 1;\n');
    expect(snapshot.files.some(f => f.path === '.env' || f.path === 'untracked.txt')).toBe(false);
    expect(snapshot.files.find(f => f.path === 'binary.bin')?.reason).toBe('binary');
    expect(snapshot.files.find(f => f.path === 'large.txt')?.reason).toBe('too-large');
  }, 20000);
  it('rejects a mismatched repository, unpermitted branch and included Git configuration', async () => {
    const { config, git } = await fixture();
    await expect(importRepository({ ...config, githubUrl: 'https://github.com/example/other' })).rejects.toThrow('does not match');
    await expect(importRepository({ ...config, branch: '../main' })).rejects.toThrow();
    await git('config', 'include.path', 'E:/not-permitted');
    await expect(importRepository(config)).rejects.toThrow('Included');
  }, 20000);
  it('refuses junction source paths and redirected object databases', async () => {
    const { config } = await fixture();
    const folder = await mkdtemp(path.join(root, 'jess-junction-')); const alias = path.join(folder, 'alias');
    await symlink(config.sourceDirectory, alias, 'junction');
    await expect(importRepository({ ...config, sourceDirectory: alias })).rejects.toThrow('Redirected');
    await writeFile(path.join(config.sourceDirectory, '.git/objects/info/alternates'), 'E:/outside/objects');
    await expect(importRepository(config)).rejects.toThrow('External Git');
  }, 20000);
});
