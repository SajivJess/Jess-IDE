import asyncio
import os
import shutil
import time
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional

import re

from app.core.config import settings
from app.core.logging import logger
from app.db.models.project import Project
from app.db.models.workspace import Workspace
from app.schemas.workspace import (
    WorkspaceCommandResponse,
    WorkspaceFileItem,
    WorkspaceGitBranchItem,
    WorkspaceGitBranchesResponse,
    WorkspaceGitCommitResponse,
    WorkspaceGitDiffResponse,
    WorkspaceGitFileDiff,
    WorkspaceGitStatusResponse,
    WorkspaceStatus,
)
from app.services.workspace.base import BaseWorkspaceProvider, resolve_secure_path


ALLOWLISTED_COMMANDS = {
    "python", "python3", "pytest", "unittest", "flutter", "dart",
    "git", "npm", "node", "npx", "pip", "cargo", "go", "mvn", "gradle",
    "cat", "ls", "dir", "echo",
}


class LocalSandboxWorkspaceProvider(BaseWorkspaceProvider):
    """Isolated filesystem sandbox workspace provider.
    
    Provides directory containment, path traversal defense, environment sanitization,
    and process execution constraints for local development and non-Docker environments.
    """

    def __init__(self, base_data_dir: Optional[str] = None) -> None:
        self.base_data_dir = Path(base_data_dir or settings.WORKSPACE_DATA_DIR)
        self.base_data_dir.mkdir(parents=True, exist_ok=True)

    def get_workspace_dir(self, workspace_or_id: Any) -> Path:
        """Resolve workspace root folder, prioritizing project-assigned workspace paths."""
        if isinstance(workspace_or_id, Workspace) and workspace_or_id.root_path:
            p = Path(workspace_or_id.root_path).resolve()
            if p.exists():
                return p
        ws_id = getattr(workspace_or_id, "id", workspace_or_id)
        wdir = (self.base_data_dir / str(ws_id)).resolve()
        wdir.mkdir(parents=True, exist_ok=True)
        return wdir

    async def provision(self, workspace: Workspace, project: Project) -> Dict[str, Any]:
        """Initialize workspace directory, honoring project workspace_path or creating sandboxed files."""
        if project.workspace_path and Path(project.workspace_path).resolve().exists():
            wdir = Path(project.workspace_path).resolve()
        else:
            wdir = self.get_workspace_dir(workspace)
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

        if not command:
            raise ValueError("Command cannot be empty.")

        binary_raw = command[0]
        binary = Path(binary_raw).stem.lower()
        if binary not in ALLOWLISTED_COMMANDS:
            return WorkspaceCommandResponse(
                exit_code=1,
                stdout="",
                stderr=f"Command '{binary}' is not permitted by workspace sandbox allowlist.",
                duration_ms=0,
                timed_out=False,
            )

        root = self.get_workspace_dir(workspace)
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
        root = self.get_workspace_dir(workspace)
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
        clean_rel = relative_path.strip().replace("\\", "/").lstrip("/")
        if clean_rel == ".env" or clean_rel.startswith(".env.") or "/.env" in clean_rel:
            raise ValueError(f"Reading protected secret file '{relative_path}' is prohibited.")

        root = self.get_workspace_dir(workspace)
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
        clean_rel = relative_path.strip().replace("\\", "/").lstrip("/")
        if (
            clean_rel == ".env"
            or clean_rel.startswith(".env.")
            or "/.env" in clean_rel
            or clean_rel == ".git"
            or clean_rel.startswith(".git/")
            or "/.git" in clean_rel
        ):
            raise ValueError(f"Modification of protected path '{relative_path}' is prohibited.")

        root = self.get_workspace_dir(workspace)
        target = resolve_secure_path(root, relative_path)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8")

    async def get_git_status(self, workspace: Workspace) -> WorkspaceGitStatusResponse:
        root = self.get_workspace_dir(workspace)
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

    def _parse_unified_diff(self, diff_text: str) -> List[WorkspaceGitFileDiff]:
        """Parse unified diff text into individual file diff structures."""
        if not diff_text.strip():
            return []

        chunks = re.split(r"(?=^diff --git )", diff_text, flags=re.MULTILINE)
        file_diffs: List[WorkspaceGitFileDiff] = []

        for chunk in chunks:
            chunk = chunk.strip()
            if not chunk.startswith("diff --git "):
                continue

            lines = chunk.splitlines()
            first_line = lines[0]
            # e.g. diff --git a/app/main.py b/app/main.py
            m = re.match(r"^diff --git a/(.+?) b/(.+?)$", first_line)
            file_path = m.group(2) if m else "unknown"

            status = "modified"
            if "new file mode" in chunk:
                status = "added"
            elif "deleted file mode" in chunk:
                status = "deleted"

            additions = sum(1 for l in lines if l.startswith("+") and not l.startswith("+++"))
            deletions = sum(1 for l in lines if l.startswith("-") and not l.startswith("---"))

            file_diffs.append(
                WorkspaceGitFileDiff(
                    path=file_path,
                    status=status,
                    additions=additions,
                    deletions=deletions,
                    patch=chunk,
                )
            )

        return file_diffs

    async def get_git_diff(self, workspace: Workspace) -> WorkspaceGitDiffResponse:
        root = self.get_workspace_dir(workspace)
        git_dir = root / ".git"
        if not git_dir.exists():
            return WorkspaceGitDiffResponse(diff="", files_changed=0, additions=0, deletions=0, files=[])

        # 1. Run git diff HEAD
        cmd_res = await self.execute_command(workspace, ["git", "diff", "HEAD"])
        if cmd_res.exit_code != 0:
            # Fallback to unstaged diff (e.g. before initial commit)
            cmd_res = await self.execute_command(workspace, ["git", "diff"])

        diff_parts: List[str] = [cmd_res.stdout.strip()] if cmd_res.stdout.strip() else []

        # 2. Capture untracked files and synthesize diffs so all newly created files appear
        status_res = await self.execute_command(workspace, ["git", "status", "--porcelain=v1"])
        if status_res.exit_code == 0:
            for s_line in status_res.stdout.splitlines():
                if s_line.startswith("?? "):
                    u_rel = s_line[3:].strip()
                    # Skip .env and internal paths
                    if u_rel.startswith(".env") or "/.env" in u_rel or u_rel.startswith(".git"):
                        continue
                    target_file = root / u_rel
                    if target_file.exists() and target_file.is_file():
                        try:
                            # Only include files under 500KB
                            if target_file.stat().st_size <= 500 * 1024:
                                content = target_file.read_text(encoding="utf-8", errors="replace")
                                file_lines = content.splitlines()
                                patch_hdr = (
                                    f"diff --git a/{u_rel} b/{u_rel}\n"
                                    f"new file mode 100644\n"
                                    f"--- /dev/null\n"
                                    f"+++ b/{u_rel}\n"
                                    f"@@ -0,0 +1,{max(1, len(file_lines))} @@\n"
                                )
                                patch_body = "\n".join("+" + l for l in file_lines)
                                diff_parts.append(patch_hdr + patch_body)
                        except Exception:
                            pass

        unified_diff = "\n\n".join(p for p in diff_parts if p.strip()).strip()
        parsed_files = self._parse_unified_diff(unified_diff)

        total_add = sum(f.additions for f in parsed_files)
        total_del = sum(f.deletions for f in parsed_files)

        return WorkspaceGitDiffResponse(
            diff=unified_diff,
            files_changed=len(parsed_files),
            additions=total_add,
            deletions=total_del,
            files=parsed_files,
        )

    async def get_git_branches(self, workspace: Workspace) -> WorkspaceGitBranchesResponse:
        root = self.get_workspace_dir(workspace)
        git_dir = root / ".git"
        if not git_dir.exists():
            return WorkspaceGitBranchesResponse(
                current_branch="main",
                branches=[WorkspaceGitBranchItem(name="main", is_current=True)],
            )

        # 1. Get current branch
        curr_res = await self.execute_command(workspace, ["git", "branch", "--show-current"])
        current_branch = curr_res.stdout.strip()
        if not current_branch:
            # Check if repo has HEAD commit or detached
            rev_res = await self.execute_command(workspace, ["git", "rev-parse", "--short", "HEAD"])
            current_branch = rev_res.stdout.strip() or "main"

        # 2. List all branches with SHA and commit message
        list_res = await self.execute_command(
            workspace,
            ["git", "branch", "--list", "--format=%(refname:short)|%(objectname:short)|%(contents:subject)"],
        )

        branch_items: List[WorkspaceGitBranchItem] = []
        if list_res.exit_code == 0 and list_res.stdout.strip():
            for line in list_res.stdout.splitlines():
                if not line.strip():
                    continue
                parts = line.strip().split("|", 2)
                b_name = parts[0].strip()
                b_sha = parts[1].strip() if len(parts) > 1 else None
                b_msg = parts[2].strip() if len(parts) > 2 else None

                branch_items.append(
                    WorkspaceGitBranchItem(
                        name=b_name,
                        is_current=(b_name == current_branch),
                        commit_sha=b_sha,
                        commit_message=b_msg,
                    )
                )

        if not branch_items:
            branch_items.append(WorkspaceGitBranchItem(name=current_branch, is_current=True))

        return WorkspaceGitBranchesResponse(
            current_branch=current_branch,
            branches=branch_items,
        )

    async def checkout_git_branch(
        self, workspace: Workspace, branch: str, create_new: bool = False
    ) -> WorkspaceGitStatusResponse:
        clean = branch.strip()
        # Security validation against branch name manipulation / command injection
        if not re.match(r"^[a-zA-Z0-9_\-\./]+$", clean):
            raise ValueError(
                f"Invalid branch name '{branch}'. Branch names may only contain alphanumeric characters, hyphens, underscores, dots, and slashes."
            )
        if ".." in clean or clean.startswith("/") or clean.startswith("-") or clean.endswith("/") or clean.endswith(".lock"):
            raise ValueError(f"Prohibited branch name '{branch}'.")

        cmd = ["git", "checkout"]
        if create_new:
            cmd.extend(["-b", clean])
        else:
            cmd.append(clean)

        res = await self.execute_command(workspace, cmd)
        if res.exit_code != 0:
            err = res.stderr.strip() or res.stdout.strip() or f"Failed to checkout branch '{clean}'"
            raise ValueError(err)

        logger.info(f"[WorkspaceGit] Checked out branch '{clean}' (create_new={create_new}) in workspace {workspace.id}")
        return await self.get_git_status(workspace)

    async def commit_git_changes(
        self,
        workspace: Workspace,
        message: str,
        author_name: Optional[str] = None,
        author_email: Optional[str] = None,
    ) -> WorkspaceGitCommitResponse:
        clean_msg = message.strip()
        if not clean_msg:
            raise ValueError("Commit message cannot be empty.")

        # Stage all working tree files
        add_res = await self.execute_command(workspace, ["git", "add", "-A"])
        if add_res.exit_code != 0:
            raise ValueError(f"Failed to stage changes: {add_res.stderr.strip()}")

        cmd = ["git"]
        if author_name:
            clean_author = re.sub(r'[\r\n"\'\\]', '', author_name).strip()
            if clean_author:
                cmd.extend(["-c", f"user.name={clean_author}"])
        if author_email:
            clean_email = re.sub(r'[\r\n"\'\\]', '', author_email).strip()
            if clean_email:
                cmd.extend(["-c", f"user.email={clean_email}"])

        cmd.extend(["commit", "-m", clean_msg])
        commit_res = await self.execute_command(workspace, cmd)

        if commit_res.exit_code != 0:
            if "nothing to commit" in commit_res.stdout.lower() or "nothing to commit" in commit_res.stderr.lower():
                rev_res = await self.execute_command(workspace, ["git", "rev-parse", "HEAD"])
                curr_res = await self.execute_command(workspace, ["git", "branch", "--show-current"])
                return WorkspaceGitCommitResponse(
                    success=True,
                    commit_sha=rev_res.stdout.strip()[:8] if rev_res.stdout.strip() else "",
                    branch=curr_res.stdout.strip() or "main",
                    message="Working tree already clean; nothing to commit.",
                    files_committed=[],
                )
            raise ValueError(f"Commit failed: {commit_res.stderr.strip() or commit_res.stdout.strip()}")

        # Retrieve new commit SHA and branch
        sha_res = await self.execute_command(workspace, ["git", "rev-parse", "HEAD"])
        curr_res = await self.execute_command(workspace, ["git", "branch", "--show-current"])

        # Retrieve committed files list
        files_res = await self.execute_command(workspace, ["git", "diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD"])
        committed_files = [f.strip() for f in files_res.stdout.splitlines() if f.strip()]

        commit_sha = sha_res.stdout.strip()
        branch_name = curr_res.stdout.strip() or "main"

        logger.info(f"[WorkspaceGit] Committed {len(committed_files)} file(s) ({commit_sha[:8]} on `{branch_name}`): {clean_msg}")
        return WorkspaceGitCommitResponse(
            success=True,
            commit_sha=commit_sha,
            branch=branch_name,
            message=clean_msg,
            files_committed=committed_files,
        )

    async def get_logs(self, workspace: Workspace) -> str:
        return f"LocalSandbox workspace active at {workspace.root_path} (Host: {workspace.host_type})"
