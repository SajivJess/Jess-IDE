import sqlite3
import uuid
import datetime

conn = sqlite3.connect('jess_dev.db')
c = conn.cursor()

ws_path = 'D:/SajivJess/jess dev ide/backend/workspaces_data/verification_test_repo'

# 1. Update cloudaiagent
c.execute("UPDATE projects SET workspace_path = ? WHERE name = 'cloudaiagent'", (ws_path,))
print("Updated cloudaiagent rows:", c.rowcount)

# 2. Add Calculator Demo Repo for dev@jess.dev
user = c.execute("SELECT id FROM users WHERE email = 'dev@jess.dev'").fetchone()
if user:
    user_id = user[0]
    exists = c.execute("SELECT id FROM projects WHERE name = 'Calculator Demo Repo' AND user_id = ?", (user_id,)).fetchone()
    if not exists:
        proj_id = uuid.uuid4().hex
        now = datetime.datetime.utcnow().isoformat()
        c.execute("""
            INSERT INTO projects (id, user_id, name, description, source_type, default_branch, workspace_path, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, (proj_id, user_id, 'Calculator Demo Repo', 'Demonstration repo for autonomous test failure diagnosis and repair', 'local', 'master', ws_path, now, now))
        print("Created Calculator Demo Repo project:", proj_id)
    else:
        c.execute("UPDATE projects SET workspace_path = ? WHERE id = ?", (ws_path, exists[0]))
        print("Updated existing Calculator Demo Repo project:", exists[0])

conn.commit()
conn.close()
