# Jess Ide Dev — Backend Foundation

Milestone 1 implements a development-only Fastify API, PostgreSQL persistence and a separate durable worker. It supports owned projects, queued coding tasks, cancellation, ordered events and reconnectable delivery.

The `fake-v1` agent is a deterministic simulation. Its sample files and check results are labelled simulated: **it does not change files, execute commands, run project tests or call an AI provider**. Antigravity is not installed, authenticated or integrated.

## Requirements

- Node.js 24 LTS and npm. Dependency versions are committed in `package-lock.json`.
- PostgreSQL 17 recommended; the implementation uses standard PostgreSQL row locks, transactions and JSONB.
- Run commands from this repository root, including the built migration command.

## Local setup

```bash
npm ci
cp .env.example .env
```

Generate a random development bearer token and place it in `.env` as `DEV_AUTH_TOKEN`:

```bash
node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"
```

Set `DATABASE_URL` to your PostgreSQL connection string. Keep `NODE_ENV=development` and `AUTH_MODE=development`. `.env` is ignored by Git and automatically loaded by the API, worker, migration and test scripts; existing environment variables take precedence. Do not share its contents.

If PostgreSQL is not already available, this command creates a local development database. The password is generated into your shell environment and is not included literally in the command:

```bash
export POSTGRES_PASSWORD="$(node -e "console.log(require('crypto').randomBytes(24).toString('hex'))")"
docker run --name jess-postgres --detach \
  --publish 127.0.0.1:5432:5432 \
  --env POSTGRES_USER=jess --env POSTGRES_DB=jess --env POSTGRES_PASSWORD \
  --volume jess_pgdata:/var/lib/postgresql/data postgres:17-alpine
docker exec jess-postgres pg_isready -U jess -d jess
```

Use that generated password in `.env`'s `DATABASE_URL`, with user/database `jess` and host `127.0.0.1:5432`. Wait for `pg_isready` to report accepting connections. The named volume persists local data; do not delete it unintentionally. Protect Docker access, which can reveal container credentials. `unset POSTGRES_PASSWORD` once configured.

Apply migrations, then start the processes in separate terminals:

```bash
npm run db:migrate
npm run dev
```

```bash
npm run dev:worker
```

For compiled execution:

```bash
npm run build
npm run db:migrate:built
npm start
# Separate terminal:
npm run start:worker
```

The API listens only on `127.0.0.1`, port 3000 by default. Development identity assertions are intentionally unsuitable for public deployment. Access from a phone requires a trusted development connection to the Codex environment; this milestone does not provision a public endpoint, mobile client or hosting service.

## Authentication boundary

Only `GET /health` is public. All other endpoints require:

```text
Authorization: Bearer <DEV_AUTH_TOKEN>
X-Dev-User-Id: <UUID>
```

The token grants access to a **trusted local test harness** in which users can assert test identities. It does not authenticate an individual end user. An authenticated caller can deliberately select another test UUID; this mechanism must never be exposed as production identity. A real identity provider must replace it before public access.

Startup refuses missing/unknown `NODE_ENV`, `NODE_ENV=production`, a mode other than `AUTH_MODE=development`, missing/short tokens and the sample token placeholder. The API bind is fixed to loopback. Ownership comes from the authenticated development identity, never request body fields. Foreign and nonexistent resources both return 404.

## API

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/health` | Process liveness; no database dependency |
| GET | `/ready` | Authenticated database connectivity check |
| POST | `/projects` | Create `{ "name": "My project" }` |
| GET | `/projects/:id` | Retrieve an owned project |
| POST | `/tasks` | Submit `{ "projectId": "<uuid>", "prompt": "..." }` with `Idempotency-Key` |
| GET | `/tasks/:id` | Retrieve owned task state/result |
| POST | `/tasks/:id/cancel` | Request cancellation; no body needed |
| GET | `/tasks/:id/events?after=0&limit=100` | Durable event page and next cursor |
| GET | `/tasks/:id/events/stream` | SSE, optionally with `Last-Event-ID` or `?after=N` |

Example using the credentials already in `.env` without putting the token literally in shell history:

```bash
# Only source a trusted file you created yourself.
set -a
. ./.env
set +a
export JESS_TEST_USER=00000000-0000-4000-8000-000000000001
curl --silent --show-error http://127.0.0.1:3000/projects \
  -H "Authorization: Bearer $DEV_AUTH_TOKEN" \
  -H "X-Dev-User-Id: $JESS_TEST_USER" \
  -H 'Content-Type: application/json' \
  -d '{"name":"Phone prototype"}'
```

Use the returned project ID in the task request and supply a unique `Idempotency-Key`. Prompts are text, not shell commands. The API accepts no executable or arbitrary command field. Client-side token handling and production identity are outside this milestone.

Requests and responses use JSON schemas. Limits: 16 KiB request bodies, 8,000-character prompts, 100-character project names, 128-character idempotency keys, and event pages of at most 100 items. Invalid properties are rejected, not silently removed. Requests have 10-second network timeouts and a 120-request/minute per-IP in-memory limit. Database connections and queries have bounded timeouts. Logs omit headers, request bodies, prompts, connection strings and exception details; operational failures use fixed categories.

### Task and retry semantics

`QUEUED → RUNNING → COMPLETED | FAILED | CANCELLED`

- Submission inserts the task/job and `TASK_QUEUED` event in one transaction. No API process performs agent work.
- Idempotency keys are scoped to a project and retained with the task. Same key + same exact prompt returns the original task with `replayed: true`; changed prompt returns 409. Both fresh and replayed submissions return 202.
- Workers use `FOR UPDATE SKIP LOCKED` to claim jobs, with a random fencing token, a lease and heartbeats. Competing workers cannot claim the same unexpired task.
- A crashed or disconnected worker leaves a durable RUNNING task. After its lease expires, another worker retries it, emits `TASK_RETRYING`, and increments its attempt. Maximum three execution attempts; further recovery marks it FAILED.
- Database errors preserve recoverable work rather than converting an uncertain outcome into a successful task. Stale lease tokens cannot append progress or finalize a reclaimed task.
- Adapter failures are terminal with a generic `AGENT_EXECUTION_FAILED` error. There is no automatic retry of known agent errors in this milestone.
- Recovery can repeat progress from an earlier attempt; events include attempt numbers. Execution is **at least once**, not exactly once. This is safe for the deterministic fake agent; real filesystem/external side effects need checkpoint/reconciliation policies before integration.
- SIGINT/SIGTERM abort the fake agent, release its lease for retry and close the worker pool. Abrupt termination relies on expiry.
- Cancellation of a queued task is immediate. Running cancellation is cooperative at the fake agent's next safe boundary or heartbeat; a crash is reconciled after expiry. Repeated cancellation is idempotent. A cancellation recorded before finalization wins; cancellation after a terminal state leaves it unchanged.

### Event replay

Each task has a transactionally allocated, gap-free committed event sequence starting at 1. State changes and their events commit together. HTTP replay returns `events`, `nextCursor`, `hasMore` and `taskStatus`. Store the highest applied sequence and reconnect with `after=N`. A future cursor returns 400. Events are currently retained indefinitely.

SSE emits `id: <sequence>`, `event: task_event` and a JSON event envelope. Supply bearer/identity headers using a streaming HTTP client; browser `EventSource` cannot add these custom headers by itself. `Last-Event-ID` overrides `after`. SSE polls committed PostgreSQL events every 500 ms, sends heartbeat comments, ends after a terminal task or 30 seconds, and supports reconnect. Limits are three streams per test identity and 20 per API process; there is no long-held database transaction. On interruption, reconnect from the last processed ID. Disable proxy buffering in any future trusted development proxy.

## Configuration

| Variable | Required/default | Meaning |
| --- | --- | --- |
| `NODE_ENV` | Required: `development` or `test` | Production startup is disabled |
| `AUTH_MODE` | Required: `development` | Explicit local test authentication |
| `DEV_AUTH_TOKEN` | Required: random 32–256 non-whitespace characters | Shared local-development bearer token |
| `DATABASE_URL` | Required | PostgreSQL application database |
| `PORT` | 3000 | Loopback API port |
| `WORKER_POLL_MS` | 500 | Empty queue/error polling interval, 50–10,000 ms |
| `WORKER_LEASE_MS` | 15000 | Lease duration, 3,000–120,000 ms |
| `FAKE_AGENT_STEP_MS` | 250 | Delay per simulated step, 0–5,000 ms |
| `TEST_DATABASE_URL` | Required for DB integration tests | Dedicated disposable PostgreSQL test database |
| `REQUIRE_DATABASE_TESTS` | Optional: `1` | Fail rather than skip when the test DB URL is absent |

Migration CLI requires only `DATABASE_URL`, not development authentication. Migrations are transactional, serialized with an advisory lock, and recorded with checksums. They are explicit, not automatically applied by the API/worker. Keep the `migrations/` directory beside the source/build distribution and run from the repository root. Use a separate privileged migration identity and a restricted runtime role for future hosted deployments.

## Tests and checks

```bash
npm run typecheck
npm run lint
npm run build
npm test
```

Without `TEST_DATABASE_URL`, database integration tests are explicitly **skipped**. Configuration/liveness/auth tests and a refused-connection error test still run; these are not presented as successful database integration tests.

For real PostgreSQL integration tests, create a separate disposable database:

```bash
docker exec jess-postgres createdb -U jess jess_test
```

Set `TEST_DATABASE_URL` in `.env` to the same local server credentials but database `jess_test`, then run:

```bash
REQUIRE_DATABASE_TESTS=1 npm run check
```

Tests create a randomly named schema, apply real migrations, exercise the real database and drop only that schema afterward. The test DB role needs schema creation and permission to terminate its own test connection. Never point this setting at production. Worker crash recovery tests deliberately expire leases; a real connection-loss test terminates only a connection opened by that test. SSE tests use actual loopback HTTP rather than mocked streams.

## Structure

```text
src/api/       Fastify routes, schemas, development authentication, process entry point
src/db/        Pool, migrations runner, transactional data access and durable claims
src/agents/    Provider-independent interface and fake-v1 implementation
src/worker/    Worker loop, heartbeats and separate process entry point
src/config.ts Explicit startup guards and bounded configuration
src/domain.ts Public domain types and safe errors
migrations/   Versioned PostgreSQL SQL
tests/        Configuration/HTTP-boundary and real PostgreSQL integration tests
```

## Limitations and next milestone

No real identity provider, public deployment, mobile app, GitHub import/push, filesystem modification, diff generation, sandbox provisioning, actual previews, billing or Antigravity integration exists yet. Simulated results must not be presented as real builds or passing project tests. There is no claim of production readiness or complete workspace isolation: this milestone executes no repository code.

The next milestone is one isolated workspace provider and one supported agent adapter, subject to Antigravity's authentication and usage requirements. Before running untrusted code, add sandbox resource/network boundaries, credential isolation, safe checkpoint recovery, per-project execution coordination, enforceable supported approvals and authenticated preview/file access. Keep agent and cloud-specific behavior behind their respective boundaries.
