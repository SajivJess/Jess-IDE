import hashlib
import json
import logging
from datetime import datetime
from pathlib import Path, PurePosixPath
from typing import Any, Dict, List, Optional, Tuple
import uuid

import httpx

from app.core.config import settings
from app.db.models.task import Task
from app.schemas.contract import (
    AcceptanceCriterion,
    TaskContract,
)

logger = logging.getLogger("jess_backend")

DEFAULT_PROTECTED_FILES = [
    "auth.py",
    ".env",
    "config.py",
    "database.py",
    "network_security_config.xml",
    "AndroidManifest.xml",
]


class ContractService:
    """Service governing contract generation, Gate 1 approvals, and write permission enforcement."""

    def verify_write_permission(
        self,
        task: Task,
        target_path: str,
        workspace_root: Optional[Any] = None,
    ) -> Tuple[bool, Optional[str], Optional[str]]:
        """Verify whether an agent tool is permitted to modify or create target_path.
        
        Returns:
            (is_permitted, error_message, error_code)
        """
        clean_path = target_path.strip().replace("\\", "/").lstrip("/")
        if not clean_path:
            return False, "Target file path cannot be empty.", "EMPTY_PATH"

        # 1. Path traversal and escape prevention
        parts = clean_path.split("/")
        if ".." in parts or target_path.startswith("/") or ":" in target_path or "\0" in target_path:
            return (
                False,
                f"SecurityViolation: Invalid file path '{target_path}' (path traversal or absolute path detected).",
                "PATH_TRAVERSAL_DETECTED",
            )

        # 2. Symlink escape check if workspace_root is provided
        if workspace_root:
            try:
                root_path = Path(workspace_root).resolve()
                resolved_target = (root_path / clean_path).resolve()
                if not resolved_target.is_relative_to(root_path):
                    return (
                        False,
                        f"SecurityViolation: File path '{target_path}' escapes workspace boundary via symlink.",
                        "SYMLINK_ESCAPE_DETECTED",
                    )
            except Exception as e:
                return (
                    False,
                    f"SecurityViolation: Invalid path resolution: {e}",
                    "PATH_RESOLUTION_ERROR",
                )

        # 3. Gate 1 Contract Enforcement
        requires_contract = getattr(task, "require_contract", False)
        if requires_contract and not task.contract_data:
            return (
                False,
                "ContractRequired: Modification blocked. Task requires an approved contract before write operations.",
                "CONTRACT_REQUIRED",
            )

        # 4. Scope and protected file checking
        lower_clean = clean_path.lower()
        if lower_clean.startswith("./"):
            lower_clean = lower_clean[2:]

        if task.contract_data:
            try:
                contract = TaskContract.model_validate(task.contract_data)
            except Exception as e:
                logger.error(f"[ContractService] Corrupted contract on task {task.id}: {e}")
                return False, "Task contract data is corrupted.", "CORRUPT_CONTRACT"

            # Enforce Gate 1: Contract Approval
            if not contract.is_approved_by_user:
                return (
                    False,
                    "ContractApprovalRequired: Modification blocked. The task contract has not been approved by the task owner.",
                    "CONTRACT_NOT_APPROVED",
                )

            # Enforce Protected Files Boundary (Case-insensitive & traversal-safe)
            for protected in contract.protected_files:
                norm_protected = protected.strip().replace("\\", "/").lstrip("/").lower()
                if norm_protected.startswith("./"):
                    norm_protected = norm_protected[2:]
                if (
                    lower_clean == norm_protected
                    or lower_clean.endswith("/" + norm_protected)
                    or PurePosixPath(lower_clean).match(norm_protected)
                ):
                    return (
                        False,
                        f"ScopeViolation: File '{clean_path}' is protected by the task contract and cannot be modified.",
                        "PROTECTED_FILE_VIOLATION",
                    )

            # Enforce Allowed Scope
            # If allow_new_files is False, writes must match allowed_files
            allowed_normalized = [
                f.strip().replace("\\", "/").lstrip("/").lower() for f in contract.allowed_files
            ]
            if not contract.allow_new_files and lower_clean not in allowed_normalized:
                return (
                    False,
                    f"ScopeViolation: File '{clean_path}' is outside the approved file scope.",
                    "SCOPE_VIOLATION",
                )
        else:
            # Baseline protection for default critical files
            for protected in DEFAULT_PROTECTED_FILES:
                norm_protected = protected.strip().replace("\\", "/").lstrip("/").lower()
                if norm_protected.startswith("./"):
                    norm_protected = norm_protected[2:]
                if lower_clean == norm_protected or lower_clean.endswith("/" + norm_protected):
                    return (
                        False,
                        f"ScopeViolation: File '{clean_path}' is a protected system configuration file.",
                        "PROTECTED_FILE_VIOLATION",
                    )

        return True, None, None

    async def generate_contract_proposal(
        self,
        task: Task,
        workspace_files: Optional[List[str]] = None,
    ) -> TaskContract:
        """Draft a structured, measurable task contract before code changes begin."""
        workspace_files = workspace_files or []
        provider = getattr(settings, "AGENT_PROVIDER", "simulated").lower()
        api_key = getattr(settings, "MODEL_API_KEY", None)

        raw_contract_dict: Optional[Dict[str, Any]] = None

        if api_key and provider == "meta":
            try:
                raw_contract_dict = await self._call_meta_contract_planner(
                    task.title, task.prompt, workspace_files
                )
            except Exception as e:
                logger.warning(
                    f"[ContractService] Meta planner call failed: {e}. Falling back to deterministic planner."
                )

        if not raw_contract_dict:
            raw_contract_dict = self._generate_deterministic_contract(
                task.title, task.prompt, workspace_files
            )

        # Ensure task_id is bound strictly to the current task
        raw_contract_dict["task_id"] = str(task.id)
        # Untrusted model output: backend ALWAYS resets approval flags to False
        raw_contract_dict["is_approved_by_user"] = False
        raw_contract_dict["approved_by_user_id"] = None
        raw_contract_dict["approved_at"] = None

        # Validate through Pydantic
        contract = TaskContract.model_validate(raw_contract_dict)
        contract.contract_hash = contract.compute_hash()
        return contract

    def record_contract_approval(
        self,
        task: Task,
        user_id: uuid.UUID,
        action: str,
        contract_hash: Optional[str] = None,
        reason: Optional[str] = None,
    ) -> TaskContract:
        """Record explicit user Gate 1 approval or rejection with audit trail."""
        if not task.contract_data:
            raise ValueError("NO_CONTRACT_PROPOSED")

        contract = TaskContract.model_validate(task.contract_data)

        # Stale approval detection
        if contract_hash and contract.contract_hash:
            if contract_hash.strip().lower() != contract.contract_hash.strip().lower():
                raise ValueError("STALE_CONTRACT")

        if action.lower() == "approve":
            contract.is_approved_by_user = True
            contract.approved_by_user_id = user_id
            contract.approved_at = datetime.utcnow()
        elif action.lower() == "reject":
            contract.is_approved_by_user = False
            contract.approved_by_user_id = user_id
            contract.approved_at = None
        else:
            raise ValueError(f"Invalid approval action '{action}'. Must be 'approve' or 'reject'.")

        task.contract_data = contract.model_dump(mode="json")
        return contract

    def _generate_deterministic_contract(
        self, title: str, prompt: str, workspace_files: List[str]
    ) -> Dict[str, Any]:
        """Deterministic contract generation for offline testing and fallback."""
        lower_prompt = prompt.lower()

        # Identify files mentioned in prompt
        allowed_files = []
        for wf in workspace_files:
            base_name = wf.split("/")[-1]
            if base_name.lower() in lower_prompt:
                allowed_files.append(wf)

        # Default targets based on common demo scenarios
        if not allowed_files:
            if "calculator" in lower_prompt or "calc" in lower_prompt:
                allowed_files = ["calculator.py", "test_calculator.py"]
            else:
                allowed_files = [f for f in workspace_files if not any(p in f for p in DEFAULT_PROTECTED_FILES)][:3]
                if not allowed_files:
                    allowed_files = ["main.py", "test_main.py"]

        criteria = []
        if "divide" in lower_prompt:
            criteria.append(
                AcceptanceCriterion(
                    id="crit_1",
                    description="Implement divide(a, b) returning exact mathematical quotient.",
                ).model_dump()
            )
            criteria.append(
                AcceptanceCriterion(
                    id="crit_2",
                    description="Handle division by zero by raising ValueError with informative error message.",
                ).model_dump()
            )
            criteria.append(
                AcceptanceCriterion(
                    id="crit_3",
                    description="Ensure existing addition and arithmetic functions continue to pass without regression.",
                ).model_dump()
            )
        else:
            criteria.append(
                AcceptanceCriterion(
                    id="crit_1",
                    description=f"Implement requirement: {title.strip()}",
                ).model_dump()
            )
            criteria.append(
                AcceptanceCriterion(
                    id="crit_2",
                    description="Add comprehensive automated unit test coverage verifying expected behavior.",
                ).model_dump()
            )

        test_commands = ["python -m unittest"]
        if any("pytest" in wf for wf in workspace_files) or any("test_" in f for f in allowed_files):
            test_commands = ["python -m unittest test_calculator.py"]

        return {
            "contract_version": 1,
            "summary": f"Plan: {title.strip()}",
            "criteria": criteria,
            "allowed_files": allowed_files,
            "allow_new_files": True,
            "protected_files": DEFAULT_PROTECTED_FILES,
            "test_commands": test_commands,
            "ambiguities": [],
        }

    async def _call_meta_contract_planner(
        self, title: str, prompt: str, workspace_files: List[str]
    ) -> Dict[str, Any]:
        """Query Meta Model API for zero-shot contract formulation."""
        api_key = settings.MODEL_API_KEY
        base_url = settings.META_MODEL_BASE_URL.rstrip("/")
        model_id = settings.META_MODEL_ID

        system_instruction = (
            "You are Muse Spark, an autonomous software architect. "
            "Given a user coding request and workspace file layout, formulate a strict, testable task contract. "
            "Return ONLY valid JSON matching this schema: "
            "{"
            "  \"summary\": \"concise plan summary\", "
            "  \"criteria\": [{\"id\": \"crit_1\", \"description\": \"measurable testable rule\"}], "
            "  \"allowed_files\": [\"path/to/file.py\"], "
            "  \"allow_new_files\": true, "
            "  \"protected_files\": [\"auth.py\", \".env\", \"config.py\"], "
            "  \"test_commands\": [\"python -m unittest test_file.py\"], "
            "  \"ambiguities\": [\"any questions needing user decision\"] "
            "}"
        )

        user_content = (
            f"Task Title: {title}\n"
            f"Task Instructions:\n{prompt}\n\n"
            f"Available Workspace Files:\n" + "\n".join(workspace_files[:50])
        )

        headers = {
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        }
        body = {
            "model": model_id,
            "messages": [
                {"role": "system", "content": system_instruction},
                {"role": "user", "content": user_content},
            ],
            "temperature": 0.1,
            "max_tokens": 1024,
        }

        async with httpx.AsyncClient(timeout=30.0) as client:
            res = await client.post(f"{base_url}/chat/completions", headers=headers, json=body)
            if res.status_code != 200:
                raise RuntimeError(f"Meta Model API planner error {res.status_code}: {res.text}")

            res_json = res.json()
            content = res_json["choices"][0]["message"]["content"]

            # Extract JSON block if surrounded by markdown fences
            if "```json" in content:
                content = content.split("```json", 1)[1].split("```", 1)[0].strip()
            elif "```" in content:
                content = content.split("```", 1)[1].split("```", 1)[0].strip()

            return json.loads(content)


contract_service = ContractService()
