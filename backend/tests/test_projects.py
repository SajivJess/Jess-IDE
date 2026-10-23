import time
import uuid
import pytest
from fastapi.testclient import TestClient

from app.core.config import settings
from app.main import app


@pytest.fixture
def client():
    with TestClient(app) as test_client:
        yield test_client


def create_test_user_and_token(client: TestClient, prefix: str = "user") -> tuple[str, str]:
    """Helper to register and login a test user, returning (user_id, access_token)."""
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
    access_token = login_res.json()["access_token"]

    return user_id, access_token


def test_create_and_list_projects(client: TestClient):
    """Verify that an authenticated user can create projects and list them."""
    _, token = create_test_user_and_token(client, "project_owner")
    headers = {"Authorization": f"Bearer {token}"}

    # Create first project
    create_payload = {
        "name": "Jess Mobile App",
        "description": "Flutter Android developer companion",
        "source_type": "github",
        "repo_url": "https://github.com/SajivJess/jess-ide.git",
        "default_branch": "main",
        "workspace_path": "/workspace/jess_app",
    }
    create_res = client.post(
        f"{settings.API_V1_STR}/projects",
        json=create_payload,
        headers=headers,
    )
    assert create_res.status_code == 201
    p1 = create_res.json()
    assert p1["name"] == "Jess Mobile App"
    assert p1["source_type"] == "github"
    assert p1["repo_url"] == "https://github.com/SajivJess/jess-ide.git"
    assert "id" in p1

    # Create second project
    client.post(
        f"{settings.API_V1_STR}/projects",
        json={"name": "Backend Microservice", "source_type": "local"},
        headers=headers,
    )

    # List projects
    list_res = client.get(f"{settings.API_V1_STR}/projects", headers=headers)
    assert list_res.status_code == 200
    data = list_res.json()
    assert data["total"] == 2
    assert len(data["items"]) == 2
    project_names = [p["name"] for p in data["items"]]
    assert "Jess Mobile App" in project_names
    assert "Backend Microservice" in project_names


def test_cross_user_isolation(client: TestClient):
    """Verify User A cannot read, update, or delete User B's project."""
    _, token_a = create_test_user_and_token(client, "user_a")
    _, token_b = create_test_user_and_token(client, "user_b")

    headers_a = {"Authorization": f"Bearer {token_a}"}
    headers_b = {"Authorization": f"Bearer {token_b}"}

    # User A creates a project
    create_res = client.post(
        f"{settings.API_V1_STR}/projects",
        json={"name": "Confidential Project A", "source_type": "scratch"},
        headers=headers_a,
    )
    assert create_res.status_code == 201
    project_id = create_res.json()["id"]

    # User B lists projects - must NOT see User A's project
    b_list = client.get(f"{settings.API_V1_STR}/projects", headers=headers_b)
    assert b_list.status_code == 200
    assert b_list.json()["total"] == 0

    # User B attempts to GET User A's project
    b_get = client.get(f"{settings.API_V1_STR}/projects/{project_id}", headers=headers_b)
    assert b_get.status_code == 404

    # User B attempts to PATCH User A's project
    b_patch = client.patch(
        f"{settings.API_V1_STR}/projects/{project_id}",
        json={"name": "Hacked Name"},
        headers=headers_b,
    )
    assert b_patch.status_code == 404

    # User B attempts to DELETE User A's project
    b_delete = client.delete(
        f"{settings.API_V1_STR}/projects/{project_id}",
        headers=headers_b,
    )
    assert b_delete.status_code == 404

    # Verify project still exists untouched for User A
    a_get = client.get(f"{settings.API_V1_STR}/projects/{project_id}", headers=headers_a)
    assert a_get.status_code == 200
    assert a_get.json()["name"] == "Confidential Project A"


def test_invalid_source_types_and_malformed_input(client: TestClient):
    """Verify that invalid source_type and malformed URLs are rejected with 422."""
    _, token = create_test_user_and_token(client, "validator")
    headers = {"Authorization": f"Bearer {token}"}

    # Invalid source_type
    res1 = client.post(
        f"{settings.API_V1_STR}/projects",
        json={"name": "Invalid Source", "source_type": "unsupported_type_xyz"},
        headers=headers,
    )
    assert res1.status_code == 422

    # Malformed repo_url
    res2 = client.post(
        f"{settings.API_V1_STR}/projects",
        json={
            "name": "Invalid URL",
            "source_type": "github",
            "repo_url": "ftp://not-supported-scheme.com",
        },
        headers=headers,
    )
    assert res2.status_code == 422

    # Empty name
    res3 = client.post(
        f"{settings.API_V1_STR}/projects",
        json={"name": "", "source_type": "local"},
        headers=headers,
    )
    assert res3.status_code == 422


def test_pagination_and_filtering(client: TestClient):
    """Verify pagination and source-type / search filtering."""
    _, token = create_test_user_and_token(client, "filter_user")
    headers = {"Authorization": f"Bearer {token}"}

    # Create 5 projects across different sources
    projects_data = [
        {"name": "Alpha Web", "source_type": "github", "description": "Frontend react portal"},
        {"name": "Beta API", "source_type": "github", "description": "FastAPI gateway"},
        {"name": "Gamma CLI", "source_type": "local", "description": "Command line tool"},
        {"name": "Delta Template", "source_type": "template", "description": "Starter kit"},
        {"name": "Epsilon Scratch", "source_type": "scratch", "description": "Quick prototype"},
    ]
    for p in projects_data:
        client.post(f"{settings.API_V1_STR}/projects", json=p, headers=headers)

    # Test pagination: limit=2, skip=0
    p1 = client.get(f"{settings.API_V1_STR}/projects?limit=2&skip=0", headers=headers)
    assert p1.status_code == 200
    assert len(p1.json()["items"]) == 2
    assert p1.json()["total"] == 5

    # Test pagination: limit=2, skip=4
    p2 = client.get(f"{settings.API_V1_STR}/projects?limit=2&skip=4", headers=headers)
    assert p2.status_code == 200
    assert len(p2.json()["items"]) == 1

    # Filter by source_type=github
    f_github = client.get(f"{settings.API_V1_STR}/projects?source_type=github", headers=headers)
    assert f_github.status_code == 200
    assert f_github.json()["total"] == 2
    for item in f_github.json()["items"]:
        assert item["source_type"] == "github"

    # Search filter by keyword
    f_search = client.get(f"{settings.API_V1_STR}/projects?search=FastAPI", headers=headers)
    assert f_search.status_code == 200
    assert f_search.json()["total"] == 1
    assert f_search.json()["items"][0]["name"] == "Beta API"


def test_update_and_delete_project(client: TestClient):
    """Verify updating and deleting a project."""
    _, token = create_test_user_and_token(client, "lifecycle_user")
    headers = {"Authorization": f"Bearer {token}"}

    create_res = client.post(
        f"{settings.API_V1_STR}/projects",
        json={"name": "Initial Name", "description": "Initial desc", "source_type": "local"},
        headers=headers,
    )
    project_id = create_res.json()["id"]

    # Update name and description
    patch_res = client.patch(
        f"{settings.API_V1_STR}/projects/{project_id}",
        json={"name": "Updated Name", "default_branch": "develop"},
        headers=headers,
    )
    assert patch_res.status_code == 200
    updated_data = patch_res.json()
    assert updated_data["name"] == "Updated Name"
    assert updated_data["default_branch"] == "develop"
    assert updated_data["description"] == "Initial desc"

    # Delete project
    del_res = client.delete(f"{settings.API_V1_STR}/projects/{project_id}", headers=headers)
    assert del_res.status_code == 200
    assert del_res.json()["status"] == "deleted"

    # Verify project is gone
    get_res = client.get(f"{settings.API_V1_STR}/projects/{project_id}", headers=headers)
    assert get_res.status_code == 404


def test_unauthenticated_requests_rejected(client: TestClient):
    """Verify that requests without valid credentials are appropriately rejected with 401."""
    # List without auth
    r1 = client.get(f"{settings.API_V1_STR}/projects")
    assert r1.status_code == 401

    # Create without auth
    r2 = client.post(f"{settings.API_V1_STR}/projects", json={"name": "Test"})
    assert r2.status_code == 401

    # Fake token
    r3 = client.get(
        f"{settings.API_V1_STR}/projects",
        headers={"Authorization": "Bearer invalid.token.signature"},
    )
    assert r3.status_code == 401
