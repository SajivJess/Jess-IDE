# Antigravity CLI development adapter

The optional `antigravity-cli-v1` adapter invokes Google's official `agy` executable in print mode, reads its JSON result, runs host-controlled checks, and returns the actual Git diff. The default adapter remains `fake-v1` unless `AGENT_PROVIDER=antigravity` is explicitly configured.

## Installed laptop tools

- CLI 1.4.0: `E:\tools\antigravity-cli\agy.exe`, verified against the SHA-512 digest in the official installer manifest.
- Git: `E:\tools\git\cmd\git.exe`.
- Node/npm: `E:\tools\node-v24.22.0-win-x64`.
- CLI home and task logs: `E:\local-data\antigravity-home`.
- Task clones: `E:\local-data\jess\workspaces` when configured as in `.env.example`.

The CLI is separate from the IDE's `antigravity-ide` launcher. No unofficial IDE bridge is used. Google's model service still processes prompts remotely; local execution does not mean on-device model inference.

## Authentication

Use the prepared launcher from PowerShell:

```powershell
E:\cloudaiagent\scripts\antigravity.ps1
```

Complete Google's sign-in flow, then exit the CLI. The launcher directs the CLI's configurable profile, application data and temporary locations to E:. Google may use Windows Credential Manager for sign-in; that OS-managed store cannot be relocated by this wrapper. Do not assume an E: profile relocates Windows' credential database. Under a strict prohibition on OS credential storage on C:, use a supported E:-stored API-key configuration instead of signing into the account flow.

Google also supports Gemini API-key authentication by setting `modelProvider=gemini` in the profile's `.gemini/antigravity-cli/settings.json` and providing `GEMINI_API_KEY`. This runner intentionally does not currently pass API credentials into execution processes. Add a dedicated secret provider before adopting that mode; do not paste keys into prompts or commit them.

Google account sign-in on this laptop is complete. A separate authenticated print-mode run returned `JESS_CLI_READY`. A native `write_to_file` test created `docs/cli-validation.md` in a task clone, and its content was checked on disk. No authorization codes or account credentials are committed to this repository.

## Enabling local execution

Configure all commented `AGENT_*` / `ANTIGRAVITY_*` paths shown in `.env.example`, and change `AGENT_PROVIDER` to `antigravity`. Keep `.env` local. Configure the profile permission file as described below before starting the worker.

Rebuild after source changes. The worker chooses the adapter at startup. A project currently maps to the single server-configured source repository; per-project repository selection is not implemented.

For one local task without starting the API, worker, database or tunnel, save the task text to an E: file and run:

```powershell
E:\cloudaiagent\scripts\antigravity-task.ps1 -PromptFile E:\local-data\jess\task.txt
```

This uses the laptop paths above for that invocation only and prints the result/diff. It does not enable Antigravity in the persistent `.env`. Build first if the compiled files are missing. The task is executed directly and is not inserted into the database queue.

For each task attempt, the runner:

1. Creates a separate full Git clone from the source's committed HEAD, without local object sharing or untracked files such as `.env`.
2. Removes its `origin` remote and creates `jess/task-<task UUID>-<attempt>` in that clone. The branch exists in the separate clone, not in the primary checkout.
3. Installs locked dependencies with npm lifecycle scripts disabled.
4. Runs `agy --print ... --output-format stream-json --disable-slash-commands`, with the normal permission policy and a fixed timeout. It saves bounded events in the local profile and requires a final successful result envelope. It never uses `--dangerously-skip-permissions`.
5. Rejects errors, invalid JSON, denied tool actions, and unexpected Git history changes.
6. Runs fixed Node entry points for TypeScript, lint, tests and build. Check statuses come from exit codes, not model claims. Database integration tests in task clones have no credentials and may be skipped; the check label states this limitation.
7. Returns changed files, the actual diff, branch and base commit. Diffs are capped at 200,000 characters and explicitly flagged when truncated. Command output is capped at 2 MiB; an oversized output fails execution.

The complete attempt has a 10-minute default timeout (configurable between 30 seconds and 30 minutes). Cancellation/timeout terminates the active process tree on Windows. Attempt directories and local reports remain for review; they are never silently reused or automatically deleted. No task commits or pushes automatically.

The process wrapper bounds final output draining after the CLI exits: a native helper retaining an inherited Windows output handle cannot keep the runner waiting indefinitely.

## Permissions and current limits

The prepared E: CLI profile uses `request-review`, denies agent shell/unsandboxed commands, MCP calls and browser actions, and denies access to `.git` and dependencies. The runner explicitly supplies the task clone with `--add-dir`, uses `--mode accept-edits`, and writes a workspace-relative `write_file(.)` allow rule. It does not rely on implicit file-write permission in Windows headless mode. Host-controlled commands run after the agent finishes.

The dedicated CLI profile is locked while a task runs so a second task cannot overwrite its permission policy. A hard process crash can leave `.jess-cli.lock` in that profile. Remove it only after verifying that no task runner is still active; the runner never silently steals a lock or reuses an uncertain attempt.

These controls are for an owner's trusted development repository. A separate clone and a clean environment are **not an operating-system sandbox**. Tests, compiler configuration, plugins and package code execute as the Windows user. CPU, memory, disk and network are not isolated with Windows Job Objects or a container. Task contents must be trusted. Editing CLI permission files can change what the agent is allowed to do.

Therefore the public portal refuses new task submissions whenever its startup environment selects the real adapter. Keep it stopped during local development. Internet-triggered real execution needs enforceable OS isolation and a dedicated credential boundary first. The existing public simulator remains available when explicitly run with the fake adapter.

## Validation

`tests/antigravity.test.ts` uses real temporary Git repositories and a controlled CLI substitute to test clone separation, omission of `.env` and backend credentials, actual diff capture (including new files), check failures, non-reuse of attempts, provider/JSON errors, denied actions, cancellation, runtime and output limits. It also verifies the workspace scope and mutual exclusion of the CLI profile. These automated boundary tests are distinct from the real authenticated CLI checks described above.

### Live verification on 17 October 2026

Task `f39f032e-6b44-447e-8d9e-eb2cdf493122` completed through `scripts/antigravity-task.ps1` with the real authenticated CLI. It started from source commit `a7ebe863c5fb26a4d974bddf25886a8db398321e` in its own clone and branch, created only `docs/cli-validation.md`, and returned `simulated: false` with the actual one-line Git diff.

The host-controlled TypeScript, lint, tests-without-database-credentials and build checks all returned exit code zero. Database integration tests were not run in the task clone; the runner deliberately supplies no database credentials. Separately, type checking, lint, build and all five runner regression tests passed for the updated harness.

The local report is `E:\local-data\antigravity-home\result-f39f032e-6b44-447e-8d9e-eb2cdf493122-1.json`. Its task branch is retained in `E:\local-data\jess\workspaces\f39f032e-6b44-447e-8d9e-eb2cdf493122-1`. No task commit, push or merge was performed. This validates one small real file-edit task, not general-purpose isolation or production readiness.

Official references:

- https://www.antigravity.google/docs/cli/headless/
- https://www.antigravity.google/docs/install?tab=cli
- https://www.antigravity.google/docs/permissions?tab=cli
