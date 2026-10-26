import uuid
from typing import TYPE_CHECKING, List, Optional
from sqlalchemy import ForeignKey, String, Text
from sqlalchemy.orm import Mapped, mapped_column, relationship
from sqlalchemy.types import Uuid

from app.db.base import Base, TimestampMixin, UUIDMixin

if TYPE_CHECKING:
    from app.db.models.conversation import Conversation
    from app.db.models.project import Project
    from app.db.models.task_event import TaskEvent
    from app.db.models.workspace import Workspace


class Task(Base, UUIDMixin, TimestampMixin):
    """An agentic development task executed within a project workspace."""

    __tablename__ = "tasks"

    project_id: Mapped[uuid.UUID] = mapped_column(
        Uuid(as_uuid=True),
        ForeignKey("projects.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    conversation_id: Mapped[Optional[uuid.UUID]] = mapped_column(
        Uuid(as_uuid=True),
        ForeignKey("conversations.id", ondelete="SET NULL"),
        nullable=True,
        index=True,
    )
    workspace_id: Mapped[Optional[uuid.UUID]] = mapped_column(
        Uuid(as_uuid=True),
        ForeignKey("workspaces.id", ondelete="SET NULL"),
        nullable=True,
        index=True,
    )
    title: Mapped[str] = mapped_column(
        String(255),
        default="Untitled Task",
        nullable=False,
    )
    prompt: Mapped[str] = mapped_column(
        Text,
        nullable=False,
    )
    status: Mapped[str] = mapped_column(
        String(50),
        default="QUEUED",
        nullable=False,
    )
    active_branch: Mapped[Optional[str]] = mapped_column(
        String(100),
        nullable=True,
    )
    commit_sha: Mapped[Optional[str]] = mapped_column(
        String(40),
        nullable=True,
    )
    execution_log: Mapped[Optional[str]] = mapped_column(
        Text,
        nullable=True,
    )

    # Relationships
    project: Mapped["Project"] = relationship(
        "Project",
        back_populates="tasks",
    )
    conversation: Mapped[Optional["Conversation"]] = relationship(
        "Conversation",
        back_populates="tasks",
    )
    workspace: Mapped[Optional["Workspace"]] = relationship(
        "Workspace",
        back_populates="tasks",
    )
    events: Mapped[List["TaskEvent"]] = relationship(
        "TaskEvent",
        back_populates="task",
        cascade="all, delete-orphan",
        order_by="TaskEvent.sequence_num",
    )

    def __repr__(self) -> str:
        return f"<Task id={self.id} status={self.status} project={self.project_id}>"
