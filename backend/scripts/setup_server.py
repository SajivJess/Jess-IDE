"""Turnkey server initialization script for fresh machine deployments.

1. Creates database tables if they do not exist.
2. Seeds demo user `dev@jess.dev` (password: `password123`).
3. Creates disposable sample demo repo in `workspaces_data/verification_test_repo` with baseline bug.
4. Registers `Calculator Demo Repo` project pointing dynamically to the local repo.
"""

import asyncio
import os
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

# Add backend directory to sys.path
backend_dir = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(backend_dir))

from sqlalchemy import select
from app.db.base import Base
from app.db.session import engine, async_session_maker
from app.db.models import User, Project
from app.core.security import hash_password


async def init_database():
    print("[1/4] Ensuring database schema exists...")
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    print("      Schema verified.")


async def seed_demo_user():
    print("[2/4] Ensuring demo user exists (dev@jess.dev)...")
    async with async_session_maker() as session:
        result = await session.execute(select(User).where(User.email == "dev@jess.dev"))
        user = result.scalar_one_or_none()
        if not user:
            user = User(
                email="dev@jess.dev",
                hashed_password=hash_password("password123"),
                full_name="Jess Developer",
                is_active=True,
                is_verified=True,
            )
            session.add(user)
            await session.commit()
            await session.refresh(user)
            print(f"      Created demo user: dev@jess.dev (ID: {user.id})")
        else:
            print(f"      Demo user already exists (ID: {user.id})")
        return user.id


def setup_demo_workspace(reset: bool = False):
    print("[3/4] Initializing demo workspace (verification_test_repo)...")
    ws_dir = (backend_dir / "workspaces_data" / "verification_test_repo").resolve()
    ws_dir.mkdir(parents=True, exist_ok=True)

    calc_file = ws_dir / "calculator.py"
    test_file = ws_dir / "test_calculator.py"

    if calc_file.exists() and test_file.exists() and not reset:
        print(f"      Preserving existing workspace files at {ws_dir} (pass --reset to re-seed).")
    else:
        calc_file.write_text(
            "def add(a, b):\n    return a - b  # BUG: subtraction instead of addition\n",
            encoding="utf-8",
        )
        test_file.write_text(
            "import unittest\n"
            "from calculator import add\n\n"
            "class TestCalc(unittest.TestCase):\n"
            "    def test_add(self):\n"
            "        self.assertEqual(add(2, 3), 5)\n\n"
            "if __name__ == '__main__':\n"
            "    unittest.main()\n",
            encoding="utf-8",
        )
        print(f"      Seeded demo files at {ws_dir}")

    # Initialize git repo if not already initialized
    git_dir = ws_dir / ".git"
    if not git_dir.exists():
        subprocess.run(["git", "init"], cwd=str(ws_dir), check=True, capture_output=True)
        subprocess.run(
            ["git", "-c", "user.name=Jess Demo", "-c", "user.email=demo@jess.local", "add", "."],
            cwd=str(ws_dir),
            check=True,
            capture_output=True,
        )
        subprocess.run(
            ["git", "-c", "user.name=Jess Demo", "-c", "user.email=demo@jess.local", "commit", "-m", "baseline with bug"],
            cwd=str(ws_dir),
            check=True,
            capture_output=True,
        )
        print(f"      Initialized Git repo at {ws_dir}")
    else:
        print(f"      Git repo already present at {ws_dir}")

    return str(ws_dir)


async def link_project(user_id, ws_path: str):
    print("[4/4] Linking 'Calculator Demo Repo' to user...")
    import uuid as _uuid
    if isinstance(user_id, str):
        user_id = _uuid.UUID(user_id)
    async with async_session_maker() as session:
        result = await session.execute(
            select(Project).where(
                Project.user_id == user_id,
                Project.name == "Calculator Demo Repo",
            )
        )
        proj = result.scalar_one_or_none()
        if not proj:
            proj = Project(
                user_id=user_id,
                name="Calculator Demo Repo",
                description="Demonstration repo for autonomous test failure diagnosis and repair",
                source_type="local",
                default_branch="master",
                workspace_path=ws_path,
            )
            session.add(proj)
            await session.commit()
            print("      Created project 'Calculator Demo Repo'.")
        else:
            proj.workspace_path = ws_path
            await session.commit()
            print("      Updated workspace path for 'Calculator Demo Repo'.")


async def main():
    import argparse
    parser = argparse.ArgumentParser(description="MuseFlow Server Turnkey Setup")
    parser.add_argument("--reset", action="store_true", help="Force overwrite/reset demo workspace files")
    args = parser.parse_args()

    print("=" * 60)
    print("MuseFlow Server Setup")
    print("=" * 60)
    await init_database()
    user_id = await seed_demo_user()
    ws_path = setup_demo_workspace(reset=args.reset)
    await link_project(user_id, ws_path)
    print("=" * 60)
    print("Setup completed successfully!")
    print("You can now start the backend with:")
    print("    uvicorn app.main:app --host 0.0.0.0 --port 8000")
    print("=" * 60)


if __name__ == "__main__":
    asyncio.run(main())
