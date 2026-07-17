#!/bin/sh
set -eu

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "Usage: $0 RESTORED_CONFIG_DIRECTORY [TARGET_DIRECTORY]" >&2
  exit 2
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "Run this migration script as root on the new server" >&2
  exit 1
fi

restored_config="$1"
target="${2:-/opt/inbox-agent-n8n}"
repository_root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
postgres_dump="/tmp/inbox-agent-latest.dump"

for required_path in \
  "${restored_config}/inbox-agent/.env" \
  "${restored_config}/inbox-agent/.backup.env" \
  "${restored_config}/nginx/inbox.mihabot.top.conf"; do
  if [ ! -f "${required_path}" ]; then
    echo "Required migration input is missing: ${required_path}" >&2
    exit 1
  fi
done

install -d -m 0700 "${target}"
cp -R "${repository_root}/database" "${target}/"
cp -R "${repository_root}/services" "${target}/"
cp -R "${repository_root}/scripts" "${target}/"
install -m 0600 "${repository_root}/docker-compose.yml" "${target}/docker-compose.yml"
install -m 0600 "${restored_config}/inbox-agent/.env" "${target}/.env"
install -m 0600 "${restored_config}/inbox-agent/.backup.env" "${target}/.backup.env"
install -m 0644 "${restored_config}/nginx/inbox.mihabot.top.conf" /etc/nginx/conf.d/inbox.mihabot.top.conf

docker compose --file "${target}/docker-compose.yml" --env-file "${target}/.env" build
rm -f "${postgres_dump}"
docker compose --file "${target}/docker-compose.yml" --env-file "${target}/.env" run \
  --rm \
  --no-deps \
  --volume /tmp:/restore \
  postgres-backup \
  download-latest /restore/inbox-agent-latest.dump
CONFIRM_RESTORE=n8n_agent "${target}/scripts/recovery/restore-postgres.sh" "${postgres_dump}" "${target}"
rm -f "${postgres_dump}"
nginx -t
systemctl reload nginx

echo "Inbox Agent migration completed. Verify HTTPS, Telegram capture, B2 upload, and RAG search."
