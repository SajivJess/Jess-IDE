"""Create conversations, conversation_messages, conversation_events and task.conversation_id

Revision ID: 5b1c8e9f2a34
Revises: 4a9c1e7f3b82
Create Date: 2026-10-25 15:00:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = '5b1c8e9f2a34'
down_revision: Union[str, Sequence[str], None] = '4a9c1e7f3b82'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # 1. Create conversations table
    op.create_table(
        'conversations',
        sa.Column('id', sa.Uuid(), nullable=False),
        sa.Column('project_id', sa.Uuid(), nullable=False),
        sa.Column('title', sa.String(length=255), server_default='Coding Session', nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('(CURRENT_TIMESTAMP)'), nullable=False),
        sa.Column('updated_at', sa.DateTime(timezone=True), server_default=sa.text('(CURRENT_TIMESTAMP)'), nullable=False),
        sa.ForeignKeyConstraint(['project_id'], ['projects.id'], ondelete='CASCADE'),
        sa.PrimaryKeyConstraint('id'),
    )
    with op.batch_alter_table('conversations', schema=None) as batch_op:
        batch_op.create_index(batch_op.f('ix_conversations_project_id'), ['project_id'], unique=False)

    # 2. Add conversation_id to tasks table
    with op.batch_alter_table('tasks', schema=None) as batch_op:
        batch_op.add_column(sa.Column('conversation_id', sa.Uuid(), nullable=True))
        batch_op.create_foreign_key('fk_tasks_conversation_id', 'conversations', ['conversation_id'], ['id'], ondelete='SET NULL')
        batch_op.create_index(batch_op.f('ix_tasks_conversation_id'), ['conversation_id'], unique=False)

    # 3. Create conversation_messages table
    op.create_table(
        'conversation_messages',
        sa.Column('id', sa.Uuid(), nullable=False),
        sa.Column('conversation_id', sa.Uuid(), nullable=False),
        sa.Column('run_id', sa.Uuid(), nullable=True),
        sa.Column('role', sa.String(length=20), nullable=False),
        sa.Column('content', sa.Text(), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('(CURRENT_TIMESTAMP)'), nullable=False),
        sa.Column('updated_at', sa.DateTime(timezone=True), server_default=sa.text('(CURRENT_TIMESTAMP)'), nullable=False),
        sa.ForeignKeyConstraint(['conversation_id'], ['conversations.id'], ondelete='CASCADE'),
        sa.ForeignKeyConstraint(['run_id'], ['tasks.id'], ondelete='SET NULL'),
        sa.PrimaryKeyConstraint('id'),
    )
    with op.batch_alter_table('conversation_messages', schema=None) as batch_op:
        batch_op.create_index(batch_op.f('ix_conversation_messages_conversation_id'), ['conversation_id'], unique=False)
        batch_op.create_index(batch_op.f('ix_conversation_messages_run_id'), ['run_id'], unique=False)
        batch_op.create_index(batch_op.f('ix_conversation_messages_role'), ['role'], unique=False)

    # 4. Create conversation_events table
    op.create_table(
        'conversation_events',
        sa.Column('id', sa.Uuid(), nullable=False),
        sa.Column('conversation_id', sa.Uuid(), nullable=False),
        sa.Column('run_id', sa.Uuid(), nullable=True),
        sa.Column('sequence_num', sa.Integer(), nullable=False),
        sa.Column('event_type', sa.String(length=100), nullable=False),
        sa.Column('schema_version', sa.String(length=20), server_default='1.0', nullable=False),
        sa.Column('payload', sa.JSON(), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('(CURRENT_TIMESTAMP)'), nullable=False),
        sa.Column('updated_at', sa.DateTime(timezone=True), server_default=sa.text('(CURRENT_TIMESTAMP)'), nullable=False),
        sa.ForeignKeyConstraint(['conversation_id'], ['conversations.id'], ondelete='CASCADE'),
        sa.ForeignKeyConstraint(['run_id'], ['tasks.id'], ondelete='SET NULL'),
        sa.PrimaryKeyConstraint('id'),
        sa.UniqueConstraint('conversation_id', 'sequence_num', name='uq_conv_events_conv_id_seq'),
    )
    with op.batch_alter_table('conversation_events', schema=None) as batch_op:
        batch_op.create_index(batch_op.f('ix_conversation_events_conversation_id'), ['conversation_id'], unique=False)
        batch_op.create_index(batch_op.f('ix_conversation_events_run_id'), ['run_id'], unique=False)
        batch_op.create_index(batch_op.f('ix_conversation_events_sequence_num'), ['sequence_num'], unique=False)
        batch_op.create_index(batch_op.f('ix_conversation_events_event_type'), ['event_type'], unique=False)


def downgrade() -> None:
    with op.batch_alter_table('conversation_events', schema=None) as batch_op:
        batch_op.drop_index(batch_op.f('ix_conversation_events_event_type'))
        batch_op.drop_index(batch_op.f('ix_conversation_events_sequence_num'))
        batch_op.drop_index(batch_op.f('ix_conversation_events_run_id'))
        batch_op.drop_index(batch_op.f('ix_conversation_events_conversation_id'))

    op.drop_table('conversation_events')

    with op.batch_alter_table('conversation_messages', schema=None) as batch_op:
        batch_op.drop_index(batch_op.f('ix_conversation_messages_role'))
        batch_op.drop_index(batch_op.f('ix_conversation_messages_run_id'))
        batch_op.drop_index(batch_op.f('ix_conversation_messages_conversation_id'))

    op.drop_table('conversation_messages')

    with op.batch_alter_table('tasks', schema=None) as batch_op:
        batch_op.drop_index(batch_op.f('ix_tasks_conversation_id'))
        batch_op.drop_constraint('fk_tasks_conversation_id', type_='foreignkey')
        batch_op.drop_column('conversation_id')

    with op.batch_alter_table('conversations', schema=None) as batch_op:
        batch_op.drop_index(batch_op.f('ix_conversations_project_id'))

    op.drop_table('conversations')
