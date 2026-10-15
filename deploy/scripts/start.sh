#!/bin/sh
set -eu
umask 077
mkdir -p "$HOME" "$ACE_DATA_DIR"
if [ ! -w "$ACE_DATA_DIR" ]; then
  echo 'ACE_DATA_DIR must be writable by UID 10001.' >&2
  exit 1
fi
exec python3 /opt/ace/ops/supervisor.py "$@"
