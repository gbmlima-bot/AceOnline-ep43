#!/usr/bin/env python3
"""Convert every observed static render code in the pinned original map3002.

No game executable is run. Declared CGameData payloads are bounded; opaque
trailers are hashed and left uninterpreted, as in the source loader.
"""
from __future__ import annotations
import argparse
from collections import Counter
import io
import json
from pathlib import Path
import re
import struct
import numpy as np
from PIL import Image
import convert_original_gears as core
import convert_original_props as prior
from convert_original_terrain import parse_resource, parse_terrain, require, sha256


def unpack(pack: Path, destination: Path) -> dict:
    entries, container = parse_resource(pack.read_bytes())
    destination.mkdir(parents=True, exist_ok=True)
    records = []
    for name, entry in entries.items():
        require(re.fullmatch(r"[A-Za-z0-9_-]{1,40}", name), "unsafe resource name")
        if entry.data.startswith(b"xof "):
            require(entry.data[:16] in (b"xof 0303txt 0032", b"xof 0303bzip0032", b"xof 0303bin 0032"), "unknown X header")
            kind, suffix = "model", "x"
        else:
            with Image.open(io.BytesIO(entry.data)) as image:
                require(0 < image.width * image.height <= 4096 * 4096, "image dimensions outside policy")
                image.load()
                kind, suffix = "image", image.format.lower()
        path = destination / (name + "." + suffix)
        path.write_bytes(entry.data)
        records.append({"entry_name": name, "kind": kind, "path": str(path.resolve()), "size": len(entry.data),
                        "source_sha256": sha256(entry.data), "source_payload_offset": entry.offset})
    manifest = {"source_pack": str(pack.resolve()), "source_pack_sha256": container["sha256"], "container": container, "entries": records}
    (destination / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return manifest


def read_rows(data: bytes) -> dict:
    require(sha256(data) == prior.OMI_SHA, "unknown OMI source")
    require(struct.unpack_from("<2i", data, prior.OMI_SECTION_OFFSET) == (2, prior.OMI_COUNT), "wrong MAPOBJECT section")
    rows = {}
    for index in range(prior.OMI_COUNT):
        offset = prior.OMI_SECTION_OFFSET + 8 + index * prior.MAPOBJECT.size
        code, alpha, collision, server_collision, render_type, render_index = prior.MAPOBJECT.unpack_from(data, offset)
        require(code not in rows and alpha in (0, 1), "invalid MAPOBJECT row")
        rows[code] = {"code": code, "alpha": alpha, "collision": collision, "server_collision": server_collision,
                      "render_type": render_type, "render_index": render_index, "source_sha256": prior.OMI_SHA,
                      "source_offset": offset, "source_record_sha256": sha256(data[offset:offset + 12]), "source_record_hex": data[offset:offset + 12].hex()}
    return rows


def read_placements(data: bytes, resource_id: int = 3002) -> tuple[list, dict]:
    profiles = {3002: (prior.EXPECTED_RESOURCES["3002.dat"], 911, 31), 3003: ("ad1d44cf704355fb335c99b171595f2c3b65e9443867cd0138340cc31d15337b", 312, 28), 3302: ("2f4f4b3d652904669d542bc13ea4f8fff4c0f668d45768338c87e36ce014f6b2", 908, 31)}
    require(resource_id in profiles and sha256(data) == profiles[resource_id][0], "unknown DAT source")
    entries, container = parse_resource(data)
    payload = entries[str(resource_id)].data
    terrain = parse_terrain(payload)
    start = 36 + len(terrain.vertices) * 24 + terrain.tiles * terrain.tiles * 24
    poses, counts = [], Counter()
    for index in range(terrain.object_count):
        record = payload[start + index * 112:start + (index + 1) * 112]
        code = struct.unpack_from("<I", record)[0]
        position, direction, up = (struct.unpack_from("<3f", record, off) for off in (8, 20, 32))
        basis, origin = prior.original_pose(position, direction, up)
        event = struct.unpack_from("<i", record, 60)[0]
        poses.append({"source_record_index": index, "source_record_offset": entries[str(resource_id)].offset + start + index * 112,
                      "source_record_sha256": sha256(record), "code": code, "source_position": position,
                      "source_direction": direction, "source_up": up, "body_condition_byte": record[56],
                      "body_condition_mask": 1 << record[56], "source_texture_index": record[48], "source_is_event": event,
                      "transform_columns": np.concatenate((basis.T.reshape(-1), origin)).tolist()})
        counts[code] += 1
    require((len(poses), len(counts)) == profiles[resource_id][1:], "pinned map object count changed")
    return poses, {"sha256": container["sha256"], "total_records": len(poses), "selected_records": len(poses),
                   "omitted_records": 0, "unique_render_codes": len(counts), "selected_counts": {str(c): n for c, n in sorted(counts.items())}}


def collision_mesh(path: Path, metadata: dict, output: Path, asset_prefix: str = "res://assets/original_props/") -> dict:
    """Export exactly the static visual triangle soup, not a guessed proxy."""
    data = path.read_bytes()
    require(data[:4] == b"glTF" and struct.unpack_from("<I", data, 8)[0] == len(data), "bad converted GLB")
    length = struct.unpack_from("<I", data, 12)[0]
    doc = json.loads(data[20:20 + length])
    binary = memoryview(data)[28 + length:]
    def accessor(index):
        a = doc["accessors"][index]; v = doc["bufferViews"][a["bufferView"]]
        require(a["componentType"] in (5126, 5125), "unknown accessor type")
        width = {"VEC3": 3, "SCALAR": 1}[a["type"]]
        start = v.get("byteOffset", 0) + a.get("byteOffset", 0)
        array = np.frombuffer(binary, dtype="<f4" if a["componentType"] == 5126 else "<u4", count=a["count"] * width, offset=start)
        return array.reshape((-1, width))
    triangles = []
    for mesh in doc["meshes"]:
        for p in mesh["primitives"]:
            positions = accessor(p["attributes"]["POSITION"])
            indices = accessor(p["indices"]).reshape((-1, 3))
            require(len(indices) <= 2000000 and indices.max() < len(positions), "collision triangle bounds")
            triangles.extend(positions[indices].reshape((-1, 3)).tolist())
    result = {"schema_version": 1, "code": metadata["code"], "coordinate_profile": "same local RH positions as GLB; no ship heading",
              "source_glb_sha256": sha256(data), "source_mapobjectinfo": metadata, "triangles": triangles,
              "triangle_count": len(triangles) // 3, "limitation": "Static converted visual triangle soup; animation/effect geometry is not included. Runtime must retain source Collision flags and instance transform."}
    output.write_text(json.dumps(result, separators=(",", ":"), allow_nan=False) + "\n")
    return {"path": asset_prefix + output.name, "sha256": sha256(output.read_bytes()), "triangle_count": result["triangle_count"]}


def convert(source: Path, terrain: Path, metadata: Path, unpacked: Path, output: Path, report_root: Path, resource_id: int = 3002, asset_prefix: str = "res://assets/original_props/") -> dict:
    output.mkdir(parents=True, exist_ok=True); report_root.mkdir(parents=True, exist_ok=True)
    rows = read_rows(metadata.read_bytes()); poses, placement_source = read_placements(terrain.read_bytes(), resource_id)
    codes = sorted({p["code"] for p in poses})
    core.SOURCE_ROOT, core.OUTPUT_ROOT, core.REPORT_ROOT = unpacked, output, report_root
    reports, models = [], []
    for code in codes:
        require(code in rows and rows[code]["render_type"] in (0, 2, 3, 4, 10), "object requires an unsupported source renderer")
        name = f"{code:08d}"; row = rows[code]
        source_manifest = unpack(source / (name + ".obj"), unpacked / name)
        images = sorted(e["entry_name"] for e in source_manifest["entries"] if e["kind"] == "image")
        require(bool(images), "source AnotherTexture1 has no image")
        report = core.convert(name, "SCENERY", profile="scenery", alpha_mode="BLEND" if row["alpha"] else "OPAQUE", texture_entry_override=images[0], generate_zero_normals=True)
        report["texture_override"]["origin"] = "CObjRender.cpp:90 forces AnotherTexture(1); SkinnedMesh.h:477 and SkinnedMesh.cpp:2498 select first image in sorted CGameData order regardless of stale material filename."
        report["source_mapobjectinfo"] = row
        report["material_profile"]["source_selected_mapobjectinfo_alpha"] = row["alpha"]
        report["alpha_override"]["origin"] = "Confirmed current MAPOBJECTINFO.Alpha; nonzero requires runtime test>=127 and straight alpha blending."
        report["source_container_opaque_trailing"] = source_manifest["container"]["opaque_trailing"]
        report["render_type_note"] = "Source AtumDefine.h:243-253: normal0,big-culled2,big-no-collision3,big-effect4,big-contour10 retain base CObjRender mesh path. Static base mesh exported; descriptor effects and original culling behavior are not baked."
        model = {"code": code, "scene": asset_prefix + name + ".glb", "filename": name + ".glb",
                 "sha256": report["output_sha256"], "source_mapobjectinfo": row, "placements": [p for p in poses if p["code"] == code]}
        if row["collision"] or row["server_collision"]:
            model["collision_mesh"] = collision_mesh(output / (name + ".glb"), row, output / (name + "_collision.json"), asset_prefix)
            report["collision_mesh"] = model["collision_mesh"]
        (report_root / (name + "-conversion.json")).write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")
        reports.append(report); models.append(model)
    alpha = {"enabled": True, "per_model": True, "source_alpha_flag": "models[].source_mapobjectinfo.alpha",
             "function": "GREATER_EQUAL", "reference_uint8": 127, "cutoff": 127 / 255,
             "blend": "SRCALPHA/INVSRCALPHA", "runtime": "Only Alpha!=0: discard below cutoff then blend_mix. Alpha0 is opaque."}
    layout = {"schema_version": 1, "resource_id": resource_id, "source": placement_source, "instance_count": len(poses),
              "model_count": len(models), "coordinate_profile": "F*inverse(LookAtLH(position,position+direction,normalize(up)))*F, F=diag(1,1,-1); origin+=(-5120,0,5120); no ship heading",
              "matrix_layout": "12 floats: basisX.xyz,basisY.xyz,basisZ.xyz,origin.xyz; Godot column vectors", "alpha_pipeline": alpha, "models": models}
    (output / "placements.json").write_text(json.dumps(layout, indent=2, allow_nan=False) + "\n")
    template = Path(__file__).resolve().parent.parent / "client/assets/original_props/manifest.json"
    original = json.loads((output / "manifest.json" if (output / "manifest.json").exists() else template).read_text())
    original.update(model_count=len(models), instance_count=len(poses), source_placements=placement_source,
                    alpha_pipeline=alpha, placements_sha256=sha256((output / "placements.json").read_bytes()),
                    converter_sha256=sha256(Path(__file__).read_bytes()), core_converter_sha256=sha256(Path(core.__file__).read_bytes()), models=reports,
                    limitations=[f"All{len(models)}base render codes and{len(poses)}source poses retained. Source event flags retained as metadata, not interpreted as gameplay.",
                                 "Static frame pose only. Source animation tracks, descriptors and attached effects are not exported; source bones rejected.",
                                 "Collision triangle files contain the same converted static visual mesh; no invented collision proxies. Source flags retained.",
                                 "Phong-to-PBR lighting is an approximation; original texture pixels and static transforms retained."])
    (output / "manifest.json").write_text(json.dumps(original, indent=2, allow_nan=False) + "\n")
    return original


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    for arg in ("source", "terrain", "metadata", "unpacked", "output", "report-root"):
        p.add_argument("--" + arg, type=Path, required=True)
    p.add_argument("--resource-id", type=int, default=3002)
    p.add_argument("--asset-prefix", default="res://assets/original_props/")
    args = p.parse_args()
    result = convert(args.source, args.terrain, args.metadata, args.unpacked, args.output, args.report_root, args.resource_id, args.asset_prefix)
    print(json.dumps({"status": "ok", "model_count": result["model_count"], "instance_count": result["instance_count"], "triangles": sum(r["triangles"] for r in result["models"])}))
