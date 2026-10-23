import time
from fastapi import APIRouter
from pydantic import BaseModel
from app.core.config import settings

router = APIRouter()


class HealthResponse(BaseModel):
    status: str
    app: str
    version: str
    environment: str
    timestamp: float


@router.get("/health", response_model=HealthResponse, summary="Check API health")
async def health_check() -> HealthResponse:
    """Return a healthy status payload indicating the service is running."""
    return HealthResponse(
        status="ok",
        app=settings.PROJECT_NAME,
        version=settings.VERSION,
        environment=settings.ENVIRONMENT,
        timestamp=time.time(),
    )
