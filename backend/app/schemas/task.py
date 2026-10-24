import uuid
from datetime import datetime
from enum import Enum
from typing import Any, Dict, List, Optional, Set
from pydantic import BaseModel, ConfigDict, Field


class TaskStatus(str, Enum):
    QUEUED = "QUEUED"
    RUNNING = "RUNNING"
    APPROVAL_REQUIRED = "APPROVAL_REQUIRED"
    COMPLETED = "COMPLETED"
    FAILED = "FAILED"
    CANCELLED = "CANCELLED"


# Valid state transitions enforced by the task engine
VALID_TRANSITIONS: Dict[TaskStatus, Set[TaskStatus]] = {
    TaskStatus.QUEUED: {TaskStatus.RUNNING, TaskStatus.CANCELLED},
    TaskStatus.RUNNING: {
        TaskStatus.APPROVAL_REQUIRED,
        TaskStatus.COMPLETED,
        TaskStatus.FAILED,
        TaskStatus.CANCELLED,
    },
    TaskStatus.APPROVAL_REQUIRED: {
        TaskStatus.RUNNING,
        TaskStatus.CANCELLED,
        TaskStatus.FAILED,
    },
    TaskStatus.COMPLETED: set(),  # terminal
    TaskStatus.FAILED: set(),     # terminal
    TaskStatus.CANCELLED: set(),  # terminal
}

TERMINAL_STATUSES: Set[TaskStatus] = {
    TaskStatus.COMPLETED,
    TaskStatus.FAILED,
    TaskStatus.CANCELLED,
}


def can_transition(current: TaskStatus, target: TaskStatus) -> bool:
    """Check whether a transition between two task statuses is permissible."""
    if current == target:
        return True
    return target in VALID_TRANSITIONS.get(current, set())


class TaskCreate(BaseModel):
    """Payload to create and queue a new task."""

    title: str = Field(..., min_length=1, max_length=255, description="Brief task title")
    prompt: str = Field(..., min_length=1, max_length=10000, description="Task prompt / instructions")


class TaskApprovalRequest(BaseModel):
    """Request to approve or reject a task waiting in APPROVAL_REQUIRED state."""

    action: str = Field(..., pattern="^(approve|reject)$", description="approve or reject")
    reason: Optional[str] = Field(None, max_length=1000, description="Optional explanation")


class TaskRead(BaseModel):
    """Public representation of a task."""

    id: uuid.UUID
    project_id: uuid.UUID
    workspace_id: Optional[uuid.UUID] = None
    title: str
    prompt: str
    status: TaskStatus
    active_branch: Optional[str] = None
    commit_sha: Optional[str] = None
    created_at: datetime
    updated_at: datetime
    events_count: int = 0

    model_config = ConfigDict(from_attributes=True)


class TaskListResponse(BaseModel):
    """Paginated list of tasks."""

    items: List[TaskRead]
    total: int
    skip: int
    limit: int


class TaskCancelResponse(BaseModel):
    """Response returned upon cancelling a task."""

    id: uuid.UUID
    status: TaskStatus
    message: str


class TaskEventRead(BaseModel):
    """Public representation of an append-only task event."""

    id: uuid.UUID
    task_id: uuid.UUID
    sequence_num: int
    event_type: str
    payload: Dict[str, Any]
    created_at: datetime

    model_config = ConfigDict(from_attributes=True)


class TaskEventListResponse(BaseModel):
    """List of task events for replay."""

    items: List[TaskEventRead]
    task_id: uuid.UUID
    total: int
    after: int
