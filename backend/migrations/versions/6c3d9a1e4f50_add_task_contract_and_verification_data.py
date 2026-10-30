"""Add require_contract, contract_data, and verification_data to tasks

Revision ID: 6c3d9a1e4f50
Revises: 5b1c8e9f2a34
Create Date: 2026-10-30 00:30:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = '6c3d9a1e4f50'
down_revision: Union[str, Sequence[str], None] = '5b1c8e9f2a34'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    with op.batch_alter_table('tasks', schema=None) as batch_op:
        batch_op.add_column(
            sa.Column('require_contract', sa.Boolean(), server_default=sa.text('0'), nullable=False)
        )
        batch_op.add_column(
            sa.Column('contract_data', sa.JSON(), nullable=True)
        )
        batch_op.add_column(
            sa.Column('verification_data', sa.JSON(), nullable=True)
        )


def downgrade() -> None:
    with op.batch_alter_table('tasks', schema=None) as batch_op:
        batch_op.drop_column('verification_data')
        batch_op.drop_column('contract_data')
        batch_op.drop_column('require_contract')
