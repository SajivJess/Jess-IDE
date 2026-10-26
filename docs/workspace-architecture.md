# Review workspaces and execution boundary — 18 October 2026

The later [chat-first UI milestone](chat-ui-design.md) preserves this snapshot boundary. It adds conversation navigation/metadata and response presentation; it does not bind chat turns to task artifacts, enable remote execution or add Git approval endpoints.

The [Home launcher](home-launcher.md) adds owned project metadata/search and visit restoration in migration 005. Repository details come from owned conversation bindings; this does not expose a host path, import arbitrary repositories or change execution permissions.

## Assessment and implementation decision

The existing Fastify API, durable PostgreSQL queue, worker, native Antigravity adapter and password gateway remain in place. The previously uncommitted mobile portal is preserved. It uses browser ES modules, not React. The initial gaps were repository registration, owned file storage, conflict-safe writes, and an execution sandbox. The UI had a placeholder Files screen, an oversized decorative activity card, no composer shortcuts, and no task-history filtering.

This milestone implements a complete **review-only snapshot** flow: explicit local repository registration → immutable committed base → dedicated snapshot for a finished task → authenticated list/read/edit/diff. It does not connect these snapshots to execution. This is a deliberate narrower boundary than a live Windows filesystem editor: HTTP handlers never resolve or open host file paths, run Git, or execute commands. A separate Git clone or CLI permission setting does not provide OS isolation.

The snapshot represents the registered base plus manual browser edits. It is **not** the Antigravity task's output, a live checkout, or a task-attempt execution directory. Existing task result diffs/checks remain available separately under Tasks. Those checks do not validate later snapshot edits. No new project/task is required just to register a repository.

## Registration and storage

Migration `002_review_workspaces.sql` adds immutable repository metadata/files, task-associated review workspaces, mutable snapshot files and an edit-hash audit trail. All data uses the existing E-drive PostgreSQL instance. There is no public registration or host-path endpoint.

A local administrator supplies an E-drive JSON configuration:

```json
{
  "name": "Jess-IDE",
  "githubUrl": "https://github.com/SajivJess/Jess-IDE",
  "branch": "main",
  "sourceDirectory": "E:\\Jess-IDE"
}
```

After applying migrations, run from the repository with the configured owner's UUID:

```powershell
node --env-file=.env --import tsx src/tools/register-repository.ts E:\Jess-IDE\.local\repository-registration.json <owner-uuid>
```

Use the existing gateway owner, without exposing its password or backend token. Registration is explicit, not automatic on startup. Each registration is an immutable version; repeating the command creates another registration and consumes quota. The importer verifies the configured GitHub identity against local `origin`, resolves only the permitted local branch, then reads committed objects by SHA. It does not clone, fetch, read dirty worktree contents, execute repository hooks, or contact GitHub. A local `origin` string is an administrator assertion, not remote proof that the commit exists on GitHub.

Source ancestors and the Git directory are checked for links/redirection. Linked/hardlinked Git metadata, alternate object stores, included configuration and partial clones are refused. Git runs with a minimal environment, global/system configuration disabled, lazy fetch disabled and external protocols prohibited. Committed symlinks/submodules are metadata only; their targets are never opened. Protected paths, including `.env*`, `.git*`, common credential files and agent profile directories, are excluded. This filename policy is not a universal secret scanner: administrators must only register reviewed repositories suitable for this account. Nonportable filenames are omitted rather than rewritten.

The importer is a trusted local-admin operation. It is not safe against a hostile process concurrently replacing the administrator's Git database between checks. Public callers and repository contents cannot invoke it. The HTTP storage boundary does not depend on these filesystem checks: after import, it accesses only database rows. Future live-file/export support requires an independently enforced filesystem boundary; do not reuse this importer as a sandbox.

## API contract

The gateway prefixes these routes with `/api`. All require its HttpOnly session; mutations require the exact configured Origin. The loopback API requires the existing development token and fixed owner supplied by the gateway. Both task/project ownership and registered-repository ownership must match; missing and foreign objects return 404. Absolute host paths and owner overrides are never accepted.

| Route | Method | Behavior |
| --- | --- | --- |
| `/repositories` | GET | Registered revisions for the authenticated owner; host directory excluded |
| `/workspaces` | GET | Up to 50 owned review workspaces |
| `/tasks/:id/workspace` | POST | `{repositoryId}`; creates one snapshot for a COMPLETED, FAILED or CANCELLED task; same binding is idempotent; rebinding/active task returns 409 |
| `/workspaces/:id` | GET | Repository, branch, immutable base SHA, task, revision and `mode: review-only` |
| `/workspaces/:id/files` | GET | Relative `path` (empty root) and `offset`; immediate children, at most 100/page, nullable `nextOffset` |
| `/workspaces/:id/file` | GET | Relative `path`; UTF-8 content, byte size, version and quoted version/hash `etag` in JSON |
| `/workspaces/:id/file` | PUT | `{path,content}` and exact `If-Match`; modifies an existing text snapshot file only |
| `/workspaces/:id/diff` | GET | Relative `path`; bounded unified diff against registered base, branch/SHA, changed/truncated flags and `approvalAvailable:false` |

Status codes include 400 malformed input/path, 403 protected path, 404 foreign/missing object, 409 stale revision/state/quota, 413 byte/body limits, 415 unsupported text/binary/link, 428 missing revision, 429 rate limit and 503 unavailable database. Failures do not expose source paths, SQL or credentials.

Limits: 64 KiB UTF-8/file, 4 MiB editable content/snapshot, 500 imported tree entries, 300-character relative paths, 10 registrations/owner, 50 workspaces/owner and 1,000 successful edits/workspace. Read-only oversized/binary entries expose metadata only. PUT bodies are capped at 400,000 bytes to accommodate JSON escaping within the decoded-file limit. Diffs are limited to 100 ms of diff work, 4,000 edits and 200,000 output characters; incomplete previews say so. Existing API rate limits also apply. Quotas currently require local administration to reclaim; there is no deletion endpoint.

Paths reject traversal, absolute/drive/UNC paths, backslashes, percent escapes, ADS colons, Windows devices, trailing dots/spaces, protected segments, case aliases and file/directory collisions. UTF-8 text rejects binary controls and malformed surrogates. Registration detects ambiguous names before any database write. Runtime paths are identifiers within an owned snapshot, never filesystem destinations.

Save transactions lock the workspace and file, compare the client's version/hash, enforce aggregate size, update both revisions and record before/after hashes atomically. Concurrent saves based on the same version produce one success and one conflict. The immutable base stays unchanged. The audit table contains hashes, not a complete reversible edit history or tamper-proof administrator audit log.

## Mobile integration

Files supports repository/task selection, snapshot creation, workspace selection, breadcrumbs, directory name filtering, name/type sorting, read-only metadata for unsupported files, and an editor for existing text files. CodeMirror provides line numbers, syntax highlighting for JS/TS/JSON/HTML/CSS/Markdown, find/replace, undo/redo and keyboard editing. Other valid text remains editable without a language parser. The bundled dependencies are MIT-licensed; their license texts are collected into `dist/remote/editor-licenses.txt`, served through a fixed public asset path, and legal comments are retained by esbuild. No Android file-manager code was copied.

Editor drafts live in memory and survive navigation between app tabs. Saving sends `If-Match`; a conflict preserves the draft and requires an explicit reload/discard decision. Switching files/workspaces and closing the page warn about dirty content. Browser/OS termination can still lose an unsaved draft. Session expiry clears content and rejects late responses. The PWA caches only the generic offline page, never source files or API replies. CodeMirror-generated styles use a fresh CSP nonce; script policy remains same-origin with no `unsafe-inline` allowance.

The existing UI now defaults to charcoal/violet dark mode, with Light and System settings, semantic colors, compact activity information, composer shortcuts and loaded-history search/status filters. No fake activity or test results were added. File create/rename/move/delete, content search across files, pinning, binary previews, a workspace-wide changed-files index and Git approval controls remain deferred. Repository registrations are fixed revisions; the UI cannot import arbitrary repositories or modify the source checkout.

## Enforceable execution isolation — design, not implemented

The native Antigravity process still runs as the Windows user. It must remain local-only for trusted development. Do not enable public submission based on a successful native runner test or the snapshot API.

The proposed Windows deployment boundary is a dedicated Hyper-V guest per execution, with virtual disks/checkpoints on E:, a restricted guest account, and a host-side broker. No host filesystem shares, drive redirection, clipboard, host credential stores, Docker socket or general host command channel should be available. Keep host PostgreSQL/API on loopback and firewall them from the guest. The guest must not obtain the portal token, GitHub push credential, database password or host Antigravity profile. Hyper-V availability, Windows edition, virtualization support and permitted CLI guest authentication remain unverified.

Provision a reviewed immutable guest image and materialize only validated snapshot files on its private disk. The broker allocates CPU/RAM/disk/process/time budgets and kills the whole guest on timeout/cancel, then revokes temporary access. Default-deny outbound networking should be enforced outside the guest; permit only the chosen provider and approved dependency endpoints through a controlled proxy. Dependency install/build/test commands are untrusted and run inside this boundary. Store virtual disks, logs, package caches and temporary files on E:.

An authenticated, bounded broker channel should exchange task events and artifacts, never arbitrary host shell commands. Bind messages to owner/task/attempt/base SHA and monotonically ordered events. Validate exported file names, types, counts, bytes and content again; reject links/reparse points, special files, traversal, duplicate/case aliases and protected paths. Import output into a new review revision, leaving the original base unchanged. Execution output is untrusted text; redact secrets and render it inertly. No agent output authorizes a host action.

Before enabling public execution, prove denial of host-drive/credential/API access, blocked outbound destinations, resource exhaustion, malicious links and archive paths, cross-owner access, forged/replayed events and orphaned processes. Also prove cancellation and recovery after guest/host interruption. Record reproducible adversarial tests on this laptop and require an explicit configuration gate separate from provider selection. None of those OS-enforcement tests is claimed by this milestone.

Windows Sandbox is another possible boundary, but its defaults require care: Microsoft documents configuration controls for networking, clipboard and mapped folders. A `.wsb` file or separate Git clone alone is not evidence of safe deployment. See [Microsoft's configuration reference](https://learn.microsoft.com/en-us/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-configure-using-wsb-file). The importer relies on [Git object reads](https://git-scm.com/docs/git-cat-file), not a live filesystem proxy.

## Git approval contract — proposal only

There are no commit/push/merge endpoints in this milestone. Proposed review preparation (`POST /workspaces/:id/git-actions`) would accept an allowlisted action enum and task branch, never Git arguments or a shell command. The server would generate a canonical manifest binding owner, repository identity, base SHA, workspace revision, ordered file hashes/modes, diff hash, actual check results with their revision, operation and exact destination branch/remote head.

The phone would display that manifest and request explicit user confirmation. `POST /git-actions/:id/approve` would bind a short-lived, single-use approval to its manifest hash, authenticated owner and exact operation. The executor would lock the workspace, revalidate every hash/revision and expected remote head, consume approval atomically and append an auditable result. Any edit, new attempt, branch change, expired approval or remote-head mismatch invalidates the approval and requires another review. A commit and a push are separate operations and approvals; no automatic merge or force push.

Git credentials belong only to a narrow broker capable of pushing the explicitly approved task branch. They must never be exposed to the agent or browser. Network failures need idempotent reconciliation against the exact commit and branch, not blind repeated pushes. Production-quality identity/session protections, branch policy, safe export, credential provisioning and this executor remain blockers.
