#!/usr/bin/env python3
"""Convert the three most frequent original static props and their exact poses.

Reads only pinned, plain client data. Uses the shared scenery conversion profile
without ship heading normalization. No legacy executable, network or replay.
"""
from __future__ import annotations

import argparse
from collections import Counter
import io
import json
from pathlib import Path
import struct

import numpy as np
from PIL import Image

import convert_original_gears as core
from convert_original_terrain import EXPECTED_RESOURCES, FormatError, parse_resource, parse_terrain, require, sha256

MODELS = (3002200, 3002300, 3002400)
EXPECTED_PACKS = {
    3002200: "45dadfcea63d7f5d6f5f657e158d4b592b4023936636422c8a5ee09bad124d32",
    3002300: "172da7a613a4d42dc0cd446e2ea59417de74c46f3b3935e8f34a4852e0cfaa58",
    3002400: "583fd4084d2942910b90d84cb66c19404f99a3c411d03893f32380307ac282fd",
}
OMI_SHA = "4831431a42bd37ac3ecffc067989330f6304ce214c0a77e8062d28f1fffb5f48"
OMI_SECTION_OFFSET = 9443760
OMI_COUNT = 2462
MAPOBJECT = struct.Struct("<i4BH2x")
REFLECTION = np.diag([1.0, 1.0, -1.0])
WORLD_OFFSET = np.array([-5120.0, 0.0, 5120.0])


def read_object_metadata(data: bytes) -> dict[int, dict]:
    require(sha256(data) == OMI_SHA, "OMI identity mismatch; unknown layouts are not scanned/guessed")
    require(struct.unpack_from("<2i", data, OMI_SECTION_OFFSET) == (2, OMI_COUNT), "OMI DB_MAPOBJECT header mismatch")
    start = OMI_SECTION_OFFSET + 8
    end = start + OMI_COUNT * MAPOBJECT.size
    require(struct.unpack_from("<2i", data, end) == (3, 2715), "OMI next section boundary mismatch")
    rows = {}
    all_codes = set()
    for index in range(OMI_COUNT):
        offset = start + index * MAPOBJECT.size
        code, alpha, collision, server_collision, render_type, render_index = MAPOBJECT.unpack_from(data, offset)
        require(code not in all_codes and alpha in (0, 1), "invalid or duplicate MAPOBJECTINFO")
        all_codes.add(code)
        if code in MODELS:
            rows[code] = {"code": code, "alpha": alpha, "collision": collision, "server_collision": server_collision,
                          "render_type": render_type, "render_index": render_index,
                          "source_sha256": OMI_SHA, "source_offset": offset, "source_record_sha256": sha256(data[offset:offset + 12]),
                          "source_record_hex": data[offset:offset + 12].hex()}
    require(set(rows) == set(MODELS), "required object metadata absent")
    require(all(row["alpha"] == 1 and row["render_type"] == 0 for row in rows.values()), "observed static scenery alpha/render profile changed")
    return rows


def original_pose(position, direction, up) -> tuple[np.ndarray, np.ndarray]:
    """Column equivalent of D3DX inverse(LookAtLH), then F*M*F and centering."""
    position, direction, up = (np.asarray(v, dtype=np.float64) for v in (position, direction, up))
    require(all(v.shape == (3,) and np.isfinite(v).all() for v in (position, direction, up)), "invalid source pose vector")
    require(np.linalg.norm(direction) > 1e-8 and np.linalg.norm(up) > 1e-8, "zero forward or up vector")
    forward = direction / np.linalg.norm(direction)
    up = up / np.linalg.norm(up)
    right = np.cross(up, forward)
    require(np.linalg.norm(right) > 1e-8, "parallel source direction/up vectors")
    right /= np.linalg.norm(right)
    corrected_up = np.cross(forward, right)
    native_basis = np.column_stack((right, corrected_up, forward))
    target_basis = REFLECTION @ native_basis @ REFLECTION
    target_origin = REFLECTION @ position + WORLD_OFFSET
    require(abs(np.linalg.det(target_basis) - 1.0) < 1e-8, "reflected pose did not preserve rotation handedness")
    return target_basis, target_origin


def read_placements(data: bytes) -> tuple[list[dict], dict]:
    require(sha256(data) == EXPECTED_RESOURCES["3002.dat"], "terrain DAT identity mismatch")
    entries, container = parse_resource(data)
    payload = entries["3002"].data
    terrain = parse_terrain(payload)
    offset = 36 + len(terrain.vertices) * 24 + terrain.tiles * terrain.tiles * 24
    placements = []
    all_codes = Counter()
    for index in range(terrain.object_count):
        record = payload[offset + index * 112:offset + (index + 1) * 112]
        code = struct.unpack_from("<I", record, 0)[0]
        all_codes[code] += 1
        if code not in MODELS:
            continue
        event = struct.unpack_from("<i", record, 60)[0]
        require(event == 0, "selected scenery unexpectedly contains event records")
        position = struct.unpack_from("<3f", record, 8)
        direction = struct.unpack_from("<3f", record, 20)
        up = struct.unpack_from("<3f", record, 32)
        basis, origin = original_pose(position, direction, up)
        placements.append({"source_record_index": index, "source_record_offset": entries["3002"].offset + offset + index * 112,
                           "source_record_sha256": sha256(record), "code": code, "source_position": position,
                           "source_direction": direction, "source_up": up, "body_condition_byte": record[56],
                           "body_condition_mask": 1 << record[56], "source_texture_index": record[48],
                           "transform_columns": np.concatenate((basis.T.reshape(-1), origin)).tolist()})
    require(len(placements) == 723, "observed selection does not have723placements")
    return placements, {"sha256": container["sha256"], "total_records": terrain.object_count,
                        "selected_records": len(placements), "omitted_records": terrain.object_count - len(placements),
                        "unique_render_codes": len(all_codes), "selected_counts": {str(code): all_codes[code] for code in MODELS}}


def unpack_model(pack: Path, unpacked: Path, code: int) -> None:
    data = pack.read_bytes()
    require(sha256(data) == EXPECTED_PACKS[code], "scenery pack identity mismatch:" + str(code))
    entries, container = parse_resource(data)
    model_id = f"{code:08d}"
    destination = unpacked / model_id
    destination.mkdir(parents=True, exist_ok=True)
    records = []
    for name, entry in entries.items():
        if entry.data.startswith(b"xof 0303txt 0032"):
            kind, extension = "model", "x"
        else:
            with Image.open(io.BytesIO(entry.data)) as image:
                require(image.width * image.height <= 4096 * 4096, "image exceeds converter policy")
                image.load()
                kind, extension = "image", image.format.lower()
        path = destination / (name + "." + extension)
        path.write_bytes(entry.data)
        records.append({"entry_name": name, "kind": kind, "path": str(path.resolve()), "size": len(entry.data),
                        "source_sha256": sha256(entry.data), "payload_offset": entry.offset})
    require(len(records) == 2 and sum(r["kind"] == "model" for r in records) == 1, "observed prop package profile changed")
    (destination / "manifest.json").write_text(json.dumps({"source_pack": str(pack.resolve()), "source_pack_sha256": sha256(data),
                                                         "entries": records, "container": container}, indent=2) + "\n")


def convert(source_root: Path, terrain_path: Path, metadata_path: Path, unpacked_root: Path, output: Path, report_root: Path) -> dict:
    output.mkdir(parents=True, exist_ok=True)
    report_root.mkdir(parents=True, exist_ok=True)
    rows = read_object_metadata(metadata_path.read_bytes())
    placements, placement_source = read_placements(terrain_path.read_bytes())
    core.SOURCE_ROOT, core.OUTPUT_ROOT, core.REPORT_ROOT = unpacked_root, output, report_root
    reports, models = [], []
    for code in MODELS:
        model_id = f"{code:08d}"
        unpack_model(source_root / (model_id + ".obj"), unpacked_root, code)
        report = core.convert(model_id, "SCENERY", profile="scenery", alpha_mode="BLEND")
        require(report["source_animation_count"] == 0 and report["source_bone_count"] == 0, "selected props must be static without discarded animation/skin")
        report["source_mapobjectinfo"] = rows[code]
        report["material_profile"]["source_selected_mapobjectinfo_alpha"] = rows[code]["alpha"]
        report["alpha_override"]["origin"] = "Confirmed current MAPOBJECTINFO.Alpha=1; native combined alpha-test/blend is completed by original_props.gd"
        (report_root / (model_id + "-conversion.json")).write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")
        reports.append(report)
        models.append({"code": code, "scene": "res://assets/original_props/" + model_id + ".glb",
                       "filename": model_id + ".glb", "sha256": report["output_sha256"], "source_mapobjectinfo": rows[code],
                       "placements": [p for p in placements if p["code"] == code]})
    alpha = {"enabled": True, "source_alpha_flag": 1, "function": "GREATER_EQUAL", "reference_uint8": 127,
             "cutoff": 127 / 255.0, "blend": "SRCALPHA/INVSRCALPHA", "runtime": "discard below cutoff then blend_mix; original image alpha retained"}
    layout = {"schema_version": 1, "resource_id": 3002, "source": placement_source, "instance_count": len(placements),
              "model_count": len(models), "coordinate_profile": "F*inverse(LookAtLH(position,position+direction,normalize(up)))*F, F=diag(1,1,-1); origin+=(-5120,0,5120); no ship heading",
              "matrix_layout": "12 floats: basisX.xyz,basisY.xyz,basisZ.xyz,origin.xyz; Godot column vectors",
              "alpha_pipeline": alpha, "models": models}
    (output / "placements.json").write_text(json.dumps(layout, indent=2, allow_nan=False) + "\n")
    manifest = {"schema_version": 1, "kind": "original static scenery props", "model_count": len(models), "instance_count": len(placements),
                "source_package_sha256": "8395f1f33dda8165f70f30d2a6ad094c5f64e144403fce98337e5012be795841",
                "source_ep35_commit": "7c3e47ac47844e5c415d356a94d6201a0b9a38c4", "source_ep43_commit": "f880284fafa3af9b4b1a4bb2938efef1b328bb8e",
                "source_object_metadata": {"file": "Res-tex/omi.tex", "sha256": OMI_SHA, "section_offset": OMI_SECTION_OFFSET,
                                           "section_type": 2, "record_count": OMI_COUNT, "record_stride": 12, "profile": "pinned current plaintext data; unknown item/monster layouts not guessed"},
                "source_placements": placement_source, "alpha_pipeline": alpha,
                "placements_sha256": sha256((output / "placements.json").read_bytes()),
                "converter_sha256": sha256(Path(__file__).read_bytes()), "core_converter_sha256": sha256(Path(core.__file__).read_bytes()),
                "models": reports, "source_evidence": [
                    "EP35 ObjectDefine.h:639-656:OBJECTINFOCLIENT112bytes",
                    "EP35 ObjectChild.cpp:33-59,103-104:position/direction/up,rendercode,condition bit and inverseLookAtLH",
                    "EP35 MeshRender.cpp:103-140:%08d.obj plain CGameData and CSkinnedMesh",
                    "EP35 ObjRender.cpp:65-74:Alpha!=0,alphaTest>=127 and SRCALPHA/INVSRCALPHA blend",
                    "EP35 AtumParam.h:3077-3106,6612-6648:MAPOBJECTINFO12bytes,DB_MAPOBJECT2,DATA_HEADER8bytes",
                    "EP35 AtumDatabase.cpp:139-148,409-446:object metadata rows fromRes-tex/omi.tex"],
                "limitations": ["Only3of31rendercodes,723of911placements.188otherrecords omitted; no replacement props invented.",
                                "No collision,events,combat,navigation or object gameplay. Selected models contain no animation/skin.",
                                "Phong-to-PBR lighting is an approximation; original pixels,static frame scale/UVs,normals and poses retained."]}
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2, allow_nan=False) + "\n")
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, required=True, help="Directory containing the three selected .obj packages")
    parser.add_argument("--terrain", type=Path, required=True, help="Pinned original3002.dat")
    parser.add_argument("--metadata", type=Path, required=True, help="Pinned originalRes-tex/omi.tex")
    parser.add_argument("--unpacked-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=Path("client/assets/original_props"))
    parser.add_argument("--report-root", type=Path, default=Path("analysis/original-props"))
    args = parser.parse_args()
    report = convert(args.source_root, args.terrain, args.metadata, args.unpacked_root, args.output, args.report_root)
    print(json.dumps({"status": "ok", "model_count": report["model_count"], "instance_count": report["instance_count"],
                      "models": [{"id": r["model_id"], "sha256": r["output_sha256"], "triangles": r["triangles"]} for r in report["models"]]}))


if __name__ == "__main__":
    main()
