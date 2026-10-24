import asyncio
import uuid
from abc import ABC, abstractmethod
from typing import Any, Dict, Optional
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.logging import logger
from app.db.models.task import Task
from app.db.models.workspace import Workspace
from app.db.session import async_session_factory
from app.schemas.task import TaskStatus, can_transition
from app.schemas.workspace import WorkspaceStatus
from app.services.task_events import append_task_event
from app.services.workspace import get_workspace_provider


class BaseAgentAdapter(ABC):
    """Abstract provider-independent adapter interface for coding agents."""

    @abstractmethod
    async def run_task(self, task_id: uuid.UUID) -> None:
        """Start executing a task."""
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


class SimulatedAgentAdapter(BaseAgentAdapter):
    """Deterministic simulated test agent for Phase 5.
    
    Emits realistic lifecycle events (started, progress, tool request, diff proposal,
    approval request, completed/cancelled) without spending paid LLM credits or modifying files.
    """

    def __init__(self, step_delay: float = 0.4) -> None:
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
    ) -> None:
        """Validate and apply a task state machine transition."""
        current_status = TaskStatus(task.status)
        if not can_transition(current_status, target_status):
            err_msg = f"Invalid task state transition from {current_status.value} to {target_status.value}"
            logger.error(err_msg)
            raise ValueError(err_msg)

        task.status = target_status.value
        await db.commit()
        await db.refresh(task)
        logger.info(f"Task {task.id} transitioned {current_status.value} -> {target_status.value}")

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
        """Deterministic step-by-step simulation sequence."""
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
                await append_task_event(
                    db,
                    task_id,
                    "task.started",
                    {"status": TaskStatus.RUNNING.value, "title": task.title},
                )

                if cancel_event.is_set():
                    await self._handle_cancellation(db, task)
                    return

                # Check for associated active workspace for this project
                if task.workspace_id:
                    ws_stmt = select(Workspace).where(Workspace.id == task.workspace_id)
                else:
                    ws_stmt = select(Workspace).where(Workspace.project_id == task.project_id)
                ws_res = await db.execute(ws_stmt)
                workspace = ws_res.scalars().first()

                # 2. Progress: Repository inspection
                if self.step_delay > 0:
                    await asyncio.sleep(self.step_delay)
                if cancel_event.is_set():
                    await self._handle_cancellation(db, task)
                    return

                ws_ready = workspace is not None and workspace.status == WorkspaceStatus.RUNNING.value
                ws_info = f" (Connected to workspace {workspace.id})" if ws_ready else " (Simulated workspace)"

                await append_task_event(
                    db,
                    task_id,
                    "task.progress",
                    {
                        "stage": "inspect_repo",
                        "message": f"Inspecting project structure and analyzing requirements...{ws_info}",
                        "progress_percent": 25,
                        "workspace_id": str(workspace.id) if workspace else None,
                        "workspace_ready": ws_ready,
                    },
                )

                # 3. Tool Execution Request
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
                        logger.warning(f"Could not list workspace files during task execution: {e}")

                await append_task_event(
                    db,
                    task_id,
                    "tool.requested",
                    {
                        "tool": "find_files",
                        "parameters": {"pattern": "*.*", "path": ""},
                        "reason": f"Discovered {real_files_count} project files in workspace." if real_files_count is not None else "Identify existing state and service structures.",
                        "files_found": real_files_count,
                    },
                )

                # 4. Progress: Diff Generation
                if self.step_delay > 0:
                    await asyncio.sleep(self.step_delay)
                if cancel_event.is_set():
                    await self._handle_cancellation(db, task)
                    return

                await append_task_event(
                    db,
                    task_id,
                    "task.progress",
                    {
                        "stage": "diff_generation",
                        "message": "Drafting code improvements and assembling sample diff...",
                        "progress_percent": 50,
                    },
                )

                # 5. Proposed Diff
                if self.step_delay > 0:
                    await asyncio.sleep(self.step_delay)
                if cancel_event.is_set():
                    await self._handle_cancellation(db, task)
                    return

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
                target_file = "lib/services/api_client.dart"

                if ws_ready:
                    try:
                        diff_data = await ws_provider.get_git_diff(workspace)
                        if diff_data.get("diff"):
                            diff_text = diff_data["diff"]
                            changed = diff_data.get("changed_files", [])
                            if changed:
                                target_file = changed[0].get("file", target_file)
                    except Exception as e:
                        logger.warning(f"Could not fetch git diff during task execution: {e}")

                await append_task_event(
                    db,
                    task_id,
                    "diff.proposed",
                    {
                        "file_path": target_file,
                        "diff": diff_text,
                        "additions": 3,
                        "deletions": 0,
                    },
                )

                # 6. RUNNING -> APPROVAL_REQUIRED
                if self.step_delay > 0:
                    await asyncio.sleep(self.step_delay)
                if cancel_event.is_set():
                    await self._handle_cancellation(db, task)
                    return

                await self._transition(db, task, TaskStatus.APPROVAL_REQUIRED)
                await append_task_event(
                    db,
                    task_id,
                    "approval.required",
                    {
                        "action": "apply_code_diff",
                        "target_file": target_file,
                        "prompt": f"Approve modifying {target_file} to apply changes?",
                    },
                )

                # 7. Await approval or cancellation
                loop = asyncio.get_running_loop()
                approval_fut: asyncio.Future = loop.create_future()
                self._pending_approvals[task_id] = approval_fut

            # Release db connection while waiting for user approval
            cancel_task = asyncio.create_task(cancel_event.wait())

            done, pending = await asyncio.wait(
                [approval_fut, cancel_task],
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
                        await append_task_event(
                            db,
                            task_id,
                            "approval.granted",
                            {"action": "apply_code_diff", "reviewer": "user"},
                        )

                        # Final verification progress
                        if self.step_delay > 0:
                            await asyncio.sleep(self.step_delay)

                        # Re-verify workspace state
                        if task.workspace_id:
                            ws_stmt = select(Workspace).where(Workspace.id == task.workspace_id)
                        else:
                            ws_stmt = select(Workspace).where(Workspace.project_id == task.project_id)
                        ws_res = await db.execute(ws_stmt)
                        ws = ws_res.scalars().first()
                        ws_active = ws is not None and ws.status == WorkspaceStatus.RUNNING.value
                        verif_msg = (
                            f"Workspace {ws.id} verification complete. All changes successfully validated."
                            if ws_active
                            else "Verification complete. All changes successfully validated."
                        )

                        await append_task_event(
                            db,
                            task_id,
                            "task.progress",
                            {
                                "stage": "verification",
                                "message": verif_msg,
                                "progress_percent": 100,
                            },
                        )

                        # RUNNING -> COMPLETED
                        await self._transition(db, task, TaskStatus.COMPLETED)
                        await append_task_event(
                            db,
                            task_id,
                            "task.completed",
                            {
                                "status": TaskStatus.COMPLETED.value,
                                "summary": "Task completed successfully. Workspace state verified." if ws_active else "Task completed successfully. Simulated diff applied.",
                            },
                        )
                    else:
                        # Rejection -> CANCELLED or FAILED
                        await self._transition(db, task, TaskStatus.CANCELLED)
                        await append_task_event(
                            db,
                            task_id,
                            "approval.rejected",
                            {"reason": reason or "User rejected proposed changes."},
                        )
                        await append_task_event(
                            db,
                            task_id,
                            "task.cancelled",
                            {"reason": "Task cancelled following approval rejection."},
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
                    await append_task_event(
                        db,
                        task_id,
                        "task.cancelled",
                        {"reason": "Task cancelled by user request."},
                    )
        except Exception as e:
            logger.exception(f"Unhandled error in simulated agent for task {task_id}: {e}")
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
                    await append_task_event(
                        db,
                        task_id,
                        "task.failed",
                        {"error": str(e)},
                    )

    async def _handle_cancellation(self, db: AsyncSession, task: Task) -> None:
        """Handle cancellation transition cleanly."""
        current = TaskStatus(task.status)
        if can_transition(current, TaskStatus.CANCELLED):
            await self._transition(db, task, TaskStatus.CANCELLED)
            await append_task_event(
                db,
                task.id,
                "task.cancelled",
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


# Global simulated agent instance
simulated_agent = SimulatedAgentAdapter(step_delay=0.4)
