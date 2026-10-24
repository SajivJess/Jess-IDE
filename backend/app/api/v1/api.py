from fastapi import APIRouter
from app.api.v1.endpoints import auth, health, projects, tasks, ws

api_router = APIRouter()

# Health endpoints
api_router.include_router(health.router, tags=["Health"])

# Authentication endpoints
api_router.include_router(auth.router, prefix="/auth", tags=["Authentication"])

# Projects endpoints
api_router.include_router(projects.router, prefix="/projects", tags=["Projects"])

# Tasks endpoints
api_router.include_router(tasks.router, tags=["Tasks"])

# WebSocket streaming endpoints
api_router.include_router(ws.router, prefix="/ws", tags=["WebSockets"])
