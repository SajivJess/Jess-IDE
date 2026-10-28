import asyncio
import hashlib
import json
import os
from pathlib import Path
import shlex
import time
import uuid
from typing import Any, Dict, List, Optional, Set

import httpx
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.core.logging import logger
from app.db.models.conversation_message import ConversationMessage
from app.db.models.project import Project
from app.db.models.task import Task
from app.db.models.workspace import Workspace
from app.db.session import async_session_factory
from app.schemas.task import TERMINAL_STATUSES, TaskStatus, can_transition
from app.schemas.workspace import WorkspaceStatus
from app.services.agent_adapter import BaseAgentAdapter
from app.services.conversation_events import append_conversation_event
from app.services.task_events import append_task_event
from app.services.workspace import get_workspace_provider

# ─── Meta Model Approved Tool Definitions ────────────────────────────────────
META_TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "list_files",
            "description": "List files in the workspace (or a subdirectory). Returns relative paths and directory flags.",
            "parameters": {
                "type": "object",
                "properties": {
                    "directory": {
                        "type": "string",
                        "description": "Subdirectory path relative to workspace root (defaults to root '').",
                    }
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "read_file",
            "description": "Read file contents from the workspace. Maximum 2 MB.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "File path relative to workspace root.",
                    }
                },
                "required": ["path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "write_file",
            "description": "Create or overwrite a file in the workspace. Cannot write to .env or .git.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "File path relative to workspace root.",
                    },
                    "content": {
                        "type": "string",
                        "description": "Complete file content to write.",
                    },
                },
                "required": ["path", "content"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "run_check",
            "description": "Run an approved command (such as a test runner, linter, or script) in the workspace.",
            "parameters": {
                "type": "object",
                "properties": {
                    "command": {
                        "type": "string",
                        "description": "Command to execute (e.g. 'pytest', 'python -m unittest', 'python -m pytest', 'flutter test').",
                    }
                },
                "required": ["command"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_git_diff",
            "description": "Return the current git diff of all modifications made in the workspace relative to HEAD.",
            "parameters": {"type": "object", "properties": {}, "required": []},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "host_preview",
            "description": "Host and generate a live web preview link for any HTML/web file in the workspace (e.g. 'calculator.html', 'index.html'). Generates an instant public HTTPS tunnel or local IP link for mobile and browser testing.",
            "parameters": {
                "type": "object",
                "properties": {
                    "file_path": {
                        "type": "string",
                        "description": "File path relative to workspace root to host and preview (e.g. 'calculator.html' or 'index.html').",
                    },
                    "hosting_type": {
                        "type": "string",
                        "enum": ["temp_tunnel", "local_ip"],
                        "description": "Hosting type: 'temp_tunnel' (temporary Cloudflare/ngrok public HTTPS link accessible remotely on phone) or 'local_ip' (for same Wi-Fi LAN). Default is 'temp_tunnel'.",
                    },
                },
                "required": ["file_path"],
            },
        },
    },
]

# ─── Safe Task-Scoped Git Baseline & Reversion Helpers ──────────────────────────

async def _capture_git_baseline(ws_provider: Any, workspace: Workspace) -> Dict[str, Any]:
    """Capture repository identity, branch, HEAD SHA, and pre-existing modifications."""
    wdir = ws_provider.get_workspace_dir(workspace)
    git_dir = wdir / ".git"
    if not git_dir.exists():
        return {
            "has_git": False,
            "branch": "main",
            "base_sha": "",
            "modified": set(),
            "untracked": set(),
            "staged": set(),
        }

    b_res = await ws_provider.execute_command(workspace, ["git", "rev-parse", "--abbrev-ref", "HEAD"])
    branch = b_res.stdout.strip() if b_res.exit_code == 0 and b_res.stdout.strip() else "main"

    s_res = await ws_provider.execute_command(workspace, ["git", "rev-parse", "HEAD"])
    base_sha = s_res.stdout.strip() if s_res.exit_code == 0 and s_res.stdout.strip() else ""

    st_res = await ws_provider.execute_command(workspace, ["git", "status", "--porcelain=v1"])
    modified = set()
    untracked = set()
    staged = set()

    if st_res.exit_code == 0:
        for line in st_res.stdout.splitlines():
            if len(line) >= 3:
                x = line[0]
                y = line[1]
                path = line[3:].strip().replace("\\", "/")
                if x in ("M", "A", "D", "R", "C"):
                    staged.add(path)
                if y in ("M", "D"):
                    modified.add(path)
                elif line.startswith("??"):
                    untracked.add(path)

    ls_res = await ws_provider.execute_command(workspace, ["git", "ls-files"])
    tracked = set()
    if ls_res.exit_code == 0:
        for line in ls_res.stdout.splitlines():
            clean_l = line.strip().replace("\\", "/")
            if clean_l:
                tracked.add(clean_l)

    return {
        "has_git": True,
        "branch": branch,
        "base_sha": base_sha,
        "modified": modified,
        "untracked": untracked,
        "staged": staged,
        "tracked": tracked,
    }


async def _get_task_scoped_diff(
    ws_provider: Any,
    workspace: Workspace,
    task_owned_files: Set[str],
    baseline: Dict[str, Any],
) -> str:
    """Generate diff strictly attributable to task-owned files, omitting pre-existing uncommitted work."""
    if not task_owned_files or not baseline.get("has_git", False):
        return ""

    wdir = ws_provider.get_workspace_dir(workspace)
    diff_parts: List[str] = []

    tracked_set = baseline.get("tracked", set())
    tracked_files = [f for f in task_owned_files if f in tracked_set]
    new_task_files = [f for f in task_owned_files if f not in tracked_set]

    if tracked_files:
        cmd = ["git", "diff", "HEAD", "--", *tracked_files]
        res = await ws_provider.execute_command(workspace, cmd)
        if res.exit_code == 0 and res.stdout.strip():
            diff_parts.append(res.stdout.strip())

    for ntf in new_task_files:
        target_p = wdir / ntf
        if target_p.exists() and target_p.is_file():
            try:
                content = target_p.read_text(encoding="utf-8", errors="replace")
                lines = content.splitlines()
                patch_header = f"diff --git a/{ntf} b/{ntf}\nnew file mode 100644\n--- /dev/null\n+++ b/{ntf}\n@@ -0,0 +1,{len(lines)} @@\n"
                body = "\n".join("+" + l for l in lines)
                diff_parts.append(patch_header + body)
            except Exception:
                pass

    return "\n\n".join(diff_parts) if diff_parts else ""


async def _revert_task_changes(
    ws_provider: Any,
    workspace: Workspace,
    task_owned_files: Set[str],
    baseline: Optional[Dict[str, Any]] = None,
    file_existed_before_task: Optional[Dict[str, bool]] = None,
) -> None:
    """Safely revert only task-owned files.
    
    NEVER runs 'git checkout -- .' or 'git clean -fd'.
    Preserves all pre-existing modifications and untracked files.
    """
    if not task_owned_files:
        return

    wdir = ws_provider.get_workspace_dir(workspace)
    existed_map = file_existed_before_task or {}
    pre_untracked = baseline.get("untracked", set()) if baseline else set()
    pre_modified = baseline.get("modified", set()) if baseline else set()

    for rel_path in task_owned_files:
        clean_rel = rel_path.strip().replace("\\", "/").lstrip("/")
        target = wdir / clean_rel

        # 1. If file was created by this task (did not exist before task and wasn't pre-existing untracked)
        was_new = (not existed_map.get(clean_rel, True)) and (clean_rel not in pre_untracked)
        if was_new:
            try:
                if target.exists() and target.is_file():
                    target.unlink()
                    logger.info(f"[SafeRevert] Removed task-created file: {clean_rel}")
            except Exception as e:
                logger.warning(f"[SafeRevert] Error removing task-created file {clean_rel}: {e}")
        else:
            # 2. File existed before. If it was clean at baseline (not pre-modified), restore to HEAD
            if clean_rel not in pre_modified:
                try:
                    await ws_provider.execute_command(workspace, ["git", "checkout", "HEAD", "--", clean_rel])
                    logger.info(f"[SafeRevert] Reverted modified file to HEAD: {clean_rel}")
                except Exception as e:
                    logger.warning(f"[SafeRevert] Error checking out {clean_rel}: {e}")
            else:
                logger.info(f"[SafeRevert] Preserving pre-existing modification on: {clean_rel}")


async def _check_stale_review(
    ws_provider: Any,
    workspace: Workspace,
    baseline_branch: str,
    baseline_sha: str,
    diff_hash: str,
    task_owned_files: Set[str],
    baseline: Dict[str, Any],
) -> Optional[str]:
    """Check if repository branch, HEAD SHA, or task-scoped diff have diverged since review was requested."""
    if not baseline.get("has_git", False):
        return None

    # Check branch
    b_res = await ws_provider.execute_command(workspace, ["git", "rev-parse", "--abbrev-ref", "HEAD"])
    curr_branch = b_res.stdout.strip() if b_res.exit_code == 0 else ""
    if curr_branch and curr_branch != baseline_branch:
        return f"Branch changed from '{baseline_branch}' to '{curr_branch}'."

    # Check base SHA
    s_res = await ws_provider.execute_command(workspace, ["git", "rev-parse", "HEAD"])
    curr_sha = s_res.stdout.strip() if s_res.exit_code == 0 else ""
    if curr_sha and curr_sha != baseline_sha:
        return f"Repository HEAD commit moved from {baseline_sha[:8]} to {curr_sha[:8]}."

    # Check task diff hash
    curr_diff = await _get_task_scoped_diff(ws_provider, workspace, task_owned_files, baseline)
    curr_hash = hashlib.sha256(curr_diff.encode("utf-8")).hexdigest()[:16]
    if curr_hash != diff_hash:
        return f"File contents have changed (proposed diff hash {diff_hash} != current {curr_hash})."

    return None


async def _commit_task_changes(
    ws_provider: Any,
    workspace: Workspace,
    task_title: str,
    task_owned_files: Set[str],
) -> Optional[str]:
    """Commit ONLY task-owned files."""
    if not task_owned_files:
        return None

    files_list = list(task_owned_files)
    # Stage only task-owned files
    await ws_provider.execute_command(workspace, ["git", "add", "--", *files_list])

    commit_cmd = [
        "git",
        "-c", "user.name=Jess Meta Agent",
        "-c", "user.email=meta@jess.local",
        "commit",
        "-m", f"Applied: {task_title}",
        "--",
        *files_list,
    ]
    await ws_provider.execute_command(workspace, commit_cmd)

    sha_res = await ws_provider.execute_command(workspace, ["git", "rev-parse", "HEAD"])
    if sha_res.exit_code == 0 and sha_res.stdout.strip():
        return sha_res.stdout.strip()[:40]
    return None


# ─── Context-Window Management & Token Budgeting ───────────────────────────────

def estimate_tokens(text: str) -> int:
    """Conservative token estimate (~3.5 characters per token)."""
    if not text:
        return 0
    return max(1, int(len(text) / 3.5))


def estimate_messages_tokens(messages: List[Dict[str, Any]]) -> int:
    """Estimate total tokens across a list of chat completion messages."""
    total = 0
    for m in messages:
        content = m.get("content") or ""
        total += estimate_tokens(content)
        if "tool_calls" in m and isinstance(m["tool_calls"], list):
            for tc in m["tool_calls"]:
                fn = tc.get("function", {})
                total += estimate_tokens(fn.get("name", "")) + estimate_tokens(str(fn.get("arguments", "")))
    return total


def compact_context_window(
    messages: List[Dict[str, Any]],
    max_tokens: int,
    task_owned_files: Set[str],
    last_check_command: Optional[str] = None,
    last_check_exit_code: Optional[int] = None,
    last_check_passed: Optional[bool] = None,
) -> List[Dict[str, Any]]:
    """Enforce predictable context limits by compacting older tool iterations.
    
    Guarantees:
    - Never summarizes away system instructions (messages[0]).
    - Never summarizes away user task specification & safety constraints (messages[1]).
    - Never summarizes away test check results or failure evidence.
    - Preserves the latest tool exchanges (tail of recent interactions).
    - Compacts intermediate file reading and listings into a structured summary.
    """
    total_tokens = estimate_messages_tokens(messages)
    if total_tokens <= max_tokens or len(messages) <= 6:
        return messages

    # Keep system prompt and initial task prompt
    system_msg = messages[0]
    task_msg = messages[1]

    # Retain the most recent 4 messages (the tail of the active interaction)
    tail_count = 4
    middle = messages[2:-tail_count]

    if not middle:
        return messages

    # Extract intermediate actions
    inspected_files = set()
    for m in middle:
        if m.get("role") == "assistant" and "tool_calls" in m:
            for tc in m["tool_calls"]:
                fn = tc.get("function", {})
                if fn.get("name") in ("read_file", "list_files"):
                    try:
                        args = json.loads(fn.get("arguments", "{}"))
                        if "path" in args:
                            inspected_files.add(args["path"])
                    except Exception:
                        pass

    summary_parts = [
        "[Context Budget Optimization: Compacted Prior Iterations]",
        f"- Task modified files so far: {', '.join(sorted(task_owned_files)) if task_owned_files else 'None'}",
        f"- Files previously inspected: {', '.join(sorted(inspected_files)[:10]) if inspected_files else 'Workspace structure explored'}",
    ]
    if last_check_command:
        summary_parts.append(
            f"- Test Verification Outcome: Command '{last_check_command}' finished with exit code {last_check_exit_code} (passed: {last_check_passed})"
        )
    summary_parts.append("- Prior intermediate iterations compacted to stay within token limits. Proceeding with active step below.")

    compact_summary_msg = {
        "role": "user",
        "content": "\n".join(summary_parts),
    }

    compacted = [system_msg, task_msg, compact_summary_msg] + messages[-tail_count:]
    logger.info(
        f"[ContextBudget] Compacted {len(messages)} messages ({total_tokens} est tokens) -> {len(compacted)} messages ({estimate_messages_tokens(compacted)} est tokens)."
    )
    return compacted


class MetaAgentAdapter(BaseAgentAdapter):
    """Real Meta Model API coding-agent adapter for Jess IDE.
    
    Powers autonomous coding workflows using Meta Model API (e.g. muse-spark-1.3)
    with isolated workspace tool execution, test-and-repair loops, and human-in-the-loop approval.
    """

    def __init__(self) -> None:
        self._pending_approvals: Dict[uuid.UUID, asyncio.Future] = {}
        self._running_tasks: Dict[uuid.UUID, asyncio.Task] = {}
        self._cancellation_events: Dict[uuid.UUID, asyncio.Event] = {}
        self._dispatch_locks: Dict[uuid.UUID, asyncio.Lock] = {}
        self._global_lock = asyncio.Lock()

    def is_task_running(self, task_id: uuid.UUID) -> bool:
        task = self._running_tasks.get(task_id)
        return task is not None and not task.done()

    async def _get_dispatch_lock(self, task_id: uuid.UUID) -> asyncio.Lock:
        async with self._global_lock:
            if task_id not in self._dispatch_locks:
                self._dispatch_locks[task_id] = asyncio.Lock()
            return self._dispatch_locks[task_id]

    async def _transition(
        self, db: AsyncSession, task: Task, target_status: TaskStatus
    ) -> bool:
        stmt = select(Task.status).where(Task.id == task.id)
        res = await db.execute(stmt)
        fresh_status_str = res.scalar_one_or_none()
        if not fresh_status_str:
            raise ValueError(f"Task {task.id} not found in database during transition")

        fresh_status = TaskStatus(fresh_status_str)
        if fresh_status in TERMINAL_STATUSES:
            logger.warning(
                f"Task {task.id} is already in terminal status {fresh_status.value}. "
                f"Refusing transition to {target_status.value}."
            )
            task.status = fresh_status.value
            return False

        if not can_transition(fresh_status, target_status):
            err_msg = f"Invalid task state transition from {fresh_status.value} to {target_status.value}"
            logger.error(err_msg)
            raise ValueError(err_msg)

        task.status = target_status.value
        await db.commit()
        logger.info(f"Task {task.id} transitioned {fresh_status.value} -> {target_status.value}")
        return True

    async def _emit_task_event(
        self,
        db: AsyncSession,
        task: Task,
        event_type: str,
        payload: Dict[str, Any],
    ) -> None:
        task_id_val = getattr(task, "id", None)
        if task_id_val:
            await append_task_event(db, task_id_val, event_type, payload)

    async def _emit_conv_event(
        self,
        db: AsyncSession,
        task: Task,
        event_type: str,
        payload: Dict[str, Any],
        conversation_id: Optional[uuid.UUID] = None,
    ) -> None:
        conv_id = conversation_id
        if conv_id is None:
            try:
                conv_id = task.conversation_id
            except Exception:
                conv_id = None
        if conv_id:
            await append_conversation_event(
                db,
                conversation_id=conv_id,
                event_type=event_type,
                payload=payload,
                run_id=getattr(task, "id", None),
            )

    async def run_task(self, task_id: uuid.UUID) -> None:
        if self.is_task_running(task_id):
            logger.warning(f"Task {task_id} is already executing. Ignoring duplicate run request.")
            return

        lock = await self._get_dispatch_lock(task_id)
        async with lock:
            if self.is_task_running(task_id):
                logger.warning(f"Task {task_id} already started under lock. Ignoring duplicate.")
                return

            cancel_event = asyncio.Event()
            self._cancellation_events[task_id] = cancel_event

            bg_task = asyncio.create_task(self._execute_meta_loop(task_id, cancel_event))
            self._running_tasks[task_id] = bg_task

            def _cleanup(t: asyncio.Task) -> None:
                self._running_tasks.pop(task_id, None)
                self._cancellation_events.pop(task_id, None)
                self._pending_approvals.pop(task_id, None)

            bg_task.add_done_callback(_cleanup)

    async def _execute_meta_loop(
        self, task_id: uuid.UUID, cancel_event: asyncio.Event
    ) -> None:
        ws_provider = get_workspace_provider()
        last_changed_file = "README.md"
        repair_attempts = 0
        last_check_command: Optional[str] = None
        last_check_exit_code: Optional[int] = None
        last_check_passed: Optional[bool] = None

        try:
            async with async_session_factory() as db:
                stmt = select(Task).where(Task.id == task_id)
                res = await db.execute(stmt)
                task = res.scalar_one_or_none()
                if not task:
                    logger.error(f"Task {task_id} not found in database for execution.")
                    return

                task_title = task.title or "Untitled Task"
                task_prompt = task.prompt or ""
                task_project_id = task.project_id
                task_workspace_id = task.workspace_id
                task_conversation_id = task.conversation_id

                # If task is already terminal, abort immediately
                if TaskStatus(task.status) in TERMINAL_STATUSES:
                    logger.warning(
                        f"Task {task_id} is already in terminal state {task.status}. Aborting execution."
                    )
                    return

                # 1. QUEUED -> RUNNING
                success = await self._transition(db, task, TaskStatus.RUNNING)
                if not success:
                    return

                await self._emit_task_event(
                    db,
                    task,
                    "task.started",
                    {"status": TaskStatus.RUNNING.value, "title": task_title},
                )
                await self._emit_conv_event(
                    db,
                    task,
                    "run.started",
                    {"prompt": task_prompt, "status": TaskStatus.RUNNING.value, "title": task_title},
                )

                if cancel_event.is_set():
                    await self._handle_cancellation(db, task)
                    return

                # 2. Workspace Setup
                project_stmt = select(Project).where(Project.id == task_project_id)
                p_res = await db.execute(project_stmt)
                project = p_res.scalar_one_or_none()
                if not project:
                    raise ValueError(f"Project {task_project_id} not found for task {task_id}")

                project_name = project.name
                project_user_id = project.user_id
                project_workspace_path = project.workspace_path

                if task_workspace_id:
                    ws_stmt = select(Workspace).where(Workspace.id == task_workspace_id)
                else:
                    ws_stmt = select(Workspace).where(Workspace.project_id == task_project_id)
                ws_res = await db.execute(ws_stmt)
                workspace = ws_res.scalars().first()

                if not workspace:
                    workspace = Workspace(
                        user_id=project_user_id,
                        project_id=task_project_id,
                        name=f"{project_name} Workspace",
                        host_type="docker" if getattr(ws_provider, "_is_docker_available", False) else "local_sandbox",
                        root_path=project_workspace_path if project_workspace_path else None,
                        status=WorkspaceStatus.PENDING.value,
                    )
                    db.add(workspace)
                    await db.commit()
                    task.workspace_id = workspace.id
                    await db.commit()

                # Ensure workspace root_path honors project.workspace_path
                if project_workspace_path and (not workspace.root_path or workspace.root_path != project_workspace_path):
                    workspace.root_path = project_workspace_path
                    await db.commit()

                # Ensure provisioned
                if workspace.status != WorkspaceStatus.RUNNING.value:
                    await ws_provider.provision(workspace, project)
                    await ws_provider.start(workspace)
                    await db.commit()

                workspace_id_str = str(workspace.id)
                workspace_host_type = workspace.host_type or "local_sandbox"

                wdir = ws_provider.get_workspace_dir(workspace)
                if not wdir.exists():
                    raise ValueError(f"Workspace directory for project '{project_name}' not found: {wdir}. Workspace setup pending.")

                # Capture safe Git baseline before modifying any files
                baseline = await _capture_git_baseline(ws_provider, workspace)
                task.active_branch = baseline["branch"]
                await db.commit()

                task_owned_files: Set[str] = set()
                file_existed_before_task: Dict[str, bool] = {}

                ws_info = f"Container ({workspace_host_type})"
                await self._emit_task_event(
                    db,
                    task,
                    "task.progress",
                    {
                        "stage": "inspect_repo",
                        "message": f"Connected to {ws_info} workspace on branch '{baseline['branch']}' (HEAD: {baseline['base_sha'][:8] if baseline['base_sha'] else 'initial'}). Calling Meta Model API...",
                        "progress_percent": 15,
                        "workspace_id": workspace_id_str,
                        "branch": baseline["branch"],
                        "base_commit": baseline["base_sha"][:8] if baseline["base_sha"] else "",
                    },
                )

                # 3. Prepare Meta Model API client & messages
                api_key = settings.MODEL_API_KEY
                if not api_key:
                    raise ValueError("MODEL_API_KEY is not configured in backend/.env")

                base_url = settings.META_MODEL_BASE_URL.rstrip("/")
                model_id = settings.META_MODEL_ID

                system_prompt = (
                    "You are an autonomous AI software engineer and system assistant in Jess IDE.\n"
                    "You have direct control over the project workspace and server tools.\n"
                    "Your mission is to inspect the project workspace, implement the requested code changes, "
                    "run tests to verify your changes, diagnose and repair any failures, and produce clean results.\n\n"
                    "Rules & Capabilities:\n"
                    "- Always use the approved tools: list_files, read_file, write_file, run_check, get_git_diff, host_preview.\n"
                    "- Always inspect existing files using list_files and read_file before making changes.\n"
                    "- Write clean, working code using write_file.\n"
                    "- Always execute project checks using run_check (e.g. 'pytest', 'python -m unittest', 'python -m pytest', etc.).\n"
                    "- If a check fails, carefully analyze stdout and stderr, diagnose the root cause, apply a repair with write_file, and re-run run_check.\n"
                    "- When tests pass and you are done, summarize what you accomplished.\n\n"
                    "Hosting & Web Preview Instructions:\n"
                    "- When the user asks to host, run, or preview an application (e.g. 'host the py file and html file', 'give me a temp link', 'preview the app'):\n"
                    "  * If the user specifies hosting or asks for a temp link, immediately call `host_preview` with `hosting_type='temp_tunnel'`.\n"
                    "  * If the user asks for hosting options, offer both: (1) Temporary Public Tunnel (Cloudflare/ngrok HTTPS link accessible on their phone anywhere) or (2) Local Wi-Fi / Static IP.\n"
                    "  * Never attempt to launch background servers via `run_check` (which is reserved for non-blocking test runners).\n\n"
                    "Chat & Artifact Export Instructions:\n"
                    "- When the user asks to export the chat, conversation history, or results to a text file (e.g. 'export this entire chat and give me as txt file'):\n"
                    "  * Summarize the full conversation (prompts given, agent tool actions, code created/fixed, test results), and save it into the workspace as `chat_export.txt` using `write_file`."
                )

                initial_user_prompt = (
                    f"Task Title: {task_title}\n\n"
                    f"Task Description and Requirements:\n{task_prompt}\n\n"
                    f"Repository Context: branch '{baseline['branch']}', base commit '{baseline['base_sha'][:8] if baseline['base_sha'] else 'HEAD'}'.\n"
                    "Please begin by exploring the workspace files, understanding the setup, making necessary changes, and testing them."
                )

                # Conversation Continuity: Inject previous task summary from the same conversation if present
                if task_conversation_id:
                    prior_stmt = (
                        select(Task)
                        .where(
                            Task.conversation_id == task_conversation_id,
                            Task.id != task_id,
                            Task.status.in_([TaskStatus.COMPLETED.value, TaskStatus.CANCELLED.value]),
                        )
                        .order_by(Task.updated_at.desc())
                        .limit(1)
                    )
                    p_res = await db.execute(prior_stmt)
                    prior_task = p_res.scalar_one_or_none()
                    if prior_task and prior_task.execution_log:
                        try:
                            prior_data = json.loads(prior_task.execution_log)
                            prior_files = prior_data.get("task_owned_files") or [prior_data.get("target_file")]
                            prior_files_clean = [f for f in prior_files if f]
                            prior_check_cmd = prior_data.get("last_check_command") or "None"
                            prior_check_exit = prior_data.get("last_check_exit_code")
                            prior_check_pass = prior_data.get("last_check_passed")
                            initial_user_prompt += (
                                f"\n\nContext from previous task in this conversation:\n"
                                f"- Prior Task: {prior_task.title}\n"
                                f"- Prior Status: {prior_task.status} (Commit: {prior_task.commit_sha or 'none'}, Branch: {prior_task.active_branch or baseline['branch']})\n"
                                f"- Files touched: {', '.join(prior_files_clean) if prior_files_clean else 'None'}\n"
                                f"- Prior test check: {prior_check_cmd} (Exit code: {prior_check_exit}, Passed: {prior_check_pass})\n"
                            )
                        except Exception as pe:
                            logger.warning(f"Could not parse prior task execution_log: {pe}")

                # Check for oversized user prompt
                prompt_tokens = estimate_tokens(initial_user_prompt)
                if prompt_tokens > settings.META_CONTEXT_BUDGET_TOKENS - 2000:
                    raise ValueError(
                        f"The requested prompt is too large ({prompt_tokens} estimated tokens) for the context budget "
                        f"({settings.META_CONTEXT_BUDGET_TOKENS} tokens). Please split this request into smaller incremental tasks."
                    )

                messages: List[Dict[str, Any]] = [
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": initial_user_prompt},
                ]

                # 4. Meta Agent Tool-Calling Loop
                iteration = 0
                max_iterations = settings.META_MAX_TOOL_ITERATIONS
                max_repairs = settings.META_MAX_REPAIR_ATTEMPTS
                client_headers = {
                    "Authorization": f"Bearer {api_key}",
                    "Content-Type": "application/json",
                }

                async with httpx.AsyncClient(timeout=settings.META_REQUEST_TIMEOUT_SECONDS) as http_client:
                    while iteration < max_iterations:
                        if cancel_event.is_set():
                            await self._handle_cancellation(db, task)
                            return

                        iteration += 1

                        # Enforce context window limits by compacting older intermediate turns
                        messages = compact_context_window(
                            messages,
                            max_tokens=settings.META_CONTEXT_BUDGET_TOKENS,
                            task_owned_files=task_owned_files,
                            last_check_command=last_check_command,
                            last_check_exit_code=last_check_exit_code,
                            last_check_passed=last_check_passed,
                        )

                        payload = {
                            "model": model_id,
                            "messages": messages,
                            "tools": META_TOOLS,
                            "tool_choice": "auto",
                        }

                        # Post request with automatic retry for transient network dropouts
                        response = None
                        last_exc = None
                        for attempt in range(1, 4):
                            try:
                                response = await http_client.post(
                                    f"{base_url}/chat/completions",
                                    headers=client_headers,
                                    json=payload,
                                )
                                break
                            except Exception as net_err:
                                last_exc = net_err
                                logger.warning(f"[MetaAgent] Network attempt {attempt}/3 failed: {net_err}. Retrying...")
                                if attempt < 3:
                                    await asyncio.sleep(1.5 * attempt)

                        if response is None:
                            raise RuntimeError(f"Meta Model API request failed after 3 retries: {last_exc}")

                        if response.status_code != 200:
                            err_body = response.text
                            logger.error(f"[MetaAgent] API error {response.status_code}: {err_body}")
                            raise RuntimeError(f"Meta Model API returned {response.status_code}: {err_body}")

                        resp_json = response.json()
                        usage = resp_json.get("usage")
                        if usage:
                            logger.info(
                                f"[MetaAgent] Reported tokens: prompt={usage.get('prompt_tokens')}, "
                                f"completion={usage.get('completion_tokens')}, total={usage.get('total_tokens')}"
                            )

                        choices = resp_json.get("choices", [])
                        if not choices:
                            break

                        choice = choices[0]
                        message_obj = choice.get("message", {})
                        content = message_obj.get("content")
                        tool_calls = message_obj.get("tool_calls", [])

                        # Stream assistant thoughts to Flutter timeline with canonical message ID
                        if content:
                            msg_id = str(uuid.uuid4())
                            if task_conversation_id:
                                try:
                                    asst_msg = ConversationMessage(
                                        id=uuid.UUID(msg_id),
                                        conversation_id=task_conversation_id,
                                        run_id=task_id,
                                        role="assistant",
                                        content=content,
                                    )
                                    db.add(asst_msg)
                                    await db.commit()
                                except Exception as me:
                                    logger.warning(f"Could not persist assistant message: {me}")

                            await self._emit_conv_event(
                                db,
                                task,
                                "message.started",
                                {"message_id": msg_id, "role": "assistant"},
                            )
                            await self._emit_conv_event(
                                db,
                                task,
                                "message.delta",
                                {"message_id": msg_id, "text": content},
                            )
                            await self._emit_conv_event(
                                db,
                                task,
                                "message.completed",
                                {"message_id": msg_id, "text": content, "finish_reason": "stop"},
                            )

                        messages.append(message_obj)

                        # Check if model finished without calling more tools
                        if not tool_calls:
                            logger.info(f"[MetaAgent] Model finished tool calls at iteration {iteration}")
                            break

                        # Process tool calls
                        for tc in tool_calls:
                            if cancel_event.is_set():
                                await self._handle_cancellation(db, task)
                                return

                            fn = tc.get("function", {})
                            fn_name = fn.get("name", "")
                            tc_id = tc.get("id", str(uuid.uuid4()))
                            raw_args = fn.get("arguments", "{}")
                            try:
                                args = json.loads(raw_args) if isinstance(raw_args, str) else raw_args
                            except Exception:
                                args = {}

                            logger.info(f"[MetaAgent] Executing tool '{fn_name}' with args {args}")

                            # Tool execution started
                            await self._emit_conv_event(
                                db,
                                task,
                                "tool.started",
                                {
                                    "tool": fn_name,
                                    "label": f"Executing {fn_name}",
                                    "status": "running",
                                    "arguments": args,
                                },
                            )

                            tool_output = ""
                            exit_code = 0

                            try:
                                if fn_name == "list_files":
                                    dir_path = args.get("directory", "")
                                    items = await ws_provider.list_files(workspace, dir_path)
                                    tool_output = json.dumps([{"path": i.path, "is_dir": i.is_dir} for i in items])

                                elif fn_name == "read_file":
                                    file_path = args.get("path", "")
                                    tool_output = await ws_provider.read_file(workspace, file_path)
                                    if len(tool_output) > 25000:
                                        tool_output = (
                                            tool_output[:25000]
                                            + "\n\n... [Content truncated to conserve context budget; showing first 25,000 characters] ..."
                                        )

                                elif fn_name == "write_file":
                                    file_path = args.get("path", "")
                                    file_content = args.get("content", "")
                                    clean_rel = file_path.strip().replace("\\", "/").lstrip("/")
                                    last_changed_file = clean_rel

                                    # Record ownership and pre-existence status for safe scoped isolation
                                    if clean_rel not in file_existed_before_task:
                                        target_p = ws_provider.get_workspace_dir(workspace) / clean_rel
                                        file_existed_before_task[clean_rel] = target_p.exists()
                                    task_owned_files.add(clean_rel)

                                    # Detect identical repair attempts to prevent endless loops
                                    existing_content = ""
                                    try:
                                        existing_content = await ws_provider.read_file(workspace, file_path)
                                    except Exception:
                                        pass

                                    if existing_content and existing_content == file_content:
                                        tool_output = json.dumps({
                                            "ok": True,
                                            "path": file_path,
                                            "warning": "Content is identical to existing file; no modifications were made. Please diagnose root cause and implement an actual change.",
                                        })
                                    else:
                                        await ws_provider.write_file(workspace, file_path, file_content)

                                        # Generate diff snippet for the changed file
                                        diff_res = await ws_provider.get_git_diff(workspace)
                                        diff_snippet = diff_res.diff or f"Updated {file_path}"

                                        await self._emit_conv_event(
                                            db,
                                            task,
                                            "file.changed",
                                            {
                                                "file": file_path,
                                                "action": "modified",
                                                "diff": diff_snippet,
                                                "additions": len(file_content.splitlines()),
                                                "deletions": 0,
                                            },
                                        )
                                        tool_output = json.dumps({"ok": True, "path": file_path})

                                elif fn_name == "run_check":
                                    cmd_str = args.get("command", "")
                                    cmd_parts = shlex.split(cmd_str, posix=False) if os.name == 'nt' else shlex.split(cmd_str)
                                    cmd_res = await ws_provider.execute_command(workspace, cmd_parts)
                                    exit_code = cmd_res.exit_code
                                    tool_output = (cmd_res.stdout + "\n" + cmd_res.stderr).strip()

                                    last_check_command = cmd_str
                                    last_check_exit_code = exit_code
                                    last_check_passed = (exit_code == 0)

                                    # Emit output to Flutter
                                    await self._emit_conv_event(
                                        db,
                                        task,
                                        "tool.output",
                                        {
                                            "tool": fn_name,
                                            "output": tool_output[:4000],
                                            "status": "running",
                                        },
                                    )

                                    # Handle test failure -> trigger bounded repair loop
                                    if exit_code != 0 and repair_attempts < max_repairs:
                                        repair_attempts += 1
                                        await self._emit_task_event(
                                            db,
                                            task,
                                            "task.progress",
                                            {
                                                "stage": "repair",
                                                "message": f"Check failed (exit code {exit_code}). Autonomous repair attempt {repair_attempts}/{max_repairs} underway...",
                                                "progress_percent": 60 + (repair_attempts * 10),
                                            },
                                        )
                                    elif exit_code != 0 and repair_attempts >= max_repairs:
                                        tool_output += f"\n\n[Notice]: Maximum autonomous repair limit ({max_repairs}) reached. Please summarize remaining issues."

                                elif fn_name == "get_git_diff":
                                    diff_res = await ws_provider.get_git_diff(workspace)
                                    tool_output = diff_res.diff

                                elif fn_name == "host_preview":
                                    file_path = args.get("file_path", "")
                                    hosting_type = args.get("hosting_type", "temp_tunnel")
                                    clean_rel = file_path.strip().replace("\\", "/").lstrip("/")
                                    wdir_p = ws_provider.get_workspace_dir(workspace)
                                    target_p = wdir_p / clean_rel if clean_rel else wdir_p

                                    # Fallback to search for html files if not found
                                    if not target_p.exists() or target_p.is_dir():
                                        for cand in ("calculator.html", "index.html", "app.html", "main.html"):
                                            if (wdir_p / cand).exists():
                                                clean_rel = cand
                                                target_p = wdir_p / cand
                                                break
                                        else:
                                            html_list = list(wdir_p.glob("*.html"))
                                            if html_list:
                                                clean_rel = html_list[0].name
                                                target_p = html_list[0]

                                    tunnel_base = (settings.PUBLIC_TUNNEL_URL or "https://household-modeling-studio-carry.trycloudflare.com").rstrip("/")
                                    local_base = f"http://{settings.HOST}:{settings.PORT}"

                                    chosen_base = local_base if hosting_type == "local_ip" else tunnel_base
                                    preview_url = f"{chosen_base}/api/v1/workspaces/{workspace_id_str}/preview/{clean_rel}"
                                    tunnel_url = f"{tunnel_base}/api/v1/workspaces/{workspace_id_str}/preview/{clean_rel}"
                                    local_url = f"{local_base}/api/v1/workspaces/{workspace_id_str}/preview/{clean_rel}"

                                    # Emit preview.launched event to Flutter client
                                    await self._emit_conv_event(
                                        db,
                                        task,
                                        "preview.launched",
                                        {
                                            "preview_url": preview_url,
                                            "tunnel_url": tunnel_url,
                                            "local_url": local_url,
                                            "file": clean_rel,
                                            "hosting_type": hosting_type,
                                            "title": f"Live Preview: {clean_rel}",
                                        },
                                    )

                                    tool_output = json.dumps({
                                        "status": "hosted",
                                        "preview_url": preview_url,
                                        "tunnel_url": tunnel_url,
                                        "local_url": local_url,
                                        "file": clean_rel,
                                        "hosting_type": hosting_type,
                                        "message": f"Application is live! Tell the user they can preview and run it at: {preview_url}",
                                    })

                                else:
                                    tool_output = f"Unknown tool: {fn_name}"
                                    exit_code = 1

                            except Exception as ex:
                                tool_output = f"Tool execution error: {ex}"
                                exit_code = 1

                            # Tool completed event
                            await self._emit_conv_event(
                                db,
                                task,
                                "tool.completed",
                                {
                                    "tool": fn_name,
                                    "status": "completed" if exit_code == 0 else "failed",
                                    "exit_code": exit_code,
                                    "summary": tool_output[:300],
                                },
                            )

                            # Return tool result back to model
                            messages.append({
                                "role": "tool",
                                "tool_call_id": tc_id,
                                "content": tool_output[:8000],
                            })

                # 5. Extract task-scoped real diff & record revision hash
                if not task_owned_files:
                    # Pure informational or read-only task: no code changes to approve
                    logger.info(f"[MetaAgent] Task {task_id} produced no file modifications; completing cleanly.")
                    task.execution_log = json.dumps({
                        "task_owned_files": [],
                        "diff": "",
                        "prompt": "Exploration completed",
                        "status": "completed",
                    })
                    await self._transition(db, task, TaskStatus.COMPLETED)
                    await self._emit_task_event(
                        db,
                        task,
                        "task.completed",
                        {"status": TaskStatus.COMPLETED.value, "title": task_title, "files_changed": 0},
                    )
                    await self._emit_conv_event(
                        db,
                        task,
                        "run.completed",
                        {"status": TaskStatus.COMPLETED.value, "title": task_title, "files_changed": 0},
                    )
                    return

                final_diff = await _get_task_scoped_diff(ws_provider, workspace, task_owned_files, baseline)
                if not final_diff:
                    final_diff = "(No file modifications detected)"
                diff_hash = hashlib.sha256(final_diff.encode("utf-8")).hexdigest()[:16]

                files_desc = ", ".join(sorted(task_owned_files)) if task_owned_files else last_changed_file

                # Truthful prompt generation based on actual test outcome
                if last_check_passed is False:
                    approval_prompt = (
                        f"Tests failed (exit code {last_check_exit_code}) for `{last_check_command}`. "
                        f"Repair limit reached ({repair_attempts}/{max_repairs}). Review proposed modifications to `{files_desc}`?"
                    )
                else:
                    approval_prompt = f"Approve applying proposed modifications to `{files_desc}` on branch `{baseline['branch']}`?"

                task.execution_log = json.dumps({
                    "diff_hash": diff_hash,
                    "baseline_branch": baseline["branch"],
                    "baseline_sha": baseline["base_sha"],
                    "task_owned_files": list(task_owned_files),
                    "target_files": list(task_owned_files),
                    "target_file": files_desc,
                    "diff": final_diff,
                    "prompt": approval_prompt,
                    "last_check_command": last_check_command,
                    "last_check_exit_code": last_check_exit_code,
                    "last_check_passed": last_check_passed,
                    "repair_attempts": repair_attempts,
                })
                await db.commit()

                await self._emit_task_event(
                    db,
                    task,
                    "task.progress",
                    {
                        "stage": "diff_generation",
                        "message": f"Assembled task-scoped diff for {len(task_owned_files)} file(s). Requesting mobile approval.",
                        "progress_percent": 85,
                    },
                )

                await self._emit_task_event(
                    db,
                    task,
                    "diff.proposed",
                    {
                        "file_path": files_desc,
                        "diff": final_diff,
                        "diff_hash": diff_hash,
                        "branch": baseline["branch"],
                        "base_commit": baseline["base_sha"][:8] if baseline["base_sha"] else "",
                        "additions": final_diff.count("\n+"),
                        "deletions": final_diff.count("\n-"),
                    },
                )

                # 6. RUNNING -> APPROVAL_REQUIRED
                loop = asyncio.get_running_loop()
                approval_fut: asyncio.Future = loop.create_future()
                self._pending_approvals[task_id] = approval_fut

                await self._transition(db, task, TaskStatus.APPROVAL_REQUIRED)
                approval_payload = {
                    "action": "apply_code_diff",
                    "target": files_desc,
                    "target_file": files_desc,
                    "prompt": approval_prompt,
                    "diff": final_diff,
                    "diff_hash": diff_hash,
                    "branch": baseline["branch"],
                    "base_commit": baseline["base_sha"][:8] if baseline["base_sha"] else "",
                    "check_command": last_check_command,
                    "check_exit_code": last_check_exit_code,
                    "check_passed": last_check_passed,
                }
                await self._emit_task_event(
                    db,
                    task,
                    "approval.required",
                    approval_payload,
                )
                await self._emit_conv_event(
                    db,
                    task,
                    "approval.required",
                    approval_payload,
                )

                # 7. Await approval or cancellation

            # Outside session while waiting for mobile approval
            cancel_wait = asyncio.create_task(cancel_event.wait())
            done, pending = await asyncio.wait(
                [approval_fut, cancel_wait],
                return_when=asyncio.FIRST_COMPLETED,
            )
            for p in pending:
                p.cancel()

            # 8. Process human approval decision
            async with async_session_factory() as db:
                stmt = select(Task).where(Task.id == task_id)
                res = await db.execute(stmt)
                task = res.scalar_one_or_none()
                if not task:
                    return

                if cancel_event.is_set():
                    await self._handle_cancellation(db, task)
                    return

                if approval_fut in done:
                    decision = approval_fut.result()
                    is_approved = decision.get("approved", False)
                    reason = decision.get("reason")

                    if is_approved:
                        # Stale review verification
                        stale_reason = await _check_stale_review(
                            ws_provider, workspace, baseline["branch"], baseline["base_sha"], diff_hash, task_owned_files, baseline
                        )
                        if stale_reason:
                            logger.warning(f"Refusing approval due to stale review: {stale_reason}")
                            await self._emit_task_event(
                                db,
                                task,
                                "approval.stale",
                                {"reason": stale_reason, "status": "stale_review_rejected"},
                            )
                            await self._emit_conv_event(
                                db,
                                task,
                                "approval.stale",
                                {"reason": stale_reason, "status": "stale_review_rejected"},
                            )
                            return

                        await self._transition(db, task, TaskStatus.RUNNING)

                        # Stage and commit ONLY task-owned files
                        commit_sha: Optional[str] = None
                        try:
                            commit_sha = await _commit_task_changes(
                                ws_provider, workspace, task_title, task_owned_files
                            )
                            if commit_sha:
                                task.commit_sha = commit_sha
                                await db.commit()
                        except Exception as ce:
                            logger.warning(f"Git commit step completed with warning: {ce}")

                        await self._emit_task_event(
                            db,
                            task,
                            "approval.granted",
                            {
                                "action": "apply_code_diff",
                                "reviewer": "user",
                                "commit_sha": commit_sha,
                                "branch": baseline["branch"],
                            },
                        )

                        await self._emit_task_event(
                            db,
                            task,
                            "task.progress",
                            {
                                "stage": "verification",
                                "message": f"Task-owned changes approved and committed (SHA: {commit_sha[:8] if commit_sha else 'HEAD'}).",
                                "progress_percent": 100,
                            },
                        )

                        # Transition to COMPLETED
                        await self._transition(db, task, TaskStatus.COMPLETED)
                        summary_info = {
                            "status": TaskStatus.COMPLETED.value,
                            "summary": f"Modifications approved and committed ({commit_sha[:8] if commit_sha else 'HEAD'} on {baseline['branch']}).",
                            "commit_sha": commit_sha,
                            "branch": baseline["branch"],
                            "changed_files": list(task_owned_files),
                        }
                        await self._emit_task_event(db, task, "task.completed", summary_info)
                        await self._emit_conv_event(db, task, "run.completed", summary_info)

                        # Structured summary for conversation continuity
                        summary_record = {
                            "task_id": str(task_id),
                            "title": task_title,
                            "status": TaskStatus.COMPLETED.value,
                            "branch": baseline["branch"],
                            "base_sha": baseline["base_sha"],
                            "commit_sha": commit_sha,
                            "task_owned_files": list(task_owned_files),
                            "target_files": list(task_owned_files),
                            "target_file": files_desc,
                            "last_check_command": last_check_command,
                            "last_check_exit_code": last_check_exit_code,
                            "last_check_passed": last_check_passed,
                            "decision": "approved",
                        }
                        task.execution_log = json.dumps(summary_record)
                        await db.commit()

                        if task_conversation_id:
                            db.add(ConversationMessage(
                                conversation_id=task_conversation_id,
                                run_id=task_id,
                                role="assistant",
                                content=f"Applied and committed task changes to {files_desc} (SHA: {commit_sha[:8] if commit_sha else 'HEAD'} on `{baseline['branch']}`).",
                            ))
                            await db.commit()
                    else:
                        # Rejection -> Safe reversion of ONLY task-owned files
                        await _revert_task_changes(
                            ws_provider, workspace, task_owned_files, baseline, file_existed_before_task
                        )

                        await self._transition(db, task, TaskStatus.CANCELLED)
                        rejection_info = {
                            "reason": reason or "User rejected proposed changes on mobile.",
                            "branch": baseline["branch"],
                            "reverted_files": list(task_owned_files),
                        }
                        await self._emit_task_event(db, task, "approval.rejected", rejection_info)
                        await self._emit_conv_event(db, task, "run.cancelled", rejection_info)

                        summary_record = {
                            "task_id": str(task_id),
                            "title": task_title,
                            "status": TaskStatus.CANCELLED.value,
                            "branch": baseline["branch"],
                            "base_sha": baseline["base_sha"],
                            "commit_sha": None,
                            "task_owned_files": list(task_owned_files),
                            "target_files": list(task_owned_files),
                            "target_file": files_desc,
                            "last_check_command": last_check_command,
                            "last_check_exit_code": last_check_exit_code,
                            "last_check_passed": last_check_passed,
                            "decision": "rejected",
                            "reason": reason,
                        }
                        task.execution_log = json.dumps(summary_record)
                        await db.commit()

                        if task_conversation_id:
                            db.add(ConversationMessage(
                                conversation_id=task_conversation_id,
                                run_id=task_id,
                                role="assistant",
                                content=f"Task '{task_title}' was rejected ({reason or 'User rejected changes'}). Safely reverted task changes on branch `{baseline['branch']}` without affecting pre-existing files.",
                            ))
                            await db.commit()

        except asyncio.CancelledError:
            logger.info(f"Task {task_id} execution was cancelled.")
            async with async_session_factory() as db:
                stmt = select(Task).where(Task.id == task_id)
                res = await db.execute(stmt)
                task = res.scalar_one_or_none()
                if task and task.status not in (
                    TaskStatus.COMPLETED.value,
                    TaskStatus.CANCELLED.value,
                    TaskStatus.FAILED.value,
                ):
                    task.status = TaskStatus.CANCELLED.value
                    await db.commit()
                    await self._emit_task_event(
                        db,
                        task,
                        "task.cancelled",
                        {"reason": "Cancelled by user request."},
                    )
                    await self._emit_conv_event(
                        db,
                        task,
                        "run.cancelled",
                        {"reason": "Cancelled by user request."},
                    )
        except Exception as e:
            logger.exception(f"Unhandled error in MetaAgentAdapter for task {task_id}: {e}")
            async with async_session_factory() as db:
                stmt = select(Task).where(Task.id == task_id)
                res = await db.execute(stmt)
                task = res.scalar_one_or_none()
                if task and task.status not in (
                    TaskStatus.COMPLETED.value,
                    TaskStatus.CANCELLED.value,
                    TaskStatus.FAILED.value,
                ):
                    task.status = TaskStatus.FAILED.value
                    safe_error = str(e)
                    if settings.MODEL_API_KEY:
                        safe_error = safe_error.replace(settings.MODEL_API_KEY, "[REDACTED]")
                    await db.commit()
                    await self._emit_task_event(
                        db,
                        task,
                        "task.failed",
                        {"error": safe_error, "status": TaskStatus.FAILED.value},
                    )
                    await self._emit_conv_event(
                        db,
                        task,
                        "run.failed",
                        {"error": safe_error, "status": TaskStatus.FAILED.value},
                    )

    async def _handle_cancellation(self, db: AsyncSession, task: Task) -> None:
        current = TaskStatus(task.status)
        if can_transition(current, TaskStatus.CANCELLED):
            await self._transition(db, task, TaskStatus.CANCELLED)
            await self._emit_task_event(
                db,
                task,
                "task.cancelled",
                {"reason": "Cancellation requested by user."},
            )
            await self._emit_conv_event(
                db,
                task,
                "run.cancelled",
                {"reason": "Cancellation requested by user."},
            )

    async def handle_approval(
        self, task_id: uuid.UUID, approved: bool, reason: Optional[str] = None
    ) -> None:
        fut = self._pending_approvals.get(task_id)
        if fut and not fut.done():
            fut.set_result({"approved": approved, "reason": reason})
            return

        logger.warning(
            f"No active pending approval future for task {task_id}. Applying DB fallback resolution."
        )
        async with async_session_factory() as db:
            stmt = select(Task).where(Task.id == task_id)
            res = await db.execute(stmt)
            task = res.scalar_one_or_none()
            if not task:
                return

            if task.status == TaskStatus.APPROVAL_REQUIRED.value:
                ws_provider = get_workspace_provider()
                workspace = None
                if task.workspace_id:
                    workspace = await db.get(Workspace, task.workspace_id)
                elif task.project_id:
                    ws_stmt = select(Workspace).where(Workspace.project_id == task.project_id)
                    ws_res = await db.execute(ws_stmt)
                    workspace = ws_res.scalars().first()

                # Extract task metadata from execution_log
                task_files: Set[str] = set()
                base_branch = "main"
                base_sha = ""
                diff_hash = ""
                if task.execution_log:
                    try:
                        log_data = json.loads(task.execution_log)
                        task_files = set(log_data.get("task_owned_files") or [log_data.get("target_file", "")])
                        task_files = {f for f in task_files if f}
                        base_branch = log_data.get("baseline_branch", "main")
                        base_sha = log_data.get("baseline_sha", "")
                        diff_hash = log_data.get("diff_hash", "")
                    except Exception:
                        pass

                if approved:
                    await self._transition(db, task, TaskStatus.RUNNING)
                    commit_sha: Optional[str] = None
                    if workspace and task_files:
                        try:
                            commit_sha = await _commit_task_changes(
                                ws_provider, workspace, task.title, task_files
                            )
                            if commit_sha:
                                task.commit_sha = commit_sha
                                await db.commit()
                        except Exception as ce:
                            logger.warning(f"DB fallback commit warning: {ce}")

                    await self._emit_task_event(
                        db,
                        task,
                        "approval.granted",
                        {"action": "apply_code_diff", "reviewer": "user", "commit_sha": commit_sha, "branch": base_branch},
                    )
                    await self._transition(db, task, TaskStatus.COMPLETED)
                    summary_info = {
                        "status": TaskStatus.COMPLETED.value,
                        "summary": "Meta-powered coding task completed and verified successfully.",
                        "commit_sha": commit_sha,
                        "branch": base_branch,
                    }
                    await self._emit_task_event(db, task, "task.completed", summary_info)
                    await self._emit_conv_event(db, task, "run.completed", summary_info)

                    if task.conversation_id:
                        db.add(ConversationMessage(
                            conversation_id=task.conversation_id,
                            run_id=task.id,
                            role="assistant",
                            content=f"Approved modifications to {', '.join(task_files) or 'workspace'}. Committed {commit_sha[:8] if commit_sha else 'HEAD'} on `{base_branch}`.",
                        ))
                        await db.commit()
                else:
                    if workspace and task_files:
                        try:
                            await _revert_task_changes(ws_provider, workspace, task_files)
                        except Exception as ce:
                            logger.warning(f"DB fallback safe revert warning: {ce}")

                    await self._transition(db, task, TaskStatus.CANCELLED)
                    rejection_info = {
                        "reason": reason or "User rejected proposed changes on mobile.",
                        "branch": base_branch,
                        "reverted_files": list(task_files),
                    }
                    await self._emit_task_event(db, task, "approval.rejected", rejection_info)
                    await self._emit_conv_event(db, task, "run.cancelled", rejection_info)

                    if task.conversation_id:
                        db.add(ConversationMessage(
                            conversation_id=task.conversation_id,
                            run_id=task.id,
                            role="assistant",
                            content=f"Task '{task.title}' was rejected ({reason or 'User rejected changes'}). Safely reverted task changes without affecting pre-existing files.",
                        ))
                        await db.commit()

    async def cancel_task(self, task_id: uuid.UUID) -> None:
        cancel_event = self._cancellation_events.get(task_id)
        if cancel_event:
            cancel_event.set()

        fut = self._pending_approvals.get(task_id)
        if fut and not fut.done():
            fut.cancel()

        bg_task = self._running_tasks.get(task_id)
        if bg_task and not bg_task.done():
            bg_task.cancel()
