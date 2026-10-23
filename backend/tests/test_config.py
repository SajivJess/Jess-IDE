from app.core.config import Settings


def test_default_settings() -> None:
    """Verify that default settings load with expected attributes."""
    test_settings = Settings()
    assert test_settings.PROJECT_NAME == "Jess Ide Dev Backend"
    assert test_settings.VERSION == "0.1.0"
    assert test_settings.API_V1_STR == "/api/v1"
    assert test_settings.PORT == 8000
    assert len(test_settings.CORS_ORIGINS) > 0


def test_cors_origins_parsing() -> None:
    """Verify that comma-separated and JSON list CORS origins parse accurately."""
    # Test comma-separated string
    parsed_comma = Settings.assemble_cors_origins("http://localhost:3000, http://example.com")
    assert parsed_comma == ["http://localhost:3000", "http://example.com"]

    # Test JSON formatted string
    parsed_json = Settings.assemble_cors_origins('["http://localhost:3000", "http://example.com"]')
    assert parsed_json == ["http://localhost:3000", "http://example.com"]

    # Test native list
    parsed_list = Settings.assemble_cors_origins(["http://localhost:3000"])
    assert parsed_list == ["http://localhost:3000"]
