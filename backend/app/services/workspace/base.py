import os
from abc import ABC, abstractmethod
from pathlib import Path
from typing import Any, Dict, List, Optional

from app.db.models.project import Project
from app.db.models.workspace import Workspace
from app.schemas.workspace import (
    WorkspaceCommandResponse,
    WorkspaceFileItem,
    WorkspaceGitDiffResponse,
    WorkspaceGitStatusResponse,
)


def resolve_secure_path(base_dir: Path, requested_path: str) -> Path:
    r"""Resolve a requested relative path against base_dir and guarantee strict containment.
    
    Rejects:
    - Absolute paths (/etc/..., C:\...)
    - Path traversal (../../)
    - Symlink escapes
    """
    clean = requested_path.strip().lstrip("/").lstrip("\\")
    if os.path.isabs(requested_path) or requested_path.startswith("/") or requested_path.startswith("\\"):
        raise ValueError("Absolute paths are prohibited. All paths must be relative to workspace root.")

    if len(requested_path) >= 2 and requested_path[1] == ":":
        raise ValueError("Drive-letter paths are prohibited.")

    base_resolved = base_dir.resolve()
    target_resolved = (base_dir / clean).resolve()

    try:
        common = os.path.commonpath([str(base_resolved), str(target_resolved)])
    except ValueError:
        raise ValueError(f"Path traversal attempt detected: '{requested_path}' escapes workspace root.")

    if common != str(base_resolved):
        raise ValueError(f"Path traversal attempt detected: '{requested_path}' escapes workspace root.")

    return target_resolved


class BaseWorkspaceProvider(ABC):
    """Abstract provider interface for isolated project execution environments."""

    @abstractmethod
    async def provision(self, workspace: Workspace, project: Project) -> Dict[str, Any]:
        """Create and initialize the workspace environment and project files."""
        pass

    @abstractmethod
    async def start(self, workspace: Workspace) -> bool:
        """Start the stopped workspace container or process sandbox."""
        pass

    @abstractmethod
    async def stop(self, workspace: Workspace) -> bool:
        """Stop the running workspace container or process sandbox."""
        pass

    @abstractmethod
    async def destroy(self, workspace: Workspace) -> bool:
        """Clean up all containers, volumes, and temporary files allocated to workspace."""
        pass

    @abstractmethod
    async def execute_command(
        self,
        workspace: Workspace,
        command: List[str],
        working_dir: Optional[str] = None,
        timeout_seconds: int = 30,
    ) -> WorkspaceCommandResponse:
        """Execute a structured command inside the isolated workspace."""
        pass

    @abstractmethod
    async def list_files(
        self, workspace: Workspace, relative_path: str = ""
    ) -> List[WorkspaceFileItem]:
        """List files and directories inside the workspace."""
        pass

    @abstractmethod
    async def read_file(self, workspace: Workspace, relative_path: str) -> str:
        """Read text file contents from workspace."""
        pass

    @abstractmethod
    async def write_file(
        self, workspace: Workspace, relative_path: str, content: str
    ) -> None:
        """Write content to a file inside the workspace."""
        pass

    @abstractmethod
    async def get_git_status(self, workspace: Workspace) -> WorkspaceGitStatusResponse:
        """Query Git status inside the workspace."""
        pass

    @abstractmethod
    async def get_git_diff(self, workspace: Workspace) -> WorkspaceGitDiffResponse:
        """Query Git diff inside the workspace."""
        pass

    @abstractmethod
    async def get_logs(self, workspace: Workspace) -> str:
        """Retrieve recent logs emitted by the workspace environment."""
        pass
