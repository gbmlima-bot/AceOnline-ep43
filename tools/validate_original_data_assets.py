#!/usr/bin/env python3
"""Independently validate exported data assets without loading original code."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import struct
import numpy as np
from PIL import Image


def sha(data): return hashlib.sha256(data).hexdigest()


def validate_glb(path):
    b = path.read_bytes()
    assert b[:4] == b"glTF" and struct.unpack_from("<II", b, 4) == (2, len(b))
    length = struct.unpack_from("<I", b, 12)[0]
    assert b[16:20] == b"JSON" and b[24 + length:28 + length] == b"BIN\0"
    d = json.loads(b[20:20 + length]); binary = memoryview(b)[28 + length:]
    assert not any("uri" in x for x in d.get("buffers", []) + d.get("images", []))
    arrays = []
    for a in d["accessors"]:
        v = d["bufferViews"][a["bufferView"]]
        offset = v.get("byteOffset", 0) + a.get("byteOffset", 0)
        width = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}[a["type"]]
        dtype = {5126: "<f4", 5125: "<u4", 5123: "<u2", 5121: "u1"}[a["componentType"]]
        assert "byteStride" not in v, "Unexpected interleaved profile"
        itemsize = np.dtype(dtype).itemsize
        assert offset + a["count"] * width * itemsize <= v.get("byteOffset", 0) + v["byteLength"] <= len(binary)
        array = np.frombuffer(binary, dtype=dtype, count=a["count"] * width, offset=offset).reshape((-1, width))
        assert np.isfinite(array).all()
        arrays.append(array)
    triangles = 0; maximum_normal_error = 0
    for mesh in d["meshes"]:
        for p in mesh["primitives"]:
            pos = arrays[p["attributes"]["POSITION"]]; index = arrays[p["indices"]].reshape(-1)
            assert index.max() < len(pos) and len(index) % 3 == 0
            triangles += len(index) // 3
            if "NORMAL" in p["attributes"]:
                error = float(abs(np.linalg.norm(arrays[p["attributes"]["NORMAL"]], axis=1) - 1).max())
                maximum_normal_error = max(maximum_normal_error, error); assert error < .025
            if "WEIGHTS_0" in p["attributes"]:
                assert float(abs(arrays[p["attributes"]["WEIGHTS_0"]].sum(axis=1) - 1).max()) < .001
                assert arrays[p["attributes"]["JOINTS_0"]].max() < max(len(s["joints"]) for s in d["skins"])
    images = []
    for image in d.get("images", []):
        v = d["bufferViews"][image["bufferView"]]; offset = v.get("byteOffset", 0)
        raw = bytes(binary[offset:offset + v["byteLength"]]); im = Image.open(io.BytesIO(raw)); im.load()
        images.append({"name": image.get("name"), "dimensions": im.size, "decoded_rgba_sha256": sha(im.convert("RGBA").tobytes())})
    return {"path": str(path), "sha256": sha(b), "triangles": triangles, "images": images,
            "accessors_finite": True, "indices_in_bounds": True, "self_contained": True, "maximum_normal_length_error": maximum_normal_error}


def validate(client, report):
    assets = client / "assets"
    folders = ("original_props", "original_3d", "original_combat", "original_sky", "original_world", "original_worlds")
    models = [validate_glb(p) for folder in folders for p in sorted((assets / folder).rglob("*.glb"))]
    index = {str(Path(m["path"]).resolve()): m for m in models}
    worlds = []
    for ident, folder, props, count in ((3002, "original_world", "original_props", 911), (3003, "original_worlds/3003", "original_worlds/3003/props", 312), (3302, "original_worlds/3302", "original_worlds/3302/props", 908)):
        root = assets / folder; metadata = json.loads((root / f"{ident}_terrain.json").read_text())
        grid = metadata["grid"]; height = (root / grid["heightmap"]).read_bytes()
        assert len(height) == grid["vertex_side"] ** 2 * 4 and sha(height) == grid["heightmap_sha256"]
        assert np.isfinite(np.frombuffer(height, dtype="<f4")).all()
        for kind, field in (("water", "active_tile_flags"), ("landing", "tile_flags")):
            row = metadata[kind]; flags = (root / row[field]).read_bytes()
            assert len(flags) == grid["tile_side"] ** 2 and set(flags) <= {0, 1} and sha(flags) == row[field + "_sha256"]
        layout = json.loads((assets / props / "placements.json").read_text())
        assert layout["instance_count"] == count and sum(len(m["placements"]) for m in layout["models"]) == count
        for model in layout["models"]:
            target = client / model["scene"].removeprefix("res://")
            assert index[str(target.resolve())]["sha256"] == model["sha256"]
            for pose in model["placements"]:
                matrix = np.asarray(pose["transform_columns"])
                assert matrix.shape == (12,) and np.isfinite(matrix).all()
                assert abs(np.linalg.det(matrix[:9].reshape((3, 3))) - 1) < .0001
            if "collision_mesh" in model:
                record = model["collision_mesh"]; path = client / record["path"].removeprefix("res://")
                assert sha(path.read_bytes()) == record["sha256"]
                collision = json.loads(path.read_text()); tri = np.asarray(collision["triangles"])
                assert tri.shape == (collision["triangle_count"] * 3, 3) and np.isfinite(tri).all()
        worlds.append({"resource_id": ident, "models": len(layout["models"]), "instances": count, "height_and_flags_valid": True, "poses_and_source_glb_hashes_valid": True})
    result = {"status": "passed", "glb_count": len(models), "worlds": worlds, "models": models,
              "limitations": ["Validates exported data, not original client/server execution.", "Source image equivalence and source render bindings are additionally recorded in per-asset conversion reports."]}
    report.parent.mkdir(parents=True, exist_ok=True); report.write_text(json.dumps(result, indent=2, allow_nan=False) + "\n")
    return result


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__); p.add_argument("--client", type=Path, required=True); p.add_argument("--report", type=Path, required=True)
    a = p.parse_args(); r = validate(a.client, a.report); print(json.dumps({"status": r["status"], "glb_count": r["glb_count"], "worlds": r["worlds"]}))
