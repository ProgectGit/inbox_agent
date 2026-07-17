#!/bin/sh
set -eu

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "Usage: $0 RECOVERY_BUNDLE AGE_IDENTITY [TARGET_DIRECTORY]" >&2
  exit 2
fi

bundle="$1"
identity="$2"
target="${3:-./restored-inbox-agent-config}"

for command_name in age tar; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "Required command not found: ${command_name}" >&2
    exit 1
  fi
done

if [ -e "${target}" ]; then
  echo "Target already exists: ${target}" >&2
  exit 1
fi

umask 077
mkdir -p "${target}"
age --decrypt --identity "${identity}" "${bundle}" | tar -xzf - -C "${target}"

for required_file in \
  "${target}/inbox-agent/.env" \
  "${target}/inbox-agent/.backup.env" \
  "${target}/inbox-agent/docker-compose.yml" \
  "${target}/nginx/inbox.mihabot.top.conf"; do
  if [ ! -f "${required_file}" ]; then
    echo "Recovery bundle is missing ${required_file}" >&2
    exit 1
  fi
done

echo "Recovery configuration restored to ${target}"
