-- Review-only snapshots. API requests never dereference a host filesystem path.
CREATE TABLE registered_repositories (
  id uuid PRIMARY KEY, owner_id uuid NOT NULL, name varchar(100) NOT NULL,
  github_url text NOT NULL, branch varchar(200) NOT NULL, base_commit varchar(64) NOT NULL,
  source_directory text NOT NULL, created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX repositories_owner ON registered_repositories(owner_id);
CREATE TABLE repository_files (
  repository_id uuid NOT NULL REFERENCES registered_repositories(id),
  path varchar(300) NOT NULL, content text, reason varchar(100), size integer NOT NULL,
  PRIMARY KEY(repository_id,path), CHECK ((content IS NULL) = (reason IS NOT NULL)),
  CHECK(size>=0), CHECK(content IS NULL OR octet_length(content)<=65536)
);
CREATE TABLE review_workspaces (
  id uuid PRIMARY KEY, task_id uuid NOT NULL UNIQUE REFERENCES tasks(id),
  repository_id uuid NOT NULL REFERENCES registered_repositories(id),
  revision integer NOT NULL DEFAULT 0 CHECK(revision>=0),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE workspace_files (
  workspace_id uuid NOT NULL REFERENCES review_workspaces(id),
  path varchar(300) NOT NULL, content text, version integer NOT NULL DEFAULT 0 CHECK(version>=0),
  PRIMARY KEY(workspace_id,path), CHECK(content IS NULL OR octet_length(content)<=65536)
);
CREATE TABLE workspace_edits (
  workspace_id uuid NOT NULL REFERENCES review_workspaces(id), revision integer NOT NULL,
  owner_id uuid NOT NULL, path varchar(300) NOT NULL, before_hash char(64) NOT NULL, after_hash char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY(workspace_id,revision)
);
