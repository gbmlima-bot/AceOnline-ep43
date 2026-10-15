#!/usr/bin/env python3
"""Verify scenery placement conjugation, source evidence and derived materials."""
import hashlib
import io
import json
from pathlib import Path
import struct
import unittest

import numpy as np
from PIL import Image
import convert_original_props as props

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "client/assets/original_props"


def decode_glb(path):
    data = path.read_bytes()
    assert struct.unpack_from("<III", data) == (0x46546C67, 2, len(data))
    length, kind = struct.unpack_from("<II", data, 12)
    assert kind == 0x4E4F534A
    doc = json.loads(data[20:20 + length])
    binary_length, kind = struct.unpack_from("<II", data, 20 + length)
    assert kind == 0x004E4942
    binary = data[28 + length:]
    assert len(binary) == binary_length
    return data, doc, binary


def native_world_by_view_inverse(position, direction, up):
    # Construct D3DX's row-vector view matrix independently, then invert it.
    position, direction, up = (np.array(x, dtype=float) for x in (position, direction, up))
    forward = direction / np.linalg.norm(direction)
    right = np.cross(up, forward)
    right /= np.linalg.norm(right)
    corrected_up = np.cross(forward, right)
    view = np.eye(4)
    view[:3, :3] = np.column_stack((right, corrected_up, forward))
    view[3, :3] = [-np.dot(right, position), -np.dot(corrected_up, position), -np.dot(forward, position)]
    return np.linalg.inv(view).T


class PoseTests(unittest.TestCase):
    def test_known_nonaxial_pose_and_no_ship_heading(self):
        basis, origin = props.original_pose((10, 20, 30), (1, 0, 1), (0, 3, 0))
        root_half = 1 / np.sqrt(2)
        self.assertTrue(np.allclose(basis, [[root_half, 0, -root_half], [0, 1, 0], [root_half, 0, root_half]]))
        self.assertTrue(np.array_equal(origin, [-5110, 20, 5090]))
        identity, _ = props.original_pose((0, 0, 0), (0, 0, 3), (0, 2, 0))
        self.assertTrue(np.allclose(identity, np.eye(3)), "no Y180 heading may be added to scenery")

    def test_invalid_pose_vectors_and_unknown_dataset_rejected(self):
        for direction, up in [((0, 0, 0), (0, 1, 0)), ((0, 1, 0), (0, 2, 0)), ((float("nan"), 0, 1), (0, 1, 0))]:
            with self.assertRaises(props.FormatError):
                props.original_pose((0, 0, 0), direction, up)
        with self.assertRaises(props.FormatError):
            props.read_object_metadata(b"not the pinned OMI")
        with self.assertRaises(props.FormatError):
            props.read_placements(b"not the pinned terrain")


class ArtifactTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.layout = json.loads((ASSETS / "placements.json").read_text())
        cls.manifest = json.loads((ASSETS / "manifest.json").read_text())

    def test_all911_poses_match_source_lookat_conjugation(self):
        seen, count = set(), 0
        reflected_local = np.array([10, 20, -30, 1.0])
        native_local = np.array([10, 20, 30, 1.0])
        reflection = np.diag([1, 1, -1, 1])
        for model in self.layout["models"]:
            self.assertIn(model["source_mapobjectinfo"]["alpha"], (0, 1))
            for record in model["placements"]:
                self.assertNotIn(record["source_record_index"], seen)
                seen.add(record["source_record_index"])
                values = record["transform_columns"]
                matrix = np.eye(4)
                matrix[:3, :3] = np.array(values[:9]).reshape(3, 3).T
                matrix[:3, 3] = values[9:]
                native = native_world_by_view_inverse(record["source_position"], record["source_direction"], record["source_up"])
                expected = reflection @ native @ native_local
                expected[:3] += [-5120, 0, 5120]
                self.assertTrue(np.allclose(matrix @ reflected_local, expected, atol=1e-7))
                self.assertTrue(np.allclose(matrix[:3, :3].T @ matrix[:3, :3], np.eye(3), atol=1e-7))
                self.assertAlmostEqual(np.linalg.det(matrix[:3, :3]), 1.0)
                self.assertEqual(record["body_condition_mask"], 4)
                count += 1
        self.assertEqual(count, 911)
        self.assertEqual(len(self.layout["models"]), 31)
        self.assertEqual(self.manifest["instance_count"], count)

    def test_exact_source_alpha_evidence_and_placements_hash(self):
        self.assertEqual(props.sha256((ASSETS / "placements.json").read_bytes()), self.manifest["placements_sha256"])
        for model in self.layout["models"]:
            row = model["source_mapobjectinfo"]
            raw = bytes.fromhex(row["source_record_hex"])
            code, alpha, collision, server_collision, render_type, render_index = struct.unpack("<i4BH2x", raw)
            self.assertEqual(code, model["code"])
            self.assertEqual((alpha, collision, server_collision, render_type, render_index),
                             tuple(row[key] for key in ("alpha", "collision", "server_collision", "render_type", "render_index")))
            self.assertEqual(props.sha256(raw), row["source_record_sha256"])
            self.assertEqual(row["source_sha256"], props.OMI_SHA)
        self.assertEqual(self.layout["alpha_pipeline"]["reference_uint8"], 127)

    def test_glb_geometry_alpha_and_original_pixels(self):
        report_by_id = {r["model_id"]: r for r in self.manifest["models"]}
        for model in self.layout["models"]:
            data, doc, binary = decode_glb(ASSETS / model["filename"])
            report = report_by_id[Path(model["filename"]).stem]
            self.assertEqual(hashlib.sha256(data).hexdigest(), model["sha256"])
            self.assertIn(report["source_animation_count"], (0, 1))
            self.assertEqual(report["exported_animation_count"], 0)
            self.assertEqual(report["source_bone_count"], 0)
            self.assertEqual(report["triangles"], sum(doc["accessors"][p["indices"]]["count"] // 3 for mesh in doc["meshes"] for p in mesh["primitives"]))
            alpha = model["source_mapobjectinfo"]["alpha"]
            self.assertEqual(report["material_profile"]["source_selected_mapobjectinfo_alpha"], alpha)
            for material in doc["materials"]:
                self.assertEqual(material["alphaMode"], "BLEND" if alpha else "OPAQUE")
                self.assertFalse(material["doubleSided"])
                self.assertNotIn("KHR_materials_unlit", material.get("extensions", {}))
            for image, texture in zip(doc["images"], report["textures"]):
                view = doc["bufferViews"][image["bufferView"]]
                pixels = binary[view["byteOffset"]:view["byteOffset"] + view["byteLength"]]
                self.assertEqual(props.sha256(pixels), texture["embedded_sha256"])
                with Image.open(io.BytesIO(pixels)) as decoded:
                    rgba = np.array(decoded.convert("RGBA"))
                self.assertEqual(props.sha256(rgba.tobytes()), texture["decoded_rgba_sha256"])
                self.assertEqual((int(rgba[:, :, 3].min()), int(rgba[:, :, 3].max())), (texture["alpha_min"], texture["alpha_max"]))
        self.assertEqual(sum(r["triangles"] for r in report_by_id.values()), 11065)

    def test_original_frame_scales_preserved(self):
        expected = {"03002200": 1.0, "03002300": 0.4, "03002400": 0.6}
        for report in self.manifest["models"]:
            self.assertEqual(report["conversion_profile"], "scenery")
            for mesh in report["meshes"]:
                matrix = np.array(mesh["source_world_matrix_baked"])
                self.assertTrue(np.isfinite(matrix).all())
                self.assertGreater(abs(np.linalg.det(matrix[:3, :3])), 1e-10)
            if report["model_id"] in expected:
                self.assertEqual(len(report["meshes"]), 1)
                singular = np.linalg.svd(matrix[:3, :3], compute_uv=False)
                self.assertTrue(np.allclose(singular, expected[report["model_id"]], atol=1e-6))


if __name__ == "__main__":
    unittest.main(verbosity=2)
