import time
from datetime import datetime, timedelta, timezone
import pytest
from fastapi.testclient import TestClient

from app.core.config import settings
from app.core.security import create_access_token, hash_password, verify_password
from app.main import app


@pytest.fixture
def client():
    with TestClient(app) as test_client:
        yield test_client


def test_argon2_hashing_and_verification():
    """Verify that password hashing uses genuine Argon2id and correctly verifies."""
    pw = "SuperSecurePassword123!"
    hashed = hash_password(pw)

    assert hashed.startswith("$argon2id$")
    assert verify_password(pw, hashed) is True
    assert verify_password("WrongPassword!", hashed) is False
    assert verify_password("", hashed) is False


def test_user_registration_success(client: TestClient):
    """Test standard user registration flow."""
    unique_email = f"user_{int(time.time() * 1000)}@example.com"
    response = client.post(
        f"{settings.API_V1_STR}/auth/register",
        json={
            "email": unique_email,
            "password": "Password1234!",
            "full_name": "Test Developer",
        },
    )
    assert response.status_code == 201
    data = response.json()
    assert data["user"]["email"] == unique_email
    assert data["user"]["full_name"] == "Test Developer"
    assert data["user"]["is_active"] is True
    assert data["user"]["is_verified"] is False
    assert data["verification_required"] is True
    assert "verification_token" in data


def test_duplicate_registration_returns_409(client: TestClient):
    """Test that registering an existing email returns HTTP 409 Conflict."""
    dup_email = f"duplicate_{int(time.time() * 1000)}@example.com"
    payload = {
        "email": dup_email,
        "password": "Password1234!",
        "full_name": "Original User",
    }
    # First registration
    res1 = client.post(f"{settings.API_V1_STR}/auth/register", json=payload)
    assert res1.status_code == 201

    # Second registration with same email
    res2 = client.post(f"{settings.API_V1_STR}/auth/register", json=payload)
    assert res2.status_code == 409
    assert "already exists" in res2.json()["detail"]


def test_login_success(client: TestClient):
    """Test successful login returning short-lived access JWT and refresh token."""
    email = f"login_ok_{int(time.time() * 1000)}@example.com"
    password = "ValidPassword123!"
    client.post(
        f"{settings.API_V1_STR}/auth/register",
        json={"email": email, "password": password},
    )

    response = client.post(
        f"{settings.API_V1_STR}/auth/login",
        json={"email": email, "password": password},
    )
    assert response.status_code == 200
    data = response.json()
    assert "access_token" in data
    assert "refresh_token" in data
    assert data["token_type"] == "bearer"
    assert data["expires_in"] == settings.ACCESS_TOKEN_EXPIRE_MINUTES * 60


def test_login_invalid_credentials(client: TestClient):
    """Test login with wrong password and nonexistent user."""
    email = f"wrong_pw_{int(time.time() * 1000)}@example.com"
    client.post(
        f"{settings.API_V1_STR}/auth/register",
        json={"email": email, "password": "CorrectPassword123!"},
    )

    # Wrong password
    res1 = client.post(
        f"{settings.API_V1_STR}/auth/login",
        json={"email": email, "password": "WrongPassword!"},
    )
    assert res1.status_code == 401
    assert "Invalid email or password" in res1.json()["detail"]

    # Nonexistent user
    res2 = client.post(
        f"{settings.API_V1_STR}/auth/login",
        json={"email": "nonexistent@example.com", "password": "AnyPassword!"},
    )
    assert res2.status_code == 401
    assert "Invalid email or password" in res2.json()["detail"]


def test_protected_me_endpoint(client: TestClient):
    """Test GET /api/v1/auth/me with valid, expired, and missing tokens."""
    email = f"me_test_{int(time.time() * 1000)}@example.com"
    password = "MyPassword123!"
    reg_res = client.post(
        f"{settings.API_V1_STR}/auth/register",
        json={"email": email, "password": password, "full_name": "Auth Me"},
    )
    user_id = reg_res.json()["user"]["id"]

    login_res = client.post(
        f"{settings.API_V1_STR}/auth/login",
        json={"email": email, "password": password},
    )
    access_token = login_res.json()["access_token"]

    # Valid token
    me_res = client.get(
        f"{settings.API_V1_STR}/auth/me",
        headers={"Authorization": f"Bearer {access_token}"},
    )
    assert me_res.status_code == 200
    data = me_res.json()
    assert data["id"] == user_id
    assert data["email"] == email
    assert data["full_name"] == "Auth Me"

    # Missing token
    unauth_res = client.get(f"{settings.API_V1_STR}/auth/me")
    assert unauth_res.status_code == 401

    # Tampered / invalid token
    bad_res = client.get(
        f"{settings.API_V1_STR}/auth/me",
        headers={"Authorization": "Bearer bad.token.payload"},
    )
    assert bad_res.status_code == 401

    # Expired token
    expired_token = create_access_token(
        subject=user_id,
        expires_delta=timedelta(seconds=-10),
    )
    exp_res = client.get(
        f"{settings.API_V1_STR}/auth/me",
        headers={"Authorization": f"Bearer {expired_token}"},
    )
    assert exp_res.status_code == 401
    assert "expired" in exp_res.json()["detail"]


def test_refresh_token_rotation(client: TestClient):
    """Test refresh token rotation issues new access and refresh tokens."""
    email = f"refresh_{int(time.time() * 1000)}@example.com"
    password = "SecretPassword123!"
    client.post(
        f"{settings.API_V1_STR}/auth/register",
        json={"email": email, "password": password},
    )
    login_res = client.post(
        f"{settings.API_V1_STR}/auth/login",
        json={"email": email, "password": password},
    )
    refresh_token_1 = login_res.json()["refresh_token"]

    # Rotate token
    rotate_res = client.post(
        f"{settings.API_V1_STR}/auth/refresh",
        json={"refresh_token": refresh_token_1},
    )
    assert rotate_res.status_code == 200
    rotate_data = rotate_res.json()
    refresh_token_2 = rotate_data["refresh_token"]
    access_token_2 = rotate_data["access_token"]
    assert refresh_token_2 != refresh_token_1

    # New access token works
    me_res = client.get(
        f"{settings.API_V1_STR}/auth/me",
        headers={"Authorization": f"Bearer {access_token_2}"},
    )
    assert me_res.status_code == 200
    assert me_res.json()["email"] == email


def test_refresh_token_replay_attack_detection(client: TestClient):
    """Test that reusing an already rotated refresh token triggers replay protection."""
    email = f"replay_{int(time.time() * 1000)}@example.com"
    password = "SecretPassword123!"
    client.post(
        f"{settings.API_V1_STR}/auth/register",
        json={"email": email, "password": password},
    )
    login_res = client.post(
        f"{settings.API_V1_STR}/auth/login",
        json={"email": email, "password": password},
    )
    original_refresh = login_res.json()["refresh_token"]

    # First rotation succeeds
    rot1 = client.post(
        f"{settings.API_V1_STR}/auth/refresh",
        json={"refresh_token": original_refresh},
    )
    assert rot1.status_code == 200
    second_refresh = rot1.json()["refresh_token"]

    # Replay attack: Attacker tries to use original_refresh again
    replay_attempt = client.post(
        f"{settings.API_V1_STR}/auth/refresh",
        json={"refresh_token": original_refresh},
    )
    assert replay_attempt.status_code == 401
    assert "Token reuse detected" in replay_attempt.json()["detail"]

    # Even the legitimate second_refresh should now be revoked because the entire family is compromised
    rot2 = client.post(
        f"{settings.API_V1_STR}/auth/refresh",
        json={"refresh_token": second_refresh},
    )
    assert rot2.status_code == 401


def test_genuine_email_verification_flow(client: TestClient):
    """Test end-to-end genuine email verification and verification status endpoint."""
    email = f"verify_{int(time.time() * 1000)}@example.com"
    reg_res = client.post(
        f"{settings.API_V1_STR}/auth/register",
        json={"email": email, "password": "Password1234!"},
    )
    assert reg_res.status_code == 201
    verification_token = reg_res.json()["verification_token"]
    assert verification_token is not None

    # Status before verification
    status_before = client.get(
        f"{settings.API_V1_STR}/auth/verify-status",
        params={"email": email},
    )
    assert status_before.status_code == 200
    assert status_before.json()["is_verified"] is False

    # Attempt verification with invalid token
    bad_verify = client.post(
        f"{settings.API_V1_STR}/auth/verify-email",
        json={"token": "invalid_token_string_here_12345"},
    )
    assert bad_verify.status_code == 400

    # Genuine verification with valid token
    good_verify = client.post(
        f"{settings.API_V1_STR}/auth/verify-email",
        json={"token": verification_token},
    )
    assert good_verify.status_code == 200
    assert good_verify.json()["status"] == "verified"

    # Status after verification
    status_after = client.get(
        f"{settings.API_V1_STR}/auth/verify-status",
        params={"email": email},
    )
    assert status_after.status_code == 200
    assert status_after.json()["is_verified"] is True

    # Token reuse should fail
    reuse_verify = client.post(
        f"{settings.API_V1_STR}/auth/verify-email",
        json={"token": verification_token},
    )
    assert reuse_verify.status_code == 400
    assert "already been used" in reuse_verify.json()["detail"]
