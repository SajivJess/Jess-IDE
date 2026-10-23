import pytest
from typing import Generator
from fastapi.testclient import TestClient
from app.main import app


@pytest.fixture(scope="module")
def client() -> Generator[TestClient, None, None]:
    """Test client fixture for synchronous testing."""
    with TestClient(app) as test_client:
        yield test_client
