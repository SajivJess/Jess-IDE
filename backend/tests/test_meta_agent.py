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


if __name__ == "__main__":
    unittest.main()
