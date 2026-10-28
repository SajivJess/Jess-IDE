import json
import unittest
import uuid
from unittest.mock import patch

from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.future import select

from app.core.config import settings
from app.db.base import Base
from app.db.models.conversation import Conversation
from app.db.models.conversation_event import ConversationEvent
from app.db.models.conversation_message import ConversationMessage
from app.db.models.project import Project
from app.db.models.task import Task
from app.db.models.user import User
from app.schemas.task import TaskStatus
from app.services.meta_agent import (
    compact_context_window,
    estimate_messages_tokens,
    estimate_tokens,
)
from app.services.task_recovery import reconcile_interrupted_tasks


class TestBatch3RecoveryAndCompaction(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        # In-memory SQLite async engine for isolated test runs
        self.engine = create_async_engine("sqlite+aiosqlite:///:memory:", echo=False)
        async with self.engine.begin() as conn:
            await conn.run_sync(Base.metadata.create_all)
        self.session_factory = async_sessionmaker(self.engine, class_=AsyncSession, expire_on_commit=False)

    async def asyncTearDown(self) -> None:
        await self.engine.dispose()

    async def _create_test_environment(self, db: AsyncSession):
        user_id = uuid.uuid4()
        user = User(
            id=user_id,
            email=f"test_{uuid.uuid4().hex[:6]}@jess.local",
            hashed_password="fakehashedpassword",
            full_name="Tester",
        )
        db.add(user)
        project = Project(
            id=uuid.uuid4(),
            user_id=user_id,
            name="Test Project",
        )
        db.add(project)
        conv = Conversation(
            id=uuid.uuid4(),
            project_id=project.id,
            title="Session 1",
        )
        db.add(conv)
        await db.commit()
        return user, project, conv

    async def test_reconcile_orphaned_running_task_marks_failed(self) -> None:
        async with self.session_factory() as db:
            _, project, conv = await self._create_test_environment(db)

            running_task = Task(
                id=uuid.uuid4(),
                project_id=project.id,
                conversation_id=conv.id,
                title="Orphaned Running Task",
                prompt="Fix bug in calculator",
                status=TaskStatus.RUNNING.value,
            )
            db.add(running_task)
            await db.commit()

            # Reconcile interrupted tasks
            recovered = await reconcile_interrupted_tasks(db)
            self.assertEqual(len(recovered), 1)
            self.assertEqual(recovered[0], running_task.id)

            # Verify task state in database
            stmt = select(Task).where(Task.id == running_task.id)
            updated_task = (await db.execute(stmt)).scalar_one()
            self.assertEqual(updated_task.status, TaskStatus.FAILED.value)

            log_data = json.loads(updated_task.execution_log or "{}")
            self.assertTrue(log_data.get("interrupted"))
            self.assertIn("interrupted by a backend restart", log_data.get("reason", ""))

            # Verify explanatory assistant message was posted
            msg_stmt = select(ConversationMessage).where(ConversationMessage.conversation_id == conv.id)
            messages = (await db.execute(msg_stmt)).scalars().all()
            self.assertEqual(len(messages), 1)
            self.assertEqual(messages[0].role, "assistant")
            self.assertIn("interrupted by a backend restart", messages[0].content)

            # Verify persistent run.failed event was emitted
            ev_stmt = select(ConversationEvent).where(ConversationEvent.conversation_id == conv.id)
            events = (await db.execute(ev_stmt)).scalars().all()
            self.assertEqual(len(events), 1)
            self.assertEqual(events[0].event_type, "run.failed")
            self.assertTrue(events[0].payload.get("interrupted"))

    async def test_reconcile_preserves_approval_required_tasks(self) -> None:
        async with self.session_factory() as db:
            _, project, conv = await self._create_test_environment(db)

            approval_task = Task(
                id=uuid.uuid4(),
                project_id=project.id,
                conversation_id=conv.id,
                title="Task Awaiting Mobile Review",
                prompt="Add user auth",
                status=TaskStatus.APPROVAL_REQUIRED.value,
                execution_log=json.dumps({"diff": "+ print('hello')", "prompt": "Apply diff?"}),
            )
            db.add(approval_task)
            await db.commit()

            # Reconcile should NOT fail or change approval_required task
            recovered = await reconcile_interrupted_tasks(db)
            self.assertEqual(len(recovered), 0)

            stmt = select(Task).where(Task.id == approval_task.id)
            task_after = (await db.execute(stmt)).scalar_one()
            self.assertEqual(task_after.status, TaskStatus.APPROVAL_REQUIRED.value)
            self.assertIn("+ print('hello')", task_after.execution_log or "")

    async def test_reconcile_idempotency_no_duplicates(self) -> None:
        async with self.session_factory() as db:
            _, project, conv = await self._create_test_environment(db)

            running_task = Task(
                id=uuid.uuid4(),
                project_id=project.id,
                conversation_id=conv.id,
                title="Orphaned Task 2",
                prompt="Optimize build script",
                status=TaskStatus.RUNNING.value,
            )
            db.add(running_task)
            await db.commit()

            # First run
            rec1 = await reconcile_interrupted_tasks(db)
            self.assertEqual(len(rec1), 1)

            # Second immediate run
            rec2 = await reconcile_interrupted_tasks(db)
            self.assertEqual(len(rec2), 0)

            # Messages count must remain exactly 1
            msg_stmt = select(ConversationMessage).where(ConversationMessage.conversation_id == conv.id)
            messages = (await db.execute(msg_stmt)).scalars().all()
            self.assertEqual(len(messages), 1)

    def test_token_estimation_and_compaction(self) -> None:
        # 1. Conservative estimation
        short_text = "Hello world! This is a test."
        tokens = estimate_tokens(short_text)
        self.assertGreater(tokens, 0)
        self.assertEqual(tokens, len(short_text) // 4 + 1)

        # 2. Large conversation message list
        messages = [
            {"role": "system", "content": "You are Jess Dev Agent."},
            {"role": "user", "content": "Fix the calculator bug."},
            # 8 older tool turns
            {"role": "assistant", "content": "I will inspect files.", "tool_calls": [{"id": "1", "function": {"name": "list_files"}}]},
            {"role": "tool", "tool_call_id": "1", "name": "list_files", "content": "file1.py\nfile2.py"},
            {"role": "assistant", "content": "Reading file1.", "tool_calls": [{"id": "2", "function": {"name": "read_file"}}]},
            {"role": "tool", "tool_call_id": "2", "name": "read_file", "content": "def add(a, b): return a + b"},
            {"role": "assistant", "content": "Running test.", "tool_calls": [{"id": "3", "function": {"name": "run_check"}}]},
            {"role": "tool", "tool_call_id": "3", "name": "run_check", "content": "Tests failed: exit code 1"},
            {"role": "assistant", "content": "Writing fix.", "tool_calls": [{"id": "4", "function": {"name": "write_file"}}]},
            {"role": "tool", "tool_call_id": "4", "name": "write_file", "content": "OK: wrote file1.py"},
            # Recent turns
            {"role": "assistant", "content": "Verifying again.", "tool_calls": [{"id": "5", "function": {"name": "run_check"}}]},
            {"role": "tool", "tool_call_id": "5", "name": "run_check", "content": "Tests passed: exit code 0"},
        ]

        compacted = compact_context_window(
            messages=messages,
            max_tokens=30,
            task_owned_files={"file1.py"},
            last_check_command="pytest",
            last_check_exit_code=0,
            last_check_passed=True,
        )
        # System prompt and user prompt are preserved
        self.assertEqual(compacted[0]["role"], "system")
        self.assertEqual(compacted[1]["role"], "user")
        # An intermediate compaction summary card should replace the older tool turns
        summary_msg = next((m for m in compacted if "Context Budget Optimization" in m.get("content", "")), None)
        self.assertIsNotNone(summary_msg)
        self.assertIn("Task modified files so far: file1.py", summary_msg["content"])
        self.assertIn("Test Verification Outcome: Command 'pytest'", summary_msg["content"])
        # Recent tool turns remain intact
        self.assertEqual(compacted[-1]["name"], "run_check")
        self.assertEqual(compacted[-1]["content"], "Tests passed: exit code 0")

    def test_context_budget_settings(self) -> None:
        self.assertGreaterEqual(settings.META_CONTEXT_BUDGET_TOKENS, 8000)
        self.assertGreaterEqual(settings.META_MAX_HISTORY_TURNS, 4)
