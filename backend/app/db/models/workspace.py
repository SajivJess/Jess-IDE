import uuid
from datetime import datetime
from typing import TYPE_CHECKING, Any, Dict, List, Optional
from sqlalchemy import DateTime, ForeignKey, JSON, String, Text
from sqlalchemy.orm import Mapped, mapped_column, relationship
from sqlalchemy.types import Uuid

from app.db.base import Base, TimestampMixin, UUIDMixin

if TYPE_CHECKING:
    from app.db.models.user import User
    from app.db.models.task import Task
    from app.db.models.project import Project


class Workspace(Base, UUIDMixin, TimestampMixin):
    """Remote or local execution environment where agentic coding tasks run."""

    __tablename__ = "workspaces"

    user_id: Mapped[uuid.UUID] = mapped_column(
        Uuid(as_uuid=True),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    project_id: Mapped[Optional[uuid.UUID]] = mapped_column(
        Uuid(as_uuid=True),
        ForeignKey("projects.id", ondelete="CASCADE"),
        nullable=True,
        index=True,
    )
    name: Mapped[str] = mapped_column(
        String(100),
        nullable=False,
    )
    host_type: Mapped[str] = mapped_column(
        String(50),
        default="docker",
        nullable=False,
    )
    status: Mapped[str] = mapped_column(
        String(50),
        default="PENDING",
        nullable=False,
    )
    container_id: Mapped[Optional[str]] = mapped_column(
        String(100),
        nullable=True,
    )
    image_name: Mapped[Optional[str]] = mapped_column(
        String(200),
        nullable=True,
    )
    root_path: Mapped[Optional[str]] = mapped_column(
        String(512),
        nullable=True,
    )
    error_message: Mapped[Optional[str]] = mapped_column(
        Text,
        nullable=True,
    )
    connection_info: Mapped[Optional[Dict[str, Any]]] = mapped_column(
        JSON,
        nullable=True,
    )
    last_heartbeat: Mapped[Optional[datetime]] = mapped_column(
        DateTime(timezone=True),
        nullable=True,
    )

    # Relationships
    user: Mapped["User"] = relationship(
        "User",
        back_populates="workspaces",
    )
    project: Mapped[Optional["Project"]] = relationship(
        "Project",
        back_populates="workspaces",
    )
    tasks: Mapped[List["Task"]] = relationship(
        "Task",
        back_populates="workspace",
    )

    def __repr__(self) -> str:
        return f"<Workspace {self.name} host={self.host_type} status={self.status} (id={self.id})>"
