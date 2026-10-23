import uuid
from typing import Any, Dict, List, Optional
from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.api.deps import get_current_user
from app.core.logging import logger
from app.db.models.project import Project
from app.db.models.user import User
from app.db.session import get_db
from app.schemas.project import (
    ProjectCreate,
    ProjectListResponse,
    ProjectRead,
    ProjectUpdate,
)

router = APIRouter()


@router.get(
    "",
    response_model=ProjectListResponse,
    summary="List authenticated user's projects",
)
async def list_projects(
    skip: int = Query(0, ge=0, description="Offset for pagination"),
    limit: int = Query(20, ge=1, le=100, description="Page size limit"),
    source_type: Optional[str] = Query(None, description="Filter by source type"),
    search: Optional[str] = Query(None, description="Search by name or description"),
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> ProjectListResponse:
    """Retrieve only the projects owned by the authenticated user with optional filtering and pagination."""
    # Base query restricted strictly to current user's projects
    base_conditions = [Project.user_id == current_user.id]

    if source_type:
        clean_source = source_type.strip().lower()
        if clean_source != "all":
            base_conditions.append(func.lower(Project.source_type) == clean_source)

    if search:
        search_term = f"%{search.strip()}%"
        base_conditions.append(
            Project.name.ilike(search_term) | Project.description.ilike(search_term)
        )

    # Total count query
    count_stmt = select(func.count(Project.id)).where(*base_conditions)
    total_result = await db.execute(count_stmt)
    total = total_result.scalar() or 0

    # Paginated items query
    stmt = (
        select(Project)
        .options(selectinload(Project.tasks))
        .where(*base_conditions)
        .order_by(Project.updated_at.desc())
        .offset(skip)
        .limit(limit)
    )
    result = await db.execute(stmt)
    projects = result.scalars().all()

    items = []
    for p in projects:
        read_model = ProjectRead(
            id=p.id,
            user_id=p.user_id,
            name=p.name,
            description=p.description,
            source_type=p.source_type,
            repo_url=p.repo_url,
            default_branch=p.default_branch,
            workspace_path=p.workspace_path,
            created_at=p.created_at,
            updated_at=p.updated_at,
            task_count=len(p.tasks) if p.tasks else 0,
        )
        items.append(read_model)

    return ProjectListResponse(
        items=items,
        total=total,
        skip=skip,
        limit=limit,
    )


@router.post(
    "",
    response_model=ProjectRead,
    status_code=status.HTTP_201_CREATED,
    summary="Create a new project",
)
async def create_project(
    payload: ProjectCreate,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> ProjectRead:
    """Create a project owned by the authenticated user. Ownership is derived strictly from session."""
    project = Project(
        user_id=current_user.id,
        name=payload.name.strip(),
        description=payload.description.strip() if payload.description else None,
        source_type=payload.source_type,
        repo_url=payload.repo_url,
        default_branch=payload.default_branch.strip(),
        workspace_path=payload.workspace_path.strip() if payload.workspace_path else None,
    )
    db.add(project)
    await db.commit()
    await db.refresh(project)

    logger.info(f"Created project: {project.name} (id: {project.id}) for user: {current_user.email}")

    return ProjectRead(
        id=project.id,
        user_id=project.user_id,
        name=project.name,
        description=project.description,
        source_type=project.source_type,
        repo_url=project.repo_url,
        default_branch=project.default_branch,
        workspace_path=project.workspace_path,
        created_at=project.created_at,
        updated_at=project.updated_at,
        task_count=0,
    )


@router.get(
    "/{project_id}",
    response_model=ProjectRead,
    summary="Get project by ID",
)
async def get_project(
    project_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> ProjectRead:
    """Retrieve details for a specific project. Only accessible by the project owner."""
    stmt = (
        select(Project)
        .options(selectinload(Project.tasks))
        .where(Project.id == project_id, Project.user_id == current_user.id)
    )
    result = await db.execute(stmt)
    project = result.scalar_one_or_none()

    if not project:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Project not found",
        )

    return ProjectRead(
        id=project.id,
        user_id=project.user_id,
        name=project.name,
        description=project.description,
        source_type=project.source_type,
        repo_url=project.repo_url,
        default_branch=project.default_branch,
        workspace_path=project.workspace_path,
        created_at=project.created_at,
        updated_at=project.updated_at,
        task_count=len(project.tasks) if project.tasks else 0,
    )


@router.patch(
    "/{project_id}",
    response_model=ProjectRead,
    summary="Update project metadata",
)
async def update_project(
    project_id: uuid.UUID,
    payload: ProjectUpdate,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> ProjectRead:
    """Update editable project fields after validating user ownership."""
    stmt = (
        select(Project)
        .options(selectinload(Project.tasks))
        .where(Project.id == project_id, Project.user_id == current_user.id)
    )
    result = await db.execute(stmt)
    project = result.scalar_one_or_none()

    if not project:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Project not found",
        )

    # Apply partial updates
    update_data = payload.model_dump(exclude_unset=True)
    for field, value in update_data.items():
        if field == "name" and value is not None:
            setattr(project, field, value.strip())
        elif field == "description" and value is not None:
            setattr(project, field, value.strip())
        elif field == "default_branch" and value is not None:
            setattr(project, field, value.strip())
        elif field == "workspace_path" and value is not None:
            setattr(project, field, value.strip())
        else:
            setattr(project, field, value)

    await db.commit()
    await db.refresh(project)

    logger.info(f"Updated project: {project.name} (id: {project.id}) for user: {current_user.email}")

    return ProjectRead(
        id=project.id,
        user_id=project.user_id,
        name=project.name,
        description=project.description,
        source_type=project.source_type,
        repo_url=project.repo_url,
        default_branch=project.default_branch,
        workspace_path=project.workspace_path,
        created_at=project.created_at,
        updated_at=project.updated_at,
        task_count=len(project.tasks) if project.tasks else 0,
    )


@router.delete(
    "/{project_id}",
    summary="Delete a project",
)
async def delete_project(
    project_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> Dict[str, Any]:
    """Permanently delete a project and cascade-delete associated tasks."""
    stmt = select(Project).where(
        Project.id == project_id, Project.user_id == current_user.id
    )
    result = await db.execute(stmt)
    project = result.scalar_one_or_none()

    if not project:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Project not found",
        )

    project_name = project.name
    await db.delete(project)
    await db.commit()

    logger.info(f"Deleted project: {project_name} (id: {project_id}) by user: {current_user.email}")

    return {
        "status": "deleted",
        "id": project_id,
        "name": project_name,
    }
