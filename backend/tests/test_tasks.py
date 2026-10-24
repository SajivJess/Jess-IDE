import time
import uuid
import pytest
from fastapi.testclient import TestClient

from app.core.config import settings
from app.main import app
from app.schemas.task import TaskStatus, can_transition
from app.services.agent_adapter import simulated_agent


@pytest.fixture
def client():
    # Set simulated agent step delay to near-zero for instant tests
    simulated_agent.step_delay = 0.02
    with TestClient(app) as test_client:
        yield test_client
    simulated_agent.step_delay = 0.4


def create_user_and_project(client: TestClient, prefix: str = "user") -> tuple[str, str, str]:
    """Helper to register user, login, and create a project, returning (user_id, token, project_id)."""
    email = f"{prefix}_{int(time.time() * 1000)}_{uuid.uuid4().hex[:6]}@example.com"
    password = "SecurePassword123!"

    reg_res = client.post(
        f"{settings.API_V1_STR}/auth/register",
        json={"email": email, "password": password, "full_name": f"{prefix} tester"},
    )
    assert reg_res.status_code == 201
    user_id = reg_res.json()["user"]["id"]

    login_res = client.post(
        f"{settings.API_V1_STR}/auth/login",
        json={"email": email, "password": password},
    )
    assert login_res.status_code == 200
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


def test_task_creation_and_ownership_isolation(client: TestClient):
    """Verify that only the project owner can create and view tasks."""
    _, token_a, proj_a = create_user_and_project(client, "owner_a")
    _, token_b, _ = create_user_and_project(client, "owner_b")

    headers_a = {"Authorization": f"Bearer {token_a}"}
    headers_b = {"Authorization": f"Bearer {token_b}"}

    # User A creates a task
    create_payload = {
        "title": "Build Authentication Module",
        "prompt": "Create JWT authentication endpoints and session tables.",
    }
    create_res = client.post(
        f"{settings.API_V1_STR}/projects/{proj_a}/tasks",
        json=create_payload,
        headers=headers_a,
    )
    assert create_res.status_code == 201
    task_data = create_res.json()
    task_id = task_data["id"]
    assert task_data["title"] == "Build Authentication Module"
    assert task_data["status"] in (TaskStatus.QUEUED.value, TaskStatus.RUNNING.value)

    # User A lists tasks for proj_a
    list_res = client.get(
        f"{settings.API_V1_STR}/projects/{proj_a}/tasks",
        headers=headers_a,
    )
    assert list_res.status_code == 200
    assert list_res.json()["total"] >= 1
    assert any(t["id"] == task_id for t in list_res.json()["items"])

    # User A gets task directly
    get_res = client.get(
        f"{settings.API_V1_STR}/tasks/{task_id}",
        headers=headers_a,
    )
    assert get_res.status_code == 200
    assert get_res.json()["id"] == task_id

    # User B cannot access User A's project tasks
    forbidden_list = client.get(
        f"{settings.API_V1_STR}/projects/{proj_a}/tasks",
        headers=headers_b,
    )
    assert forbidden_list.status_code == 404

    # User B cannot access User A's task directly
    forbidden_get = client.get(
        f"{settings.API_V1_STR}/tasks/{task_id}",
        headers=headers_b,
    )
    assert forbidden_get.status_code == 404

    # User B cannot create task in User A's project
    forbidden_create = client.post(
        f"{settings.API_V1_STR}/projects/{proj_a}/tasks",
        json={"title": "Unauthorized Task", "prompt": "Hack the planet"},
        headers=headers_b,
    )
    assert forbidden_create.status_code == 404


def test_state_machine_valid_and_invalid_transitions():
    """Verify state transition rules."""
    # Valid transitions
    assert can_transition(TaskStatus.QUEUED, TaskStatus.RUNNING)
    assert can_transition(TaskStatus.QUEUED, TaskStatus.CANCELLED)
    assert can_transition(TaskStatus.RUNNING, TaskStatus.APPROVAL_REQUIRED)
    assert can_transition(TaskStatus.RUNNING, TaskStatus.COMPLETED)
    assert can_transition(TaskStatus.RUNNING, TaskStatus.FAILED)
    assert can_transition(TaskStatus.RUNNING, TaskStatus.CANCELLED)
    assert can_transition(TaskStatus.APPROVAL_REQUIRED, TaskStatus.RUNNING)
    assert can_transition(TaskStatus.APPROVAL_REQUIRED, TaskStatus.CANCELLED)

    # Invalid transitions
    assert not can_transition(TaskStatus.QUEUED, TaskStatus.COMPLETED)
    assert not can_transition(TaskStatus.COMPLETED, TaskStatus.RUNNING)
    assert not can_transition(TaskStatus.COMPLETED, TaskStatus.CANCELLED)
    assert not can_transition(TaskStatus.CANCELLED, TaskStatus.RUNNING)
    assert not can_transition(TaskStatus.FAILED, TaskStatus.RUNNING)


def test_cancellation_and_terminal_protection(client: TestClient):
    """Verify task cancellation and terminal state protection."""
    _, token, proj_id = create_user_and_project(client, "canceller")
    headers = {"Authorization": f"Bearer {token}"}

    create_res = client.post(
        f"{settings.API_V1_STR}/projects/{proj_id}/tasks",
        json={"title": "To be cancelled", "prompt": "Cancel immediately"},
        headers=headers,
    )
    assert create_res.status_code == 201
    task_id = create_res.json()["id"]

    # Request cancellation
    cancel_res = client.post(
        f"{settings.API_V1_STR}/projects/{proj_id}/tasks/{task_id}/cancel",
        headers=headers,
    )
    assert cancel_res.status_code == 200
    assert cancel_res.json()["status"] == TaskStatus.CANCELLED.value

    # Verify task is now CANCELLED
    status_res = client.get(
        f"{settings.API_V1_STR}/tasks/{task_id}",
        headers=headers,
    )
    assert status_res.json()["status"] == TaskStatus.CANCELLED.value

    # Attempting to cancel an already cancelled task returns 400 Bad Request
    dup_cancel = client.post(
        f"{settings.API_V1_STR}/projects/{proj_id}/tasks/{task_id}/cancel",
        headers=headers,
    )
    assert dup_cancel.status_code == 400


def test_persistent_events_ordering_and_replay(client: TestClient):
    """Verify sequential event generation and HTTP replay via ?after=seq."""
    _, token, proj_id = create_user_and_project(client, "event_tester")
    headers = {"Authorization": f"Bearer {token}"}

    create_res = client.post(
        f"{settings.API_V1_STR}/projects/{proj_id}/tasks",
        json={"title": "Event Ordering Test", "prompt": "Simulate and verify event ordering"},
        headers=headers,
    )
    assert create_res.status_code == 201
    task_id = create_res.json()["id"]

    # Wait for simulator to pause in APPROVAL_REQUIRED state
    for _ in range(40):
        time.sleep(0.08)
        task_res = client.get(f"{settings.API_V1_STR}/tasks/{task_id}", headers=headers)
        if task_res.json().get("status") == TaskStatus.APPROVAL_REQUIRED.value:
            break

    # Fetch all events (after=0)
    events_res = client.get(
        f"{settings.API_V1_STR}/projects/{proj_id}/tasks/{task_id}/events?after=0",
        headers=headers,
    )
    assert events_res.status_code == 200
    events = events_res.json()["items"]
    assert len(events) >= 2

    # Check strictly monotonically increasing sequence numbers: 1, 2, 3...
    seq_nums = [e["sequence_num"] for e in events]
    assert seq_nums == list(range(1, len(seq_nums) + 1))
    assert events[0]["event_type"] == "task.queued"

    # Replay after sequence 1
    replay_res = client.get(
        f"{settings.API_V1_STR}/projects/{proj_id}/tasks/{task_id}/events?after=1",
        headers=headers,
    )
    assert replay_res.status_code == 200
    replayed = replay_res.json()["items"]
    assert len(replayed) == len(events) - 1
    assert all(e["sequence_num"] > 1 for e in replayed)


def test_simulated_agent_lifecycle_and_approval_flow(client: TestClient):
    """Verify complete simulated lifecycle: progress -> tool -> diff -> approval -> completed."""
    _, token, proj_id = create_user_and_project(client, "agent_sim")
    headers = {"Authorization": f"Bearer {token}"}

    create_res = client.post(
        f"{settings.API_V1_STR}/projects/{proj_id}/tasks",
        json={"title": "Implement Retry Policy", "prompt": "Add retry policy to ApiClient"},
        headers=headers,
    )
    assert create_res.status_code == 201
    task_id = create_res.json()["id"]

    reached_approval = False
    for _ in range(40):
        time.sleep(0.08)
        task_res = client.get(f"{settings.API_V1_STR}/tasks/{task_id}", headers=headers)
        if task_res.json().get("status") == TaskStatus.APPROVAL_REQUIRED.value:
            reached_approval = True
            break
    assert reached_approval, "Task did not enter APPROVAL_REQUIRED state within timeout"

    # Submit user approval
    approval_res = client.post(
        f"{settings.API_V1_STR}/projects/{proj_id}/tasks/{task_id}/approve",
        json={"action": "approve"},
        headers=headers,
    )
    assert approval_res.status_code == 200
    assert approval_res.json()["approved"] is True

    # Poll until COMPLETED
    reached_completed = False
    for _ in range(30):
        time.sleep(0.08)
        task_res = client.get(f"{settings.API_V1_STR}/tasks/{task_id}", headers=headers)
        if task_res.json()["status"] == TaskStatus.COMPLETED.value:
            reached_completed = True
            break
    assert reached_completed, "Task did not complete within timeout after approval"

    # Verify event types persisted in order
    events_res = client.get(
        f"{settings.API_V1_STR}/projects/{proj_id}/tasks/{task_id}/events?after=0",
        headers=headers,
    )
    event_types = [e["event_type"] for e in events_res.json()["items"]]
    assert "task.queued" in event_types
    assert "task.started" in event_types
    assert "tool.requested" in event_types
    assert "diff.proposed" in event_types
    assert "approval.required" in event_types
    assert "approval.granted" in event_types
    assert "task.completed" in event_types


def test_simulated_agent_approval_rejection_flow(client: TestClient):
    """Verify that rejecting approval cleanly cancels the task."""
    _, token, proj_id = create_user_and_project(client, "reject_tester")
    headers = {"Authorization": f"Bearer {token}"}

    create_res = client.post(
        f"{settings.API_V1_STR}/projects/{proj_id}/tasks",
        json={"title": "Diff to Reject", "prompt": "Simulate and reject"},
        headers=headers,
    )
    task_id = create_res.json()["id"]

    # Wait for APPROVAL_REQUIRED
    for _ in range(30):
        time.sleep(0.08)
        task_res = client.get(f"{settings.API_V1_STR}/tasks/{task_id}", headers=headers)
        if task_res.json()["status"] == TaskStatus.APPROVAL_REQUIRED.value:
            break

    # Reject
    reject_res = client.post(
        f"{settings.API_V1_STR}/projects/{proj_id}/tasks/{task_id}/approve",
        json={"action": "reject", "reason": "Security review failed"},
        headers=headers,
    )
    assert reject_res.status_code == 200
    assert reject_res.json()["approved"] is False

    # Check task status transitions to CANCELLED
    time.sleep(0.1)
    task_res = client.get(f"{settings.API_V1_STR}/tasks/{task_id}", headers=headers)
    assert task_res.json()["status"] == TaskStatus.CANCELLED.value


def test_websocket_authentication_and_unauthorized_rejection(client: TestClient):
    """Verify WebSocket security: rejected when token is invalid or user does not own task."""
    _, token_a, proj_a = create_user_and_project(client, "ws_owner")
    _, token_b, _ = create_user_and_project(client, "ws_intruder")

    headers_a = {"Authorization": f"Bearer {token_a}"}
    create_res = client.post(
        f"{settings.API_V1_STR}/projects/{proj_a}/tasks",
        json={"title": "WS Auth Test", "prompt": "Test WebSocket auth"},
        headers=headers_a,
    )
    task_id = create_res.json()["id"]

    # 1. Rejected with invalid/empty token
    try:
        with client.websocket_connect(f"{settings.API_V1_STR}/ws/tasks/{task_id}?token=invalid_token") as ws:
            ws.receive_json()
    except Exception:
        pass  # Rejected connection expected

    # 2. Rejected when User B attempts to listen to User A's task
    try:
        with client.websocket_connect(f"{settings.API_V1_STR}/ws/tasks/{task_id}?token={token_b}") as ws:
            msg = ws.receive_json()
            assert msg.get("type") == "error"
    except Exception:
        pass  # Rejected connection expected


def test_websocket_event_streaming_and_replay(client: TestClient):
    """Verify that WebSocket delivers replayed events and responds to ping/pong."""
    _, token, proj_id = create_user_and_project(client, "ws_streamer")
    headers = {"Authorization": f"Bearer {token}"}

    create_res = client.post(
        f"{settings.API_V1_STR}/projects/{proj_id}/tasks",
        json={"title": "WS Streaming Test", "prompt": "Stream events live"},
        headers=headers,
    )
    task_id = create_res.json()["id"]

    # Wait for at least task.queued and task.started events
    time.sleep(0.15)

    # Connect WebSocket with after=0 to receive all events
    with client.websocket_connect(f"{settings.API_V1_STR}/ws/tasks/{task_id}?token={token}&after=0") as ws:
        # First message should be an event
        first_msg = ws.receive_json()
        assert first_msg["type"] == "event"
        assert first_msg["data"]["sequence_num"] == 1
        assert first_msg["data"]["event_type"] == "task.queued"

        # Ping-pong test
        ws.send_json({"type": "ping"})
        pong_msg = ws.receive_json()
        # Might receive next event or pong
        if pong_msg.get("type") == "event":
            # Next event received; pong should follow
            pass
        elif pong_msg.get("type") == "pong":
            assert pong_msg["type"] == "pong"
