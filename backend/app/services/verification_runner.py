import asyncio
import json
import logging
import os
from pathlib import Path
import shlex
import time
from typing import Any, Dict, List, Optional, Set
import uuid

from app.core.config import settings
from app.db.models.task import Task
from app.db.models.workspace import Workspace
from app.schemas.contract import (
    BreakItCheck,
    CommandEvidence,
    ScopeStatus,
    TaskContract,
    TestExecutionStatus,
    VerificationEvidence,
)
from app.services.workspace import get_workspace_provider

logger = logging.getLogger("jess_backend")

# Allowlisted binary stems safe for test verification execution
VERIFICATION_ALLOWLIST = {
    "python", "python3", "pytest", "unittest", "flutter", "dart", "node", "npm"
}


class VerificationRunner:
    """Safe, deterministic verification engine for Proof, Not Vibes.
    
    Executes actual tests in the isolated workspace sandbox, records exact exit codes,
    bounded outputs, and runs deterministic edge-case probes without relying on model self-reporting.
    """

    async def run_verification(
        self,
        task: Task,
        workspace: Workspace,
        task_owned_files: Optional[Set[str]] = None,
        diff_stat: Optional[Dict[str, int]] = None,
    ) -> VerificationEvidence:
        """Execute full verification suite: scope check, allowlisted test commands, and break-it edge cases."""
        ws_provider = get_workspace_provider()
        task_owned_files = task_owned_files or set()
        diff_stat = diff_stat or {}

        if not task.contract_data:
            logger.warning(f"[VerificationRunner] No contract found on task {task.id}. Generating baseline evidence.")
            evidence = VerificationEvidence(
                task_id=task.id,
                scope_status=ScopeStatus.CLEAN,
                overall_verdict="NO_CONTRACT",
                diff_stat=diff_stat,
            )
            task.verification_data = evidence.model_dump(mode="json")
            return evidence

        try:
            contract = TaskContract.model_validate(task.contract_data)
        except Exception as e:
            logger.error(f"[VerificationRunner] Corrupt contract on task {task.id}: {e}")
            evidence = VerificationEvidence(
                task_id=task.id,
                scope_status=ScopeStatus.VIOLATED,
                overall_verdict="CORRUPT_CONTRACT",
                diff_stat=diff_stat,
            )
            task.verification_data = evidence.model_dump(mode="json")
            return evidence

        # 1. Enforce Scope Verification
        protected_violated: List[str] = []
        unexpected_modified: List[str] = []

        allowed_normalized = [
            f.strip().replace("\\", "/").lstrip("/").lower() for f in contract.allowed_files
        ]

        wdir = ws_provider.get_workspace_dir(workspace)
        wdir_resolved = wdir.resolve()

        for file_path in task_owned_files:
            clean_p = file_path.strip().replace("\\", "/").lstrip("/").lower()
            if clean_p.startswith("./"):
                clean_p = clean_p[2:]

            target_path = wdir / clean_p

            # Check for symlink escapes or indirect symlink aliasing
            if target_path.is_symlink() or target_path.exists():
                try:
                    resolved_target = target_path.resolve()
                    # Check if target escapes workspace root
                    common = os.path.commonpath([str(wdir_resolved), str(resolved_target)])
                    if common != str(wdir_resolved):
                        protected_violated.append(f"{file_path} (escapes workspace via symlink)")
                        continue

                    # Check if resolved canonical path targets any protected file
                    resolved_rel = os.path.relpath(str(resolved_target), str(wdir_resolved)).replace("\\", "/").lower()
                    for protected in contract.protected_files:
                        norm_p = protected.strip().replace("\\", "/").lstrip("/").lower()
                        if norm_p.startswith("./"):
                            norm_p = norm_p[2:]
                        if resolved_rel == norm_p or resolved_rel.endswith("/" + norm_p):
                            protected_violated.append(f"{file_path} (symlink targets protected file '{protected}')")
                            break
                except Exception as e:
                    protected_violated.append(f"{file_path} (unresolvable path: {e})")

            # Check protected files nominally
            for protected in contract.protected_files:
                norm_p = protected.strip().replace("\\", "/").lstrip("/").lower()
                if norm_p.startswith("./"):
                    norm_p = norm_p[2:]
                if clean_p == norm_p or clean_p.endswith("/" + norm_p):
                    protected_violated.append(file_path)

            # Check allowed files if new files not permitted
            if not contract.allow_new_files and clean_p not in allowed_normalized:
                unexpected_modified.append(file_path)

        scope_status = (
            ScopeStatus.VIOLATED
            if (protected_violated or unexpected_modified)
            else ScopeStatus.CLEAN
        )

        # 2. Allowlisted Command Execution with Timeout and Output Bounds
        command_runs: List[CommandEvidence] = []
        for cmd_str in contract.test_commands:
            cmd = cmd_str.strip()
            if not cmd:
                continue

            # Check dangerous shell injection and path traversal tokens
            if any(fc in cmd for fc in [";", "&&", "||", "|", "`", "$(", ".."]):
                command_runs.append(
                    CommandEvidence(
                        command=cmd,
                        exit_code=1,
                        duration_ms=0,
                        stdout_snippet="",
                        stderr_snippet=f"SecurityError: Command '{cmd}' contains forbidden shell operators or path traversal.",
                        status=TestExecutionStatus.BLOCKED,
                    )
                )
                continue

            cmd_parts = shlex.split(cmd, posix=False) if os.name == "nt" else shlex.split(cmd)
            binary = Path(cmd_parts[0]).stem.lower()

            if binary not in VERIFICATION_ALLOWLIST:
                command_runs.append(
                    CommandEvidence(
                        command=cmd,
                        exit_code=1,
                        duration_ms=0,
                        stdout_snippet="",
                        stderr_snippet=f"SecurityError: Binary '{binary}' is not permitted by verification allowlist.",
                        status=TestExecutionStatus.BLOCKED,
                    )
                )
                continue

            # Execute safely inside isolated workspace
            start_t = time.time()
            try:
                cmd_res = await ws_provider.execute_command(
                    workspace, cmd_parts, timeout_seconds=30
                )
                duration_ms = int((time.time() - start_t) * 1000)
                status = (
                    TestExecutionStatus.PASSED
                    if cmd_res.exit_code == 0
                    else (TestExecutionStatus.BLOCKED if cmd_res.timed_out else TestExecutionStatus.FAILED)
                )
                command_runs.append(
                    CommandEvidence(
                        command=cmd,
                        exit_code=cmd_res.exit_code,
                        duration_ms=duration_ms,
                        stdout_snippet=cmd_res.stdout[:20000],
                        stderr_snippet=cmd_res.stderr[:20000] if cmd_res.stderr else None,
                        status=status,
                    )
                )
            except Exception as e:
                duration_ms = int((time.time() - start_t) * 1000)
                command_runs.append(
                    CommandEvidence(
                        command=cmd,
                        exit_code=1,
                        duration_ms=duration_ms,
                        stdout_snippet="",
                        stderr_snippet=f"Execution error: {e}",
                        status=TestExecutionStatus.FAILED,
                    )
                )

        # 3. Deterministic Edge-Case Probe (Calculator Demo: Division by zero & addition regression)
        break_it_checks: List[BreakItCheck] = []
        calc_file = wdir / "calculator.py"

        if calc_file.exists():
            break_it_checks.extend(await self._run_calculator_edge_case_probes(ws_provider, workspace))

        # 4. Acceptance Criteria Verification
        commands_all_passed = (
            len(command_runs) > 0 and all(cr.status == TestExecutionStatus.PASSED for cr in command_runs)
        )
        probes_all_passed = (
            len(break_it_checks) == 0 or all(bc.passed for bc in break_it_checks)
        )

        # Update contract criteria verified flags with reliable test/probe mapping
        for criterion in contract.criteria:
            crit_lower = criterion.description.lower()
            if "zero" in crit_lower or "divide" in crit_lower:
                zero_check = next((bc for bc in break_it_checks if "zero" in bc.name.lower()), None)
                if zero_check and zero_check.passed:
                    criterion.verified = True
                    criterion.evidence_note = f"Break-It Probe: {zero_check.actual_behavior}"
                else:
                    criterion.verified = False
                    criterion.evidence_note = (
                        f"Break-It Probe Failed: {zero_check.actual_behavior}"
                        if zero_check
                        else "UNPROVEN: No zero-division probe run."
                    )
            elif "addition" in crit_lower or "regression" in crit_lower or "arithmetic" in crit_lower:
                add_check = next(
                    (bc for bc in break_it_checks if any(k in bc.name.lower() for k in ("addition", "regression", "arithmetic"))),
                    None,
                )
                if add_check and add_check.passed:
                    criterion.verified = True
                    criterion.evidence_note = f"Regression Probe: {add_check.actual_behavior}"
                else:
                    criterion.verified = False
                    criterion.evidence_note = (
                        f"Regression Probe Failed: {add_check.actual_behavior}"
                        if add_check
                        else "UNPROVEN: No arithmetic regression probe run."
                    )
            else:
                if commands_all_passed:
                    criterion.verified = True
                    criterion.evidence_note = f"Verified via test suite exit code 0 ({len(command_runs)} commands passed)"
                else:
                    criterion.verified = False
                    criterion.evidence_note = "UNPROVEN: Required test commands failed or were blocked."

        # Strict Proof Rule: every criterion must be verified, test suite must pass, probes must pass, and scope clean
        all_criteria_met = (
            len(contract.criteria) > 0
            and all(c.verified for c in contract.criteria)
            and (len(command_runs) == 0 or commands_all_passed)
            and probes_all_passed
            and (scope_status == ScopeStatus.CLEAN)
        )

        # Sync updated criteria with contract_data
        task.contract_data = contract.model_dump(mode="json")

        # 5. Overall Verdict Formulation
        if scope_status == ScopeStatus.VIOLATED:
            overall_verdict = "SCOPE_BREACH"
        elif not all_criteria_met:
            overall_verdict = "FAILED_CHECKS"
        else:
            overall_verdict = "PROVEN"

        evidence = VerificationEvidence(
            task_id=task.id,
            scope_status=scope_status,
            unexpected_files_modified=unexpected_modified,
            protected_files_violated=protected_violated,
            command_runs=command_runs,
            break_it_checks=break_it_checks,
            diff_stat=diff_stat,
            all_criteria_met=all_criteria_met,
            overall_verdict=overall_verdict,
        )

        task.verification_data = evidence.model_dump(mode="json")
        logger.info(
            f"[VerificationRunner] Task {task.id} verification completed: verdict={overall_verdict}, "
            f"checks={len(command_runs)}, break_it={len(break_it_checks)}"
        )
        return evidence

    async def _run_calculator_edge_case_probes(
        self, ws_provider: Any, workspace: Workspace
    ) -> List[BreakItCheck]:
        """Execute deterministic boundary probes for the calculator demo."""
        probes: List[BreakItCheck] = []

        # Probe 1: Division by zero raises ValueError
        zero_probe_code = (
            "import sys\n"
            "import calculator\n"
            "try:\n"
            "    res = calculator.divide(10, 0)\n"
            "    print(f'RETURNED_VAL:{res}')\n"
            "    sys.exit(2)\n"
            "except ValueError as ve:\n"
            "    print(f'VALUE_ERROR:{ve}')\n"
            "    sys.exit(0)\n"
            "except ZeroDivisionError:\n"
            "    print('UNHANDLED_ZERO_DIVISION_ERROR')\n"
            "    sys.exit(3)\n"
            "except Exception as e:\n"
            "    print(f'OTHER_ERROR:{type(e).__name__}:{e}')\n"
            "    sys.exit(4)\n"
        )

        res_zero = await ws_provider.execute_command(
            workspace, ["python", "-c", zero_probe_code], timeout_seconds=10
        )

        out_zero = (res_zero.stdout + "\n" + res_zero.stderr).strip()
        passed_zero = (res_zero.exit_code == 0)

        if passed_zero:
            actual_zero = f"Passed: Raised ValueError as expected ({out_zero})"
        elif res_zero.exit_code == 2:
            actual_zero = f"Failed: Returned value instead of raising ValueError ({out_zero})"
        elif res_zero.exit_code == 3:
            actual_zero = "Failed: Raised raw ZeroDivisionError instead of informative ValueError"
        else:
            actual_zero = f"Failed: Probe error (exit {res_zero.exit_code}): {out_zero[:120]}"

        probes.append(
            BreakItCheck(
                name="Zero Division Boundary Probe",
                input_description="divide(10, 0)",
                expected_behavior="Raise ValueError with informative message",
                actual_behavior=actual_zero,
                passed=passed_zero,
            )
        )

        # Probe 2: Arithmetic regression test (addition must still return 5)
        add_probe_code = (
            "import sys\n"
            "import calculator\n"
            "try:\n"
            "    assert calculator.add(2, 3) == 5\n"
            "    print('ADD_OK:5')\n"
            "    sys.exit(0)\n"
            "except AssertionError:\n"
            "    print('ASSERTION_FAILED:add(2, 3) != 5')\n"
            "    sys.exit(2)\n"
            "except Exception as e:\n"
            "    print(f'ERROR:{e}')\n"
            "    sys.exit(3)\n"
        )

        res_add = await ws_provider.execute_command(
            workspace, ["python", "-c", add_probe_code], timeout_seconds=10
        )
        passed_add = (res_add.exit_code == 0)
        actual_add = "Passed: add(2, 3) returned 5" if passed_add else f"Failed regression probe: {res_add.stdout.strip() or res_add.stderr.strip()}"

        probes.append(
            BreakItCheck(
                name="Arithmetic Regression Probe",
                input_description="add(2, 3)",
                expected_behavior="Return 5 without regression",
                actual_behavior=actual_add,
                passed=passed_add,
            )
        )

        return probes


verification_runner = VerificationRunner()
