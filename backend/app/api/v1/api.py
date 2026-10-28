from fastapi import APIRouter
from app.api.v1.endpoints import (
    auth,
    conversations,
    github,
    health,
    projects,
    tasks,
    ui_suggestions,
    voice,
    workspaces,
    ws,
)

api_router = APIRouter()

# Health endpoints
api_router.include_router(health.router, tags=["Health"])

# Authentication endpoints
api_router.include_router(auth.router, prefix="/auth", tags=["Authentication"])

# Voice Transcription endpoints (Muse Voice Transcribe)
api_router.include_router(voice.router, prefix="/voice", tags=["Voice"])

# UI Design Suggestions endpoints (Muse Image)
api_router.include_router(ui_suggestions.router, tags=["UI Suggestions"])

# GitHub Integration endpoints
api_router.include_router(github.router, prefix="/github", tags=["GitHub"])

# Projects endpoints
api_router.include_router(projects.router, prefix="/projects", tags=["Projects"])

# Conversations & Runs endpoints
api_router.include_router(conversations.router, tags=["Conversations"])

# Workspaces endpoints
api_router.include_router(workspaces.router, tags=["Workspaces"])

# Tasks endpoints (legacy)
api_router.include_router(tasks.router, tags=["Tasks"])

# WebSocket streaming endpoints
api_router.include_router(ws.router, prefix="/ws", tags=["WebSockets"])
