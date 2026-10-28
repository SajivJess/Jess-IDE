import asyncio
import uuid
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Set
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.logging import logger
from app.db.models.conversation_event import ConversationEvent
from app.db.models.conversation_message import ConversationMessage
from app.schemas.conversation import AgentEvent


class ConversationEventBroadcaster:
    """In-memory pub/sub broker to broadcast live events to connected WebSocket clients."""

    def __init__(self) -> None:
        self._subscribers: Dict[uuid.UUID, Set[asyncio.Queue]] = {}
        self._lock = asyncio.Lock()

    async def subscribe(self, conversation_id: uuid.UUID) -> asyncio.Queue:
        """Register a new queue for a WebSocket client listening to a conversation."""
        queue: asyncio.Queue = asyncio.Queue(maxsize=1000)
        async with self._lock:
            if conversation_id not in self._subscribers:
                self._subscribers[conversation_id] = set()
            self._subscribers[conversation_id].add(queue)
        logger.debug(
            f"Subscribed client to conversation {conversation_id}. Total listeners: {len(self._subscribers[conversation_id])}"
        )
        return queue

    async def unsubscribe(self, conversation_id: uuid.UUID, queue: asyncio.Queue) -> None:
        """Remove a subscriber queue when client disconnects."""
        async with self._lock:
            if conversation_id in self._subscribers:
                self._subscribers[conversation_id].discard(queue)
                if not self._subscribers[conversation_id]:
                    del self._subscribers[conversation_id]
        logger.debug(f"Unsubscribed client from conversation {conversation_id}.")

    async def broadcast(self, conversation_id: uuid.UUID, event: AgentEvent) -> None:
        """Push a normalized event to all active subscriber queues for conversation_id."""
        async with self._lock:
            queues = list(self._subscribers.get(conversation_id, set()))

        event_dict = event.model_dump()
        for q in queues:
            try:
                q.put_nowait(event_dict)
            except asyncio.QueueFull:
                logger.warning(f"Subscriber queue full for conversation {conversation_id}. Dropping old item.")
                try:
                    q.get_nowait()
                    q.put_nowait(event_dict)
                except Exception:
                    pass


# Global singleton broadcaster
conversation_broadcaster = ConversationEventBroadcaster()

_conv_locks: Dict[uuid.UUID, asyncio.Lock] = {}
_conv_global_lock = asyncio.Lock()


async def _get_conversation_lock(conversation_id: uuid.UUID) -> asyncio.Lock:
    async with _conv_global_lock:
        if conversation_id not in _conv_locks:
            _conv_locks[conversation_id] = asyncio.Lock()
        return _conv_locks[conversation_id]


async def append_conversation_event(
    db: AsyncSession,
    conversation_id: uuid.UUID,
    event_type: str,
    payload: Optional[Dict[str, Any]] = None,
    run_id: Optional[uuid.UUID] = None,
    schema_version: str = "1.0",
) -> AgentEvent:
    """Atomically append a persistent event to conversation_events and broadcast to active listeners."""
    if payload is None:
        payload = {}

    conv_lock = await _get_conversation_lock(conversation_id)
    async with conv_lock:
        event = None
        for attempt in range(5):
            try:
                seq_stmt = select(
                    func.coalesce(func.max(ConversationEvent.sequence_num), 0) + 1
                ).where(ConversationEvent.conversation_id == conversation_id)
                seq_result = await db.execute(seq_stmt)
                next_seq = seq_result.scalar() or 1

                event = ConversationEvent(
                    conversation_id=conversation_id,
                    run_id=run_id,
                    sequence_num=next_seq,
                    event_type=event_type,
                    schema_version=schema_version,
                    payload=payload,
                )
                db.add(event)
                await db.commit()
                await db.refresh(event)
                break
            except Exception:
                await db.rollback()
                if attempt == 4:
                    raise
                await asyncio.sleep(0.05)

    created_iso = (
        event.created_at.isoformat()
        if event.created_at
        else datetime.now(timezone.utc).isoformat()
    )

    agent_event = AgentEvent(
        schema_version=schema_version,
        type=event_type,
        event_id=str(event.id),
        conversation_id=str(conversation_id),
        run_id=str(run_id) if run_id else None,
        sequence=event.sequence_num,
        created_at=created_iso,
        data=payload,
    )

    # If this marks assistant message completion, also persist message row if text is present
    if event_type == "message.completed":
        text_content = payload.get("text", "")
        msg_id_str = payload.get("message_id")
        if text_content:
            try:
                existing_msg = None
                if msg_id_str:
                    try:
                        existing_msg = await db.get(ConversationMessage, uuid.UUID(msg_id_str))
                    except Exception:
                        pass

                if not existing_msg:
                    msg = ConversationMessage(
                        id=uuid.UUID(msg_id_str) if msg_id_str else uuid.uuid4(),
                        conversation_id=conversation_id,
                        run_id=run_id,
                        role="assistant",
                        content=text_content,
                    )
                    db.add(msg)
                    await db.commit()
                    await db.refresh(msg)
                    payload["message_id"] = str(msg.id)
                    agent_event.data["message_id"] = str(msg.id)
                else:
                    payload["message_id"] = str(existing_msg.id)
                    agent_event.data["message_id"] = str(existing_msg.id)
            except Exception as e:
                logger.warning(f"Could not persist completed assistant message: {e}")

    # Broadcast to live WebSockets
    await conversation_broadcaster.broadcast(conversation_id, agent_event)
    logger.info(
        f"[Conversation #{conversation_id}] seq={agent_event.sequence} type={event_type}"
    )
    return agent_event


async def get_conversation_events_after(
    db: AsyncSession,
    conversation_id: uuid.UUID,
    after_seq: int = 0,
) -> List[AgentEvent]:
    """Retrieve ordered persistent events starting after sequence number after_seq."""
    stmt = (
        select(ConversationEvent)
        .where(
            ConversationEvent.conversation_id == conversation_id,
            ConversationEvent.sequence_num > after_seq,
        )
        .order_by(ConversationEvent.sequence_num.asc())
    )
    result = await db.execute(stmt)
    records = list(result.scalars().all())

    return [
        AgentEvent(
            schema_version=r.schema_version,
            type=r.event_type,
            event_id=str(r.id),
            conversation_id=str(r.conversation_id),
            run_id=str(r.run_id) if r.run_id else None,
            sequence=r.sequence_num,
            created_at=r.created_at.isoformat() if r.created_at else "",
            data=r.payload,
        )
        for r in records
    ]
