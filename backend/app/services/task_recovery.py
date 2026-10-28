import json
import uuid
from typing import List
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.logging import logger
from app.db.models.conversation_message import ConversationMessage
from app.db.models.task import Task
from app.db.session import async_session_factory
from app.schemas.task import TaskStatus
from app.services.agent_adapter import simulated_agent
from app.services.conversation_events import append_conversation_event


INTERRUPTED_REASON = (
    "Execution was interrupted by a backend restart or worker disconnection. "
    "Any uncommitted workspace modifications remain preserved on disk and can be inspected under the 'Changes' tab. "
    "You can review them, discard them, or retry this instruction intentionally."
)


async def reconcile_interrupted_tasks(db: AsyncSession = None) -> List[uuid.UUID]:
    """Identify and safely recover tasks left in nonterminal states across server crashes/restarts.
    
    Requirements:
    1. Distinguish genuinely active tasks from disappeared workers.
    2. Do NOT mark tasks failed if their execution is still alive in memory.
    3. Tasks awaiting APPROVAL_REQUIRED are preserved, not failed or silently committed.
    4. Transition dead RUNNING or QUEUED tasks to FAILED with explicit explanation.
    5. Idempotent: repeated recovery runs will not produce duplicate messages or events.
    6. Terminal tasks remain terminal.
    """
    recovered_ids: List[uuid.UUID] = []

    async def _process(session: AsyncSession) -> None:
        stmt = select(Task).where(
            Task.status.in_([TaskStatus.RUNNING.value, TaskStatus.QUEUED.value])
        )
        res = await session.execute(stmt)
        candidates = res.scalars().all()

        for t in candidates:
            # Check if execution is still alive in agent adapter
            if simulated_agent.is_task_running(t.id):
                logger.info(f"[Recovery] Task {t.id} is actively executing in memory. Preserving state.")
                continue

            logger.warning(
                f"[Recovery] Task {t.id} ('{t.title}') was left in {t.status} across restart. Safely marking FAILED."
            )
            prev_status = t.status
            t.status = TaskStatus.FAILED.value

            log_data = {}
            if t.execution_log:
                try:
                    log_data = json.loads(t.execution_log)
                except Exception:
                    log_data = {"raw_log": t.execution_log}

            log_data["interrupted"] = True
            log_data["interrupted_reason"] = INTERRUPTED_REASON
            log_data["reason"] = INTERRUPTED_REASON
            log_data["previous_status"] = prev_status
            t.execution_log = json.dumps(log_data)
            recovered_ids.append(t.id)

            # If task belongs to a conversation, idempotently persist explanation message & event
            if t.conversation_id:
                # Idempotency check: see if an assistant message with this explanation was already posted
                existing_msg_stmt = select(ConversationMessage).where(
                    ConversationMessage.conversation_id == t.conversation_id,
                    ConversationMessage.run_id == t.id,
                    ConversationMessage.role == "assistant",
                )
                msg_res = await session.execute(existing_msg_stmt)
                existing_msg = msg_res.scalars().first()

                if not existing_msg:
                    asst_msg = ConversationMessage(
                        conversation_id=t.conversation_id,
                        run_id=t.id,
                        role="assistant",
                        content=f"⚠️ {INTERRUPTED_REASON}",
                    )
                    session.add(asst_msg)

                await append_conversation_event(
                    session,
                    conversation_id=t.conversation_id,
                    event_type="run.failed",
                    payload={"reason": INTERRUPTED_REASON, "interrupted": True},
                    run_id=t.id,
                )

        if recovered_ids:
            await session.commit()
            logger.info(f"[Recovery] Successfully reconciled {len(recovered_ids)} interrupted task(s).")

    if db is not None:
        await _process(db)
    else:
        async with async_session_factory() as session:
            await _process(session)

    return recovered_ids
