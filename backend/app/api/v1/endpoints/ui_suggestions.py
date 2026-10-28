import logging
import uuid
from pathlib import Path
from typing import Optional
from fastapi import APIRouter, Depends, HTTPException, status
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import get_current_user
from app.db.models.project import Project
from app.db.models.user import User
from app.db.session import get_db
from app.services.meta_image_service import meta_image_service

logger = logging.getLogger("jess_backend")

router = APIRouter()


class UiSuggestionRequest(BaseModel):
    prompt: str = Field(..., description="Description of the screen or UI component to design")
    reference_image: Optional[str] = Field(None, description="Optional base64-encoded reference mockup or screenshot")


async def _get_project_with_ownership(
    project_id: uuid.UUID,
    user_id: uuid.UUID,
    db: AsyncSession,
) -> Project:
    stmt = select(Project).where(Project.id == project_id, Project.user_id == user_id)
    res = await db.execute(stmt)
    project = res.scalar_one_or_none()
    if not project:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Project not found",
        )
    return project


@router.post(
    "/projects/{project_id}/ui-suggestions",
    summary="Generate UI design suggestion mockup with Muse Image",
    status_code=status.HTTP_200_OK,
)
async def generate_ui_suggestion(
    project_id: uuid.UUID,
    payload: UiSuggestionRequest,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Generate a UI design suggestion mockup using Meta's Muse Image (muse-image-1.0).
    
    Returns a visual mockup proposal. Muse Spark's coding loop remains separate and unaltered.
    """
    await _get_project_with_ownership(project_id, current_user.id, db)

    try:
        suggestion = await meta_image_service.generate_ui_suggestion(
            prompt=payload.prompt,
            project_id=str(project_id),
            reference_image_base64=payload.reference_image,
        )

        image_id = suggestion["id"]
        suggestion["preview_url"] = f"/api/v1/projects/{project_id}/ui-suggestions/preview/{image_id}"
        return suggestion

    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))
    except TimeoutError as e:
        raise HTTPException(status_code=status.HTTP_504_GATEWAY_TIMEOUT, detail=str(e))
    except Exception as e:
        logger.error(f"[UiSuggestions] Error generating mockup: {e}")
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=f"UI suggestion service error: {e}",
        )


@router.get(
    "/projects/{project_id}/ui-suggestions/preview/{image_id}",
    summary="Get cached UI suggestion image mockup",
)
async def get_ui_suggestion_preview(
    project_id: uuid.UUID,
    image_id: str,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Serve cached UI design mockup image."""
    await _get_project_with_ownership(project_id, current_user.id, db)

    # Validate image_id is clean UUID to prevent path traversal
    try:
        uuid.UUID(image_id)
    except ValueError:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Invalid image ID format.")

    img_path = Path("workspaces_data/ui_suggestions") / f"{image_id}.png"
    if not img_path.exists():
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="UI mockup image not found.")

    return FileResponse(path=str(img_path), media_type="image/png")
