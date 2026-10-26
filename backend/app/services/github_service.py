"""GitHub Service for Jess IDE.

Handles repository discovery, inspection, cloning, branch management,
and pull request creation using fine-grained Personal Access Tokens (PAT)
or GitHub App credentials.
"""

import logging
import os
import shutil
import subprocess
from typing import Any, Dict, List, Optional
import httpx

from app.core.config import settings

logger = logging.getLogger("jess_github")


class GitHubService:
    """Service wrapping GitHub REST API v3 / v2022-11-28 for Jess IDE."""

    def __init__(self, token: Optional[str] = None, base_url: Optional[str] = None):
        self.token = token if token is not None else settings.GITHUB_TOKEN
        self.base_url = (base_url or settings.GITHUB_API_BASE_URL).rstrip("/")
        self.timeout = 15.0

    def _get_headers(self) -> Dict[str, str]:
        headers = {
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "Jess-IDE/1.0",
        }
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        return headers

    @property
    def is_configured(self) -> bool:
        return bool(self.token and self.token.strip())

    async def get_status(self) -> Dict[str, Any]:
        """Check if token is configured and valid, returning user info."""
        if not self.is_configured:
            return {
                "connected": False,
                "configured": False,
                "message": "No GitHub token configured. Set GITHUB_TOKEN in backend environment.",
            }

        url = f"{self.base_url}/user"
        try:
            async with httpx.AsyncClient(timeout=self.timeout) as client:
                resp = await client.get(url, headers=self._get_headers())
                if resp.status_code == 200:
                    data = resp.json()
                    return {
                        "connected": True,
                        "configured": True,
                        "login": data.get("login"),
                        "name": data.get("name"),
                        "avatar_url": data.get("avatar_url"),
                        "html_url": data.get("html_url"),
                        "public_repos": data.get("public_repos", 0),
                        "total_private_repos": data.get("total_private_repos", 0),
                        "plan": data.get("plan", {}).get("name", "free"),
                    }
                elif resp.status_code == 401:
                    return {
                        "connected": False,
                        "configured": True,
                        "message": "GitHub token is invalid or expired (HTTP 401 Unauthorized).",
                    }
                else:
                    return {
                        "connected": False,
                        "configured": True,
                        "message": f"GitHub API returned HTTP {resp.status_code}: {resp.text[:200]}",
                    }
        except Exception as e:
            logger.error(f"Error checking GitHub status: {e}")
            return {
                "connected": False,
                "configured": True,
                "message": f"Network error connecting to GitHub: {str(e)}",
            }

    async def list_repositories(
        self,
        visibility: Optional[str] = None,
        sort: str = "updated",
        direction: str = "desc",
        per_page: int = 30,
        page: int = 1,
    ) -> List[Dict[str, Any]]:
        """List repositories accessible to the configured token."""
        if not self.is_configured:
            return []

        url = f"{self.base_url}/user/repos"
        params: Dict[str, Any] = {
            "sort": sort,
            "direction": direction,
            "per_page": min(per_page, 100),
            "page": page,
        }
        if visibility:
            params["visibility"] = visibility

        try:
            async with httpx.AsyncClient(timeout=self.timeout) as client:
                resp = await client.get(url, headers=self._get_headers(), params=params)
                if resp.status_code == 200:
                    raw_repos = resp.json()
                    return [
                        {
                            "id": r.get("id"),
                            "name": r.get("name"),
                            "full_name": r.get("full_name"),
                            "private": r.get("private", False),
                            "html_url": r.get("html_url"),
                            "clone_url": r.get("clone_url"),
                            "description": r.get("description"),
                            "default_branch": r.get("default_branch", "main"),
                            "language": r.get("language"),
                            "stargazers_count": r.get("stargazers_count", 0),
                            "forks_count": r.get("forks_count", 0),
                            "updated_at": r.get("updated_at"),
                            "owner": {
                                "login": r.get("owner", {}).get("login"),
                                "avatar_url": r.get("owner", {}).get("avatar_url"),
                            },
                        }
                        for r in raw_repos
                    ]
                else:
                    logger.warning(f"Failed to fetch repositories: {resp.status_code} - {resp.text[:200]}")
                    return []
        except Exception as e:
            logger.error(f"Error listing GitHub repositories: {e}")
            return []

    async def get_repository(self, owner: str, repo: str) -> Optional[Dict[str, Any]]:
        """Get details for a specific repository."""
        if not self.is_configured:
            return None

        url = f"{self.base_url}/repos/{owner}/{repo}"
        try:
            async with httpx.AsyncClient(timeout=self.timeout) as client:
                resp = await client.get(url, headers=self._get_headers())
                if resp.status_code == 200:
                    r = resp.json()
                    return {
                        "id": r.get("id"),
                        "name": r.get("name"),
                        "full_name": r.get("full_name"),
                        "private": r.get("private", False),
                        "html_url": r.get("html_url"),
                        "clone_url": r.get("clone_url"),
                        "description": r.get("description"),
                        "default_branch": r.get("default_branch", "main"),
                        "language": r.get("language"),
                        "stargazers_count": r.get("stargazers_count", 0),
                        "updated_at": r.get("updated_at"),
                    }
                return None
        except Exception as e:
            logger.error(f"Error getting GitHub repository {owner}/{repo}: {e}")
            return None

    async def list_branches(self, owner: str, repo: str) -> List[Dict[str, Any]]:
        """List branches for a given repository."""
        if not self.is_configured:
            return []

        url = f"{self.base_url}/repos/{owner}/{repo}/branches"
        try:
            async with httpx.AsyncClient(timeout=self.timeout) as client:
                resp = await client.get(url, headers=self._get_headers())
                if resp.status_code == 200:
                    return [
                        {
                            "name": b.get("name"),
                            "commit_sha": b.get("commit", {}).get("sha"),
                            "protected": b.get("protected", False),
                        }
                        for b in resp.json()
                    ]
                return []
        except Exception as e:
            logger.error(f"Error listing branches for {owner}/{repo}: {e}")
            return []

    async def create_pull_request(
        self,
        owner: str,
        repo: str,
        title: str,
        head: str,
        base: str,
        body: str = "",
    ) -> Dict[str, Any]:
        """Create a pull request on GitHub."""
        if not self.is_configured:
            return {"success": False, "message": "GitHub token not configured."}

        url = f"{self.base_url}/repos/{owner}/{repo}/pulls"
        payload = {
            "title": title,
            "head": head,
            "base": base,
            "body": body,
        }
        try:
            async with httpx.AsyncClient(timeout=self.timeout) as client:
                resp = await client.post(url, headers=self._get_headers(), json=payload)
                if resp.status_code == 201:
                    pr = resp.json()
                    return {
                        "success": True,
                        "pr_number": pr.get("number"),
                        "html_url": pr.get("html_url"),
                        "title": pr.get("title"),
                    }
                else:
                    return {
                        "success": False,
                        "message": f"GitHub PR creation failed (HTTP {resp.status_code}): {resp.text[:300]}",
                    }
        except Exception as e:
            logger.error(f"Error creating GitHub PR: {e}")
            return {"success": False, "message": str(e)}

    def clone_repository(
        self,
        owner: str,
        repo: str,
        target_dir: str,
        branch: Optional[str] = None,
        git_executable: str = "git",
    ) -> Dict[str, Any]:
        """Clone repository into target_dir using authenticated credentials.
        
        The token is securely used for the clone and stripped from remote URLs
        to avoid persisting credentials in plaintext inside .git/config.
        """
        if not self.is_configured:
            return {"success": False, "message": "No GitHub token configured."}

        # Build authenticated clone URL
        auth_url = f"https://x-access-token:{self.token}@github.com/{owner}/{repo}.git"
        clean_url = f"https://github.com/{owner}/{repo}.git"

        os.makedirs(target_dir, exist_ok=True)
        cmd = [git_executable, "clone", "--depth", "1"]
        if branch:
            cmd.extend(["--branch", branch])
        cmd.extend([auth_url, target_dir])

        try:
            res = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=120,
            )
            if res.returncode != 0:
                # Sanitize error message to ensure token is never exposed
                sanitized_err = res.stderr.replace(self.token, "[REDACTED]")
                return {"success": False, "message": f"Git clone failed: {sanitized_err}"}

            # Reset the remote URL to clean URL so the token is not saved in .git/config
            subprocess.run(
                [git_executable, "remote", "set-url", "origin", clean_url],
                cwd=target_dir,
                capture_output=True,
                timeout=10,
            )
            return {"success": True, "target_dir": target_dir}
        except Exception as e:
            logger.error(f"Error cloning repository: {e}")
            return {"success": False, "message": str(e)}


github_service = GitHubService()
