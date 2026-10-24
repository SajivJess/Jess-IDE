import uuid
from typing import Any, Dict, Optional
from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import get_current_user
from app.core.logging import logger
from app.db.models.project import Project
from app.db.models.user import User
from app.db.models.workspace import Workspace
from app.db.session import get_db
from app.schemas.workspace import (
    WorkspaceCommandRequest,
    WorkspaceCommandResponse,
    WorkspaceCreate,
    WorkspaceFileItem,
    WorkspaceFileListResponse,
    WorkspaceFileReadResponse,
    WorkspaceFileWriteRequest,
    WorkspaceGitDiffResponse,
    WorkspaceGitStatusResponse,
    WorkspaceListResponse,
    WorkspaceRead,
    WorkspaceStatus,
    can_transition_workspace,
)
from app.services.workspace import get_workspace_provider

router = APIRouter()


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


async def _get_workspace_with_ownership(
    workspace_id: uuid.UUID,
    user_id: uuid.UUID,
    project_id: Optional[uuid.UUID],
    db: AsyncSession,
) -> Workspace:
    stmt = select(Workspace).where(Workspace.id == workspace_id, Workspace.user_id == user_id)
    if project_id:
        stmt = stmt.where(Workspace.project_id == project_id)

    res = await db.execute(stmt)
    ws = res.scalar_one_or_none()
    if not ws:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Workspace not found",
        )
    return ws


@router.post(
    "/projects/{project_id}/workspaces",
    response_model=WorkspaceRead,
    status_code=status.HTTP_201_CREATED,
    summary="Provision a workspace for project",
)
async def provision_workspace(
    project_id: uuid.UUID,
    payload: WorkspaceCreate,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> WorkspaceRead:
    project = await _get_project_with_ownership(project_id, current_user.id, db)

    ws_name = payload.name or f"{project.name}-workspace"
    workspace = Workspace(
        user_id=current_user.id,
        project_id=project.id,
        name=ws_name,
        host_type=payload.host_type,
        image_name=payload.image_name,
        status=WorkspaceStatus.PENDING.value,
    )
    db.add(workspace)
    await db.commit()
    await db.refresh(workspace)

    # Provision workspace files and execution container
    provider = get_workspace_provider(payload.provider_type)
    try:
        workspace.status = WorkspaceStatus.CREATING.value
        await db.commit()
        await provider.provision(workspace, project)
        await db.commit()
        await db.refresh(workspace)
    except Exception as e:
        workspace.status = WorkspaceStatus.FAILED.value
        workspace.error_message = str(e)
        await db.commit()
        await db.refresh(workspace)
        logger.error(f"Failed to provision workspace {workspace.id}: {e}")

    logger.info(f"Provisioned workspace: {workspace.id} for project {project.id}")
    return WorkspaceRead.model_validate(workspace)


@router.get(
    "/projects/{project_id}/workspaces",
    response_model=WorkspaceListResponse,
    summary="List workspaces for project",
)
async def list_project_workspaces(
    project_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> WorkspaceListResponse:
    await _get_project_with_ownership(project_id, current_user.id, db)

    stmt = select(Workspace).where(Workspace.project_id == project_id).order_by(Workspace.created_at.desc())
    res = await db.execute(stmt)
    workspaces = res.scalars().all()

    items = [WorkspaceRead.model_validate(w) for w in workspaces]
    return WorkspaceListResponse(items=items, total=len(items))


@router.get(
    "/projects/{project_id}/workspaces/{workspace_id}",
    response_model=WorkspaceRead,
    summary="Get workspace details",
)
async def get_project_workspace(
    project_id: uuid.UUID,
    workspace_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> WorkspaceRead:
    ws = await _get_workspace_with_ownership(workspace_id, current_user.id, project_id, db)
    return WorkspaceRead.model_validate(ws)


@router.get(
    "/workspaces/{workspace_id}",
    response_model=WorkspaceRead,
    summary="Direct route to get workspace",
)
async def get_workspace_direct(
    workspace_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> WorkspaceRead:
    ws = await _get_workspace_with_ownership(workspace_id, current_user.id, None, db)
    return WorkspaceRead.model_validate(ws)


@router.post(
    "/projects/{project_id}/workspaces/{workspace_id}/start",
    response_model=WorkspaceRead,
    summary="Start stopped workspace",
)
async def start_workspace(
    project_id: uuid.UUID,
    workspace_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> WorkspaceRead:
    ws = await _get_workspace_with_ownership(workspace_id, current_user.id, project_id, db)
    current_status = WorkspaceStatus(ws.status)

    if not can_transition_workspace(current_status, WorkspaceStatus.RUNNING):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Cannot start workspace in status '{current_status.value}'",
        )

    provider = get_workspace_provider()
    await provider.start(ws)
    await db.commit()
    await db.refresh(ws)
    return WorkspaceRead.model_validate(ws)


@router.post(
    "/projects/{project_id}/workspaces/{workspace_id}/stop",
    response_model=WorkspaceRead,
    summary="Stop running workspace",
)
async def stop_workspace(
    project_id: uuid.UUID,
    workspace_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> WorkspaceRead:
    ws = await _get_workspace_with_ownership(workspace_id, current_user.id, project_id, db)
    current_status = WorkspaceStatus(ws.status)

    if not can_transition_workspace(current_status, WorkspaceStatus.STOPPED):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Cannot stop workspace in status '{current_status.value}'",
        )

    provider = get_workspace_provider()
    await provider.stop(ws)
    await db.commit()
    await db.refresh(ws)
    return WorkspaceRead.model_validate(ws)


@router.post(
    "/projects/{project_id}/workspaces/{workspace_id}/restart",
    response_model=WorkspaceRead,
    summary="Restart workspace",
)
async def restart_workspace(
    project_id: uuid.UUID,
    workspace_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> WorkspaceRead:
    ws = await _get_workspace_with_ownership(workspace_id, current_user.id, project_id, db)
    provider = get_workspace_provider()
    await provider.stop(ws)
    await provider.start(ws)
    await db.commit()
    await db.refresh(ws)
    return WorkspaceRead.model_validate(ws)


@router.delete(
    "/projects/{project_id}/workspaces/{workspace_id}",
    summary="Delete workspace",
)
async def delete_workspace(
    project_id: uuid.UUID,
    workspace_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> Dict[str, Any]:
    ws = await _get_workspace_with_ownership(workspace_id, current_user.id, project_id, db)
    provider = get_workspace_provider()
    await provider.destroy(ws)
    await db.delete(ws)
    await db.commit()

    return {"status": "deleted", "id": str(workspace_id)}


@router.get(
    "/projects/{project_id}/workspaces/{workspace_id}/logs",
    summary="Get workspace logs",
)
async def get_workspace_logs(
    project_id: uuid.UUID,
    workspace_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> Dict[str, str]:
    ws = await _get_workspace_with_ownership(workspace_id, current_user.id, project_id, db)
    provider = get_workspace_provider()
    logs = await provider.get_logs(ws)
    return {"logs": logs}


@router.post(
    "/projects/{project_id}/workspaces/{workspace_id}/commands/run",
    response_model=WorkspaceCommandResponse,
    summary="Execute controlled command in workspace",
)
async def run_workspace_command(
    project_id: uuid.UUID,
    workspace_id: uuid.UUID,
    payload: WorkspaceCommandRequest,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> WorkspaceCommandResponse:
    ws = await _get_workspace_with_ownership(workspace_id, current_user.id, project_id, db)

    if ws.status != WorkspaceStatus.RUNNING.value:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Cannot run commands: workspace is in '{ws.status}' state (must be RUNNING).",
        )

    provider = get_workspace_provider()
    try:
        res = await provider.execute_command(
            ws,
            command=payload.command,
            working_dir=payload.working_dir,
            timeout_seconds=payload.timeout_seconds,
        )
        return res
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))


@router.get(
    "/projects/{project_id}/workspaces/{workspace_id}/files",
    response_model=WorkspaceFileListResponse,
    summary="List workspace directory",
)
async def list_workspace_files(
    project_id: uuid.UUID,
    workspace_id: uuid.UUID,
    path: str = Query("", description="Relative path within workspace root"),
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> WorkspaceFileListResponse:
    ws = await _get_workspace_with_ownership(workspace_id, current_user.id, project_id, db)
    provider = get_workspace_provider()
    try:
        items = await provider.list_files(ws, relative_path=path)
        return WorkspaceFileListResponse(items=items, current_path=path)
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))


@router.get(
    "/projects/{project_id}/workspaces/{workspace_id}/files/read",
    response_model=WorkspaceFileReadResponse,
    summary="Read workspace file content",
)
async def read_workspace_file(
    project_id: uuid.UUID,
    workspace_id: uuid.UUID,
    path: str = Query(..., description="Relative file path"),
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> WorkspaceFileReadResponse:
    ws = await _get_workspace_with_ownership(workspace_id, current_user.id, project_id, db)
    provider = get_workspace_provider()
    try:
        content = await provider.read_file(ws, relative_path=path)
        return WorkspaceFileReadResponse(
            path=path,
            content=content,
            size_bytes=len(content.encode("utf-8")),
            truncated=False,
        )
    except FileNotFoundError:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"File '{path}' not found")
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))


@router.post(
    "/projects/{project_id}/workspaces/{workspace_id}/files/write",
    summary="Write workspace file content",
)
async def write_workspace_file(
    project_id: uuid.UUID,
    workspace_id: uuid.UUID,
    payload: WorkspaceFileWriteRequest,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> Dict[str, str]:
    ws = await _get_workspace_with_ownership(workspace_id, current_user.id, project_id, db)
    provider = get_workspace_provider()
    try:
        await provider.write_file(ws, relative_path=payload.path, content=payload.content)
        return {"status": "written", "path": payload.path}
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))


@router.get(
    "/projects/{project_id}/workspaces/{workspace_id}/git/status",
    response_model=WorkspaceGitStatusResponse,
    summary="Get workspace Git status",
)
async def get_workspace_git_status(
    project_id: uuid.UUID,
    workspace_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> WorkspaceGitStatusResponse:
    ws = await _get_workspace_with_ownership(workspace_id, current_user.id, project_id, db)
    provider = get_workspace_provider()
    return await provider.get_git_status(ws)


@router.get(
    "/projects/{project_id}/workspaces/{workspace_id}/git/diff",
    response_model=WorkspaceGitDiffResponse,
    summary="Get workspace Git diff",
)
async def get_workspace_git_diff(
    project_id: uuid.UUID,
    workspace_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> WorkspaceGitDiffResponse:
    ws = await _get_workspace_with_ownership(workspace_id, current_user.id, project_id, db)
    provider = get_workspace_provider()
    return await provider.get_git_diff(ws)
