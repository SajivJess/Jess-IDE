"""Add title to tasks and create task_events table

Revision ID: 3f8b7c91a02d
Revises: 2e4ae19c7dc5
Create Date: 2026-10-24 23:15:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

# revision identifiers, used by Alembic.
revision: str = '3f8b7c91a02d'
down_revision: Union[str, Sequence[str], None] = '2e4ae19c7dc5'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # 1. Add title to tasks table
    with op.batch_alter_table('tasks', schema=None) as batch_op:
        batch_op.add_column(
            sa.Column('title', sa.String(length=255), server_default='Untitled Task', nullable=False)
        )

    # 2. Create task_events table
    op.create_table(
        'task_events',
        sa.Column('id', sa.Uuid(), nullable=False),
        sa.Column('task_id', sa.Uuid(), nullable=False),
        sa.Column('sequence_num', sa.Integer(), nullable=False),
        sa.Column('event_type', sa.String(length=100), nullable=False),
        sa.Column('payload', sa.JSON(), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('(CURRENT_TIMESTAMP)'), nullable=False),
        sa.Column('updated_at', sa.DateTime(timezone=True), server_default=sa.text('(CURRENT_TIMESTAMP)'), nullable=False),
        sa.ForeignKeyConstraint(['task_id'], ['tasks.id'], ondelete='CASCADE'),
        sa.PrimaryKeyConstraint('id'),
        sa.UniqueConstraint('task_id', 'sequence_num', name='uq_task_events_task_id_sequence_num'),
    )
    with op.batch_alter_table('task_events', schema=None) as batch_op:
        batch_op.create_index(batch_op.f('ix_task_events_task_id'), ['task_id'], unique=False)
        batch_op.create_index(batch_op.f('ix_task_events_sequence_num'), ['sequence_num'], unique=False)
        batch_op.create_index(batch_op.f('ix_task_events_event_type'), ['event_type'], unique=False)


def downgrade() -> None:
    with op.batch_alter_table('task_events', schema=None) as batch_op:
        batch_op.drop_index(batch_op.f('ix_task_events_event_type'))
        batch_op.drop_index(batch_op.f('ix_task_events_sequence_num'))
        batch_op.drop_index(batch_op.f('ix_task_events_task_id'))

    op.drop_table('task_events')

    with op.batch_alter_table('tasks', schema=None) as batch_op:
        batch_op.drop_column('title')
