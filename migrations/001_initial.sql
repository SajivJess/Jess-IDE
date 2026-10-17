CREATE TABLE projects (
  id uuid PRIMARY KEY,
  owner_id uuid NOT NULL,
  name varchar(100) NOT NULL CHECK (length(trim(name)) > 0),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX projects_owner ON projects(owner_id);

-- The task row is also the durable job. No separate volatile queue is involved.
CREATE TABLE tasks (
  id uuid PRIMARY KEY,
  project_id uuid NOT NULL REFERENCES projects(id),
  prompt text NOT NULL CHECK (length(prompt) BETWEEN 1 AND 8000),
  idempotency_key varchar(128) NOT NULL,
  status text NOT NULL DEFAULT 'QUEUED'
    CHECK (status IN ('QUEUED', 'RUNNING', 'COMPLETED', 'FAILED', 'CANCELLED')),
  attempts integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  max_attempts integer NOT NULL DEFAULT 3 CHECK (max_attempts BETWEEN 1 AND 10),
  lease_token uuid,
  lease_expires_at timestamptz,
  cancel_requested boolean NOT NULL DEFAULT false,
  event_sequence integer NOT NULL DEFAULT 0 CHECK (event_sequence >= 0),
  result jsonb,
  error text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(project_id, idempotency_key),
  CHECK ((status = 'RUNNING') = (lease_token IS NOT NULL AND lease_expires_at IS NOT NULL))
);
CREATE INDEX tasks_claim ON tasks(status, lease_expires_at, created_at)
  WHERE status IN ('QUEUED', 'RUNNING');
CREATE INDEX tasks_project ON tasks(project_id, created_at);

CREATE TABLE task_events (
  task_id uuid NOT NULL REFERENCES tasks(id),
  sequence integer NOT NULL,
  type text NOT NULL,
  payload jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(task_id, sequence)
);
