#!/bin/sh
set -eu

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "Usage: CONFIRM_RESTORE=n8n_agent $0 POSTGRES_DUMP [COMPOSE_DIRECTORY]" >&2
  exit 2
fi

if [ "${CONFIRM_RESTORE:-}" != "n8n_agent" ]; then
  echo "Refusing destructive restore. Set CONFIRM_RESTORE=n8n_agent after verifying the target server." >&2
  exit 1
fi

dump_path="$1"
compose_directory="${2:-/opt/inbox-agent-n8n}"
compose_file="${compose_directory}/docker-compose.yml"
env_file="${compose_directory}/.env"
database_container="inbox-agent-postgres"

if [ ! -f "${dump_path}" ] || [ ! -f "${compose_file}" ] || [ ! -f "${env_file}" ]; then
  echo "Dump, Compose file, or .env is missing" >&2
  exit 1
fi

compose() {
  docker compose --file "${compose_file}" --env-file "${env_file}" "$@"
}

restart_stack() {
  compose up -d >/dev/null 2>&1 || true
}
trap restart_stack EXIT INT TERM

compose up -d postgres
compose stop n8n postgres-backup config-backup >/dev/null 2>&1 || true
docker cp "${dump_path}" "${database_container}:/tmp/inbox-agent-restore.dump"
docker exec "${database_container}" dropdb --username n8n_agent --force --if-exists n8n_agent
docker exec "${database_container}" createdb --username n8n_agent --owner n8n_agent n8n_agent
docker exec "${database_container}" pg_restore \
  --username n8n_agent \
  --dbname n8n_agent \
  --no-owner \
  --no-acl \
  /tmp/inbox-agent-restore.dump
docker exec "${database_container}" rm -f /tmp/inbox-agent-restore.dump

required_tables="$(docker exec "${database_container}" psql -U n8n_agent -d n8n_agent -Atc \
  "SELECT to_regclass('inbox.inbox_items') IS NOT NULL AND to_regclass('public.workflow_entity') IS NOT NULL;")"
if [ "${required_tables}" != "t" ]; then
  echo "Restored database validation failed" >&2
  exit 1
fi

trap - EXIT INT TERM
compose up -d
echo "PostgreSQL restore completed and the Inbox Agent stack was started"
