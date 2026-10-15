import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("bundle", Path(__file__).parents[2] / "tools/build_server_bundle.py")
BUNDLE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUNDLE)


class ServerBundle(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.source = Path(self.temporary.name) / "project"
        self.source.mkdir()
        required = ["server/project.godot", "server/main.gd", "server/admin.gd", "server/server.tscn",
                    "server/addons/godot-sqlite/gdsqlite.gdextension",
                    "server/addons/godot-sqlite/libsqlite.linux.debug.x86_64.so"]
        required += ["client/scripts/online/" + name for name in BUNDLE.ONLINE_SCRIPTS]
        required += ["client/scripts/" + name for name in BUNDLE.CORE_SCRIPTS]
        required += ["client/" + name for name in BUNDLE.DATA_FILES + BUNDLE.WORLD_FILES]
        for name in required:
            path = self.source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("fixture\n")

    def tearDown(self):
        self.temporary.cleanup()

    def test_whitelist_omits_artwork_credentials_and_saves(self):
        for name in ["client/assets/original_world/3002.glb", "client/credentials.env", "client/players.sqlite", "server/token.txt", "client/scripts/online/online_view.gd"]:
            (self.source / name).write_bytes(b"excluded")
        output = Path(self.temporary.name) / "bundle"
        report = BUNDLE.build(self.source, output, None, app_only=True)
        names = {row["path"] for row in report["files"]}
        self.assertTrue(names)
        self.assertFalse(any(name.endswith((".glb", ".env", ".sqlite", "token.txt")) for name in names))
        self.assertNotIn("scripts/online/online_view.gd", names)
        self.assertEqual((output / "app/scripts/inventory_model.gd").read_text(), "fixture\n")

    def test_identical_sources_produce_identical_manifests(self):
        first = Path(self.temporary.name) / "first"
        second = Path(self.temporary.name) / "second"
        BUNDLE.build(self.source, first, None, app_only=True)
        BUNDLE.build(self.source, second, None, app_only=True)
        self.assertEqual((first / "bundle-manifest.json").read_bytes(), (second / "bundle-manifest.json").read_bytes())

    def test_missing_data_and_script_symlink_fail_closed(self):
        path = self.source / "client/scripts/flight_model.gd"
        path.unlink()
        with self.assertRaises(ValueError):
            BUNDLE.application_files(self.source)
        outside = Path(self.temporary.name) / "outside.gd"
        outside.write_text("outside")
        path.symlink_to(outside)
        with self.assertRaises(ValueError):
            BUNDLE.application_files(self.source)

    def test_unmarked_output_and_wrong_engine_cannot_be_replaced(self):
        output = Path(self.temporary.name) / "existing"
        output.mkdir()
        (output / "personal.txt").write_text("keep")
        with self.assertRaises(ValueError):
            BUNDLE.build(self.source, output, None, app_only=True, force=True)
        self.assertEqual((output / "personal.txt").read_text(), "keep")
        with self.assertRaises(ValueError):
            BUNDLE.build(self.source, output, self.source / "server/main.gd")

    def test_force_preserves_operator_backups_in_a_marked_bundle(self):
        output = Path(self.temporary.name) / "generated"
        BUNDLE.build(self.source, output, None, app_only=True)
        backup = output / "backups/real.sqlite"
        backup.parent.mkdir()
        backup.write_bytes(b"operator backup")
        with self.assertRaises(ValueError):
            BUNDLE.build(self.source, output, None, app_only=True, force=True)
        self.assertEqual(backup.read_bytes(), b"operator backup")


if __name__ == "__main__":
    unittest.main()
