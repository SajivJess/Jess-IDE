import time
from typing import Optional
from fastapi import APIRouter, Response, status
from pydantic import BaseModel

from app.core.config import settings
from app.db.session import check_db_connection

router = APIRouter()


class HealthResponse(BaseModel):
    status: str
    app: str
    version: str
    environment: str
    database: str
    timestamp: float


class ReadyResponse(BaseModel):
    status: str
    database: str
    timestamp: float


@router.get("/health", response_model=HealthResponse, summary="Check API health and DB connection")
async def health_check() -> HealthResponse:
    """Return an operational status payload indicating the service and database are reachable."""
    is_db_connected = await check_db_connection()
    return HealthResponse(
        status="ok",
        app=settings.PROJECT_NAME,
        version=settings.VERSION,
        environment=settings.ENVIRONMENT,
        database="connected" if is_db_connected else "disconnected",
        timestamp=time.time(),
    )


@router.get("/ready", response_model=ReadyResponse, summary="Readiness check for traffic routing")
async def readiness_check(response: Response) -> ReadyResponse:
    """Readiness probe that returns HTTP 200 if ready or 503 if dependencies are unavailable."""
    is_db_connected = await check_db_connection()
    if not is_db_connected:
        response.status_code = status.HTTP_503_SERVICE_UNAVAILABLE
        return ReadyResponse(
            status="not_ready",
            database="disconnected",
            timestamp=time.time(),
        )

    return ReadyResponse(
        status="ready",
        database="connected",
        timestamp=time.time(),
    )
