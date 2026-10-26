import pytest
from typing import Generator
from fastapi.testclient import TestClient
from app.main import app


from app.core.config import settings


@pytest.fixture(autouse=True)
def default_simulated_for_tests(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(settings, "AGENT_PROVIDER", "simulated")


@pytest.fixture(scope="module")
def client() -> Generator[TestClient, None, None]:
    """Test client fixture for synchronous testing."""
    with TestClient(app) as test_client:
        yield test_client
