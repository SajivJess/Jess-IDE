import hashlib
import json
import os
import shutil
import tempfile
import unittest
import uuid

import httpx
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from app.core.config import settings
from app.core.security import create_access_token
from app.db.base import Base
from app.db.models.conversation import Conversation
from app.db.models.conversation_message import ConversationMessage
from app.db.models.project import Project
from app.db.models.user import User
from app.db.models.workspace import Workspace
from app.main import app
from app.services.meta_agent import META_TOOLS
from app.services.workspace import get_workspace_provider
from app.services.workspace.local_sandbox import LocalSandboxWorkspaceProvider


class TestLivePreviewAndHosting(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self.temp_dir = tempfile.mkdtemp(prefix="jess_preview_test_")
        self.provider = LocalSandboxWorkspaceProvider()

        db_file = os.path.join(self.temp_dir, "test_preview.db")
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

    def test_meta_tools_registered(self) -> None:
        """Verify host_preview is properly registered in META_TOOLS."""
        tool_names = [t["function"]["name"] for t in META_TOOLS if "function" in t]
        self.assertIn("host_preview", tool_names)
        self.assertIn("get_git_diff", tool_names
)
        self.assertIn("write_file", tool_names)

        host_tool = next(t for t in META_TOOLS if t.get("function", {}).get("name") == "host_preview")
        props = host_tool["function"]["parameters"]["properties"]
        self.assertIn("file_path", props)
        self.assertIn("hosting_type", props)
        self.assertEqual(host_tool["function"]["parameters"]["required"], ["file_path"])

    async def test_live_preview_endpoint(self) -> None:
        """Verify workspace preview serves HTML with correct content type and directory traversal safety."""
        async with self.session_factory() as db:
            user = User(
                id=uuid.uuid4(),
                email="dev@preview.test",
                hashed_password="pw",
                is_active=True,
                is_verified=True,
            )
            project = Project(
                id=uuid.uuid4(),
                user_id=user.id,
                name="Calculator Preview Project",
            )
            workspace = Workspace(
                id=uuid.uuid4(),
                user_id=user.id,
                project_id=project.id,
                name="Calc Workspace",
                status="running",
            )
            db.add_all([user, project, workspace])
            await db.commit()

            # Set up workspace directory
            wdir = self.provider.get_workspace_dir(workspace)
            wdir.mkdir(parents=True, exist_ok=True)
            html_content = "<!DOCTYPE html><html><body><h1>Jess IDE Calculator Live Preview</h1></body></html>"
            (wdir / "calculator.html").write_text(html_content, encoding="utf-8")

        async def _override_get_db():
            async with self.session_factory() as s:
                yield s

        from app.db.session import get_db
        app.dependency_overrides[get_db] = _override_get_db

        try:
            async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test") as client:
                # 1. Preview calculator.html
                res = await client.get(f"/api/v1/workspaces/{workspace.id}/preview/calculator.html")
                self.assertEqual(res.status_code, 200)
                self.assertIn("text/html", res.headers.get("content-type", ""))
                self.assertIn("Jess IDE Calculator Live Preview", res.text)
                self.assertEqual(res.headers.get("x-jess-workspace-preview"), "true")

                # 2. Directory fallback (empty path -> calculator.html)
                res_fallback = await client.get(f"/api/v1/workspaces/{workspace.id}/preview/")
                self.assertEqual(res_fallback.status_code, 200)
                self.assertIn("Jess IDE Calculator Live Preview", res_fallback.text)

                # 3. Path traversal protection
                res_traversal = await client.get(f"/api/v1/workspaces/{workspace.id}/preview/..%2F..%2Fsecret.txt")
                self.assertIn(res_traversal.status_code, (400, 401, 403, 404, 422))
        finally:
            app.dependency_overrides.pop(get_db, None)

    async def test_conversation_export(self) -> None:
        """Verify exporting conversation history as a text file."""
        async with self.session_factory() as db:
            user = User(
                id=uuid.uuid4(),
                email="dev@export.test",
                hashed_password="pw",
                is_active=True,
                is_verified=True,
            )
            project = Project(
                id=uuid.uuid4(),
                user_id=user.id,
                name="Export Project",
            )
            conv = Conversation(
                id=uuid.uuid4(),
                project_id=project.id,
                title="Calculator Feature Session",
            )
            m1 = ConversationMessage(
                id=uuid.uuid4(),
                conversation_id=conv.id,
                role="user",
                content="host the py file and html file and give me the temp link...",
            )
            m2 = ConversationMessage(
                id=uuid.uuid4(),
                conversation_id=conv.id,
                role="assistant",
                content="I have hosted your application! You can preview it at https://household-modeling-studio-carry.trycloudflare.com/...",
            )
            db.add_all([user, project, conv, m1, m2])
            await db.commit()

        token = create_access_token(user.id)
        headers = {"Authorization": f"Bearer {token}"}

        async def _override_get_db():
            async with self.session_factory() as s:
                yield s

        from app.db.session import get_db
        app.dependency_overrides[get_db] = _override_get_db

        try:
            async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test") as client:
                res = await client.get(
                    f"/api/v1/projects/{project.id}/conversations/{conv.id}/export",
                    headers=headers,
                )
                self.assertEqual(res.status_code, 200)
                self.assertIn("text/plain", res.headers.get("content-type", ""))
                self.assertIn("JESS IDE — CONVERSATION EXPORT", res.text)
                self.assertIn("host the py file", res.text)
                self.assertIn("trycloudflare.com", res.text)
                self.assertIn("attachment", res.headers.get("content-disposition", ""))
        finally:
            app.dependency_overrides.pop(get_db, None)
