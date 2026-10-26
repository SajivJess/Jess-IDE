import time
import uuid
import pytest
from fastapi.testclient import TestClient

from app.core.config import settings
from app.main import app
from app.schemas.task import TaskStatus
from app.services.agent_adapter import simulated_agent


@pytest.fixture
def client():
    simulated_agent.step_delay = 0.01
    with TestClient(app) as test_client:
        yield test_client
    simulated_agent.step_delay = 0.3


def create_user_and_project(client: TestClient, prefix: str = "conv_user") -> tuple[str, str, str]:
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


def test_conversation_lifecycle_and_ownership(client: TestClient):
    """Test conversation creation, listing, and ownership security."""
    _, token_a, proj_a = create_user_and_project(client, "alice")
    _, token_b, _ = create_user_and_project(client, "bob")

    headers_a = {"Authorization": f"Bearer {token_a}"}
    headers_b = {"Authorization": f"Bearer {token_b}"}

    # 1. Listing conversations when none exist automatically initializes default
    list_res = client.get(
        f"{settings.API_V1_STR}/projects/{proj_a}/conversations",
        headers=headers_a,
    )
    assert list_res.status_code == 200
    data = list_res.json()
    assert data["total"] == 1
    assert data["items"][0]["title"] == "Coding Session"
    conv_id = data["items"][0]["id"]

    # 2. Ownership check: Bob cannot access Alice's conversation
    forbidden_res = client.get(
        f"{settings.API_V1_STR}/projects/{proj_a}/conversations",
        headers=headers_b,
    )
    assert forbidden_res.status_code == 404

    conv_get = client.get(
        f"{settings.API_V1_STR}/projects/{proj_a}/conversations/{conv_id}",
        headers=headers_b,
    )
    assert conv_get.status_code == 404


def test_agent_run_event_stream_and_replay(client: TestClient):
    """Test starting an agent run, streaming standardized JSON events, and replaying missed events."""
    _, token, proj_id = create_user_and_project(client, "streamer")
    headers = {"Authorization": f"Bearer {token}"}

    # Get or create conversation
    list_res = client.get(
        f"{settings.API_V1_STR}/projects/{proj_id}/conversations",
        headers=headers,
    )
    conv_id = list_res.json()["items"][0]["id"]

    # Start an agent run
    run_res = client.post(
        f"{settings.API_V1_STR}/projects/{proj_id}/conversations/{conv_id}/runs",
        headers=headers,
        json={"prompt": "Add retry policy with exponential backoff to api client"},
    )
    assert run_res.status_code == 201
    run_data = run_res.json()
    run_id = run_data["id"]
    assert run_data["status"] == "QUEUED"

    # Wait for simulator to reach APPROVAL_REQUIRED state
    for _ in range(50):
        time.sleep(0.05)
        status_check = client.get(
            f"{settings.API_V1_STR}/projects/{proj_id}/runs/{run_id}",
            headers=headers,
        )
        if status_check.json().get("status") == TaskStatus.APPROVAL_REQUIRED.value:
            break

    # Replay events
    replay_res = client.get(
        f"{settings.API_V1_STR}/projects/{proj_id}/conversations/{conv_id}/events?after=0",
        headers=headers,
    )
    assert replay_res.status_code == 200
    replay_data = replay_res.json()
    events = replay_data["items"]
    assert len(events) >= 5

    # Verify event schema compliance
    types = [e["type"] for e in events]
    assert "run.started" in types
    assert "message.started" in types
    assert "message.delta" in types
    assert "tool.started" in types
    assert "file.changed" in types
    assert "approval.required" in types

    for ev in events:
        assert ev["schema_version"] == "1.0"
        assert ev["conversation_id"] == conv_id
        assert "sequence" in ev
        assert "created_at" in ev
        assert isinstance(ev["data"], dict)

    # Verify monotonic sequencing
    seqs = [e["sequence"] for e in events]
    assert seqs == sorted(seqs)
    assert len(seqs) == len(set(seqs))

    # Test replay filter with after=sequence
    cutoff_seq = seqs[2]
    filtered_res = client.get(
        f"{settings.API_V1_STR}/projects/{proj_id}/conversations/{conv_id}/events?after={cutoff_seq}",
        headers=headers,
    )
    assert filtered_res.status_code == 200
    filtered_events = filtered_res.json()["items"]
    for fe in filtered_events:
        assert fe["sequence"] > cutoff_seq

    # Submit approval
    appr_res = client.post(
        f"{settings.API_V1_STR}/projects/{proj_id}/runs/{run_id}/approval",
        headers=headers,
        json={"action": "approve"},
    )
    assert appr_res.status_code == 200
    assert appr_res.json()["approved"] is True

    # Wait for completion
    for _ in range(50):
        time.sleep(0.05)
        status_res = client.get(
            f"{settings.API_V1_STR}/projects/{proj_id}/runs/{run_id}",
            headers=headers,
        )
        if status_res.json().get("status") == TaskStatus.COMPLETED.value:
            break

    # Check run completed
    status_res = client.get(
        f"{settings.API_V1_STR}/projects/{proj_id}/runs/{run_id}",
        headers=headers,
    )
    assert status_res.status_code == 200
    assert status_res.json()["status"] == TaskStatus.COMPLETED.value


def test_agent_run_cancellation(client: TestClient):
    """Test cancelling an active agent run."""
    _, token, proj_id = create_user_and_project(client, "canceller")
    headers = {"Authorization": f"Bearer {token}"}

    list_res = client.get(
        f"{settings.API_V1_STR}/projects/{proj_id}/conversations",
        headers=headers,
    )
    conv_id = list_res.json()["items"][0]["id"]

    # Start run
    run_res = client.post(
        f"{settings.API_V1_STR}/projects/{proj_id}/conversations/{conv_id}/runs",
        headers=headers,
        json={"prompt": "Investigate network timeout bug"},
    )
    assert run_res.status_code == 201
    run_id = run_res.json()["id"]

    # Cancel immediately
    cancel_res = client.post(
        f"{settings.API_V1_STR}/projects/{proj_id}/runs/{run_id}/cancel",
        headers=headers,
    )
    assert cancel_res.status_code == 200
    assert cancel_res.json()["status"] == TaskStatus.CANCELLED.value

    # Verify status is CANCELLED
    status_res = client.get(
        f"{settings.API_V1_STR}/projects/{proj_id}/runs/{run_id}",
        headers=headers,
    )
    assert status_res.status_code == 200
    assert status_res.json()["status"] == TaskStatus.CANCELLED.value


def test_intent_routing_conversational_and_coding_messages(client: TestClient):
    """Regression test proving 'hey', 'How are you?', and 'Explain...' do not start a run,
    while 'Add exponential backoff...' starts a coding run.
    """
    _, token, proj_id = create_user_and_project(client, "intent_user")
    headers = {"Authorization": f"Bearer {token}"}

    conv_res = client.get(
        f"{settings.API_V1_STR}/projects/{proj_id}/conversations",
        headers=headers,
    )
    conv_id = conv_res.json()["items"][0]["id"]

    # 1. 'hey' must NOT start a run
    hey_res = client.post(
        f"{settings.API_V1_STR}/projects/{proj_id}/conversations/{conv_id}/messages",
        headers=headers,
        json={"content": "hey"},
    )
    assert hey_res.status_code == 201
    hey_data = hey_res.json()
    assert hey_data["intent"] == "CONVERSATION"
    assert hey_data["run"] is None
    assert hey_data["assistant_message"] is not None
    assert any(w in hey_data["assistant_message"]["content"].lower() for w in ["hey", "hello", "hi", "work", "jess"])

    # 2. 'How are you?' must NOT start a run
    how_res = client.post(
        f"{settings.API_V1_STR}/projects/{proj_id}/conversations/{conv_id}/messages",
        headers=headers,
        json={"content": "How are you?"},
    )
    assert how_res.status_code == 201
    how_data = how_res.json()
    assert how_data["intent"] == "CONVERSATION"
    assert how_data["run"] is None
    assert how_data["assistant_message"] is not None

    # 3. 'Explain the API client' must NOT start a run
    explain_res = client.post(
        f"{settings.API_V1_STR}/projects/{proj_id}/conversations/{conv_id}/messages",
        headers=headers,
        json={"content": "Explain the API client"},
    )
    assert explain_res.status_code == 201
    explain_data = explain_res.json()
    assert explain_data["intent"] == "PROJECT_QUESTION"
    assert explain_data["run"] is None
    assert explain_data["assistant_message"] is not None

    # Verify no runs exist yet
    runs_res = client.get(
        f"{settings.API_V1_STR}/projects/{proj_id}/conversations/{conv_id}",
        headers=headers,
    )
    assert runs_res.json()["runs_count"] == 0

    # 4. 'Add exponential backoff retry logic to the API client' MUST start a coding run
    code_res = client.post(
        f"{settings.API_V1_STR}/projects/{proj_id}/conversations/{conv_id}/messages",
        headers=headers,
        json={"content": "Add exponential backoff retry logic to the API client"},
    )
    assert code_res.status_code == 201
    code_data = code_res.json()
    assert code_data["intent"] == "CODING_INSTRUCTION"
    assert code_data["run"] is not None
    assert code_data["assistant_message"] is None
    run_id = code_data["run"]["id"]
    assert code_data["run"]["status"] in (TaskStatus.QUEUED.value, TaskStatus.RUNNING.value, TaskStatus.APPROVAL_REQUIRED.value)

    # Cancel the run cleanly
    client.post(f"{settings.API_V1_STR}/projects/{proj_id}/runs/{run_id}/cancel", headers=headers)


def test_intent_routing_ambiguous_requests(client: TestClient):
    """Regression test proving ambiguous requests ask for clarification and do not start a run."""
    _, token, proj_id = create_user_and_project(client, "ambig_user")
    headers = {"Authorization": f"Bearer {token}"}

    conv_res = client.get(
        f"{settings.API_V1_STR}/projects/{proj_id}/conversations",
        headers=headers,
    )
    conv_id = conv_res.json()["items"][0]["id"]

    for phrase in ["fix it", "make changes", "update"]:
        res = client.post(
            f"{settings.API_V1_STR}/projects/{proj_id}/conversations/{conv_id}/messages",
            headers=headers,
            json={"content": phrase},
        )
        assert res.status_code == 201
        data = res.json()
        assert data["intent"] == "AMBIGUOUS"
        assert data["run"] is None
        assert data["assistant_message"] is not None
        content = data["assistant_message"]["content"].lower()
        assert "?" in content or any(w in content for w in ["clarify", "example", "what", "which", "please", "help"])


def test_intent_routing_classification_failure_safe_fallback(client: TestClient, monkeypatch):
    """Regression test proving classification failure never executes code (fails closed)."""
    from app.services.intent_router import IntentRouter, MessageIntent

    _, token, proj_id = create_user_and_project(client, "safe_user")
    headers = {"Authorization": f"Bearer {token}"}

    conv_res = client.get(
        f"{settings.API_V1_STR}/projects/{proj_id}/conversations",
        headers=headers,
    )
    conv_id = conv_res.json()["items"][0]["id"]

    # Simulate classifier failure returning AMBIGUOUS
    async def mock_failing_classify(*args, **kwargs):
        return MessageIntent.AMBIGUOUS

    monkeypatch.setattr(IntentRouter, "classify", mock_failing_classify)

    res = client.post(
        f"{settings.API_V1_STR}/projects/{proj_id}/conversations/{conv_id}/messages",
        headers=headers,
        json={"content": "random unrecognized unclassified query 12345"},
    )
    assert res.status_code == 201
    data = res.json()
    assert data["intent"] == "AMBIGUOUS"
    assert data["run"] is None
    assert data["assistant_message"] is not None


def test_intent_routing_ownership_and_unauthorized_access(client: TestClient):
    """Regression test: unauthorized user cannot post to another user's conversation."""
    _, token_alice, proj_alice = create_user_and_project(client, "alice_router")
    _, token_bob, _ = create_user_and_project(client, "bob_router")

    headers_alice = {"Authorization": f"Bearer {token_alice}"}
    headers_bob = {"Authorization": f"Bearer {token_bob}"}

    conv_res = client.get(
        f"{settings.API_V1_STR}/projects/{proj_alice}/conversations",
        headers=headers_alice,
    )
    conv_id = conv_res.json()["items"][0]["id"]

    # Bob attempts to post into Alice's conversation
    unauth_res = client.post(
        f"{settings.API_V1_STR}/projects/{proj_alice}/conversations/{conv_id}/messages",
        headers=headers_bob,
        json={"content": "hey"},
    )
    assert unauth_res.status_code == 404

