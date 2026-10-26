# Phone access to the laptop

The `remote/` portal is an optional, single-owner development interface for this laptop. It uses an HTTPS Cloudflare Quick Tunnel to relay traffic to a loopback-only portal on port 3001. The API remains on loopback port 3000; PostgreSQL remains on loopback port 5432. Application processing and database storage stay on E:. Cloudflare carries the web traffic; this is not a deployed cloud VM.

The mobile interface opens into a project-launching Home without a bottom navigation bar, with profile personalization, recent work, owned search and project metadata. Opening a project restores Chat. The existing project/task history, simulator, cancellation and review editor are preserved. The default public task agent is `fake-v1`: it does not edit files or execute a real coding agent. Real-agent task submissions and public chat dispatch remain blocked. History comes from PostgreSQL and is restored after signing in, including at a new tunnel hostname with the same configured owner. Files supports review snapshots and conflict-safe edits, independent of the live checkout. See [the Home contract](home-launcher.md), [mobile-web contract](mobile-web.md) and [workspace boundaries](workspace-architecture.md).

The Project chat subpage now displays recorded native CLI conversations and offers project-context/transcript downloads. Public chat send is denied independently of simulated task submission. See [the local relay instructions](chat-relay.md).

## This laptop's layout

- Repository: `E:\Jess-IDE`
- Node 24: `E:\tools\node-v24.22.0-win-x64\node.exe`
- Official Cloudflare tunnel binary: `E:\tools\cloudflared.exe`
- Local configuration/password/owner UUID: `.local/remote-config.json`
- Development backend token: `.env` (never sent to the browser)
- PID files and logs: `.local/`
- Temporary files: `E:\local-data\tmp`

Both configuration files are Git-ignored. Do not commit credentials, session cookies, database data, or machine logs.

## Start and stop

First start the database, API and worker using `.local/start.ps1`. Then:

```powershell
powershell -ExecutionPolicy Bypass -File E:\Jess-IDE\remote\start.ps1
```

The script prints the public URL. Read the password from the local configuration file and enter it on the phone. The URL is temporary and changes when the tunnel is recreated. Keep the laptop powered on, awake, and connected to the internet. These processes are not installed as Windows startup services.

To revoke the link immediately:

```powershell
powershell -ExecutionPolicy Bypass -File E:\Jess-IDE\remote\stop.ps1
```

To change the password, stop public access, update `password` in `.local/remote-config.json` to at least 20 random characters, then start again. Preserve the `owner` UUID to retain access to that owner's tasks. Sessions expire after eight hours and are cleared on portal restart.

## Authentication boundary

The portal uses a separate random password, bounded login attempts, in-memory sessions, Secure/HttpOnly/SameSite cookies, exact Host/Origin checks, no-store responses, and a restrictive Content Security Policy. Its small API allowlist always supplies the same server-configured owner UUID and token; incoming development-auth headers are ignored. No arbitrary proxy destinations, filesystem access, shell commands, or SSE routes are exposed.

This is a single-owner prototype, not a multi-user production identity system. New real-execution capabilities need their own authorization and isolation review before adding them to the public portal.

Run the gateway boundary tests with the local Node executable:

```powershell
E:\tools\node-v24.22.0-win-x64\node.exe --test remote/security.test.mjs
```

Official tunnel documentation: https://developers.cloudflare.com/tunnel/get-started/quick-tunnels/
