# MuseFlow — Mobile AI Pair Programming & Coding IDE

[![Backend Tests](https://img.shields.io/badge/backend%20tests-97%2F97%20passing-brightgreen.svg)](backend/)
[![Flutter Tests](https://img.shields.io/badge/flutter%20tests-30%2F30%20passing-brightgreen.svg)](jess_app/)
[![FastAPI](https://img.shields.io/badge/FastAPI-0.115+-009688.svg?logo=fastapi&logoColor=white)](https://fastapi.tiangolo.com)
[![Flutter](https://img.shields.io/badge/Flutter-3.24+-02569B.svg?logo=flutter&logoColor=white)](https://flutter.dev)
[![Meta Model API](https://img.shields.io/badge/Meta%20Model%20API-Three--Model%20Architecture-0081FB.svg?logo=meta&logoColor=white)](https://ai.meta.com)

**MuseFlow** is an autonomous mobile pair-programming IDE designed for developers on the go. It connects a native Android smartphone to an agentic execution host on your development machine, empowering you to prompt, follow live progress, inspect proposed changes, and authorize Git diffs entirely from your phone.

Built for the **Meta Global AI Developer Hackathon**, MuseFlow integrates Meta's model family into a unified three-model developer experience.

---

## 🌟 The Three-Model Meta Architecture

All Meta API keys are held strictly server-side on the backend. Mobile devices never touch or store credentials.

```
                      ┌──────────────────────────────────────┐
                      │        MuseFlow Mobile App           │
                      │          (Flutter / Android)         │
                      └───────┬──────────────────────┬───────┘
                              │ Push-to-Talk Voice   │ UI Suggestion Prompt
                              ▼                      ▼
┌────────────────────────────────────────────────────────────────────────────┐
│                         FastAPI Backend Service                            │
│                                                                            │
│   ┌────────────────────────┐  ┌────────────────────────┐                   │
│   │  Muse Voice Transcribe │  │       Muse Image       │                   │
│   │ muse-voice-transcribe  │  │     muse-image-1.0     │                   │
│   │          1.0           │  │                        │                   │
│   │   [Voice-to-Text]      │  │  [UI Mockup Generator] │                   │
│   └───────────┬────────────┘  └───────────┬────────────┘                   │
│               │ Populates                 │ "Code This Design"             │
│               │ Prompt                    │                                │
│               └─────────────► ◄───────────┘                                │
│                               │                                            │
│               ┌───────────────▼────────────────────────┐                   │
│               │             Muse Spark 1.3             │                   │
│               │       Primary Autonomous Agent         │                   │
│               │       (Inspect · Reason · Code)        │                   │
│               └───────────────┬────────────────────────┘                   │
│                               │                                            │
│                               ▼                                            │
│               ┌────────────────────────────────────────┐                   │
│               │      Isolated Workspace Sandbox        │                   │
│               │  Filesystem · Automated Tests · Git    │                   │
│               └───────────────┬────────────────────────┘                   │
│                               │                                            │
│                               ▼                                            │
│               ┌────────────────────────────────────────┐                   │
│               │    Human-in-the-Loop Review Gate       │                   │
│               │  APPROVAL_REQUIRED -> Color-Coded Diff │                   │
│               └────────────────────────────────────────┘                   │
└────────────────────────────────────────────────────────────────────────────┘
```

1. **`muse-spark-1.3` — Primary Autonomous Coding Agent:**  
   The core intelligence driving workspace exploration, multi-turn reasoning, file modifications, and test suite verification. It autonomously diagnoses issues, writes solutions, runs checks, and halts at `APPROVAL_REQUIRED` with a clean Git diff.
2. **`muse-voice-transcribe-1.0` — Conversational Voice Input:**  
   Enables hands-free coding via push-to-talk audio streaming. Validates audio payloads (15 MB ceiling, whitelisted audio formats), handles English and Tamil speech, and fills the mobile composer for review before execution.
3. **`muse-image-1.0` — AI UI Suggestions & Mockups:**  
   Generates visual design proposals from natural language interface descriptions. Renders responsive design cards in the mobile chat with a one-tap **"Code This Design"** dispatch button.

---

## 🔒 Security & Reliability Hardening

In accordance with strict security standards, MuseFlow implements production-grade safeguards:

- **Token Privacy in Streaming:** WebSocket connection routines omit bearer authentication tokens from client diagnostic logs and debug prints.
- **Enforced JWT Signing Secret:** The backend checks secret key entropy at startup, immediately terminating execution in `production` or `staging` if a weak or default key is detected.
- **Android Network Security Config:** `network_security_config.xml` strictly blocks unencrypted cleartext HTTP over public networks, permitting cleartext exclusively on loopback (`127.0.0.1`, `localhost`, `10.0.2.2`). The client highlights insecure connections with prominent in-app warnings.
- **Sanitized Public Responses:** Uncaught provider errors return generic HTTP 502/504 responses to client callers without leaking backend stack traces or upstream provider details.
- **Audio Payload Validation:** The voice endpoint rejects files over 15 MB and validates MIME types and extensions (`.m4a`, `.wav`, `.mp3`, `.webm`, `.ogg`, `.aac`).
- **Non-Destructive Demo Seeding:** `python scripts/setup_server.py` checks for existing repositories and refuses to overwrite user files unless explicitly invoked with `--reset`.

---

## 📱 Mobile Client Experience (`jess_app/`)

- **Three-Tab Main Navigation:** Fluid dashboard for recent projects, active task monitoring, and host network configuration.
- **Contextual Project Views:** Overview, Live Agent Chat, Workspace File Explorer, and Git Changes Review.
- **Live WebSocket Event Stream:** Custom `ChatTimelineReconciler` delivers strictly ordered sequence events with zero duplicate bubbles across re-connections.
- **Human-in-the-Loop Diff Review:** Unified diff viewer with syntax highlighting, added/removed line counters, and explicit **"Approve & Commit"** / **"Reject Changes"** buttons.

---

## 🚀 Quickstart Guide

### 1. Backend Setup

```bash
# Clone the repository
git clone https://github.com/SajivJess/Jess-IDE.git
cd Jess-IDE/backend

# Create and activate virtual environment
python -m venv .venv
# Windows (PowerShell):
.\.venv\Scripts\Activate.ps1
# Linux / macOS:
source .venv/bin/activate

# Install dependencies
pip install -r requirements.txt

# Configure environment
cp .env.example .env
# Edit .env: Set MODEL_API_KEY (or leave blank for offline simulation)

# Run turnkey setup (database, demo workspace, and demo user)
python scripts/setup_server.py

# Launch FastAPI backend
uvicorn app.main:app --host 127.0.0.1 --port 8000 --reload
```

Backend health endpoints:
- **Liveness:** [http://127.0.0.1:8000/health](http://127.0.0.1:8000/health)
- **API Docs (when DEBUG=true):** [http://127.0.0.1:8000/docs](http://127.0.0.1:8000/docs)

### 2. Android App Setup

```bash
cd ../jess_app

# Run automated tests
flutter test

# Connect phone via USB and port-forward backend:
adb reverse tcp:8000 tcp:8000

# Run on physical device or emulator
flutter run
```

### 3. Build Standalone Release APK

```bash
flutter build apk --release
```
The compiled APK will be generated at `jess_app/build/app/outputs/flutter-apk/app-release.apk`.

---

## 🧪 Automated Test Verification

| Suite | Scope | Tests | Result |
| :--- | :--- | :--- | :--- |
| **Backend Pytest** | Auth, JWT, Projects, Workspaces, Task Loops, Git Diff, Meta Voice, Meta Image, Config Security | 97 | **97 / 97 Passed (100%)** |
| **Flutter Tests** | Audio Recording, Chat Reconciler, WebSocket Events, UI Components, Navigation Shell | 30 | **30 / 30 Passed (100%)** |

Run tests independently:
```bash
# Run backend test suite
cd backend && pytest tests/ -v

# Run Flutter test suite
cd jess_app && flutter test
```

---

## 📖 Live vs. Simulated Delineation

To ensure transparent and honest evaluation, MuseFlow clearly labels model states:

- **Live Mode:** When `MODEL_API_KEY` is supplied, real requests are submitted to `muse-spark-1.3`, `muse-voice-transcribe-1.0`, and `muse-image-1.0`.
- **Simulation Mode:** When `MODEL_API_KEY` is omitted, the backend generates deterministic, labelled outputs (`[Simulated Voice Note]`, `[Simulated Mockup]`), ensuring offline testability and flawless local development without unexpected provider failures.

---

## 📂 Repository Structure

- `backend/` — Asynchronous FastAPI backend, SQLAlchemy models, task engine, and Meta service clients.
- `jess_app/` — Native Flutter Android mobile client with custom dark IDE design tokens.
- `docs/` — Product vision, architecture diagrams, and detailed security specifications.
- `SERVER_README.md` — Deployment guide for hosting the backend on Windows, Linux, or macOS.

---

## License

Licensed under the [Apache 2.0 License](LICENSE).
