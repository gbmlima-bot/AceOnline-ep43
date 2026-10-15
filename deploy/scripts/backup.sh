#!/bin/sh
set -eu
umask 077
cd "$(dirname "$0")/.."
stamp="$(date -u +%Y%m%dT%H%M%SZ)-$$"
destination="${1:-./backups/ace-online-$stamp.sqlite}"
if [ -e "$destination" ]; then
  echo 'Backup destination already exists.' >&2
  exit 1
fi
mkdir -p "$(dirname "$destination")"
docker compose exec -T game python3 /opt/ace/ops/sqlite_ops.py backup \
  /data/ace-online.sqlite "/data/backups/ace-online-$stamp.sqlite"
docker compose cp "game:/data/backups/ace-online-$stamp.sqlite" "$destination"
chmod 0600 "$destination"
sha256sum "$destination" > "$destination.sha256"
echo "Backup saved: $destination"
