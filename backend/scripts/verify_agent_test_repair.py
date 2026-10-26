import os
import sys
import json
import shutil
import subprocess
import httpx
from pathlib import Path
from dotenv import load_dotenv

load_dotenv()

api_key = os.getenv("MODEL_API_KEY", "")
base_url = os.getenv("META_MODEL_BASE_URL", "https://api.meta.ai/v1").rstrip("/")
model_id = os.getenv("META_MODEL_ID", "muse-spark-1.3")

# 1. Setup disposable workspace
import stat

def on_rm_error(func, path, exc_info):
    try:
        os.chmod(path, stat.S_IWRITE)
        func(path)
    except Exception:
        pass

ws_dir = Path("workspaces_data/verification_test_repo").resolve()
if ws_dir.exists():
    shutil.rmtree(ws_dir, onerror=on_rm_error)
ws_dir.mkdir(parents=True, exist_ok=True)

print(f"Creating disposable sample workspace at: {ws_dir}")

# Create buggy implementation
(ws_dir / "calculator.py").write_text("def add(a, b):\n    return a - b  # BUG: subtraction instead of addition\n", encoding="utf-8")
(ws_dir / "test_calculator.py").write_text(
    "import unittest\n"
    "from calculator import add\n\n"
    "class TestCalc(unittest.TestCase):\n"
    "    def test_add(self):\n"
    "        self.assertEqual(add(2, 3), 5)\n\n"
    "if __name__ == '__main__':\n"
    "    unittest.main()\n",
    encoding="utf-8"
)

# Git init and baseline commit
subprocess.run(["git", "init"], cwd=str(ws_dir), check=True, capture_output=True)
subprocess.run(["git", "-c", "user.name=Test", "-c", "user.email=test@test.local", "add", "."], cwd=str(ws_dir), check=True, capture_output=True)
subprocess.run(["git", "-c", "user.name=Test", "-c", "user.email=test@test.local", "commit", "-m", "baseline with bug"], cwd=str(ws_dir), check=True, capture_output=True)

print("Baseline commit created with intentional failing test.")

# 2. Tool definitions
tools = [
    {
        "type": "function",
        "function": {
            "name": "list_files",
            "description": "List files in workspace.",
            "parameters": {"type": "object", "properties": {}, "required": []}
        }
    },
    {
        "type": "function",
        "function": {
            "name": "read_file",
            "description": "Read file contents from workspace.",
            "parameters": {
                "type": "object",
                "properties": {"path": {"type": "string"}},
                "required": ["path"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "write_file",
            "description": "Write file contents to workspace.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string"},
                    "content": {"type": "string"}
                },
                "required": ["path", "content"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "run_check",
            "description": "Run check/test command in workspace.",
            "parameters": {
                "type": "object",
                "properties": {"command": {"type": "string"}},
                "required": ["command"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "get_git_diff",
            "description": "Get git diff relative to HEAD.",
            "parameters": {"type": "object", "properties": {}, "required": []}
        }
    }
]

messages = [
    {
        "role": "system",
        "content": (
            "You are an autonomous coding agent. Your goal is to inspect the workspace, "
            "run the project tests using run_check ('python -m unittest test_calculator.py'), "
            "diagnose any failure, repair the code in calculator.py using write_file, "
            "and re-run the tests to verify the fix."
        )
    },
    {
        "role": "user",
        "content": "The test suite in test_calculator.py is currently failing. Please inspect, run the test, fix the bug, and verify the test passes."
    }
]

client = httpx.Client(timeout=120.0)
headers = {"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"}

print("\n--- Starting Autonomous Agent Loop ---")
for iteration in range(1, 8):
    print(f"\n[Iteration {iteration}] Sending messages to Meta Model ({model_id})...")
    resp = client.post(
        f"{base_url}/chat/completions",
        headers=headers,
        json={"model": model_id, "messages": messages, "tools": tools, "tool_choice": "auto"}
    )
    if resp.status_code != 200:
        print(f"Error {resp.status_code}: {resp.text}")
        sys.exit(1)

    choice = resp.json()["choices"][0]
    msg = choice["message"]
    messages.append(msg)

    if msg.get("content"):
        print(f"Meta Model Thought: {msg['content'][:300]}")

    tool_calls = msg.get("tool_calls", [])
    if not tool_calls:
        print("Meta Model concluded loop (no further tool calls).")
        break

    for tc in tool_calls:
        fn_name = tc["function"]["name"]
        raw_args = tc["function"].get("arguments", "{}")
        try:
            args = json.loads(raw_args)
        except Exception:
            args = {}

        print(f"-> Tool Call: {fn_name}({args})")
        tool_result = ""

        if fn_name == "list_files":
            files = [p.name for p in ws_dir.iterdir() if p.name != ".git"]
            tool_result = json.dumps(files)
        elif fn_name == "read_file":
            target = ws_dir / args.get("path", "")
            tool_result = target.read_text(encoding="utf-8") if target.exists() else "File not found"
        elif fn_name == "write_file":
            target = ws_dir / args.get("path", "")
            target.write_text(args.get("content", ""), encoding="utf-8")
            tool_result = json.dumps({"ok": True, "path": args.get("path")})
        elif fn_name == "run_check":
            cmd = args.get("command", "")
            proc = subprocess.run(cmd, cwd=str(ws_dir), shell=True, capture_output=True, text=True)
            tool_result = f"Exit code: {proc.returncode}\nStdout: {proc.stdout}\nStderr: {proc.stderr}"
            print(f"   Check Output: {tool_result.strip()}")
        elif fn_name == "get_git_diff":
            diff = subprocess.run(["git", "diff", "HEAD"], cwd=str(ws_dir), capture_output=True, text=True).stdout
            tool_result = diff

        messages.append({
            "role": "tool",
            "tool_call_id": tc["id"],
            "content": tool_result
        })

# 3. Final verification of Git Diff and Test
print("\n--- Final Verification Evidence ---")
final_diff = subprocess.run(["git", "diff", "HEAD"], cwd=str(ws_dir), capture_output=True, text=True).stdout
print(f"Final Git Diff:\n{final_diff}")

final_test = subprocess.run(["python", "-m", "unittest", "test_calculator.py"], cwd=str(ws_dir), capture_output=True, text=True)
print(f"Final Test Exit Code: {final_test.returncode}")
print(f"Final Test Output: {final_test.stderr.strip()}")

if final_test.returncode == 0 and "FAIL" not in final_test.stderr and ("+" in final_diff):
    print("\nSUCCESS: Real test failure captured, autonomously repaired, and verified with exit code 0!")
else:
    print("\nFAIL: Test did not pass cleanly after repair.")
    sys.exit(1)
