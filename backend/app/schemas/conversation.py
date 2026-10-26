import uuid
from datetime import datetime
from typing import Any, Dict, List, Optional
from pydantic import BaseModel, ConfigDict, Field

from app.schemas.task import TaskStatus


class AgentEvent(BaseModel):
    """Normalized provider-independent event adhering to the specification."""

    schema_version: str = "1.0"
    type: str
    event_id: str
    conversation_id: str
    run_id: Optional[str] = None
    sequence: int
    created_at: str
    data: Dict[str, Any] = Field(default_factory=dict)


class ConversationCreate(BaseModel):
    """Payload to initialize a new conversation."""

    title: Optional[str] = Field("Coding Session", max_length=255)


class ConversationMessageRead(BaseModel):
    """Public representation of a conversation chat message."""

    id: uuid.UUID
    conversation_id: uuid.UUID
    run_id: Optional[uuid.UUID] = None
    role: str
    content: str
    created_at: datetime

    model_config = ConfigDict(from_attributes=True)


class ConversationRead(BaseModel):
    """Public representation of an agent conversation."""

    id: uuid.UUID
    project_id: uuid.UUID
    title: str
    created_at: datetime
    updated_at: datetime
    messages_count: int = 0
    runs_count: int = 0

    model_config = ConfigDict(from_attributes=True)


class ConversationListResponse(BaseModel):
    """List of conversations for a project."""

    items: List[ConversationRead]
    total: int


class RunStartRequest(BaseModel):
    """Request payload to start an agent coding run in a conversation."""

    prompt: str = Field(..., min_length=1, max_length=10000, description="User instruction for the agent")
    title: Optional[str] = Field(None, max_length=255, description="Optional brief title")


class RunRead(BaseModel):
    """Public metadata for an active or past agent run."""

    id: uuid.UUID
    project_id: uuid.UUID
    conversation_id: uuid.UUID
    status: TaskStatus
    prompt: str
    title: str
    created_at: datetime
    updated_at: datetime

    model_config = ConfigDict(from_attributes=True)


class EventReplayResponse(BaseModel):
    """Ordered event list for reconnect and replay."""

    items: List[AgentEvent]
    conversation_id: uuid.UUID
    total: int
    after: int


class ChatMessageCreate(BaseModel):
    """Payload to post a message into the conversation timeline."""

    content: str = Field(..., min_length=1, max_length=10000, description="User message text")


class ChatMessageResponse(BaseModel):
    """Response returned after processing a user message through the intent router."""

    user_message: ConversationMessageRead
    intent: str
    assistant_message: Optional[ConversationMessageRead] = None
    run: Optional[RunRead] = None

