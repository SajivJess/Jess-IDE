# Chat-first UI implementation — 18 October 2026

The subsequent [Home launcher milestone](home-launcher.md) makes Home the initial destination with no bottom navigation. The chat implementation below remains the project conversation screen; its earlier default-entry decision has been superseded by the Home specification.

## Assessment and scope

The starting application already had password authentication, native CLI session journaling, project registration, task replay, review snapshots and a CodeMirror editor. Its project-chat subpage combined selectors, history, message form and portable notes in a long document. It lacked a dedicated scrolling conversation layout, drawer search and conversation metadata actions. The supplied charcoal/violet reference guided the new hierarchy and spacing; its sample messages were not copied into the application.

The implementation retains vanilla browser ES modules, the existing gateway/Fastify/PostgreSQL contract and native relay. No second conversation engine or frontend framework was introduced. Prior dirty source files, their hashes, a Git bundle and patch were saved outside the working tree at `E:/local-data/jess/checkpoints/pre-chat-design-2026-10-18T05-35-02.814Z`; a verified PostgreSQL custom-format backup was added before migration 004.

## Implemented interface

- Chat opens by default. Chat, Projects, Tasks and Files are the four permanent destinations. Settings is contextual; the old task composer is still reachable through Tasks → New task.
- The mobile conversation drawer becomes a collapsible desktop sidebar. It switches projects, searches actual titles and message content, orders conversations by activity, marks unresolved work and creates logical conversations without dispatching a CLI process. Rename and archive/restore are revision checked. Archiving preserves history and native bindings.
- The selected conversation is reflected in `#chat/<UUID>`. User bubbles sit on a subtle violet surface; agent replies use readable text and whitespace. Actual timestamps and recorded delivery states remain distinct from code/test results.
- The message timeline scrolls independently. Keyed turns retain DOM nodes on unchanged replay, per-conversation scroll positions are kept, and older history preserves the visible position. A latest-message control returns to the end.
- The composer grows with multiline input and follows the visual viewport. Short landscape layouts use compact navigation so the timeline cannot cover the composer. Enter inserts a newline by default; Conversation details can change it to send, with Shift+Enter retaining multiline input. Composition events are respected.
- Message drafts and conflicting project notes are preserved across project/conversation/tab switching in page memory. Unsaved drafts trigger a leave warning. They are deliberately not placed in browser persistent storage, so a full reload discards them. Only theme and Enter preference are stored locally.
- Browser connectivity, laptop service availability and recorded native CLI state have separate labels. Offline draft text remains editable. Reconnect refreshes the existing journal and does not create a request or restart an agent.
- Conversation details holds native IDs, context/handoff editing, conflict recovery and Markdown exports. Sensitive page state is cleared on session expiry.

`remote/chat.js` owns the chat controller; `remote/index.html` provides the header, drawer, timeline, composer and dialogs. `remote/chat.css` uses the existing semantic dark/light/system tokens. `remote/app.js` continues to own application navigation; `remote/api.js` and its declaration file remain the typed transport. Existing task/file controllers are retained.

## Response rendering and safety

`remote/markdown-source.js` uses Marked's lexer and constructs an explicit set of DOM nodes. It supports headings, emphasis, lists, quotes, inline code, fenced blocks, links and tables. It never assigns agent content to HTML, evaluates scripts or loads remote images. Only absolute HTTP/HTTPS links without embedded credentials become links; other targets remain text. Code and table regions scroll horizontally. Code and complete responses have copy controls. Existing CodeMirror parsers provide syntax highlighting for JavaScript, TypeScript, JSX/TSX, JSON, CSS and HTML; other languages remain plain text. Node/depth/highlighting limits bound rendering work.

The local build now bundles both editor and Markdown modules and retains bundled dependency license notices. Marked is MIT licensed; dependency versions are locked in `package-lock.json`. No external font, icon or rendering CDN is required.

## Metadata API additions

Migration 004 adds `archived_at`, `metadata_revision` and an activity index. `GET /projects/:id/conversations` accepts bounded `search` and `archived` parameters; queries are parameterized and constrained by both project and registered-repository ownership. `PUT /conversations/:id` requires the current revision and exactly one of `title` or `archived`. Conflicts return 409. Rename/archive events extend the journal and portable transcript instead of changing historical turns. The gateway fixes owner/credentials, enforces Origin and strips unrelated request fields.

Message history now supplies the actual completion timestamp. These additions do not change native session selection, prompt delivery, tool policies or Git behavior.

## Acceptance boundaries

| Requested behavior | Delivery |
| --- | --- |
| Chat default, drawer, real history, copy/Markdown, responsive composer, themes | Implemented; automated phone/desktop coverage |
| Search, switching, rename, archive/restore, transcript export | Implemented using authenticated persistent metadata |
| Draft preservation, offline/reconnect, session expiry, scroll retention | Implemented within the current page; reload discards unsent drafts |
| Intended native session and continuity | Existing local-only relay preserved; earlier three-turn native verification is recorded in `chat-relay.md`; no new model call was needed for this visual milestone |
| Real progress/errors | Recorded journal replay; completed final output rather than fabricated token streaming |
| Public message sending or Stop | Not enabled; API and gateway continue to return 403 for message dispatch. No unsupported Stop button is shown |
| Exact changed-file cards, validation cards and chat-linked diffs | Deferred: chat turns do not yet carry authenticated coding artifacts or review-workspace bindings. Existing task result/diff and review snapshot screens remain functional |
| Handoff to a new session | Existing user-authored context and local native workflow preserved; arbitrary external native-session import remains unsupported |
| Context file synchronization timestamp/import UI | Not added; database revision and explicit exports are available. Disk projections refresh through the local exporter |
| Commit/push/merge approvals | Not enabled or invoked |
| Physical Android keyboard/device validation | Pending; Playwright phone emulation and short/landscape viewport checks are not a physical IME test |

Public live execution still requires an enforceable OS/credential boundary. A separate clone and restrictive CLI tool policy are not a Windows sandbox. This UI milestone does not resolve that blocker.

See [the verification report](mobile-web-verification.md) for exact checks, artifacts and changed files.
