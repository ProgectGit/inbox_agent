#!/bin/sh
set -eu

interval_seconds="${CONFIG_BACKUP_INTERVAL_SECONDS:-86400}"
retention_days="${BACKUP_RETENTION_DAYS:-30}"
backup_prefix="${CONFIG_BACKUP_PREFIX:-backups/config}"
retry_seconds="${BACKUP_RETRY_SECONDS:-300}"

if [ -z "${RECOVERY_AGE_RECIPIENT:-}" ]; then
  echo "RECOVERY_AGE_RECIPIENT is required" >&2
  exit 1
fi

export RCLONE_CONFIG_B2_TYPE=s3
export RCLONE_CONFIG_B2_PROVIDER=Other
export RCLONE_CONFIG_B2_ACCESS_KEY_ID="${B2_KEY_ID}"
export RCLONE_CONFIG_B2_SECRET_ACCESS_KEY="${B2_APPLICATION_KEY}"
export RCLONE_CONFIG_B2_ENDPOINT="${B2_S3_ENDPOINT}"
export RCLONE_CONFIG_B2_REGION="${B2_REGION}"
export RCLONE_CONFIG_B2_NO_CHECK_BUCKET=true

if [ "${1:-}" = "download-latest" ]; then
  destination="${2:-/tmp/inbox-agent-config-latest.tar.gz.age}"
  latest_file="$(
    rclone lsf "b2:${B2_BUCKET}/${backup_prefix}" \
      --files-only \
      --include "inbox-agent-config-*.tar.gz.age" \
      --s3-no-check-bucket | sort | tail -n 1
  )"
  if [ -z "${latest_file}" ]; then
    echo "No encrypted recovery bundle found" >&2
    exit 1
  fi
  rclone copyto \
    "b2:${B2_BUCKET}/${backup_prefix}/${latest_file}" \
    "${destination}" \
    --s3-no-check-bucket \
    --contimeout 15s \
    --timeout 5m \
    --retries 3
  echo "Latest recovery bundle downloaded to ${destination}"
  exit 0
fi

backup_config_once() {
  rm -f /tmp/inbox-agent-config-*.tar.gz.age
  timestamp="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
  filename="inbox-agent-config-${timestamp}.tar.gz.age"
  local_path="/tmp/${filename}"
  remote_path="b2:${B2_BUCKET}/${backup_prefix}/${filename}"

  echo "Creating encrypted recovery bundle ${filename}"
  tar -C /recovery -czf - . | age --encrypt \
    --recipient "${RECOVERY_AGE_RECIPIENT}" \
    --output "${local_path}"

  echo "Uploading encrypted recovery bundle"
  rclone copyto "${local_path}" "${remote_path}" \
    --s3-no-check-bucket \
    --contimeout 15s \
    --timeout 5m \
    --retries 3
  rm -f "${local_path}"
  date -u +%Y-%m-%dT%H:%M:%SZ > /tmp/last-config-backup-success
  echo "Encrypted recovery bundle uploaded successfully"

  if ! rclone delete "b2:${B2_BUCKET}/${backup_prefix}" \
    --min-age "${retention_days}d" \
    --include "inbox-agent-config-*.tar.gz.age" \
    --s3-no-check-bucket; then
    echo "Warning: recovery bundle retention cleanup failed" >&2
  fi
}

while true; do
  until backup_config_once; do
    echo "Config backup failed; retrying in ${retry_seconds} seconds" >&2
    sleep "${retry_seconds}"
  done
  sleep "${interval_seconds}"
done
