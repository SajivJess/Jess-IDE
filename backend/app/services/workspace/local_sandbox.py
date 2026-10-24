import asyncio
import os
import shutil
import time
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional

from app.core.config import settings
from app.core.logging import logger
from app.db.models.project import Project
from app.db.models.workspace import Workspace
from app.schemas.workspace import (
    WorkspaceCommandResponse,
    WorkspaceFileItem,
    WorkspaceGitDiffResponse,
    WorkspaceGitStatusResponse,
    WorkspaceStatus,
)
from app.services.workspace.base import BaseWorkspaceProvider, resolve_secure_path


class LocalSandboxWorkspaceProvider(BaseWorkspaceProvider):
    """Isolated filesystem sandbox workspace provider.
    
    Provides directory containment, path traversal defense, environment sanitization,
    and process execution constraints for local development and non-Docker environments.
    """

    def __init__(self, base_data_dir: Optional[str] = None) -> None:
        self.base_data_dir = Path(base_data_dir or settings.WORKSPACE_DATA_DIR)
        self.base_data_dir.mkdir(parents=True, exist_ok=True)

    def get_workspace_dir(self, workspace_id: Any) -> Path:
        """Resolve workspace root folder."""
        wdir = (self.base_data_dir / str(workspace_id)).resolve()
        wdir.mkdir(parents=True, exist_ok=True)
        return wdir

    async def provision(self, workspace: Workspace, project: Project) -> Dict[str, Any]:
        """Initialize workspace directory, clone repo if configured or create starter files."""
        wdir = self.get_workspace_dir(workspace.id)
        workspace.root_path = str(wdir)
        workspace.host_type = "local_sandbox"

        # Initialize project content
        readme_path = wdir / "README.md"
        if not readme_path.exists():
            readme_content = f"# {project.name}\n\n{project.description or 'Jess Ide Dev Project'}\n"
            readme_path.write_text(readme_content, encoding="utf-8")

        # Handle Git initialization or clone
        try:
            if project.source_type == "github" and project.repo_url:
                # Attempt clone if directory is empty
                entries = list(wdir.iterdir())
                if len(entries) <= 1:  # Only README.md or empty
                    clone_cmd = [
                        "git",
                        "clone",
                        "--depth",
                        "1",
                        "-b",
                        project.default_branch,
                        project.repo_url,
                        str(wdir / "repo_clone"),
                    ]
                    # We run with clean env and timeout
                    proc = await asyncio.create_subprocess_exec(
                        *clone_cmd,
                        stdout=asyncio.subprocess.PIPE,
                        stderr=asyncio.subprocess.PIPE,
                    )
                    await asyncio.wait_for(proc.communicate(), timeout=30)
            else:
                # Initialize local Git repository for version tracking
                git_dir = wdir / ".git"
                if not git_dir.exists():
                    init_proc = await asyncio.create_subprocess_exec(
                        "git",
                        "init",
                        cwd=str(wdir),
                        stdout=asyncio.subprocess.PIPE,
                        stderr=asyncio.subprocess.PIPE,
                    )
                    await asyncio.wait_for(init_proc.communicate(), timeout=10)

                    # Initial commit so git status and diff work cleanly
                    add_proc = await asyncio.create_subprocess_exec(
                        "git", "add", "README.md", cwd=str(wdir)
                    )
                    await add_proc.wait()

                    commit_proc = await asyncio.create_subprocess_exec(
                        "git",
                        "-c",
                        "user.name=Jess Dev",
                        "-c",
                        "user.email=dev@jess.local",
                        "commit",
                        "-m",
                        "Initial project workspace commit",
                        cwd=str(wdir),
                    )
                    await commit_proc.wait()
        except Exception as e:
            logger.warning(f"Git setup exception for workspace {workspace.id}: {e}")

        workspace.status = WorkspaceStatus.RUNNING.value
        workspace.last_heartbeat = datetime.utcnow()
        workspace.connection_info = {
            "provider": "local_sandbox",
            "root_path": str(wdir),
            "docker_available": False,
        }
        return workspace.connection_info

    async def start(self, workspace: Workspace) -> bool:
        wdir = self.get_workspace_dir(workspace.id)
        if not wdir.exists():
            wdir.mkdir(parents=True, exist_ok=True)
        workspace.status = WorkspaceStatus.RUNNING.value
        workspace.last_heartbeat = datetime.utcnow()
        return True

    async def stop(self, workspace: Workspace) -> bool:
        workspace.status = WorkspaceStatus.STOPPED.value
        return True

    async def destroy(self, workspace: Workspace) -> bool:
        wdir = self.get_workspace_dir(workspace.id)
        if wdir.exists():
            shutil.rmtree(str(wdir), ignore_errors=True)
        return True

    def _get_clean_env(self) -> Dict[str, str]:
        """Construct sanitized environment without leaking host secrets, credentials, or keys."""
        safe_keys = {"PATH", "SYSTEMROOT", "WINDIR", "TEMP", "TMP", "HOMEDRIVE", "HOMEPATH"}
        clean = {k: v for k, v in os.environ.items() if k.upper() in safe_keys}
        clean["LANG"] = "C.UTF-8"
        clean["LC_ALL"] = "C.UTF-8"
        return clean

    async def execute_command(
        self,
        workspace: Workspace,
        command: List[str],
        working_dir: Optional[str] = None,
        timeout_seconds: int = 30,
    ) -> WorkspaceCommandResponse:
        """Execute a controlled command inside the workspace directory."""
        if workspace.status != WorkspaceStatus.RUNNING.value:
            raise ValueError(f"Cannot execute command in workspace with status: {workspace.status}")

        root = self.get_workspace_dir(workspace.id)
        cwd = resolve_secure_path(root, working_dir or "")
        start_time = time.time()
        timeout = min(timeout_seconds, settings.WORKSPACE_COMMAND_TIMEOUT_SECONDS)

        try:
            proc = await asyncio.create_subprocess_exec(
                *command,
                cwd=str(cwd),
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                env=self._get_clean_env(),
            )
            stdout_bytes, stderr_bytes = await asyncio.wait_for(
                proc.communicate(), timeout=timeout
            )
            duration_ms = int((time.time() - start_time) * 1000)

            # Cap output sizes to prevent memory exhaustion
            max_bytes = settings.WORKSPACE_MAX_OUTPUT_BYTES
            stdout = stdout_bytes[:max_bytes].decode("utf-8", errors="replace")
            stderr = stderr_bytes[:max_bytes].decode("utf-8", errors="replace")

            return WorkspaceCommandResponse(
                exit_code=proc.returncode or 0,
                stdout=stdout,
                stderr=stderr,
                duration_ms=duration_ms,
                timed_out=False,
            )
        except asyncio.TimeoutError:
            try:
                proc.kill()
                await proc.wait()
            except Exception:
                pass
            duration_ms = int((time.time() - start_time) * 1000)
            return WorkspaceCommandResponse(
                exit_code=-1,
                stdout="",
                stderr=f"Command execution timed out after {timeout} seconds.",
                duration_ms=duration_ms,
                timed_out=True,
            )
        except Exception as e:
            duration_ms = int((time.time() - start_time) * 1000)
            return WorkspaceCommandResponse(
                exit_code=-1,
                stdout="",
                stderr=f"Failed to launch command: {e}",
                duration_ms=duration_ms,
                timed_out=False,
            )

    async def list_files(
        self, workspace: Workspace, relative_path: str = ""
    ) -> List[WorkspaceFileItem]:
        root = self.get_workspace_dir(workspace.id)
        target = resolve_secure_path(root, relative_path)
        if not target.exists() or not target.is_dir():
            return []

        items: List[WorkspaceFileItem] = []
        for entry in target.iterdir():
            # Skip .git internal directory from listing
            if entry.name == ".git":
                continue

            rel_entry_path = str(entry.relative_to(root)).replace("\\", "/")
            stat = entry.stat()
            modified = datetime.fromtimestamp(stat.st_mtime)
            items.append(
                WorkspaceFileItem(
                    name=entry.name,
                    path=rel_entry_path,
                    is_dir=entry.is_dir(),
                    size_bytes=stat.st_size if entry.is_file() else 0,
                    modified_at=modified,
                )
            )

        items.sort(key=lambda x: (not x.is_dir, x.name.lower()))
        return items

    async def read_file(self, workspace: Workspace, relative_path: str) -> str:
        root = self.get_workspace_dir(workspace.id)
        target = resolve_secure_path(root, relative_path)
        if not target.exists() or not target.is_file():
            raise FileNotFoundError(f"File not found: '{relative_path}'")

        # Size check (2MB max)
        if target.stat().st_size > 2 * 1024 * 1024:
            raise ValueError(f"File '{relative_path}' exceeds maximum read size of 2MB.")

        return target.read_text(encoding="utf-8", errors="replace")

    async def write_file(
        self, workspace: Workspace, relative_path: str, content: str
    ) -> None:
        root = self.get_workspace_dir(workspace.id)
        target = resolve_secure_path(root, relative_path)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8")

    async def get_git_status(self, workspace: Workspace) -> WorkspaceGitStatusResponse:
        root = self.get_workspace_dir(workspace.id)
        git_dir = root / ".git"
        if not git_dir.exists():
            return WorkspaceGitStatusResponse(
                branch="main",
                is_clean=True,
                modified_files=[],
                untracked_files=[],
                staged_files=[],
            )

        cmd_res = await self.execute_command(workspace, ["git", "status", "--porcelain=v1", "-b"])
        if cmd_res.exit_code != 0:
            return WorkspaceGitStatusResponse(
                branch="main",
                is_clean=True,
                modified_files=[],
                untracked_files=[],
                staged_files=[],
            )

        branch = "main"
        modified: List[str] = []
        untracked: List[str] = []
        staged: List[str] = []

        lines = cmd_res.stdout.splitlines()
        for line in lines:
            if line.startswith("##"):
                # e.g. ## main...origin/main
                parts = line[2:].strip().split("...")
                if parts:
                    branch = parts[0].strip()
            elif len(line) >= 3:
                x = line[0]
                y = line[1]
                path = line[3:].strip()
                if x in ("M", "A", "D", "R", "C"):
                    staged.append(path)
                if y == "M":
                    modified.append(path)
                elif line.startswith("??"):
                    untracked.append(path)

        is_clean = len(modified) == 0 and len(untracked) == 0 and len(staged) == 0
        return WorkspaceGitStatusResponse(
            branch=branch,
            is_clean=is_clean,
            modified_files=modified,
            untracked_files=untracked,
            staged_files=staged,
        )

    async def get_git_diff(self, workspace: Workspace) -> WorkspaceGitDiffResponse:
        root = self.get_workspace_dir(workspace.id)
        git_dir = root / ".git"
        if not git_dir.exists():
            return WorkspaceGitDiffResponse(diff="", files_changed=0)

        # Run git diff HEAD
        cmd_res = await self.execute_command(workspace, ["git", "diff", "HEAD"])
        if cmd_res.exit_code != 0:
            # Fallback to unstaged diff
            cmd_res = await self.execute_command(workspace, ["git", "diff"])

        diff_text = cmd_res.stdout
        # Count number of files changed (number of 'diff --git' markers)
        files_changed = diff_text.count("diff --git")
        return WorkspaceGitDiffResponse(
            diff=diff_text,
            files_changed=files_changed,
        )

    async def get_logs(self, workspace: Workspace) -> str:
        return f"LocalSandbox workspace active at {workspace.root_path} (Host: {workspace.host_type})"
