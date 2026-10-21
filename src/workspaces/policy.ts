import { createHash } from 'node:crypto';
import { HttpError } from '../domain.js';

export const MAX_FILE_BYTES = 65536;
export const MAX_SNAPSHOT_BYTES = 4 * 1024 * 1024;
export const MAX_FILES = 500;

export function workspacePath(value: string, directory = false): string {
  if (directory && value === '') return '';
  if (!value || value.length > 300 || value.includes('\\') || value.includes('%') || value.startsWith('/') || value.endsWith('/')) throw new HttpError(400, 'INVALID_PATH');
  for (const part of value.split('/')) {
    if (!/^[A-Za-z0-9_@(). +\-]+$/.test(part) || part === '.' || part === '..' || /[. ]$/.test(part) ||
      /^(con|prn|aux|nul|com[0-9]|lpt[0-9])(?:\.|$)/i.test(part)) throw new HttpError(400, 'INVALID_PATH');
    if (/^(\.git.*|\.env.*|\.ssh|\.aws|\.azure|\.codex|\.gemini|\.agents|node_modules|\.local|\.npmrc|\.netrc)$/i.test(part) ||
      /\.(pem|key|p12|pfx|keystore)$/i.test(part) || /^(credentials|id_rsa|id_ed25519)(\.|$)/i.test(part)) throw new HttpError(403, 'PROTECTED_PATH');
  }
  return value;
}
export function textContent(content: string): string {
  if (Buffer.byteLength(content, 'utf8') > MAX_FILE_BYTES) throw new HttpError(413, 'FILE_TOO_LARGE');
  if (/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/.test(content) || content.includes('\uFFFD')) throw new HttpError(415, 'UNSUPPORTED_TEXT');
  // Reject unmatched UTF-16 surrogates so hashing and database UTF-8 storage agree.
  if (Buffer.from(content).toString('utf8') !== content) throw new HttpError(415, 'UNSUPPORTED_TEXT');
  return content;
}
export const hash = (content: string): string => createHash('sha256').update(content).digest('hex');
export const etag = (version: number, content: string): string => `"${version}-${hash(content)}"`;
export interface SnapshotFile { path: string; content: string | null; reason: string | null; size: number }
export interface RepositorySnapshot {
  name: string; githubUrl: string; branch: string; baseCommit: string; sourceDirectory: string; files: SnapshotFile[];
}
