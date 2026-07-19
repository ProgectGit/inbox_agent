#!/bin/sh
set -eu

N8N_CONTAINER=${N8N_CONTAINER:-inbox-agent-n8n}
TELEGRAM_CREDENTIAL_ID=${TELEGRAM_CREDENTIAL_ID:-iIA8c9213PIlR1Zm}
CONFIGURE_SCRIPT=${CONFIGURE_SCRIPT:-/opt/inbox-agent-n8n/scripts/configure-telegram-commands.sh}
EXPORT_FILE=/tmp/telegram-menu-credential.json

cleanup() {
  docker exec "$N8N_CONTAINER" rm -f "$EXPORT_FILE" >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM

docker exec "$N8N_CONTAINER" n8n export:credentials \
  --id="$TELEGRAM_CREDENTIAL_ID" \
  --decrypted \
  --output="$EXPORT_FILE" >/dev/null

TOKEN=$(docker exec "$N8N_CONTAINER" node -e '
const fs = require("fs");
const rows = JSON.parse(fs.readFileSync("/tmp/telegram-menu-credential.json", "utf8"));
const token = String(rows?.[0]?.data?.accessToken || rows?.[0]?.data?.token || "");
if (!token) process.exit(2);
process.stdout.write(token);
')

TELEGRAM_BOT_TOKEN="$TOKEN" "$CONFIGURE_SCRIPT"
unset TOKEN TELEGRAM_BOT_TOKEN
