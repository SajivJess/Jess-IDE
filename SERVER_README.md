# MuseFlow — Server Host Setup & Deployment Guide

This guide explains how to set up and run the **MuseFlow** FastAPI backend service on a server or development laptop (Windows, macOS, or Linux), initialize the demonstration workspace, and connect from the Android client.

---

> [!WARNING]
> ### Security Notice: Demo Configuration vs. Public Exposure
> - The credentials `dev@jess.dev` / `password123` are **local demo credentials only**. Never expose a shared demo account over a public tunnel.
> - When exposing the server to the internet or public tunnels, configure a strong, random `SECRET_KEY` (minimum 32 characters), disable `DEBUG`, enforce HTTPS, and register individual accounts via `/api/v1/auth/register`.
> - The server should bind to loopback `127.0.0.1` by default. Do not bind `0.0.0.0` on untrusted networks without firewall protections.

---

## 1. Prerequisites on Server Machine

- **Operating System:** Windows 10/11, macOS, or Ubuntu 22.04+
- **Python:** Python 3.10+ (Verified on Python 3.10)
- **Git:** Installed and available in PATH (`git --version`)
- **ADB (Optional, for USB tethering):** Android Debug Bridge from Android SDK platform-tools

---

## 2. Quickstart Installation

### Step 1: Open Terminal in `backend/`
```powershell
cd backend
```

### Step 2: Create & Activate Virtual Environment
```powershell
# Windows (PowerShell):
python -m venv .venv
.\.venv\Scripts\Activate.ps1

# Linux / macOS:
python3 -m venv .venv
source .venv/bin/activate
```

### Step 3: Install Dependencies
```bash
pip install -r requirements.txt
```

### Step 4: Configure Environment
Copy `.env.example` to `.env`:
```powershell
Copy-Item .env.example .env
```
Open `backend/.env` and review key settings:
1. `MODEL_API_KEY`: Enter your Meta Model API key (or leave empty to run in deterministic offline simulation mode).
2. `AGENT_PROVIDER`: Set to `"meta"` for autonomous live model execution, or `"simulated"` for offline testing.
3. `SECRET_KEY`: For production or public exposure, generate a strong 32+ character key:
   ```bash
   python -c "import secrets; print(secrets.token_hex(32))"
   ```

### Step 5: Run Turnkey Server Setup
Run the setup script to initialize the database schema, seed demo access, and prepare the demo workspace:
```powershell
python scripts/setup_server.py
```
> [!NOTE]
> The setup script is **non-destructive**. It will preserve any existing workspace files. If you explicitly want to re-seed the intentional calculator bug for demo resets, pass the `--reset` flag:
> ```powershell
> python scripts/setup_server.py --reset
> ```

---

## 3. Starting the Backend Server

For local USB debugging (most secure):
```powershell
uvicorn app.main:app --host 127.0.0.1 --port 8000 --reload
```

For trusted local Wi-Fi LAN testing:
```powershell
uvicorn app.main:app --host 0.0.0.0 --port 8000
```

### Verify Service Health
Open your browser to:
- [http://127.0.0.1:8000/health](http://127.0.0.1:8000/health) -> `{"status": "ok", "app": "MuseFlow Backend"}`
- [http://127.0.0.1:8000/docs](http://127.0.0.1:8000/docs) -> Interactive OpenAPI / Swagger UI (available when `DEBUG=true`)

---

## 4. Connecting the Android Client

### Option A: USB ADB Reverse (Recommended — Fastest & Most Secure)
Connect your Android phone via USB with USB Debugging enabled:
1. Reverse port 8000 so the device talks directly to your computer's loopback:
   ```powershell
   adb reverse tcp:8000 tcp:8000
   ```
2. Open **MuseFlow** on your phone.
3. In **Settings**, tap the **USB ADB (127.0.0.1:8000)** preset chip.
4. Tap **Ping / Test Probe** to verify `HTTP 200 OK`.
5. Sign in or register a new account.

### Option B: Android Emulator
If running an Android Virtual Device (AVD):
1. In **Settings**, select the **Android Emulator (10.0.2.2:8000)** preset chip.
2. Tap **Ping / Test Probe**.

### Option C: Remote HTTPS Tunnel
If testing across separate networks:
1. Start an authenticated HTTPS tunnel (e.g., Cloudflare Named Tunnel or ngrok):
   ```bash
   ngrok http 8000
   ```
2. In the app's **Settings**, paste your secure HTTPS URL:
   `https://<your-subdomain>.ngrok-free.app/api/v1`
3. Tap **Ping / Test Probe** to verify end-to-end connectivity.
   *(The app automatically upgrades WebSocket connections to `wss://` and protects token transmission via TLS).*

---

## 5. Automated Verification Suites

Verify all backend components before demo recording:
```powershell
pytest tests/ -v
```
All 97 test cases cover authentication, project workspaces, tasks, recovery, git reviews, Meta Model API integration, voice transcription endpoints, and UI suggestion mockups.
