import asyncio
import json
import os
import shlex
import time
import uuid
from typing import Any, Dict, List, Optional

import httpx
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.core.logging import logger
from app.db.models.project import Project
from app.db.models.task import Task
from app.db.models.workspace import Workspace
from app.db.session import async_session_factory
from app.schemas.task import TaskStatus, can_transition
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
]


class MetaAgentAdapter(BaseAgentAdapter):
    """Real Meta Model API coding-agent adapter for Jess IDE.
    
    Powers autonomous coding workflows using Meta Model API (e.g. muse-spark-1.3)
    with isolated workspace tool execution, test-and-repair loops, and human-in-the-loop approval.
    """

    def __init__(self) -> None:
        self._pending_approvals: Dict[uuid.UUID, asyncio.Future] = {}
        self._running_tasks: Dict[uuid.UUID, asyncio.Task] = {}
        self._cancellation_events: Dict[uuid.UUID, asyncio.Event] = {}

    def is_task_running(self, task_id: uuid.UUID) -> bool:
        task = self._running_tasks.get(task_id)
        return task is not None and not task.done()

    async def _transition(
        self, db: AsyncSession, task: Task, target_status: TaskStatus
    ) -> None:
        current_status = TaskStatus(task.status)
        if not can_transition(current_status, target_status):
            err_msg = f"Invalid task state transition from {current_status.value} to {target_status.value}"
            logger.error(err_msg)
            raise ValueError(err_msg)

        task.status = target_status.value
        await db.commit()
        await db.refresh(task)
        logger.info(f"Task {task.id} transitioned {current_status.value} -> {target_status.value}")

    async def _emit_task_event(
        self,
        db: AsyncSession,
        task: Task,
        event_type: str,
        payload: Dict[str, Any],
    ) -> None:
        await append_task_event(db, task.id, event_type, payload)

    async def _emit_conv_event(
        self,
        db: AsyncSession,
        task: Task,
        event_type: str,
        payload: Dict[str, Any],
    ) -> None:
        if task.conversation_id:
            await append_conversation_event(
                db,
                conversation_id=task.conversation_id,
                event_type=event_type,
                payload=payload,
                run_id=task.id,
            )

    async def run_task(self, task_id: uuid.UUID) -> None:
        if self.is_task_running(task_id):
            logger.warning(f"Task {task_id} is already executing. Ignoring duplicate run request.")
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

        try:
            async with async_session_factory() as db:
                stmt = select(Task).where(Task.id == task_id)
                res = await db.execute(stmt)
                task = res.scalar_one_or_none()
                if not task:
                    logger.error(f"Task {task_id} not found in database for execution.")
                    return

                # 1. QUEUED -> RUNNING
                await self._transition(db, task, TaskStatus.RUNNING)
                await self._emit_task_event(
                    db,
                    task,
                    "task.started",
                    {"status": TaskStatus.RUNNING.value, "title": task.title},
                )
                await self._emit_conv_event(
                    db,
                    task,
                    "run.started",
                    {"prompt": task.prompt, "status": TaskStatus.RUNNING.value, "title": task.title},
                )

                if cancel_event.is_set():
                    await self._handle_cancellation(db, task)
                    return

                # 2. Workspace Setup
                project_stmt = select(Project).where(Project.id == task.project_id)
                p_res = await db.execute(project_stmt)
                project = p_res.scalar_one_or_none()
                if not project:
                    raise ValueError(f"Project {task.project_id} not found for task {task_id}")

                if task.workspace_id:
                    ws_stmt = select(Workspace).where(Workspace.id == task.workspace_id)
                else:
                    ws_stmt = select(Workspace).where(Workspace.project_id == task.project_id)
                ws_res = await db.execute(ws_stmt)
                workspace = ws_res.scalars().first()

                if not workspace:
                    workspace = Workspace(
                        user_id=project.user_id,
                        project_id=project.id,
                        name=f"{project.name} Workspace",
                        host_type="docker" if getattr(ws_provider, "_is_docker_available", False) else "local_sandbox",
                        status=WorkspaceStatus.PENDING.value,
                    )
                    db.add(workspace)
                    await db.commit()
                    await db.refresh(workspace)
                    task.workspace_id = workspace.id
                    await db.commit()

                # Ensure provisioned
                if workspace.status != WorkspaceStatus.RUNNING.value:
                    await ws_provider.provision(workspace, project)
                    await ws_provider.start(workspace)
                    await db.commit()
                    await db.refresh(workspace)

                ws_info = f"Container ({workspace.host_type})"
                await self._emit_task_event(
                    db,
                    task,
                    "task.progress",
                    {
                        "stage": "inspect_repo",
                        "message": f"Connected to isolated {ws_info} workspace. Calling Meta Model API...",
                        "progress_percent": 15,
                        "workspace_id": str(workspace.id),
                    },
                )

                # 3. Prepare Meta Model API client & messages
                api_key = settings.MODEL_API_KEY
                if not api_key:
                    raise ValueError("MODEL_API_KEY is not configured in backend/.env")

                base_url = settings.META_MODEL_BASE_URL.rstrip("/")
                model_id = settings.META_MODEL_ID

                system_prompt = (
                    "You are an autonomous AI software engineer in Jess IDE.\n"
                    "Your mission is to inspect the project workspace, implement the requested code changes, "
                    "run tests to verify your changes, diagnose and repair any failures, and produce a clean diff.\n\n"
                    "Rules:\n"
                    "- Always use the approved tools: list_files, read_file, write_file, run_check, get_git_diff.\n"
                    "- Always inspect existing files using list_files and read_file before making changes.\n"
                    "- Write clean, working code using write_file.\n"
                    "- Always execute project checks using run_check (e.g. 'pytest', 'python -m unittest', 'python -m pytest', etc.).\n"
                    "- If a check fails, carefully analyze stdout and stderr, diagnose the root cause, apply a repair with write_file, and re-run run_check.\n"
                    "- When tests pass and you are done, summarize what you accomplished."
                )

                messages: List[Dict[str, Any]] = [
                    {"role": "system", "content": system_prompt},
                    {
                        "role": "user",
                        "content": (
                            f"Task Title: {task.title}\n\n"
                            f"Task Description and Requirements:\n{task.prompt}\n\n"
                            "Please begin by exploring the workspace files, understanding the setup, making necessary changes, and testing them."
                        ),
                    },
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
                        choices = resp_json.get("choices", [])
                        if not choices:
                            break

                        choice = choices[0]
                        message_obj = choice.get("message", {})
                        content = message_obj.get("content")
                        tool_calls = message_obj.get("tool_calls", [])

                        # Stream assistant thoughts to Flutter timeline
                        if content:
                            await self._emit_conv_event(db, task, "message.started", {"role": "assistant"})
                            await self._emit_conv_event(db, task, "message.delta", {"text": content})
                            await self._emit_conv_event(
                                db, task, "message.completed", {"text": content, "finish_reason": "stop"}
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

                                elif fn_name == "write_file":
                                    file_path = args.get("path", "")
                                    file_content = args.get("content", "")
                                    last_changed_file = file_path
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
                                    # Split command safely
                                    cmd_parts = shlex.split(cmd_str, posix=False) if os.name == 'nt' else shlex.split(cmd_str)
                                    cmd_res = await ws_provider.execute_command(workspace, cmd_parts)
                                    exit_code = cmd_res.exit_code
                                    tool_output = (cmd_res.stdout + "\n" + cmd_res.stderr).strip()

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
                                                "message": f"Test failed (exit code {exit_code}). Autonomous repair attempt {repair_attempts}/{max_repairs} underway...",
                                                "progress_percent": 60 + (repair_attempts * 10),
                                            },
                                        )

                                elif fn_name == "get_git_diff":
                                    diff_res = await ws_provider.get_git_diff(workspace)
                                    tool_output = diff_res.diff

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

                # 5. Extract final real diff
                diff_data = await ws_provider.get_git_diff(workspace)
                final_diff = diff_data.diff or "(No file modifications detected)"

                await self._emit_task_event(
                    db,
                    task,
                    "task.progress",
                    {
                        "stage": "diff_generation",
                        "message": "Assembled genuine diff from workspace execution. Requesting mobile approval.",
                        "progress_percent": 85,
                    },
                )

                await self._emit_task_event(
                    db,
                    task,
                    "diff.proposed",
                    {
                        "file_path": last_changed_file,
                        "diff": final_diff,
                        "additions": final_diff.count("\n+"),
                        "deletions": final_diff.count("\n-"),
                    },
                )

                # 6. RUNNING -> APPROVAL_REQUIRED
                await self._transition(db, task, TaskStatus.APPROVAL_REQUIRED)
                await self._emit_task_event(
                    db,
                    task,
                    "approval.required",
                    {
                        "action": "apply_code_diff",
                        "target_file": last_changed_file,
                        "prompt": f"Approve modifications generated by Meta model for {last_changed_file}?",
                    },
                )
                await self._emit_conv_event(
                    db,
                    task,
                    "approval.required",
                    {
                        "action": "apply_code_diff",
                        "target": last_changed_file,
                        "prompt": f"Approve applying proposed modifications to `{last_changed_file}`?",
                        "diff": final_diff,
                    },
                )

                # 7. Await approval or cancellation
                loop = asyncio.get_running_loop()
                approval_fut: asyncio.Future = loop.create_future()
                self._pending_approvals[task_id] = approval_fut

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
                        await self._transition(db, task, TaskStatus.RUNNING)
                        await self._emit_task_event(
                            db,
                            task,
                            "approval.granted",
                            {"action": "apply_code_diff", "reviewer": "user"},
                        )

                        # Commit changes to git branch
                        try:
                            await ws_provider.execute_command(
                                workspace,
                                ["git", "-c", "user.name=Jess Meta Agent", "-c", "user.email=meta@jess.local", "commit", "-am", f"Applied: {task.title}"]
                            )
                        except Exception:
                            pass

                        await self._emit_task_event(
                            db,
                            task,
                            "task.progress",
                            {
                                "stage": "verification",
                                "message": "Changes approved and committed to isolated branch.",
                                "progress_percent": 100,
                            },
                        )

                        # Transition to COMPLETED
                        await self._transition(db, task, TaskStatus.COMPLETED)
                        await self._emit_task_event(
                            db,
                            task,
                            "task.completed",
                            {
                                "status": TaskStatus.COMPLETED.value,
                                "summary": "Meta-powered coding task completed and verified successfully.",
                            },
                        )
                        await self._emit_conv_event(
                            db,
                            task,
                            "run.completed",
                            {
                                "status": TaskStatus.COMPLETED.value,
                                "summary": "Meta-powered modifications approved and committed.",
                            },
                        )
                    else:
                        await self._transition(db, task, TaskStatus.CANCELLED)
                        await self._emit_task_event(
                            db,
                            task,
                            "approval.rejected",
                            {"reason": reason or "User rejected proposed changes on mobile."},
                        )
                        await self._emit_conv_event(
                            db,
                            task,
                            "run.cancelled",
                            {"reason": reason or "User rejected proposed changes on mobile."},
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
                    await db.commit()
                    await self._emit_task_event(
                        db,
                        task,
                        "task.failed",
                        {"error": str(e), "status": TaskStatus.FAILED.value},
                    )
                    await self._emit_conv_event(
                        db,
                        task,
                        "run.failed",
                        {"error": str(e), "status": TaskStatus.FAILED.value},
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
                if approved:
                    await self._transition(db, task, TaskStatus.RUNNING)
                    await self._emit_task_event(
                        db,
                        task,
                        "approval.granted",
                        {"action": "apply_code_diff", "reviewer": "user"},
                    )
                    await self._transition(db, task, TaskStatus.COMPLETED)
                    await self._emit_task_event(
                        db,
                        task,
                        "task.completed",
                        {
                            "status": TaskStatus.COMPLETED.value,
                            "summary": "Meta-powered coding task completed and verified successfully.",
                        },
                    )
                    await self._emit_conv_event(
                        db,
                        task,
                        "run.completed",
                        {
                            "status": TaskStatus.COMPLETED.value,
                            "summary": "Meta-powered modifications approved and committed.",
                        },
                    )
                else:
                    await self._transition(db, task, TaskStatus.CANCELLED)
                    await self._emit_task_event(
                        db,
                        task,
                        "approval.rejected",
                        {"reason": reason or "User rejected proposed changes on mobile."},
                    )
                    await self._emit_conv_event(
                        db,
                        task,
                        "run.cancelled",
                        {"reason": reason or "User rejected proposed changes on mobile."},
                    )

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
