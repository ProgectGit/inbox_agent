#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"

if [[ ! -f .env ]]; then
  echo "Missing $project_dir/.env" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

required=(
  OWNER_TELEGRAM_USER_ID
  OWNER_TELEGRAM_CHAT_ID
  OWNER_DISPLAY_NAME
  OWNER_LOCALE
)

for variable in "${required[@]}"; do
  if [[ -z "${!variable:-}" ]]; then
    echo "Missing $variable in .env" >&2
    exit 1
  fi
done

docker compose exec -T postgres sh -lc \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1' \
  < database/migrations/001_initial_schema.sql

docker compose exec -T postgres sh -lc \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1' \
  < database/migrations/002_seed_taxonomy.sql

docker compose exec -T postgres sh -lc \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 \
    -v telegram_user_id="$OWNER_TELEGRAM_USER_ID" \
    -v telegram_chat_id="$OWNER_TELEGRAM_CHAT_ID" \
    -v username="$OWNER_TELEGRAM_USERNAME" \
    -v display_name="$OWNER_DISPLAY_NAME" \
    -v locale="$OWNER_LOCALE"' \
  < database/migrations/003_seed_owner.sql

for migration in database/migrations/[0-9][0-9][0-9]_*.sql; do
  [[ -e "$migration" ]] || continue
  case "${migration##*/}" in
    001_*|002_*|003_*) continue ;;
  esac
  docker compose exec -T postgres sh -lc \
    'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1' \
    < "$migration"
done

echo "Inbox Agent database migrations applied successfully."
