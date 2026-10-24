"""Add project_id and execution environment metadata to workspaces

Revision ID: 4a9c1e7f3b82
Revises: 3f8b7c91a02d
Create Date: 2026-10-25 00:15:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = '4a9c1e7f3b82'
down_revision: Union[str, Sequence[str], None] = '3f8b7c91a02d'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    with op.batch_alter_table('workspaces', schema=None) as batch_op:
        batch_op.add_column(sa.Column('project_id', sa.Uuid(), nullable=True))
        batch_op.add_column(sa.Column('container_id', sa.String(length=100), nullable=True))
        batch_op.add_column(sa.Column('image_name', sa.String(length=200), nullable=True))
        batch_op.add_column(sa.Column('root_path', sa.String(length=512), nullable=True))
        batch_op.add_column(sa.Column('error_message', sa.Text(), nullable=True))
        batch_op.create_foreign_key('fk_workspaces_project_id', 'projects', ['project_id'], ['id'], ondelete='CASCADE')
        batch_op.create_index(batch_op.f('ix_workspaces_project_id'), ['project_id'], unique=False)


def downgrade() -> None:
    with op.batch_alter_table('workspaces', schema=None) as batch_op:
        batch_op.drop_index(batch_op.f('ix_workspaces_project_id'))
        batch_op.drop_constraint('fk_workspaces_project_id', type_='foreignkey')
        batch_op.drop_column('error_message')
        batch_op.drop_column('root_path')
        batch_op.drop_column('image_name')
        batch_op.drop_column('container_id')
        batch_op.drop_column('project_id')
