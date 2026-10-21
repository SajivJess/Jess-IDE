ALTER TABLE projects ADD COLUMN last_opened_at timestamptz;
ALTER TABLE projects ADD COLUMN last_conversation_id uuid REFERENCES conversations(id) ON DELETE SET NULL;
CREATE INDEX projects_last_opened ON projects(owner_id,last_opened_at DESC);
