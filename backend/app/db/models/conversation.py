import uuid
from typing import TYPE_CHECKING, List
from sqlalchemy import ForeignKey, String
from sqlalchemy.orm import Mapped, mapped_column, relationship
from sqlalchemy.types import Uuid

from app.db.base import Base, TimestampMixin, UUIDMixin

if TYPE_CHECKING:
    from app.db.models.project import Project
    from app.db.models.conversation_message import ConversationMessage
    from app.db.models.conversation_event import ConversationEvent
    from app.db.models.task import Task


class Conversation(Base, UUIDMixin, TimestampMixin):
    """A conversational agent session within a project."""

    __tablename__ = "conversations"

    project_id: Mapped[uuid.UUID] = mapped_column(
        Uuid(as_uuid=True),
        ForeignKey("projects.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    title: Mapped[str] = mapped_column(
        String(255),
        default="Coding Session",
        nullable=False,
    )

    # Relationships
    project: Mapped["Project"] = relationship(
        "Project",
        back_populates="conversations",
    )
    messages: Mapped[List["ConversationMessage"]] = relationship(
        "ConversationMessage",
        back_populates="conversation",
        cascade="all, delete-orphan",
        order_by="ConversationMessage.created_at",
    )
    events: Mapped[List["ConversationEvent"]] = relationship(
        "ConversationEvent",
        back_populates="conversation",
        cascade="all, delete-orphan",
        order_by="ConversationEvent.sequence_num",
    )
    tasks: Mapped[List["Task"]] = relationship(
        "Task",
        back_populates="conversation",
        cascade="all, delete-orphan",
        order_by="Task.created_at",
    )

    def __repr__(self) -> str:
        return f"<Conversation id={self.id} title={self.title} project={self.project_id}>"
