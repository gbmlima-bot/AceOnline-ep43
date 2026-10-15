#!/usr/bin/env python3
"""Malformed-input fixtures and independent checks of the actual GLB artifact."""
import importlib.util
import json
import math
from pathlib import Path
import struct
import sys
import unittest

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("terrain_convert", ROOT / "convert_original_terrain.py")
converter = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = converter
spec.loader.exec_module(converter)
ARTIFACTS = ROOT.parent / "client" / "assets" / "original_world"


def fixture_payload() -> bytes:
    # The central height deliberately breaks the other diagonal: exact visual
    # interpolation must return5 at the cellcenter, not zero or a bilinear2.5.
    vertices = [(x * 40.0, 10.0 if x == 1 and z == 1 else 0.0, z * 40.0, 0.0, 1.0, 0.0)
                for x in range(3) for z in range(3)]
    return b"\0" * 20 + struct.pack("<f3i", 40.0, 9, 4, 0) + b"".join(struct.pack("<6f", *v) for v in vertices) + b"\0" * 96


def fixture_resource(payload: bytes = b"data", trailing: bytes = b"") -> bytes:
    return struct.pack("<5i", 1000, 1000, len(payload), 1, 0) + struct.pack("<3i10s2s", 7, len(payload), 0, b"3002", b"\0\0") + payload + trailing


class MalformedAndTransformTests(unittest.TestCase):
    def test_resource_plain_header_and_payload_bounds(self):
        for value in (b"", b"\0" * 20, fixture_resource()[:30], fixture_resource()[:-1]):
            with self.subTest(value=value[:20]), self.assertRaises(converter.FormatError):
                converter.parse_resource(value)
        data = bytearray(fixture_resource())
        struct.pack_into("<i", data, 24, -1)
        with self.assertRaises(converter.FormatError):
            converter.parse_resource(bytes(data))

    def test_resource_count_duplicate_and_opaque_trailing(self):
        data = bytearray(fixture_resource())
        struct.pack_into("<i", data, 12, -1)
        with self.assertRaises(converter.FormatError):
            converter.parse_resource(bytes(data))
        data = bytearray(fixture_resource())
        struct.pack_into("<i", data, 12, 2)
        data.extend(data[20:])
        with self.assertRaises(converter.FormatError):
            converter.parse_resource(bytes(data))
        entries, manifest = converter.parse_resource(fixture_resource(trailing=b"opaque"))
        self.assertEqual(entries["3002"].data, b"data")
        self.assertEqual(manifest["opaque_trailing"]["size"], 6)
        self.assertEqual(manifest["opaque_trailing"]["sha256"], converter.sha256(b"opaque"))

    def test_terrain_count_truncation_and_extra_bytes(self):
        source = fixture_payload()
        for data in (source[:20], source[:-1], source + b"\0"):
            with self.assertRaises(converter.FormatError):
                converter.parse_terrain(data)
        data = bytearray(source)
        struct.pack_into("<i", data, 28, 5)
        with self.assertRaises(converter.FormatError):
            converter.parse_terrain(bytes(data))

    def test_terrain_rejects_nan_spacing_and_bad_normals(self):
        for offset, value in ((36, math.nan), (36, 1.0), (36 + 16, 0.0), (20, math.inf)):
            data = bytearray(fixture_payload())
            struct.pack_into("<f", data, offset, value)
            with self.subTest(offset=offset, value=value), self.assertRaises(converter.FormatError):
                converter.parse_terrain(bytes(data))

    def test_native_y_and_handedness_uv_contract(self):
        terrain = converter.parse_terrain(fixture_payload())
        positions, normals, uvs, indices = converter.surface_geometry(terrain, 0, 0, 2)
        self.assertEqual(positions[0], (-40.0, 0.0, 40.0))
        self.assertEqual(positions[4], (0.0, 10.0, 0.0))
        self.assertEqual(uvs[0], (0.0, 1.0))
        self.assertEqual(uvs[-1], (1.0, 0.0))
        self.assertEqual(normals[0], (0.0, 1.0, -0.0))
        self.assertEqual(len(indices), 24)
        a, b, c = (positions[i] for i in indices[:3])
        cross_y = (b[2] - a[2]) * (c[0] - a[0]) - (b[0] - a[0]) * (c[2] - a[2])
        self.assertGreater(cross_y, 0.0, "glTF CCW front faces point upward after reflection")

    def test_visual_diagonal_and_outside_query(self):
        terrain = converter.parse_terrain(fixture_payload())
        self.assertEqual(converter.sample_height(terrain, -20, 20), 5.0)
        self.assertEqual(converter.sample_height(terrain, -30, 10), 2.5)
        self.assertEqual(converter.sample_height(terrain, 40, -40), 0.0)
        with self.assertRaises(converter.FormatError):
            converter.sample_height(terrain, 41, 0)

    def test_jpeg_segment_rejects_invalid_truncated_headers(self):
        for data in (b"", b"\xff\xd8\xff\xd9", b"\xff\xd8\xff\xc0\x00\xff\xff\xd9"):
            with self.assertRaises(converter.FormatError):
                converter.jpeg_dimensions(data)

    def test_workspace_count_and_truncation(self):
        for data in (b"", b"\0" * 65, b"\0" * 64):
            with self.assertRaises(converter.FormatError):
                converter.parse_project(data, "3002")


class ExportedArtifactTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.metadata = json.loads((ARTIFACTS / "3002_terrain.json").read_text())
        cls.data = (ARTIFACTS / "3002_terrain.glb").read_bytes()
        magic, version, total = struct.unpack_from("<III", cls.data)
        if (magic, version, total) != (0x46546C67, 2, len(cls.data)):
            raise AssertionError("invalid GLB container header")
        n_json, kind = struct.unpack_from("<II", cls.data, 12)
        if kind != 0x4E4F534A:
            raise AssertionError("missing JSON chunk")
        cls.doc = json.loads(cls.data[20:20 + n_json])
        n_bin, kind = struct.unpack_from("<II", cls.data, 20 + n_json)
        cls.binary = cls.data[28 + n_json:]
        if kind != 0x004E4942 or n_bin != len(cls.binary):
            raise AssertionError("invalid BIN chunk")

    def accessor(self, index):
        a = self.doc["accessors"][index]
        view = self.doc["bufferViews"][a["bufferView"]]
        size = {"SCALAR": 1, "VEC2": 2, "VEC3": 3}[a["type"]]
        kind = {5123: "H", 5126: "f"}[a["componentType"]]
        offset = view["byteOffset"] + a.get("byteOffset", 0)
        return list(struct.iter_unpack("<" + kind * size, self.binary[offset:offset + a["count"] * size * (2 if kind == "H" else 4)]))

    def test_buffer_alignment_bounds_and_artifact_digest(self):
        self.assertEqual(converter.sha256(self.data), self.metadata["geometry"]["sha256"])
        for view in self.doc["bufferViews"]:
            self.assertEqual(view["byteOffset"] % 4, 0)
            self.assertGreater(view["byteLength"], 0)
            self.assertLessEqual(view["byteOffset"] + view["byteLength"], len(self.binary))
        self.assertEqual(self.doc["nodes"][0].keys(), {"name", "mesh"}, "transform must be baked; no hidden node scale")

    def test_every_embedded_jpeg_matches_its_original_entry(self):
        entries = self.metadata["source_resources"]["map"]["entries"]
        original = {e["name"]: e["sha256"] for e in entries}
        self.assertEqual(len(self.doc["images"]), 16)
        for image in self.doc["images"]:
            self.assertEqual(image["mimeType"], "image/jpeg")
            view = self.doc["bufferViews"][image["bufferView"]]
            data = self.binary[view["byteOffset"]:view["byteOffset"] + view["byteLength"]]
            self.assertEqual(converter.sha256(data), original[image["name"]])
            self.assertEqual(converter.jpeg_dimensions(data), (512, 512))

    def test_mesh_winding_normals_uvs_no_degenerate_faces_and_complete_extent(self):
        minimum, maximum = [math.inf] * 3, [-math.inf] * 3
        triangles = 0
        for primitive in self.doc["meshes"][0]["primitives"]:
            positions = self.accessor(primitive["attributes"]["POSITION"])
            normals = self.accessor(primitive["attributes"]["NORMAL"])
            uvs = self.accessor(primitive["attributes"]["TEXCOORD_0"])
            indices = [row[0] for row in self.accessor(primitive["indices"])]
            self.assertEqual(len(positions), 65 * 65)
            self.assertEqual(len(indices), 64 * 64 * 6)
            self.assertTrue(all(0 <= i < len(positions) for i in indices))
            self.assertTrue(all(math.isfinite(value) for row in positions for value in row))
            self.assertTrue(all(abs(sum(v * v for v in n) - 1.0) < 0.001 for n in normals))
            self.assertTrue(all(0.0 <= v <= 1.0 for uv in uvs for v in uv))
            self.assertEqual(uvs[0], (0.0, 1.0))
            self.assertEqual(uvs[-1], (1.0, 0.0))
            for p in positions:
                for axis in range(3):
                    minimum[axis] = min(minimum[axis], p[axis])
                    maximum[axis] = max(maximum[axis], p[axis])
            for i in range(0, len(indices), 3):
                a, b, c = (positions[j] for j in indices[i:i + 3])
                up = (b[2] - a[2]) * (c[0] - a[0]) - (b[0] - a[0]) * (c[2] - a[2])
                self.assertAlmostEqual(up, 40.0 * 40.0, msg="triangle projected area/winding differs")
            triangles += len(indices) // 3
        self.assertEqual(triangles, 131072)
        self.assertEqual([minimum, maximum], self.metadata["target_bounds"])

    def test_height_grid_exact_float_values_and_safe_training_route(self):
        raw = (ARTIFACTS / self.metadata["grid"]["heightmap"]).read_bytes()
        self.assertEqual(len(raw), 257 * 257 * 4)
        self.assertEqual(converter.sha256(raw), self.metadata["grid"]["heightmap_sha256"])
        self.assertEqual(struct.unpack_from("<f", raw, (128 * 257 + 128) * 4)[0], -160.0)
        for sample in self.metadata["training_route_height_samples"]:
            self.assertGreaterEqual(sample["clearance"], 265.0)
        self.assertEqual(self.metadata["project_environment"]["water_height"], -170.0)
        self.assertEqual(self.metadata["water"]["source_flag1_tile_count"], 5217)
        self.assertFalse(self.metadata["water"]["rendered_in_terrain_glb"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
