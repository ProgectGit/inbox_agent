BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE SCHEMA IF NOT EXISTS inbox;

CREATE TABLE IF NOT EXISTS inbox.schema_migrations (
  version text PRIMARY KEY,
  applied_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION inbox.set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

CREATE TABLE IF NOT EXISTS inbox.users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  telegram_user_id bigint UNIQUE,
  telegram_chat_id bigint,
  username text,
  display_name text NOT NULL,
  locale text NOT NULL DEFAULT 'uk',
  role text NOT NULL DEFAULT 'user'
    CHECK (role IN ('owner', 'admin', 'user')),
  status text NOT NULL DEFAULT 'active'
    CHECK (status IN ('active', 'disabled')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS inbox.projects (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug text NOT NULL UNIQUE,
  name text NOT NULL UNIQUE,
  description text,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS inbox.categories (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug text NOT NULL UNIQUE,
  name text NOT NULL UNIQUE,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS inbox.item_types (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug text NOT NULL UNIQUE,
  name text NOT NULL UNIQUE,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS inbox.priorities (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug text NOT NULL UNIQUE,
  name text NOT NULL UNIQUE,
  rank smallint NOT NULL UNIQUE CHECK (rank BETWEEN 1 AND 4),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS inbox.inbox_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES inbox.users(id) ON DELETE RESTRICT,
  source text NOT NULL
    CHECK (source IN ('telegram', 'web_api', 'browser', 'mcp', 'import', 'manual')),
  source_message_id text,
  source_chat_id text,
  source_url text,
  content_type text NOT NULL
    CHECK (content_type IN ('text', 'voice', 'photo', 'file', 'link', 'mixed')),
  raw_text text,
  normalized_text text,
  raw_payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  content_hash text,
  status text NOT NULL DEFAULT 'received'
    CHECK (status IN (
      'received',
      'extracting',
      'analyzing',
      'indexing',
      'ready',
      'needs_review',
      'failed'
    )),
  error_code text,
  error_message text,
  retry_count integer NOT NULL DEFAULT 0 CHECK (retry_count >= 0),
  received_at timestamptz NOT NULL DEFAULT now(),
  processed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS inbox_items_source_message_uidx
  ON inbox.inbox_items (user_id, source, source_message_id)
  WHERE source_message_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS inbox_items_content_hash_uidx
  ON inbox.inbox_items (user_id, content_hash)
  WHERE content_hash IS NOT NULL;

CREATE INDEX IF NOT EXISTS inbox_items_status_received_idx
  ON inbox.inbox_items (status, received_at);

CREATE INDEX IF NOT EXISTS inbox_items_user_received_idx
  ON inbox.inbox_items (user_id, received_at DESC);

CREATE INDEX IF NOT EXISTS inbox_items_raw_payload_gin_idx
  ON inbox.inbox_items USING gin (raw_payload jsonb_path_ops);

CREATE TABLE IF NOT EXISTS inbox.attachments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  inbox_item_id uuid NOT NULL REFERENCES inbox.inbox_items(id) ON DELETE CASCADE,
  kind text NOT NULL
    CHECK (kind IN ('voice', 'photo', 'document', 'archive', 'other')),
  original_name text,
  mime_type text,
  size_bytes bigint CHECK (size_bytes IS NULL OR size_bytes >= 0),
  storage_path text,
  telegram_file_id text,
  checksum_sha256 text,
  extracted_text text,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS attachments_inbox_item_idx
  ON inbox.attachments (inbox_item_id);

CREATE UNIQUE INDEX IF NOT EXISTS attachments_checksum_uidx
  ON inbox.attachments (checksum_sha256)
  WHERE checksum_sha256 IS NOT NULL;

CREATE TABLE IF NOT EXISTS inbox.knowledge_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  inbox_item_id uuid NOT NULL UNIQUE REFERENCES inbox.inbox_items(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES inbox.users(id) ON DELETE RESTRICT,
  project_id uuid REFERENCES inbox.projects(id) ON DELETE SET NULL,
  category_id uuid REFERENCES inbox.categories(id) ON DELETE SET NULL,
  item_type_id uuid REFERENCES inbox.item_types(id) ON DELETE SET NULL,
  priority_id uuid REFERENCES inbox.priorities(id) ON DELETE SET NULL,
  title text NOT NULL,
  summary text NOT NULL,
  content text NOT NULL,
  language text NOT NULL DEFAULT 'uk',
  source_url text,
  next_actions jsonb NOT NULL DEFAULT '[]'::jsonb
    CHECK (jsonb_typeof(next_actions) = 'array'),
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  is_archived boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS knowledge_items_user_created_idx
  ON inbox.knowledge_items (user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS knowledge_items_project_idx
  ON inbox.knowledge_items (project_id, created_at DESC);

CREATE INDEX IF NOT EXISTS knowledge_items_category_idx
  ON inbox.knowledge_items (category_id, created_at DESC);

CREATE INDEX IF NOT EXISTS knowledge_items_type_idx
  ON inbox.knowledge_items (item_type_id, created_at DESC);

CREATE INDEX IF NOT EXISTS knowledge_items_metadata_gin_idx
  ON inbox.knowledge_items USING gin (metadata jsonb_path_ops);

CREATE TABLE IF NOT EXISTS inbox.knowledge_chunks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  knowledge_item_id uuid NOT NULL REFERENCES inbox.knowledge_items(id) ON DELETE CASCADE,
  chunk_index integer NOT NULL CHECK (chunk_index >= 0),
  content text NOT NULL,
  token_count integer CHECK (token_count IS NULL OR token_count >= 0),
  vector_id uuid NOT NULL UNIQUE DEFAULT gen_random_uuid(),
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (knowledge_item_id, chunk_index)
);

CREATE INDEX IF NOT EXISTS knowledge_chunks_item_idx
  ON inbox.knowledge_chunks (knowledge_item_id, chunk_index);

CREATE TABLE IF NOT EXISTS inbox.tags (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  normalized_name text NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS inbox.knowledge_item_tags (
  knowledge_item_id uuid NOT NULL REFERENCES inbox.knowledge_items(id) ON DELETE CASCADE,
  tag_id uuid NOT NULL REFERENCES inbox.tags(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (knowledge_item_id, tag_id)
);

CREATE TABLE IF NOT EXISTS inbox.relations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_item_id uuid NOT NULL REFERENCES inbox.knowledge_items(id) ON DELETE CASCADE,
  target_item_id uuid NOT NULL REFERENCES inbox.knowledge_items(id) ON DELETE CASCADE,
  relation_type text NOT NULL
    CHECK (relation_type IN ('similar', 'supports', 'contradicts', 'references', 'duplicate', 'continues')),
  score numeric(5,4) CHECK (score IS NULL OR score BETWEEN 0 AND 1),
  explanation text,
  created_by text NOT NULL DEFAULT 'ai'
    CHECK (created_by IN ('ai', 'user', 'system')),
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (source_item_id <> target_item_id),
  UNIQUE (source_item_id, target_item_id, relation_type)
);

CREATE INDEX IF NOT EXISTS relations_target_idx
  ON inbox.relations (target_item_id, relation_type);

CREATE TABLE IF NOT EXISTS inbox.conversations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES inbox.users(id) ON DELETE CASCADE,
  channel text NOT NULL CHECK (channel IN ('telegram', 'web', 'api')),
  external_conversation_id text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, channel, external_conversation_id)
);

CREATE TABLE IF NOT EXISTS inbox.messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id uuid NOT NULL REFERENCES inbox.conversations(id) ON DELETE CASCADE,
  role text NOT NULL CHECK (role IN ('user', 'assistant', 'system', 'tool')),
  content text NOT NULL,
  external_message_id text,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS messages_conversation_created_idx
  ON inbox.messages (conversation_id, created_at);

CREATE TABLE IF NOT EXISTS inbox.memories (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES inbox.users(id) ON DELETE CASCADE,
  source_knowledge_item_id uuid REFERENCES inbox.knowledge_items(id) ON DELETE SET NULL,
  kind text NOT NULL CHECK (kind IN ('fact', 'preference', 'goal', 'constraint', 'context')),
  content text NOT NULL,
  confidence numeric(5,4) NOT NULL DEFAULT 1 CHECK (confidence BETWEEN 0 AND 1),
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS memories_user_kind_idx
  ON inbox.memories (user_id, kind, created_at DESC);

CREATE TABLE IF NOT EXISTS inbox.documents (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  knowledge_item_id uuid NOT NULL REFERENCES inbox.knowledge_items(id) ON DELETE CASCADE,
  attachment_id uuid REFERENCES inbox.attachments(id) ON DELETE SET NULL,
  document_type text,
  page_count integer CHECK (page_count IS NULL OR page_count >= 0),
  extraction_metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (knowledge_item_id, attachment_id)
);

CREATE TABLE IF NOT EXISTS inbox.processing_jobs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  inbox_item_id uuid NOT NULL REFERENCES inbox.inbox_items(id) ON DELETE CASCADE,
  job_type text NOT NULL
    CHECK (job_type IN ('extract', 'analyze', 'index', 'relate', 'reprocess')),
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'running', 'completed', 'failed', 'cancelled')),
  attempts integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  max_attempts integer NOT NULL DEFAULT 4 CHECK (max_attempts BETWEEN 1 AND 10),
  run_after timestamptz NOT NULL DEFAULT now(),
  locked_at timestamptz,
  locked_by text,
  last_error text,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS processing_jobs_ready_idx
  ON inbox.processing_jobs (status, run_after)
  WHERE status IN ('pending', 'failed');

DROP TRIGGER IF EXISTS users_set_updated_at ON inbox.users;
CREATE TRIGGER users_set_updated_at
BEFORE UPDATE ON inbox.users
FOR EACH ROW EXECUTE FUNCTION inbox.set_updated_at();

DROP TRIGGER IF EXISTS projects_set_updated_at ON inbox.projects;
CREATE TRIGGER projects_set_updated_at
BEFORE UPDATE ON inbox.projects
FOR EACH ROW EXECUTE FUNCTION inbox.set_updated_at();

DROP TRIGGER IF EXISTS categories_set_updated_at ON inbox.categories;
CREATE TRIGGER categories_set_updated_at
BEFORE UPDATE ON inbox.categories
FOR EACH ROW EXECUTE FUNCTION inbox.set_updated_at();

DROP TRIGGER IF EXISTS item_types_set_updated_at ON inbox.item_types;
CREATE TRIGGER item_types_set_updated_at
BEFORE UPDATE ON inbox.item_types
FOR EACH ROW EXECUTE FUNCTION inbox.set_updated_at();

DROP TRIGGER IF EXISTS inbox_items_set_updated_at ON inbox.inbox_items;
CREATE TRIGGER inbox_items_set_updated_at
BEFORE UPDATE ON inbox.inbox_items
FOR EACH ROW EXECUTE FUNCTION inbox.set_updated_at();

DROP TRIGGER IF EXISTS attachments_set_updated_at ON inbox.attachments;
CREATE TRIGGER attachments_set_updated_at
BEFORE UPDATE ON inbox.attachments
FOR EACH ROW EXECUTE FUNCTION inbox.set_updated_at();

DROP TRIGGER IF EXISTS knowledge_items_set_updated_at ON inbox.knowledge_items;
CREATE TRIGGER knowledge_items_set_updated_at
BEFORE UPDATE ON inbox.knowledge_items
FOR EACH ROW EXECUTE FUNCTION inbox.set_updated_at();

DROP TRIGGER IF EXISTS conversations_set_updated_at ON inbox.conversations;
CREATE TRIGGER conversations_set_updated_at
BEFORE UPDATE ON inbox.conversations
FOR EACH ROW EXECUTE FUNCTION inbox.set_updated_at();

DROP TRIGGER IF EXISTS memories_set_updated_at ON inbox.memories;
CREATE TRIGGER memories_set_updated_at
BEFORE UPDATE ON inbox.memories
FOR EACH ROW EXECUTE FUNCTION inbox.set_updated_at();

DROP TRIGGER IF EXISTS processing_jobs_set_updated_at ON inbox.processing_jobs;
CREATE TRIGGER processing_jobs_set_updated_at
BEFORE UPDATE ON inbox.processing_jobs
FOR EACH ROW EXECUTE FUNCTION inbox.set_updated_at();

INSERT INTO inbox.schema_migrations (version)
VALUES ('001_initial_schema')
ON CONFLICT (version) DO NOTHING;

COMMIT;
