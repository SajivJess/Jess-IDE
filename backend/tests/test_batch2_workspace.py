import hashlib
import os
import shutil
import subprocess
import tempfile
import unittest
import uuid

from app.db.models.project import Project
from app.db.models.task import Task
from app.db.models.workspace import Workspace
from app.schemas.project import ProjectCreate, ProjectUpdate
from app.schemas.workspace import WorkspaceStatus
from app.services.meta_agent import (
    _capture_git_baseline,
    _check_stale_review,
    _get_task_scoped_diff,
    _revert_task_changes,
)
from app.services.workspace.local_sandbox import LocalSandboxWorkspaceProvider


class TestBatch2WorkspaceAndGit(unittest.IsolatedAsyncioTestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.mkdtemp(prefix="jess_test_batch2_")
        self.provider = LocalSandboxWorkspaceProvider()
        self.workspace = Workspace(
            id=uuid.uuid4(),
            user_id=uuid.uuid4(),
            name="test-batch2-ws",
            root_path=self.temp_dir,
            status=WorkspaceStatus.RUNNING.value,
        )

    def tearDown(self) -> None:
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def _init_git_repo(self, repo_dir: str) -> None:
        subprocess.run(["git", "init", "-b", "main"], cwd=repo_dir, check=True, capture_output=True)
        subprocess.run(["git", "config", "user.name", "Jess Tester"], cwd=repo_dir, check=True, capture_output=True)
        subprocess.run(["git", "config", "user.email", "tester@jess.local"], cwd=repo_dir, check=True, capture_output=True)
        
        # Initial commit
        init_file = os.path.join(repo_dir, "README.md")
        with open(init_file, "w", encoding="utf-8") as f:
            f.write("# Test Repo\n")
        subprocess.run(["git", "add", "README.md"], cwd=repo_dir, check=True, capture_output=True)
        subprocess.run(["git", "commit", "-m", "Initial commit"], cwd=repo_dir, check=True, capture_output=True)

    def test_workspace_path_traversal_validation(self) -> None:
        # Invalid traversal paths must raise ValidationError
        for bad_path in [
            "../../etc/shadow",
            "../secret_repo",
            "folder/../../outside",
            "path\x00with_null",
            "/",
            "\\",
        ]:
            with self.subTest(bad_path=bad_path):
                with self.assertRaises(ValueError):
                    ProjectCreate(name="BadProj", workspace_path=bad_path)

        # Valid paths must be accepted
        valid_paths = [
            os.path.join(self.temp_dir, "my_repo"),
            "workspaces_data/my_repo",
        ]
        for good_path in valid_paths:
            with self.subTest(good_path=good_path):
                proj = ProjectCreate(name="GoodProj", workspace_path=good_path)
                self.assertEqual(proj.workspace_path, good_path.replace("\\", "/"))

    async def test_safe_git_baseline_captures_untracked_and_modified(self) -> None:
        self._init_git_repo(self.temp_dir)

        # Create pre-existing untracked file
        untracked_path = os.path.join(self.temp_dir, "pre_existing_untracked.txt")
        with open(untracked_path, "w", encoding="utf-8") as f:
            f.write("user note before task")

        # Create pre-existing modification in README.md
        readme_path = os.path.join(self.temp_dir, "README.md")
        with open(readme_path, "a", encoding="utf-8") as f:
            f.write("user uncommitted edit\n")

        baseline = await _capture_git_baseline(self.provider, self.workspace)
        self.assertTrue(baseline["has_git"])
        self.assertTrue(baseline["base_sha"])
        self.assertIn("pre_existing_untracked.txt", baseline["untracked"])
        self.assertIn("README.md", baseline["modified"])

    async def test_revert_task_changes_preserves_pre_existing_files(self) -> None:
        self._init_git_repo(self.temp_dir)

        # 1. Pre-existing untracked file (must NOT be deleted on rejection)
        pre_untracked = os.path.join(self.temp_dir, "my_scratch.txt")
        with open(pre_untracked, "w", encoding="utf-8") as f:
            f.write("important scratchpad")

        # 2. Pre-existing dirty modification in README.md (must NOT be wiped by git checkout)
        readme_path = os.path.join(self.temp_dir, "README.md")
        with open(readme_path, "a", encoding="utf-8") as f:
            f.write("user uncommitted line\n")

        # 3. Pre-existing tracked file that was clean at baseline
        math_file = os.path.join(self.temp_dir, "math.py")
        with open(math_file, "w", encoding="utf-8") as f:
            f.write("def add(a, b): return a + b\n")
        subprocess.run(["git", "add", "math.py"], cwd=self.temp_dir, check=True, capture_output=True)
        subprocess.run(["git", "commit", "-m", "add math"], cwd=self.temp_dir, check=True, capture_output=True)

        baseline = await _capture_git_baseline(self.provider, self.workspace)

        # Now simulate a task that modifies math.py and creates task_script.py
        task_script = os.path.join(self.temp_dir, "task_script.py")
        with open(task_script, "w", encoding="utf-8") as f:
            f.write("def generated_code(): pass\n")

        with open(math_file, "w", encoding="utf-8") as f:
            f.write("def add(a, b): return a + b + 0\n")

        task_owned_files = {"task_script.py", "math.py"}
        file_existed_before_task = {"task_script.py": False, "math.py": True}

        # REJECTION: Revert task changes safely
        await _revert_task_changes(
            ws_provider=self.provider,
            workspace=self.workspace,
            task_owned_files=task_owned_files,
            baseline=baseline,
            file_existed_before_task=file_existed_before_task,
        )

        # Assert task-created file was deleted
        self.assertFalse(os.path.exists(task_script))

        # Assert math.py was restored to clean baseline
        with open(math_file, "r", encoding="utf-8") as f:
            content = f.read()
            self.assertEqual(content, "def add(a, b): return a + b\n")

        # CRITICAL SAFETY CHECK: Pre-existing files MUST be preserved!
        self.assertTrue(os.path.exists(pre_untracked), "Pre-existing untracked file was deleted by revert!")
        with open(pre_untracked, "r", encoding="utf-8") as f:
            self.assertEqual(f.read(), "important scratchpad")

        with open(readme_path, "r", encoding="utf-8") as f:
            readme_content = f.read()
            self.assertIn("user uncommitted line", readme_content, "Pre-existing modification was discarded!")

    async def test_stale_review_detection_branch_and_head_divergence(self) -> None:
        self._init_git_repo(self.temp_dir)
        baseline = await _capture_git_baseline(self.provider, self.workspace)

        # Create a task file and get diff
        task_file = os.path.join(self.temp_dir, "calc.py")
        with open(task_file, "w", encoding="utf-8") as f:
            f.write("def div(a, b): return a / b if b != 0 else 0\n")

        task_owned = {"calc.py"}
        diff_text = await _get_task_scoped_diff(self.provider, self.workspace, task_owned, baseline)
        diff_hash = hashlib.sha256(diff_text.encode("utf-8")).hexdigest()[:16]

        # Check freshness right after generation -> Fresh (returns None for reason)
        stale_reason = await _check_stale_review(
            ws_provider=self.provider,
            workspace=self.workspace,
            baseline_branch=baseline["branch"],
            baseline_sha=baseline["base_sha"],
            diff_hash=diff_hash,
            task_owned_files=task_owned,
            baseline=baseline,
        )
        self.assertIsNone(stale_reason)

        # 1. Stale test: HEAD SHA moves (e.g. an external commit happened)
        another_file = os.path.join(self.temp_dir, "other.txt")
        with open(another_file, "w", encoding="utf-8") as f:
            f.write("unrelated commit\n")
        subprocess.run(["git", "add", "other.txt"], cwd=self.temp_dir, check=True, capture_output=True)
        subprocess.run(["git", "commit", "-m", "unrelated commit"], cwd=self.temp_dir, check=True, capture_output=True)

        stale_reason = await _check_stale_review(
            ws_provider=self.provider,
            workspace=self.workspace,
            baseline_branch=baseline["branch"],
            baseline_sha=baseline["base_sha"],
            diff_hash=diff_hash,
            task_owned_files=task_owned,
            baseline=baseline,
        )
        self.assertIsNotNone(stale_reason)
        self.assertIn("HEAD commit moved", stale_reason)

    async def test_task_scoped_diff_excludes_unrelated_modifications(self) -> None:
        self._init_git_repo(self.temp_dir)
        baseline = await _capture_git_baseline(self.provider, self.workspace)

        # Unrelated dirty change
        readme_path = os.path.join(self.temp_dir, "README.md")
        with open(readme_path, "a", encoding="utf-8") as f:
            f.write("unrelated developer modification\n")

        # Task change
        task_file = os.path.join(self.temp_dir, "app.py")
        with open(task_file, "w", encoding="utf-8") as f:
            f.write("print('hello world')\n")

        task_diff = await _get_task_scoped_diff(self.provider, self.workspace, {"app.py"}, baseline)
        self.assertIn("app.py", task_diff)
        self.assertNotIn("README.md", task_diff)
        self.assertNotIn("unrelated developer modification", task_diff)
