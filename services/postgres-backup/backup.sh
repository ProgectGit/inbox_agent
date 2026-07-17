#!/bin/sh
set -eu

interval_seconds="${BACKUP_INTERVAL_SECONDS:-86400}"
retention_days="${BACKUP_RETENTION_DAYS:-30}"
backup_prefix="${BACKUP_PREFIX:-backups/postgresql}"
retry_seconds="${BACKUP_RETRY_SECONDS:-300}"

export RCLONE_CONFIG_B2_TYPE=s3
export RCLONE_CONFIG_B2_PROVIDER=Other
export RCLONE_CONFIG_B2_ACCESS_KEY_ID="${B2_KEY_ID}"
export RCLONE_CONFIG_B2_SECRET_ACCESS_KEY="${B2_APPLICATION_KEY}"
export RCLONE_CONFIG_B2_ENDPOINT="${B2_S3_ENDPOINT}"
export RCLONE_CONFIG_B2_REGION="${B2_REGION}"
export RCLONE_CONFIG_B2_NO_CHECK_BUCKET=true

backup_once() {
  rm -f /tmp/inbox-agent-*.dump
  timestamp="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
  filename="inbox-agent-${timestamp}.dump"
  local_path="/tmp/${filename}"
  remote_path="b2:${B2_BUCKET}/${backup_prefix}/${filename}"

  rm -f "${local_path}"
  echo "Creating PostgreSQL backup ${filename}"
  pg_dump --format=custom --compress=6 --no-owner --no-acl --file="${local_path}"

  echo "Uploading ${filename} to private object storage"
  rclone copyto "${local_path}" "${remote_path}" \
    --s3-no-check-bucket \
    --contimeout 15s \
    --timeout 5m \
    --retries 3
  rm -f "${local_path}"
  date -u +%Y-%m-%dT%H:%M:%SZ > /tmp/last-backup-success
  echo "Backup ${filename} uploaded successfully"

  if ! rclone delete "b2:${B2_BUCKET}/${backup_prefix}" \
    --min-age "${retention_days}d" \
    --include "inbox-agent-*.dump" \
    --s3-no-check-bucket; then
    echo "Warning: remote retention cleanup failed; backup upload is still valid" >&2
  fi
}

while true; do
  until backup_once; do
    echo "Backup failed; retrying in ${retry_seconds} seconds" >&2
    sleep "${retry_seconds}"
  done
  sleep "${interval_seconds}"
done
