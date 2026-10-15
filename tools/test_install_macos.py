#!/usr/bin/env python3
"""Offline checks: no download of the game and no native macOS claim."""
import hashlib
import json
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().with_name("install_macos.sh")
REPOSITORY = SCRIPT.parent.parent
APP_FIXTURE = SCRIPT.parent / "tests" / "fixtures" / "macos-installer" / "app-integrity.json"


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ace-installer-test-")
        self.folder = Path(self.temp.name)
        self.good = b"good"
        self.sha = hashlib.sha256(self.good).hexdigest()
        self.work = self.folder / "work"
        self.downloads = self.folder / "downloads"
        self.work.mkdir()
        self.downloads.mkdir()

    def tearDown(self):
        self.temp.cleanup()

    def shell(self, code):
        prelude = (
            f"source {shlex.quote(str(SCRIPT))}\n"
            f"WORK_DIR={shlex.quote(str(self.work))}\n"
            f"DOWNLOADS={shlex.quote(str(self.downloads))}\n"
            "PART_PATHS=()\nPART_COUNT=0\n"
        )
        return subprocess.run(
            ["bash", "-c", prelude + code], text=True, capture_output=True,
            timeout=10,
        )

    def test_syntax(self):
        result = subprocess.run(["bash", "-n", str(SCRIPT)], capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_linux_is_rejected_before_any_download(self):
        result = self.shell("uname() { printf 'Linux\\n'; }; curl() { printf 'UNEXPECTED_DOWNLOAD'; }; main")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Nenhum download foi iniciado", result.stderr)
        self.assertNotIn("UNEXPECTED_DOWNLOAD", result.stdout)

    def test_file_hash_size_and_symlink(self):
        payload = self.folder / "payload"
        payload.write_bytes(self.good)
        alias = self.folder / "alias"
        alias.symlink_to(payload)
        for path, sha, size, accepted in (
            (payload, self.sha, 4, True),
            (payload, "0" * 64, 4, False),
            (payload, self.sha, 5, False),
            (alias, self.sha, 4, False),
        ):
            with self.subTest(path=path.name, size=size, sha=sha):
                result = self.shell(f"verify_file {shlex.quote(str(path))} {sha} {size}")
                self.assertEqual(result.returncode == 0, accepted)

    def test_valid_download_is_reused_without_modification(self):
        existing = self.downloads / "part"
        existing.write_bytes(self.good)
        result = self.shell(
            "curl() { printf 'UNEXPECTED_DOWNLOAD'; return 9; }; "
            f"download_part part {self.sha} 4; "
            '[[ "$PART_COUNT" -eq 1 && "${PART_PATHS[0]}" == "$DOWNLOADS/part" ]]'
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("UNEXPECTED_DOWNLOAD", result.stdout)
        self.assertEqual(existing.read_bytes(), self.good)
        self.assertFalse((self.work / "part").exists())

    def test_wrong_download_stays_partial_and_is_never_promoted(self):
        result = self.shell(
            "curl() { local output=''; while [[ $# -gt 0 ]]; do "
            "if [[ $1 == --output ]]; then output=$2; shift; fi; shift; done; "
            "printf 'evil' > \"$output\"; }; "
            f"download_part part {self.sha} 4"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SHA-256 ou tamanho incorreto", result.stderr)
        self.assertEqual((self.work / "part.download").read_bytes(), b"evil")
        self.assertFalse((self.work / "part").exists())

    def test_corrupt_existing_dedicated_part_is_preserved(self):
        existing = self.work / "part"
        existing.write_bytes(b"evil")
        result = self.shell(
            "curl() { printf 'UNEXPECTED_DOWNLOAD'; return 9; }; "
            f"download_part part {self.sha} 4"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("UNEXPECTED_DOWNLOAD", result.stdout)
        self.assertEqual(existing.read_bytes(), b"evil")

    def test_partial_download_uses_continue_and_verifies_finished_result(self):
        partial = self.work / "part.download"
        partial.write_bytes(b"go")
        result = self.shell(
            "curl() { local output='' continuation=0; while [[ $# -gt 0 ]]; do "
            "case $1 in --output) output=$2; shift ;; --continue-at) [[ $2 == - ]] || return 8; continuation=1; shift ;; esac; "
            "shift; done; [[ $continuation -eq 1 ]] || return 9; printf 'od' >> \"$output\"; }; "
            f"download_part part {self.sha} 4"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(partial.exists())
        self.assertEqual((self.work / "part").read_bytes(), self.good)

    def make_staging(self):
        staging = self.folder / "staging"
        (staging / "ACE Modern.app").mkdir(parents=True)
        (staging / "ACE Modern.app" / "fixture").write_bytes(self.good)
        (staging / "LEIA-ME-ONLINE.txt").write_text("instructions")
        (staging / "third_party").mkdir()
        (staging / "third_party" / "license").write_text("license")
        return staging

    def test_publish_refuses_existing_directory_without_merging(self):
        staging = self.make_staging()
        destination = self.folder / "existing"
        destination.mkdir()
        (destination / "sentinel").write_text("keep")
        result = self.shell(f"publish_installation {shlex.quote(str(staging))} {shlex.quote(str(destination))}")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual([p.name for p in destination.iterdir()], ["sentinel"])
        self.assertTrue((staging / "ACE Modern.app" / "fixture").exists())

    def test_publish_preserves_guide_and_licenses(self):
        staging = self.make_staging()
        destination = self.folder / "new installation"
        result = self.shell(f"publish_installation {shlex.quote(str(staging))} {shlex.quote(str(destination))}")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((destination / "ACE Modern.app" / "fixture").read_bytes(), self.good)
        self.assertEqual((destination / "third_party" / "license").read_text(), "license")
        self.assertTrue((destination / "LEIA-ME-ONLINE.txt").exists())
        self.assertFalse(staging.exists())

    def test_pins_match_published_manifest_and_desktop_report(self):
        archive = json.loads((REPOSITORY / "verification" / "desktop-macos-zip-v08.json").read_text())
        release = json.loads((REPOSITORY / "verification" / "github-release-assets.json").read_text())
        app = json.loads(APP_FIXTURE.read_text())
        content = SCRIPT.read_text()
        self.assertIn(archive["sha256"], content)
        self.assertIn(str(archive["bytes"]), content)
        parts = [item for item in release["assets"] if item["name"].startswith("ace-modern-online-macos-v0.8.zip.part-")]
        self.assertEqual(len(parts), 3)
        for item in parts:
            self.assertIn(item["expected_sha256"], content)
            self.assertIn(str(item["expected_bytes"]), content)
        self.assertEqual(len(app["files"]), 7)
        for item in app["files"]:
            self.assertIn(item["sha256"], content)
            self.assertIn(str(item["bytes"]), content)


if __name__ == "__main__":
    unittest.main(verbosity=2)
