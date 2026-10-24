from typing import Optional
from app.services.workspace.base import BaseWorkspaceProvider
from app.services.workspace.docker_provider import DockerWorkspaceProvider
from app.services.workspace.local_sandbox import LocalSandboxWorkspaceProvider

# Singleton provider instances
_local_provider = LocalSandboxWorkspaceProvider()
_docker_provider = DockerWorkspaceProvider(fallback_provider=_local_provider)


def get_workspace_provider(provider_type: Optional[str] = None) -> BaseWorkspaceProvider:
    """Retrieve workspace provider based on configuration or auto-detection.
    
    Returns DockerWorkspaceProvider (which auto-detects Docker daemon and falls back
    to LocalSandboxWorkspaceProvider safely) or explicit LocalSandboxWorkspaceProvider.
    """
    if provider_type == "local_sandbox":
        return _local_provider
    # Default to docker provider (which handles docker detection and safe fallback)
    return _docker_provider
