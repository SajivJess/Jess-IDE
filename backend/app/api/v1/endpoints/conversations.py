from datetime import datetime, timezone
import uuid
from typing import Optional
from fastapi import APIRouter, Depends, HTTPException, Query, Response, status
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.api.deps import get_current_user
from app.core.logging import logger
from app.db.models.conversation import Conversation
from app.db.models.conversation_message import ConversationMessage
from app.db.models.project import Project
from app.db.models.task import Task
from app.db.models.user import User
from app.db.models.workspace import Workspace
from app.db.session import get_db
from app.schemas.conversation import (
    ChatMessageCreate,
    ChatMessageResponse,
    ConversationCreate,
    ConversationListResponse,
    ConversationMessageRead,
    ConversationRead,
    EventReplayResponse,
    RunRead,
    RunStartRequest,
)
from app.schemas.task import (
    TERMINAL_STATUSES,
    TaskApprovalRequest,
    TaskCancelResponse,
    TaskStatus,
)
from app.services.agent_adapter import simulated_agent
from app.services.conversation_events import (
    append_conversation_event,
    get_conversation_events_after,
)
from app.services.intent_router import IntentRouter, MessageIntent

router = APIRouter()


async def _get_project_with_ownership(
    project_id: uuid.UUID,
    user_id: uuid.UUID,
    db: AsyncSession,
) -> Project:
    stmt = select(Project).where(Project.id == project_id, Project.user_id == user_id)
    res = await db.execute(stmt)
    project = res.scalar_one_or_none()
    if not project:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Project not found",
        )
    return project


async def _get_conversation_with_ownership(
    conversation_id: uuid.UUID,
    user_id: uuid.UUID,
    project_id: Optional[uuid.UUID],
    db: AsyncSession,
) -> Conversation:
    stmt = (
        select(Conversation)
        .join(Project, Conversation.project_id == Project.id)
        .options(
            selectinload(Conversation.messages),
            selectinload(Conversation.tasks),
        )
        .where(Conversation.id == conversation_id, Project.user_id == user_id)
    )
    if project_id:
        stmt = stmt.where(Conversation.project_id == project_id)

    res = await db.execute(stmt)
    conv = res.scalar_one_or_none()
    if not conv:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Conversation not found",
        )
    return conv


@router.get(
    "/projects/{project_id}/conversations",
    response_model=ConversationListResponse,
    summary="List conversations for project",
)
async def list_conversations(
    project_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> ConversationListResponse:
    """List conversations for project. Automatically initializes an active session if none exists."""
    await _get_project_with_ownership(project_id, current_user.id, db)

    stmt = (
        select(Conversation)
        .options(
            selectinload(Conversation.messages),
            selectinload(Conversation.tasks),
        )
        .where(Conversation.project_id == project_id)
        .order_by(Conversation.updated_at.desc())
    )
    res = await db.execute(stmt)
    convs = list(res.scalars().all())

    # If project has no conversations yet, create default one
    if not convs:
        default_conv = Conversation(
            project_id=project_id,
            title="Coding Session",
        )
        db.add(default_conv)
        await db.commit()

        refetch_stmt = (
            select(Conversation)
            .options(
                selectinload(Conversation.messages),
                selectinload(Conversation.tasks),
            )
            .where(Conversation.id == default_conv.id)
        )
        refetch_res = await db.execute(refetch_stmt)
        convs = [refetch_res.scalar_one()]

    items = [
        ConversationRead(
            id=c.id,
            project_id=c.project_id,
            title=c.title,
            created_at=c.created_at,
            updated_at=c.updated_at,
            messages_count=len(c.messages) if c.messages else 0,
            runs_count=len(c.tasks) if c.tasks else 0,
        )
        for c in convs
    ]

    return ConversationListResponse(items=items, total=len(items))


@router.post(
    "/projects/{project_id}/conversations",
    response_model=ConversationRead,
    status_code=status.HTTP_201_CREATED,
    summary="Create a new conversation",
)
async def create_conversation(
    project_id: uuid.UUID,
    payload: ConversationCreate,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> ConversationRead:
    await _get_project_with_ownership(project_id, current_user.id, db)

    conv = Conversation(
        project_id=project_id,
        title=payload.title.strip() if payload.title else "Coding Session",
    )
    db.add(conv)
    await db.commit()
    await db.refresh(conv)

    return ConversationRead(
        id=conv.id,
        project_id=conv.project_id,
        title=conv.title,
        created_at=conv.created_at,
        updated_at=conv.updated_at,
        messages_count=0,
        runs_count=0,
    )


@router.get(
    "/projects/{project_id}/conversations/{conversation_id}",
    response_model=ConversationRead,
    summary="Get conversation metadata",
)
async def get_conversation(
    project_id: uuid.UUID,
    conversation_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> ConversationRead:
    conv = await _get_conversation_with_ownership(conversation_id, current_user.id, project_id, db)
    return ConversationRead(
        id=conv.id,
        project_id=conv.project_id,
        title=conv.title,
        created_at=conv.created_at,
        updated_at=conv.updated_at,
        messages_count=len(conv.messages) if conv.messages else 0,
        runs_count=len(conv.tasks) if conv.tasks else 0,
    )


@router.get(
    "/projects/{project_id}/conversations/{conversation_id}/messages",
    response_model=list[ConversationMessageRead],
    summary="Get message history for conversation",
)
async def get_conversation_messages(
    project_id: uuid.UUID,
    conversation_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> list[ConversationMessageRead]:
    await _get_conversation_with_ownership(conversation_id, current_user.id, project_id, db)

    stmt = (
        select(ConversationMessage)
        .where(ConversationMessage.conversation_id == conversation_id)
        .order_by(ConversationMessage.created_at.asc())
    )
    res = await db.execute(stmt)
    messages = res.scalars().all()

    return [
        ConversationMessageRead(
            id=m.id,
            conversation_id=m.conversation_id,
            run_id=m.run_id,
            role=m.role,
            content=m.content,
            created_at=m.created_at,
        )
        for m in messages
    ]


@router.post(
    "/projects/{project_id}/conversations/{conversation_id}/messages",
    response_model=ChatMessageResponse,
    status_code=status.HTTP_201_CREATED,
    summary="Post a message into conversation with backend intent routing",
)
async def post_conversation_message(
    project_id: uuid.UUID,
    conversation_id: uuid.UUID,
    payload: ChatMessageCreate,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> ChatMessageResponse:
    project = await _get_project_with_ownership(project_id, current_user.id, db)
    conv = await _get_conversation_with_ownership(conversation_id, current_user.id, project_id, db)

    raw_text = payload.content.strip()
    if not raw_text:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="Message content cannot be empty.",
        )

    # 1. Classify user intent
    intent = await IntentRouter.classify(
        raw_text,
        project_name=project.name,
        project_description=project.description,
    )
    logger.info(
        f"Classified message intent as '{intent.value}' for conversation {conv.id}: '{raw_text[:40]}'"
    )

    # 2. Handle non-coding intents (CONVERSATION, PROJECT_QUESTION, AMBIGUOUS)
    if intent != MessageIntent.CODING_INSTRUCTION:
        # A. Save user message in DB
        user_msg = ConversationMessage(
            conversation_id=conv.id,
            run_id=None,
            role="user",
            content=raw_text,
        )
        db.add(user_msg)
        await db.commit()
        await db.refresh(user_msg)

        # B. Fetch recent messages for conversational context
        stmt = (
            select(ConversationMessage)
            .where(ConversationMessage.conversation_id == conv.id)
            .order_by(ConversationMessage.created_at.desc())
            .limit(6)
        )
        history_res = await db.execute(stmt)
        history_msgs = list(reversed(history_res.scalars().all()))
        history_payload = [
            {"role": m.role, "content": m.content}
            for m in history_msgs
            if m.id != user_msg.id
        ]

        reply_text = await IntentRouter.generate_conversational_reply(
            intent=intent,
            prompt=raw_text,
            project_name=project.name,
            project_description=project.description,
            history=history_payload,
        )

        # C. Save assistant message in DB
        asst_msg = ConversationMessage(
            conversation_id=conv.id,
            run_id=None,
            role="assistant",
            content=reply_text,
        )
        db.add(asst_msg)
        await db.commit()
        await db.refresh(asst_msg)

        # D. Broadcast live events to WebSocket subscribers so Flutter timeline updates
        await append_conversation_event(
            db,
            conversation_id=conv.id,
            event_type="message.started",
            payload={"message_id": str(asst_msg.id), "role": "assistant"},
        )
        await append_conversation_event(
            db,
            conversation_id=conv.id,
            event_type="message.completed",
            payload={"message_id": str(asst_msg.id), "text": reply_text, "role": "assistant"},
        )

        return ChatMessageResponse(
            user_message=ConversationMessageRead(
                id=user_msg.id,
                conversation_id=user_msg.conversation_id,
                run_id=None,
                role=user_msg.role,
                content=user_msg.content,
                created_at=user_msg.created_at,
            ),
            intent=intent.value,
            assistant_message=ConversationMessageRead(
                id=asst_msg.id,
                conversation_id=asst_msg.conversation_id,
                run_id=None,
                role=asst_msg.role,
                content=asst_msg.content,
                created_at=asst_msg.created_at,
            ),
            run=None,
        )

    # 3. Intent is CODING_INSTRUCTION -> Start agent run
    ws_stmt = select(Workspace).where(Workspace.project_id == project_id)
    ws_res = await db.execute(ws_stmt)
    ws = ws_res.scalars().first()

    title = raw_text.split("\n")[0][:60]
    task = Task(
        project_id=project_id,
        conversation_id=conv.id,
        workspace_id=ws.id if ws else None,
        title=title,
        prompt=raw_text,
        status=TaskStatus.QUEUED.value,
    )
    db.add(task)

    user_msg = ConversationMessage(
        conversation_id=conv.id,
        run_id=task.id,
        role="user",
        content=raw_text,
    )
    db.add(user_msg)

    await db.commit()
    await db.refresh(task)
    await db.refresh(user_msg)

    # Launch background agent execution
    await simulated_agent.run_task(task.id)

    logger.info(f"Intent CODING_INSTRUCTION: Started agent run {task.id} for conversation {conv.id}")

    return ChatMessageResponse(
        user_message=ConversationMessageRead(
            id=user_msg.id,
            conversation_id=user_msg.conversation_id,
            run_id=task.id,
            role=user_msg.role,
            content=user_msg.content,
            created_at=user_msg.created_at,
        ),
        intent=intent.value,
        assistant_message=None,
        run=RunRead(
            id=task.id,
            project_id=task.project_id,
            conversation_id=conv.id,
            status=TaskStatus(task.status),
            prompt=task.prompt,
            title=task.title,
            active_branch=task.active_branch,
            commit_sha=task.commit_sha,
            execution_log=task.execution_log,
            created_at=task.created_at,
            updated_at=task.updated_at,
        ),
    )


@router.post(
    "/projects/{project_id}/conversations/{conversation_id}/runs",
    response_model=RunRead,
    status_code=status.HTTP_201_CREATED,
    summary="Start an agent coding run in a conversation",
)
async def start_run(
    project_id: uuid.UUID,
    conversation_id: uuid.UUID,
    payload: RunStartRequest,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> RunRead:
    """Start an agent run: saves user message, creates run, and triggers agent adapter."""
    conv = await _get_conversation_with_ownership(conversation_id, current_user.id, project_id, db)

    # 1. Derive task title
    prompt_text = payload.prompt.strip()
    title = payload.title.strip() if payload.title else prompt_text.split("\n")[0][:60]

    # 2. Create run (Task)
    ws_stmt = select(Workspace).where(Workspace.project_id == project_id)
    ws_res = await db.execute(ws_stmt)
    ws = ws_res.scalars().first()

    task = Task(
        project_id=project_id,
        conversation_id=conv.id,
        workspace_id=ws.id if ws else None,
        title=title,
        prompt=prompt_text,
        status=TaskStatus.QUEUED.value,
    )
    db.add(task)

    # 3. Persist user message linked to run
    user_msg = ConversationMessage(
        conversation_id=conv.id,
        run_id=task.id,
        role="user",
        content=prompt_text,
    )
    db.add(user_msg)

    await db.commit()
    await db.refresh(task)

    # 4. Trigger agent adapter in background
    await simulated_agent.run_task(task.id)

    logger.info(
        f"Started conversation run {task.id} in conversation {conv.id} for project {project_id}"
    )

    return RunRead(
        id=task.id,
        project_id=task.project_id,
        conversation_id=conv.id,
        status=TaskStatus(task.status),
        prompt=task.prompt,
        title=task.title,
        active_branch=task.active_branch,
        commit_sha=task.commit_sha,
        execution_log=task.execution_log,
        created_at=task.created_at,
        updated_at=task.updated_at,
    )


@router.get(
    "/projects/{project_id}/conversations/{conversation_id}/events",
    response_model=EventReplayResponse,
    summary="Replay conversation events after sequence number",
)
async def replay_conversation_events(
    project_id: uuid.UUID,
    conversation_id: uuid.UUID,
    after: int = Query(0, ge=0, description="Retrieve events with sequence > after"),
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> EventReplayResponse:
    await _get_conversation_with_ownership(conversation_id, current_user.id, project_id, db)
    events = await get_conversation_events_after(db, conversation_id, after_seq=after)

    return EventReplayResponse(
        items=events,
        conversation_id=conversation_id,
        total=len(events),
        after=after,
    )


@router.post(
    "/projects/{project_id}/runs/{run_id}/approval",
    summary="Submit approval or rejection for a run",
)
async def submit_run_approval(
    project_id: uuid.UUID,
    run_id: uuid.UUID,
    payload: TaskApprovalRequest,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> dict:
    """Submit approval or rejection for an active run waiting in APPROVAL_REQUIRED."""
    await _get_project_with_ownership(project_id, current_user.id, db)

    task = await db.get(Task, run_id)
    if not task or task.project_id != project_id:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Run not found")

    current_status = TaskStatus(task.status)
    if current_status == TaskStatus.COMPLETED and payload.action.lower() == "approve":
        return {
            "status": "ok",
            "run_id": str(task.id),
            "approved": True,
            "idempotent": True,
            "message": "Run already approved and completed.",
        }
    if current_status == TaskStatus.CANCELLED and payload.action.lower() == "reject":
        return {
            "status": "ok",
            "run_id": str(task.id),
            "approved": False,
            "idempotent": True,
            "message": "Run already rejected.",
        }
    if current_status in TERMINAL_STATUSES:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=f"Run is in terminal state {current_status.value} and cannot be modified.",
        )
    if current_status != TaskStatus.APPROVAL_REQUIRED:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Run is in {task.status} status and not waiting for approval.",
        )

    is_approved = payload.action.lower() == "approve"
    await simulated_agent.handle_approval(task.id, approved=is_approved, reason=payload.reason)

    logger.info(f"Submitted approval {payload.action} for run {task.id}")
    return {"status": "ok", "run_id": str(task.id), "approved": is_approved}


@router.post(
    "/projects/{project_id}/runs/{run_id}/cancel",
    response_model=TaskCancelResponse,
    summary="Cancel active run",
)
async def cancel_run(
    project_id: uuid.UUID,
    run_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> TaskCancelResponse:
    await _get_project_with_ownership(project_id, current_user.id, db)

    task = await db.get(Task, run_id)
    if not task or task.project_id != project_id:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Run not found")

    current_status = TaskStatus(task.status)
    if current_status in TERMINAL_STATUSES:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Cannot cancel run in terminal state {current_status.value}",
        )

    await simulated_agent.cancel_task(task.id)

    task.status = TaskStatus.CANCELLED.value
    await db.commit()

    if task.conversation_id:
        await append_conversation_event(
            db,
            conversation_id=task.conversation_id,
            event_type="run.cancelled",
            payload={"reason": "Cancelled by user via API."},
            run_id=task.id,
        )

    return TaskCancelResponse(
        id=task.id,
        status=TaskStatus.CANCELLED,
        message="Run cancelled successfully.",
    )


@router.get(
    "/projects/{project_id}/runs/{run_id}",
    response_model=RunRead,
    summary="Get run status",
)
async def get_run_status(
    project_id: uuid.UUID,
    run_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> RunRead:
    await _get_project_with_ownership(project_id, current_user.id, db)

    task = await db.get(Task, run_id)
    if not task or task.project_id != project_id:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Run not found")

    return RunRead(
        id=task.id,
        project_id=task.project_id,
        conversation_id=task.conversation_id or task.project_id,
        status=TaskStatus(task.status),
        prompt=task.prompt,
        title=task.title,
        active_branch=task.active_branch,
        commit_sha=task.commit_sha,
        execution_log=task.execution_log,
        created_at=task.created_at,
        updated_at=task.updated_at,
    )


@router.get(
    "/projects/{project_id}/conversations/{conversation_id}/export",
    summary="Export conversation history as formatted text",
)
@router.get(
    "/conversations/{conversation_id}/export",
    summary="Export conversation history as formatted text",
)
async def export_conversation(
    conversation_id: uuid.UUID,
    project_id: Optional[uuid.UUID] = None,
    format: str = Query("txt", description="Export format: 'txt' or 'md'"),
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> Response:
    conv = await _get_conversation_with_ownership(conversation_id, current_user.id, project_id, db)

    stmt = (
        select(ConversationMessage)
        .where(ConversationMessage.conversation_id == conversation_id)
        .order_by(ConversationMessage.created_at.asc())
    )
    res = await db.execute(stmt)
    messages = res.scalars().all()

    now_str = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    lines = [
        "=" * 60,
        "JESS IDE — CONVERSATION EXPORT",
        f"Project ID: {conv.project_id}",
        f"Conversation: {conv.title} ({conv.id})",
        f"Exported At: {now_str}",
        f"Total Messages: {len(messages)}",
        "=" * 60,
        "",
    ]

    for m in messages:
        sender = "USER" if m.role == "user" else "ASSISTANT (Jess Meta Agent)"
        m_time = m.created_at.strftime("%Y-%m-%d %H:%M:%S") if m.created_at else "Unknown Time"
        lines.append(f"[{m_time}] {sender}:")
        lines.append(m.content.strip() if m.content else "(empty)")
        lines.append("-" * 40)
        lines.append("")

    export_content = "\n".join(lines)
    ext = "md" if format == "md" else "txt"
    media_type = "text/markdown; charset=utf-8" if format == "md" else "text/plain; charset=utf-8"

    return Response(
        content=export_content,
        media_type=media_type,
        headers={
            "Content-Disposition": f'attachment; filename="chat_{str(conv.id)[:8]}.{ext}"',
            "Access-Control-Allow-Origin": "*",
        },
    )

