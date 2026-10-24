import time
import uuid
import pytest
from fastapi.testclient import TestClient

from app.core.config import settings
from app.main import app
from app.schemas.task import TaskStatus
from app.schemas.workspace import WorkspaceStatus


@pytest.fixture
def client():
    with TestClient(app) as test_client:
        yield test_client


def create_user_and_project(client: TestClient, prefix: str = "ws_user") -> tuple[str, str, str]:
    email = f"{prefix}_{int(time.time() * 1000)}_{uuid.uuid4().hex[:6]}@example.com"
    password = "SecurePassword123!"

    reg_res = client.post(
        f"{settings.API_V1_STR}/auth/register",
        json={"email": email, "password": password, "full_name": f"{prefix} tester"},
    )
    assert reg_res.status_code == 201

    login_res = client.post(
        f"{settings.API_V1_STR}/auth/login",
        json={"email": email, "password": password},
    )
    user_id = reg_res.json()["user"]["id"]
    token = login_res.json()["access_token"]

    headers = {"Authorization": f"Bearer {token}"}
    proj_res = client.post(
        f"{settings.API_V1_STR}/projects",
        json={
            "name": f"{prefix} Project",
            "source_type": "scratch",
            "default_branch": "main",
        },
        headers=headers,
    )
    assert proj_res.status_code == 201
    project_id = proj_res.json()["id"]

    return user_id, token, project_id


def test_workspace_provisioning_and_lifecycle(client: TestClient):
    """Verify workspace creation, status transitions, start, stop, restart, and deletion."""
    _, token, proj_id = create_user_and_project(client, "lifecycle_user")
    headers = {"Authorization": f"Bearer {token}"}

    # 1. Provision workspace
    prov_res = client.post(
        f"{settings.API_V1_STR}/projects/{proj_id}/workspaces",
        json={"name": "Dev Sandbox", "provider_type": "local_sandbox"},
        headers=headers,
    )
    assert prov_res.status_code == 201
    ws = prov_res.json()
    ws_id = ws["id"]
    assert ws["name"] == "Dev Sandbox"
    assert ws["status"] == WorkspaceStatus.RUNNING.value
    assert ws["root_path"] is not None

    # 2. List workspaces for project
    list_res = client.get(
        f"{settings.API_V1_STR}/projects/{proj_id}/workspaces",
        headers=headers,
    )
    assert list_res.status_code == 200
    assert any(item["id"] == ws_id for item in list_res.json()["items"])

    # 3. Stop workspace
    stop_res = client.post(
        f"{settings.API_V1_STR}/projects/{proj_id}/workspaces/{ws_id}/stop",
        headers=headers,
    )
    assert stop_res.status_code == 200
    assert stop_res.json()["status"] == WorkspaceStatus.STOPPED.value

    # 4. Start workspace
    start_res = client.post(
        f"{settings.API_V1_STR}/projects/{proj_id}/workspaces/{ws_id}/start",
        headers=headers,
    )
    assert start_res.status_code == 200
    assert start_res.json()["status"] == WorkspaceStatus.RUNNING.value

    # 5. Restart workspace
    restart_res = client.post(
        f"{settings.API_V1_STR}/projects/{proj_id}/workspaces/{ws_id}/restart",
        headers=headers,
    )
    assert restart_res.status_code == 200
    assert restart_res.json()["status"] == WorkspaceStatus.RUNNING.value

    # 6. Delete workspace
    del_res = client.delete(
        f"{settings.API_V1_STR}/projects/{proj_id}/workspaces/{ws_id}",
        headers=headers,
    )
    assert del_res.status_code == 200
    assert del_res.json()["status"] == "deleted"

    # 7. Check 404 after deletion
    get_res = client.get(
        f"{settings.API_V1_STR}/workspaces/{ws_id}",
        headers=headers,
    )
    assert get_res.status_code == 404


def test_workspace_cross_user_isolation(client: TestClient):
    """Verify that User B cannot access, control, or execute commands in User A's workspace."""
    _, token_a, proj_a = create_user_and_project(client, "owner_a")
    _, token_b, _ = create_user_and_project(client, "intruder_b")

    headers_a = {"Authorization": f"Bearer {token_a}"}
    headers_b = {"Authorization": f"Bearer {token_b}"}

    # User A provisions workspace
    prov_res = client.post(
        f"{settings.API_V1_STR}/projects/{proj_a}/workspaces",
        json={"name": "Owner A Workspace"},
        headers=headers_a,
    )
    assert prov_res.status_code == 201
    ws_id = prov_res.json()["id"]

    # User B attempts to access directly
    get_res = client.get(
        f"{settings.API_V1_STR}/workspaces/{ws_id}",
        headers=headers_b,
    )
    assert get_res.status_code == 404

    # User B attempts to stop User A's workspace
    stop_res = client.post(
        f"{settings.API_V1_STR}/projects/{proj_a}/workspaces/{ws_id}/stop",
        headers=headers_b,
    )
    assert stop_res.status_code == 404

    # User B attempts to run a command
    run_res = client.post(
        f"{settings.API_V1_STR}/projects/{proj_a}/workspaces/{ws_id}/commands/run",
        json={"command": ["echo", "unauthorized"]},
        headers=headers_b,
    )
    assert run_res.status_code == 404

    # User B attempts to list files
    files_res = client.get(
        f"{settings.API_V1_STR}/projects/{proj_a}/workspaces/{ws_id}/files",
        headers=headers_b,
    )
    assert files_res.status_code == 404


def test_workspace_safe_command_execution(client: TestClient):
    """Verify structured command execution, timeout enforcement, and stopped state protection."""
    _, token, proj_id = create_user_and_project(client, "cmd_runner")
    headers = {"Authorization": f"Bearer {token}"}

    prov_res = client.post(
        f"{settings.API_V1_STR}/projects/{proj_id}/workspaces",
        json={"name": "Command Test Workspace"},
        headers=headers,
    )
    ws_id = prov_res.json()["id"]

    # Run successful python command
    cmd_res = client.post(
        f"{settings.API_V1_STR}/projects/{proj_id}/workspaces/{ws_id}/commands/run",
        json={"command": ["python", "-c", "print('hello from sandbox')"]},
        headers=headers,
    )
    assert cmd_res.status_code == 200
    data = cmd_res.json()
    assert data["exit_code"] == 0
    assert "hello from sandbox" in data["stdout"]
    assert data["timed_out"] is False

    # Test execution timeout
    timeout_res = client.post(
        f"{settings.API_V1_STR}/projects/{proj_id}/workspaces/{ws_id}/commands/run",
        json={
            "command": ["python", "-c", "import time; time.sleep(5)"],
            "timeout_seconds": 1,
        },
        headers=headers,
    )
    assert timeout_res.status_code == 200
    assert timeout_res.json()["timed_out"] is True
    assert timeout_res.json()["exit_code"] == -1

    # Stop workspace and verify commands are rejected
    client.post(
        f"{settings.API_V1_STR}/projects/{proj_id}/workspaces/{ws_id}/stop",
        headers=headers,
    )
    stopped_cmd = client.post(
        f"{settings.API_V1_STR}/projects/{proj_id}/workspaces/{ws_id}/commands/run",
        json={"command": ["echo", "test"]},
        headers=headers,
    )
    assert stopped_cmd.status_code == 400


def test_path_traversal_defense(client: TestClient):
    """Verify path traversal prevention across file endpoints."""
    _, token, proj_id = create_user_and_project(client, "security_tester")
    headers = {"Authorization": f"Bearer {token}"}

    prov_res = client.post(
        f"{settings.API_V1_STR}/projects/{proj_id}/workspaces",
        json={"name": "Security Test Workspace"},
        headers=headers,
    )
    ws_id = prov_res.json()["id"]

    # 1. Traversal in list files
    bad_list = client.get(
        f"{settings.API_V1_STR}/projects/{proj_id}/workspaces/{ws_id}/files?path=../../etc",
        headers=headers,
    )
    assert bad_list.status_code == 400
    assert "traversal" in bad_list.json()["detail"].lower()

    # 2. Traversal in read file
    bad_read = client.get(
        f"{settings.API_V1_STR}/projects/{proj_id}/workspaces/{ws_id}/files/read?path=../../../etc/passwd",
        headers=headers,
    )
    assert bad_read.status_code == 400
    assert "traversal" in bad_read.json()["detail"].lower()

    # 3. Traversal in write file
    bad_write = client.post(
        f"{settings.API_V1_STR}/projects/{proj_id}/workspaces/{ws_id}/files/write",
        json={"path": "../../escape.txt", "content": "malicious content"},
        headers=headers,
    )
    assert bad_write.status_code == 400
    assert "traversal" in bad_write.json()["detail"].lower()


def test_file_operations_in_sandbox(client: TestClient):
    """Verify reading, writing, and directory listing in managed workspace."""
    _, token, proj_id = create_user_and_project(client, "file_tester")
    headers = {"Authorization": f"Bearer {token}"}

    prov_res = client.post(
        f"{settings.API_V1_STR}/projects/{proj_id}/workspaces",
        json={"name": "File Test Workspace"},
        headers=headers,
    )
    ws_id = prov_res.json()["id"]

    # Write a new code file
    write_res = client.post(
        f"{settings.API_V1_STR}/projects/{proj_id}/workspaces/{ws_id}/files/write",
        json={
            "path": "src/app.py",
            "content": "def run():\n    return 'running in sandbox'\n",
        },
        headers=headers,
    )
    assert write_res.status_code == 200

    # Read the file back
    read_res = client.get(
        f"{settings.API_V1_STR}/projects/{proj_id}/workspaces/{ws_id}/files/read?path=src/app.py",
        headers=headers,
    )
    assert read_res.status_code == 200
    assert "running in sandbox" in read_res.json()["content"]

    # List root directory
    list_res = client.get(
        f"{settings.API_V1_STR}/projects/{proj_id}/workspaces/{ws_id}/files?path=",
        headers=headers,
    )
    assert list_res.status_code == 200
    file_names = [item["name"] for item in list_res.json()["items"]]
    assert "README.md" in file_names
    assert "src" in file_names


def test_git_status_and_diff(client: TestClient):
    """Verify Git working tree status inspection and diff generation."""
    _, token, proj_id = create_user_and_project(client, "git_tester")
    headers = {"Authorization": f"Bearer {token}"}

    prov_res = client.post(
        f"{settings.API_V1_STR}/projects/{proj_id}/workspaces",
        json={"name": "Git Test Workspace"},
        headers=headers,
    )
    ws_id = prov_res.json()["id"]

    # Modify README.md
    client.post(
        f"{settings.API_V1_STR}/projects/{proj_id}/workspaces/{ws_id}/files/write",
        json={"path": "README.md", "content": "# Updated Project Title\nNew line added.\n"},
        headers=headers,
    )

    # Check Git status
    status_res = client.get(
        f"{settings.API_V1_STR}/projects/{proj_id}/workspaces/{ws_id}/git/status",
        headers=headers,
    )
    assert status_res.status_code == 200
    git_status = status_res.json()
    assert git_status["is_clean"] is False
    assert any("README.md" in f for f in git_status["modified_files"])

    # Check Git diff
    diff_res = client.get(
        f"{settings.API_V1_STR}/projects/{proj_id}/workspaces/{ws_id}/git/diff",
        headers=headers,
    )
    assert diff_res.status_code == 200
    diff_data = diff_res.json()
    assert diff_data["files_changed"] >= 1
    assert "Updated Project Title" in diff_data["diff"]


def test_task_workspace_integration(client: TestClient):
    """Verify task engine resolves and connects to active project workspace."""
    import time
    _, token, proj_id = create_user_and_project(client, "task_ws_user")
    headers = {"Authorization": f"Bearer {token}"}

    # 1. Provision a workspace for this project
    prov_res = client.post(
        f"{settings.API_V1_STR}/projects/{proj_id}/workspaces",
        json={"name": "Integrated Task Workspace"},
        headers=headers,
    )
    assert prov_res.status_code == 201
    ws_id = prov_res.json()["id"]

    # 2. Create a task in the project
    task_res = client.post(
        f"{settings.API_V1_STR}/projects/{proj_id}/tasks",
        json={"title": "Workspace Integrated Task", "prompt": "Inspect files and propose diff"},
        headers=headers,
    )
    assert task_res.status_code == 201
    task_id = task_res.json()["id"]

    # 3. Poll until agent reaches APPROVAL_REQUIRED
    reached = False
    for _ in range(50):
        time.sleep(0.1)
        res = client.get(f"{settings.API_V1_STR}/tasks/{task_id}", headers=headers)
        if res.json().get("status") == TaskStatus.APPROVAL_REQUIRED.value:
            reached = True
            break
    assert reached, "Task did not reach APPROVAL_REQUIRED state"

    # 4. Check persistent events for workspace integration
    events_res = client.get(
        f"{settings.API_V1_STR}/projects/{proj_id}/tasks/{task_id}/events",
        headers=headers,
    )
    assert events_res.status_code == 200
    events = events_res.json()["items"]
    progress_events = [e for e in events if e["event_type"] == "task.progress"]
    assert len(progress_events) >= 1
    # Check that inspect_repo stage recorded workspace connection
    first_progress = progress_events[0]["payload"]
    assert first_progress.get("workspace_id") == ws_id
    assert first_progress.get("workspace_ready") is True

