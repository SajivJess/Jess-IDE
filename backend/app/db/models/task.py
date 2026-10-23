import uuid
from typing import TYPE_CHECKING, Optional
from sqlalchemy import ForeignKey, String, Text
from sqlalchemy.orm import Mapped, mapped_column, relationship
from sqlalchemy.types import Uuid

from app.db.base import Base, TimestampMixin, UUIDMixin

if TYPE_CHECKING:
    from app.db.models.project import Project
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
    workspace_id: Mapped[Optional[uuid.UUID]] = mapped_column(
        Uuid(as_uuid=True),
        ForeignKey("workspaces.id", ondelete="SET NULL"),
        nullable=True,
        index=True,
    )
    prompt: Mapped[str] = mapped_column(
        Text,
        nullable=False,
    )
    status: Mapped[str] = mapped_column(
        String(50),
        default="pending",
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
    workspace: Mapped[Optional["Workspace"]] = relationship(
        "Workspace",
        back_populates="tasks",
    )

    def __repr__(self) -> str:
        return f"<Task id={self.id} status={self.status} project={self.project_id}>"
