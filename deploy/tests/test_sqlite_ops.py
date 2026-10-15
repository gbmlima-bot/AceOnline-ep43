import importlib.util
import io
from pathlib import Path
import sqlite3
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("sqlite_ops", Path(__file__).parents[1] / "scripts/sqlite_ops.py")
OPS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(OPS)


class DatabaseOperations(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.source = self.root / "source.sqlite"
        self.writer = sqlite3.connect(self.source)
        self.writer.executescript("""
            PRAGMA journal_mode=WAL;
            CREATE TABLE pilots(id TEXT PRIMARY KEY, label TEXT);
            CREATE TABLE rooms(id TEXT PRIMARY KEY);
            CREATE TABLE receipts(pilot_id TEXT REFERENCES pilots(id));
            PRAGMA user_version=1;
            INSERT INTO pilots VALUES('pilot-one','Original');
        """)
        self.writer.commit()

    def tearDown(self):
        self.writer.close()
        self.temporary.cleanup()

    def test_live_wal_backup_has_committed_data_and_is_private(self):
        self.assertTrue(Path(str(self.source) + "-wal").exists())
        destination = self.root / "backup.sqlite"
        result = OPS.backup(self.source, destination)
        self.assertTrue(result["ok"])
        self.assertEqual(destination.stat().st_mode & 0o777, 0o600)
        self.assertEqual(sqlite3.connect(destination).execute("SELECT label FROM pilots").fetchone(), ("Original",))
        self.writer.execute("UPDATE pilots SET label='Newer'")
        self.writer.commit()
        self.assertEqual(sqlite3.connect(destination).execute("SELECT label FROM pilots").fetchone(), ("Original",))
        self.assertFalse(Path(str(destination) + "-wal").exists())

    def test_backup_refuses_existing_target(self):
        destination = self.root / "existing.sqlite"
        destination.write_bytes(b"do not replace")
        with self.assertRaises(ValueError):
            OPS.backup(self.source, destination)
        self.assertEqual(destination.read_bytes(), b"do not replace")

    def test_offline_restore_is_atomic_and_checks_source(self):
        source = self.root / "snapshot.sqlite"
        OPS.backup(self.source, source)
        target = self.root / "restored.sqlite"
        target.write_bytes(b"previous target")
        with self.assertRaises(ValueError):
            OPS.restore(source, target, False)
        self.assertEqual(target.read_bytes(), b"previous target")
        self.assertTrue(OPS.restore(source, target, True)["ok"])
        self.assertEqual(sqlite3.connect(target).execute("SELECT label FROM pilots").fetchone(), ("Original",))
        self.assertEqual(target.stat().st_mode & 0o777, 0o600)

    def test_restore_never_discards_a_pending_wal(self):
        source = self.root / "snapshot.sqlite"
        OPS.backup(self.source, source)
        target = self.root / "target.sqlite"
        target.write_bytes(b"previous target")
        Path(str(target) + "-wal").write_bytes(b"pending")
        with self.assertRaises(ValueError):
            OPS.restore(source, target, True)
        self.assertEqual(target.read_bytes(), b"previous target")

    def test_corrupt_wrong_schema_and_symlink_sources_are_refused(self):
        invalid = self.root / "corrupt.sqlite"
        invalid.write_bytes(b"not sqlite")
        with self.assertRaises(sqlite3.DatabaseError):
            OPS.inspect_database(invalid)
        linked = self.root / "linked.sqlite"
        linked.symlink_to(self.source)
        with self.assertRaises(ValueError):
            OPS.inspect_database(linked)
        self.writer.execute("PRAGMA user_version=2")
        self.writer.commit()
        with self.assertRaises(ValueError):
            OPS.inspect_database(self.source)

    def test_private_stdin_stage_validates_before_publishing(self):
        backup = self.root / "backup.sqlite"
        OPS.backup(self.source, backup)
        staged = self.root / "incoming.sqlite"
        result = OPS.stage(staged, io.BytesIO(backup.read_bytes()))
        self.assertEqual(result["sha256"], OPS.inspect_database(backup)["sha256"])
        self.assertEqual(staged.stat().st_mode & 0o777, 0o600)
        invalid = self.root / "bad-upload.sqlite"
        with self.assertRaises(sqlite3.DatabaseError):
            OPS.stage(invalid, io.BytesIO(b"corrupt"))
        self.assertFalse(invalid.exists())

    def test_offline_checkpoint_retains_wal_commit(self):
        self.writer.close()
        self.assertTrue(OPS.checkpoint(self.source, True)["ok"])
        self.assertFalse(Path(str(self.source) + "-wal").exists())
        self.assertEqual(sqlite3.connect(self.source).execute("SELECT label FROM pilots").fetchone(), ("Original",))


if __name__ == "__main__":
    unittest.main()
