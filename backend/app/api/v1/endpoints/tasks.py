import uuid
from typing import Optional
from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.api.deps import get_current_user
from app.core.logging import logger
from app.db.models.project import Project
from app.db.models.task import Task
from app.db.models.user import User
from app.db.models.workspace import Workspace
from app.db.session import get_db
from app.schemas.task import (
    TERMINAL_STATUSES,
    TaskApprovalRequest,
    TaskCancelResponse,
    TaskCreate,
    TaskEventListResponse,
    TaskEventRead,
    TaskListResponse,
    TaskRead,
    TaskStatus,
)
from app.services.agent_adapter import simulated_agent
from app.services.task_events import append_task_event, get_task_events_after

router = APIRouter()


async def _get_project_with_ownership(
    project_id: uuid.UUID,
    user_id: uuid.UUID,
    db: AsyncSession,
) -> Project:
    """Fetch project ensuring strictly that the authenticated user is the owner."""
    stmt = select(Project).where(Project.id == project_id, Project.user_id == user_id)
    res = await db.execute(stmt)
    project = res.scalar_one_or_none()
    if not project:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Project not found",
        )
    return project


async def _get_task_with_ownership(
    task_id: uuid.UUID,
    user_id: uuid.UUID,
    project_id: Optional[uuid.UUID],
    db: AsyncSession,
) -> Task:
    """Fetch task ensuring ownership through the project and user."""
    stmt = (
        select(Task)
        .join(Project, Task.project_id == Project.id)
        .options(selectinload(Task.events))
        .where(Task.id == task_id, Project.user_id == user_id)
    )
    if project_id:
        stmt = stmt.where(Task.project_id == project_id)

    res = await db.execute(stmt)
    task = res.scalar_one_or_none()
    if not task:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Task not found",
        )
    return task


@router.post(
    "/projects/{project_id}/tasks",
    response_model=TaskRead,
    status_code=status.HTTP_201_CREATED,
    summary="Create and queue a task",
)
async def create_task(
    project_id: uuid.UUID,
    payload: TaskCreate,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> TaskRead:
    """Create a new task in QUEUED status for the specified project and launch execution."""
    await _get_project_with_ownership(project_id, current_user.id, db)

    ws_stmt = select(Workspace).where(Workspace.project_id == project_id)
    ws_res = await db.execute(ws_stmt)
    ws = ws_res.scalars().first()

    task = Task(
        project_id=project_id,
        workspace_id=ws.id if ws else None,
        title=payload.title.strip(),
        prompt=payload.prompt.strip(),
        status=TaskStatus.QUEUED.value,
    )
    db.add(task)
    await db.commit()
    await db.refresh(task)

    # Persist initial task.queued event
    await append_task_event(
        db,
        task.id,
        "task.queued",
        {"title": task.title, "prompt": task.prompt, "status": TaskStatus.QUEUED.value},
    )

    # Trigger agent adapter execution in background
    await simulated_agent.run_task(task.id)

    logger.info(f"Created and queued task: {task.id} ('{task.title}') in project {project_id}")

    return TaskRead(
        id=task.id,
        project_id=task.project_id,
        workspace_id=task.workspace_id,
        title=task.title,
        prompt=task.prompt,
        status=TaskStatus(task.status),
        active_branch=task.active_branch,
        commit_sha=task.commit_sha,
        created_at=task.created_at,
        updated_at=task.updated_at,
        events_count=1,
    )


@router.get(
    "/projects/{project_id}/tasks",
    response_model=TaskListResponse,
    summary="List tasks for project",
)
async def list_tasks(
    project_id: uuid.UUID,
    skip: int = Query(0, ge=0),
    limit: int = Query(20, ge=1, le=100),
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> TaskListResponse:
    """List tasks belonging to authenticated user's project."""
    await _get_project_with_ownership(project_id, current_user.id, db)

    count_stmt = select(func.count(Task.id)).where(Task.project_id == project_id)
    count_res = await db.execute(count_stmt)
    total = count_res.scalar() or 0

    stmt = (
        select(Task)
        .options(selectinload(Task.events))
        .where(Task.project_id == project_id)
        .order_by(Task.created_at.desc())
        .offset(skip)
        .limit(limit)
    )
    res = await db.execute(stmt)
    tasks = res.scalars().all()

    items = [
        TaskRead(
            id=t.id,
            project_id=t.project_id,
            workspace_id=t.workspace_id,
            title=t.title,
            prompt=t.prompt,
            status=TaskStatus(t.status),
            active_branch=t.active_branch,
            commit_sha=t.commit_sha,
            created_at=t.created_at,
            updated_at=t.updated_at,
            events_count=len(t.events) if t.events else 0,
        )
        for t in tasks
    ]

    return TaskListResponse(
        items=items,
        total=total,
        skip=skip,
        limit=limit,
    )


@router.get(
    "/projects/{project_id}/tasks/{task_id}",
    response_model=TaskRead,
    summary="Get task by ID within project",
)
async def get_project_task(
    project_id: uuid.UUID,
    task_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> TaskRead:
    """Retrieve details and status for a specific task."""
    task = await _get_task_with_ownership(task_id, current_user.id, project_id, db)
    return TaskRead(
        id=task.id,
        project_id=task.project_id,
        workspace_id=task.workspace_id,
        title=task.title,
        prompt=task.prompt,
        status=TaskStatus(task.status),
        active_branch=task.active_branch,
        commit_sha=task.commit_sha,
        created_at=task.created_at,
        updated_at=task.updated_at,
        events_count=len(task.events) if task.events else 0,
    )


@router.get(
    "/tasks/{task_id}",
    response_model=TaskRead,
    summary="Get task by ID",
)
async def get_task_direct(
    task_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> TaskRead:
    """Direct route to fetch task by ID after validating user ownership."""
    task = await _get_task_with_ownership(task_id, current_user.id, None, db)
    return TaskRead(
        id=task.id,
        project_id=task.project_id,
        workspace_id=task.workspace_id,
        title=task.title,
        prompt=task.prompt,
        status=TaskStatus(task.status),
        active_branch=task.active_branch,
        commit_sha=task.commit_sha,
        created_at=task.created_at,
        updated_at=task.updated_at,
        events_count=len(task.events) if task.events else 0,
    )


@router.post(
    "/projects/{project_id}/tasks/{task_id}/cancel",
    response_model=TaskCancelResponse,
    summary="Cancel a task",
)
async def cancel_task(
    project_id: uuid.UUID,
    task_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> TaskCancelResponse:
    """Request immediate cancellation of a running or queued task."""
    task = await _get_task_with_ownership(task_id, current_user.id, project_id, db)

    current_status = TaskStatus(task.status)
    if current_status in TERMINAL_STATUSES:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Cannot cancel task in terminal state: {current_status.value}",
        )

    # Signal agent adapter
    await simulated_agent.cancel_task(task.id)

    task.status = TaskStatus.CANCELLED.value
    await db.commit()
    await db.refresh(task)

    await append_task_event(
        db,
        task.id,
        "task.cancelled",
        {"reason": "Cancelled by user via API."},
    )

    logger.info(f"Task {task.id} cancelled by user {current_user.email}")
    return TaskCancelResponse(
        id=task.id,
        status=TaskStatus.CANCELLED,
        message="Task was successfully cancelled.",
    )


@router.post(
    "/projects/{project_id}/tasks/{task_id}/approve",
    summary="Approve or reject a task awaiting user approval",
)
async def approve_task(
    project_id: uuid.UUID,
    task_id: uuid.UUID,
    payload: TaskApprovalRequest,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> dict:
    """Respond to an APPROVAL_REQUIRED gate."""
    task = await _get_task_with_ownership(task_id, current_user.id, project_id, db)

    current_status = TaskStatus(task.status)
    if current_status == TaskStatus.COMPLETED and payload.action.lower() == "approve":
        return {
            "status": "ok",
            "task_id": str(task.id),
            "action": payload.action,
            "approved": True,
            "idempotent": True,
            "message": "Task already approved and completed.",
        }
    if current_status == TaskStatus.CANCELLED and payload.action.lower() == "reject":
        return {
            "status": "ok",
            "task_id": str(task.id),
            "action": payload.action,
            "approved": False,
            "idempotent": True,
            "message": "Task already rejected.",
        }
    if current_status in TERMINAL_STATUSES:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=f"Task is in terminal state {current_status.value} and cannot be modified.",
        )
    if current_status != TaskStatus.APPROVAL_REQUIRED:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Task is in {task.status} status and is not waiting for approval.",
        )

    is_approved = payload.action.lower() == "approve"
    await simulated_agent.handle_approval(
        task.id, approved=is_approved, reason=payload.reason
    )

    logger.info(
        f"Submitted approval decision '{payload.action}' for task {task.id} by {current_user.email}"
    )
    return {
        "status": "ok",
        "task_id": str(task.id),
        "action": payload.action,
        "approved": is_approved,
    }


@router.get(
    "/projects/{project_id}/tasks/{task_id}/events",
    response_model=TaskEventListResponse,
    summary="Get task event history with replay",
)
async def get_task_events(
    project_id: uuid.UUID,
    task_id: uuid.UUID,
    after: int = Query(0, ge=0, description="Retrieve events with sequence_num > after"),
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> TaskEventListResponse:
    """HTTP endpoint to replay events for a task."""
    task = await _get_task_with_ownership(task_id, current_user.id, project_id, db)
    events = await get_task_events_after(db, task.id, after_seq=after)

    items = [
        TaskEventRead(
            id=e.id,
            task_id=e.task_id,
            sequence_num=e.sequence_num,
            event_type=e.event_type,
            payload=e.payload,
            created_at=e.created_at,
        )
        for e in events
    ]

    return TaskEventListResponse(
        items=items,
        task_id=task.id,
        total=len(items),
        after=after,
    )
