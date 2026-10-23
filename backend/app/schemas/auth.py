import uuid
from datetime import datetime
from typing import Optional
from pydantic import BaseModel, ConfigDict, EmailStr, Field


class UserRegister(BaseModel):
    """Payload for user registration."""

    email: EmailStr
    password: str = Field(..., min_length=8, max_length=128, description="Minimum 8 characters")
    full_name: Optional[str] = Field(None, max_length=255)


class UserLogin(BaseModel):
    """Payload for user authentication."""

    email: EmailStr
    password: str = Field(..., min_length=1)


class TokenResponse(BaseModel):
    """OAuth2 compatible token response containing access and refresh tokens."""

    access_token: str
    refresh_token: str
    token_type: str = "bearer"
    expires_in: int = Field(..., description="Access token expiration in seconds")


class RefreshTokenRequest(BaseModel):
    """Payload to exchange a refresh token for new credentials."""

    refresh_token: str = Field(..., min_length=10)


class VerifyEmailRequest(BaseModel):
    """Payload to genuinely verify email via token."""

    token: str = Field(..., min_length=10)


class ResendVerificationRequest(BaseModel):
    """Payload to request a new email verification link."""

    email: EmailStr


class UserRead(BaseModel):
    """Public user profile schema."""

    id: uuid.UUID
    email: EmailStr
    full_name: Optional[str] = None
    is_active: bool
    is_verified: bool
    is_superuser: bool
    created_at: datetime
    updated_at: datetime

    model_config = ConfigDict(from_attributes=True)


class RegisterResponse(BaseModel):
    """Response returned upon successful registration."""

    user: UserRead
    message: str
    verification_required: bool = True
    verification_token: Optional[str] = Field(
        None,
        description="Provided in development mode to facilitate direct verification testing",
    )
