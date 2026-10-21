import { HttpError } from '../domain.js';

// A conservative export filter, not a guarantee that arbitrary prose contains no
// secrets. Raw CLI internals/tool parameters/thinking are never journalled.
export function redactor(secrets: string[] = []): (text: string) => string {
  const known = secrets.filter(value => value.length >= 8).sort((a, b) => b.length - a.length);
  return text => {
    for (const secret of known) text = text.split(secret).join('[REDACTED]');
    return text.replace(/-----BEGIN [^-]*PRIVATE KEY-----[\s\S]*?-----END [^-]*PRIVATE KEY-----/g, '[REDACTED PRIVATE KEY]')
      .replace(/\b(?:gh[pousr]_[A-Za-z0-9_]{16,}|github_pat_[A-Za-z0-9_]{16,}|AIza[A-Za-z0-9_-]{25,}|sk-[A-Za-z0-9_-]{16,}|4\/0A[A-Za-z0-9_-]{20,})/g, '[REDACTED]')
      .replace(/\bBearer\s+[A-Za-z0-9._~+\/-]+=*/gi, 'Bearer [REDACTED]')
      .replace(/((?:password|api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|DEV_AUTH_TOKEN)\s*[=:]\s*)(?:"[^"]*"|'[^']*'|[^\s,;]+)/gi, '$1[REDACTED]')
      .replace(/(\b[a-z][a-z0-9+.-]*:\/\/)[^\s/@]+:[^\s/@]+@/gi, '$1[REDACTED]@');
  };
}
export function boundedText(value: string, maxBytes: number): string {
  if (typeof value !== 'string' || Buffer.byteLength(value) > maxBytes) throw new HttpError(413, 'TEXT_TOO_LARGE');
  if (Buffer.from(value).toString('utf8') !== value || /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/.test(value)) throw new HttpError(400, 'INVALID_TEXT');
  return value;
}
export function environmentSecrets(env: NodeJS.ProcessEnv): string[] {
  const values = Object.entries(env).filter(([key]) => /TOKEN|SECRET|PASSWORD|API_KEY|DATABASE_URL/.test(key)).map(([, value]) => value ?? '');
  for (const key of ['DATABASE_URL', 'TEST_DATABASE_URL']) try { values.push(decodeURIComponent(new URL(env[key] ?? '').password)); } catch { /* Not configured. */ }
  return values;
}
