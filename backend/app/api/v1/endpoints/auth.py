import uuid
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, Optional
from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import func, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import get_current_user
from app.core.config import settings
from app.core.logging import logger
from app.core.security import (
    create_access_token,
    generate_secure_token,
    hash_password,
    hash_token,
    verify_password,
)
from app.db.models.refresh_token import RefreshToken
from app.db.models.user import User
from app.db.models.verification_token import EmailVerificationToken
from app.db.session import get_db
from app.schemas.auth import (
    RefreshTokenRequest,
    RegisterResponse,
    ResendVerificationRequest,
    TokenResponse,
    UserLogin,
    UserRead,
    UserRegister,
    VerifyEmailRequest,
)

router = APIRouter()


@router.post(
    "/register",
    response_model=RegisterResponse,
    status_code=status.HTTP_201_CREATED,
    summary="Register a new developer account",
)
async def register(
    payload: UserRegister,
    db: AsyncSession = Depends(get_db),
) -> RegisterResponse:
    """Create a new user account with Argon2 password hashing and issue an email verification token."""
    email_clean = payload.email.lower().strip()

    # Check for existing email address
    existing_result = await db.execute(
        select(User).where(func.lower(User.email) == email_clean)
    )
    if existing_result.scalar_one_or_none():
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="An account with this email address already exists.",
        )

    # Hash password with Argon2id
    hashed = hash_password(payload.password)

    user = User(
        email=email_clean,
        hashed_password=hashed,
        full_name=payload.full_name.strip() if payload.full_name else None,
        is_active=True,
        is_verified=False,
        is_superuser=False,
    )
    db.add(user)
    await db.flush()

    # Generate genuine verification token
    raw_verification_token = generate_secure_token(32)
    token_hash = hash_token(raw_verification_token)
    expires_at = datetime.now(timezone.utc) + timedelta(
        hours=settings.EMAIL_VERIFICATION_TOKEN_EXPIRE_HOURS
    )

    verification_record = EmailVerificationToken(
        user_id=user.id,
        token_hash=token_hash,
        expires_at=expires_at,
    )
    db.add(verification_record)
    await db.commit()
    await db.refresh(user)

    logger.info(f"Registered new user: {user.email} (id: {user.id})")

    return RegisterResponse(
        user=UserRead.model_validate(user),
        message="Registration successful. Please verify your email before accessing workspace resources.",
        verification_required=True,
        verification_token=raw_verification_token if settings.DEBUG else None,
    )


@router.post(
    "/login",
    response_model=TokenResponse,
    summary="Authenticate and receive access & refresh tokens",
)
async def login(
    payload: UserLogin,
    db: AsyncSession = Depends(get_db),
) -> TokenResponse:
    """Validate credentials and return short-lived access JWT and opaque refresh token."""
    email_clean = payload.email.lower().strip()

    result = await db.execute(
        select(User).where(func.lower(User.email) == email_clean)
    )
    user = result.scalar_one_or_none()

    # Constant-time mitigation against user enumeration
    if not user:
        verify_password("dummy_password_timing_pad", "$argon2id$v=19$m=65536,t=3,p=4$c29tZXNhbHQ$RdescudvJCsgqlfreuzflSVJWgLkMmYWdcnezqpAvko")
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid email or password.",
            headers={"WWW-Authenticate": "Bearer"},
        )

    if not verify_password(payload.password, user.hashed_password):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid email or password.",
            headers={"WWW-Authenticate": "Bearer"},
        )

    if not user.is_active:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Account is deactivated.",
        )

    # Issue access token (15 mins)
    access_token = create_access_token(
        subject=user.id,
        extra_claims={"email": user.email, "is_verified": user.is_verified},
    )

    # Issue opaque refresh token (7 days) with token family
    raw_refresh_token = generate_secure_token(48)
    refresh_hash = hash_token(raw_refresh_token)
    family_id = uuid.uuid4()
    expires_at = datetime.now(timezone.utc) + timedelta(
        days=settings.REFRESH_TOKEN_EXPIRE_DAYS
    )

    db_refresh_token = RefreshToken(
        user_id=user.id,
        token_hash=refresh_hash,
        family_id=family_id,
        expires_at=expires_at,
    )
    db.add(db_refresh_token)
    await db.commit()

    return TokenResponse(
        access_token=access_token,
        refresh_token=raw_refresh_token,
        token_type="bearer",
        expires_in=settings.ACCESS_TOKEN_EXPIRE_MINUTES * 60,
    )


@router.post(
    "/refresh",
    response_model=TokenResponse,
    summary="Rotate refresh token and issue new access token",
)
async def refresh_tokens(
    payload: RefreshTokenRequest,
    db: AsyncSession = Depends(get_db),
) -> TokenResponse:
    """Rotate refresh token with family tracking and replay attack protection."""
    token_hash = hash_token(payload.refresh_token)

    result = await db.execute(
        select(RefreshToken).where(RefreshToken.token_hash == token_hash)
    )
    token_record = result.scalar_one_or_none()

    if not token_record:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or expired refresh token.",
            headers={"WWW-Authenticate": "Bearer"},
        )

    # Replay attack detection: token was already revoked
    if token_record.revoked_at is not None:
        logger.warning(
            f"Token reuse detected for family {token_record.family_id} user {token_record.user_id}! Revoking all family tokens."
        )
        # Revoke entire token family to protect user account
        await db.execute(
            update(RefreshToken)
            .where(RefreshToken.family_id == token_record.family_id)
            .values(revoked_at=datetime.now(timezone.utc))
        )
        await db.commit()
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Token reuse detected. All sessions in this chain have been invalidated.",
            headers={"WWW-Authenticate": "Bearer"},
        )

    # Check expiration
    now = datetime.now(timezone.utc)
    # Ensure timezone awareness for comparison
    token_expires = token_record.expires_at
    if token_expires.tzinfo is None:
        token_expires = token_expires.replace(tzinfo=timezone.utc)

    if token_expires < now:
        token_record.revoked_at = now
        await db.commit()
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Refresh token has expired.",
            headers={"WWW-Authenticate": "Bearer"},
        )

    user = await db.get(User, token_record.user_id)
    if not user or not user.is_active:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="User account is inactive or not found.",
            headers={"WWW-Authenticate": "Bearer"},
        )

    # Revoke current token
    token_record.revoked_at = now

    # Issue new rotated refresh token in the same family
    new_raw_refresh = generate_secure_token(48)
    new_hash = hash_token(new_raw_refresh)
    new_expires_at = now + timedelta(days=settings.REFRESH_TOKEN_EXPIRE_DAYS)

    new_token_record = RefreshToken(
        user_id=user.id,
        token_hash=new_hash,
        family_id=token_record.family_id,
        expires_at=new_expires_at,
    )
    db.add(new_token_record)

    # Issue new access token
    access_token = create_access_token(
        subject=user.id,
        extra_claims={"email": user.email, "is_verified": user.is_verified},
    )

    await db.commit()

    return TokenResponse(
        access_token=access_token,
        refresh_token=new_raw_refresh,
        token_type="bearer",
        expires_in=settings.ACCESS_TOKEN_EXPIRE_MINUTES * 60,
    )


@router.get(
    "/me",
    response_model=UserRead,
    summary="Get current authenticated user profile",
)
async def get_me(
    current_user: User = Depends(get_current_user),
) -> UserRead:
    """Retrieve profile of currently authenticated user identified by JWT access token."""
    return UserRead.model_validate(current_user)


@router.post(
    "/verify-email",
    summary="Genuinely verify an account using an email token",
)
async def verify_email(
    payload: VerifyEmailRequest,
    db: AsyncSession = Depends(get_db),
) -> Dict[str, Any]:
    """Verify user account with a genuine token. Rejects expired or reused tokens."""
    token_hash = hash_token(payload.token)

    result = await db.execute(
        select(EmailVerificationToken).where(
            EmailVerificationToken.token_hash == token_hash
        )
    )
    token_record = result.scalar_one_or_none()

    if not token_record:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Invalid or expired verification token.",
        )

    if token_record.used_at is not None:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Verification token has already been used.",
        )

    now = datetime.now(timezone.utc)
    token_expires = token_record.expires_at
    if token_expires.tzinfo is None:
        token_expires = token_expires.replace(tzinfo=timezone.utc)

    if token_expires < now:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Verification token has expired. Please request a new one.",
        )

    user = await db.get(User, token_record.user_id)
    if not user:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="User associated with token not found.",
        )

    user.is_verified = True
    token_record.used_at = now
    await db.commit()

    logger.info(f"User email verified: {user.email}")
    return {
        "status": "verified",
        "message": "Email address successfully verified.",
        "email": user.email,
    }


@router.post(
    "/resend-verification",
    summary="Resend verification email to user",
)
async def resend_verification(
    payload: ResendVerificationRequest,
    db: AsyncSession = Depends(get_db),
) -> Dict[str, Any]:
    """Issue a new verification token. Returns a generic response to prevent account enumeration."""
    email_clean = payload.email.lower().strip()

    result = await db.execute(
        select(User).where(func.lower(User.email) == email_clean)
    )
    user = result.scalar_one_or_none()

    raw_token: Optional[str] = None
    if user and not user.is_verified:
        # Invalidate existing unused tokens for this user
        now = datetime.now(timezone.utc)
        await db.execute(
            update(EmailVerificationToken)
            .where(
                EmailVerificationToken.user_id == user.id,
                EmailVerificationToken.used_at.is_(None),
            )
            .values(used_at=now)
        )

        # Issue new token
        raw_token = generate_secure_token(32)
        token_hash = hash_token(raw_token)
        expires_at = now + timedelta(
            hours=settings.EMAIL_VERIFICATION_TOKEN_EXPIRE_HOURS
        )
        new_record = EmailVerificationToken(
            user_id=user.id,
            token_hash=token_hash,
            expires_at=expires_at,
        )
        db.add(new_record)
        await db.commit()
        logger.info(f"Dispatched new email verification for {user.email}")

    response_payload: Dict[str, Any] = {
        "status": "dispatched",
        "message": "If an unverified account exists with this email, a verification link has been sent.",
    }
    if settings.DEBUG and raw_token:
        response_payload["verification_token"] = raw_token

    return response_payload


@router.get(
    "/verify-status",
    summary="Check email verification status for an email",
)
async def verify_status(
    email: str = Query(..., description="Email address to check status for"),
    db: AsyncSession = Depends(get_db),
) -> Dict[str, Any]:
    """Check genuine verification status of an email address."""
    email_clean = email.lower().strip()
    result = await db.execute(
        select(User).where(func.lower(User.email) == email_clean)
    )
    user = result.scalar_one_or_none()
    if not user:
        return {"email": email_clean, "is_verified": False, "exists": False}

    return {"email": user.email, "is_verified": user.is_verified, "exists": True}
