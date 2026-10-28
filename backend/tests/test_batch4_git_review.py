import os
import shutil
import subprocess
import tempfile
import unittest
import uuid

from app.db.models.workspace import Workspace
from app.schemas.workspace import WorkspaceStatus
from app.services.task_recovery import INTERRUPTED_REASON, reconcile_interrupted_tasks
from app.services.workspace.local_sandbox import LocalSandboxWorkspaceProvider


class TestBatch4GitReviewAndBranchManagement(unittest.IsolatedAsyncioTestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.mkdtemp(prefix="jess_test_batch4_")
        self.provider = LocalSandboxWorkspaceProvider()
        self.workspace = Workspace(
            id=uuid.uuid4(),
            user_id=uuid.uuid4(),
            name="test-batch4-ws",
            root_path=self.temp_dir,
            status=WorkspaceStatus.RUNNING.value,
        )
        self._init_git_repo(self.temp_dir)

    def tearDown(self) -> None:
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def _init_git_repo(self, repo_dir: str) -> None:
        subprocess.run(["git", "init", "-b", "main"], cwd=repo_dir, check=True, capture_output=True)
        subprocess.run(["git", "config", "user.name", "Jess Tester"], cwd=repo_dir, check=True, capture_output=True)
        subprocess.run(["git", "config", "user.email", "tester@jess.local"], cwd=repo_dir, check=True, capture_output=True)

        # Initial commit
        init_file = os.path.join(repo_dir, "README.md")
        with open(init_file, "w", encoding="utf-8") as f:
            f.write("# Project Alpha\nInitial documentation.\n")
        subprocess.run(["git", "add", "README.md"], cwd=repo_dir, check=True, capture_output=True)
        subprocess.run(["git", "commit", "-m", "Initial commit on main"], cwd=repo_dir, check=True, capture_output=True)

    async def test_get_git_branches(self) -> None:
        # Initial state: only main branch
        branches_resp = await self.provider.get_git_branches(self.workspace)
        self.assertEqual(branches_resp.current_branch, "main")
        self.assertEqual(len(branches_resp.branches), 1)
        self.assertTrue(branches_resp.branches[0].is_current)
        self.assertEqual(branches_resp.branches[0].name, "main")
        self.assertIsNotNone(branches_resp.branches[0].commit_sha)

    async def test_checkout_and_create_branch(self) -> None:
        # Create and checkout a feature branch
        status = await self.provider.checkout_git_branch(
            self.workspace,
            branch="feature/recovery-hardening",
            create_new=True,
        )
        self.assertEqual(status.branch, "feature/recovery-hardening")

        # Verify branches list reflects the new branch and current branch
        branches_resp = await self.provider.get_git_branches(self.workspace)
        self.assertEqual(branches_resp.current_branch, "feature/recovery-hardening")
        self.assertEqual(len(branches_resp.branches), 2)
        active_b = [b for b in branches_resp.branches if b.is_current][0]
        self.assertEqual(active_b.name, "feature/recovery-hardening")

        # Switch back to main
        status_main = await self.provider.checkout_git_branch(
            self.workspace,
            branch="main",
            create_new=False,
        )
        self.assertEqual(status_main.branch, "main")

    async def test_branch_name_security_validation(self) -> None:
        # Security: Injection and invalid branch names must be rejected
        bad_branches = [
            "; rm -rf /",
            "feature/../escape",
            "-b malicious",
            "branch name with spaces",
            "branch.lock",
            "/leading_slash",
            "trailing_slash/",
            "double//slashes",
        ]
        for bad in bad_branches:
            with self.subTest(bad_branch=bad):
                with self.assertRaises(ValueError):
                    await self.provider.checkout_git_branch(
                        self.workspace,
                        branch=bad,
                        create_new=True,
                    )

    async def test_diff_with_untracked_and_modified_files(self) -> None:
        # 1. Modify existing file
        with open(os.path.join(self.temp_dir, "README.md"), "a", encoding="utf-8") as f:
            f.write("Added new line in Batch 4.\n")

        # 2. Add a new untracked file
        with open(os.path.join(self.temp_dir, "new_service.py"), "w", encoding="utf-8") as f:
            f.write("def run():\n    return 'success'\n")

        diff_resp = await self.provider.get_git_diff(self.workspace)
        self.assertGreater(diff_resp.files_changed, 0)
        self.assertGreater(diff_resp.additions, 0)
        self.assertTrue(len(diff_resp.files) >= 2)

        paths = [file_diff.path for file_diff in diff_resp.files]
        self.assertIn("README.md", paths)
        self.assertIn("new_service.py", paths)

        # Check untracked synthetic diff
        untracked = [f for f in diff_resp.files if f.path == "new_service.py"][0]
        self.assertEqual(untracked.status, "added")
        self.assertGreater(untracked.additions, 0)
        self.assertIn("+def run():", untracked.patch)

    async def test_commit_git_changes(self) -> None:
        # Modify file and create commit
        with open(os.path.join(self.temp_dir, "README.md"), "a", encoding="utf-8") as f:
            f.write("Commit verification line.\n")

        commit_result = await self.provider.commit_git_changes(
            self.workspace,
            message="feat: verify git review commit workflow",
            author_name="Jess Mobile User",
            author_email="user@jess.local",
        )

        self.assertTrue(commit_result.success)
        self.assertEqual(commit_result.branch, "main")
        self.assertGreater(len(commit_result.commit_sha), 0)
        self.assertIn("README.md", commit_result.files_committed)

        # Working tree must be clean now
        status = await self.provider.get_git_status(self.workspace)
        self.assertTrue(status.is_clean)

    def test_interrupted_task_reassurance_message(self) -> None:
        # Verify the user explanation message explicitly reassures about preserved disk files
        self.assertIn("preserved on disk", INTERRUPTED_REASON)
        self.assertIn("Changes", INTERRUPTED_REASON)
        self.assertIn("interrupted by a backend restart", INTERRUPTED_REASON)


if __name__ == "__main__":
    unittest.main()
