# MuseFlow — FastAPI Backend Service

Production-grade asynchronous FastAPI backend service powering **MuseFlow** (Mobile AI Pair Programming & Coding IDE).

The backend manages developer workspaces, hosts the autonomous **Three-Model Meta Architecture**, streams real-time task events over WebSockets, enforces human-in-the-loop diff approvals, and safeguards API credentials entirely server-side.

---

## Architectural Highlights

```
backend/
├── app/
│   ├── api/
│   │   ├── deps.py                  # JWT authentication & DB session dependency injection
│   │   └── v1/
│   │       ├── api.py               # Master API v1 router mounting all sub-endpoints
│   │       └── endpoints/
│   │           ├── auth.py          # User registration, JWT tokens, refresh, & password reset
│   │           ├── projects.py      # Project lifecycle, git repo links, & workspace auto-provisioning
│   │           ├── workspaces.py    # Sandboxed execution, file read/write, & git status/diff
│   │           ├── tasks.py         # Autonomous coding task lifecycle, cancellation, & approvals
│   │           ├── task_stream.py   # WebSocket event streaming with ordered sequence delivery
│   │           ├── conversations.py # Project chat history & conversation relays
│   │           ├── voice.py         # 15MB-limited audio uploads & Muse Voice Transcribe
│   │           ├── ui_suggestions.py# Muse Image 1.0 mockup generation & preview caching
│   │           ├── live_preview.py  # Local dev server preview hosting & tunnel status
│   │           └── health.py        # Service liveness & database readiness checks
│   ├── core/
│   │   ├── config.py                # Pydantic Settings with production secret key validation
│   │   ├── security.py              # Password hashing (Argon2/bcrypt) & JWT issuance
│   │   └── logging.py               # Structured console & diagnostic logging
│   ├── db/
│   │   ├── base.py                  # Declarative SQLAlchemy base
│   │   ├── session.py               # AsyncSession engine (SQLite & PostgreSQL support)
│   │   └── models/                  # User, Project, Workspace, Task, TaskEvent, Conversation
│   ├── schemas/                     # Pydantic validation schemas for all requests/responses
│   ├── services/
│   │   ├── meta_agent_service.py    # Muse Spark 1.3 coding loop (inspect, code, test, review)
│   │   ├── meta_voice_service.py    # Muse Voice Transcribe 1.0 client with simulation fallback
│   │   ├── meta_image_service.py    # Muse Image 1.0 mockup client with simulation fallback
│   │   ├── workspace_provider.py    # Local filesystem & Git isolation sandbox
│   │   └── task_engine.py           # Background task execution & cancellation coordination
│   └── main.py                      # FastAPI app entrypoint, CORS, lifespan, & error sanitization
├── scripts/
│   └── setup_server.py              # Turnkey database setup & non-destructive demo seeder
├── tests/                           # 97 automated pytest tests (100% passing)
├── .env.example                     # Production-ready environment template
└── requirements.txt                 # Pinned Python dependencies
```

---

## Three-Model Meta Architecture

All Meta API keys remain strictly server-side in `MODEL_API_KEY`:

| Model ID | Role | Key Behaviors |
| :--- | :--- | :--- |
| **`muse-spark-1.3`** | **Primary Coding Agent** | Autonomous multi-turn reasoning loop. Inspects workspace files, modifies code, runs automated test suites, halts at `APPROVAL_REQUIRED`, and generates unified Git diffs. |
| **`muse-voice-transcribe-1.0`** | **Voice Transcribe** | Converts push-to-talk audio recordings into coding instructions. Validates audio formats (`.m4a`, `.wav`, `.mp3`, `.webm`, `.ogg`, `.aac`), enforces a 15 MB payload ceiling, and handles Tamil/English speech. |
| **`muse-image-1.0`** | **UI Design Mockups** | Generates visual interface mockup cards from natural language prompts. Enables one-tap mobile dispatch into the primary Muse Spark coding loop. |

*Offline Mode:* If `MODEL_API_KEY` is not provided, the backend seamlessly falls back to labelled simulated responses (`[Simulated Voice Note]`, `[Simulated Mockup]`), ensuring repeatable local testing and development.

---

## Security Readiness

- **JWT Secret Key Validation:** Startup refuses execution in `production` or `staging` if `SECRET_KEY` is too short (< 32 characters) or retains the default development string.
- **Sanitized Public Errors:** Unhandled exceptions in voice transcription or UI suggestions return generic 502/504 errors to client callers; detailed tracebacks and provider payloads are retained exclusively in protected server logs.
- **Audio Payload Protection:** Uploads exceeding 15 MB or unsupported file extensions are immediately rejected before reading into model memory.
- **Non-Destructive Demo Seeding:** `python scripts/setup_server.py` checks file existence and preserves existing repositories. Demo re-seeding requires an explicit `--reset` flag.

---

## Setup & Running

### 1. Prerequisites
- Python 3.10+
- Git

### 2. Setup Virtual Environment
```bash
python -m venv .venv

# Windows (PowerShell):
.\.venv\Scripts\Activate.ps1

# Linux / macOS:
source .venv/bin/activate
```

### 3. Install Dependencies
```bash
pip install -r requirements.txt
```

### 4. Initialize Database & Demo Workspace
```bash
python scripts/setup_server.py
```
*(Add `--reset` if you need to wipe and re-seed the intentional calculator demo bug).*

### 5. Launch Backend Service
```bash
uvicorn app.main:app --host 127.0.0.1 --port 8000 --reload
```

---

## Automated Verification

Run the complete 97-test backend suite:
```bash
pytest tests/ -v
```
Tests cover:
- Authentication, JWT lifecycle, verification, and Argon2/bcrypt security
- Project and workspace provisioning, isolation, file I/O, and Git status/diff
- Task engine state transitions, background worker loops, and cancellation
- WebSocket sequence delivery and reconnection reconciliation
- Meta Model API request formatting, error sanitization, and fallback simulations
