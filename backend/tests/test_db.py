import uuid
import pytest
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from app.db.base import Base
from app.db.models.user import User
from app.db.models.workspace import Workspace
from app.db.models.project import Project
from app.db.models.task import Task
from app.db.session import check_db_connection


@pytest.fixture
async def test_db_session():
    """Isolated in-memory async SQLite session fixture."""
    test_engine = create_async_engine(
        "sqlite+aiosqlite:///:memory:",
        connect_args={"check_same_thread": False},
        future=True,
    )

    async with test_engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

    session_factory = async_sessionmaker(
        bind=test_engine,
        class_=AsyncSession,
        expire_on_commit=False,
    )

    async with session_factory() as session:
        yield session

    await test_engine.dispose()


@pytest.mark.asyncio
async def test_check_db_connection_live():
    """Verify that default database connection check succeeds."""
    connected = await check_db_connection()
    assert connected is True


@pytest.mark.asyncio
async def test_user_creation_and_query(test_db_session: AsyncSession):
    """Test creating and retrieving a user model."""
    user = User(
        email="developer@example.com",
        hashed_password="hashed_pw_secret_123",
        full_name="Jess Developer",
    )
    test_db_session.add(user)
    await test_db_session.commit()

    assert isinstance(user.id, uuid.UUID)
    assert user.created_at is not None
    assert user.updated_at is not None
    assert user.is_active is True
    assert user.is_superuser is False

    # Retrieve from DB
    result = await test_db_session.execute(
        select(User).where(User.email == "developer@example.com")
    )
    queried_user = result.scalar_one_or_none()
    assert queried_user is not None
    assert queried_user.id == user.id
    assert queried_user.full_name == "Jess Developer"


@pytest.mark.asyncio
async def test_user_email_unique_constraint(test_db_session: AsyncSession):
    """Test that duplicate emails raise an IntegrityError."""
    user1 = User(
        email="unique@example.com",
        hashed_password="pw1",
    )
    test_db_session.add(user1)
    await test_db_session.commit()

    user2 = User(
        email="unique@example.com",
        hashed_password="pw2",
    )
    test_db_session.add(user2)

    with pytest.raises(IntegrityError):
        await test_db_session.commit()

    await test_db_session.rollback()


@pytest.mark.asyncio
async def test_workspace_creation_and_relationship(test_db_session: AsyncSession):
    """Test creating a workspace associated with a user."""
    user = User(
        email="workspace_user@example.com",
        hashed_password="pw",
        full_name="Workspace User",
    )
    test_db_session.add(user)
    await test_db_session.flush()

    workspace = Workspace(
        user_id=user.id,
        name="Local Development Container",
        host_type="docker",
        status="active",
        connection_info={"port": 8080, "host": "127.0.0.1"},
    )
    test_db_session.add(workspace)
    await test_db_session.commit()

    assert isinstance(workspace.id, uuid.UUID)
    assert workspace.connection_info["port"] == 8080

    # Test relationship
    result = await test_db_session.execute(
        select(User).where(User.id == user.id)
    )
    loaded_user = result.scalar_one()
    # Workspace is linked
    res_ws = await test_db_session.execute(
        select(Workspace).where(Workspace.user_id == loaded_user.id)
    )
    workspaces = res_ws.scalars().all()
    assert len(workspaces) == 1
    assert workspaces[0].name == "Local Development Container"


@pytest.mark.asyncio
async def test_project_and_task_lifecycle(test_db_session: AsyncSession):
    """Test Project creation, Task attachment, status transitions, and cascade delete."""
    user = User(
        email="project_owner@example.com",
        hashed_password="pw",
    )
    test_db_session.add(user)
    await test_db_session.flush()

    project = Project(
        user_id=user.id,
        name="Jess Mobile App",
        description="Flutter Dev Assistant",
        source_type="local",
        workspace_path="/home/workspace/jess_app",
    )
    test_db_session.add(project)
    await test_db_session.flush()

    task = Task(
        project_id=project.id,
        prompt="Implement authentication screens with Flutter",
        status="pending",
    )
    test_db_session.add(task)
    await test_db_session.commit()

    assert task.status == "pending"
    assert isinstance(task.id, uuid.UUID)

    # Update task state
    task.status = "running"
    task.active_branch = "feature/auth"
    task.commit_sha = "a1b2c3d4e5f6"
    await test_db_session.commit()

    refreshed_task = await test_db_session.get(Task, task.id)
    assert refreshed_task.status == "running"
    assert refreshed_task.active_branch == "feature/auth"

    # Verify cascading delete: Deleting project deletes associated tasks
    await test_db_session.delete(project)
    await test_db_session.commit()

    deleted_task = await test_db_session.get(Task, task.id)
    assert deleted_task is None


@pytest.mark.asyncio
async def test_task_workspace_set_null(test_db_session: AsyncSession):
    """Test that deleting a Workspace sets task.workspace_id to NULL rather than deleting task."""
    user = User(email="set_null_test@example.com", hashed_password="pw")
    test_db_session.add(user)
    await test_db_session.flush()

    workspace = Workspace(user_id=user.id, name="Ephemeral Runner", host_type="local")
    project = Project(user_id=user.id, name="Test Project")
    test_db_session.add_all([workspace, project])
    await test_db_session.flush()

    task = Task(
        project_id=project.id,
        workspace_id=workspace.id,
        prompt="Run unit tests",
        status="running",
    )
    test_db_session.add(task)
    await test_db_session.commit()

    assert task.workspace_id == workspace.id

    # Delete workspace
    await test_db_session.delete(workspace)
    await test_db_session.commit()

    # Task still exists with workspace_id set to None
    refreshed_task = await test_db_session.get(Task, task.id)
    assert refreshed_task is not None
    assert refreshed_task.workspace_id is None
