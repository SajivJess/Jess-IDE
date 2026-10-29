import base64
import unittest
from unittest.mock import AsyncMock, MagicMock, patch
import uuid
from fastapi.testclient import TestClient
import httpx
import pytest

from app.core.config import settings
from app.db.models.project import Project
from app.db.models.user import User
from app.db.session import get_db
from app.api.deps import get_current_user
from app.main import app
from app.services.meta_voice_service import meta_voice_service
from app.services.meta_image_service import meta_image_service


class TestMetaVoiceAndImage(unittest.IsolatedAsyncioTestCase):
    """Test suite for Muse Voice Transcribe and Muse Image while preserving Muse Spark."""

    def test_model_configuration_preservation(self) -> None:
        """Verify Muse Spark remains primary while Voice and Image models are configured."""
        self.assertEqual(settings.META_MODEL_ID, "muse-spark-1.3")
        self.assertEqual(settings.META_VOICE_MODEL_ID, "muse-voice-transcribe-1.0")
        self.assertEqual(settings.META_IMAGE_MODEL_ID, "muse-image-1.0")

    @pytest.mark.asyncio
    async def test_voice_transcription_empty_audio_raises(self) -> None:
        """Verify empty audio bytes raise ValueError."""
        with self.assertRaises(ValueError):
            await meta_voice_service.transcribe_audio(b"", "audio.m4a", "audio/m4a")

    @pytest.mark.asyncio
    async def test_voice_transcription_simulation_fallback(self) -> None:
        """Verify deterministic fallback when MODEL_API_KEY is not configured."""
        with patch.object(settings, "MODEL_API_KEY", None):
            result = await meta_voice_service.transcribe_audio(b"dummy_audio_bytes", "audio.m4a", "audio/m4a")
            self.assertIsInstance(result, str)
            self.assertTrue(result.startswith("[Simulated Voice Note]"))

    @pytest.mark.asyncio
    async def test_voice_transcription_mock_api_call(self) -> None:
        """Verify Meta Model API request format for muse-voice-transcribe-1.0."""
        mock_response = MagicMock(spec=httpx.Response)
        mock_response.status_code = 200
        mock_response.json.return_value = {"text": "Add a dark mode toggle to the dashboard."}

        with patch.object(settings, "MODEL_API_KEY", "meta_key_voice_test"), \
             patch("httpx.AsyncClient.post", new_callable=AsyncMock) as mock_post:
            mock_post.return_value = mock_response

            transcript = await meta_voice_service.transcribe_audio(
                audio_bytes=b"sample_voice_bytes",
                filename="voice_command.m4a",
                content_type="audio/m4a",
                language="ta",
            )

            self.assertEqual(transcript, "Add a dark mode toggle to the dashboard.")
            mock_post.assert_called_once()
            call_kwargs = mock_post.call_args[1]
            self.assertEqual(call_kwargs["headers"]["Authorization"], "Bearer meta_key_voice_test")
            self.assertEqual(call_kwargs["data"]["model"], "muse-voice-transcribe-1.0")
            self.assertEqual(call_kwargs["data"]["language"], "ta")

    @pytest.mark.asyncio
    async def test_ui_suggestion_empty_prompt_raises(self) -> None:
        """Verify empty prompt raises ValueError."""
        with self.assertRaises(ValueError):
            await meta_image_service.generate_ui_suggestion("")

    @pytest.mark.asyncio
    async def test_ui_suggestion_simulation_fallback(self) -> None:
        """Verify deterministic fallback when MODEL_API_KEY is not configured."""
        with patch.object(settings, "MODEL_API_KEY", None):
            res = await meta_image_service.generate_ui_suggestion("Modern calculator interface")
            self.assertEqual(res["model"], "muse-image-1.0")
            self.assertEqual(res["status"], "simulated")
            self.assertTrue(res["prompt"].startswith("[Simulated Mockup]"))
            self.assertTrue(res["image_data_uri"].startswith("data:image/png;base64,"))

    @pytest.mark.asyncio
    async def test_ui_suggestion_mock_api_call(self) -> None:
        """Verify Meta Model API request format for muse-image-1.0."""
        fake_b64 = base64.b64encode(b"fake_png_binary_content").decode("utf-8")
        mock_response = MagicMock(spec=httpx.Response)
        mock_response.status_code = 200
        mock_response.json.return_value = {"data": [{"b64_json": fake_b64}]}

        with patch.object(settings, "MODEL_API_KEY", "meta_key_image_test"), \
             patch("httpx.AsyncClient.post", new_callable=AsyncMock) as mock_post:
            mock_post.return_value = mock_response

            res = await meta_image_service.generate_ui_suggestion("E-commerce cart screen")

            self.assertEqual(res["model"], "muse-image-1.0")
            self.assertEqual(res["status"], "generated")
            self.assertIn("data:image/png;base64,", res["image_data_uri"])
            mock_post.assert_called_once()
            call_kwargs = mock_post.call_args[1]
            self.assertEqual(call_kwargs["headers"]["Authorization"], "Bearer meta_key_image_test")
            self.assertEqual(call_kwargs["json"]["model"], "muse-image-1.0")
            self.assertIn("E-commerce cart screen", call_kwargs["json"]["prompt"])

    def test_voice_endpoint_integration(self) -> None:
        """Test POST /api/v1/voice/transcribe with authentication and multipart upload."""
        mock_user = User(
            id=uuid.uuid4(),
            email="voice_tester@example.com",
            is_active=True,
            is_verified=True,
        )

        app.dependency_overrides[get_current_user] = lambda: mock_user
        try:
            client = TestClient(app)

            with patch.object(meta_voice_service, "transcribe_audio", new_callable=AsyncMock) as mock_transcribe:
                mock_transcribe.return_value = "Run tests on calculator component."

                files = {"file": ("audio_note.m4a", b"raw_audio_test_content", "audio/m4a")}
                data = {"language": "en"}
                res = client.post("/api/v1/voice/transcribe", files=files, data=data)

                self.assertEqual(res.status_code, 200)
                body = res.json()
                self.assertEqual(body["text"], "Run tests on calculator component.")
                self.assertEqual(body["model"], "muse-voice-transcribe-1.0")
                mock_transcribe.assert_called_once()

            # Test invalid extension rejected
            bad_ext_files = {"file": ("malicious_script.sh", b"echo hello", "text/x-shellscript")}
            bad_res = client.post("/api/v1/voice/transcribe", files=bad_ext_files)
            self.assertEqual(bad_res.status_code, 400)
            self.assertIn("Unsupported audio format", bad_res.json()["detail"])

            # Test oversized file rejected (> 15MB)
            oversized_data = b"x" * (16 * 1024 * 1024)
            oversized_files = {"file": ("huge_recording.m4a", oversized_data, "audio/m4a")}
            large_res = client.post("/api/v1/voice/transcribe", files=oversized_files)
            self.assertEqual(large_res.status_code, 413)
            self.assertIn("exceeds maximum size limit", large_res.json()["detail"])
        finally:
            app.dependency_overrides.pop(get_current_user, None)

    def test_ui_suggestions_endpoint_integration(self) -> None:
        """Test POST /api/v1/projects/{project_id}/ui-suggestions and preview endpoint."""
        user_id = uuid.uuid4()
        project_id = uuid.uuid4()
        mock_user = User(id=user_id, email="ui_tester@example.com", is_active=True, is_verified=True)
        mock_project = Project(id=project_id, user_id=user_id, name="Test Project")

        mock_db = MagicMock()
        mock_exec = AsyncMock()
        mock_scalar = MagicMock()
        mock_scalar.scalar_one_or_none.return_value = mock_project
        mock_exec.return_value = mock_scalar
        mock_db.execute = mock_exec

        async def _override_get_db():
            yield mock_db

        app.dependency_overrides[get_current_user] = lambda: mock_user
        app.dependency_overrides[get_db] = _override_get_db

        try:
            client = TestClient(app)

            with patch.object(meta_image_service, "generate_ui_suggestion", new_callable=AsyncMock) as mock_gen:
                mock_gen.return_value = {
                    "id": str(uuid.uuid4()),
                    "prompt": "Dashboard dark mode",
                    "model": "muse-image-1.0",
                    "status": "generated",
                    "image_filename": "mockup.png",
                    "image_data_uri": "data:image/png;base64,mock",
                }

                res = client.post(
                    f"/api/v1/projects/{project_id}/ui-suggestions",
                    json={"prompt": "Dashboard dark mode"},
                )

                self.assertEqual(res.status_code, 200)
                body = res.json()
                self.assertEqual(body["model"], "muse-image-1.0")
                self.assertIn("preview_url", body)
                mock_gen.assert_called_once()
        finally:
            app.dependency_overrides.pop(get_current_user, None)
            app.dependency_overrides.pop(get_db, None)
