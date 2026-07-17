#!/bin/sh
set -eu

threshold="${DISK_ALERT_PERCENT:-80}"
interval_seconds="${DISK_CHECK_INTERVAL_SECONDS:-300}"
state="unknown"

case "${threshold}" in
  ''|*[!0-9]*) echo "DISK_ALERT_PERCENT must be an integer" >&2; exit 1 ;;
esac

while true; do
  usage="$(df -P /host | awk 'NR == 2 { gsub(/%/, "", $5); print $5 }')"
  available="$(df -Pk /host | awk 'NR == 2 { print $4 }')"
  date -u +%Y-%m-%dT%H:%M:%SZ > /tmp/last-disk-check

  if [ "${usage}" -ge "${threshold}" ]; then
    if [ "${state}" != "warning" ]; then
      echo "WARNING: host disk usage is ${usage}% (threshold ${threshold}%, available ${available} KiB)" >&2
    fi
    state="warning"
  else
    if [ "${state}" = "warning" ]; then
      echo "RECOVERED: host disk usage returned to ${usage}%"
    elif [ "${state}" = "unknown" ]; then
      echo "Disk monitor active: usage ${usage}%, warning threshold ${threshold}%"
    fi
    state="ok"
  fi

  sleep "${interval_seconds}"
done
