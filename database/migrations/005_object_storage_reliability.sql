BEGIN;

DROP INDEX IF EXISTS inbox.attachments_checksum_uidx;
DROP INDEX IF EXISTS inbox.attachments_storage_object_uidx;

CREATE INDEX IF NOT EXISTS attachments_checksum_idx
  ON inbox.attachments (checksum_sha256)
  WHERE checksum_sha256 IS NOT NULL;

CREATE INDEX IF NOT EXISTS attachments_storage_object_idx
  ON inbox.attachments (storage_provider, storage_bucket, object_key)
  WHERE storage_bucket IS NOT NULL AND object_key IS NOT NULL;

ALTER TABLE inbox.attachments
  ADD COLUMN IF NOT EXISTS duplicate_of_attachment_id uuid
    REFERENCES inbox.attachments(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS upload_attempts integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS upload_started_at timestamptz,
  ADD COLUMN IF NOT EXISTS next_upload_at timestamptz,
  ADD COLUMN IF NOT EXISTS storage_alerted_at timestamptz;

ALTER TABLE inbox.attachments
  DROP CONSTRAINT IF EXISTS attachments_upload_attempts_check;

ALTER TABLE inbox.attachments
  ADD CONSTRAINT attachments_upload_attempts_check
  CHECK (upload_attempts >= 0);

CREATE INDEX IF NOT EXISTS attachments_upload_queue_idx
  ON inbox.attachments (next_upload_at, created_at)
  WHERE upload_status IN ('metadata_only', 'pending', 'failed', 'uploading');

CREATE INDEX IF NOT EXISTS attachments_duplicate_of_idx
  ON inbox.attachments (duplicate_of_attachment_id)
  WHERE duplicate_of_attachment_id IS NOT NULL;

INSERT INTO inbox.schema_migrations (version)
VALUES ('005_object_storage_reliability')
ON CONFLICT (version) DO NOTHING;

COMMIT;
