# Project-launching Home — 18 October 2026

Home is now the default destination after sign-in. It has no bottom navigation and concentrates on creating or opening an authorized project. The existing Chat, Tasks, Projects, Files/editor and Settings screens are preserved. The earlier task composer moved to `#compose`; Tasks → New task and legacy project actions still reach it. A project opens Chat and restores its saved conversation when available. Workspace navigation contains Home, Chat, Projects, Tasks and Files; the Home button is the first navigation item rather than a header shortcut.

## Implemented experience

- A compact branded header with search and Settings, a date derived from the browser's date, a personalized welcome and one prominent creation card.
- A server-side workspace profile name. The authenticated `/session` response supplies it; Settings can change it. A missing name produces a generic welcome. No example name or project is embedded in the UI. This is the existing single-owner password identity, not Google profile synchronization or multi-account authentication.
- Continue working restores a project/conversation from actual server-recorded visits. Explicit conversation switches update that record. Archived conversations are excluded from automatic restoration. Native session IDs are retained; opening a project does not launch Antigravity or reset a session.
- Project cards show real names, linked repository and branch where known, actual activity/open times and recorded CLI state. A repository is derived from the selected/recent owned conversation; projects without that association say no repository is linked.
- Grid/list presentation and sorting by activity or name. The complete authorized list is paginated in groups of 50, with a Load more action. Counts come from the database, not the loaded browser page.
- Global search opens from the header or Ctrl/Cmd+K. It searches authorized project names, linked repository names/URLs, conversation titles and actual recorded prompt/reply content. It returns at most 20 matches and opens the precise matching conversation. It is not a source-code search engine.
- Project creation supports a logical workspace without a repository, or a registered repository that creates a conversation. It does not clone arbitrary GitHub repositories, run code or start the CLI. If creation succeeds but a subsequent step fails, the interface keeps the created project and warns against recreating it.
- Loading skeletons, empty-state onboarding, retry/error feedback, session-expiry clearing and theme consistency. No decorative statistics or activity feed were added.

Laptop reachability and CLI readiness remain separate. A saved native ID is labeled as a saved/local-only session, not as an online agent. Pending or uncertain turns retain their actual delivery labels. The Home connection row states that remote Antigravity messaging remains unavailable.

## API and data changes

Migration `005_home_navigation.sql` adds `projects.last_opened_at` and a saved conversation reference. Existing project IDs, history, repositories, review snapshots and native bindings are preserved.

| Route | Method | Behavior |
| --- | --- | --- |
| `/workspace/home` | GET | Owned project metadata, total count, recent work; `sort=recent|name`, bounded `offset`; at most 50 projects/page |
| `/workspace/search` | GET | `q`, 2–100 trimmed characters; at most 20 owned project/conversation matches |
| `/projects/:id/open` | POST | Optional `conversationId`; checks project/repository ownership and conversation/project association, records a visit and returns the resumable conversation |
| Portal `/session` | GET | Existing capabilities plus authenticated `user.displayName` |
| Portal `/profile` | PUT | `{displayName}` only; current session and exact Origin required, validates and persists the name in ignored local configuration |

The gateway adds `/api` to backend routes, fixes owner/credentials and forwards only approved fields. Search text is parameterized. The API does not expose source-directory paths, native credentials or the backend token through Home metadata. The profile writer uses a fixed local file, rejects linked configuration files and replaces the configuration through an exclusive temporary file. Profile updates do not change the authenticated owner.

## Implementation locations

`src/workspaces/home.ts` supplies the owned read/navigation APIs. `remote/home.js` owns launcher/search/profile interactions, request generations and expiry clearing. `remote/home.css` reuses the existing semantic theme tokens. `remote/app.js` keeps application navigation, while `remote/chat.js` supports a project URL with no existing conversation. Existing task/file controllers are retained.

Project/conversation content and search results remain in memory and the database. The launcher does not put that content into localStorage or the service-worker cache. Chat and editor draft preservation still use their existing mechanisms. Grid/list and sort choices currently last within the page session.

## Remaining scope

Public real-agent messaging/isolation remains a separate unfinished milestone. No public dispatch, Git approval, commit, push or merge was enabled. Project rename/archive, arbitrary repository import, tags/folders and advanced project filters were not added. Task and file destinations retain their existing workspace-wide behavior; this milestone does not turn them into a new project-scoped IDE.

Actual Android hardware, keyboard/IME and installed-PWA testing still require device validation. See the current [verification report](mobile-web-verification.md) for test results, screenshots and exact changed files.
