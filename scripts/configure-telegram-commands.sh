#!/bin/sh
set -eu

if [ -z "${TELEGRAM_BOT_TOKEN:-}" ]; then
  echo "TELEGRAM_BOT_TOKEN is required" >&2
  exit 1
fi

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
COMMANDS_FILE=${1:-"$ROOT_DIR/config/telegram-commands.json"}

if [ ! -f "$COMMANDS_FILE" ]; then
  echo "Commands file not found: $COMMANDS_FILE" >&2
  exit 1
fi

API_URL="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/setMyCommands"

curl --fail --silent --show-error \
  --request POST \
  --header 'Content-Type: application/json' \
  --data-binary "@$COMMANDS_FILE" \
  "$API_URL"

printf '\n'
