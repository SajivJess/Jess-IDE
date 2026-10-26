import asyncio
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
from app.services.workspace.base import BaseWorkspaceProvider
from app.services.workspace.local_sandbox import LocalSandboxWorkspaceProvider


class DockerWorkspaceProvider(BaseWorkspaceProvider):
    """Docker container-based workspace provider for production isolation.
    
    Provisions isolated containers, applies CPU/memory quotas, mounts only the project
    directory, prevents Docker socket exposure, and provides graceful fallback when Docker
    is not installed on the host.
    """

    def __init__(self, fallback_provider: Optional[BaseWorkspaceProvider] = None) -> None:
        self.fallback = fallback_provider or LocalSandboxWorkspaceProvider()
        self._is_docker_available: Optional[bool] = None

    async def check_docker_available(self) -> bool:
        """Check if Docker CLI or daemon responds."""
        if self._is_docker_available is not None:
            return self._is_docker_available

        try:
            proc = await asyncio.create_subprocess_exec(
                "docker",
                "version",
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            _, _ = await asyncio.wait_for(proc.communicate(), timeout=3)
            self._is_docker_available = (proc.returncode == 0)
        except Exception:
            self._is_docker_available = False

        return self._is_docker_available

    async def provision(self, workspace: Workspace, project: Project) -> Dict[str, Any]:
        has_docker = await self.check_docker_available()
        if not has_docker:
            if getattr(workspace, "provider_type", None) == "docker" or getattr(settings, "REQUIRE_DOCKER_ISOLATION", False):
                err_msg = (
                    f"Docker isolation is strictly required for workspace {workspace.id}, "
                    "but Docker CLI/daemon is unavailable on this host. "
                    "Silent host fallback is refused for safety."
                )
                logger.error(err_msg)
                raise RuntimeError(err_msg)

            logger.warning(
                f"Docker is not available on this host. Falling back to LocalSandbox for workspace {workspace.id}. "
                "Notice: Execution will run in isolated local directory, not a Docker container."
            )
            res = await self.fallback.provision(workspace, project)
            workspace.host_type = "local_sandbox"
            return res

        # Docker is available on the host
        # Ensure project directory is prepared first
        await self.fallback.provision(workspace, project)
        host_dir = workspace.root_path or str(Path(settings.WORKSPACE_DATA_DIR) / str(workspace.id))
        image = workspace.image_name or settings.DEFAULT_WORKSPACE_IMAGE
        container_name = f"jess_ws_{str(workspace.id)[:8]}"

        try:
            # Run docker container in background with security & resource constraints:
            # - --memory 1g
            # - --cpus 1.0
            # - --pids-limit 100
            # - -v host_dir:/workspace
            # - -w /workspace
            # - No docker socket access
            run_cmd = [
                "docker",
                "run",
                "-d",
                "--name",
                container_name,
                "--memory",
                "1g",
                "--cpus",
                "1.0",
                "--pids-limit",
                "100",
                "-v",
                f"{host_dir}:/workspace",
                "-w",
                "/workspace",
                image,
                "sleep",
                "infinity",
            ]
            proc = await asyncio.create_subprocess_exec(
                *run_cmd,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=20)
            if proc.returncode == 0:
                cid = stdout.decode().strip()[:12]
                workspace.container_id = cid
                workspace.status = WorkspaceStatus.RUNNING.value
                workspace.host_type = "docker"
                workspace.connection_info = {
                    "provider": "docker",
                    "container_id": cid,
                    "container_name": container_name,
                    "image": image,
                    "root_path": host_dir,
                    "docker_available": True,
                }
                return workspace.connection_info
            else:
                err_msg = stderr.decode()
                logger.warning(f"Failed to launch Docker container: {err_msg}. Using local sandbox.")
                workspace.host_type = "local_sandbox"
                return workspace.connection_info or {}
        except Exception as e:
            logger.warning(f"Docker provisioning exception: {e}. Defaulting to local sandbox.")
            workspace.host_type = "local_sandbox"
            return workspace.connection_info or {}

    async def start(self, workspace: Workspace) -> bool:
        if workspace.container_id and await self.check_docker_available():
            proc = await asyncio.create_subprocess_exec("docker", "start", workspace.container_id)
            await proc.wait()
            workspace.status = WorkspaceStatus.RUNNING.value
            return True
        return await self.fallback.start(workspace)

    async def stop(self, workspace: Workspace) -> bool:
        if workspace.container_id and await self.check_docker_available():
            proc = await asyncio.create_subprocess_exec("docker", "stop", workspace.container_id)
            await proc.wait()
            workspace.status = WorkspaceStatus.STOPPED.value
            return True
        return await self.fallback.stop(workspace)

    async def destroy(self, workspace: Workspace) -> bool:
        if workspace.container_id and await self.check_docker_available():
            try:
                proc = await asyncio.create_subprocess_exec(
                    "docker", "rm", "-f", workspace.container_id
                )
                await proc.wait()
            except Exception:
                pass
        return await self.fallback.destroy(workspace)

    async def execute_command(
        self,
        workspace: Workspace,
        command: List[str],
        working_dir: Optional[str] = None,
        timeout_seconds: int = 30,
    ) -> WorkspaceCommandResponse:
        # If running inside a container, execute via `docker exec`
        if workspace.container_id and await self.check_docker_available():
            exec_cmd = ["docker", "exec"]
            if working_dir:
                exec_cmd.extend(["-w", f"/workspace/{working_dir.strip().lstrip('/')}"])
            exec_cmd.append(workspace.container_id)
            exec_cmd.extend(command)

            try:
                proc = await asyncio.create_subprocess_exec(
                    *exec_cmd,
                    stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.PIPE,
                )
                stdout_b, stderr_b = await asyncio.wait_for(
                    proc.communicate(), timeout=timeout_seconds
                )
                return WorkspaceCommandResponse(
                    exit_code=proc.returncode or 0,
                    stdout=stdout_b.decode("utf-8", errors="replace"),
                    stderr=stderr_b.decode("utf-8", errors="replace"),
                    duration_ms=100,
                    timed_out=False,
                )
            except asyncio.TimeoutError:
                return WorkspaceCommandResponse(
                    exit_code=-1,
                    stdout="",
                    stderr="Command timed out in container.",
                    duration_ms=timeout_seconds * 1000,
                    timed_out=True,
                )
            except Exception as e:
                logger.warning(f"docker exec failed ({e}), falling back to local sandbox execution.")

        return await self.fallback.execute_command(
            workspace, command, working_dir, timeout_seconds
        )

    async def list_files(
        self, workspace: Workspace, relative_path: str = ""
    ) -> List[WorkspaceFileItem]:
        return await self.fallback.list_files(workspace, relative_path)

    async def read_file(self, workspace: Workspace, relative_path: str) -> str:
        return await self.fallback.read_file(workspace, relative_path)

    async def write_file(
        self, workspace: Workspace, relative_path: str, content: str
    ) -> None:
        return await self.fallback.write_file(workspace, relative_path, content)

    async def get_git_status(self, workspace: Workspace) -> WorkspaceGitStatusResponse:
        return await self.fallback.get_git_status(workspace)

    async def get_git_diff(self, workspace: Workspace) -> WorkspaceGitDiffResponse:
        return await self.fallback.get_git_diff(workspace)

    async def get_logs(self, workspace: Workspace) -> str:
        if workspace.container_id and await self.check_docker_available():
            proc = await asyncio.create_subprocess_exec(
                "docker",
                "logs",
                "--tail",
                "100",
                workspace.container_id,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            stdout, stderr = await proc.communicate()
            return stdout.decode() or stderr.decode() or "No container logs."
        return await self.fallback.get_logs(workspace)
