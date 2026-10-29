import logging
from typing import Optional
from fastapi import APIRouter, Depends, File, Form, HTTPException, UploadFile, status

from app.api.deps import get_current_user
from app.core.config import settings
from app.db.models.user import User
from app.services.meta_voice_service import meta_voice_service

logger = logging.getLogger("jess_backend")

router = APIRouter()


MAX_AUDIO_SIZE_BYTES = 15 * 1024 * 1024  # 15 MB
ALLOWED_AUDIO_EXTENSIONS = {".m4a", ".wav", ".mp3", ".webm", ".ogg", ".aac"}


@router.post(
    "/transcribe",
    summary="Transcribe conversational voice input using Muse Voice Transcribe",
    status_code=status.HTTP_200_OK,
)
async def transcribe_voice(
    file: UploadFile = File(..., description="Audio recording binary file (e.g. m4a, wav, mp3)"),
    language: Optional[str] = Form(None, description="Optional ISO language code (e.g. 'ta', 'en')"),
    current_user: User = Depends(get_current_user),
):
    """Transcribe client-recorded voice audio into text.
    
    Uses Meta's Muse Voice Transcribe (muse-voice-transcribe-1.0) on the server.
    API keys remain completely protected on the backend.
    """
    if not file:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="No audio file provided.",
        )

    filename = file.filename or "recording.m4a"
    ext = "." + filename.rsplit(".", 1)[-1].lower() if "." in filename else ""
    if ext and ext not in ALLOWED_AUDIO_EXTENSIONS:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Unsupported audio format '{ext}'. Allowed formats: {', '.join(sorted(ALLOWED_AUDIO_EXTENSIONS))}",
        )

    try:
        audio_bytes = await file.read()
        if not audio_bytes:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Uploaded audio file is empty.",
            )

        if len(audio_bytes) > MAX_AUDIO_SIZE_BYTES:
            raise HTTPException(
                status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
                detail=f"Audio file exceeds maximum size limit of {MAX_AUDIO_SIZE_BYTES // (1024 * 1024)} MB.",
            )

        content_type = file.content_type or "audio/m4a"

        transcript = await meta_voice_service.transcribe_audio(
            audio_bytes=audio_bytes,
            filename=filename,
            content_type=content_type,
            language=language,
        )

        return {
            "text": transcript,
            "model": settings.META_VOICE_MODEL_ID,
            "bytes_received": len(audio_bytes),
        }

    except HTTPException:
        raise
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))
    except TimeoutError:
        raise HTTPException(
            status_code=status.HTTP_504_GATEWAY_TIMEOUT,
            detail="Voice transcription request timed out. Please try again with a shorter recording.",
        )
    except Exception as e:
        logger.error(f"[VoiceEndpoint] Transcription error: {e}", exc_info=True)
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail="Voice transcription service temporarily unavailable. Please try again.",
        )
