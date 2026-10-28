import asyncio
import json
import os
import shlex
import uuid
from abc import ABC, abstractmethod
from typing import Any, Dict, Optional
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.core.logging import logger
from app.db.models.task import Task
from app.db.models.workspace import Workspace
from app.db.session import async_session_factory
from app.schemas.task import TERMINAL_STATUSES, TaskStatus, can_transition
from app.schemas.workspace import WorkspaceStatus
from app.services.conversation_events import append_conversation_event
from app.services.task_events import append_task_event
from app.services.workspace import get_workspace_provider


class BaseAgentAdapter(ABC):
    """Abstract provider-independent adapter interface for coding agents."""

    @abstractmethod
    async def run_task(self, task_id: uuid.UUID) -> None:
        """Start executing a task or conversation run."""
        pass

    @abstractmethod
    async def handle_approval(
        self, task_id: uuid.UUID, approved: bool, reason: Optional[str] = None
    ) -> None:
        """Submit approval or rejection for a task awaiting user approval."""
        pass

    @abstractmethod
    async def cancel_task(self, task_id: uuid.UUID) -> None:
        """Request immediate cancellation of a running or queued task."""
        pass

    async def cancel_run(self, run_id: uuid.UUID) -> None:
        """Alias for cancel_task for conversational runs."""
        await self.cancel_task(run_id)


class SimulatedAgentAdapter(BaseAgentAdapter):
    """Deterministic, provider-independent conversational coding agent adapter.
    
    Emits standardized JSON events:
    - message.started, message.delta, message.completed
    - tool.started, tool.output, tool.completed
    - file.changed
    - approval.required
    - run.started, run.completed, run.failed, run.cancelled
    """

    def __init__(self, step_delay: float = 0.3) -> None:
        self.step_delay = step_delay
        self._pending_approvals: Dict[uuid.UUID, asyncio.Future] = {}
        self._running_tasks: Dict[uuid.UUID, asyncio.Task] = {}
        self._cancellation_events: Dict[uuid.UUID, asyncio.Event] = {}

    def is_task_running(self, task_id: uuid.UUID) -> bool:
        """Check if a task is currently executing in background."""
        task = self._running_tasks.get(task_id)
        return task is not None and not task.done()

    async def _transition(
        self, db: AsyncSession, task: Task, target_status: TaskStatus
    ) -> bool:
        """Validate and apply a task state machine transition with fresh DB status verification."""
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
        await db.refresh(task)
        logger.info(f"Task {task.id} transitioned {fresh_status.value} -> {target_status.value}")
        return True

    async def _emit_task_event(
        self,
        db: AsyncSession,
        task: Task,
        event_type: str,
        payload: Dict[str, Any],
    ) -> None:
        """Emit legacy task event."""
        await append_task_event(db, task.id, event_type, payload)

    async def _emit_conv_event(
        self,
        db: AsyncSession,
        task: Task,
        event_type: str,
        payload: Dict[str, Any],
    ) -> None:
        """Emit normalized conversation event."""
        if task.conversation_id:
            await append_conversation_event(
                db,
                conversation_id=task.conversation_id,
                event_type=event_type,
                payload=payload,
                run_id=task.id,
            )

    async def run_task(self, task_id: uuid.UUID) -> None:
        """Launch execution of the task as a managed background asyncio Task."""
        if self.is_task_running(task_id):
            logger.warning(f"Task {task_id} is already executing. Ignoring duplicate run request.")
            return

        cancel_event = asyncio.Event()
        self._cancellation_events[task_id] = cancel_event

        coro = self._execute_lifecycle(task_id, cancel_event)
        bg_task = asyncio.create_task(coro)
        self._running_tasks[task_id] = bg_task

        def _cleanup(_: Any) -> None:
            self._running_tasks.pop(task_id, None)
            self._pending_approvals.pop(task_id, None)
            self._cancellation_events.pop(task_id, None)

        bg_task.add_done_callback(_cleanup)

    async def _execute_lifecycle(
        self, task_id: uuid.UUID, cancel_event: asyncio.Event
    ) -> None:
        """Step-by-step agent execution sequence reconstructing progress into chat."""
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

                # Workspace inspection
                if task.workspace_id:
                    ws_stmt = select(Workspace).where(Workspace.id == task.workspace_id)
                else:
                    ws_stmt = select(Workspace).where(Workspace.project_id == task.project_id)
                ws_res = await db.execute(ws_stmt)
                workspace = ws_res.scalars().first()
                ws_ready = workspace is not None and workspace.status == WorkspaceStatus.RUNNING.value
                ws_info = f" (Connected to workspace {workspace.id})" if ws_ready else " (Simulated workspace)"

                # 2. Assistant explains initial approach
                if self.step_delay > 0:
                    await asyncio.sleep(self.step_delay)
                if cancel_event.is_set():
                    await self._handle_cancellation(db, task)
                    return

                real_files_count = None
                ws_provider = get_workspace_provider()
                if ws_ready:
                    try:
                        file_items = await ws_provider.list_files(workspace, "")
                        real_files_count = len(file_items)
                    except Exception as e:
                        logger.warning(f"Could not list workspace files during task: {e}")

                inspect_summary = (
                    f"Discovered {real_files_count} project files in container workspace.{ws_info}"
                    if real_files_count is not None
                    else f"Inspecting project structure and analyzing requirements...{ws_info}"
                )

                await self._emit_task_event(
                    db,
                    task,
                    "task.progress",
                    {
                        "stage": "inspect_repo",
                        "message": inspect_summary,
                        "progress_percent": 25,
                        "workspace_id": str(workspace.id) if workspace else None,
                        "workspace_ready": ws_ready,
                    },
                )

                await self._emit_conv_event(db, task, "message.started", {"role": "assistant"})
                thought_text = "I am analyzing your request and inspecting the workspace files...\nLet me examine the repository structure and test setup."
                await self._emit_conv_event(db, task, "message.delta", {"text": thought_text})
                await self._emit_conv_event(
                    db, task, "message.completed", {"text": thought_text, "finish_reason": "stop"}
                )

                # 3. Tool: Inspect Workspace
                if self.step_delay > 0:
                    await asyncio.sleep(self.step_delay)
                if cancel_event.is_set():
                    await self._handle_cancellation(db, task)
                    return

                await self._emit_task_event(
                    db,
                    task,
                    "tool.requested",
                    {
                        "tool": "find_files",
                        "parameters": {"pattern": "*.*", "path": ""},
                        "reason": f"Discovered {real_files_count} project files in workspace." if real_files_count is not None else "Identify existing state and service structures.",
                        "files_found": real_files_count,
                    },
                )

                await self._emit_conv_event(
                    db,
                    task,
                    "tool.started",
                    {
                        "tool": "terminal",
                        "label": "Inspecting project structure & files",
                        "status": "running",
                        "command": "git status && ls -la",
                    },
                )
                await self._emit_conv_event(
                    db,
                    task,
                    "tool.output",
                    {"tool": "terminal", "output": inspect_summary, "status": "running"},
                )
                await self._emit_conv_event(
                    db,
                    task,
                    "tool.completed",
                    {"tool": "terminal", "status": "completed", "exit_code": 0, "summary": inspect_summary},
                )

                # 4. Tool: File modification / diff generation
                if self.step_delay > 0:
                    await asyncio.sleep(self.step_delay)
                if cancel_event.is_set():
                    await self._handle_cancellation(db, task)
                    return

                target_file = "lib/services/api_client.dart"
                sample_diff = (
                    "--- a/lib/services/api_client.dart\n"
                    "+++ b/lib/services/api_client.dart\n"
                    "@@ -15,3 +15,7 @@\n"
                    " class ApiClient {\n"
                    "+  // Added exponential backoff retry policy\n"
                    "+  final int maxRetries = 3;\n"
                    "+  final Duration retryDelay = Duration(milliseconds: 500);\n"
                    "   final String baseUrl;\n"
                )

                diff_text = sample_diff
                if ws_ready:
                    try:
                        diff_data = await ws_provider.get_git_diff(workspace)
                        if diff_data.get("diff"):
                            diff_text = diff_data["diff"]
                            changed = diff_data.get("changed_files", [])
                            if changed:
                                target_file = changed[0].get("file", target_file)
                    except Exception as e:
                        logger.warning(f"Could not fetch git diff during task: {e}")

                await self._emit_task_event(
                    db,
                    task,
                    "task.progress",
                    {
                        "stage": "diff_generation",
                        "message": "Drafting code improvements and assembling sample diff...",
                        "progress_percent": 50,
                    },
                )
                await self._emit_task_event(
                    db,
                    task,
                    "diff.proposed",
                    {
                        "file_path": target_file,
                        "diff": diff_text,
                        "additions": 3,
                        "deletions": 0,
                    },
                )

                await self._emit_conv_event(
                    db,
                    task,
                    "tool.started",
                    {
                        "tool": "file_edit",
                        "label": f"Drafting changes for {target_file}",
                        "status": "running",
                        "file": target_file,
                    },
                )
                await self._emit_conv_event(
                    db,
                    task,
                    "file.changed",
                    {
                        "file": target_file,
                        "action": "modified",
                        "diff": diff_text,
                        "additions": 3,
                        "deletions": 0,
                    },
                )
                await self._emit_conv_event(
                    db,
                    task,
                    "tool.completed",
                    {
                        "tool": "file_edit",
                        "status": "completed",
                        "summary": f"Changes prepared for {target_file}",
                    },
                )

                # 5. RUNNING -> APPROVAL_REQUIRED
                if self.step_delay > 0:
                    await asyncio.sleep(self.step_delay)
                if cancel_event.is_set():
                    await self._handle_cancellation(db, task)
                    return

                await self._transition(db, task, TaskStatus.APPROVAL_REQUIRED)
                await self._emit_task_event(
                    db,
                    task,
                    "approval.required",
                    {
                        "action": "apply_code_diff",
                        "target_file": target_file,
                        "prompt": f"Approve modifying {target_file} to apply changes?",
                    },
                )
                await self._emit_conv_event(
                    db,
                    task,
                    "approval.required",
                    {
                        "action": "apply_code_diff",
                        "target": target_file,
                        "prompt": f"Approve applying proposed modifications to `{target_file}`?",
                        "diff": diff_text,
                    },
                )

                # 6. Await approval or cancellation
                loop = asyncio.get_running_loop()
                approval_fut: asyncio.Future = loop.create_future()
                self._pending_approvals[task_id] = approval_fut

            # Release db connection while waiting for approval
            cancel_wait = asyncio.create_task(cancel_event.wait())
            done, pending = await asyncio.wait(
                [approval_fut, cancel_wait],
                return_when=asyncio.FIRST_COMPLETED,
            )
            for p in pending:
                p.cancel()

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
                        # APPROVAL_REQUIRED -> RUNNING
                        await self._transition(db, task, TaskStatus.RUNNING)
                        await self._emit_task_event(
                            db,
                            task,
                            "approval.granted",
                            {"action": "apply_code_diff", "reviewer": "user"},
                        )
                        await self._emit_task_event(
                            db,
                            task,
                            "task.progress",
                            {
                                "stage": "verification",
                                "message": "Verification complete. All changes successfully validated.",
                                "progress_percent": 100,
                            },
                        )

                        # Tool: Run tests for conversation
                        await self._emit_conv_event(
                            db,
                            task,
                            "tool.started",
                            {
                                "tool": "terminal",
                                "label": "Running verification tests",
                                "status": "running",
                                "command": "flutter test",
                            },
                        )

                        if self.step_delay > 0:
                            await asyncio.sleep(self.step_delay)

                        await self._emit_conv_event(
                            db,
                            task,
                            "tool.output",
                            {
                                "tool": "terminal",
                                "output": "00:02 +14: All tests passed!",
                                "status": "running",
                            },
                        )
                        await self._emit_conv_event(
                            db,
                            task,
                            "tool.completed",
                            {
                                "tool": "terminal",
                                "status": "completed",
                                "exit_code": 0,
                                "summary": "14 tests passed successfully.",
                            },
                        )

                        completion_msg = (
                            f"I've successfully applied the modifications to `{target_file}` "
                            "and verified that all tests are passing."
                        )
                        await self._emit_conv_event(db, task, "message.started", {"role": "assistant"})
                        await self._emit_conv_event(db, task, "message.delta", {"text": completion_msg})
                        await self._emit_conv_event(
                            db, task, "message.completed", {"text": completion_msg, "finish_reason": "stop"}
                        )

                        # RUNNING -> COMPLETED
                        await self._transition(db, task, TaskStatus.COMPLETED)
                        await self._emit_task_event(
                            db,
                            task,
                            "task.completed",
                            {
                                "status": TaskStatus.COMPLETED.value,
                                "summary": "Task completed successfully. Simulated diff applied.",
                            },
                        )
                        await self._emit_conv_event(
                            db,
                            task,
                            "run.completed",
                            {
                                "status": TaskStatus.COMPLETED.value,
                                "summary": "Code modifications verified and tests passed.",
                            },
                        )
                    else:
                        # Rejection -> CANCELLED
                        await self._transition(db, task, TaskStatus.CANCELLED)
                        await self._emit_task_event(
                            db,
                            task,
                            "approval.rejected",
                            {"reason": reason or "User rejected proposed changes."},
                        )
                        await self._emit_task_event(
                            db,
                            task,
                            "task.cancelled",
                            {"reason": "Task cancelled following approval rejection."},
                        )
                        await self._emit_conv_event(
                            db,
                            task,
                            "run.cancelled",
                            {"reason": reason or "User rejected proposed changes."},
                        )

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
                        {"reason": "Run cancelled by user request."},
                    )
                    await self._emit_conv_event(
                        db,
                        task,
                        "run.cancelled",
                        {"reason": "Run cancelled by user request."},
                    )
        except Exception as e:
            logger.exception(f"Unhandled error in agent adapter for task {task_id}: {e}")
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
        """Handle cancellation transition cleanly."""
        current = TaskStatus(task.status)
        if can_transition(current, TaskStatus.CANCELLED):
            await self._transition(db, task, TaskStatus.CANCELLED)
            await self._emit_task_event(
                db,
                task,
                "task.cancelled",
                {"reason": "Cancellation requested before step execution."},
            )
            await self._emit_conv_event(
                db,
                task,
                "run.cancelled",
                {"reason": "Cancellation requested before step execution."},
            )

    async def handle_approval(
        self, task_id: uuid.UUID, approved: bool, reason: Optional[str] = None
    ) -> None:
        """Fulfill the pending approval future for task_id."""
        fut = self._pending_approvals.get(task_id)
        if fut and not fut.done():
            fut.set_result({"approved": approved, "reason": reason})
        else:
            logger.warning(f"No pending approval future found for task {task_id}.")

    async def cancel_task(self, task_id: uuid.UUID) -> None:
        """Signal cancellation for task_id."""
        cancel_event = self._cancellation_events.get(task_id)
        if cancel_event:
            cancel_event.set()

        fut = self._pending_approvals.get(task_id)
        if fut and not fut.done():
            fut.cancel()

        bg_task = self._running_tasks.get(task_id)
        if bg_task and not bg_task.done():
            bg_task.cancel()


class CLIProcessAgentAdapter(BaseAgentAdapter):
    """Provider-independent CLI process adapter for executing real CLI agents.
    
    Starts a configured CLI process in the workspace, consumes stdout/stderr,
    normalizes output, handles cancellation and exit codes.
    """

    def __init__(self, cli_command: Optional[str] = None, timeout_seconds: int = 600) -> None:
        self.cli_command = cli_command or os.getenv("AGENT_CLI_COMMAND", "")
        self.timeout_seconds = timeout_seconds
        self._running_processes: Dict[uuid.UUID, asyncio.subprocess.Process] = {}
        self._pending_approvals: Dict[uuid.UUID, asyncio.Future] = {}

    async def run_task(self, task_id: uuid.UUID) -> None:
        """Run the configured CLI process."""
        if not self.cli_command:
            # Fall back to simulated adapter if no CLI command is configured
            logger.info(f"No AGENT_CLI_COMMAND configured. Delegating task {task_id} to simulated agent.")
            await simulated_agent.run_task(task_id)
            return

        async with async_session_factory() as db:
            task = await db.get(Task, task_id)
            if not task:
                return

            task.status = TaskStatus.RUNNING.value
            await db.commit()

            # Emit run.started
            await append_conversation_event(
                db,
                conversation_id=task.conversation_id or task.project_id,
                event_type="run.started",
                payload={"prompt": task.prompt, "status": "running"},
                run_id=task.id,
            )

        bg_task = asyncio.create_task(self._execute_cli_process(task_id))

    async def _execute_cli_process(self, task_id: uuid.UUID) -> None:
        """Execute and monitor the CLI subprocess."""
        async with async_session_factory() as db:
            task = await db.get(Task, task_id)
            if not task:
                return

            conv_id = task.conversation_id or task.project_id

            try:
                cmd_parts = shlex.split(self.cli_command)
                # Append task prompt as argument
                cmd_parts.append(task.prompt)

                process = await asyncio.create_subprocess_exec(
                    *cmd_parts,
                    stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.PIPE,
                    stdin=asyncio.subprocess.PIPE,
                )
                self._running_processes[task_id] = process

                await append_conversation_event(
                    db,
                    conversation_id=conv_id,
                    event_type="tool.started",
                    payload={"tool": "cli_agent", "label": f"Executing {cmd_parts[0]}", "status": "running"},
                    run_id=task_id,
                )

                async def read_stream(stream, is_stderr=False):
                    while True:
                        line_bytes = await stream.readline()
                        if not line_bytes:
                            break
                        line = line_bytes.decode("utf-8", errors="replace").strip()
                        if not line:
                            continue

                        # Check if line is structured JSON event
                        try:
                            parsed = json.loads(line)
                            ev_type = parsed.get("type", "tool.output")
                            ev_data = parsed.get("data", parsed)
                            async with async_session_factory() as sub_db:
                                await append_conversation_event(
                                    sub_db,
                                    conversation_id=conv_id,
                                    event_type=ev_type,
                                    payload=ev_data,
                                    run_id=task_id,
                                )
                        except json.JSONDecodeError:
                            # Conservative fallback: treat as tool output, not fabricated assistant response
                            async with async_session_factory() as sub_db:
                                await append_conversation_event(
                                    sub_db,
                                    conversation_id=conv_id,
                                    event_type="tool.output",
                                    payload={"tool": "cli_agent", "output": line, "is_stderr": is_stderr},
                                    run_id=task_id,
                                )

                stdout_task = asyncio.create_task(read_stream(process.stdout, False))
                stderr_task = asyncio.create_task(read_stream(process.stderr, True))

                try:
                    exit_code = await asyncio.wait_for(process.wait(), timeout=self.timeout_seconds)
                    await asyncio.gather(stdout_task, stderr_task)
                except asyncio.TimeoutError:
                    process.kill()
                    exit_code = -1
                    logger.warning(f"CLI agent process timed out after {self.timeout_seconds}s for task {task_id}")

                if exit_code == 0:
                    task.status = TaskStatus.COMPLETED.value
                    await db.commit()
                    await append_conversation_event(
                        db,
                        conversation_id=conv_id,
                        event_type="run.completed",
                        payload={"status": "completed", "summary": "CLI agent finished successfully."},
                        run_id=task_id,
                    )
                else:
                    task.status = TaskStatus.FAILED.value
                    await db.commit()
                    await append_conversation_event(
                        db,
                        conversation_id=conv_id,
                        event_type="run.failed",
                        payload={"status": "failed", "error": f"CLI exited with code {exit_code}"},
                        run_id=task_id,
                    )

            except Exception as e:
                logger.exception(f"Error executing CLI process: {e}")
                task.status = TaskStatus.FAILED.value
                await db.commit()
                await append_conversation_event(
                    db,
                    conversation_id=conv_id,
                    event_type="run.failed",
                    payload={"status": "failed", "error": str(e)},
                    run_id=task_id,
                )
            finally:
                self._running_processes.pop(task_id, None)

    async def handle_approval(
        self, task_id: uuid.UUID, approved: bool, reason: Optional[str] = None
    ) -> None:
        process = self._running_processes.get(task_id)
        if process and process.stdin:
            response = b"y\n" if approved else b"n\n"
            process.stdin.write(response)
            await process.stdin.drain()

    async def cancel_task(self, task_id: uuid.UUID) -> None:
        process = self._running_processes.get(task_id)
        if process:
            try:
                process.terminate()
                await asyncio.sleep(0.5)
                if process.returncode is None:
                    process.kill()
            except Exception:
                pass


class DispatchingAgentAdapter(BaseAgentAdapter):
    """Dynamic dispatcher between MetaAgentAdapter and SimulatedAgentAdapter.
    
    Routes execution dynamically based on AGENT_PROVIDER ('meta' vs 'simulated')
    and MODEL_API_KEY configuration without breaking existing callers.
    """

    def __init__(self) -> None:
        self._simulated = SimulatedAgentAdapter(step_delay=0.3)
        self._meta: Optional[BaseAgentAdapter] = None

    @property
    def step_delay(self) -> float:
        return self._simulated.step_delay

    @step_delay.setter
    def step_delay(self, value: float) -> None:
        self._simulated.step_delay = value

    def _resolve(self) -> BaseAgentAdapter:
        if settings.MODEL_API_KEY and getattr(settings, "AGENT_PROVIDER", "simulated").lower() == "meta":
            if self._meta is None:
                from app.services.meta_agent import MetaAgentAdapter
                self._meta = MetaAgentAdapter()
            return self._meta
        return self._simulated

    async def run_task(self, task_id: uuid.UUID) -> None:
        adapter = self._resolve()
        logger.info(f"[AgentDispatcher] Routing task {task_id} to {adapter.__class__.__name__}")
        await adapter.run_task(task_id)

    async def handle_approval(
        self, task_id: uuid.UUID, approved: bool, reason: Optional[str] = None
    ) -> None:
        adapter = self._resolve()
        await adapter.handle_approval(task_id, approved, reason)

    async def cancel_task(self, task_id: uuid.UUID) -> None:
        adapter = self._resolve()
        await adapter.cancel_task(task_id)

    def is_task_running(self, task_id: uuid.UUID) -> bool:
        if self._meta is not None and self._meta.is_task_running(task_id):
            return True
        return self._simulated.is_task_running(task_id)


# Global agent instance exposed to endpoints (routes to Meta when AGENT_PROVIDER=meta)
simulated_agent = DispatchingAgentAdapter()
