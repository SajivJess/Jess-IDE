import uuid
from datetime import datetime
from enum import Enum
from typing import Any, Dict, List, Optional, Set
from pydantic import BaseModel, ConfigDict, Field


class WorkspaceStatus(str, Enum):
    PENDING = "PENDING"
    CREATING = "CREATING"
    RUNNING = "RUNNING"
    STOPPING = "STOPPING"
    STOPPED = "STOPPED"
    FAILED = "FAILED"


WORKSPACE_VALID_TRANSITIONS: Dict[WorkspaceStatus, Set[WorkspaceStatus]] = {
    WorkspaceStatus.PENDING: {WorkspaceStatus.CREATING, WorkspaceStatus.FAILED},
    WorkspaceStatus.CREATING: {WorkspaceStatus.RUNNING, WorkspaceStatus.FAILED},
    WorkspaceStatus.RUNNING: {WorkspaceStatus.STOPPING, WorkspaceStatus.STOPPED, WorkspaceStatus.FAILED},
    WorkspaceStatus.STOPPING: {WorkspaceStatus.STOPPED, WorkspaceStatus.FAILED},
    WorkspaceStatus.STOPPED: {WorkspaceStatus.CREATING, WorkspaceStatus.RUNNING, WorkspaceStatus.FAILED},
    WorkspaceStatus.FAILED: {WorkspaceStatus.CREATING, WorkspaceStatus.PENDING},
}


def can_transition_workspace(current: WorkspaceStatus, target: WorkspaceStatus) -> bool:
    """Validate whether the workspace lifecycle transition is valid."""
    if current == target:
        return True
    return target in WORKSPACE_VALID_TRANSITIONS.get(current, set())


class WorkspaceCreate(BaseModel):
    """Payload to create or provision a project workspace."""

    name: Optional[str] = Field(None, max_length=100, description="Workspace display name")
    image_name: Optional[str] = Field("python:3.10-slim", max_length=200, description="Docker image tag")
    host_type: str = Field("docker", description="Host type: docker or local")
    provider_type: Optional[str] = Field(None, description="Force provider: docker or local_sandbox")


class WorkspaceRead(BaseModel):
    """Public representation of a workspace."""

    id: uuid.UUID
    user_id: uuid.UUID
    project_id: Optional[uuid.UUID] = None
    name: str
    host_type: str
    status: WorkspaceStatus
    container_id: Optional[str] = None
    image_name: Optional[str] = None
    root_path: Optional[str] = None
    error_message: Optional[str] = None
    connection_info: Optional[Dict[str, Any]] = None
    last_heartbeat: Optional[datetime] = None
    created_at: datetime
    updated_at: datetime

    model_config = ConfigDict(from_attributes=True)


class WorkspaceListResponse(BaseModel):
    """List of workspaces."""

    items: List[WorkspaceRead]
    total: int


class WorkspaceCommandRequest(BaseModel):
    """Structured request to execute a controlled command inside a workspace."""

    command: List[str] = Field(
        ...,
        min_length=1,
        description="Structured executable and argument list (never a shell string concatenation)",
    )
    working_dir: Optional[str] = Field(
        None,
        description="Relative path inside workspace root where command should run",
    )
    timeout_seconds: int = Field(
        30,
        ge=1,
        le=120,
        description="Command timeout limit in seconds",
    )


class WorkspaceCommandResponse(BaseModel):
    """Result of controlled workspace command execution."""

    exit_code: int
    stdout: str
    stderr: str
    duration_ms: int
    timed_out: bool


class WorkspaceFileItem(BaseModel):
    """Metadata for a file or directory inside the workspace."""

    name: str
    path: str
    is_dir: bool
    size_bytes: int
    modified_at: Optional[datetime] = None


class WorkspaceFileListResponse(BaseModel):
    """Directory listing response."""

    items: List[WorkspaceFileItem]
    current_path: str


class WorkspaceFileReadResponse(BaseModel):
    """File content read response."""

    path: str
    content: str
    size_bytes: int
    truncated: bool = False


class WorkspaceFileWriteRequest(BaseModel):
    """File content write payload."""

    path: str = Field(..., min_length=1, description="Relative file path inside workspace root")
    content: str = Field(..., description="Text content to write")


class WorkspaceGitStatusResponse(BaseModel):
    """Git working tree status inside workspace."""

    branch: str
    is_clean: bool
    modified_files: List[str]
    untracked_files: List[str]
    staged_files: List[str]


class WorkspaceGitDiffResponse(BaseModel):
    """Git diff of current changes."""

    diff: str
    files_changed: int
