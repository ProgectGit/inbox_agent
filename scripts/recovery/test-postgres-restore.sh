#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 POSTGRES_DUMP" >&2
  exit 2
fi

dump_path="$1"
container_name="inbox-agent-restore-test"

cleanup() {
  docker rm -f "${container_name}" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

cleanup
docker run --detach \
  --name "${container_name}" \
  --env POSTGRES_PASSWORD=restore-test-only \
  --env POSTGRES_DB=restore_test \
  --tmpfs /var/lib/postgresql/data:rw,size=512m \
  postgres:16 >/dev/null

attempt=0
until docker exec "${container_name}" pg_isready -U postgres -d restore_test >/dev/null 2>&1; do
  attempt=$((attempt + 1))
  if [ "${attempt}" -ge 30 ]; then
    echo "Temporary PostgreSQL did not become ready" >&2
    exit 1
  fi
  sleep 1
done

docker cp "${dump_path}" "${container_name}:/tmp/restore-test.dump"
docker exec "${container_name}" pg_restore \
  --username postgres \
  --dbname restore_test \
  --no-owner \
  --no-acl \
  /tmp/restore-test.dump

result="$(docker exec "${container_name}" psql -U postgres -d restore_test -Atc \
  "SELECT to_regclass('inbox.inbox_items') IS NOT NULL AND to_regclass('public.workflow_entity') IS NOT NULL;")"
if [ "${result}" != "t" ]; then
  echo "Restore validation failed" >&2
  exit 1
fi

echo "PostgreSQL restore test passed"
