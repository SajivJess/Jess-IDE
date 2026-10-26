import uuid
from typing import TYPE_CHECKING, Any, Dict, Optional
from sqlalchemy import ForeignKey, Integer, String, UniqueConstraint
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column, relationship
from sqlalchemy.types import JSON, Uuid

from app.db.base import Base, TimestampMixin, UUIDMixin

if TYPE_CHECKING:
    from app.db.models.conversation import Conversation
    from app.db.models.task import Task


class ConversationEvent(Base, UUIDMixin, TimestampMixin):
    """An append-only persistent event emitted during a conversation run."""

    __tablename__ = "conversation_events"
    __table_args__ = (
        UniqueConstraint(
            "conversation_id",
            "sequence_num",
            name="uq_conv_events_conv_id_seq",
        ),
    )

    conversation_id: Mapped[uuid.UUID] = mapped_column(
        Uuid(as_uuid=True),
        ForeignKey("conversations.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    run_id: Mapped[Optional[uuid.UUID]] = mapped_column(
        Uuid(as_uuid=True),
        ForeignKey("tasks.id", ondelete="SET NULL"),
        nullable=True,
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
    schema_version: Mapped[str] = mapped_column(
        String(20),
        default="1.0",
        nullable=False,
    )
    payload: Mapped[Dict[str, Any]] = mapped_column(
        JSON().with_variant(JSONB, "postgresql"),
        nullable=False,
        default=dict,
    )

    # Relationships
    conversation: Mapped["Conversation"] = relationship(
        "Conversation",
        back_populates="events",
    )
    task: Mapped[Optional["Task"]] = relationship(
        "Task",
    )

    def __repr__(self) -> str:
        return f"<ConversationEvent id={self.id} conv={self.conversation_id} seq={self.sequence_num} type={self.event_type}>"
