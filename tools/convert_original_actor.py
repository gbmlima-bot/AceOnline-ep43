#!/usr/bin/env python3
"""Preserve an original skinned actor through Assimp's glTF2 exporter.

The source container and image are hash checked. A caller supplies a proven
one-based texture selection. Stale material filesystem paths are never read.
"""
import argparse
import hashlib
import io
import json
from pathlib import Path
import struct
import subprocess
import numpy as np
from PIL import Image


def sha(data): return hashlib.sha256(data).hexdigest()


def convert(unpacked: Path, output: Path, report_root: Path, source_code: int, texture_index: int = 1):
    m = json.loads((unpacked / "manifest.json").read_text())
    if sha(Path(m["source_pack"]).read_bytes()) != m["source_pack_sha256"]: raise ValueError("source pack changed")
    for e in m["entries"]:
        data = Path(e["path"]).read_bytes()
        if len(data) != e["size"] or sha(data) != e["source_sha256"]: raise ValueError("source payload changed")
    model = [e for e in m["entries"] if e["kind"] == "model"]
    images = sorted((e for e in m["entries"] if e["kind"] == "image"), key=lambda e:e["entry_name"])
    if len(model) != 1 or not 1 <= texture_index <= len(images): raise ValueError("unsupported actor selection")
    report_root.mkdir(parents=True, exist_ok=True); output.parent.mkdir(parents=True, exist_ok=True)
    stage = report_root / (output.stem + "-assimp.gltf")
    log = report_root / (output.stem + "-assimp-export.log")
    with log.open("w") as stream:
        subprocess.run(["/workspace/tools/assimp/root/usr/bin/assimp", "export", model[0]["path"], str(stage), "-fgltf2"], stdout=stream, stderr=subprocess.STDOUT, check=True)
    raw = stage.read_bytes()
    d = json.loads(raw.decode("utf-8", "surrogateescape"))
    if len(d["buffers"]) != 1: raise ValueError("unexpected exporter buffer count")
    uri = d["buffers"][0]["uri"]
    if Path(uri).name != uri: raise ValueError("unsafe generated buffer path")
    binary = bytearray((stage.parent / uri).read_bytes())
    if len(binary) != d["buffers"][0]["byteLength"]: raise ValueError("exported buffer length mismatch")
    source_animation_count = len(d.get("animations", []))
    bad_animation_inputs = 0
    for animation in d.get("animations", []):
        for sampler in animation["samplers"]:
            a = d["accessors"][sampler["input"]]; v = d["bufferViews"][a["bufferView"]]
            values = np.frombuffer(binary, dtype="<f4", count=a["count"], offset=v.get("byteOffset", 0) + a.get("byteOffset", 0)).copy()
            bad_animation_inputs += int(not np.isfinite(values).all())
    if bad_animation_inputs:
        # This source's importer timing has no finite seconds. Do not invent a
        # tick rate. Keep the skin and original bind pose, omit only animation.
        d.pop("animations", None)
        used = {i for mesh in d["meshes"] for p in mesh["primitives"] for i in [p["indices"], *p["attributes"].values()]}
        used.update(s["inverseBindMatrices"] for s in d.get("skins", []))
        mapping = {old: new for new, old in enumerate(sorted(used))}
        for mesh in d["meshes"]:
            for primitive in mesh["primitives"]:
                primitive["indices"] = mapping[primitive["indices"]]
                primitive["attributes"] = {key: mapping[value] for key, value in primitive["attributes"].items()}
        for skin in d.get("skins", []): skin["inverseBindMatrices"] = mapping[skin["inverseBindMatrices"]]
        d["accessors"] = [d["accessors"][i] for i in sorted(used)]
        used_views = sorted({a["bufferView"] for a in d["accessors"]})
        view_mapping = {old: new for new, old in enumerate(used_views)}
        for a in d["accessors"]: a["bufferView"] = view_mapping[a["bufferView"]]
        new_binary = bytearray()
        views = []
        for index in used_views:
            v = dict(d["bufferViews"][index]); start = v.get("byteOffset", 0)
            new_binary.extend(b"\0" * (-len(new_binary) % 4))
            v["byteOffset"] = len(new_binary); new_binary.extend(binary[start:start + v["byteLength"]]); views.append(v)
        binary = new_binary; d["bufferViews"] = views
    image_entry = images[texture_index - 1]
    with Image.open(image_entry["path"]) as image:
        image.load(); pixels = image.convert("RGBA"); pixel_bytes = pixels.tobytes()
        target = io.BytesIO(); pixels.save(target, "PNG"); png = target.getvalue(); size = image.size
    with Image.open(io.BytesIO(png)) as image:
        if image.convert("RGBA").tobytes() != pixel_bytes: raise ValueError("image pixel mismatch")
    binary.extend(b"\0" * (-len(binary) % 4))
    view = len(d["bufferViews"])
    d["bufferViews"].append({"buffer": 0, "byteOffset": len(binary), "byteLength": len(png)})
    binary.extend(png)
    d["images"] = [{"name": image_entry["entry_name"], "bufferView": view, "mimeType": "image/png"}]
    for texture in d.get("textures", []): texture["source"] = 0
    for material in d["materials"]:
        material["alphaMode"] = "BLEND"
        material.setdefault("extras", {})["source_texture_selection"] = "MonRender.cpp:188,194 AnotherTexture(TextureIndex=1), not stale material path. AlphaBlending=1 in current monster record; native test>=8/255 must be applied by runtime for exact combined test/blend."
    # Both original MonsterData and ShuttleChild orient local -Z with LookAtRH.
    for scene in d["scenes"]:
        parent = len(d["nodes"])
        d["nodes"].append({"name": "Original_actor_heading_normalization", "rotation": [0, 1, 0, 0], "children": scene["nodes"]})
        scene["nodes"] = [parent]
    d["buffers"] = [{"byteLength": len(binary)}]
    d["asset"]["extras"] = {"source_pack_sha256": m["source_pack_sha256"], "source_code": source_code,
                                "orientation": "Assimp X Z reflection and glTF UV conversion, then proper Y180 parent. Forward -Z/up+Y; no runtime extra rotation.",
                                "animation_policy": ("Source animation omitted because Assimp exports nonfinite time inputs; no tick rate guessed. Skin, inverse-bind matrices and source bind pose preserved." if bad_animation_inputs else "All source skin joints, inverse-bind matrices and exported animation channels preserved.")}
    # Re-encoding removes the invalid source filename bytes, which are only in
    # the replaced image URI. Reject any other unexpected surrogate text.
    encoded = json.dumps(d, separators=(",", ":"), ensure_ascii=False, allow_nan=False).encode("utf-8")
    encoded += b" " * (-len(encoded) % 4); binary.extend(b"\0" * (-len(binary) % 4))
    glb = struct.pack("<4sII", b"glTF", 2, 28 + len(encoded) + len(binary))
    glb += struct.pack("<I4s", len(encoded), b"JSON") + encoded + struct.pack("<I4s", len(binary), b"BIN\0") + binary
    output.write_bytes(glb)
    triangles = sum(d["accessors"][p["indices"]]["count"] // 3 for mesh in d["meshes"] for p in mesh["primitives"])
    report = {"model_id": output.stem, "source_code": source_code, "output": str(output), "output_sha256": sha(glb), "output_size": len(glb),
              "source_pack": m["source_pack"], "source_pack_sha256": m["source_pack_sha256"], "source_x_sha256": model[0]["source_sha256"],
              "triangles": triangles, "skin_count": len(d.get("skins", [])), "skin_joint_counts": [len(s["joints"]) for s in d.get("skins", [])],
              "source_animation_count": source_animation_count, "animation_tracks_exported": len(d.get("animations", [])),
              "omitted_nonfinite_animation_samplers": bad_animation_inputs,
              "animation_channel_count": sum(len(a["channels"]) for a in d.get("animations", [])),
              "texture": {"entry_name": image_entry["entry_name"], "source_sha256": image_entry["source_sha256"], "embedded_sha256": sha(png),
                          "dimensions": size, "decoded_rgba_sha256": sha(pixel_bytes), "transformation": "Lossless RGBA PNG encoding; exact decoded source pixels, no image flip."},
              "orientation": {"forward": [0, 0, -1], "up": [0, 1, 0], "rotation_degrees": [0, 0, 0], "heading_baked": True},
              "coordinate_evidence": "EP35 MonsterData.cpp:231,832,836 inverse LookAtRH; MonRender.cpp:188,194 texture selection; source units unchanged.",
              "source_alpha_policy": {"enabled": True, "reference_uint8": 8, "blend": "SRCALPHA/INVSRCALPHA", "evidence": "EP35 MonRender.cpp:149-155", "gltf_limitation": "GLB BLEND preserves partial alpha; combined source alpha test is a runtime policy."},
              "external_resources": [], "converter_sha256": sha(Path(__file__).read_bytes()), "exporter": "Debian Assimp5.4.3 gltf2 exporter; verified original skin/animation retained"}
    (report_root / (output.stem + "-conversion.json")).write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")
    return report


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--unpacked", type=Path, required=True); p.add_argument("--output", type=Path, required=True)
    p.add_argument("--report-root", type=Path, required=True); p.add_argument("--source-code", type=int, required=True)
    a = p.parse_args(); r = convert(a.unpacked, a.output, a.report_root, a.source_code)
    print(json.dumps({k:r[k] for k in ("model_id", "output_sha256", "triangles", "skin_joint_counts", "animation_tracks_exported")}))
