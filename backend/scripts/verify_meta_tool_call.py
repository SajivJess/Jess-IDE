import os
import json
import httpx
from dotenv import load_dotenv

load_dotenv()

api_key = os.getenv("MODEL_API_KEY", "")
base_url = os.getenv("META_MODEL_BASE_URL", "https://api.meta.ai/v1").rstrip("/")
model_id = os.getenv("META_MODEL_ID", "muse-spark-1.3")

if not api_key:
    print("FAIL: MODEL_API_KEY is not set.")
    exit(1)

masked_key = api_key[:6] + "..." + api_key[-4:]
print(f"Testing live Meta Model API with key {masked_key} on {base_url} with model {model_id}")

tools = [
    {
        "type": "function",
        "function": {
            "name": "list_files",
            "description": "List files in the workspace directory.",
            "parameters": {
                "type": "object",
                "properties": {
                    "directory": {"type": "string", "description": "Subdirectory to list"}
                },
                "required": []
            }
        }
    }
]

messages = [
    {"role": "system", "content": "You are a coding assistant. Use the list_files tool to inspect the workspace."},
    {"role": "user", "content": "Please inspect the root workspace and tell me what files are present."}
]

client = httpx.Client(timeout=30.0)

# Step 1: Initial call requesting tool call
print("\n--- Step 1: Requesting chat completion with tools ---")
resp1 = client.post(
    f"{base_url}/chat/completions",
    headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
    json={
        "model": model_id,
        "messages": messages,
        "tools": tools,
        "tool_choice": "auto"
    }
)

print(f"Status: {resp1.status_code}")
if resp1.status_code != 200:
    print(f"Error: {resp1.text}")
    exit(1)

data1 = resp1.json()
choice1 = data1["choices"][0]
msg1 = choice1["message"]
tool_calls = msg1.get("tool_calls", [])

print(f"Model ID returned: {data1.get('model', 'unknown')}")
print(f"Content: {msg1.get('content')}")
print(f"Tool calls received: {len(tool_calls)}")

if not tool_calls:
    print("FAIL: Model did not request any tool call.")
    exit(1)

tc = tool_calls[0]
print(f"Tool requested: {tc['function']['name']}, arguments: {tc['function']['arguments']}")
messages.append(msg1)

# Step 2: Feed back real tool result
print("\n--- Step 2: Returning tool result to model ---")
fake_tool_result = json.dumps(["README.md", "main.py", "test_main.py"])
messages.append({
    "role": "tool",
    "tool_call_id": tc["id"],
    "content": fake_tool_result
})

resp2 = client.post(
    f"{base_url}/chat/completions",
    headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
    json={
        "model": model_id,
        "messages": messages,
        "tools": tools,
    }
)

print(f"Status: {resp2.status_code}")
if resp2.status_code != 200:
    print(f"Error: {resp2.text}")
    exit(1)

data2 = resp2.json()
choice2 = data2["choices"][0]
msg2 = choice2["message"]
print(f"Model follow-up response: {msg2.get('content')}")
print("\nSUCCESS: Full tool-call round trip verified with muse-spark-1.3!")
