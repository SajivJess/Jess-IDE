ALTER TABLE conversations ADD COLUMN archived_at timestamptz;
ALTER TABLE conversations ADD COLUMN metadata_revision integer NOT NULL DEFAULT 0 CHECK(metadata_revision>=0);
CREATE INDEX conversations_activity ON conversations(project_id,updated_at DESC,id DESC);
