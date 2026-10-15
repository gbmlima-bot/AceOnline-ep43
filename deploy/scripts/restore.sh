#!/bin/sh
set -eu
umask 077
if [ "$#" -ne 1 ] || [ ! -f "$1" ]; then
  echo 'Usage: scripts/restore.sh /absolute/path/to/verified-backup.sqlite' >&2
  exit 1
fi
source_file="$(realpath "$1")"
cd "$(dirname "$0")/.."
stamp="$(date -u +%Y%m%dT%H%M%SZ)-$$"
staged="/data/backups/restore-input-$stamp.sqlite"
# Stream the private file into the UID10001 volume; no world-readable bind mount.
docker compose run --rm --no-deps -T --entrypoint python3 game \
  /opt/ace/ops/sqlite_ops.py stage "$staged" < "$source_file"
# Preserve a current consistent recovery point before stopping the room.
./scripts/backup.sh
docker compose stop game
docker compose run --rm --no-deps -T --entrypoint python3 game \
  /opt/ace/ops/sqlite_ops.py checkpoint /data/ace-online.sqlite --server-stopped
docker compose run --rm --no-deps -T --entrypoint python3 game \
  /opt/ace/ops/sqlite_ops.py restore "$staged" /data/ace-online.sqlite --server-stopped
docker compose up -d game
echo 'Database restored; server health must become ready before reconnecting.'
