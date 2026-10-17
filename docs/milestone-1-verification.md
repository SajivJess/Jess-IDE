# Milestone 1 verification

Verified in Codex Cloud on 17 October 2026 with Node.js 24.19.0, npm 11.9.0 and a real local PostgreSQL 17 container. The database ran on loopback port 55432. Its generated credentials were kept outside the repository and were not printed or committed.

## Final results

| Check | Result |
| --- | --- |
| Strict TypeScript check | Passed |
| ESLint, zero warnings | Passed |
| Vitest | 27 passed, 0 failed, 0 skipped |
| Real PostgreSQL integration tests | 22 passed |
| Configuration/HTTP boundary tests | 5 passed, including an actual refused database connection |
| Compiled TypeScript build | Passed |
| Source and compiled migration CLI | Passed; repeat application was idempotent |
| Compiled API and worker via npm scripts | Passed; separate processes completed a persisted fake task |
| Dependency audit, including development dependencies | 0 known vulnerabilities reported |

The real database suite covers creation/retrieval, concurrent idempotency, ownership boundaries, input/size validation, task lifecycle and event sequence, replay, actual HTTP SSE disconnect/reconnect, cancellation, competing claims, expired leases, stale worker fencing, retry exhaustion, heartbeats, graceful worker interruption, safe adapter errors, a terminated test DB connection, a real lock-timeout failure followed by worker recovery, and separate source API/worker processes.

The agent always simulated work. These results do not mean an AI agent edited repository files or executed application checks.

## Commands executed

Inspection included `git clone`, `git status`, Node/npm/Git versions, package version/peer metadata, the managed Docker daemon health check, and file inventories. PostgreSQL was started with `docker run` using an external private environment file, loopback-only port publication and `postgres:17-alpine`; readiness was checked with `docker exec ... pg_isready`.

Repository commands:

```text
npm install
npm run typecheck
npm run lint
REQUIRE_DATABASE_TESTS=1 npm run check
npm audit --omit=dev --audit-level=moderate
npm audit --audit-level=moderate
npm ls --depth=0
npm run db:migrate
npm run db:migrate:built
npm start
npm run start:worker
git diff --check
```

The full check expands to typecheck, lint, tests and build. The initial typecheck caught an overly narrow inferred test-helper argument; it was corrected before the final passing run. The compiled npm start commands were exercised by a temporary in-memory smoke harness that created a project/task through HTTP, observed the separate worker's completion, then stopped both processes. No harness credential was printed or saved in source.

Tests without PostgreSQL are explicitly skipped when `TEST_DATABASE_URL` is absent; `REQUIRE_DATABASE_TESTS=1` makes that omission fail instead. No mock database was used to represent successful integration coverage.

## Not run / not implemented

Antigravity installation/authentication/execution, real AI provider calls, untrusted workspace execution, production identity, mobile application checks, cloud workspace provider tests and production deployment were not run or implemented. Public access is intentionally disabled. No reference documents were copied into application source; the two existing planning files outside the repository were left untouched.

Use the README for setup and limitations. The verification describes this environment and does not promise the test database or background containers will persist when Codex Cloud replaces it.
