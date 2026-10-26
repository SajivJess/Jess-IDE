"""GitHub API endpoints for Jess IDE.

Enables GitHub account status checking, repository browsing,
branch inspection, and importing GitHub repositories as Jess IDE projects.
"""

import logging
import os
import uuid
from typing import Any, Dict, List, Optional
from fastapi import APIRouter, Depends, HTTPException, Query, status
from pydantic import BaseModel, Field
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import get_current_user, get_db
from app.core.config import settings
from app.db.models.project import Project
from app.db.models.user import User
from app.schemas.project import ProjectRead
from app.services.github_service import github_service

logger = logging.getLogger("jess_github_api")

router = APIRouter()


class GitHubStatusResponse(BaseModel):
    connected: bool
    configured: bool
    login: Optional[str] = None
    name: Optional[str] = None
    avatar_url: Optional[str] = None
    html_url: Optional[str] = None
    public_repos: int = 0
    total_private_repos: int = 0
    plan: Optional[str] = None
    message: Optional[str] = None


class GitHubRepoOwner(BaseModel):
    login: Optional[str] = None
    avatar_url: Optional[str] = None


class GitHubRepoItem(BaseModel):
    id: Optional[int] = None
    name: str
    full_name: str
    private: bool = False
    html_url: Optional[str] = None
    clone_url: Optional[str] = None
    description: Optional[str] = None
    default_branch: str = "main"
    language: Optional[str] = None
    stargazers_count: int = 0
    forks_count: int = 0
    updated_at: Optional[str] = None
    owner: Optional[GitHubRepoOwner] = None


class GitHubBranchItem(BaseModel):
    name: str
    commit_sha: Optional[str] = None
    protected: bool = False


class ImportRepoRequest(BaseModel):
    branch: Optional[str] = None
    project_name: Optional[str] = None
    description: Optional[str] = None


class ImportRepoResponse(BaseModel):
    project: ProjectRead
    workspace_path: str
    message: str


@router.get(
    "/status",
    response_model=GitHubStatusResponse,
    summary="Get GitHub connection status and profile",
)
async def get_github_status(
    current_user: User = Depends(get_current_user),
) -> GitHubStatusResponse:
    """Return status of the configured GitHub integration."""
    status_data = await github_service.get_status()
    return GitHubStatusResponse(**status_data)


@router.get(
    "/repos",
    response_model=List[GitHubRepoItem],
    summary="List accessible GitHub repositories",
)
async def list_github_repositories(
    visibility: Optional[str] = Query(None, description="all, public, or private"),
    sort: str = Query("updated", description="created, updated, pushed, full_name"),
    direction: str = Query("desc", description="asc or desc"),
    page: int = Query(1, ge=1),
    per_page: int = Query(30, ge=1, le=100),
    current_user: User = Depends(get_current_user),
) -> List[GitHubRepoItem]:
    """List GitHub repositories accessible with the configured token."""
    repos = await github_service.list_repositories(
        visibility=visibility,
        sort=sort,
        direction=direction,
        per_page=per_page,
        page=page,
    )
    return [GitHubRepoItem(**r) for r in repos]


@router.get(
    "/repos/{owner}/{repo}/branches",
    response_model=List[GitHubBranchItem],
    summary="List branches for a GitHub repository",
)
async def list_repo_branches(
    owner: str,
    repo: str,
    current_user: User = Depends(get_current_user),
) -> List[GitHubBranchItem]:
    """List branches for the specified repository."""
    branches = await github_service.list_branches(owner, repo)
    return [GitHubBranchItem(**b) for b in branches]


@router.post(
    "/repos/{owner}/{repo}/import",
    response_model=ImportRepoResponse,
    status_code=status.HTTP_201_CREATED,
    summary="Import GitHub repository into a Jess IDE Project",
)
async def import_github_repository(
    owner: str,
    repo: str,
    payload: ImportRepoRequest,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> ImportRepoResponse:
    """Clone and import a GitHub repository as a new Jess IDE project."""
    repo_data = await github_service.get_repository(owner, repo)
    if not repo_data:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"GitHub repository {owner}/{repo} not found or inaccessible.",
        )

    branch = payload.branch or repo_data.get("default_branch", "main")
    project_name = payload.project_name or repo
    project_desc = payload.description or repo_data.get("description") or f"Imported from {owner}/{repo}"

    # Target workspace directory under WORKSPACE_DATA_DIR
    project_slug = f"gh_{owner}_{repo}_{uuid.uuid4().hex[:8]}"
    workspace_path = os.path.abspath(os.path.join(settings.WORKSPACE_DATA_DIR, project_slug))

    clone_result = github_service.clone_repository(
        owner=owner,
        repo=repo,
        target_dir=workspace_path,
        branch=branch,
    )

    if not clone_result.get("success"):
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=clone_result.get("message", "Failed to clone repository."),
        )

    # Create project record in database
    new_project = Project(
        user_id=current_user.id,
        name=project_name,
        description=project_desc,
        source_type="github",
        repo_url=repo_data.get("html_url"),
        default_branch=branch,
        workspace_path=workspace_path,
    )
    db.add(new_project)
    await db.commit()
    await db.refresh(new_project)

    logger.info(f"Successfully imported {owner}/{repo} into project {new_project.id} ({workspace_path})")

    return ImportRepoResponse(
        project=ProjectRead(
            id=new_project.id,
            user_id=new_project.user_id,
            name=new_project.name,
            description=new_project.description,
            source_type=new_project.source_type,
            repo_url=new_project.repo_url,
            default_branch=new_project.default_branch,
            workspace_path=new_project.workspace_path,
            created_at=new_project.created_at,
            updated_at=new_project.updated_at,
            task_count=0,
        ),
        workspace_path=workspace_path,
        message=f"Successfully imported {owner}/{repo} ({branch}) into Jess IDE workspace.",
    )
