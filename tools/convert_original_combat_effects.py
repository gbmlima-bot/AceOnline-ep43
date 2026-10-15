#!/usr/bin/env python3
"""Convert three source-bound weapon meshes; preserve explicit render policies."""
import argparse
import io
import json
from pathlib import Path
import struct
from PIL import Image
import convert_original_gears as core

ROLES = {"06502160": "secondary_projectile", "06374500": "secondary_effect", "06303300": "primary_effect"}


def convert(unpacked, output, report_root, proof):
    evidence = json.loads(proof.read_text())
    table = next(f for f in evidence["files"] if f["filename"] == "effectinfo.inf")
    rows = {e["name"]: e for e in table["selected_entries"]}
    core.SOURCE_ROOT, core.OUTPUT_ROOT, core.REPORT_ROOT = unpacked, output, report_root
    models = []
    for name, role in ROLES.items():
        row = rows[name]; fields = row["fields"]
        source = json.loads((unpacked / name / "manifest.json").read_text())
        images = sorted((e for e in source["entries"] if e["kind"] == "image"), key=lambda e:e["entry_name"])
        r = core.convert(name, role.upper(), profile="scenery", texture_entry_override=images[0]["entry_name"], alpha_mode="BLEND" if fields["alpha_blend"] else "OPAQUE")
        p = output / (name + ".glb"); b = p.read_bytes(); length = struct.unpack_from("<I", b, 12)[0]
        d = json.loads(b[20:20 + length]); binary = b[28 + length:]
        for mat in d["materials"]:
            mat["pbrMetallicRoughness"]["baseColorFactor"] = fields["color_rgba"]
            mat["extras"]["source_material_policy"] = "EffectRender.cpp2808-2809 uses externally supplied ObjectAniData color; descriptor RGBA replaces mesh material."
            if not fields["environment_light"]:
                mat["extensions"] = {"KHR_materials_unlit": {}}
                d["extensionsUsed"] = ["KHR_materials_unlit"]
        d["asset"]["extras"]["source_effect_descriptor_sha256"] = row["sha256"]
        encoded = json.dumps(d, separators=(",", ":"), allow_nan=False).encode(); encoded += b" " * (-len(encoded) % 4)
        glb = struct.pack("<4sII", b"glTF", 2, 28 + len(encoded) + len(binary))
        glb += struct.pack("<I4s", len(encoded), b"JSON") + encoded + struct.pack("<I4s", len(binary), b"BIN\0") + binary
        p.write_bytes(glb)
        frames = []
        for index, e in enumerate(images):
            with Image.open(e["path"]) as image:
                image.load(); image = image.convert("RGBA"); pixels = image.tobytes(); target = io.BytesIO(); image.save(target, "PNG"); png = target.getvalue()
            frame = output / (e["entry_name"] + ".png"); frame.write_bytes(png)
            frames.append({"index": index, "name": e["entry_name"], "path": "res://assets/original_combat/" + frame.name,
                           "sha256": core.sha(png), "source_sha256": e["source_sha256"], "decoded_rgba_sha256": core.sha(pixels)})
        r.update(output_sha256=core.sha(glb), output_size=len(glb), asset_kind=role, effect_descriptor=row,
                 material_profile={"unlit": not fields["environment_light"], "baseColorFactor": fields["color_rgba"], "source_render_policy": fields,
                                   "gltf_limitation": "GLB retains source image/frame1. Additive ONE/ONE, zwrite0 and texture frame animation require runtime policy."})
        (report_root / (name + "-conversion.json")).write_text(json.dumps(r, indent=2, allow_nan=False) + "\n")
        models.append({"id": name, "role": role, "source_code": 7901000 if role.startswith("secondary") else 7000040,
                       "scene_path": "res://assets/original_combat/" + name + ".glb", "sha256": r["output_sha256"], "bytes": len(glb), "triangles": r["triangles"],
                       "aabb": {k:r["aabb_" + k] for k in ("min", "max", "size", "center")}, "rotation_degrees": [0, 0, 0],
                       "orientation": {"forward": [0, 0, -1], "up": [0, 1, 0], "heading": "Assimp Z reflection only; original weapon uses inverseLookAtLH local+Z. No ship Y180."},
                       "source_pack": "Res-eff/" + name + ".obj", "source_pack_sha256": r["source_pack_sha256"], "source_x_sha256": r["source_x_sha256"],
                       "effect_descriptor": row, "effect_info_container_sha256": table["sha256"], "texture_frames": frames,
                       "attachment_source_position": [0, 0, 2.5] if name == "06374500" else [0, 0, 0],
                       "attachment_target_position": [0, 0, -2.5] if name == "06374500" else [0, 0, 0],
                       "render_policy": fields, "animation_tracks_exported": 0, "source_animation_count": r["source_animation_count"],
                       "external_resources": [], "limitation": "Static source mesh with source frame1; source render blend/depth/light/frame policies supplied separately, not fully expressible by standard glTF."})
    manifest_path = output / "manifest.json"; manifest = json.loads(manifest_path.read_text())
    manifest["models"] = [m for m in manifest["models"] if m["id"] not in ROLES] + models
    manifest["provenance"]["effect_descriptor_evidence"] = "docs/evidence/" + proof.name
    manifest["provenance"]["effect_descriptor_evidence_sha256"] = core.sha(proof.read_bytes())
    manifest["provenance"]["effect_converter_sha256"] = core.sha(Path(__file__).read_bytes())
    manifest_path.write_text(json.dumps(manifest, indent=2, allow_nan=False) + "\n")
    return models


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    for name in ("unpacked", "output", "report-root", "proof"):
        p.add_argument("--" + name, type=Path, required=True)
    a = p.parse_args(); result = convert(a.unpacked, a.output, a.report_root, a.proof)
    print(json.dumps([{"id": m["id"], "role": m["role"], "sha256": m["sha256"], "triangles": m["triangles"]} for m in result]))
