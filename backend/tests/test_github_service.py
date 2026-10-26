import unittest
from unittest.mock import AsyncMock, MagicMock, patch

from app.core.config import Settings
from app.services.github_service import GitHubService


class TestGitHubService(unittest.IsolatedAsyncioTestCase):
    def test_github_settings_configuration(self) -> None:
        s = Settings(
            GITHUB_TOKEN="ghp_test_token_123456",
            GITHUB_API_BASE_URL="https://api.github.com",
        )
        self.assertEqual(s.GITHUB_TOKEN, "ghp_test_token_123456")
        self.assertEqual(s.GITHUB_API_BASE_URL, "https://api.github.com")

    def test_github_service_is_configured(self) -> None:
        svc_configured = GitHubService(token="ghp_sample_token")
        self.assertTrue(svc_configured.is_configured)

        svc_unconfigured = GitHubService(token="")
        self.assertFalse(svc_unconfigured.is_configured)

    async def test_get_status_authenticated(self) -> None:
        svc = GitHubService(token="mock_valid_token")

        mock_resp = MagicMock()
        mock_resp.status_code = 200
        mock_resp.json.return_value = {
            "login": "testuser",
            "name": "Test User",
            "avatar_url": "https://github.com/images/error/testuser_happy.gif",
            "html_url": "https://github.com/testuser",
            "public_repos": 12,
            "total_private_repos": 5,
        }

        with patch("httpx.AsyncClient.get", new_callable=AsyncMock) as mock_get:
            mock_get.return_value = mock_resp
            status = await svc.get_status()

            self.assertTrue(status["connected"])
            self.assertEqual(status["login"], "testuser")
            self.assertEqual(status["public_repos"], 12)
            self.assertEqual(status["total_private_repos"], 5)

    async def test_list_repositories(self) -> None:
        svc = GitHubService(token="mock_valid_token")

        mock_resp = MagicMock()
        mock_resp.status_code = 200
        mock_resp.json.return_value = [
            {
                "id": 101,
                "name": "project-one",
                "full_name": "testuser/project-one",
                "private": False,
                "html_url": "https://github.com/testuser/project-one",
                "clone_url": "https://github.com/testuser/project-one.git",
                "description": "First project",
                "default_branch": "main",
                "language": "Python",
                "stargazers_count": 10,
                "forks_count": 2,
                "updated_at": "2026-10-26T12:00:00Z",
                "owner": {"login": "testuser", "avatar_url": "https://example.com/avatar.png"},
            }
        ]

        with patch("httpx.AsyncClient.get", new_callable=AsyncMock) as mock_get:
            mock_get.return_value = mock_resp
            repos = await svc.list_repositories()

            self.assertEqual(len(repos), 1)
            self.assertEqual(repos[0]["name"], "project-one")
            self.assertEqual(repos[0]["full_name"], "testuser/project-one")
            self.assertEqual(repos[0]["default_branch"], "main")

    async def test_list_branches(self) -> None:
        svc = GitHubService(token="mock_valid_token")

        mock_resp = MagicMock()
        mock_resp.status_code = 200
        mock_resp.json.return_value = [
            {"name": "main", "commit": {"sha": "abc1234"}, "protected": True},
            {"name": "dev", "commit": {"sha": "def5678"}, "protected": False},
        ]

        with patch("httpx.AsyncClient.get", new_callable=AsyncMock) as mock_get:
            mock_get.return_value = mock_resp
            branches = await svc.list_branches("testuser", "project-one")

            self.assertEqual(len(branches), 2)
            self.assertEqual(branches[0]["name"], "main")
            self.assertTrue(branches[0]["protected"])

    async def test_create_pull_request(self) -> None:
        svc = GitHubService(token="mock_valid_token")

        mock_resp = MagicMock()
        mock_resp.status_code = 201
        mock_resp.json.return_value = {
            "number": 42,
            "html_url": "https://github.com/testuser/project-one/pull/42",
            "title": "Fix bug in calculator",
        }

        with patch("httpx.AsyncClient.post", new_callable=AsyncMock) as mock_post:
            mock_post.return_value = mock_resp
            result = await svc.create_pull_request(
                owner="testuser",
                repo="project-one",
                title="Fix bug in calculator",
                head="fix/calc",
                base="main",
            )

            self.assertTrue(result["success"])
            self.assertEqual(result["pr_number"], 42)


if __name__ == "__main__":
    unittest.main()
