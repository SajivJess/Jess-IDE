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
from app.schemas.contract import (
    TaskContract,
    TaskContractApprovalRequest,
    TaskContractApprovalResponse,
    VerificationEvidence,
)
from app.services.agent_adapter import simulated_agent
from app.services.contract_service import contract_service
from app.services.task_events import append_task_event, get_task_events_after

router = APIRouter()


def _format_task_read(task: Task, events_count: Optional[int] = None) -> TaskRead:
    count = events_count if events_count is not None else (len(task.events) if task.events else 0)
    return TaskRead(
        id=task.id,
        project_id=task.project_id,
        workspace_id=task.workspace_id,
        title=task.title,
        prompt=task.prompt,
        status=TaskStatus(task.status),
        active_branch=task.active_branch,
        commit_sha=task.commit_sha,
        contract=task.contract_data,
        verification=task.verification_data,
        require_contract=getattr(task, "require_contract", False),
        created_at=task.created_at,
        updated_at=task.updated_at,
        events_count=count,
    )


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
        require_contract=payload.require_contract,
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

    return _format_task_read(task, events_count=1)


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

    items = [_format_task_read(t) for t in tasks]

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
    return _format_task_read(task)


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
    return _format_task_read(task)


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

    # Gate 2 Enforcement: Do not permit committing unverified, failing, or scope-breached tasks
    # when contract-first enforcement is enabled for the task
    requires_gate2 = getattr(task, "require_contract", False) or (
        task.contract_data is not None and task.contract_data.get("is_approved_by_user", False)
    )
    if is_approved and requires_gate2:
        if not task.verification_data:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Gate 2 Commit Blocked: Task requires contract verification, but no verification evidence was recorded.",
            )
        v_data = task.verification_data
        overall_verdict = v_data.get("overall_verdict")
        all_criteria_met = v_data.get("all_criteria_met", False)
        scope_status = v_data.get("scope_status")
        if overall_verdict != "PROVEN" or not all_criteria_met or scope_status == "VIOLATED":
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=(
                    f"Gate 2 Commit Blocked: Verification verdict is '{overall_verdict}'. "
                    "Only verified tasks with all criteria met and clean scope can be committed to repository."
                ),
            )

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


# ==============================================================================
# Gate 1 Contract Endpoints (Proof, Not Vibes Foundation)
# ==============================================================================

@router.get(
    "/projects/{project_id}/tasks/{task_id}/contract",
    response_model=TaskContract,
    summary="Get task contract",
)
async def get_task_contract(
    project_id: uuid.UUID,
    task_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> TaskContract:
    """Retrieve the proposed or approved task contract."""
    task = await _get_task_with_ownership(task_id, current_user.id, project_id, db)
    if not task.contract_data:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="No contract has been proposed for this task yet.",
        )
    return TaskContract.model_validate(task.contract_data)


@router.post(
    "/projects/{project_id}/tasks/{task_id}/contract/approve",
    response_model=TaskContractApprovalResponse,
    summary="Submit Gate 1 contract approval decision",
)
async def submit_contract_approval(
    project_id: uuid.UUID,
    task_id: uuid.UUID,
    payload: TaskContractApprovalRequest,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> TaskContractApprovalResponse:
    """Explicitly approve or reject the proposed contract before any code modification begins."""
    task = await _get_task_with_ownership(task_id, current_user.id, project_id, db)

    if not task.contract_data:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="No contract has been proposed for this task yet.",
        )

    current_status = TaskStatus(task.status)
    if current_status in TERMINAL_STATUSES:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=f"Task is in terminal state {current_status.value} and contract cannot be modified.",
        )

    if current_status not in (TaskStatus.CONTRACT_PROPOSED, TaskStatus.QUEUED):
        # If already approved, return idempotent success
        if current_status in (TaskStatus.CONTRACT_APPROVED, TaskStatus.RUNNING, TaskStatus.APPROVAL_REQUIRED):
            c = TaskContract.model_validate(task.contract_data)
            if c.is_approved_by_user and payload.action.lower() == "approve":
                return TaskContractApprovalResponse(
                    task_id=task.id,
                    action=payload.action,
                    approved=True,
                    contract_version=c.contract_version,
                    approved_at=c.approved_at,
                    message="Contract already approved.",
                )
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Task is in {task.status} status and is not waiting for contract approval.",
        )

    try:
        updated_contract = contract_service.record_contract_approval(
            task=task,
            user_id=current_user.id,
            action=payload.action,
            contract_hash=payload.contract_hash,
            reason=payload.reason,
        )
    except ValueError as e:
        err_msg = str(e)
        if err_msg == "STALE_CONTRACT":
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="Stale approval rejected: The contract terms have changed since you reviewed it. Please review latest terms.",
            )
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Invalid approval request: {e}",
        )

    is_approved = payload.action.lower() == "approve"
    if is_approved:
        task.status = TaskStatus.CONTRACT_APPROVED.value
        await append_task_event(
            db,
            task.id,
            "contract.approved",
            {"status": TaskStatus.CONTRACT_APPROVED.value, "version": updated_contract.contract_version},
        )
    else:
        task.status = TaskStatus.CANCELLED.value
        await append_task_event(
            db,
            task.id,
            "contract.rejected",
            {"reason": payload.reason or "User rejected proposed contract.", "status": TaskStatus.CANCELLED.value},
        )

    db.add(task)
    await db.commit()
    await db.refresh(task)

    # Signal agent adapter
    await simulated_agent.handle_contract_approval(
        task.id, approved=is_approved, reason=payload.reason
    )

    logger.info(
        f"Contract approval '{payload.action}' recorded for task {task.id} by {current_user.email}"
    )

    return TaskContractApprovalResponse(
        task_id=task.id,
        action=payload.action,
        approved=is_approved,
        contract_version=updated_contract.contract_version,
        approved_at=updated_contract.approved_at,
        message=(
            "Contract approved. Agent is authorized to implement within specified scope."
            if is_approved
            else "Contract rejected. Task cancelled."
        ),
    )


@router.post(
    "/projects/{project_id}/tasks/{task_id}/contract/generate",
    response_model=TaskContract,
    summary="Generate or regenerate a proposed contract for a task",
)
async def generate_task_contract(
    project_id: uuid.UUID,
    task_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> TaskContract:
    """Generate a structured, testable task contract before code changes begin."""
    task = await _get_task_with_ownership(task_id, current_user.id, project_id, db)

    current_status = TaskStatus(task.status)
    if current_status in TERMINAL_STATUSES:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=f"Task is in terminal state {current_status.value}.",
        )

    workspace_files = []
    if task.workspace_id:
        ws = await db.get(Workspace, task.workspace_id)
        if ws:
            from app.services.workspace import get_workspace_provider
            try:
                items = await get_workspace_provider().list_files(ws, "")
                workspace_files = [i.path for i in items if not i.is_dir]
            except Exception:
                pass

    contract = await contract_service.generate_contract_proposal(task, workspace_files)
    task.contract_data = contract.model_dump(mode="json")
    if current_status == TaskStatus.QUEUED:
        task.status = TaskStatus.CONTRACT_PROPOSED.value

    db.add(task)
    await db.commit()
    await db.refresh(task)

    await append_task_event(
        db,
        task.id,
        "contract.proposed",
        task.contract_data,
    )

    return contract


@router.get(
    "/tasks/{task_id}/contract",
    response_model=TaskContract,
    summary="Direct route to get task contract",
)
async def get_task_contract_direct(
    task_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> TaskContract:
    """Direct route to retrieve task contract."""
    task = await _get_task_with_ownership(task_id, current_user.id, None, db)
    if not task.contract_data:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="No contract has been proposed for this task yet.",
        )
    return TaskContract.model_validate(task.contract_data)


@router.post(
    "/tasks/{task_id}/contract/approve",
    response_model=TaskContractApprovalResponse,
    summary="Direct route to approve or reject task contract",
)
async def submit_contract_approval_direct(
    task_id: uuid.UUID,
    payload: TaskContractApprovalRequest,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> TaskContractApprovalResponse:
    """Direct route to submit Gate 1 approval decision."""
    task = await _get_task_with_ownership(task_id, current_user.id, None, db)
    return await submit_contract_approval(
        project_id=task.project_id,
        task_id=task.id,
        payload=payload,
        current_user=current_user,
        db=db,
    )


@router.get(
    "/projects/{project_id}/tasks/{task_id}/verification",
    response_model=VerificationEvidence,
    summary="Get task verification evidence",
)
async def get_task_verification(
    project_id: uuid.UUID,
    task_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> VerificationEvidence:
    """Retrieve actual recorded verification evidence for a task."""
    task = await _get_task_with_ownership(task_id, current_user.id, project_id, db)
    if not task.verification_data:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Verification has not been executed for this task yet.",
        )
    return VerificationEvidence.model_validate(task.verification_data)


@router.get(
    "/tasks/{task_id}/verification",
    response_model=VerificationEvidence,
    summary="Direct route to get task verification evidence",
)
async def get_task_verification_direct(
    task_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> VerificationEvidence:
    """Direct route to retrieve task verification evidence."""
    task = await _get_task_with_ownership(task_id, current_user.id, None, db)
    if not task.verification_data:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Verification has not been executed for this task yet.",
        )
    return VerificationEvidence.model_validate(task.verification_data)

