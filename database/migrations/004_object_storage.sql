BEGIN;

ALTER TABLE inbox.attachments
  ADD COLUMN IF NOT EXISTS storage_provider text NOT NULL DEFAULT 'telegram',
  ADD COLUMN IF NOT EXISTS storage_bucket text,
  ADD COLUMN IF NOT EXISTS object_key text,
  ADD COLUMN IF NOT EXISTS etag text,
  ADD COLUMN IF NOT EXISTS storage_class text,
  ADD COLUMN IF NOT EXISTS upload_status text NOT NULL DEFAULT 'metadata_only',
  ADD COLUMN IF NOT EXISTS uploaded_at timestamptz,
  ADD COLUMN IF NOT EXISTS encryption text,
  ADD COLUMN IF NOT EXISTS storage_error text;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'attachments_upload_status_check'
      AND conrelid = 'inbox.attachments'::regclass
  ) THEN
    ALTER TABLE inbox.attachments
      ADD CONSTRAINT attachments_upload_status_check
      CHECK (upload_status IN ('metadata_only', 'pending', 'uploading', 'stored', 'failed', 'deleted'));
  END IF;
END
$$;

CREATE UNIQUE INDEX IF NOT EXISTS attachments_storage_object_uidx
  ON inbox.attachments (storage_provider, storage_bucket, object_key)
  WHERE storage_bucket IS NOT NULL AND object_key IS NOT NULL;

CREATE INDEX IF NOT EXISTS attachments_storage_usage_idx
  ON inbox.attachments (storage_provider, upload_status)
  WHERE upload_status = 'stored';

CREATE TABLE IF NOT EXISTS inbox.storage_thresholds (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES inbox.users(id) ON DELETE CASCADE,
  storage_provider text NOT NULL,
  threshold_bytes bigint NOT NULL CHECK (threshold_bytes > 0),
  current_bytes bigint NOT NULL DEFAULT 0 CHECK (current_bytes >= 0),
  alerted_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, storage_provider, threshold_bytes)
);

DROP TRIGGER IF EXISTS storage_thresholds_set_updated_at ON inbox.storage_thresholds;
CREATE TRIGGER storage_thresholds_set_updated_at
BEFORE UPDATE ON inbox.storage_thresholds
FOR EACH ROW EXECUTE FUNCTION inbox.set_updated_at();

INSERT INTO inbox.storage_thresholds (user_id, storage_provider, threshold_bytes)
SELECT id, 'backblaze_b2', 7000000000
FROM inbox.users
WHERE status = 'active'
ON CONFLICT (user_id, storage_provider, threshold_bytes) DO NOTHING;

INSERT INTO inbox.schema_migrations (version)
VALUES ('004_object_storage')
ON CONFLICT (version) DO NOTHING;

COMMIT;
