import json
from typing import Any, List, Optional, Union
from pydantic import field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Application Settings managed through environment variables."""

    PROJECT_NAME: str = "MuseFlow Backend"
    VERSION: str = "0.1.0"
    ENVIRONMENT: str = "development"
    DEBUG: bool = True
    API_V1_STR: str = "/api/v1"

    # Server Bindings
    HOST: str = "127.0.0.1"
    PORT: int = 8000

    # CORS Configuration
    CORS_ORIGINS: List[str] = [
        "http://localhost",
        "http://localhost:3000",
        "http://localhost:8080",
        "http://127.0.0.1:3000",
        "http://127.0.0.1:8080",
    ]

    # Database Configuration
    DATABASE_URL: str = "sqlite+aiosqlite:///./jess_dev.db"
    DB_POOL_SIZE: int = 5
    DB_MAX_OVERFLOW: int = 10
    DB_POOL_TIMEOUT: int = 30
    DB_ECHO: bool = False

    # Security & Authentication
    SECRET_KEY: str = "jess_dev_super_secret_jwt_signing_key_min_32_bytes_long_123456"
    JWT_ALGORITHM: str = "HS256"
    ACCESS_TOKEN_EXPIRE_MINUTES: int = 15
    REFRESH_TOKEN_EXPIRE_DAYS: int = 7
    EMAIL_VERIFICATION_TOKEN_EXPIRE_HOURS: int = 24

    # Workspace Execution Settings
    WORKSPACE_DATA_DIR: str = "workspaces_data"
    DEFAULT_WORKSPACE_IMAGE: str = "python:3.10-slim"
    WORKSPACE_COMMAND_TIMEOUT_SECONDS: int = 60
    WORKSPACE_MAX_OUTPUT_BYTES: int = 1048576  # 1 MB

    # Gemini & LLM Orchestration
    GEMINI_API_KEY: Optional[str] = None
    GEMINI_MODEL: str = "gemini-2.5-flash"
    GEMINI_API_BASE: str = "https://generativelanguage.googleapis.com/v1beta"

    # Meta Model API Orchestration
    MODEL_API_KEY: Optional[str] = None
    META_MODEL_ID: str = "muse-spark-1.3"  # Primary coding agent
    META_VOICE_MODEL_ID: str = "muse-voice-transcribe-1.0"  # Voice transcription
    META_IMAGE_MODEL_ID: str = "muse-image-1.0"  # UI design suggestions
    META_MODEL_BASE_URL: str = "https://api.meta.ai/v1"
    AGENT_PROVIDER: str = "meta"  # "meta" or "simulated"
    META_MAX_TOOL_ITERATIONS: int = 15
    META_MAX_REPAIR_ATTEMPTS: int = 3
    META_REQUEST_TIMEOUT_SECONDS: int = 90
    META_CONTEXT_BUDGET_TOKENS: int = 12000
    META_MAX_HISTORY_TURNS: int = 8
    REQUIRE_DOCKER_ISOLATION: bool = False

    # GitHub Integration
    GITHUB_TOKEN: Optional[str] = None
    GITHUB_API_BASE_URL: str = "https://api.github.com"

    # Public Preview & Tunnel Configuration
    PUBLIC_TUNNEL_URL: Optional[str] = None

    @field_validator("CORS_ORIGINS", mode="before")
    @classmethod
    def assemble_cors_origins(cls, v: Union[str, List[str]]) -> List[str]:
        if isinstance(v, str):
            v_trimmed = v.strip()
            if v_trimmed.startswith("[") and v_trimmed.endswith("]"):
                try:
                    return json.loads(v_trimmed)
                except Exception:
                    pass
            return [i.strip() for i in v_trimmed.split(",") if i.strip()]
        elif isinstance(v, list):
            return v
        return []

    def model_post_init(self, __context: Any) -> None:
        """Validate security settings post-initialization."""
        env_lower = self.ENVIRONMENT.lower()
        if env_lower in ("production", "staging"):
            if (
                self.SECRET_KEY == "jess_dev_super_secret_jwt_signing_key_min_32_bytes_long_123456"
                or len(self.SECRET_KEY) < 32
            ):
                raise ValueError(
                    "Insecure or weak default SECRET_KEY detected in production/staging. "
                    "You must configure a strong, random SECRET_KEY (minimum 32 characters) via environment variable or .env."
                )

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        case_sensitive=True,
        extra="ignore",
    )


settings = Settings()
