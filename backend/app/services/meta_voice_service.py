import logging
from typing import Optional
import httpx

from app.core.config import settings

logger = logging.getLogger("jess_backend")


class MetaVoiceService:
    """Service for speech-to-text using Meta's Muse Voice Transcribe (muse-voice-transcribe-1.0).
    
    Converts audio recordings captured on client devices to text transcripts.
    Protects API keys server-side and supports multilingual speech including Tamil and English.
    """

    @classmethod
    async def transcribe_audio(
        cls,
        audio_bytes: bytes,
        filename: str = "audio.m4a",
        content_type: str = "audio/m4a",
        language: Optional[str] = None,
    ) -> str:
        """Transcribe audio bytes to text using Meta Model API.
        
        Args:
            audio_bytes: Raw audio binary data.
            filename: Audio file name (e.g. audio.wav, audio.m4a, audio.mp3).
            content_type: MIME type of the audio.
            language: Optional ISO language code (e.g. 'ta', 'en') or None for auto-detection.
            
        Returns:
            Recognized transcript text.
        """
        api_key = settings.MODEL_API_KEY
        base_url = settings.META_MODEL_BASE_URL.rstrip("/")
        model_id = settings.META_VOICE_MODEL_ID

        if not audio_bytes:
            raise ValueError("Audio data is empty.")

        # Safe fallback if API key is not configured or in offline simulation mode
        if not api_key:
            logger.info("[MetaVoice] MODEL_API_KEY not set. Returning simulated transcription.")
            return "[Simulated Voice Note] Create a responsive calculator app with HTML and CSS."

        url = f"{base_url}/audio/transcriptions"
        headers = {
            "Authorization": f"Bearer {api_key}",
        }

        data = {
            "model": model_id,
        }
        if language and language.strip():
            data["language"] = language.strip().lower()

        files = {
            "file": (filename, audio_bytes, content_type),
        }

        logger.info(f"[MetaVoice] Transcribing audio with model '{model_id}' ({len(audio_bytes)} bytes)")

        async with httpx.AsyncClient(timeout=60.0) as client:
            try:
                response = await client.post(
                    url,
                    headers=headers,
                    data=data,
                    files=files,
                )
                if response.status_code != 200:
                    err_msg = response.text[:300]
                    logger.error(f"[MetaVoice] Transcribe request failed: status {response.status_code} - {err_msg}")
                    raise RuntimeError(f"Transcription service error ({response.status_code}): {err_msg}")

                res_json = response.json()
                transcript = res_json.get("text", "")
                return transcript.strip()

            except httpx.TimeoutException:
                logger.error("[MetaVoice] Request timed out while calling transcription service.")
                raise TimeoutError("Voice transcription service timed out.")
            except Exception as e:
                logger.error(f"[MetaVoice] Error during audio transcription: {e}")
                raise


meta_voice_service = MetaVoiceService()
