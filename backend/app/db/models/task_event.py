import uuid
from typing import TYPE_CHECKING, Any, Dict
from sqlalchemy import ForeignKey, Integer, String, UniqueConstraint
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column, relationship
from sqlalchemy.types import JSON, Uuid

from app.db.base import Base, TimestampMixin, UUIDMixin

if TYPE_CHECKING:
    from app.db.models.task import Task


class TaskEvent(Base, UUIDMixin, TimestampMixin):
    """An append-only persistent event emitted during task lifecycle and agent execution."""

    __tablename__ = "task_events"
    __table_args__ = (
        UniqueConstraint("task_id", "sequence_num", name="uq_task_events_task_id_sequence_num"),
    )

    task_id: Mapped[uuid.UUID] = mapped_column(
        Uuid(as_uuid=True),
        ForeignKey("tasks.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    sequence_num: Mapped[int] = mapped_column(
        Integer,
        nullable=False,
        index=True,
    )
    event_type: Mapped[str] = mapped_column(
        String(100),
        nullable=False,
        index=True,
    )
    payload: Mapped[Dict[str, Any]] = mapped_column(
        JSON().with_variant(JSONB, "postgresql"),
        nullable=False,
        default=dict,
    )

    # Relationships
    task: Mapped["Task"] = relationship(
        "Task",
        back_populates="events",
    )

    def __repr__(self) -> str:
        return f"<TaskEvent id={self.id} task_id={self.task_id} seq={self.sequence_num} type={self.event_type}>"
