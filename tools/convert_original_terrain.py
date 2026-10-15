#!/usr/bin/env python3
"""Bounded, offline reader/converter for the observed plain ACE terrain profile.

No legacy program, service, protocol, decoder or protection is used. The parser
only accepts CGameData 1000/1000 and the Win32 MapInfo/VERTEXINFO layout pinned
in terrain-source-format.json. Unknown trailing container bytes are preserved
in provenance; the legacy loader also stops after its declared entry count.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import json
import math
from pathlib import Path
import struct

HEADER = struct.Struct("<5i")
ENTRY = struct.Struct("<3i10s2s")
MAP_INFO = struct.Struct("<f3i")
VERTEX = struct.Struct("<6f")
MAX_RESOURCE = 64 * 1024 * 1024
MAX_ENTRIES = 1024
MAX_VERTICES = 1025 * 1025
MAX_TRAILING = 1024 * 1024  # converter policy, not a claimed legacy format limit
TILE_RECORD_SIZE = 24
OBJECT_RECORD_SIZE = 112
SOURCE_SHA = "7c3e47ac47844e5c415d356a94d6201a0b9a38c4"
EP43_SHA = "f880284fafa3af9b4b1a4bb2938efef1b328bb8e"
EXPECTED_RESOURCES = {
    "3002.dat": "ddc85816f376c044dbd239ed3888eeb1e8e28dfc62db4d93cf6ff1d3cd6e2d92",
    "3002.map": "8bc78a50d3a9144957b2ce8863422b29ec5c1603531f2970c4a987e685ccf1d8",
    "ms.wok": "a9201ff81a3c192448cc377300d33d87827b809618f368673d7c28a9cbcf13aa",
}


class FormatError(ValueError):
    pass


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise FormatError(message)


@dataclass(frozen=True)
class ResourceEntry:
    name: str
    identifier: int
    offset: int
    data: bytes


def parse_resource(data: bytes) -> tuple[dict[str, ResourceEntry], dict]:
    require(HEADER.size <= len(data) <= MAX_RESOURCE, "resource size outside converter policy")
    encode, identification, declared, count, parity = HEADER.unpack_from(data)
    require((encode, identification) == (1000, 1000), "unsupported resource profile; expected plain1000/1000")
    require(0 <= count <= MAX_ENTRIES, "invalid resource entry count")
    offset = HEADER.size
    entries = {}
    records = []
    for index in range(count):
        require(offset + ENTRY.size <= len(data), "truncated resource entry header")
        identifier, length, entry_parity, raw_name, padding = ENTRY.unpack_from(data, offset)
        offset += ENTRY.size
        require(0 <= length <= len(data) - offset, "invalid resource payload length")
        try:
            name = raw_name.split(b"\0", 1)[0].decode("ascii")
        except UnicodeDecodeError as exc:
            raise FormatError("non-ASCII entry name outside accepted profile") from exc
        require(bool(name) and name not in entries, "empty or duplicate resource entry name")
        payload = data[offset:offset + length]
        entries[name] = ResourceEntry(name, identifier, offset, payload)
        records.append({"index": index, "name": name, "identifier": identifier, "offset": offset,
                        "size": length, "sha256": sha256(payload), "parity": entry_parity,
                        "raw_name_hex": raw_name.hex(), "padding_hex": padding.hex()})
        offset += length
    trailing = data[offset:]
    require(len(trailing) <= MAX_TRAILING, "opaque trailing extension exceeds converter policy")
    return entries, {"size": len(data), "sha256": sha256(data), "header": {
        "encode": encode, "identification": identification, "declared_payload_size": declared,
        "entry_count": count, "parity": parity}, "entries": records,
        "opaque_trailing": {"offset": offset, "size": len(trailing), "sha256": sha256(trailing),
                            "meaning": "not interpreted; legacy loader stops after declared entries"}}


@dataclass(frozen=True)
class Terrain:
    tile_size: float
    tiles: int
    vertices: tuple[tuple[float, ...], ...]
    object_count: int
    native_bounds: tuple[tuple[float, ...], tuple[float, ...]]


def parse_terrain(payload: bytes) -> Terrain:
    require(len(payload) >= 20 + MAP_INFO.size, "truncated terrain prefix/MapInfo")
    tile_size, vertex_count, tile_count, object_count = MAP_INFO.unpack_from(payload, 20)
    require(math.isfinite(tile_size) and tile_size > 0.0, "invalid tile size")
    require(4 <= vertex_count <= MAX_VERTICES and tile_count > 0 and object_count >= 0, "invalid terrain counts")
    side = math.isqrt(vertex_count)
    require(side * side == vertex_count and (side - 1) ** 2 == tile_count, "only internally consistent square grids are supported")
    required = 20 + MAP_INFO.size + vertex_count * VERTEX.size + tile_count * TILE_RECORD_SIZE + object_count * OBJECT_RECORD_SIZE
    require(required == len(payload), "terrain arrays do not exactly fit selected entry")
    vertices = tuple(VERTEX.iter_unpack(payload[36:36 + vertex_count * VERTEX.size]))
    minimum = [math.inf] * 3
    maximum = [-math.inf] * 3
    for index, vertex in enumerate(vertices):
        require(all(math.isfinite(value) for value in vertex), "non-finite terrain vertex or normal")
        x, z = divmod(index, side)
        require(abs(vertex[0] - x * tile_size) <= 0.01 and abs(vertex[2] - z * tile_size) <= 0.01,
                "vertex order/spacing differs from observed x-major grid")
        length = math.sqrt(sum(value * value for value in vertex[3:]))
        require(0.98 <= length <= 1.02, "source normal is not approximately unit length")
        for axis in range(3):
            minimum[axis] = min(minimum[axis], vertex[axis])
            maximum[axis] = max(maximum[axis], vertex[axis])
    return Terrain(tile_size, side - 1, vertices, object_count, (tuple(minimum), tuple(maximum)))


def parse_project(data: bytes, resource_id: str) -> dict:
    require(64 <= len(data) <= MAX_RESOURCE, "truncated workspace")
    count = struct.unpack_from("<i", data, 60)[0]
    require(0 <= count <= 4096 and 64 + count * 148 == len(data), "workspace project count/size mismatch")
    matches = []
    for index in range(count):
        offset = 64 + index * 148
        if data[offset + 4:offset + 44].split(b"\0", 1)[0] != resource_id.encode("ascii"):
            continue
        sx, sz, maximum, minimum, water = struct.unpack_from("<hh3f", data, offset + 84)
        lighting = struct.unpack_from("<12f", data, offset + 100)
        require(sx > 0 and sz > 0 and all(math.isfinite(v) for v in (maximum, minimum, water, *lighting)), "invalid project dimensions/environment")
        matches.append({"workspace_sha256": sha256(data), "record_index": index, "record_offset": offset,
                        "record_sha256": sha256(data[offset:offset + 148]), "project_name": resource_id,
                        "tile_dimensions": [sx, sz], "editor_height_range": [minimum, maximum], "water_height": water,
                        "diffuse_day": lighting[0:3], "ambient_day": lighting[3:6],
                        "diffuse_night": lighting[6:9], "ambient_night": lighting[9:12],
                        "note": "Only dimensions, water and lighting read. Network fields are not extracted."})
    require(len(matches) == 1, "workspace must identify selected project exactly once")
    return matches[0]


def water_patches(payload: bytes, terrain: Terrain, water_height: float) -> dict:
    tile_offset = 36 + len(terrain.vertices) * VERTEX.size
    side = terrain.tiles + 1
    active = set()
    original_count = 0
    for x in range(terrain.tiles):
        for z in range(terrain.tiles):
            flag = struct.unpack_from("<I", payload, tile_offset + (x * terrain.tiles + z) * TILE_RECORD_SIZE + 4)[0]
            if flag != 1:
                continue
            original_count += 1
            corners = (x * side + z, (x + 1) * side + z, x * side + z + 1, (x + 1) * side + z + 1)
            if any(terrain.vertices[v][1] < water_height for v in corners):
                active.add((x // 2, z // 2))
    return {"height": water_height, "source_flag1_tile_count": original_count, "active_patch_count": len(active),
            "source_patch_size_tiles": 2, "patch_world_size": terrain.tile_size * 2,
            "active_patch_indices_source_xz": sorted(active),
            "formula": "patch(px,pz) covers sourceX=[px*80,(px+1)*80], sourceZ=[pz*80,(pz+1)*80]; apply terrain transform",
            "source_rule": "clear flag1 when all4vertices are >=water; patch2x2 active if any remaining flag1",
            "texture": None, "texture_note": "CurrentMAP_INFO.WaterType not decoded; no water texture association claimed",
            "rendered_in_terrain_glb": False}


def jpeg_dimensions(data: bytes) -> tuple[int, int]:
    require(data.startswith(b"\xff\xd8") and data.endswith(b"\xff\xd9"), "terrain texture is not a complete JPEG")
    offset = 2
    while offset < len(data):
        require(data[offset] == 0xFF, "invalid JPEG marker")
        while offset < len(data) and data[offset] == 0xFF:
            offset += 1
        require(offset < len(data), "truncated JPEG marker")
        marker = data[offset]
        offset += 1
        if marker in (0xD8, 0xD9) or 0xD0 <= marker <= 0xD7:
            continue
        require(offset + 2 <= len(data), "truncated JPEG segment length")
        length = struct.unpack_from(">H", data, offset)[0]
        require(length >= 2 and offset + length <= len(data), "invalid JPEG segment bounds")
        if marker in (0xC0, 0xC1, 0xC2):
            require(length >= 8, "truncated JPEG frame header")
            height, width = struct.unpack_from(">HH", data, offset + 3)
            require(0 < width <= 4096 and 0 < height <= 4096, "JPEG dimensions outside converter policy")
            return width, height
        require(marker != 0xDA, "JPEG scan precedes supported frame header")
        offset += length
    raise FormatError("JPEG has no supported frame header")


def surface_geometry(terrain: Terrain, bx: int, bz: int, block_tiles: int = 64) -> tuple[list, list, list, list]:
    require(0 <= bx * block_tiles and (bx + 1) * block_tiles <= terrain.tiles, "surface X outside terrain")
    require(0 <= bz * block_tiles and (bz + 1) * block_tiles <= terrain.tiles, "surface Z outside terrain")
    side = terrain.tiles + 1
    width = block_tiles + 1
    center = terrain.tiles * terrain.tile_size / 2.0
    positions, normals, uvs, indices = [], [], [], []
    for x in range(width):
        for z in range(width):
            source = terrain.vertices[(bx * block_tiles + x) * side + bz * block_tiles + z]
            positions.append((source[0] - center, source[1], center - source[2]))
            normals.append((source[3], source[4], -source[5]))
            uvs.append((x / block_tiles, 1.0 - z / block_tiles))
    for x in range(block_tiles):
        for z in range(block_tiles):
            a = x * width + z
            b, c, d = a + 1, a + width + 1, a + width
            # Source A,B,C / A,C,D is reversed after the Z reflection so glTF
            # keeps counterclockwise front faces and outward source normals.
            indices.extend((a, c, b, a, d, c))
    return positions, normals, uvs, indices


def sample_height(terrain: Terrain, target_x: float, target_z: float) -> float:
    """Height on the exported visual A-C diagonal, not legacy collision's B-D."""
    center = terrain.tiles * terrain.tile_size / 2.0
    x = (target_x + center) / terrain.tile_size
    z = (center - target_z) / terrain.tile_size
    require(0.0 <= x <= terrain.tiles and 0.0 <= z <= terrain.tiles, "height query outside terrain")
    ix, iz = min(int(x), terrain.tiles - 1), min(int(z), terrain.tiles - 1)
    tx, tz = x - ix, z - iz
    side = terrain.tiles + 1
    a = terrain.vertices[ix * side + iz][1]
    b = terrain.vertices[ix * side + iz + 1][1]
    c = terrain.vertices[(ix + 1) * side + iz + 1][1]
    d = terrain.vertices[(ix + 1) * side + iz][1]
    return a + tz * (b - a) + tx * (c - b) if tz >= tx else a + tx * (d - a) + tz * (c - d)


def export_glb(terrain: Terrain, textures: dict[str, ResourceEntry], destination: Path, resource_id: str = "3002") -> dict:
    require(terrain.tiles == 256, "export profile requires256tiles and16native64-tile textures")
    binary = bytearray()
    doc = {"asset": {"version": "2.0", "generator": "ACE bounded original terrain converter"},
           "scene": 0, "scenes": [{"nodes": [0]}], "nodes": [{"name": "ACE_resource_" + resource_id + "_terrain", "mesh": 0}],
           "meshes": [{"name": "Original_grid", "primitives": []}], "buffers": [], "bufferViews": [],
           "accessors": [], "materials": [], "textures": [], "images": [],
           "samplers": [{"magFilter": 9729, "minFilter": 9987, "wrapS": 33071, "wrapT": 33071}]}

    def add_view(data: bytes, target: int | None = None) -> int:
        binary.extend(b"\0" * ((-len(binary)) % 4))
        view = {"buffer": 0, "byteOffset": len(binary), "byteLength": len(data)}
        if target is not None:
            view["target"] = target
        doc["bufferViews"].append(view)
        binary.extend(data)
        return len(doc["bufferViews"]) - 1

    def accessor(values: list, components: int, kind: str, indices: bool = False) -> int:
        flat = values if indices else [value for row in values for value in row]
        encoded = struct.pack("<" + ("H" if indices else "f") * len(flat), *flat)
        index = len(doc["accessors"])
        record = {"bufferView": add_view(encoded, 34963 if indices else 34962),
                  "componentType": 5123 if indices else 5126, "count": len(values), "type": kind}
        if components == 3:
            record["min"] = [min(row[axis] for row in values) for axis in range(3)]
            record["max"] = [max(row[axis] for row in values) for axis in range(3)]
        doc["accessors"].append(record)
        return index

    surfaces = []
    for bx in range(4):
        for bz in range(4):
            texture_name = "map%02d" % (bx + 4 * (3 - bz))
            require(texture_name in textures, "missing original terrain texture:" + texture_name)
            texture = textures[texture_name]
            dimensions = jpeg_dimensions(texture.data)
            require(dimensions == (512, 512), "observed3002terrain texture profile expects512x512")
            image = len(doc["images"])
            doc["images"].append({"name": texture_name, "mimeType": "image/jpeg", "bufferView": add_view(texture.data)})
            doc["textures"].append({"sampler": 0, "source": image})
            doc["materials"].append({"name": texture_name, "pbrMetallicRoughness": {
                "baseColorTexture": {"index": image}, "metallicFactor": 0.0, "roughnessFactor": 1.0}, "doubleSided": False})
            positions, normals, uvs, triangles = surface_geometry(terrain, bx, bz)
            attributes = {"POSITION": accessor(positions, 3, "VEC3"), "NORMAL": accessor(normals, 3, "VEC3"),
                          "TEXCOORD_0": accessor(uvs, 2, "VEC2")}
            primitive = {"attributes": attributes, "indices": accessor(triangles, 1, "SCALAR", True), "material": image, "mode": 4}
            doc["meshes"][0]["primitives"].append(primitive)
            surfaces.append({"block_x": bx, "block_source_z": bz, "texture_name": texture_name,
                             "texture_sha256": sha256(texture.data), "texture_size": len(texture.data),
                             "texture_dimensions": dimensions, "vertex_count": len(positions), "triangle_count": len(triangles) // 3})
    doc["buffers"] = [{"byteLength": len(binary)}]
    encoded_json = json.dumps(doc, separators=(",", ":"), allow_nan=False).encode()
    encoded_json += b" " * ((-len(encoded_json)) % 4)
    binary.extend(b"\0" * ((-len(binary)) % 4))
    glb = struct.pack("<III", 0x46546C67, 2, 12 + 8 + len(encoded_json) + 8 + len(binary))
    glb += struct.pack("<II", len(encoded_json), 0x4E4F534A) + encoded_json
    glb += struct.pack("<II", len(binary), 0x004E4942) + binary
    destination.write_bytes(glb)
    return {"path": destination.name, "path_root": "metadata_directory", "sha256": sha256(glb), "size": len(glb), "surfaces": surfaces,
            "vertex_count_with_block_seams": sum(s["vertex_count"] for s in surfaces),
            "triangle_count": sum(s["triangle_count"] for s in surfaces)}


def convert(source: Path, destination: Path) -> dict:
    destination.mkdir(parents=True, exist_ok=True)
    for filename, expected in EXPECTED_RESOURCES.items():
        require(sha256((source / filename).read_bytes()) == expected, "observed dataset identity mismatch:" + filename)
    dat_entries, dat_manifest = parse_resource((source / "3002.dat").read_bytes())
    require("3002" in dat_entries, "selected terrain entry3002 is absent")
    terrain = parse_terrain(dat_entries["3002"].data)
    project = parse_project((source / "ms.wok").read_bytes(), "3002")
    require(project["tile_dimensions"] == [terrain.tiles, terrain.tiles], "workspace and selected terrain dimensions disagree")
    map_entries, map_manifest = parse_resource((source / "3002.map").read_bytes())
    geometry = export_glb(terrain, map_entries, destination / "3002_terrain.glb")
    height_bytes = struct.pack("<" + "f" * len(terrain.vertices), *(v[1] for v in terrain.vertices))
    (destination / "3002_heights.f32").write_bytes(height_bytes)
    center = terrain.tiles * terrain.tile_size / 2.0
    route = [(0, 105, 170), (0, 105, -40), (15, 118, -290), (-35, 145, -535),
             (-115, 170, -780), (-30, 205, -1030), (120, 230, -1280), (210, 245, -1540), (110, 270, -1810)]
    samples = [{"target_position": list(p), "visual_terrain_height": sample_height(terrain, p[0], p[2]),
                "clearance": p[1] - sample_height(terrain, p[0], p[2])} for p in route]
    report = {"schema_version": 1, "resource_id": 3002, "display_name": None,
              "identity_note": "3002 is the observed resource/entry identifier; no localized map name or current server mapping is claimed",
              "source_code": {"ep35_commit": SOURCE_SHA, "ep43_commit": EP43_SHA},
              "source_package": {"name": "ACEonline-20250709.7z", "sha256": "8395f1f33dda8165f70f30d2a6ad094c5f64e144403fce98337e5012be795841"},
              "converter": {"filename": Path(__file__).name, "sha256": sha256(Path(__file__).read_bytes()),
                            "profile": "observed original3002resource set; square grid256tiles,64-tile blocks; no variant guessing"},
              "source_evidence": [
                  "EP35 Client/EtcLib/main/GameDataLast.h:15-36; GameDataLast.cpp:325-344:20-byte header/24-byte interleaved entries; loader ignores trailing bytes",
                  "EP35 Client/Common/ObjectDefine.h:619-699:VERTEXINFO,TILEINFOCLIENT,OBJECTINFOCLIENT,MapInfo,WORKSPACE,PROJECTINFO",
                  "EP35 Client/ProjectAtum/main/Background.cpp:323-377; EP43 ProjectAtum/ProjectAtum/main/Background.cpp:388-402:terrain entry prefix20 and arrays",
                  "EP35 andEP43 QuadGround.cpp:105-106,258-269,400-408,849-872:texture block mapping,UVs,normals and render diagonal",
                  "EP35 Background.cpp:384-405,595-629,806-836; EP43 Background.cpp:411-430,666-694:water flag filtering,patches,height",
                  "EP35 Client/ProjectAtum/main/SceneData.cpp:1923-2009,3227-3236:project diffuse/ambient day/night colors",
                  "EP35 Client/Common/AtumGlobal.cpp:1465-1478:water texture requires currentMAP_INFO.WaterType; not inferred fromresourceID"],
              "source_resources": {"dat": dat_manifest, "map": map_manifest}, "geometry": geometry,
              "native_bounds": terrain.native_bounds, "target_bounds": [[-center, terrain.native_bounds[0][1], -center], [center, terrain.native_bounds[1][1], center]],
              "transform": {"formula": "target=(source.x-5120, source.y, 5120-source.z)",
                            "scale": [1, 1, -1], "translation": [-center, 0, center],
                            "normals": "(nx,ny,-nz); original unit normals retained", "winding": "reverse each source triangle after Z reflection; glTF CCW front faces", "node_transform": "identity; conversion baked into vertex buffers"},
              "grid": {"vertex_side": terrain.tiles + 1, "tile_side": terrain.tiles, "tile_size": terrain.tile_size,
                       "heightmap": "3002_heights.f32", "heightmap_sha256": sha256(height_bytes),
                       "heightmap_format": "little-endian float32; source-x-major/source-z-minor; index=ix*257+iz; targetX=ix*40-5120,targetZ=5120-iz*40",
                       "interpolation": "visual A-C diagonal; sample_height in converter. Legacy collision uses other diagonal."},
              "project_environment": project,
              "water": water_patches(dat_entries["3002"].data, terrain, project["water_height"]),
              "training_route_height_samples": samples,
              "omitted": {"object_records": terrain.object_count, "tile_metadata": "bounded24-byte records retained only in source resource; not interpreted",
                          "water": "source geometry patches/height in metadata, but no water material or mesh exported", "sky_clouds": True, "detail_texture": True,
                          "legacy_lighting_fog_LOD": True, "navigation_combat_network": True},
              "compatibility_note": "Original terrain positions, normals and JPEG payloads; new static glTF renderer, not original client runtime."}
    (destination / "3002_terrain.json").write_text(json.dumps(report, ensure_ascii=False, indent=2, allow_nan=False) + "\n")
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    report = convert(args.source, args.output)
    print(json.dumps({"status": "ok", "glb": report["geometry"]["path"], "sha256": report["geometry"]["sha256"],
                      "triangles": report["geometry"]["triangle_count"], "bounds": report["target_bounds"],
                      "training_route_height_samples": report["training_route_height_samples"]}, ensure_ascii=False))


if __name__ == "__main__":
    main()
