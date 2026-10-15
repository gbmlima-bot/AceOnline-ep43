"""Synthetic metadata fixtures only; no release, real installer or app is generated."""
import copy
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

import generate_macos_installer as generator


class MacInstallerGenerationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="ace-macos-generator-test-")
        self.root = Path(self.temporary.name)
        self.historical = generator.TEMPLATE.read_bytes()
        tree = [{"path": path, "bytes": index + 1,
                 "sha256": hashlib.sha256(("synthetic-test-only:" + path).encode()).hexdigest(),
                 "mode": 0o755 if "/MacOS/" in path else 0o644}
                for index, path in enumerate(generator.APP_PATHS)]
        tree_sha = hashlib.sha256(json.dumps(tree, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
        base = {"platform": "macos", "architectures": ["arm64", "x86_64"], "native_executed": False,
                "executable_permission": True, "plist_version": "0.9.0", "pck": {"application_version": "0.9.0"}}
        self.desktop = dict(base, artifact_kind="app_directory", release="0.9.0", verified=True,
                            tree=tree, bytes=sum(row["bytes"] for row in tree), sha256=tree_sha)
        self.zip = dict(base, zip_crc_all_members=True, bytes=9, sha256=hashlib.sha256(b"test-only").hexdigest())
        self.manifest = {"format": "ace-release-parts", "version": 1, "part_size_bytes": 4,
                         "artifact": {"name": generator.ZIP_NAME, "bytes": self.zip["bytes"], "sha256": self.zip["sha256"]},
                         "parts": [{"index": index, "name": generator.ZIP_NAME + ".part-" + str(index).zfill(3),
                                    "bytes": size, "sha256": hashlib.sha256(bytes([index]) * size).hexdigest()}
                                   for index, size in enumerate([4, 4, 1], 1)]}
        self.desktop_path = self.root / "desktop-report.json"
        self.zip_path = self.root / "zip-report.json"
        self.parts_path = self.root / "parts.json"
        self.output = self.root / "synthetic-installer.sh"

    def tearDown(self):
        self.assertEqual(generator.TEMPLATE.read_bytes(), self.historical)
        self.temporary.cleanup()

    def generate(self):
        for path, value in ((self.desktop_path, self.desktop), (self.zip_path, self.zip), (self.parts_path, self.manifest)):
            path.write_text(json.dumps(value), encoding="utf-8")
        return generator.generate(self.desktop_path, self.zip_path, self.parts_path, self.output)

    def test_exact_pins_paths_syntax_and_no_native_claim(self):
        report = self.generate()
        text = self.output.read_text()
        self.assertEqual(subprocess.run(["bash", "-n", str(self.output)], capture_output=True).returncode, 0)
        self.assertIn(generator.RELEASE_URL, text)
        self.assertIn('WORK_DIR="$DOWNLOADS/ACE-Modern-v0.9-macos"', text)
        self.assertIn('DESTINATION="$INSTALL_ROOT/ACE Modern 0.9"', text)
        self.assertNotIn("0.8", text)
        self.assertIn(self.zip["sha256"], text)
        for row in self.manifest["parts"] + self.desktop["tree"]:
            self.assertIn(row["sha256"], text)
        self.assertIn("execução nativa ainda precisa ser confirmada", text)
        self.assertFalse(report["native_executed"])
        self.assertFalse(report["published"])
        self.assertEqual(report["app_files"], 7)
        self.assertEqual(report["parts"], 3)
        self.assertEqual(report["sha256"], hashlib.sha256(self.output.read_bytes()).hexdigest())

    def test_metadata_inconsistencies_leave_no_output(self):
        originals = [copy.deepcopy(value) for value in (self.desktop, self.zip, self.manifest)]
        corruptions = [
            (0, lambda row: row.update(verified=False)),
            (0, lambda row: row.update(release="0.8.0")),
            (0, lambda row: row.update(native_executed=True)),
            (0, lambda row: row.update(architectures=["arm64"])),
            (0, lambda row: row.update(bytes=row["bytes"] + 1)),
            (0, lambda row: row.update(sha256="a" * 64)),
            (0, lambda row: row["tree"].append(dict(row["tree"][0]))),
            (0, lambda row: row["tree"][0].update(path="../outside")),
            (1, lambda row: row.update(zip_crc_all_members=False)),
            (1, lambda row: row.update(plist_version="0.8.0")),
            (1, lambda row: row.update(pck={"application_version": "0.9.0", "changed": True})),
            (1, lambda row: row.update(sha256="b" * 64)),
            (2, lambda row: row["artifact"].update(name="other.zip")),
            (2, lambda row: row["parts"][0].update(bytes=3)),
            (2, lambda row: row["parts"][0].update(sha256="$(malicious)")),
            (2, lambda row: row["parts"][0].update(name="unexpected.part-001")),
        ]
        for index, corrupt in corruptions:
            with self.subTest(index=index, corrupt=corrupt):
                self.desktop, self.zip, self.manifest = copy.deepcopy(originals)
                corrupt((self.desktop, self.zip, self.manifest)[index])
                with self.assertRaises((generator.InstallerError, generator.release_parts.PartsError)):
                    self.generate()
                self.assertFalse(self.output.exists())

    def test_existing_or_symlink_output_is_preserved(self):
        self.output.write_text("preserve current installer")
        with self.assertRaises(generator.InstallerError):
            self.generate()
        self.assertEqual(self.output.read_text(), "preserve current installer")
        self.output.unlink()
        self.output.symlink_to(self.root / "missing")
        with self.assertRaises(generator.InstallerError):
            self.generate()
        self.assertTrue(self.output.is_symlink())
        self.assertFalse((self.root / "missing").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
