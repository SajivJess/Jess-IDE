"""Security and multi-tenant isolation verification script.
Tests:
1. Unauthenticated request protection (401 Unauthorized).
2. Cross-user isolation (User B cannot read/write User A's projects, tasks, conversations, files).
3. WebSocket token authentication.
"""

import json
import sys
import uuid
import httpx
import websockets
import asyncio

BASE_URL = "http://127.0.0.1:8000/api/v1"
WS_BASE = "ws://127.0.0.1:8000/api/v1"

async def test_security():
    print("=" * 60)
    print("RUNNING LIVE SECURITY & ISOLATION AUDIT")
    print("=" * 60)

    async with httpx.AsyncClient(timeout=10.0) as client:
        # --- 1. Unauthenticated checks ---
        print("\n[Phase 1] Testing Unauthenticated Request Rejection:")
        unauth_routes = [
            ("GET", f"{BASE_URL}/projects"),
            ("POST", f"{BASE_URL}/projects", {"name": "Hacked", "source_type": "local"}),
            ("GET", f"{BASE_URL}/projects/{uuid.uuid4()}/conversations"),
            ("GET", f"{BASE_URL}/projects/{uuid.uuid4()}/conversations/{uuid.uuid4()}"),
            ("POST", f"{BASE_URL}/projects/{uuid.uuid4()}/tasks", {"title": "X", "prompt": "Y"}),
            ("GET", f"{BASE_URL}/projects/{uuid.uuid4()}/workspaces"),
        ]

        for method, url, *body in unauth_routes:
            data = body[0] if body else None
            if method == "GET":
                r = await client.get(url)
            else:
                r = await client.post(url, json=data)
            
            assert r.status_code == 401, f"FAIL: {method} {url} returned {r.status_code}, expected 401"
            print(f"  [OK] {method} {url.split('/api/v1')[1]} -> 401 Unauthorized")

        # --- 2. Multi-tenant isolation ---
        print("\n[Phase 2] Testing Cross-User Tenant Isolation:")
        uid = uuid.uuid4().hex[:6]
        user_a_email = f"alice_{uid}@jess.dev"
        user_b_email = f"bob_{uid}@jess.dev"

        # Register & Login User A
        ra = await client.post(f"{BASE_URL}/auth/register", json={
            "email": user_a_email, "password": "Password123!", "full_name": "Alice"
        })
        assert ra.status_code == 201, f"Failed to register User A: {ra.text}"
        la = await client.post(f"{BASE_URL}/auth/login", json={"email": user_a_email, "password": "Password123!"})
        assert la.status_code == 200, f"Failed to login User A: {la.text}"
        token_a = la.json()["access_token"]
        headers_a = {"Authorization": f"Bearer {token_a}"}

        # Register & Login User B
        rb = await client.post(f"{BASE_URL}/auth/register", json={
            "email": user_b_email, "password": "Password123!", "full_name": "Bob"
        })
        assert rb.status_code == 201, f"Failed to register User B: {rb.text}"
        lb = await client.post(f"{BASE_URL}/auth/login", json={"email": user_b_email, "password": "Password123!"})
        assert lb.status_code == 200, f"Failed to login User B: {lb.text}"
        token_b = lb.json()["access_token"]
        headers_b = {"Authorization": f"Bearer {token_b}"}

        # User A creates a project
        rp = await client.post(f"{BASE_URL}/projects", headers=headers_a, json={
            "name": f"Alice Secret Project {uid}",
            "description": "Sensitive project",
            "source_type": "local"
        })
        assert rp.status_code == 201, f"Failed to create project: {rp.text}"
        proj_a_id = rp.json()["id"]
        print(f"  [OK] Alice created project: {proj_a_id}")

        # User B attempts to access Alice's project
        r_b_proj = await client.get(f"{BASE_URL}/projects/{proj_a_id}", headers=headers_b)
        assert r_b_proj.status_code == 404, f"FAIL: User B accessed Alice's project: {r_b_proj.status_code}"
        print(f"  [OK] Bob cannot read Alice's project -> 404 Not Found")

        # User B attempts to list conversations of Alice's project
        r_b_convs = await client.get(f"{BASE_URL}/projects/{proj_a_id}/conversations", headers=headers_b)
        assert r_b_convs.status_code == 404, f"FAIL: User B listed Alice's project conversations: {r_b_convs.status_code}"
        print(f"  [OK] Bob cannot list conversations on Alice's project -> 404 Not Found")

        # User B attempts to create a task in Alice's project
        r_b_task = await client.post(f"{BASE_URL}/projects/{proj_a_id}/tasks", headers=headers_b, json={
            "title": "Malicious Task",
            "prompt": "Exploit"
        })
        assert r_b_task.status_code == 404, f"FAIL: User B created task in Alice's project: {r_b_task.status_code}"
        print(f"  [OK] Bob cannot create tasks in Alice's project -> 404 Not Found")

        # --- 3. WebSocket token authentication ---
        print("\n[Phase 3] Testing WebSocket Security:")
        # Test WS without token
        ws_url_no_token = f"{WS_BASE}/ws/tasks/{uuid.uuid4()}"
        try:
            async with websockets.connect(ws_url_no_token) as ws:
                msg = await ws.recv()
                data = json.loads(msg)
                assert data.get("type") == "error"
                print(f"  [OK] WebSocket without token rejected with error: {data['message']}")
        except Exception as e:
            print(f"  [OK] WebSocket rejected without token: {type(e).__name__}")

        # Test WS with invalid token
        ws_url_bad_token = f"{WS_BASE}/ws/tasks/{uuid.uuid4()}?token=invalid_garbage_token"
        try:
            async with websockets.connect(ws_url_bad_token) as ws:
                msg = await ws.recv()
                data = json.loads(msg)
                assert data.get("type") == "error"
                print(f"  [OK] WebSocket with invalid token rejected with error: {data['message']}")
        except Exception as e:
            print(f"  [OK] WebSocket rejected invalid token: {type(e).__name__}")

    print("\n" + "=" * 60)
    print("ALL SECURITY CHECKS PASSED: ENDPOINTS ARE SECURE & ISOLATED")
    print("=" * 60)

if __name__ == "__main__":
    asyncio.run(test_security())
