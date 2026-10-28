import unittest
import uuid
from unittest.mock import patch

from app.core.config import Settings, settings
from app.services.agent_adapter import DispatchingAgentAdapter, SimulatedAgentAdapter
from app.services.meta_agent import META_TOOLS, MetaAgentAdapter


class TestMetaAgent(unittest.IsolatedAsyncioTestCase):
    def test_meta_settings_configuration(self) -> None:
        test_settings = Settings(
            MODEL_API_KEY="test_meta_key_12345",
            META_MODEL_ID="muse-spark-1.3",
            AGENT_PROVIDER="meta",
        )
        self.assertEqual(test_settings.MODEL_API_KEY, "test_meta_key_12345")
        self.assertEqual(test_settings.META_MODEL_ID, "muse-spark-1.3")
        self.assertEqual(test_settings.META_MODEL_BASE_URL, "https://api.meta.ai/v1")
        self.assertEqual(test_settings.AGENT_PROVIDER, "meta")
        self.assertEqual(test_settings.META_MAX_TOOL_ITERATIONS, 15)
        self.assertEqual(test_settings.META_MAX_REPAIR_ATTEMPTS, 3)

    def test_meta_tools_schema(self) -> None:
        tool_names = [t["function"]["name"] for t in META_TOOLS]
        self.assertIn("list_files", tool_names)
        self.assertIn("read_file", tool_names)
        self.assertIn("write_file", tool_names)
        self.assertIn("run_check", tool_names)
        self.assertIn("get_git_diff", tool_names)

        write_tool = next(t for t in META_TOOLS if t["function"]["name"] == "write_file")
        self.assertEqual(write_tool["function"]["parameters"]["required"], ["path", "content"])

        run_tool = next(t for t in META_TOOLS if t["function"]["name"] == "run_check")
        self.assertEqual(run_tool["function"]["parameters"]["required"], ["command"])

    def test_dispatching_agent_adapter_routes_to_meta(self) -> None:
        with patch.object(settings, "MODEL_API_KEY", "valid_key"), \
             patch.object(settings, "AGENT_PROVIDER", "meta"):
            dispatcher = DispatchingAgentAdapter()
            resolved = dispatcher._resolve()
            self.assertIsInstance(resolved, MetaAgentAdapter)

    def test_dispatching_agent_adapter_routes_to_simulated(self) -> None:
        with patch.object(settings, "AGENT_PROVIDER", "simulated"):
            dispatcher = DispatchingAgentAdapter()
            resolved = dispatcher._resolve()
            self.assertIsInstance(resolved, SimulatedAgentAdapter)

    async def test_meta_adapter_cancellation(self) -> None:
        adapter = MetaAgentAdapter()
        task_id = uuid.uuid4()

        self.assertFalse(adapter.is_task_running(task_id))
        # Calling cancel on non-running task should not raise error
        await adapter.cancel_task(task_id)
        # Calling handle_approval on non-pending task should not raise error
        await adapter.handle_approval(task_id, approved=True)

    async def test_workspace_command_allowlist_enforcement(self) -> None:
        from app.db.models.workspace import Workspace
        from app.schemas.workspace import WorkspaceStatus
        from app.services.workspace.local_sandbox import LocalSandboxWorkspaceProvider

        provider = LocalSandboxWorkspaceProvider()
        ws = Workspace(
            id=uuid.uuid4(),
            user_id=uuid.uuid4(),
            name="test-ws",
            status=WorkspaceStatus.RUNNING.value,
        )

        # Disallowed command (e.g., powershell, curl, rm) should be rejected immediately
        disallowed_res = await provider.execute_command(ws, ["powershell", "-c", "echo 1"])
        self.assertEqual(disallowed_res.exit_code, 1)
        self.assertIn("not permitted by workspace sandbox allowlist", disallowed_res.stderr)

        # Allowed command (e.g., python) should not be blocked by allowlist
        allowed_res = await provider.execute_command(ws, ["python", "--version"])
        self.assertNotIn("not permitted by workspace sandbox allowlist", allowed_res.stderr)

    async def test_workspace_secret_file_protection(self) -> None:
        from app.db.models.workspace import Workspace
        from app.schemas.workspace import WorkspaceStatus
        from app.services.workspace.local_sandbox import LocalSandboxWorkspaceProvider

        provider = LocalSandboxWorkspaceProvider()
        ws = Workspace(
            id=uuid.uuid4(),
            user_id=uuid.uuid4(),
            name="test-ws",
            status=WorkspaceStatus.RUNNING.value,
        )

        # Prohibit reading .env
        with self.assertRaises(ValueError):
            await provider.read_file(ws, ".env")

        # Prohibit writing .env
        with self.assertRaises(ValueError):
            await provider.write_file(ws, ".env", "SECRET=123")

        # Prohibit writing .git
        with self.assertRaises(ValueError):
            await provider.write_file(ws, ".git/config", "evil")


if __name__ == "__main__":
    unittest.main()
