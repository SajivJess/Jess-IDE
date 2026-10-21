# Selective frontend reuse assessment — 19 October 2026

## Decision

Retain the current browser ES modules, semantic CSS tokens, password gateway and Fastify/PostgreSQL contracts for this increment. Vercel Chatbot is a reference for composition and message presentation. Its React/Next.js implementation cannot be dropped into the current DOM controllers without a framework migration. No migration, external application backend, provider API, analytics service or new dependency was introduced.

Antigravity remains the only implemented real-agent adapter. Future IDE support belongs behind the existing provider boundary. Importing a chatbot's model SDK would bypass the native-session workflow rather than complete it.

The pinned Vercel [`components/chat/multimodal-input.tsx`](https://github.com/vercel/chatbot/blob/c2f8235e1f3ea903ad8b7f61447c4f74164b5c58/components/chat/multimodal-input.tsx) depends on React state, Next routing/themes, `UseChatHelpers`, its own attachment types and `/api/files/upload`. Its suggested actions likewise belong to that application's chat composition. Reuse would require explicit transport, state, upload and session adapters. Jess's prompt starters use its existing draft controller and never invoke an SDK send function.

## Source and compatibility review

These are observations of upstream main branches on 19 October 2026, not a blanket license clearance for all files or dependencies. Check the exact revision and component terms again before importing implementation code.

| Candidate | Inspected stack | Published license file | Decision for Jess |
| --- | --- | --- | --- |
| [Vercel Chatbot](https://github.com/vercel/chatbot) | Chatbot 3.1.0; Next.js 16.2.10, React 19.2.7, AI SDK 7.0.15; Auth.js, Drizzle and hosted service integrations | [Apache 2.0](https://github.com/vercel/chatbot/blob/main/LICENSE) | Composer/message presentation reference; a React foundation requires a separate migration decision. Do not bring its model execution, authentication or database layer into Jess. |
| [LibreChat](https://github.com/LibreChat-AI/LibreChat) | Frontend v0.8.8; React 18, Vite 8, its own chat/data packages and state libraries | [Root MIT license](https://github.com/LibreChat-AI/LibreChat/blob/main/LICENSE); client package metadata says ISC | Conversation organization and message-action reference. Verify exact component/package notices before copying. The old danny-avila URL redirects here. |
| [LobeHub](https://github.com/lobehub/lobehub) | 2.2.20; React 19, Next.js 16, Vite and internal packages | [LobeHub Community License](https://github.com/lobehub/lobehub/blob/main/LICENSE) contains additional derivative-distribution conditions despite MIT package metadata | Reference only for this increment. The old lobe-chat URL redirects here. No source, assets, speech service or settings backend imported. |
| [Open WebUI](https://github.com/open-webui/open-webui) | 0.12.3; Svelte 5/SvelteKit 2, separate backend; published Node range ends at 22 while Jess runs Node 24 | [Open WebUI License](https://github.com/open-webui/open-webui/blob/main/LICENSE) includes branding retention conditions and exceptions | Attachment/tool-status interaction reference. No source or upload stack imported. |

Manifest sources: [Chatbot](https://github.com/vercel/chatbot/blob/main/package.json), [LibreChat frontend](https://github.com/LibreChat-AI/LibreChat/blob/main/client/package.json), [LobeHub](https://github.com/lobehub/lobehub/blob/main/package.json), [Open WebUI](https://github.com/open-webui/open-webui/blob/main/package.json). No implementation code, artwork or branding from these repositories was copied. The new Jess controls are implemented in its existing DOM controller and semantic styles.

The manifests and license files were also retrieved at these exact GitHub main revisions and saved under `.local/frontend-references/`, with the audit in `.local/frontend-reference-audit.json`:

- Vercel Chatbot: `c2f8235e1f3ea903ad8b7f61447c4f74164b5c58`
- LibreChat: `e081b566a42d3a83b8102157bd7806cf4ff63b17`
- LobeHub: `49204982cab98bfa2f2fb6831a34d5018a2af6be`
- Open WebUI: `91ea4e3421d1d8069f13d4a463fcb5986d94ea60`

## Feature map

| Requested capability | Existing implementation | This increment / remaining gap |
| --- | --- | --- |
| Responsive chat, Markdown, syntax highlighting, code copy | `remote/chat.js`, `chat.css`, bundled `markdown-source.js` | Preserved; phone and desktop browser checks retained. |
| Project/workspace selection and navigation | Home launcher, conversation drawer, registered repository revisions and Files | Preserved, including Home as the first workspace navigation button. Home itself remains the focused launcher. |
| Conversation search, rename, archive/restore and export | Authenticated APIs, revision checks, PostgreSQL metadata and Markdown exports | Already implemented; preserve rather than replace with another application's conversation store. |
| Message actions and prompt shortcuts | Assistant/code copy already existed; task composer had shortcuts | Added user-message copy, reuse of an actual prior prompt, and four chat prompt starters. All append to the in-memory draft with a hard length check. |
| Actual replies, progress, cancellation | Local native relay and recorded chat events; simulator task cancellation | Public phone-to-CLI dispatch still returns 403. OS/credential isolation and a durable execution path remain prerequisites. Do not label recorded history as an active connected CLI. |
| Diff viewer and approvals | Real task diff display and separate review snapshots/editor | Chat-to-execution artifact binding and exact-revision Git approvals remain missing. No automatic commit, push or merge. |
| Attachments and previews | No authenticated chat attachment contract | Requires owned upload IDs, bounded size/types, E-drive storage, safe previews, retention/deletion, and a supported CLI context-transfer mechanism. Browser selection alone is not delivery to the agent. |
| Voice input/output | Not implemented | Needs an explicit local processing design and device support validation before microphone/UI controls are enabled. Do not silently route speech to a browser/cloud transcription service. |
| Conversation branching | Not implemented | Needs explicit parent/turn metadata and a verified native-session fork or new-session handoff contract. Copying a message into a draft is not a native fork. |

## Delivered behavior

- The composer's sparkle button opens an accessible Prompt shortcuts dialog with Explain code, Debug a problem, Write tests and Review changes.
- Selecting a shortcut appends editable text to the current draft. Reuse prompt appends the actual historical user message. Existing instructions are never silently replaced or truncated.
- Appending beyond the existing 8,000-character cap leaves the draft untouched and explains the limit. The dialog stays open until the user closes it or chooses an insertable prompt.
- User messages now have Copy user message and Reuse prompt actions. Historical messages and portable transcripts are unchanged.
- Actions work without dispatch and while offline. Drafts remain scoped to the conversation/project and page memory, are cleared on authentication expiry, and are not saved in browser persistent storage. The dialog closes when leaving Chat.
- Dark/light/system themes, reduced-motion settings, native dialog keyboard/focus behavior and five-item workspace navigation are preserved.
- Background chat replay pauses while a chat dialog is open, then resumes on the normal interval after it closes. This prevents a polling cycle from disabling a context editor button during a click; manual context operations remain available and revision checked.

The source checkpoint is recorded in `.local/feature-patterns-checkpoint.txt`. It contains hash-verified copies of all modified/untracked source files and the pre-edit Git patch under `E:/local-data/jess/checkpoints/`. This frontend-only change requires no database migration.

## Verification

- `npm run check`: passed type checking, lint, 57 backend tests across six files, two gateway tests, 13 frontend/controller tests and the production build. Database tests were required against the separate local test database; no suites were skipped.
- The first browser run passed 23/24 scenarios and exposed a context-reload click racing the three-second background poll. The poll could disable the button between pointer-down and click. Pausing background replay while chat dialogs are open fixed the issue without changing the revision/conflict policy.
- Both affected flows (recorded context/history and the new prompt actions) then passed twice on each form factor: eight focused checks. Changed JavaScript/test files passed lint again.
- Final `npm run test:browser`: **24/24 passed**, covering phone emulation and desktop. Disposable database-schema cleanup completed.
- Public HTTPS login and the deployed shortcuts were verified at `https://label-formation-exempt-consolidated.trycloudflare.com` on 19 October 2026. The 320-pixel layout, Home navigation and disabled Send control passed; no browser page errors were observed. Evidence: `.local/frontend-patterns-public-verification.json`.
- Screenshots inspected: `.local/mobile-preview/phone-prompt-shortcuts.png`, `desktop-prompt-shortcuts.png` and `live-prompt-shortcuts.png`.
- `git diff --check` passed. HEAD remains `e9bd95aeb9b950db6517d6d7a18cdbdb602f394e`; nothing was staged, committed or pushed. No backend/API/SQL changes, new packages or model calls were needed.

Changed source/documentation files for this increment: `remote/index.html`, `remote/chat.js`, `remote/chat.css`, `tests/browser/workspace.spec.mjs`, `README.md`, and this feature map. All other source files in the 62-file pre-edit checkpoint remained unchanged.

Automated phone emulation cannot establish physical Android keyboard, microphone or native CLI execution behavior. Public phone-to-agent dispatch, execution isolation, artifact-bound approvals, attachments and voice remain separate unfinished milestones.

## Pre-push reliability fix — 21 October 2026

Full validation before publication exposed the same class of polling race in the conversation overflow menu: a quiet replay could claim the shared busy flag and interrupt Archive between pointer-down and click. Background replay now has its own in-flight flag and never disables foreground controls. A foreground action supersedes an older replay through an operation sequence check, preventing a delayed replay from replacing newer state. Mutation requests remain single-flight, generation checked and revision checked; public dispatch remains disabled.

The conversation organization browser scenario now deliberately holds a replay request open, archives while that request is pending, then releases the replay and verifies search, restore and draft preservation. Route cleanup waits for the held handler, so the test does not complete a request twice. This makes the race reproducible rather than relying on click timing.

Pre-push validation on 21 October passed type checking, lint, build, all 57 backend tests, two gateway tests and 13 frontend tests. After the replay fix, the delayed-replay scenario passed twice on each form factor and the final full browser suite passed 24/24. The test database was stopped afterward; public services remained stopped.
