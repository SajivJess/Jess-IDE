from fastapi.testclient import TestClient
from app.core.config import settings


def test_root_health(client: TestClient) -> None:
    """Verify that GET /health returns HTTP 200 and expected payload."""
    response = client.get("/health")
    assert response.status_code == 200

    data = response.json()
    assert data["status"] == "ok"
    assert data["app"] == settings.PROJECT_NAME
    assert data["version"] == settings.VERSION
    assert data["environment"] == settings.ENVIRONMENT
    assert data["database"] == "connected"
    assert isinstance(data["timestamp"], (int, float))
    assert data["timestamp"] > 0


def test_api_v1_health(client: TestClient) -> None:
    """Verify that GET /api/v1/health returns HTTP 200 and matches root health."""
    response = client.get(f"{settings.API_V1_STR}/health")
    assert response.status_code == 200

    data = response.json()
    assert data["status"] == "ok"
    assert data["app"] == settings.PROJECT_NAME
    assert data["database"] == "connected"


def test_root_ready(client: TestClient) -> None:
    """Verify that GET /ready returns HTTP 200 when database is available."""
    response = client.get("/ready")
    assert response.status_code == 200

    data = response.json()
    assert data["status"] == "ready"
    assert data["database"] == "connected"
    assert isinstance(data["timestamp"], (int, float))


def test_api_v1_ready(client: TestClient) -> None:
    """Verify that GET /api/v1/ready returns HTTP 200 and matches readiness contract."""
    response = client.get(f"{settings.API_V1_STR}/ready")
    assert response.status_code == 200

    data = response.json()
    assert data["status"] == "ready"
    assert data["database"] == "connected"


def test_not_found_returns_404(client: TestClient) -> None:
    """Verify that invalid routes return standard HTTP 404."""
    response = client.get("/api/v1/nonexistent-endpoint-test")
    assert response.status_code == 404
