from contextlib import asynccontextmanager
from typing import AsyncGenerator
from fastapi import FastAPI, Request, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from fastapi.exceptions import RequestValidationError
from fastapi.encoders import jsonable_encoder

from app.core.config import settings
from app.core.logging import logger
from app.api.v1.api import api_router
from app.api.v1.endpoints.health import health_check, readiness_check


from sqlalchemy import select
from app.db.models.task import Task
from app.db.session import async_session_factory
from app.schemas.task import TaskStatus


from app.services.task_recovery import reconcile_interrupted_tasks


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncGenerator[None, None]:
    """Application lifespan context manager for startup and shutdown events."""
    logger.info(
        f"Starting {settings.PROJECT_NAME} v{settings.VERSION} "
        f"[env: {settings.ENVIRONMENT}, debug: {settings.DEBUG}]"
    )
    try:
        await reconcile_interrupted_tasks()
    except Exception as e:
        logger.warning(f"[Recovery] Could not reconcile interrupted tasks at startup: {e}")
    yield
    logger.info(f"Shutting down {settings.PROJECT_NAME}")


app = FastAPI(
    title=settings.PROJECT_NAME,
    version=settings.VERSION,
    description="Jess Ide Dev — Agentic Coding Environment Backend API",
    openapi_url=f"{settings.API_V1_STR}/openapi.json" if settings.DEBUG else None,
    docs_url="/docs" if settings.DEBUG else None,
    redoc_url="/redoc" if settings.DEBUG else None,
    lifespan=lifespan,
)

# CORS Middleware Configuration
if settings.CORS_ORIGINS:
    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.CORS_ORIGINS,
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )

# Root-level health check (for simple load balancers & container probes)
app.add_api_route(
    "/health",
    health_check,
    methods=["GET"],
    tags=["Health"],
    summary="Root Health Check",
)
app.add_api_route(
    "/ready",
    readiness_check,
    methods=["GET"],
    tags=["Health"],
    summary="Root Readiness Check",
)

from app.api.v1.endpoints.ws import router as ws_router

# API v1 Router
app.include_router(api_router, prefix=settings.API_V1_STR)

# Direct /ws route for convenience
app.include_router(ws_router, prefix="/ws", tags=["WebSockets"])


# Basic Request Error Handling
@app.exception_handler(RequestValidationError)
async def validation_exception_handler(
    request: Request, exc: RequestValidationError
) -> JSONResponse:
    """Standardized 422 Unprocessable Entity error handler."""
    logger.warning(f"Validation error on {request.method} {request.url.path}: {exc.errors()}")
    return JSONResponse(
        status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
        content={
            "error": "Validation Error",
            "detail": jsonable_encoder(exc.errors()),
        },
    )


@app.exception_handler(Exception)
async def generic_exception_handler(
    request: Request, exc: Exception
) -> JSONResponse:
    """Standardized 500 Internal Server Error handler preventing stack trace leak."""
    logger.error(f"Unhandled server exception on {request.method} {request.url.path}: {str(exc)}", exc_info=True)
    return JSONResponse(
        status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
        content={
            "error": "Internal Server Error",
            "message": "An unexpected error occurred. Please check server logs.",
        },
    )
