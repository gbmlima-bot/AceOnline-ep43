#!/usr/bin/env python3
"""Synthetic source updates only; no real assets, exports or multi-GB downloads."""
from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import zipfile

SPEC = importlib.util.spec_from_file_location("completion_kit", Path(__file__).with_name("package_completion_kit.py"))
kit = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(kit)


def project(version):
    return f'[application]\nconfig/name="ACE Modern"\nconfig/version="{version}"\n'.encode()


class CompletionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.base = self.root / "base"
        self.base.mkdir()
        self.originals = {"client/project.godot": project("0.8.0"), "server/project.godot": project("0.8.0"),
                          "client/scripts/model.gd": b"extends Node\n# old\n",
                          "client/assets/native.bin": b"\0native asset\xff",
                          "client/assets/original_worlds/manifest.json": b'{"maps": 2}\n',
                          kit.ECONOMY_DATA: b'{"native_shops": {}}\n',
                          kit.MISSION_DATA: b'{"records": [], "summary": {"supported": 1}}\n'}
        for name, value in self.originals.items():
            path = self.base / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(value)
        self.overlay = {"client/project.godot": project("0.9.0"), "server/project.godot": project("0.9.0"),
                        "client/scripts/model.gd": b"extends Node\n# updated\n",
                        "client/scripts/new.gd": b"extends RefCounted\n",
                        kit.ECONOMY_DATA: b'{"native_shops": {"3": [101, 102]}}\n',
                        kit.MISSION_DATA: b'{"records": [], "summary": {"supported": 541}}\n'}
        native = "client/assets/native_server/ti_Monster.json"
        table = kit.S.json_bytes({"schema_version": 1, "table": "ti_Monster", "source_sha256": kit.NATIVE_SOURCE_SHA256,
                                  "columns": ["Code", "HP", "Name"], "rows": [[101, 12.5, "Static monster"]]})
        row = kit.data_row(native, table)
        self.overlay.update({native: table, kit.NATIVE_MANIFEST: kit.S.json_bytes({
            "schema_version": 1, "source": {"sha256": kit.NATIVE_SOURCE_SHA256},
            "exported": [{"table": "ti_Monster", "file": "ti_Monster.json", "bytes": row["bytes"], "sha256": row["sha256"]}]})})
        self.archive = self.root / "base.zip"
        with zipfile.ZipFile(self.archive, "w") as zipped:
            for name, value in self.originals.items():
                zipped.writestr(kit.ARCHIVE_ROOT + name, value)
        self.kit_path = self.root / "kit"
        self.build_fixture()

    def tearDown(self):
        self.temp.cleanup()

    def build_fixture(self):
        if self.kit_path.exists():
            shutil.rmtree(self.kit_path)
        staging = self.root / "source"
        for name, value in self.overlay.items():
            path = staging / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(value)
        self.baseline, self.inventory, changes = kit.base_and_overlay(
            self.archive, {name: staging / name for name in self.overlay}, kit.S.digest(self.archive))
        files = {"source-overlay/" + name: path for name, path in changes.items()}
        files.update({"apply-update.py": Path(kit.__file__), "support/package_online_kit.py": Path(kit.S.__file__),
                      "base-manifest.json": kit.S.json_bytes(self.baseline),
                      "preserved-assets.json": kit.S.json_bytes(self.inventory),
                      "overlay-manifest.json": kit.S.json_bytes({"release": "0.9.0", "files": [kit.S.row_for(path, name) for name, path in changes.items()]}),
                      "server-bundle/README.txt": b"Small synthetic server fixture\n"})
        self.fixture = self.root / "fixture.zip"
        kit.write_archive(self.fixture, files, force=True)
        with zipfile.ZipFile(self.fixture) as zipped:
            for item in zipped.infolist():
                name = item.filename.removeprefix(kit.KIT_DIR + "/")
                kit.S.safe_name(name)
                target = self.kit_path / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(zipped.read(item))

    def test_dry_run_and_standalone_cli_do_not_write(self):
        before = {p.relative_to(self.base): p.read_bytes() for p in self.base.rglob("*") if p.is_file()}
        result = subprocess.run([sys.executable, str(self.kit_path / "apply-update.py"), "--base", str(self.base), "--dry-run"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["changed_files"], len(self.overlay))
        self.assertEqual(before, {p.relative_to(self.base): p.read_bytes() for p in self.base.rglob("*") if p.is_file()})
        self.assertFalse((self.base / ".online-update-backups").exists())

    def test_apply_preserves_artwork_userdata_and_is_idempotent(self):
        profile = self.base / "userdata/profile.save"
        profile.parent.mkdir()
        profile.write_bytes(b"private pilot")
        result = kit.apply_update(self.kit_path, self.base, source_zip=self.archive)
        self.assertFalse(result["native_desktop_executables_updated"])
        self.assertEqual(result["preserved_asset_sizes_verified"], 2)
        for name, value in self.overlay.items():
            self.assertEqual((self.base / name).read_bytes(), value)
        self.assertEqual((self.base / "client/assets/native.bin").read_bytes(), self.originals["client/assets/native.bin"])
        self.assertEqual(profile.read_bytes(), b"private pilot")
        backup = Path(result["source_backup"])
        self.assertEqual((backup / "client/scripts/model.gd").read_bytes(), self.originals["client/scripts/model.gd"])
        self.assertTrue((backup / "update-receipt.json").is_file())
        self.assertTrue(kit.apply_update(self.kit_path, self.base)["already_applied"])

    def test_baseline_conflicts_are_refused_before_writes(self):
        for name in ("client/scripts/model.gd", "client/assets/original_worlds/manifest.json"):
            with self.subTest(name=name):
                (self.base / name).write_bytes(b"user changes")
                with self.assertRaisesRegex(ValueError, "Base file changed|asset missing or size changed"):
                    kit.apply_update(self.kit_path, self.base)
                self.assertEqual((self.base / "client/project.godot").read_bytes(), project("0.8.0"))
                (self.base / name).write_bytes(self.originals[name])
        (self.base / "client/scripts/new.gd").write_bytes(b"existing")
        with self.assertRaisesRegex(ValueError, "conflicts"):
            kit.apply_update(self.kit_path, self.base)

    def test_corrupt_asset_and_optional_zip_are_refused(self):
        native = self.base / "client/assets/native.bin"
        native.unlink()
        with self.assertRaisesRegex(ValueError, "asset missing"):
            kit.apply_update(self.kit_path, self.base)
        native.write_bytes(self.originals["client/assets/native.bin"])
        self.archive.write_bytes(b"corrupt original ZIP")
        with self.assertRaisesRegex(ValueError, "ZIP SHA256 mismatch"):
            kit.apply_update(self.kit_path, self.base, source_zip=self.archive)

    def test_source_only_policy_and_corruption(self):
        self.assertFalse(kit.allowed("client/assets/native.bin"))
        self.assertFalse(kit.allowed("server/addons/godot-sqlite/bin/evil.so"))
        self.assertFalse(kit.allowed("server/.env"))
        self.assertFalse(kit.allowed("client/assets/native_server/accounts.json"))
        self.assertFalse(kit.allowed("client/assets/native_server/acc.bak"))
        self.assertFalse(kit.allowed("client/assets/native_server/unreviewed.json"))
        self.assertFalse(kit.allowed("client/assets/native_server/ti_DissolutionItem.json"))
        self.assertFalse(kit.allowed("client/assets/native_server/ti_Tender.json"))
        self.assertFalse(kit.allowed("client/assets/native_server/ti_OutPostNextWarTime.json"))
        self.assertTrue(kit.allowed("client/assets/native_server/ti_Monster.json"))
        path = self.kit_path / "source-overlay/client/scripts/model.gd"
        path.write_bytes(b"bad bytes")
        with self.assertRaisesRegex(ValueError, "checksum/size"):
            kit.apply_update(self.kit_path, self.base)
        self.build_fixture()
        (self.kit_path / "unexpected.txt").write_text("extra")
        with self.assertRaisesRegex(ValueError, "unexpected"):
            kit.apply_update(self.kit_path, self.base)

    def test_symlinks_and_traversal_are_refused(self):
        outside = self.root / "outside"
        outside.mkdir()
        native = self.base / "client/assets/native.bin"
        native.unlink()
        native.symlink_to(outside / "target")
        with self.assertRaisesRegex(ValueError, "symlink"):
            kit.apply_update(self.kit_path, self.base)
        self.assertEqual(list(outside.iterdir()), [])
        with self.assertRaisesRegex(ValueError, "Unsafe"):
            kit.write_archive(self.root / "bad.zip", {"../escape": b"x"})

    def test_derived_native_files_require_reviewed_hash(self):
        for name in kit.DERIVED_DATA:
            self.assertTrue(kit.allowed(name))
            target = self.root / "derived" / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text('{"schema_version": 1}')
            with self.assertRaisesRegex(ValueError, "Unreviewed derived"):
                kit.validate_text(self.root / "derived", name)
        self.assertFalse(kit.allowed("client/assets/legacy_rules/unreviewed.json"))

    def test_rollback_and_client_version_marker_last(self):
        original_write = kit.S.atomic_write
        writes = []
        def fail_once(path, data, executable=False):
            if path.is_relative_to(self.base) and ".online-update-backups" not in path.parts:
                writes.append(path.relative_to(self.base).as_posix())
                if len(writes) == 3:
                    raise OSError("simulated disk full")
            original_write(path, data, executable)
        with mock.patch.object(kit.S, "atomic_write", side_effect=fail_once):
            with self.assertRaisesRegex(OSError, "disk full"):
                kit.apply_update(self.kit_path, self.base)
        for name, value in self.originals.items():
            self.assertEqual((self.base / name).read_bytes(), value)
        self.assertFalse((self.base / "client/scripts/new.gd").exists())
        self.assertNotIn("client/project.godot", writes)
        with mock.patch.object(kit.S, "atomic_write", wraps=original_write) as observed:
            kit.apply_update(self.kit_path, self.base)
        mutations = [call.args[0].relative_to(self.base).as_posix() for call in observed.call_args_list
                     if ".online-update-backups" not in call.args[0].parts]
        self.assertEqual(mutations[-1], "client/project.godot")

    def test_base_zip_pin_and_reproducible_archive(self):
        with self.assertRaisesRegex(ValueError, "ZIP SHA256 mismatch"):
            kit.base_and_overlay(self.archive, {}, "0" * 64)
        a, b = self.root / "a.zip", self.root / "b.zip"
        self.assertEqual(kit.write_archive(a, {"a.txt": b"same"})["sha256"],
                         kit.write_archive(b, {"a.txt": b"same"})["sha256"])

    def test_validation_gate_rejects_missing_failed_or_error_logs(self):
        report = self.base / "report.json"
        report.write_text(json.dumps({"release": "0.9.0", "results": []}))
        with self.assertRaisesRegex(ValueError, "nonempty"):
            kit.validation_gate(self.base, report)
        log = self.base / "tests.log"
        log.write_text("SCRIPT ERROR: synthetic\n")
        report.write_text(json.dumps({"release": "0.9.0", "results": [{"name": "test", "passed": True, "log": "tests.log"}]}))
        with self.assertRaisesRegex(ValueError, "Engine/script error"):
            kit.validation_gate(self.base, report)

    def test_new_static_table_collision_is_refused(self):
        table = self.base / "client/assets/native_server/ti_Monster.json"
        table.parent.mkdir()
        table.write_bytes(b"user file, do not overwrite")
        with self.assertRaisesRegex(ValueError, "conflicts"):
            kit.apply_update(self.kit_path, self.base)
        self.assertEqual(table.read_bytes(), b"user file, do not overwrite")
        self.assertEqual((self.base / "client/project.godot").read_bytes(), project("0.8.0"))

    def test_json_evidence_is_included_and_failure_is_rejected(self):
        report = self.base / "report.json"
        evidence = self.base / "runtime.json"
        evidence.write_text('{"passed": true, "checks": 40}')
        report.write_text(json.dumps({"release": "0.9.0", "results": [
            {"name": "runtime", "passed": True, "evidence": "runtime.json"}]}))
        approved, payload = kit.validation_gate(self.base, report)
        self.assertEqual(payload, {"runtime.json": evidence.read_bytes()})
        self.assertEqual(approved["logs"][0]["sha256"], kit.S.digest(evidence))
        evidence.write_text('{"passed": false}')
        with self.assertRaisesRegex(ValueError, "Failed validation evidence"):
            kit.validation_gate(self.base, report)

    def test_static_native_provenance_source_and_rows_are_checked(self):
        manifest = json.loads(self.overlay[kit.NATIVE_MANIFEST])
        manifest["exported"][0]["sha256"] = "0" * 64
        self.overlay[kit.NATIVE_MANIFEST] = kit.S.json_bytes(manifest)
        self.build_fixture()
        with self.assertRaisesRegex(ValueError, "provenance checksum"):
            kit.apply_update(self.kit_path, self.base)
        manifest["source"]["sha256"] = "0" * 64
        self.overlay[kit.NATIVE_MANIFEST] = kit.S.json_bytes(manifest)
        self.build_fixture()
        with self.assertRaisesRegex(ValueError, "not the reviewed backup hash"):
            kit.apply_update(self.kit_path, self.base)

    def test_native_tables_are_not_arbitrary_json_containers(self):
        name = "client/assets/native_server/ti_Monster.json"
        table = json.loads(self.overlay[name])
        table["rows"] = [[101, {"nested": "not a static SQL cell"}, "name"]]
        self.overlay[name] = kit.S.json_bytes(table)
        self.build_fixture()
        with self.assertRaisesRegex(ValueError, "Invalid static native table cell"):
            kit.apply_update(self.kit_path, self.base)


if __name__ == "__main__":
    unittest.main()
