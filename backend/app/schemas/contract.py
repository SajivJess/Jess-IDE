import hashlib
import json
import re
import uuid
from datetime import datetime
from enum import Enum
from pathlib import PurePosixPath
from typing import Any, Dict, List, Optional
from pydantic import BaseModel, ConfigDict, Field, field_validator


class TestExecutionStatus(str, Enum):
    """Execution status for deterministic checks and tests."""
    PASSED = "PASSED"
    FAILED = "FAILED"
    BLOCKED = "BLOCKED"
    NOT_RUN = "NOT_RUN"


TestExecutionStatus.__test__ = False


class ScopeStatus(str, Enum):
    """Scope adherence status evaluated against the contract."""
    CLEAN = "CLEAN"
    VIOLATED = "VIOLATED"


class AcceptanceCriterion(BaseModel):
    """A single measurable, testable acceptance rule within a contract."""
    id: str = Field(..., description="Stable criterion identifier (e.g. 'crit_1')")
    description: str = Field(..., min_length=3, max_length=500, description="Testable behavioral rule")
    verified: bool = Field(default=False, description="Whether actual evidence proved this criterion")
    evidence_note: Optional[str] = Field(default=None, max_length=1000, description="Specific evidence log reference")

    @field_validator("id")
    @classmethod
    def validate_id(cls, v: str) -> str:
        v = v.strip()
        if not re.match(r"^[a-zA-Z0-9_\-]+$", v):
            raise ValueError(f"Criterion ID '{v}' must be alphanumeric with underscores or hyphens.")
        return v


class CommandEvidence(BaseModel):
    """Actual recorded result of a verification command executed on the host."""
    command: str = Field(..., description="Exact command executed")
    exit_code: int = Field(..., description="Process exit code (0 = success)")
    duration_ms: int = Field(..., ge=0, description="Execution duration in milliseconds")
    stdout_snippet: str = Field(default="", max_length=20000, description="Bounded stdout output")
    stderr_snippet: Optional[str] = Field(default=None, max_length=20000, description="Bounded stderr output")
    status: TestExecutionStatus = Field(..., description="Interpreted status")

    @field_validator("command")
    @classmethod
    def validate_command_safety(cls, v: str) -> str:
        cmd = v.strip()
        if not cmd:
            raise ValueError("Command cannot be empty.")
        # Reject dangerous shell injection characters in model-proposed commands
        forbidden_chars = [";", "&&", "||", "|", "`", "$("]
        for fc in forbidden_chars:
            if fc in cmd:
                raise ValueError(f"Command '{cmd}' contains dangerous shell operator '{fc}'.")
        return cmd


class BreakItCheck(BaseModel):
    """Deterministic edge-case probe evaluated against changed code."""
    name: str = Field(..., max_length=100)
    input_description: str = Field(..., max_length=255)
    expected_behavior: str = Field(..., max_length=255)
    actual_behavior: str = Field(default="NOT_RUN", max_length=255)
    passed: bool = Field(default=False)


class VerificationEvidence(BaseModel):
    """Immutable record of backend-collected verification proof."""
    task_id: uuid.UUID
    scope_status: ScopeStatus = ScopeStatus.CLEAN
    unexpected_files_modified: List[str] = Field(default_factory=list)
    protected_files_violated: List[str] = Field(default_factory=list)
    command_runs: List[CommandEvidence] = Field(default_factory=list)
    break_it_checks: List[BreakItCheck] = Field(default_factory=list)
    diff_stat: Dict[str, int] = Field(default_factory=dict)
    all_criteria_met: bool = False
    overall_verdict: str = "PENDING"  # "PROVEN", "FAILED_CHECKS", "SCOPE_BREACH", "PENDING"

    model_config = ConfigDict(from_attributes=True)


class TaskContract(BaseModel):
    """Structured, machine-enforced task contract for Proof, Not Vibes."""
    task_id: uuid.UUID
    contract_version: int = Field(default=1, ge=1)
    summary: str = Field(..., min_length=5, max_length=1000, description="Human-readable goal summary")
    criteria: List[AcceptanceCriterion] = Field(
        ..., min_length=1, max_length=20, description="Measurable acceptance criteria"
    )
    allowed_files: List[str] = Field(
        ..., description="Permitted relative paths for creation or modification"
    )
    allow_new_files: bool = Field(
        default=True, description="Whether creating new files within allowed directories is permitted"
    )
    protected_files: List[str] = Field(
        default_factory=lambda: [
            "auth.py",
            ".env",
            "config.py",
            "database.py",
            "network_security_config.xml",
        ],
        description="Forbidden files that trigger immediate scope rejection if modified",
    )
    test_commands: List[str] = Field(
        default_factory=lambda: ["python -m unittest"],
        description="Deterministic verification commands required to prove compliance",
    )
    ambiguities: List[str] = Field(
        default_factory=list, description="Questions or edge-case decisions identified during planning"
    )
    is_approved_by_user: bool = Field(
        default=False, description="Gate 1 user sign-off status (must be set exclusively by backend)"
    )
    approved_by_user_id: Optional[uuid.UUID] = Field(default=None)
    approved_at: Optional[datetime] = Field(default=None)
    contract_hash: Optional[str] = Field(
        default=None, description="SHA-256 fingerprint of the proposed terms to prevent stale approval"
    )

    model_config = ConfigDict(from_attributes=True)

    @field_validator("allowed_files", "protected_files")
    @classmethod
    def validate_file_paths(cls, paths: List[str]) -> List[str]:
        cleaned = []
        for p in paths:
            norm = p.strip().replace("\\", "/")
            if not norm:
                continue
            # Path traversal and escape prevention
            parts = norm.split("/")
            if ".." in parts or norm.startswith("/") or ":" in norm:
                raise ValueError(f"Illegal path '{p}': path traversal or absolute paths are forbidden.")
            cleaned.append(norm)
        return cleaned

    @field_validator("test_commands")
    @classmethod
    def validate_test_commands(cls, cmds: List[str]) -> List[str]:
        cleaned = []
        for c in cmds:
            cmd = c.strip()
            if not cmd:
                continue
            # Check command injection
            for fc in [";", "&&", "||", "|", "`", "$("]:
                if fc in cmd:
                    raise ValueError(f"Test command '{cmd}' contains dangerous shell operator '{fc}'.")
            cleaned.append(cmd)
        return cleaned

    def compute_hash(self) -> str:
        """Compute SHA-256 fingerprint of the core contract terms."""
        payload = {
            "task_id": str(self.task_id),
            "contract_version": self.contract_version,
            "summary": self.summary,
            "criteria": [{"id": c.id, "description": c.description} for c in self.criteria],
            "allowed_files": sorted(self.allowed_files),
            "allow_new_files": self.allow_new_files,
            "protected_files": sorted(self.protected_files),
            "test_commands": sorted(self.test_commands),
        }
        raw_json = json.dumps(payload, sort_keys=True)
        return hashlib.sha256(raw_json.encode("utf-8")).hexdigest()


class TaskContractApprovalRequest(BaseModel):
    """User request to approve or reject Gate 1 task contract."""
    action: str = Field(..., pattern="^(approve|reject)$", description="'approve' or 'reject'")
    contract_hash: Optional[str] = Field(
        default=None, description="Hash of the contract reviewed by client to detect stale approvals"
    )
    reason: Optional[str] = Field(default=None, max_length=500, description="Optional rejection reason")


class TaskContractApprovalResponse(BaseModel):
    """Response returned upon approving or rejecting a task contract."""
    task_id: uuid.UUID
    action: str
    approved: bool
    contract_version: int
    approved_at: Optional[datetime] = None
    message: str
