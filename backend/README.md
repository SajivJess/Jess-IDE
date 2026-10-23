# Jess Ide Dev — Backend (Phase 1)

FastAPI-powered backend service for the **Jess Ide Dev** platform.

Phase 1 provides the modular application skeleton, environment configuration, structured logging, error handling, health checks, and automated test suite.

---

## Architecture Overview

```
backend/
├── app/
│   ├── api/
│   │   └── v1/
│   │       ├── endpoints/
│   │       │   └── health.py        # GET /api/v1/health
│   │       └── api.py               # v1 master router
│   ├── core/
│   │   ├── config.py                # Pydantic Settings & environment config
│   │   └── logging.py               # Structured console logger
│   └── main.py                      # FastAPI entrypoint, lifespan, CORS, error handling
├── tests/
│   ├── conftest.py                  # Pytest fixtures & TestClient
│   ├── test_config.py               # Configuration unit tests
│   └── test_health.py               # Health endpoint integration tests
├── .env.example                     # Environment template (placeholders only)
├── .gitignore                       # Python & environment ignores
├── pyproject.toml                   # Project metadata & dependency definitions
└── requirements.txt                 # Pinned dependencies
```

---

## Local Setup

### 1. Prerequisites
- **Python 3.10+** (Tested on Python 3.10)
- **pip** (Python package manager)

### 2. Create Virtual Environment
Run from the `backend/` directory:

```bash
cd backend
python -m venv .venv
```

Activate the virtual environment:
- **Windows (PowerShell):**
  ```powershell
  .venv\Scripts\Activate.ps1
  ```
- **Windows (CMD):**
  ```cmd
  .venv\Scripts\activate.bat
  ```
- **Linux / macOS:**
  ```bash
  source .venv/bin/activate
  ```

### 3. Install Dependencies

Install all core and development dependencies:

```bash
pip install -r requirements.txt
```

Alternatively using `pyproject.toml` in editable mode:
```bash
pip install -e ".[dev]"
```

### 4. Configure Environment Variables

Copy `.env.example` to `.env`:

```bash
copy .env.example .env     # Windows
cp .env.example .env       # Linux/macOS
```

---

## Running the Server

Start the FastAPI development server with hot-reload:

```bash
uvicorn app.main:app --host 127.0.0.1 --port 8000 --reload
```

Once running, verify endpoints:
- **Root Health:** [http://127.0.0.1:8000/health](http://127.0.0.1:8000/health)
- **API v1 Health:** [http://127.0.0.1:8000/api/v1/health](http://127.0.0.1:8000/api/v1/health)
- **Interactive Swagger Docs:** [http://127.0.0.1:8000/docs](http://127.0.0.1:8000/docs)
- **ReDoc:** [http://127.0.0.1:8000/redoc](http://127.0.0.1:8000/redoc)

Sample response from `GET /health`:
```json
{
  "status": "ok",
  "app": "Jess Ide Dev Backend",
  "version": "0.1.0",
  "environment": "development",
  "timestamp": 1792750000.123
}
```

---

## Running Automated Tests

Run the test suite using `pytest`:

```bash
pytest -v
```

Expected output:
```text
tests/test_config.py::test_default_settings PASSED
tests/test_config.py::test_cors_origins_parsing PASSED
tests/test_health.py::test_root_health PASSED
tests/test_health.py::test_api_v1_health PASSED
tests/test_health.py::test_not_found_returns_404 PASSED
============================== 5 passed in 0.25s ==============================
```

---

## Next Steps (Phase 2 Roadmap)
- [ ] Connect **PostgreSQL** via async SQLAlchemy 2.0 and `asyncpg`.
- [ ] Configure **Alembic** migrations.
- [ ] Define relational data models: `User`, `Project`, `Workspace`, `Task`.
- [ ] Transition mock frontend data to persisted backend records.
