#!/usr/bin/env python3
"""Consistent SQLite backups and offline atomic restoration; no application tokens."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import sys
import tempfile

TABLES = {"pilots", "rooms", "receipts"}


def inspect_database(path: Path) -> dict:
    if path.is_symlink() or not path.is_file():
        raise ValueError("Database must be an existing regular file")
    connection = sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True, timeout=10)
    try:
        if connection.execute("PRAGMA integrity_check").fetchall() != [("ok",)]:
            raise ValueError("SQLite integrity check failed")
        if connection.execute("PRAGMA foreign_key_check").fetchone() is not None:
            raise ValueError("SQLite foreign-key check failed")
        tables = {row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        if not TABLES.issubset(tables):
            raise ValueError("File is not an ACE server database")
        version = int(connection.execute("PRAGMA user_version").fetchone()[0])
        if version != 1:
            raise ValueError("Unsupported ACE database schema version")
        return {"schema_version": version, "bytes": path.stat().st_size, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
    finally:
        connection.close()


def backup(source: Path, destination: Path) -> dict:
    if destination.exists() or destination.is_symlink():
        raise ValueError("Backup destination must be new")
    if source.is_symlink() or not source.is_file():
        raise ValueError("Source database is missing")
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    handle, temporary = tempfile.mkstemp(prefix=destination.name + ".tmp-", dir=destination.parent)
    os.close(handle)
    temporary = Path(temporary)
    original = sqlite3.connect(source.resolve().as_uri() + "?mode=ro", uri=True, timeout=10)
    target = sqlite3.connect(temporary, timeout=10)
    try:
        original.backup(target, pages=128, sleep=0.05)
        target.execute("PRAGMA journal_mode=DELETE")
        target.close()
        original.close()
        report = inspect_database(temporary)
        with temporary.open("rb") as stream:
            os.fsync(stream.fileno())
        # Hard link refuses to overwrite even if another operator races this backup.
        os.link(temporary, destination)
        destination.chmod(0o600)
        return {"ok": True, "operation": "backup", **report}
    finally:
        target.close()
        original.close()
        temporary.unlink(missing_ok=True)


def stage(destination: Path, stream) -> dict:
    if destination.exists() or destination.is_symlink():
        raise ValueError("Staging destination must be new")
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    handle, name = tempfile.mkstemp(prefix="restore-upload-", dir=destination.parent)
    temporary = Path(name)
    try:
        with os.fdopen(handle, "wb") as output:
            count = 0
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                count += len(chunk)
                if count > 512 * 1024 * 1024:
                    raise ValueError("Backup exceeds this small server's512MiB restore limit")
                output.write(chunk)
            output.flush()
            os.fsync(output.fileno())
        report = inspect_database(temporary)
        os.link(temporary, destination)
        destination.chmod(0o600)
        return {"ok": True, "operation": "stage", **report}
    finally:
        temporary.unlink(missing_ok=True)


def restore(source: Path, destination: Path, stopped: bool) -> dict:
    if not stopped:
        raise ValueError("Restore requires the server to be stopped")
    report = inspect_database(source)
    if destination.is_symlink():
        raise ValueError("Restore target cannot be a symbolic link")
    # An offline target must have no pending WAL; do not discard committed pages.
    for suffix in ("-wal", "-shm"):
        if Path(str(destination) + suffix).exists():
            raise ValueError("Target still has WAL/SHM files; checkpoint it offline first")
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    handle, name = tempfile.mkstemp(prefix=destination.name + ".restore-", dir=destination.parent)
    temporary = Path(name)
    try:
        with os.fdopen(handle, "wb") as stream, source.open("rb") as source_stream:
            for chunk in iter(lambda: source_stream.read(1024 * 1024), b""):
                stream.write(chunk)
            stream.flush()
            os.fsync(stream.fileno())
        inspect_database(temporary)
        temporary.chmod(0o600)
        os.replace(temporary, destination)
        directory = os.open(destination.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
        return {"ok": True, "operation": "restore", **report}
    finally:
        temporary.unlink(missing_ok=True)


def checkpoint(path: Path, stopped: bool) -> dict:
    if not stopped:
        raise ValueError("Offline checkpoint requires the server to be stopped")
    inspect_database(path)
    connection = sqlite3.connect(path, timeout=10)
    try:
        result = connection.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone()
        if result and result[0] != 0:
            raise ValueError("Database is busy; server may still be running")
        connection.execute("PRAGMA journal_mode=DELETE")
    finally:
        connection.close()
    return {"ok": True, "operation": "checkpoint"}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("backup", "verify", "restore", "checkpoint", "stage"))
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path, nargs="?")
    parser.add_argument("--server-stopped", action="store_true")
    args = parser.parse_args()
    os.umask(0o077)
    try:
        if args.operation == "stage":
            result = stage(args.source, sys.stdin.buffer)
        elif args.operation == "verify":
            result = {"ok": True, **inspect_database(args.source)}
        elif args.operation == "checkpoint":
            result = checkpoint(args.source, args.server_stopped)
        elif args.destination is None:
            raise ValueError("A destination path is required")
        elif args.operation == "backup":
            result = backup(args.source, args.destination)
        else:
            result = restore(args.source, args.destination, args.server_stopped)
        print(json.dumps(result, sort_keys=True))
    except (ValueError, sqlite3.Error, OSError) as error:
        parser.exit(1, str(error) + "\n")


if __name__ == "__main__":
    main()
