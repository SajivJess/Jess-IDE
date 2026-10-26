# Jess IDE — Meta Global AI Developer Hackathon 2026
## Prototype & Proof of Concept (PoC) Demo Guide

---

### 1. Architectural Overview

```
┌───────────────────────────────────────────────┐
│              Your Phone (Flutter App)          │
│   • Submits coding task                       │
│   • Streams live model reasoning & tool logs   │
│   • Inspects test results & git diff           │
│   • Human-in-the-loop explicit approval       │
└───────────────────────┬───────────────────────┘
                        │ HTTP & WebSocket (Port 8000)
                        ▼
┌───────────────────────────────────────────────┐
│            Your Laptop (Jess IDE Backend)     │
│   • FastAPI backend (app.main:app)            │
│   • MetaAgentAdapter                          │
│   • State machine (QUEUED → RUNNING →         │
│     APPROVAL_REQUIRED → COMPLETED)            │
│   • Broadcaster (live SSE & WebSocket events)  │
└───────────────┬───────────────────────────────┘
                │
        ┌───────┴───────────────────────────────┐
        ▼                                       ▼
┌───────────────────────────────┐   ┌───────────────────────────────┐
│     Meta Model API (dev.meta) │   │  Isolated Workspace Sandbox   │
│   • Remote inference service  │   │  • Strict boundary isolation  │
│   • Uses $150 free credits    │   │  • Runs inside workspaces_data│
│   • Model: muse-spark-1.3     │   │  • Approved tools only        │
│   • Autonomous repair loop    │   │  • Real tests & git diffs     │
└───────────────────────────────┘   └───────────────────────────────┘
```

---

### 2. Quick Setup & Startup on Laptop

#### Step 1: Ensure credentials in `backend/.env`
```bash
MODEL_API_KEY="LLM_2578595229279251_8bnK0Oa6aobTHC4MY9kxQZ6CSbo"
AGENT_PROVIDER="meta"
META_MODEL_ID="muse-spark-1.3"
META_MODEL_BASE_URL="https://api.meta.ai/v1"
```

#### Step 2: Start the backend server
From the `backend` folder on your laptop:
```powershell
.venv\Scripts\python.exe -m uvicorn app.main:app --host 0.0.0.0 --port 8000
```
*(Binding to `0.0.0.0` allows your phone to connect over your local Wi-Fi network).*

#### Step 3: Find your laptop's local Wi-Fi IP
```powershell
ipconfig
```
Look for **IPv4 Address** (e.g. `192.168.1.105` or `172.30.17.207`).

#### Step 4: Connect your Flutter phone app
In the Jess IDE Flutter mobile app:
- Go to **Settings** → **Backend API URL**.
- Set to: `http://<YOUR_LAPTOP_IP>:8000/api/v1` (e.g. `http://192.168.1.105:8000/api/v1`).
- Or if connected via USB with Android:
  ```powershell
  adb reverse tcp:8000 tcp:8000
  ```
  and use `http://127.0.0.1:8000/api/v1`.

---

### 3. The 3-Minute Video Demo Script

Follow this sequence for the hackathon video submission:

#### Scene 1: The Vision & Architecture (0:00 – 0:35)
- **Visual**: Show the phone running the Jess IDE Flutter app alongside the laptop screen showing the backend server logs.
- **Narrative**:
  > *"Jess IDE is an autonomous coding agent environment designed for mobile software engineering. Instead of being tied to a desktop, developers submit real tasks from their phone, while a Meta-powered agent plans, modifies, and validates code in an isolated sandbox on their machine."*

#### Scene 2: Submitting the Coding Task (0:35 – 1:00)
- **Visual**: On the phone, select your project and create a new task.
- **Sample Prompt**:
  > *"Add exponential backoff retry logic to ApiClient and ensure all verification tests pass."*
- **Action**: Tap **Submit Task**. The status instantly transitions to `QUEUED` → `RUNNING`.

#### Scene 3: Meta Model Planning & Tool Execution (1:00 – 1:40)
- **Visual**: Watch the real-time timeline stream onto the phone screen.
- **Key Evidence to Highlight**:
  1. **Meta Assistant Thoughts**: The Meta model (`muse-spark-1.3`) streams its step-by-step reasoning.
  2. **Tool Execution**: `list_files` and `read_file` events appear as the agent reads the code.
  3. **File Editing**: `write_file` modifies the file in the isolated workspace.

#### Scene 4: Real Failure & Autonomous Repair Loop (1:40 – 2:20)
- **Visual**: Show `run_check` running the test runner in the workspace.
- **Failure Detected**: The initial test fails (exit code 1).
- **Autonomous Repair**:
  - The model diagnoses the failure output in the workspace.
  - Progress updates: *"Test failed (exit code 1). Autonomous repair attempt 1/3 underway..."*
  - The agent edits the file to fix the bug and reruns `run_check`.
  - The check passes with exit code 0!

#### Scene 5: Diff Review & Human-in-the-Loop Approval (2:20 – 3:00)
- **Visual**:
  - The task transitions to **`APPROVAL REQUIRED`**.
  - The genuine Git diff appears on the phone screen with syntax-colored additions and deletions.
  - Tap **Approve Changes**.
  - The changes are committed to the branch, and the task marks **`COMPLETED`**.
- **Closing**:
  > *"No simulated output, no fake passes. A real Meta model, real process sandbox, real failure recovery, and total human control from your phone."*

---

### 4. Safety & Isolation Verification

1. **Workspace Boundary**: The agent operates inside `workspaces_data/<workspace-id>/`. Path traversal (`../`), drive escapes, and `.env` / `.git` modifications are rejected by `resolve_secure_path`.
2. **Secret Containment**: `MODEL_API_KEY` stays on your laptop; it is never forwarded to the phone, client logs, or inside the workspace.
3. **No Unapproved Commits**: The agent cannot commit or push without you tapping **Approve** on your phone.
4. **Fallback Safety**: If you want to rehearse without using API credits, simply set `AGENT_PROVIDER="simulated"` in `backend/.env`.

---

### 5. Automated Tests

Run backend unit tests anytime:
```powershell
.venv\Scripts\python.exe -m unittest tests/test_meta_agent.py
```
Expected output:
```text
Ran 5 tests in 0.075s
OK
```
