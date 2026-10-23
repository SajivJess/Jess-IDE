import re
import uuid
from datetime import datetime
from typing import List, Optional
from pydantic import BaseModel, ConfigDict, Field, field_validator

ALLOWED_SOURCE_TYPES = {"github", "local", "scratch", "template", "ideation", "host", "zip"}


class ProjectCreate(BaseModel):
    """Payload to create a new project."""

    name: str = Field(..., min_length=1, max_length=100, description="Project name")
    description: Optional[str] = Field(None, max_length=2000, description="Project description")
    source_type: str = Field("local", description="Source type: github, local, scratch, template, ideation, host, zip")
    repo_url: Optional[str] = Field(None, max_length=512, description="Git repository URL if applicable")
    default_branch: str = Field("main", min_length=1, max_length=100, description="Default git branch")
    workspace_path: Optional[str] = Field(None, max_length=512, description="Local or remote workspace folder path")

    @field_validator("source_type")
    @classmethod
    def validate_source_type(cls, v: str) -> str:
        clean = v.strip().lower()
        if clean not in ALLOWED_SOURCE_TYPES:
            raise ValueError(
                f"Invalid source_type '{v}'. Allowed types: {', '.join(sorted(ALLOWED_SOURCE_TYPES))}"
            )
        return clean

    @field_validator("repo_url")
    @classmethod
    def validate_repo_url(cls, v: Optional[str]) -> Optional[str]:
        if not v:
            return None
        v_clean = v.strip()
        if not (v_clean.startswith("http://") or v_clean.startswith("https://") or v_clean.startswith("git@")):
            raise ValueError("repo_url must be a valid HTTP, HTTPS, or SSH git URL.")
        return v_clean


class ProjectUpdate(BaseModel):
    """Payload to update an existing project."""

    name: Optional[str] = Field(None, min_length=1, max_length=100)
    description: Optional[str] = Field(None, max_length=2000)
    source_type: Optional[str] = Field(None)
    repo_url: Optional[str] = Field(None, max_length=512)
    default_branch: Optional[str] = Field(None, min_length=1, max_length=100)
    workspace_path: Optional[str] = Field(None, max_length=512)

    @field_validator("source_type")
    @classmethod
    def validate_source_type(cls, v: Optional[str]) -> Optional[str]:
        if v is None:
            return None
        clean = v.strip().lower()
        if clean not in ALLOWED_SOURCE_TYPES:
            raise ValueError(
                f"Invalid source_type '{v}'. Allowed types: {', '.join(sorted(ALLOWED_SOURCE_TYPES))}"
            )
        return clean

    @field_validator("repo_url")
    @classmethod
    def validate_repo_url(cls, v: Optional[str]) -> Optional[str]:
        if v is None:
            return None
        v_clean = v.strip()
        if not (v_clean.startswith("http://") or v_clean.startswith("https://") or v_clean.startswith("git@")):
            raise ValueError("repo_url must be a valid HTTP, HTTPS, or SSH git URL.")
        return v_clean


class ProjectRead(BaseModel):
    """Public project schema returned by API."""

    id: uuid.UUID
    user_id: uuid.UUID
    name: str
    description: Optional[str] = None
    source_type: str
    repo_url: Optional[str] = None
    default_branch: str
    workspace_path: Optional[str] = None
    created_at: datetime
    updated_at: datetime
    task_count: int = 0

    model_config = ConfigDict(from_attributes=True)


class ProjectListResponse(BaseModel):
    """Paginated list of projects."""

    items: List[ProjectRead]
    total: int
    skip: int
    limit: int
