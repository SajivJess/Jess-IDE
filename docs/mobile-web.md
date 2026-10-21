# Mobile web milestone

## Architecture assessment

The existing portal is a small Node HTTP gateway serving HTML, CSS and browser JavaScript. It already provides a separate password login, an eight-hour HttpOnly session, fixed server-side ownership and an allowlist over the Fastify API. Fastify, PostgreSQL, the leased worker and the Antigravity adapter remain the backend. No second API or frontend framework is needed for this milestone.

The original portal only remembered projects/tasks in localStorage. Fastify had create-project, get-project, submit-task, get-task, cancel, event replay and SSE routes, but no list endpoints. The gateway deliberately did not expose SSE. The first mobile milestone added bounded list endpoints. The subsequent review-workspace milestone adds migration 002 and scoped snapshot APIs; see [the current architecture and API plan](workspace-architecture.md).

`remote/api.js` is the same-origin transport; `remote/api.d.ts` declares its contract using backend domain types. `remote/state.js` owns session, projects, tasks, pagination, selection, event cursor and request lifecycle independently of the DOM. `remote/app.js` renders text safely and binds views. `remote/style.css` defines reusable theme tokens. A future native app can reuse the HTTP contract and design, while implementing its own client and platform secure storage.

## Functional scope

- Home is the default screen, with a saved profile greeting, project creation, Continue working, owned project/repository/conversation search, actual metadata and grid/list/name/activity controls. Home has no bottom navigation.
- Opening a project restores Chat, with a responsive conversation drawer/sidebar, project switching, title/content search, rename/archive/restore, safe Markdown/code rendering, copy controls and a pinned unsent-draft composer.
- The existing task composer and project picker remain available at `#compose` through Tasks → New task and legacy project actions.
- Projects with creation and paginated server history. A project currently groups tasks; it is not a configurable Git checkout.
- Tasks with paginated history, status, cancellation, events, check results, file-change summaries and unified diffs when supplied by a result. Simulated results are explicitly labeled.
- Files provides owned review snapshots, browsing, text editing, conflict-aware saves and actual per-file diffs. These are registered committed bases plus manual edits, not live host files or agent output.
- Settings, reached from the Chat overflow or other pages' header, retains connection details, theme, sign-out, install guidance and the current agent/approval limitations.
- Light/dark/system themes, persistent bottom navigation, responsive desktop layout, accessible form labels, keyboard-operable detail tabs, visible focus and reduced-motion support.

Home has no bottom navigation; the existing workspace destinations remain Chat, Projects, Tasks and Files. Chat restores owned conversation history and recorded native session labels; details holds portable context notes and Markdown downloads. Actual CLI replies can be recorded through the explicit local relay. Public message dispatch remains disabled. See [the Home contract](home-launcher.md), [chat relay contract](chat-relay.md) and [chat-first design implementation](chat-ui-design.md).

## HTTP contract

All browser requests use the current origin and its Secure/HttpOnly/SameSite cookie. A native client should send the exact configured Origin on POST and PUT, retain the Secure cookie bound to that origin, and never receive the backend development token. The server continues to enforce authentication and its configured owner.

| Gateway endpoint | Method | Request | Response / behavior |
| --- | --- | --- | --- |
| `/login` | POST | `{ password }` | `{ ok: true }` plus secure session cookie |
| `/session` | GET | — | `{ ok: true, user: { displayName }, capabilities }` |
| `/profile` | PUT | `{ displayName }` | Saved authenticated workspace display name; does not change the owner |
| `/api/workspace/home` | GET | `sort=recent|name`, bounded `offset` | Owned metadata, real total count, up to 50 projects, recent project/conversation |
| `/api/workspace/search` | GET | `q`, 2–100 trimmed characters | At most 20 owned project/conversation matches, including repository and message-content matches |
| `/api/projects/:id/open` | POST | Optional `{ conversationId }` | Validates ownership/project association and saves the most recent visit |
| `/logout` | POST | — | Revokes cookie session |
| `/api/ready` | GET | — | Backend/database readiness |
| `/api/projects` | GET | `limit` 1–50 (default 20), optional `before` UUID | `{ projects, nextCursor }` |
| `/api/projects` | POST | `{ name }`, 1–100 characters | Created project |
| `/api/tasks` | GET | Same pagination parameters | `{ tasks, nextCursor }` |
| `/api/tasks` | POST | `{ projectId, prompt }`, prompt 1–8,000 characters, `Idempotency-Key` | `{ task, replayed }`; denied when real agent configured |
| `/api/tasks/:id` | GET | — | Task including optional result |
| `/api/tasks/:id/cancel` | POST | — | Updated task; cancellation can be pending |
| `/api/tasks/:id/events` | GET | `after` sequence, `limit` 1–100 | Events, next cursor, hasMore, task status |

List pages sort by `(created_at DESC, id DESC)`. Cursors identify the last row, with the tuple comparison performed in PostgreSQL to preserve timestamp precision. Cursors must belong to the authenticated owner. Queries are parameterized and pages have fixed bounds. Existing per-item ownership checks remain unchanged. Unknown gateway query parameters cannot override the owner or credentials.

Capabilities are `{ taskSubmission, agentMode, files: true, fileStorage: 'review-snapshot', gitApprovals: false, eventTransport: 'replay' }`. `agentMode` is `simulated` or `local-only`; the existing default provider remains fake. Disabling a button is only presentation: the gateway's existing server-side denial remains authoritative.

## Progress, reconnects and storage

The app refreshes while visible every ten seconds and immediately on reconnect/resume or manual refresh. It uses the existing replay endpoint with the last sequence; duplicate events are merged and at most 500 are retained in memory. A selected task receives one event page per refresh, with a manual Load more control for backlog. There is no open SSE connection in the public portal. The API's loopback SSE route remains untouched.

On reload, project/task history is restored from PostgreSQL; the current detail selection and composer draft are not persisted. Recent list pages refresh automatically; an older task is refreshed when opened. Further history is loaded explicitly. A new tunnel hostname can see the same owner's history after sign-in.

Task submission is explicit, single-flight and uses one idempotency key for retries of the same prompt/project within the current page session. Nothing automatically resubmits on reconnect. A reload discards an unresolved submission key: inspect task history before submitting the same instruction again. Project creation has no idempotency endpoint; inspect the list after an ambiguous failure before recreating it.

Passwords are cleared from the form immediately. Session cookies are inaccessible to browser JavaScript. Project/task content lives only in page memory and on the server, not in localStorage; the old portal's local history is removed when opening this version. Only theme and Enter-key preferences are persisted. Session expiry clears state and in-flight stale responses cannot restore it. If logout fails offline, the screen locks and explains that server revocation still needs a successful sign-out. This remains a single-owner development identity model.

## PWA preparation

The manifest uses a same-origin SVG icon and standalone display. The service worker caches only a generic offline document. API responses, passwords, cookies, workspace content and application HTML are never added to Cache Storage. Navigation is network-first and falls back to the generic offline page. There is no offline task submission or background synchronization.

Install prompting depends on browser support and eligibility; no installation on the user's phone is claimed. Temporary Cloudflare hostnames make a home-screen installation short-lived. A stable HTTPS hostname is the appropriate next step for lasting installation. PNG/maskable icons and iOS-specific installation QA can follow if needed.

## Review workspace APIs and remaining execution boundary

[The current architecture/API plan](workspace-architecture.md) specifies local repository registration, snapshot list/read/write/diff endpoints, quotas, conflict semantics and the planned OS isolation and Git approvals. Public real-agent submissions remain blocked. Live task-attempt worktrees and actual agent output are not connected to these snapshots.

## Editor research from the preceding Android assessment

No Android file-manager code was imported. The web review editor now uses CodeMirror 6 with a local esbuild bundle. [MTExplorer](https://github.com/r0ld3x/MTExplorer) declares MIT but is a small project (the inspected GitHub page showed seven commits); its dependency list includes Sora, Compose, Navigation, DataStore and Coil. Its app-level license does not replace dependencies' licenses. [Sora Editor](https://github.com/Rosemoe/sora-editor) declares LGPL-2.1-or-later and its published release history includes ongoing fixes. Native Sora integration needs a separate dependency/license assessment and is deferred with Android. CodeMirror is MIT-licensed; jsdiff, used server-side, is BSD-3-Clause. Locked dependency versions and retained license notices are part of the build.

## Local validation

All runtime tooling, browser downloads, temporary profiles and reports are on E:. Run `scripts/test-mobile-web.ps1` from this laptop. It sets E-drive temp/cache/browser paths, starts PostgreSQL only if needed, runs `npm run check` and the Playwright browser suite, and stops only the database it started. Browser tests use a disposable schema in `TEST_DATABASE_URL`, a test-only password, loopback services and the real gateway/API/worker; no tunnel is opened. The browser server shuts down and drops its schema through the teardown handshake on Windows.

Frontend HTML/application ES modules/CSS are served directly. `npm run build` compiles the TypeScript backend and bundles CodeMirror into `dist/remote/editor.js` and safe Markdown rendering into `dist/remote/markdown.js`. Run it before serving the updated editor or chat renderer. Screenshots are under `.local/mobile-preview/`; Playwright failure artifacts are under `.local/browser-results/`. Both are Git-ignored. Test commands fail if required database coverage cannot run. See [the verification report and exact file inventory](mobile-web-verification.md).

The next product milestone is enforceable execution isolation, followed by authenticated agent artifact import and explicit Git approvals. The Android project is postponed; no APK is produced by this web milestone.
