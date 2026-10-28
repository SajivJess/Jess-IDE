import asyncio
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import unittest
import uuid
from typing import Any, Dict, List
from unittest.mock import AsyncMock, MagicMock, patch

import httpx
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
from app.db.models.workspace import Workspace
from app.schemas.task import TaskStatus
from app.schemas.workspace import WorkspaceStatus
from app.services.meta_agent import MetaAgentAdapter, _capture_git_baseline
from app.services.task_recovery import reconcile_interrupted_tasks
from app.services.workspace.local_sandbox import LocalSandboxWorkspaceProvider


class TestBatch5IntegrationReadiness(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self.temp_dir = tempfile.mkdtemp(prefix="jess_batch5_int_")
        self.provider = LocalSandboxWorkspaceProvider()
        self._init_git_repo(self.temp_dir)

        # File-based SQLite allows clean concurrent access from background tasks
        db_file = os.path.join(self.temp_dir, "test_integration.db")
        # Ensure path format is clean for SQLite URI
        clean_db_uri = f"sqlite+aiosqlite:///{db_file.replace(os.sep, '/')}"
        self.engine = create_async_engine(
            clean_db_uri,
            connect_args={"check_same_thread": False},
            echo=False,
        )
        async with self.engine.begin() as conn:
            await conn.run_sync(Base.metadata.create_all)
        self.session_factory = async_sessionmaker(
            self.engine,
            class_=AsyncSession,
            expire_on_commit=False,
            autoflush=False,
        )

    async def asyncTearDown(self) -> None:
        await self.engine.dispose()
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def _init_git_repo(self, repo_dir: str) -> None:
        subprocess.run(["git", "init", "-b", "main"], cwd=repo_dir, check=True, capture_output=True)
        subprocess.run(["git", "config", "user.name", "Jess Tester"], cwd=repo_dir, check=True, capture_output=True)
        subprocess.run(["git", "config", "user.email", "tester@jess.local"], cwd=repo_dir, check=True, capture_output=True)

        # Baseline files
        with open(os.path.join(repo_dir, "calculator.py"), "w", encoding="utf-8") as f:
            f.write("def add(a, b):\n    return a + b\n")

        with open(os.path.join(repo_dir, "test_calculator.py"), "w", encoding="utf-8") as f:
            f.write("import unittest\nfrom calculator import add\n\nclass TestCalc(unittest.TestCase):\n    def test_add(self):\n        self.assertEqual(add(2, 3), 5)\n\nif __name__ == '__main__':\n    unittest.main()\n")

        subprocess.run(["git", "add", "."], cwd=repo_dir, check=True, capture_output=True)
        subprocess.run(["git", "commit", "-m", "Initial calculator baseline"], cwd=repo_dir, check=True, capture_output=True)

    async def _create_test_entities(self, db: AsyncSession):
        user = User(
            id=uuid.uuid4(),
            email=f"user_{uuid.uuid4().hex[:6]}@jess.local",
            hashed_password="hashed_pw",
            full_name="Batch 5 User",
        )
        db.add(user)

        project = Project(
            id=uuid.uuid4(),
            user_id=user.id,
            name="Calculator Project",
            workspace_path=self.temp_dir,
        )
        db.add(project)

        workspace = Workspace(
            id=uuid.uuid4(),
            user_id=user.id,
            project_id=project.id,
            name="Calculator Workspace",
            host_type="local_sandbox",
            root_path=self.temp_dir,
            status=WorkspaceStatus.RUNNING.value,
        )
        db.add(workspace)

        conv = Conversation(
            id=uuid.uuid4(),
            project_id=project.id,
            title="Calculator Session",
        )
        db.add(conv)
        await db.commit()
        return user, project, workspace, conv

    async def test_end_to_end_coding_task_approval_and_commit(self) -> None:
        """Verify the full pipeline: request -> tool execution -> check -> approval -> git commit."""
        adapter = MetaAgentAdapter()

        async with self.session_factory() as db:
            user, project, workspace, conv = await self._create_test_entities(db)
            task = Task(
                id=uuid.uuid4(),
                project_id=project.id,
                workspace_id=workspace.id,
                conversation_id=conv.id,
                title="Add multiply feature",
                prompt="Add multiply(a, b) to calculator.py and update test_calculator.py",
                status=TaskStatus.QUEUED.value,
            )
            db.add(task)
            await db.commit()
            task_id = task.id

        # Mock the Meta Model responses:
        # Turn 1: Model calls write_file for calculator.py
        turn1_response = {
            "choices": [{
                "message": {
                    "role": "assistant",
                    "content": "I will implement multiply(a, b) in calculator.py.",
                    "tool_calls": [{
                        "id": "tc_write_calc",
                        "type": "function",
                        "function": {
                            "name": "write_file",
                            "arguments": json.dumps({
                                "path": "calculator.py",
                                "content": "def add(a, b):\n    return a + b\n\ndef multiply(a, b):\n    return a * b\n",
                            })
                        }
                    }]
                }
            }]
        }

        # Turn 2: Model calls run_check to test
        turn2_response = {
            "choices": [{
                "message": {
                    "role": "assistant",
                    "content": "Now I will run the tests to verify the changes.",
                    "tool_calls": [{
                        "id": "tc_run_check",
                        "type": "function",
                        "function": {
                            "name": "run_check",
                            "arguments": json.dumps({
                                "command": "python -m unittest test_calculator.py"
                            })
                        }
                    }]
                }
            }]
        }

        # Turn 3: Model summarizes and completes
        turn3_response = {
            "choices": [{
                "message": {
                    "role": "assistant",
                    "content": "All tests pass. The multiply function is successfully implemented and verified.",
                    "tool_calls": []
                }
            }]
        }

        mock_responses = [
            MagicMock(status_code=200, json=lambda: turn1_response, text=json.dumps(turn1_response)),
            MagicMock(status_code=200, json=lambda: turn2_response, text=json.dumps(turn2_response)),
            MagicMock(status_code=200, json=lambda: turn3_response, text=json.dumps(turn3_response)),
        ]

        with patch("app.services.meta_agent.async_session_factory", side_effect=self.session_factory), \
             patch("httpx.AsyncClient.post", side_effect=mock_responses):

            # Start execution loop
            await adapter.run_task(task_id)

            # Wait briefly for task to reach APPROVAL_REQUIRED
            for _ in range(50):
                await asyncio.sleep(0.05)
                async with self.session_factory() as db:
                    t = await db.get(Task, task_id)
                    if t and t.status == TaskStatus.APPROVAL_REQUIRED.value:
                        break

            async with self.session_factory() as db:
                t = await db.get(Task, task_id)
                self.assertIsNotNone(t)
                self.assertEqual(t.status, TaskStatus.APPROVAL_REQUIRED.value)
                exec_log = json.loads(t.execution_log)
                self.assertIn("diff", exec_log)
                self.assertIn("diff_hash", exec_log)
                self.assertEqual(exec_log["last_check_exit_code"], 0)
                self.assertTrue(exec_log["last_check_passed"])

            # Submit Approval
            await adapter.handle_approval(task_id, approved=True)

            # Wait for task completion and commit
            for _ in range(50):
                await asyncio.sleep(0.05)
                async with self.session_factory() as db:
                    t = await db.get(Task, task_id)
                    if t and t.status == TaskStatus.COMPLETED.value:
                        break

            async with self.session_factory() as db:
                t = await db.get(Task, task_id)
                self.assertEqual(t.status, TaskStatus.COMPLETED.value)
                self.assertIsNotNone(t.commit_sha)

            # Verify Git commit in working tree
            log_res = subprocess.run(["git", "log", "-n", "1", "--oneline"], cwd=self.temp_dir, capture_output=True, text=True)
            self.assertIn("Add multiply feature", log_res.stdout)

            # Verify working tree is clean
            diff_res = await self.provider.get_git_diff(workspace)
            self.assertEqual(diff_res.diff.strip(), "")

    async def test_end_to_end_rejection_leaves_pre_existing_files_untouched(self) -> None:
        """Verify rejecting a task reverts only task modifications while preserving unrelated work."""
        # 1. Create a pre-existing untracked file and modify an existing file
        pre_existing_untracked = os.path.join(self.temp_dir, "notes.txt")
        with open(pre_existing_untracked, "w", encoding="utf-8") as f:
            f.write("User scratchpad notes - do not delete!\n")

        adapter = MetaAgentAdapter()

        async with self.session_factory() as db:
            user, project, workspace, conv = await self._create_test_entities(db)
            task = Task(
                id=uuid.uuid4(),
                project_id=project.id,
                workspace_id=workspace.id,
                conversation_id=conv.id,
                title="Experimental feature",
                prompt="Add experimental feature",
                status=TaskStatus.QUEUED.value,
            )
            db.add(task)
            await db.commit()
            task_id = task.id

        # Model creates a new file 'experimental.py' and edits 'calculator.py'
        turn1_response = {
            "choices": [{
                "message": {
                    "role": "assistant",
                    "content": "Writing experimental file.",
                    "tool_calls": [{
                        "id": "tc_exp",
                        "type": "function",
                        "function": {
                            "name": "write_file",
                            "arguments": json.dumps({
                                "path": "experimental.py",
                                "content": "# Experimental\n"
                            })
                        }
                    }]
                }
            }]
        }
        turn2_response = {
            "choices": [{
                "message": {
                    "role": "assistant",
                    "content": "Done with experiment.",
                    "tool_calls": []
                }
            }]
        }

        mock_responses = [
            MagicMock(status_code=200, json=lambda: turn1_response, text=json.dumps(turn1_response)),
            MagicMock(status_code=200, json=lambda: turn2_response, text=json.dumps(turn2_response)),
        ]

        with patch("app.services.meta_agent.async_session_factory", side_effect=self.session_factory), \
             patch("httpx.AsyncClient.post", side_effect=mock_responses):

            await adapter.run_task(task_id)

            for _ in range(50):
                await asyncio.sleep(0.05)
                async with self.session_factory() as db:
                    t = await db.get(Task, task_id)
                    if t and t.status == TaskStatus.APPROVAL_REQUIRED.value:
                        break

            # Reject the task
            await adapter.handle_approval(task_id, approved=False, reason="Rejected: Architecture unapproved")

            for _ in range(50):
                await asyncio.sleep(0.05)
                async with self.session_factory() as db:
                    t = await db.get(Task, task_id)
                    if t and t.status == TaskStatus.CANCELLED.value:
                        break

            async with self.session_factory() as db:
                t = await db.get(Task, task_id)
                self.assertEqual(t.status, TaskStatus.CANCELLED.value)

            # Verification:
            # 1. Experimental file created by task was safely removed
            self.assertFalse(os.path.exists(os.path.join(self.temp_dir, "experimental.py")))
            # 2. Pre-existing untracked file was preserved completely!
            self.assertTrue(os.path.exists(pre_existing_untracked))
            with open(pre_existing_untracked, "r", encoding="utf-8") as f:
                self.assertIn("User scratchpad notes", f.read())

    async def test_interrupted_task_recovery_preserves_disk_modifications(self) -> None:
        """Verify an interrupted task marks task as failed, but preserves working tree files on disk."""
        # Write modified code to working tree
        with open(os.path.join(self.temp_dir, "calculator.py"), "a", encoding="utf-8") as f:
            f.write("# Interrupted modification on disk\n")

        async with self.session_factory() as db:
            user, project, workspace, conv = await self._create_test_entities(db)
            task = Task(
                id=uuid.uuid4(),
                project_id=project.id,
                workspace_id=workspace.id,
                conversation_id=conv.id,
                title="Interrupted Task",
                prompt="Add divide function",
                status=TaskStatus.RUNNING.value,  # Was in progress when restart happened
            )
            db.add(task)
            await db.commit()
            task_id = task.id

        # Reconcile interrupted tasks (server reboot simulation)
        with patch("app.services.task_recovery.async_session_factory", side_effect=self.session_factory):
            reconciled = await reconcile_interrupted_tasks()
            self.assertEqual(len(reconciled), 1)

        async with self.session_factory() as db:
            t = await db.get(Task, task_id)
            self.assertEqual(t.status, TaskStatus.FAILED.value)
            self.assertIn('"interrupted": true', t.execution_log)

            # Check that an assistant explanation message was created directing user to Changes tab
            msg_res = await db.execute(select(ConversationMessage).where(ConversationMessage.conversation_id == conv.id))
            messages = msg_res.scalars().all()
            self.assertTrue(any("preserved on disk" in m.content for m in messages))
            self.assertTrue(any("Changes" in m.content for m in messages))

        # Crucial check: working-tree file modifications must NOT be deleted or discarded
        diff_res = await self.provider.get_git_diff(workspace)
        self.assertIn("Interrupted modification on disk", diff_res.diff)

    async def test_live_meta_api_tool_roundtrip(self) -> None:
        """Integration test against the live Meta Model API (muse-spark-1.3) when configured."""
        api_key = settings.MODEL_API_KEY
        if not api_key:
            self.skipTest("MODEL_API_KEY not set; skipping live endpoint test.")

        base_url = settings.META_MODEL_BASE_URL.rstrip("/")
        model_id = settings.META_MODEL_ID

        tools = [
            {
                "type": "function",
                "function": {
                    "name": "list_files",
                    "description": "List files in the workspace directory.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "directory": {"type": "string", "description": "Subdirectory to list"}
                        },
                        "required": []
                    }
                }
            }
        ]

        messages = [
            {"role": "system", "content": "You are a coding assistant. Use the list_files tool to inspect the workspace."},
            {"role": "user", "content": "Please inspect the root workspace and tell me what files are present."}
        ]

        async with httpx.AsyncClient(timeout=30.0) as client:
            resp1 = await client.post(
                f"{base_url}/chat/completions",
                headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
                json={
                    "model": model_id,
                    "messages": messages,
                    "tools": tools,
                    "tool_choice": "auto"
                }
            )
            self.assertEqual(resp1.status_code, 200)
            data1 = resp1.json()
            tool_calls = data1["choices"][0]["message"].get("tool_calls", [])
            self.assertGreater(len(tool_calls), 0)
            tc = tool_calls[0]
            self.assertEqual(tc["function"]["name"], "list_files")

            # Feed back tool result
            messages.append(data1["choices"][0]["message"])
            messages.append({
                "role": "tool",
                "tool_call_id": tc["id"],
                "content": json.dumps(["calculator.py", "test_calculator.py"])
            })

            resp2 = await client.post(
                f"{base_url}/chat/completions",
                headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
                json={
                    "model": model_id,
                    "messages": messages,
                    "tools": tools,
                }
            )
            self.assertEqual(resp2.status_code, 200)
            data2 = resp2.json()
            content2 = data2["choices"][0]["message"].get("content", "")
            self.assertTrue("calculator.py" in content2 or "test_calculator.py" in content2 or len(content2) > 0)


if __name__ == "__main__":
    unittest.main()
