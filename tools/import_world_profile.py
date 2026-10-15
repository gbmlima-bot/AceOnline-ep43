#!/usr/bin/env python3
"""Extended bounded source-container profile and exact original terrain export.

Source GameDataLast.cpp reads only declared entries and ignores trailing bytes.
The older converter's 1MiB tail ceiling was an implementation policy. Here all
source files are independently authenticated against the pinned archive CRC and
SHA before parsing; a bounded <=64MiB container may have any remaining opaque
suffix, which is hashed and never interpreted. Texture resolution does not alter
QuadGround's fixed sixteen UV blocks, so native JPEG dimensions are preserved.
"""
import json
import struct
from pathlib import Path
from convert_original_terrain import (Terrain, ResourceEntry, require, sha256,
    HEADER, ENTRY, MAX_RESOURCE, MAX_ENTRIES, jpeg_dimensions, surface_geometry)


def parse_resource(data):
    require(HEADER.size <= len(data) <= MAX_RESOURCE, "resource size outside64MiB bounded profile")
    encode, identification, declared, count, parity = HEADER.unpack_from(data)
    require((encode, identification) == (1000,1000), "unsupported plain resource profile")
    require(0 <= count <= MAX_ENTRIES, "invalid resource entry count")
    offset = HEADER.size
    entries, records = {}, []
    for index in range(count):
        require(offset + ENTRY.size <= len(data), "truncated entry header")
        identifier, length, entry_parity, raw_name, padding = ENTRY.unpack_from(data, offset)
        offset += ENTRY.size
        require(0 <= length <= len(data)-offset, "invalid payload length")
        name = raw_name.split(b"\0",1)[0].decode("ascii")
        require(bool(name) and name not in entries, "empty or duplicate resource entry")
        payload = data[offset:offset+length]
        entries[name] = ResourceEntry(name, identifier, offset, payload)
        records.append({"index":index,"name":name,"identifier":identifier,"offset":offset,"size":length,"sha256":sha256(payload),"parity":entry_parity,"raw_name_hex":raw_name.hex(),"padding_hex":padding.hex()})
        offset += length
    tail = data[offset:]
    return entries, {"size":len(data),"sha256":sha256(data),"header":{"encode":encode,"identification":identification,"declared_payload_size":declared,"entry_count":count,"parity":parity},"entries":records,"opaque_trailing":{"offset":offset,"size":len(tail),"sha256":sha256(tail),"meaning":"not interpreted; source loader reads only declared entries"}}


def export_glb(terrain: Terrain, textures: dict[str, ResourceEntry], destination: Path, resource_id: str = "3002") -> dict:
    require(terrain.tiles == 256, "export profile requires256tiles and16native64-tile textures")
    binary = bytearray()
    doc = {"asset": {"version": "2.0", "generator": "ACE source terrain converter, variable native JPEG resolution"},
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
            require(all(0 < value <= 4096 for value in dimensions), "texture dimensions outside bounded source profile")
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

