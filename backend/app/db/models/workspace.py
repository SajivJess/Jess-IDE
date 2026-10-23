import uuid
from datetime import datetime
from typing import TYPE_CHECKING, Any, Dict, List, Optional
from sqlalchemy import DateTime, ForeignKey, JSON, String
from sqlalchemy.orm import Mapped, mapped_column, relationship
from sqlalchemy.types import Uuid

from app.db.base import Base, TimestampMixin, UUIDMixin

if TYPE_CHECKING:
    from app.db.models.user import User
    from app.db.models.task import Task


class Workspace(Base, UUIDMixin, TimestampMixin):
    """Remote or local execution environment where agentic coding tasks run."""

    __tablename__ = "workspaces"

    user_id: Mapped[uuid.UUID] = mapped_column(
        Uuid(as_uuid=True),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    name: Mapped[str] = mapped_column(
        String(100),
        nullable=False,
    )
    host_type: Mapped[str] = mapped_column(
        String(50),
        default="local",
        nullable=False,
    )
    status: Mapped[str] = mapped_column(
        String(50),
        default="active",
        nullable=False,
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
    tasks: Mapped[List["Task"]] = relationship(
        "Task",
        back_populates="workspace",
    )

    def __repr__(self) -> str:
        return f"<Workspace {self.name} host={self.host_type} status={self.status} (id={self.id})>"
