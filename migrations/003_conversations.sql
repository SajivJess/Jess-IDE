CREATE TABLE project_contexts (
  project_id uuid PRIMARY KEY REFERENCES projects(id),
  revision integer NOT NULL DEFAULT 0,
  summary text NOT NULL DEFAULT '', handoff text NOT NULL DEFAULT '',
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK(octet_length(summary)<=16000 AND octet_length(handoff)<=16000)
);
CREATE TABLE conversations (
  id uuid PRIMARY KEY, project_id uuid NOT NULL REFERENCES projects(id),
  repository_id uuid NOT NULL REFERENCES registered_repositories(id),
  title varchar(100) NOT NULL, provider text NOT NULL DEFAULT 'antigravity-cli',
  profile_binding varchar(100), native_session_id uuid,
  event_sequence integer NOT NULL DEFAULT 0, turn_sequence integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(provider,profile_binding,native_session_id)
);
CREATE INDEX conversations_project ON conversations(project_id,created_at);
CREATE TABLE conversation_turns (
  id uuid PRIMARY KEY, conversation_id uuid NOT NULL REFERENCES conversations(id),
  sequence integer NOT NULL, message_key uuid NOT NULL,
  prompt text NOT NULL, response text,
  status text NOT NULL CHECK(status IN ('DISPATCHING','COMPLETED','FAILED','UNCERTAIN')),
  error_code varchar(80), context_revision integer NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(), finished_at timestamptz,
  UNIQUE(conversation_id,message_key), UNIQUE(conversation_id,sequence),
  CHECK(octet_length(prompt)<=16000), CHECK(response IS NULL OR octet_length(response)<=65536)
);
CREATE UNIQUE INDEX one_dispatch_per_conversation ON conversation_turns(conversation_id) WHERE status='DISPATCHING';
CREATE TABLE conversation_events (
  conversation_id uuid NOT NULL REFERENCES conversations(id), sequence integer NOT NULL,
  kind varchar(40) NOT NULL, payload jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY(conversation_id,sequence)
);
