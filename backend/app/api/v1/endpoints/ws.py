import asyncio
import json
import uuid
from typing import Optional
import jwt
from fastapi import APIRouter, Query, WebSocket, WebSocketDisconnect, status
from sqlalchemy import select
from sqlalchemy.orm import selectinload

from app.core.logging import logger
from app.core.security import decode_access_token
from app.db.models.project import Project
from app.db.models.task import Task
from app.db.models.user import User
from app.db.session import async_session_factory
from app.services.task_events import event_broadcaster, get_task_events_after

router = APIRouter()


async def _authenticate_ws(
    websocket: WebSocket, token: Optional[str]
) -> Optional[User]:
    """Authenticate WebSocket client via query token, header, or initial auth message."""
    raw_token = token

    # Check Authorization header if not provided in query param
    if not raw_token:
        auth_header = websocket.headers.get("authorization")
        if auth_header and auth_header.startswith("Bearer "):
            raw_token = auth_header.replace("Bearer ", "").strip()

    # If still not provided, wait up to 4 seconds for an initial auth payload
    if not raw_token:
        try:
            auth_msg_raw = await asyncio.wait_for(websocket.receive_text(), timeout=4.0)
            data = json.loads(auth_msg_raw)
            if data.get("type") == "auth" and data.get("token"):
                raw_token = data.get("token")
        except Exception:
            return None

    if not raw_token:
        return None

    try:
        payload = decode_access_token(raw_token)
    except (jwt.PyJWTError, Exception):
        return None

    if payload.get("type") != "access":
        return None

    sub = payload.get("sub")
    if not sub:
        return None

    try:
        user_id = uuid.UUID(sub)
    except ValueError:
        return None

    async with async_session_factory() as db:
        user = await db.get(User, user_id)
        if not user or not user.is_active:
            return None
        return user


@router.websocket("/tasks/{task_id}")
async def stream_task_events(
    websocket: WebSocket,
    task_id: uuid.UUID,
    after: int = Query(0, ge=0),
    token: Optional[str] = Query(None),
) -> None:
    """Stream real-time task events to Flutter client with reconnection and event replay.
    
    Query Params:
        after: Last sequence number processed by the client (0 to receive all from beginning)
        token: Short-lived access JWT token
    """
    await websocket.accept()

    # 1. Authenticate user
    user = await _authenticate_ws(websocket, token)
    if not user:
        logger.warning(f"WebSocket connection rejected: invalid authentication on task {task_id}")
        await websocket.send_json({"type": "error", "message": "Authentication failed"})
        await websocket.close(code=status.WS_1008_POLICY_VIOLATION)
        return

    # 2. Verify task ownership
    async with async_session_factory() as db:
        stmt = (
            select(Task)
            .join(Project, Task.project_id == Project.id)
            .where(Task.id == task_id, Project.user_id == user.id)
        )
        res = await db.execute(stmt)
        task = res.scalar_one_or_none()
        if not task:
            logger.warning(
                f"WebSocket connection rejected: user {user.email} does not own task {task_id}"
            )
            await websocket.send_json(
                {"type": "error", "message": "Task not found or access denied"}
            )
            await websocket.close(code=status.WS_1008_POLICY_VIOLATION)
            return

        # 3. Replay missed events (events with sequence_num > after)
        missed_events = await get_task_events_after(db, task_id, after_seq=after)

    last_seen_seq = after

    # Send replayed events
    for ev in missed_events:
        await websocket.send_json(
            {
                "type": "event",
                "data": {
                    "id": str(ev.id),
                    "task_id": str(ev.task_id),
                    "sequence_num": ev.sequence_num,
                    "event_type": ev.event_type,
                    "payload": ev.payload,
                    "created_at": ev.created_at.isoformat() if ev.created_at else None,
                },
            }
        )
        if ev.sequence_num > last_seen_seq:
            last_seen_seq = ev.sequence_num

    logger.info(
        f"WebSocket client connected for task {task_id}. Replayed {len(missed_events)} events. Resuming live stream after seq {last_seen_seq}."
    )

    # 4. Subscribe to live broadcaster
    queue = await event_broadcaster.subscribe(task_id)

    try:
        while True:
            # Concurrently listen for broadcaster events and client incoming messages (pings / disconnects)
            get_event_task = asyncio.create_task(queue.get())
            receive_msg_task = asyncio.create_task(websocket.receive_text())

            done, pending = await asyncio.wait(
                [get_event_task, receive_msg_task],
                return_when=asyncio.FIRST_COMPLETED,
            )

            for p in pending:
                p.cancel()

            # Handle incoming event from broadcaster
            if get_event_task in done:
                event_data = get_event_task.result()
                seq = event_data.get("sequence_num", 0)
                # Prevent duplicate emissions if event was already replayed
                if seq > last_seen_seq:
                    await websocket.send_json({"type": "event", "data": event_data})
                    last_seen_seq = seq

            # Handle client incoming message or ping
            if receive_msg_task in done:
                raw_msg = receive_msg_task.result()
                try:
                    msg = json.loads(raw_msg)
                    if msg.get("type") == "ping":
                        await websocket.send_json({"type": "pong"})
                except Exception:
                    pass

    except (WebSocketDisconnect, asyncio.CancelledError):
        logger.info(f"WebSocket client disconnected cleanly for task {task_id}.")
    except Exception as e:
        logger.warning(f"WebSocket connection closed with error for task {task_id}: {e}")
    finally:
        await event_broadcaster.unsubscribe(task_id, queue)
