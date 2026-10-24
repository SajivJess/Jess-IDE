import asyncio
import uuid
from typing import Any, Dict, List, Optional, Set
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.logging import logger
from app.db.models.task_event import TaskEvent


class TaskEventBroadcaster:
    """In-memory pub/sub broker to broadcast live task events to connected WebSocket clients."""

    def __init__(self) -> None:
        self._subscribers: Dict[uuid.UUID, Set[asyncio.Queue]] = {}
        self._lock = asyncio.Lock()

    async def subscribe(self, task_id: uuid.UUID) -> asyncio.Queue:
        """Register a new queue for a WebSocket client listening to task_id."""
        queue: asyncio.Queue = asyncio.Queue(maxsize=500)
        async with self._lock:
            if task_id not in self._subscribers:
                self._subscribers[task_id] = set()
            self._subscribers[task_id].add(queue)
        logger.debug(f"Subscribed client to task {task_id}. Total listeners: {len(self._subscribers[task_id])}")
        return queue

    async def unsubscribe(self, task_id: uuid.UUID, queue: asyncio.Queue) -> None:
        """Remove a subscriber queue when client disconnects."""
        async with self._lock:
            if task_id in self._subscribers:
                self._subscribers[task_id].discard(queue)
                if not self._subscribers[task_id]:
                    del self._subscribers[task_id]
        logger.debug(f"Unsubscribed client from task {task_id}.")

    async def broadcast(self, task_id: uuid.UUID, event_data: Dict[str, Any]) -> None:
        """Push an event to all active subscriber queues for task_id without blocking."""
        async with self._lock:
            queues = list(self._subscribers.get(task_id, set()))

        for q in queues:
            try:
                q.put_nowait(event_data)
            except asyncio.QueueFull:
                logger.warning(f"Subscriber queue full for task {task_id}. Dropping old item.")
                try:
                    q.get_nowait()
                    q.put_nowait(event_data)
                except Exception:
                    pass


# Global singleton broadcaster
event_broadcaster = TaskEventBroadcaster()


_task_locks: Dict[uuid.UUID, asyncio.Lock] = {}
_global_lock = asyncio.Lock()


async def _get_task_lock(task_id: uuid.UUID) -> asyncio.Lock:
    async with _global_lock:
        if task_id not in _task_locks:
            _task_locks[task_id] = asyncio.Lock()
        return _task_locks[task_id]


async def append_task_event(
    db: AsyncSession,
    task_id: uuid.UUID,
    event_type: str,
    payload: Optional[Dict[str, Any]] = None,
) -> TaskEvent:
    """Atomically append a persistent event to the task_events table and broadcast to active listeners.
    
    Sequence numbers are monotonically increasing per task.
    """
    if payload is None:
        payload = {}

    task_lock = await _get_task_lock(task_id)
    async with task_lock:
        event = None
        for attempt in range(5):
            try:
                # Calculate next sequence number for this task
                seq_stmt = select(func.coalesce(func.max(TaskEvent.sequence_num), 0) + 1).where(
                    TaskEvent.task_id == task_id
                )
                seq_result = await db.execute(seq_stmt)
                next_seq = seq_result.scalar() or 1

                event = TaskEvent(
                    task_id=task_id,
                    sequence_num=next_seq,
                    event_type=event_type,
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

    event_data = {
        "id": str(event.id),
        "task_id": str(event.task_id),
        "sequence_num": event.sequence_num,
        "event_type": event.event_type,
        "payload": event.payload,
        "created_at": event.created_at.isoformat() if event.created_at else None,
    }

    # Broadcast to live WebSockets
    await event_broadcaster.broadcast(task_id, event_data)
    logger.info(f"[TaskEvent #{event.sequence_num}] {event_type} on task {task_id}")
    return event


async def get_task_events_after(
    db: AsyncSession,
    task_id: uuid.UUID,
    after_seq: int = 0,
) -> List[TaskEvent]:
    """Retrieve ordered persistent events for task_id starting after sequence number after_seq."""
    stmt = (
        select(TaskEvent)
        .where(TaskEvent.task_id == task_id, TaskEvent.sequence_num > after_seq)
        .order_by(TaskEvent.sequence_num.asc())
    )
    result = await db.execute(stmt)
    return list(result.scalars().all())
