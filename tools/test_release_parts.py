"""Small temporary fixtures only; no approved archive or network is touched."""
import contextlib
import hashlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import zipfile

import release_parts as parts


class ReleasePartsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.source = self.root / "sample.zip"
        with zipfile.ZipFile(self.source, "w", zipfile.ZIP_STORED) as archive:
            archive.writestr("hello.txt", "Small release fixture\n")
            archive.writestr("data.bin", bytes(range(256)) * 27)
        self.original = self.source.read_bytes()
        self.output = self.root / "restored.zip"

    def tearDown(self):
        self.assertEqual(self.source.read_bytes(), self.original)
        self.temporary.cleanup()

    def split_fixture(self):
        return parts.split(self.source, self.root / "parts", 3000)

    def write_manifest(self, path, manifest):
        path.write_text(json.dumps(manifest), encoding="utf-8")

    def assert_failed_restore(self, path, message=None):
        with self.assertRaisesRegex((parts.PartsError, OSError), message or ".*"):
            parts.restore(path, self.output)
        self.assertFalse(self.output.exists())
        self.assertFalse(list(self.root.glob(".ace-release-restore-*")))

    def test_zip_round_trip_and_original_preservation(self):
        path, manifest = self.split_fixture()
        self.assertEqual(len(manifest["parts"]), 3)
        self.assertEqual(path.name, "sample.zip.parts.json")
        self.assertEqual([r["name"] for r in manifest["parts"]], ["sample.zip.part-001", "sample.zip.part-002", "sample.zip.part-003"])
        self.assertEqual([r["bytes"] for r in manifest["parts"]], [3000, 3000, len(self.original) - 6000])
        before = {p.name: p.read_bytes() for p in path.parent.iterdir()}
        result = parts.restore(path, self.output)
        self.assertEqual(self.output.read_bytes(), self.original)
        self.assertEqual(result["sha256"], hashlib.sha256(self.original).hexdigest())
        self.assertEqual(result["parts_verified"], 3)
        self.assertEqual({p.name: p.read_bytes() for p in path.parent.iterdir()}, before)
        with zipfile.ZipFile(self.output) as archive:
            self.assertEqual(archive.read("data.bin"), bytes(range(256)) * 27)
            self.assertIsNone(archive.testzip())

    def test_verify_reads_without_creating_archive(self):
        path, _ = self.split_fixture()
        result = parts.verify(path)
        self.assertEqual(result["sha256"], hashlib.sha256(self.original).hexdigest())
        self.assertFalse((path.parent / self.source.name).exists())

    def test_exact_multiple_does_not_add_empty_part(self):
        source = self.root / "boundary.zip"
        source.write_bytes(bytes(range(64)))
        path, manifest = parts.split(source, self.root / "boundary-parts", 32)
        self.assertEqual([r["bytes"] for r in manifest["parts"]], [32, 32])
        self.assertEqual(parts.restore(path)["bytes"], 64)
        self.assertEqual((path.parent / source.name).read_bytes(), source.read_bytes())

    def test_empty_input_is_one_empty_part(self):
        source = self.root / "empty.zip"
        source.write_bytes(b"")
        path, manifest = parts.split(source, self.root / "empty-parts", 7)
        self.assertEqual([r["bytes"] for r in manifest["parts"]], [0])
        self.assertEqual(parts.restore(path)["sha256"], hashlib.sha256(b"").hexdigest())
        self.assertEqual((path.parent / source.name).read_bytes(), b"")

    def test_modified_middle_part_is_rejected_without_partial_output(self):
        path, manifest = self.split_fixture()
        middle = path.parent / manifest["parts"][1]["name"]
        content = bytearray(middle.read_bytes())
        content[len(content) // 2] ^= 1
        middle.write_bytes(content)
        self.assert_failed_restore(path, "Part SHA256 mismatch")

    def test_truncated_part_is_rejected(self):
        path, manifest = self.split_fixture()
        middle = path.parent / manifest["parts"][1]["name"]
        middle.write_bytes(middle.read_bytes()[:-1])
        self.assert_failed_restore(path, "Part size mismatch")

    def test_appended_part_data_is_rejected(self):
        path, manifest = self.split_fixture()
        middle = path.parent / manifest["parts"][1]["name"]
        with middle.open("ab") as stream:
            stream.write(b"extra")
        self.assert_failed_restore(path, "Part size mismatch")

    def test_missing_part_is_rejected(self):
        path, manifest = self.split_fixture()
        (path.parent / manifest["parts"][1]["name"]).unlink()
        self.assert_failed_restore(path, "Missing/non-regular part")

    def test_final_hash_is_checked_after_valid_part_hashes(self):
        path, manifest = self.split_fixture()
        manifest["artifact"]["sha256"] = "0" * 64
        self.write_manifest(path, manifest)
        self.assert_failed_restore(path, "Final SHA256 mismatch")

    def test_reordered_parts_fail(self):
        path, manifest = self.split_fixture()
        manifest["parts"][0], manifest["parts"][1] = manifest["parts"][1], manifest["parts"][0]
        self.write_manifest(path, manifest)
        self.assert_failed_restore(path, "manifest order")

    def test_invalid_manifest_shapes_names_hashes_and_sizes_fail(self):
        path, manifest = self.split_fixture()
        original = json.dumps(manifest)
        variants = []
        for name in ("../escape", "/absolute", "C:\\escape", "NUL.zip", "COM¹.zip", "trailing."):
            bad = json.loads(original)
            bad["parts"][0]["name"] = name
            variants.append(bad)
        for field, value in (("version", 2), ("version", True), ("part_size_bytes", parts.MAX_PART_BYTES + 1), ("part_size_bytes", 0)):
            bad = json.loads(original)
            bad[field] = value
            variants.append(bad)
        bad = json.loads(original)
        bad["parts"][1]["name"] = bad["parts"][0]["name"].upper()
        variants.append(bad)
        bad = json.loads(original)
        bad["parts"][0]["bytes"] = -1
        variants.append(bad)
        bad = json.loads(original)
        bad["parts"][0]["sha256"] = "invalid"
        variants.append(bad)
        bad = json.loads(original)
        bad["artifact"]["bytes"] += 1
        variants.append(bad)
        variants.extend(([1, 2], None))
        for bad in variants:
            with self.subTest(manifest=bad):
                self.write_manifest(path, bad)
                self.assert_failed_restore(path)

    def test_duplicate_json_keys_are_rejected(self):
        path, _ = self.split_fixture()
        path.write_text('{"format":"ace-release-parts","format":"ignored"}', encoding="utf-8")
        self.assert_failed_restore(path, "Duplicate manifest key")

    def test_existing_destination_and_input_aliases_are_preserved(self):
        path, manifest = self.split_fixture()
        self.output.write_bytes(b"keep existing output")
        with self.assertRaises(parts.PartsError):
            parts.restore(path, self.output)
        self.assertEqual(self.output.read_bytes(), b"keep existing output")
        for target in (self.source, path, path.parent / manifest["parts"][0]["name"]):
            before = target.read_bytes()
            with self.assertRaises(parts.PartsError):
                parts.restore(path, target)
            self.assertEqual(target.read_bytes(), before)

    @unittest.skipIf(parts.os.name == "nt", "POSIX final publish uses exclusive hard-link creation")
    def test_concurrent_destination_is_not_overwritten(self):
        path, _ = self.split_fixture()
        link = parts.os.link
        def concurrent_create(temporary, destination):
            Path(destination).write_bytes(b"created concurrently")
            return link(temporary, destination)
        with mock.patch.object(parts.os, "link", concurrent_create):
            with self.assertRaises(FileExistsError):
                parts.restore(path, self.output)
        self.assertEqual(self.output.read_bytes(), b"created concurrently")
        self.assertFalse(list(self.root.glob(".ace-release-restore-*")))

    def test_existing_split_directory_is_untouched(self):
        directory = self.root / "parts"
        directory.mkdir()
        sentinel = directory / "keep.txt"
        sentinel.write_bytes(b"keep")
        with self.assertRaises(parts.PartsError):
            parts.split(self.source, directory, 3000)
        self.assertEqual(list(directory.iterdir()), [sentinel])
        self.assertEqual(sentinel.read_bytes(), b"keep")

    def test_hard_part_limit_enforced_without_creating_large_files(self):
        self.assertEqual(parts.MAX_PART_BYTES, 1_500_000_000)
        for invalid in (0, -1, True, 2_000_000_000):
            with self.subTest(size=invalid):
                with self.assertRaises(parts.PartsError):
                    parts.split(self.source, self.root / "parts", invalid)
                self.assertFalse((self.root / "parts").exists())

    def test_split_refuses_to_publish_manifest_larger_than_loader_limit(self):
        with mock.patch.object(parts, "MAX_MANIFEST_BYTES", 128):
            with self.assertRaisesRegex(parts.PartsError, "Manifest would be too large"):
                self.split_fixture()
        self.assertFalse((self.root / "parts").exists())

    def test_cli_split_verify_and_restore(self):
        directory = self.root / "cli-parts"
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertEqual(parts.main(["split", str(self.source), "--output-dir", str(directory), "--part-size", "3000"]), 0)
        result = json.loads(output.getvalue())
        path = Path(result["manifest"])
        self.assertEqual(result["manifest_sha256"], hashlib.sha256(path.read_bytes()).hexdigest())
        for argv in (["verify", str(path)], ["restore", str(path), "--output", str(self.output)]):
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(parts.main(argv), 0)
        self.assertEqual(self.output.read_bytes(), self.original)
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(parts.main(["restore", str(path), "--output", str(self.output)]), 1)


if __name__ == "__main__":
    unittest.main()
