# Jess IDE — Server Laptop Setup & Deployment Guide

This guide explains how to set up and run the Jess IDE FastAPI backend service on a fresh Windows laptop (or macOS/Linux), seed the demonstration project, and connect remotely from an Android device.

---

## 1. Prerequisites on Server Laptop

- **Operating System:** Windows 10/11 (or macOS / Ubuntu 22.04+)
- **Python:** Python 3.10+ (Verified on Python 3.10)
- **Git:** Installed and available in PATH (`git --version`)
- **Network:** Connected to local Wi-Fi or internet (if using a remote HTTPS tunnel)

---

## 2. Quickstart Installation (PowerShell)

### Step 1: Extract Archive
Extract the `jess-ide-server-package.zip` into a clean directory, for example:
`C:\Users\<YourUsername>\jess-ide`

### Step 2: Open PowerShell in `backend/`
```powershell
cd C:\Users\<YourUsername>\jess-ide\backend
```

### Step 3: Create & Activate Virtual Environment
```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
```
*(If PowerShell displays an Execution Policy warning, run `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass` and reactivate).*

### Step 4: Install Dependencies
```powershell
pip install -r requirements.txt
```

### Step 5: Configure Environment
Copy the `.env.example` template to `.env`:
```powershell
Copy-Item .env.example .env
```
Open `backend\.env` in Notepad or VS Code and configure:
1. `MODEL_API_KEY`: Enter your Meta Model API key (or leave empty if using simulated provider).
2. `AGENT_PROVIDER`: Set to `"meta"` for live autonomous AI execution, or `"simulated"` for offline deterministic testing without an API key.
3. `DATABASE_URL`: Defaults to `sqlite+aiosqlite:///./jess_dev.db` (zero setup required).

### Step 6: Run Turnkey Server Setup
Run the included setup script to automatically create database tables, seed the demo user (`dev@jess.dev` / `password123`), and initialize the local `Calculator Demo Repo`:
```powershell
python scripts/setup_server.py
```
Expected output:
```
[1/4] Ensuring database schema exists...
      Schema verified.
[2/4] Ensuring demo user exists (dev@jess.dev)...
      Created demo user: dev@jess.dev
[3/4] Initializing demo workspace (verification_test_repo)...
      Initialized Git repo at .../verification_test_repo
[4/4] Linking 'Calculator Demo Repo' to user...
      Created project 'Calculator Demo Repo'.
Setup completed successfully!
```

---

## 3. Starting the Backend Server

Launch the FastAPI uvicorn server bound to all network interfaces (`0.0.0.0`):

```powershell
uvicorn app.main:app --host 0.0.0.0 --port 8000
```

### Verify Local Health
Open your web browser and navigate to:
- [http://127.0.0.1:8000/health](http://127.0.0.1:8000/health) -> `{"status": "ok", "app": "Jess Ide Dev Backend"}`
- [http://127.0.0.1:8000/docs](http://127.0.0.1:8000/docs) -> Interactive Swagger OpenAPI Documentation

---

## 4. Connecting the Android Client

### Option A: Local Wi-Fi LAN Connection (Easiest)
If the phone and server laptop are on the same Wi-Fi network:
1. Find your server laptop's IP address:
   ```powershell
   ipconfig
   ```
   Look for `IPv4 Address` (e.g. `192.168.1.150`).
2. Open **Jess IDE** on the phone.
3. Tap **Settings** (gear icon in the bottom navigation).
4. In **API Base URL**, enter: `http://192.168.1.150:8000/api/v1`
5. Tap **Test Connection** -> Verify `HTTP 200 OK`.
6. Sign in with:
   - **Email:** `dev@jess.dev`
   - **Password:** `password123`

### Option B: Remote HTTPS Tunnel (ngrok / Cloudflare Tunnel / Bore)
If testing remotely over mobile cellular data or a different Wi-Fi network:
1. Start a secure tunnel forwarding port 8000 on the server laptop:
   ```powershell
   # Example with ngrok:
   ngrok http 8000
   # Or cloudflared:
   cloudflared tunnel --url http://127.0.0.1:8000
   ```
2. Copy the generated public HTTPS URL (e.g. `https://xyz-123.ngrok-free.app`).
3. In the mobile app's **Settings** screen, enter:
   `https://xyz-123.ngrok-free.app/api/v1`
4. Tap **Test Connection** -> Verify `HTTP 200 OK`.
   *(The app automatically upgrades WebSocket connections to `wss://`)*.

---

## 5. Shutting Down
To safely stop the backend server:
- Press `Ctrl + C` in the PowerShell window.
- The server will cleanly terminate active tasks and database connections.
