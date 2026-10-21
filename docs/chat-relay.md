# Native CLI conversations and portable project context

The current entry screen is the [Home project launcher](home-launcher.md). Project visits restore the selected conversation; the local relay and public execution boundary described below are unchanged.

## Verified capabilities and scope

The installed `E:\tools\antigravity-cli\agy.exe` advertises `--input-format stream-json`, `--output-format stream-json` and `--conversation <id>`. On 18 October 2026, a direct three-turn probe confirmed two turns in a single process, followed by a new process resuming the exact same conversation ID and recalling the marker from the first turn. A second verification exercised the new Jess relay, database journal and Markdown exporter end to end, with the same result.

The official [headless CLI documentation](https://www.antigravity.google/docs/cli/headless/) specifies NDJSON input and output, one result per turn, and explicit conversation resumption. Jess uses those mechanisms and waits for a terminal result before sending the next message. It never selects the globally most recent conversation with `--continue`.

This milestone delivers an explicit **local-only relay**, persistent project conversation views, event replay and portable Markdown. The public UI can create conversation metadata, read history, edit portable notes and download Markdown. Both gateway and API refuse public message dispatch, including when the normal task worker is configured with the simulator. The normal task adapter and background worker remain separate and unchanged. The relay does not start automatically, consume a public queue, or attach to another interactive terminal.

CLI sessions created by Jess can be resumed by their persisted native ID. Importing an arbitrary pre-existing IDE/interactive CLI session, discovering its original project safely, and transferring its native history across accounts are not implemented. A supported native resume starts another CLI process when needed; it retains the same native conversation rather than starting unrelated context.

## Data model and delivery

Migration `003_conversations.sql` adds:

- `conversations`: owned project/repository association, provider, local profile label, native session ID and journal/turn sequences.
- `conversation_turns`: stable client message UUID, original user text, delivery state, actual final response and context revision.
- `conversation_events`: ordered durable journal entries for user messages, native binding, bounded CLI progress, agent replies and delivery outcomes.
- `project_contexts`: user-authored summary/handoff notes with a revision for conflict-safe editing.

Migration `004_conversation_navigation.sql` adds archival state and a separate metadata revision. Rename/archive/restore actions append journal events; they never rewrite recorded messages. Archiving retains the native binding and transcript and refuses an actively dispatching turn. Archived conversations cannot dispatch new local turns until restored. Metadata revisions protect concurrent changes with a 409 response.

Project and registered-repository ownership must both match. Browser clients cannot choose native session IDs, profile paths, working directories, executables, tool permissions or dispatch state. A conversation's project/repository binding is immutable. Native IDs are unique within provider/profile binding; a mismatched init/result ID fails the turn.

The local runner takes a database advisory lock for the conversation and the existing exclusive `.jess-cli.lock` for its E-drive CLI profile. It starts one process for the selected batch, sends each message over stdin, and records the returned result before sending another. On a later invocation, it passes only the recorded native ID using `--conversation`.

Message UUIDs are required in the local batch file. Repeating a completed UUID returns its recorded result without another CLI call. Reusing the UUID with different text fails. A message is durably marked `DISPATCHING` before stdin write; this favors refusing an ambiguous retry over accidentally executing it twice. Timeout, disconnection or a crash can therefore yield `UNCERTAIN`, including if the CLI finished but persistence failed. These turns are never automatically resent, and further turns in that conversation are blocked. Review the situation and create a new conversation with handoff notes. There is no claim of exactly-once execution across a process/database failure.

If a local process crashes, the profile lock may remain. Verify that no native runner is alive before manually removing the stale lock. The runner does not steal it. A crash can also leave its restrictive CLI permission settings in place; review the profile before other use. Normal exit/failure restores the original settings and releases locks.

The profile binding is an explicit local account label, not an authenticated Google account identifier. Change it when switching CLI credentials; existing conversations reject a different label and require a new conversation. Automatically detecting an account change is not implemented.

## Portable Markdown

PostgreSQL provides the crash-safe append-only message/event journal. Markdown is a deterministic portable projection of that journal, independent of Antigravity's native context. Rebuilding a projection does not invent or summarize agent responses. This uses the durable-journal option rather than attempting a database/filesystem dual write with false atomicity.

The local relay materializes files under an E-drive project metadata directory:

```text
E:\local-data\jess\contexts\<project UUID>\.jess-ide\
  PROJECT_CONTEXT.md
  conversations\conversation-<conversation UUID>.md
  handoffs\latest-handoff.md
```

Transcripts contain actual user messages, sanitized actual final replies, native binding and delivery outcomes. Empty/pending turns do not get a fabricated agent response. Messages are fenced as untrusted text so their HTML or Markdown does not become active transcript formatting. Summary and handoff notes are authored explicitly through the UI; Jess does not manufacture architectural decisions or claim model-provided checks were executed.

Context notes are included only for the first turn of a new native session, together with their revision and an untrusted-data label. Resumed turns use native CLI context. Changing notes does not silently rewrite an existing native conversation. To continue under another account or IDE, create a new conversation/profile binding and supply the project summary/handoff through that agent's supported input. Older transcripts remain available when relevant; the full history is not injected into every prompt.

The files are regenerated from the journal. Direct edits to exported files are not imported automatically and may be overwritten on the next export; edit notes in the UI or explicitly provide reviewed notes to a new agent. The public download endpoints always render current journal/notes data; they do not read arbitrary paths. Public note edits are persisted immediately in PostgreSQL and appear in downloads, while disk projections refresh on the next local relay/export. A failed disk export does not roll back a native turn already recorded in PostgreSQL.

File replacement uses a fresh exclusive temporary file, flush and rename under a project export lock. Paths use generated project/conversation UUIDs. Existing directory links, redirected paths and linked destination files are refused. This is a trusted local-admin exporter, not protection against another hostile process concurrently replacing host paths. HTTP requests never materialize files on disk.

Limits: 50 conversations/project, 200 turns/conversation, batches of at most 20 selected messages, 16 KiB UTF-8/user message, 16 KiB per context note, 64 KiB/final response, 2 MiB total CLI output/turn, 64 recorded progress transitions/turn, 120-second default turn timeout, 16 MiB/transcript and 20 MiB/project disk export. History pages contain up to 50 turns; event pages contain up to 100 entries. CLI result text is delivered after completion, while actual bounded progress metadata can be replayed during execution. Token-by-token reply streaming is deferred.

## Local operation

Build, migrate and create a project conversation from the portal, then write a reviewed E-drive JSON batch with stable UUIDs:

```json
[
  { "id": "11111111-1111-4111-8111-111111111111", "content": "Explain the current project. Do not modify files." },
  { "id": "22222222-2222-4222-8222-222222222222", "content": "Summarize the main points from your previous answer." }
]
```

From `E:\cloudaiagent`, with E-drive Node/temp paths configured:

```powershell
node --env-file=.env dist/tools/chat-local.js <conversation-uuid> E:\local-data\jess\messages.json laptop-account-1
```

The local tool uses the configured portal owner and this laptop's fixed CLI/profile/export paths. It executes only the specifically supplied batch. It does not watch the phone for more messages. Reuse the same file on an ambiguous retry; do not replace message UUIDs to bypass a delivery warning.

The CLI uses plan mode and a temporary read-oriented tool policy; commands, writes and remote tools are denied by that policy. Its environment omits Jess database credentials, portal password, development token and unrelated environment secrets. This is still a process running as the Windows user and is not an OS sandbox. The existing code-changing task runner remains a distinct trusted local workflow.

## Public API and UI

All routes below use existing authentication and ownership. The gateway adds `/api`, fixes the owner/token and enforces the configured Origin on mutations. Additional query/body fields cannot select an owner, native session or host path.

| Route | Method | Behavior |
| --- | --- | --- |
| `/projects/:id/conversations` | GET | Up to 50 owned conversations, latest activity first; optional `search` matches titles and recorded prompt/response content; `archived=true` includes archived records |
| `/projects/:id/conversations` | POST | `{repositoryId,title}` creates metadata only |
| `/projects/:id/context` | GET | Current summary/handoff and revision |
| `/projects/:id/context` | PUT | `{revision,summary,handoff}`; stale revision returns 409 |
| `/projects/:id/context/export` | GET | Current project/handoff Markdown strings |
| `/conversations/:id` | GET | Owned metadata and native binding |
| `/conversations/:id` | PUT | `{revision,title}` or `{revision,archived}`; exactly one change, stale revision 409; no execution |
| `/conversations/:id/messages` | GET | Optional `before` sequence for older turns |
| `/conversations/:id/events` | GET | Optional `after` sequence for replay |
| `/conversations/:id/transcript` | GET | Generated filename and Markdown |
| `/conversations/:id/messages` | POST | Always 403 for an owned conversation; no dispatch |

Chat is the primary screen with four destinations: Chat, Projects, Tasks and Files. A mobile drawer/collapsible desktop sidebar holds project selection, recent conversations, title/content search and new conversations. Rename, archive/restore, transcript export, details and Settings are contextual actions. The conversation UUID in the URL restores history after reload without storing content or credentials in localStorage. Visible chat refreshes every three seconds; existing task replay keeps its ten-second cadence. Browser, laptop and recorded native-session states are separately labeled. Actual final responses use a safe DOM-based Markdown renderer; untrusted HTML cannot execute and image references do not trigger downloads.

Unsent message drafts and conflicting project-note edits survive conversation/project/tab switching in page memory. Scroll positions are retained per conversation, and unchanged turns keep their DOM nodes during replay. A before-unload warning protects unsaved drafts; reloading still discards them. Only theme and Enter-key preferences persist in localStorage. Conversation details holds portable notes, native IDs and exports. Session expiry clears all private page state. Public send is visibly disabled and remains denied server-side. See [the UI design and scoped acceptance record](chat-ui-design.md).

Only allowlisted status metadata is retained from CLI steps. Raw tool arguments/output, diagnostics, native internal logs and private reasoning are excluded from the portable record. Responses are filtered as complete strings to avoid exposing a credential split across streaming chunks. Known server credentials and common token/private-key patterns are filtered; matching user inputs/notes are refused. This is not a comprehensive secret scanner. Users must not put credentials in conversation content, and portable exports should be reviewed before sharing or committing.

## Live verification record

Application project: `9ede59f7-0c1a-48d9-80da-23593e41e106` (`cloudaiagent`). Jess conversation: `5a6f2772-f773-42de-a0c8-8819faa2c7ee`, titled **CLI continuity verification**. Native session: `efa167df-a029-4845-80d6-0bb1e5ec81d7`.

The real relay recorded three completed turns, each returning `JESS_RELAY_CEDAR_482`. The first two shared one process. A separate local invocation resumed the native ID and recalled the same marker for turn three. The prompts requested no tools or file changes. The Markdown transcript is stored under the project directory above; these are actual CLI outputs, not browser fixtures or simulator replies.

Before development, 68 source files, their hashes, dirty-tree patch and Git history were checkpointed at `E:\local-data\jess\checkpoints\pre-chat-2026-10-18T03-05-15.078Z`. A PostgreSQL dump was added before migration 003. Prior mobile/editor changes remain intact and uncommitted.

The remaining public live-chat blocker is enforceable execution/credential isolation. Safe import of actual coding artifacts and revision-bound Git approvals also remain separate work. No chat message or context note approves a commit, push or merge; none of those operations is performed by this relay.
