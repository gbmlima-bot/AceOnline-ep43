#!/usr/bin/env python3
"""Small synthetic fixtures; never repack the real 4 GB source or final kit."""
from __future__ import annotations

import hashlib
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

SPEC = importlib.util.spec_from_file_location("kit", Path(__file__).with_name("package_online_kit.py"))
kit = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(kit)


def content_row(name, value):
    return {"path": name, "bytes": len(value), "sha256": hashlib.sha256(value).hexdigest()}


def project(version):
    return f'[application]\nconfig/name="ACE Modern"\nconfig/version="{version}"\n'.encode()


class KitTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.base = self.root / "base"
        self.base.mkdir()
        self.originals = {
            "client/project.godot": project("0.7.0"),
            "client/scripts/main.gd": b"extends Node\n# old\n",
            "client/assets/native.bin": b"\x00\x01keep native\xff",
            "README.md": b"Base README\n",
        }
        for name, data in self.originals.items():
            path = self.base / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        self.overlay = {
            "client/project.godot": project("0.8.0"),
            "client/scripts/main.gd": b"extends Node\n# online\n",
            "client/scripts/online/network.gd": b"extends RefCounted\n",
            "docs/ONLINE-PVE.md": b"Online instructions\n",
            "README.md": b"Updated README\n",
        }
        self.baseline = {"release": "0.7.0", "source_zip_sha256": "f" * 64,
                         "files": [content_row(n, v) for n, v in self.originals.items()]}
        self.kit_path = self.root / "kit"
        self.build_fixture()

    def tearDown(self):
        self.temp.cleanup()

    def fixture_payload(self):
        files = {"client-source-overlay/" + name: data for name, data in self.overlay.items()}
        files.update({
            "apply-update.py": Path(kit.__file__),
            "base-manifest.json": kit.json_bytes(self.baseline),
            "overlay-manifest.json": kit.json_bytes({"release": "0.8.0", "files": [content_row(n, v) for n, v in self.overlay.items()]}),
            "server-bundle/README.txt": b"Tiny test server fixture\n",
        })
        return files

    def build_fixture(self, files=None):
        archive = self.root / "fixture.zip"
        kit.write_archive(archive, files or self.fixture_payload(), force=True)
        if self.kit_path.exists():
            shutil.rmtree(self.kit_path)
        self.kit_path.mkdir()
        with zipfile.ZipFile(archive) as z:
            # Only our own known-safe fixture entries; production updater never extracts ZIPs.
            for item in z.infolist():
                name = item.filename.removeprefix(kit.KIT_DIR + "/")
                kit.safe_name(name)
                target = self.kit_path / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(z.read(item))

    def test_dry_run_changes_nothing(self):
        before = {str(p.relative_to(self.base)): p.read_bytes() for p in self.base.rglob("*") if p.is_file()}
        result = kit.apply_update(self.kit_path, self.base, dry_run=True)
        self.assertEqual(result["changed_files"], 5)
        self.assertEqual(before, {str(p.relative_to(self.base)): p.read_bytes() for p in self.base.rglob("*") if p.is_file()})
        self.assertFalse((self.base / ".online-update-backups").exists())

    def test_apply_preserves_assets_userdata_and_backs_up_source(self):
        (self.base / "userdata").mkdir()
        (self.base / "userdata/pilot.save").write_bytes(b"private local profile")
        result = kit.apply_update(self.kit_path, self.base)
        for name, data in self.overlay.items():
            self.assertEqual((self.base / name).read_bytes(), data)
        self.assertEqual((self.base / "client/assets/native.bin").read_bytes(), self.originals["client/assets/native.bin"])
        self.assertEqual((self.base / "userdata/pilot.save").read_bytes(), b"private local profile")
        backup = Path(result["source_backup"])
        self.assertEqual((backup / "client/project.godot").read_bytes(), project("0.7.0"))
        self.assertFalse((backup / "client/assets/native.bin").exists())
        self.assertTrue((backup / "update-receipt.json").is_file())
        self.assertTrue(kit.apply_update(self.kit_path, self.base)["already_applied"])

    def test_standalone_updater_cli(self):
        result = subprocess.run([sys.executable, str(self.kit_path / "apply-update.py"), "--base", str(self.base), "--dry-run"], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(json.loads(result.stdout)["dry_run"])

    def test_changed_base_refused_before_any_write(self):
        (self.base / "README.md").write_bytes(b"user edited")
        with self.assertRaisesRegex(ValueError, "Base file changed"):
            kit.apply_update(self.kit_path, self.base)
        self.assertEqual((self.base / "client/project.godot").read_bytes(), project("0.7.0"))
        self.assertFalse((self.base / ".online-update-backups").exists())

    def test_changed_native_asset_is_detected(self):
        (self.base / "client/assets/native.bin").write_bytes(b"corrupted")
        with self.assertRaisesRegex(ValueError, "Base file changed"):
            kit.apply_update(self.kit_path, self.base)

    def test_missing_base_file(self):
        (self.base / "README.md").unlink()
        with self.assertRaisesRegex(ValueError, "Base file changed"):
            kit.apply_update(self.kit_path, self.base)

    def test_new_source_collision(self):
        (self.base / "docs").mkdir()
        (self.base / "docs/ONLINE-PVE.md").write_text("my existing file")
        with self.assertRaisesRegex(ValueError, "conflicts"):
            kit.apply_update(self.kit_path, self.base)

    def test_corrupt_overlay_and_unexpected_payload(self):
        (self.kit_path / "client-source-overlay/README.md").write_bytes(b"tamper")
        with self.assertRaisesRegex(ValueError, "checksum"):
            kit.apply_update(self.kit_path, self.base)
        self.build_fixture()
        (self.kit_path / "unexpected.txt").write_text("unknown")
        with self.assertRaisesRegex(ValueError, "unexpected"):
            kit.apply_update(self.kit_path, self.base)

    def test_optional_base_zip_hash(self):
        archive = self.root / "original.zip"
        archive.write_bytes(b"tiny original")
        self.baseline["source_zip_sha256"] = kit.digest(archive)
        self.build_fixture()
        self.assertTrue(kit.apply_update(self.kit_path, self.base, True, archive)["dry_run"])
        archive.write_bytes(b"different")
        with self.assertRaisesRegex(ValueError, "ZIP SHA256"):
            kit.apply_update(self.kit_path, self.base, True, archive)

    def test_paths_and_case_collision(self):
        for name in ("../escape", "/absolute", "a/../../b", "a//b", "C:/escape", "a\\b", "a/./b", "a/space "):
            with self.subTest(name=name), self.assertRaises(ValueError):
                kit.safe_name(name)
        with self.assertRaisesRegex(ValueError, "case-colliding"):
            kit.rows_index([content_row("client/A.gd", b"a"), content_row("client/a.gd", b"b")])

    def test_traversal_manifest_never_writes(self):
        self.overlay["../outside.gd"] = b"escape"
        files = self.fixture_payload()
        # Unsafe source path is rejected already by the archive builder.
        with self.assertRaises(ValueError):
            kit.write_archive(self.root / "unsafe.zip", files)
        self.assertFalse((self.root / "outside.gd").exists())

    def test_symlink_destination_and_payload_refused(self):
        outside = self.root / "outside"
        outside.mkdir()
        (self.base / "docs").symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symlink"):
            kit.apply_update(self.kit_path, self.base)
        self.assertEqual(list(outside.iterdir()), [])
        (self.base / "docs").unlink()
        real = self.kit_path / "client-source-overlay/README.md"
        data = real.read_bytes()
        real.unlink()
        external = self.root / "external.txt"
        external.write_bytes(data)
        real.symlink_to(external)
        with self.assertRaisesRegex(ValueError, "Symlink"):
            kit.apply_update(self.kit_path, self.base)

    def test_binary_overlay_even_with_valid_manifest_refused(self):
        self.overlay["client/scripts/evil.gd"] = b"\x00binary"
        self.build_fixture()
        with self.assertRaisesRegex(ValueError, "Binary"):
            kit.apply_update(self.kit_path, self.base)

    def test_non_source_overlay_refused(self):
        self.overlay["client/assets/native.bin"] = b"replace"
        self.build_fixture()
        with self.assertRaisesRegex(ValueError, "Non-source"):
            kit.apply_update(self.kit_path, self.base)

    def test_rollback_and_version_marker_last(self):
        real_write = kit.atomic_write
        changed_writes = []
        def fail_once(path, data, executable=False):
            if path.is_relative_to(self.base) and ".online-update-backups" not in path.parts:
                changed_writes.append(path.relative_to(self.base).as_posix())
                if len(changed_writes) == 3:
                    raise OSError("simulated disk failure")
            real_write(path, data, executable)
        with mock.patch.object(kit, "atomic_write", side_effect=fail_once):
            with self.assertRaisesRegex(OSError, "disk failure"):
                kit.apply_update(self.kit_path, self.base)
        for name, data in self.originals.items():
            self.assertEqual((self.base / name).read_bytes(), data)
        self.assertFalse((self.base / "client/scripts/online/network.gd").exists())
        self.assertNotIn("client/project.godot", changed_writes)
        self.assertEqual(list(self.base.rglob(".ace-update-*")), [])
        with mock.patch.object(kit, "atomic_write", wraps=real_write) as patched:
            kit.apply_update(self.kit_path, self.base)
        writes = [c.args[0].relative_to(self.base).as_posix() for c in patched.call_args_list
                  if ".online-update-backups" not in c.args[0].parts]
        self.assertEqual(writes[-1], "client/project.godot")

    def test_deterministic_archive_and_overwrite_guard(self):
        files = self.fixture_payload()
        a, b = self.root / "a.zip", self.root / "b.zip"
        kit.write_archive(a, files)
        kit.write_archive(b, files)
        self.assertEqual(kit.digest(a), kit.digest(b))
        with self.assertRaisesRegex(ValueError, "already exists"):
            kit.write_archive(a, files)

    def test_base_manifest_from_small_archived_fixture(self):
        source = self.root / "source.zip"
        raw = kit.json_bytes({"version": "0.7.0", "files": self.baseline["files"]})
        with zipfile.ZipFile(source, "w") as z:
            for name, data in self.originals.items():
                z.writestr("ace-modern/" + name, data)
            z.writestr("ace-modern/reports/artifacts.json", raw)
        baseline = kit.base_manifest(source, kit.digest(source))
        self.assertEqual(baseline["release"], "0.7.0")
        self.assertEqual(len(baseline["files"]), 5)
        with self.assertRaisesRegex(ValueError, "SHA256"):
            kit.base_manifest(source, "0" * 64)

    def test_package_ships_only_approved_evidence_with_matching_hashes(self):
        source = self.root / "package-source"
        fixture = {"client/project.godot": project("0.8.0"), "docs/ONLINE-PVE.md": b"instructions",
                   "README.md": b"read", "README.txt": b"read",
                   "reports/smoke.json": kit.json_bytes({"passed": True, "checks": 27}),
                   "reports/tests.log": b"PASS 22 tests\n", "reports/not-approved.log": b"excluded"}
        for name, data in fixture.items():
            path = source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        report = {"release": "0.8.0", "results": [
            {"name": "smoke", "passed": True, "log": "reports/smoke.json"},
            {"name": "unit", "passed": True, "log": "reports/tests.log"}]}
        validation = source / "reports/validation.json"
        validation.write_bytes(kit.json_bytes(report))
        server_file = self.root / "server-fixture.txt"
        server_file.write_bytes(b"fixture server")
        output = self.root / "package.zip"
        with mock.patch.object(kit, "base_manifest", return_value=self.baseline), mock.patch.object(kit, "bundle_files", return_value={"README.txt": server_file}):
            kit.package(source, self.root / "bundle", self.root / "base.zip", validation, output)
        with zipfile.ZipFile(output) as zipped:
            prefix = kit.KIT_DIR + "/"
            evidence = json.loads(zipped.read(prefix + "validation.json"))
            manifest = json.loads(zipped.read(prefix + "kit-manifest.json"))
            rows = {r["path"]: r for r in manifest["files"]}
            for row in evidence["logs"]:
                data = zipped.read(prefix + row["path"])
                self.assertEqual(hashlib.sha256(data).hexdigest(), row["sha256"])
                self.assertEqual(len(data), row["bytes"])
                self.assertEqual(rows[row["path"]]["sha256"], row["sha256"])
                self.assertNotIn(prefix + "client-source-overlay/" + row["path"], zipped.namelist())
            self.assertNotIn(prefix + "reports/not-approved.log", zipped.namelist())
            self.assertEqual(zipped.testzip(), None)

    def test_validation_gate_failed_missing_or_dirty_logs(self):
        report = self.root / "validation.json"
        log = self.root / "test.log"
        log.write_text("PASS 27 checks\n")
        def save(results, release="0.8.0"):
            report.write_bytes(kit.json_bytes({"release": release, "results": results}))
        save([{"name": "integration", "passed": True, "log": "test.log"}])
        self.assertEqual(len(kit.validation_gate(self.root, report)["logs"]), 1)
        for bad in ("SCRIPT ERROR: broken", "ERROR: engine", "Godot\n  ERROR: missing", "Parse Error: syntax"):
            log.write_text(bad)
            with self.subTest(log=bad), self.assertRaisesRegex(ValueError, "error"):
                kit.validation_gate(self.root, report)
        log.write_text("PASS\n")
        for results in ([], [{"name": "bad", "passed": False}], [{"name": "bad", "passed": 1}]):
            save(results)
            with self.assertRaises(ValueError):
                kit.validation_gate(self.root, report)
        save([{"name": "ok", "passed": True}], "0.7.0")
        with self.assertRaises(ValueError):
            kit.validation_gate(self.root, report)

    def test_updated_source_rebuilds_standalone_application_whitelist(self):
        spec = importlib.util.spec_from_file_location("server_builder", Path(kit.__file__).with_name("build_server_bundle.py"))
        builder = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(builder)
        # The original art/numerical files stay in the synthetic v0.7 base.
        for name in builder.DATA_FILES + builder.WORLD_FILES:
            relative = "client/" + name
            value = b"\x00native numerical data" if Path(name).suffix != ".json" else b"{}\n"
            self.originals[relative] = value
        for name in builder.CORE_SCRIPTS:
            self.originals["client/scripts/" + name] = b"extends RefCounted\n"
        for name in builder.ONLINE_SCRIPTS:
            self.overlay["client/scripts/online/" + name] = b"extends RefCounted\n"
        for name in ("project.godot", "main.gd", "admin.gd", "server.tscn"):
            self.overlay["server/" + name] = b"server source fixture\n"
        self.overlay["tools/build_server_bundle.py"] = Path(builder.__file__).read_bytes()
        for name in kit.DEPLOY_TOP:
            self.overlay["deploy/" + name] = b"deployment config fixture\n"
        self.overlay["deploy/scripts/start.sh"] = b"#!/bin/sh\nexec godot --headless\n"
        for name in kit.SQLITE_TEXT:
            self.overlay[name] = b"native addon text fixture\n"
        for name in kit.SQLITE_NATIVE:
            self.overlay[name] = b"\x7fELF\x00fake verified native sqlite extension\xff"
        addon_rows = [content_row(name, self.overlay[name]) for name in sorted(kit.SQLITE_NATIVE | kit.SQLITE_TEXT)]
        self.overlay["third_party/GODOT-SQLITE.json"] = kit.json_bytes({"files": addon_rows})
        for name, data in self.originals.items():
            path = self.base / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        self.baseline["files"] = [content_row(n, v) for n, v in self.originals.items()]
        self.build_fixture()
        kit.apply_update(self.kit_path, self.base)
        # Execute the actual updated-source builder, rather than a reimplementation.
        result = subprocess.run([sys.executable, str(self.base / "tools/build_server_bundle.py"), "--source", str(self.base),
                                 "--output", str(self.root / "rebuilt-app"), "--app-only"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(json.loads(result.stdout)["ok"])
        app = builder.application_files(self.base)
        self.assertIn("project.godot", app)
        self.assertIn("scripts/online/headless_world.gd", app)
        self.assertTrue((self.base / "deploy/scripts/start.sh").is_file())
        self.assertTrue((self.base / "deploy/.env.example").is_file())
        for name in kit.SQLITE_NATIVE:
            self.assertEqual((self.base / name).read_bytes(), self.overlay[name])
        self.assertEqual((self.base / "client/assets/native.bin").read_bytes(), self.originals["client/assets/native.bin"])

    def test_native_library_requires_complete_matching_provenance(self):
        native = sorted(kit.SQLITE_NATIVE)[0]
        self.overlay[native] = b"\x7fELF\x00verified only with provenance"
        self.build_fixture()
        with self.assertRaisesRegex(ValueError, "incomplete or lacks provenance"):
            kit.apply_update(self.kit_path, self.base)
        for name in kit.SQLITE_NATIVE | kit.SQLITE_TEXT:
            self.overlay[name] = b"native\x00" if name in kit.SQLITE_NATIVE else b"text"
        rows = [content_row(n, self.overlay[n]) for n in sorted(kit.SQLITE_NATIVE | kit.SQLITE_TEXT)]
        rows[0]["sha256"] = "0" * 64
        self.overlay["third_party/GODOT-SQLITE.json"] = kit.json_bytes({"files": rows})
        self.build_fixture()
        with self.assertRaisesRegex(ValueError, "provenance mismatch"):
            kit.apply_update(self.kit_path, self.base)
        self.assertFalse((self.base / "server").exists())

    def test_deploy_private_files_and_unreviewed_binary_are_forbidden(self):
        for name in ("deploy/.env", "deploy/backups/private.sqlite", "server/private.so", "server/addons/godot-sqlite/bin/unreviewed.so",
                     "deploy/scripts/__pycache__/private.py", "server/.godot/editor/private.gd"):
            with self.subTest(name=name):
                self.assertIsNone(kit.overlay_kind(name))
                self.overlay[name] = b"private data"
                self.build_fixture()
                with self.assertRaisesRegex(ValueError, "Non-source"):
                    kit.apply_update(self.kit_path, self.base)
                del self.overlay[name]
        self.assertFalse((self.base / "server").exists())

    def test_overlay_selection_excludes_caches_art_and_historical_html(self):
        src = self.root / "source"
        files = {"client/project.godot": project("0.8.0"), "client/scripts/a.gd": b"extends Node\n",
                 "client/material.tres": b"[gd_resource]\n", "client/shader.gdshader": b"shader_type spatial;\n",
                 "client/.godot/editor/cache.gd": b"private", "client/assets/art.png": b"\xffimage",
                 "docs/read.md": b"docs", "docs/proof.json": b"{}", "docs/old.html": b"embedded images",
                 "tools/check.py": b"print('check')\n", "tools/__pycache__/bad.py": b"cache",
                 "README.md": b"read", "README.txt": b"read",
                 "server/project.godot": b"server fixture", "server/main.gd": b"extends Node\n",
                 "deploy/scripts/start.sh": b"#!/bin/sh\n", "deploy/Dockerfile": b"FROM fixture\n",
                 "deploy/.env": b"SECRET=private", "deploy/backups/private.sqlite": b"private",
                 "server/.godot/editor/private.gd": b"private"}
        for name, data in files.items():
            path = src / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        selected = kit.overlay_files(src)
        self.assertIn("client/material.tres", selected)
        self.assertIn("client/shader.gdshader", selected)
        self.assertNotIn("client/assets/art.png", selected)
        self.assertNotIn("client/.godot/editor/cache.gd", selected)
        self.assertNotIn("docs/old.html", selected)
        self.assertNotIn("tools/__pycache__/bad.py", selected)
        self.assertIn("server/project.godot", selected)
        self.assertIn("deploy/scripts/start.sh", selected)
        self.assertIn("deploy/Dockerfile", selected)
        self.assertNotIn("deploy/.env", selected)
        self.assertNotIn("deploy/backups/private.sqlite", selected)
        self.assertNotIn("server/.godot/editor/private.gd", selected)


if __name__ == "__main__":
    unittest.main()
