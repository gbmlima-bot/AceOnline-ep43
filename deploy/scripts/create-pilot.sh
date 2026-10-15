#!/bin/sh
set -eu
if [ "$#" -eq 0 ]; then
  echo 'Usage: scripts/create-pilot.sh "Pilot label"' >&2
  exit 1
fi
cd "$(dirname "$0")/.."
# The generated token is intentionally printed only to this operator terminal.
exec docker compose exec -T game godot --headless --path /opt/ace/app \
  --log-file /dev/null --script res://admin.gd -- --data-dir=/data create-pilot "$@"
