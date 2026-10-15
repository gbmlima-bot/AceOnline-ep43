#!/usr/bin/env python3
"""Export explicit ACE CINFGroupManager groups from plain Group.tex (no execution)."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import struct
import sys

import read_legacy_resources as read_resources

RECORD = struct.Struct("<36f100s100si4i")
SUBHEADER = struct.Struct("<3i")
TYPES = {0: "GROUP_TYPE", 1: "IMAGE_TYPE", 2: "GR_IMGAE_TYPE", 3: "CONTROL_TYPE", -1: "group_metadata"}


def text_field(raw):
    return raw.split(b"\0", 1)[0].decode("ascii", "backslashreplace")


def record(data, offset):
    if offset < 0 or offset + RECORD.size > len(data):
        raise read_resources.FormatError("IMAGEFILEMAIN outside payload")
    v = RECORD.unpack_from(data, offset)
    if not all(math.isfinite(x) for x in v[:36]):
        raise read_resources.FormatError("Non-finite transform float")
    return {"offset_in_payload": offset, "name": text_field(v[36]), "target_name": text_field(v[37]), "type": v[38], "type_name": TYPES.get(v[38], "unknown"), "translation": list(v[0:3]), "center": list(v[3:6]), "scaling": list(v[6:9]), "control_min": list(v[9:12]), "control_max": list(v[12:15]), "max_position": list(v[15:18]), "angle": v[18], "scale_percent": v[19], "matrix": list(v[20:36]), "source_rect": list(v[39:43])}


def parse_group(payload, name, textures):
    if len(payload) < RECORD.size + SUBHEADER.size:
        raise read_resources.FormatError(f"{name}: missing group header")
    version, count, controls = SUBHEADER.unpack_from(payload, RECORD.size)
    expected = RECORD.size + SUBHEADER.size + count * RECORD.size
    if version != 12 or count < 0 or count > 4096 or controls < 0 or expected != len(payload):
        raise read_resources.FormatError(f"{name}: unsupported version/count/payload bounds")
    metadata = record(payload, 0)
    nodes = [record(payload, 376 + n * 364) for n in range(count)]
    rects = []
    missing = []
    for index, node in enumerate(nodes):
        node["draw_order"] = index
        if node["type"] not in (1, 3):
            raise read_resources.FormatError(f"{name}: unsupported node type {node['type']}")
        if node["type"] == 3:
            a, b = node["control_min"], node["control_max"]
            node["control_size"] = [b[0] - a[0], b[1] - a[1]]
            continue
        texture = textures.get(node["name"])
        node["texture_found"] = texture is not None
        if texture:
            node["texture_dimensions"] = [texture["image"]["width"], texture["image"]["height"]]
            node["texture_sha256"] = texture["sha256"]
            node["texture_entry_index"] = texture["index"]
        else:
            missing.append(node["name"])
        left, top, right, bottom = node["source_rect"]
        if left < 0 or top < 0 or right < left or bottom < top:
            raise read_resources.FormatError(f"{name}: invalid image rect")
        if texture and (right > texture["image"]["width"] or bottom > texture["image"]["height"]):
            raise read_resources.FormatError(f"{name}: source rect outside texture {node['name']}")
        width = (right - left) * node["scaling"][0] * node["scale_percent"]
        height = (bottom - top) * node["scaling"][1] * node["scale_percent"]
        if node["angle"] == 0 and width >= 0 and height >= 0:
            node["unrotated_draw_size"] = [width, height]
            x, y = node["translation"][:2]
            rects.append([x, y, x + width, y + height])
    bounds = None
    if rects:
        bounds = [min(r[0] for r in rects), min(r[1] for r in rects), max(r[2] for r in rects), max(r[3] for r in rects)]
    return {"name": name, "version": version, "image_count": count, "declared_control_count": controls, "metadata": metadata, "nodes": nodes, "image_bounds_unrotated_local": bounds, "missing_texture_names": sorted(set(missing)), "geometry_note": "Raw child coordinates, crop rectangles and scale factors from shipped group. Group translation is stored/editor metadata and callers may override it at runtime. Control records are anchors, not drawable images. Bounds ignore controls and rotations."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("--texture-inventory", type=Path, required=True)
    parser.add_argument("--group", action="append", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        texture_report = json.loads(args.texture_inventory.read_text())
        textures = {e["name"]: e for e in texture_report["entries"] if e["image"]}
        with args.archive.open("rb") as stream:
            archive = read_resources.inventory(stream, args.archive)
            entries = {e["name"]: e for e in archive["entries"]}
            groups = []
            for name in args.group:
                if name not in entries:
                    raise read_resources.FormatError(f"Group absent: {name}")
                entry = entries[name]
                payload = read_resources.read_at(stream, entry["payload_offset"], entry["size"])
                if hashlib.sha256(payload).hexdigest() != entry["sha256"]:
                    raise read_resources.FormatError("Group payload digest changed")
                group = parse_group(payload, name, textures)
                group["source_entry"] = entry
                groups.append(group)
        result = {"schema_version": 1, "source_resource": str(args.archive.resolve()), "source_sha256": archive["source_sha256"], "texture_resource_sha256": texture_report["source_sha256"], "source_entry_count": len(entries), "record_stride": RECORD.size, "subheader_size": SUBHEADER.size, "endianness": "little", "format_source": "EP43 immutable f880284fafa3af9b4b1a4bb2938efef1b328bb8e: INFGroupManager.h:13-53, .cpp:59-105; Common/AtumDefine.h:1219-1225", "groups": groups}
        with args.output.open("x", encoding="utf-8") as stream:
            json.dump(result, stream, ensure_ascii=True, indent=2, allow_nan=False)
            stream.write("\n")
        return 0
    except (OSError, ValueError, KeyError, struct.error) as exc:
        print(json.dumps({"error": str(exc)}), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
