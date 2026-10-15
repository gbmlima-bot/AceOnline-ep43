#!/usr/bin/env python3
"""Import every bounded MEX actor referenced by the pinned original client.

No original executable is run. Native CGameData payloads, textures, skins and
bind poses pass through the existing Assimp actor converter. Unavailable packs
and unsupported models remain explicit unavailable entries in the registry.
"""
from __future__ import annotations

import argparse
from concurrent.futures import ProcessPoolExecutor, as_completed
import hashlib
import json
import math
from pathlib import Path
import struct
import ctypes
import sys
import traceback
import io
import re

import numpy as np
import pyassimp.core as assimp_core
import pyassimp.structs as assimp_structs
from PIL import Image
import convert_original_terrain as terrain_format

from convert_complete_props import unpack
from convert_original_actor import convert
from validate_original_data_assets import validate_glb


ARCHIVE_SHA = "8395f1f33dda8165f70f30d2a6ad094c5f64e144403fce98337e5012be795841"


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def read_glb(path: Path):
    data = path.read_bytes()
    if len(data) < 28 or data[:4] != b"glTF" or struct.unpack_from("<II", data, 4) != (2, len(data)):
        raise ValueError("Invalid GLB header")
    size = struct.unpack_from("<I", data, 12)[0]
    if data[16:20] != b"JSON" or data[24 + size:28 + size] != b"BIN\0":
        raise ValueError("Unsupported GLB chunks")
    doc = json.loads(data[20:20 + size])
    return doc, bytearray(data[28 + size:])


def write_glb(path: Path, doc: dict, binary: bytearray):
    raw = json.dumps(doc, separators=(",", ":"), ensure_ascii=False, allow_nan=False).encode()
    raw += b" " * (-len(raw) % 4)
    binary.extend(b"\0" * (-len(binary) % 4))
    data = struct.pack("<4sII", b"glTF", 2, 28 + len(raw) + len(binary))
    data += struct.pack("<I4s", len(raw), b"JSON") + raw
    data += struct.pack("<I4s", len(binary), b"BIN\0") + binary
    path.write_bytes(data)
    return sha(data)


def accessor_arrays(doc, binary):
    arrays = []
    for item in doc["accessors"]:
        view = doc["bufferViews"][item["bufferView"]]
        if "byteStride" in view or "sparse" in item:
            raise ValueError("Unsupported strided/sparse exported accessor")
        width = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}[item["type"]]
        dtype = {5126: "<f4", 5125: "<u4", 5123: "<u2", 5121: "u1"}[item["componentType"]]
        offset = view.get("byteOffset", 0) + item.get("byteOffset", 0)
        length = item["count"] * width * np.dtype(dtype).itemsize
        if not 0 <= offset <= offset + length <= len(binary):
            raise ValueError("Accessor outside GLB binary")
        array = np.frombuffer(binary, dtype=dtype, count=item["count"] * width, offset=offset).reshape((-1, width))
        if not np.isfinite(array).all():
            raise ValueError("Nonfinite exported accessor")
        arrays.append(array)
    return arrays


def node_matrix(node):
    if "matrix" in node:
        matrix = np.asarray(node["matrix"], dtype=np.float64).reshape((4, 4), order="F")
    else:
        x, y, z, w = node.get("rotation", [0, 0, 0, 1])
        if abs(x*x + y*y + z*z + w*w - 1) > .002:
            raise ValueError("Nonunit exported node quaternion")
        rotation = np.array([[1-2*y*y-2*z*z, 2*x*y-2*z*w, 2*x*z+2*y*w],
                             [2*x*y+2*z*w, 1-2*x*x-2*z*z, 2*y*z-2*x*w],
                             [2*x*z-2*y*w, 2*y*z+2*x*w, 1-2*x*x-2*y*y]])
        matrix = np.eye(4)
        matrix[:3, :3] = rotation @ np.diag(node.get("scale", [1, 1, 1]))
        matrix[:3, 3] = node.get("translation", [0, 0, 0])
    if not np.isfinite(matrix).all():
        raise ValueError("Nonfinite node matrix")
    return matrix


def restore_native_matrices(doc, source_path):
    """Keep affine shear discarded by the glTF exporter's TRS decomposition.

    Only the stable aiScene/aiNode prefix is accessed. pyassimp's bone wrapper
    is deliberately bypassed; the Assimp exporter preserves the actual skin.
    """
    handle = assimp_core._assimp_lib.load(str(source_path).encode(), 0)
    if not handle:
        raise ValueError("Cannot import native actor hierarchy")
    bindings = []
    replaced = 0
    try:
        root_indices=doc["scenes"][doc.get("scene",0)]["nodes"]
        if len(root_indices)!=1:
            raise ValueError("Expected single actor heading root")
        heading=doc["nodes"][root_indices[0]]
        if heading.get("name")!="Original_actor_heading_normalization" or len(heading.get("children",[]))!=1:
            raise ValueError("Expected converter heading normalization parent")
        def visit(pointer, exported_index, depth=0):
            nonlocal replaced
            if depth > 256:
                raise ValueError("Native actor hierarchy too deep")
            node = pointer.contents
            name = node.mName.data.decode("utf-8", "surrogateescape")
            values = [getattr(node.mTransformation, field) for field, _ in node.mTransformation._fields_]
            matrix = np.asarray(values, dtype=np.float64).reshape((4, 4))
            if not np.isfinite(matrix).all():
                raise ValueError("Nonfinite native node transform")
            exported=doc["nodes"][exported_index]
            children=exported.get("children",[])
            if len(children)!=node.mNumChildren:
                raise ValueError("Exporter hierarchy child count differs from source")
            for field in ("translation","rotation","scale"):
                exported.pop(field,None)
            exported["matrix"]=matrix.flatten(order="F").tolist()
            exported.setdefault("extras",{})["native_source_node_name"]=name
            replaced+=1
            if node.mNumMeshes:
                if "mesh" not in exported or len(doc["meshes"][exported["mesh"]]["primitives"])!=node.mNumMeshes:
                    raise ValueError("Exporter mesh primitive count differs from native node")
                for primitive in range(node.mNumMeshes):
                    bindings.append({"native_mesh_index":node.mMeshes[primitive],"exported_mesh_index":exported["mesh"],
                                     "primitive_index":primitive,"exported_node_index":exported_index})
            for index in range(node.mNumChildren):
                visit(node.mChildren[index],children[index],depth+1)
        visit(handle.contents.mRootNode,heading["children"][0])
    finally:
        assimp_core._assimp_lib.release(handle)
    removed = len(doc.pop("animations", []))
    return {"native_affine_matrices_restored": replaced,"mesh_bindings":bindings,"additional_animation_tracks_omitted": removed,
            "reason": "Original affine node matrices retained, including shear; static bind pose avoids invalid TRS animation of matrix nodes."}


class Bone543(ctypes.Structure):
    """Assimp5.4 aiBone ABI including armature/node before weights."""
    _fields_ = [("mName", assimp_structs.String), ("mNumWeights", ctypes.c_uint),
                ("mArmature", ctypes.c_void_p), ("mNode", ctypes.c_void_p),
                ("mWeights", ctypes.POINTER(assimp_structs.VertexWeight)),
                ("mOffsetMatrix", assimp_structs.Matrix4x4)]


def append_accessor(doc, binary, array, kind, component):
    value = np.ascontiguousarray(array, dtype={5126:"<f4",5123:"<u2",5125:"<u4"}[component])
    binary.extend(b"\0" * (-len(binary) % 4))
    view = len(doc["bufferViews"])
    doc["bufferViews"].append({"buffer":0,"byteOffset":len(binary),"byteLength":value.nbytes,"target":34963 if component==5125 else 34962})
    binary.extend(value.tobytes())
    index = len(doc["accessors"])
    doc["accessors"].append({"bufferView":view,"componentType":component,"count":len(value),"type":kind})
    doc["buffers"][0]["byteLength"] = len(binary)
    return index


def restore_native_weights(doc, binary, source_path, bindings):
    """Assimp glTF exporter emits four influences; retain up to eight originals."""
    # Match Assimp CLI glTF export's vertex joining and triangulation.
    handle = assimp_core._assimp_lib.load(str(source_path).encode(), 10)
    if not handle:
        raise ValueError("Cannot import original actor weights")
    policy = {"native_skin_meshes":0,"maximum_original_influences":0,"vertices_with_more_than_four_influences":0,
              "maximum_original_weight_sum_correction":0.0,"policy":"All original influences retained up to8; only final sum normalized for glTF."}
    try:
        scene = handle.contents
        arrays = [array.copy() for array in accessor_arrays(doc, binary)]
        for binding in bindings:
            mesh = scene.mMeshes[binding["native_mesh_index"]].contents
            primitive = doc["meshes"][binding["exported_mesh_index"]]["primitives"][binding["primitive_index"]]
            source_positions = np.asarray([[mesh.mVertices[i].x,mesh.mVertices[i].y,mesh.mVertices[i].z] for i in range(mesh.mNumVertices)])
            positions = arrays[primitive["attributes"]["POSITION"]]
            if source_positions.shape != positions.shape or not np.allclose(source_positions,positions,rtol=0,atol=1e-5):
                raise ValueError("Native/exported vertex ordering mismatch")
            if not mesh.mNumBones:
                continue
            skin_node=doc["nodes"][binding["exported_node_index"]]
            if "skin" not in skin_node:
                raise ValueError("Skinned native mesh lacks exported skin")
            skin = doc["skins"][skin_node["skin"]]
            joint_names = {doc["nodes"][joint].get("extras",{}).get("native_source_node_name",doc["nodes"][joint]["name"]):number for number,joint in enumerate(skin["joints"])}
            influences = [[] for _ in range(mesh.mNumVertices)]
            bones = ctypes.cast(mesh.mBones,ctypes.POINTER(ctypes.POINTER(Bone543)))
            for bone_index in range(mesh.mNumBones):
                bone = bones[bone_index].contents
                name = bone.mName.data.decode("utf-8","surrogateescape")
                if name not in joint_names or bone.mNumWeights > mesh.mNumVertices or not bone.mWeights:
                    raise ValueError("Unexpected native Assimp bone profile")
                for k in range(bone.mNumWeights):
                    weight = bone.mWeights[k]
                    if not 0 <= weight.mVertexId < mesh.mNumVertices or not math.isfinite(weight.mWeight) or weight.mWeight < 0:
                        raise ValueError("Invalid original skin weight")
                    if weight.mWeight:
                        influences[weight.mVertexId].append((joint_names[name],weight.mWeight))
            maximum = max(map(len,influences))
            if maximum > 8 or min(map(len,influences)) == 0:
                raise ValueError("Native skin has more than8influences or unweighted vertices")
            joints = np.zeros((mesh.mNumVertices,8),dtype="<u2")
            weights = np.zeros((mesh.mNumVertices,8),dtype="<f4")
            for vertex, values in enumerate(influences):
                for column,(joint,weight) in enumerate(sorted(values,key=lambda v:(-v[1],v[0]))):
                    joints[vertex,column]=joint;weights[vertex,column]=weight
            sums=weights.sum(axis=1)
            correction=float(abs(sums-1).max())
            if correction > .05:
                raise ValueError("Native source skin sum differs from1 by more than5percent")
            weights /= sums[:,None]
            for channel in range(2 if maximum>4 else 1):
                columns=slice(channel*4,channel*4+4)
                primitive["attributes"]["JOINTS_"+str(channel)] = append_accessor(doc,binary,joints[:,columns],"VEC4",5123)
                primitive["attributes"]["WEIGHTS_"+str(channel)] = append_accessor(doc,binary,weights[:,columns],"VEC4",5126)
            policy["native_skin_meshes"]+=1
            policy["maximum_original_influences"]=max(policy["maximum_original_influences"],maximum)
            policy["vertices_with_more_than_four_influences"]+=sum(len(v)>4 for v in influences)
            policy["maximum_original_weight_sum_correction"]=max(policy["maximum_original_weight_sum_correction"],correction)
        return policy
    finally:
        assimp_core._assimp_lib.release(handle)


def standardize_vertex_attributes(doc, binary):
    """Normalize direction/weight data explicitly for valid glTF, with bounds."""
    arrays = accessor_arrays(doc, binary)
    changes = {"normalized_normals": 0, "geometric_normals_for_source_zero": 0,
               "normalized_skin_weight_vertices": 0, "maximum_skin_weight_sum_correction": 0.0}
    for mesh in doc["meshes"]:
        for primitive in mesh["primitives"]:
            attributes = primitive["attributes"]
            normals = arrays[attributes["NORMAL"]]
            lengths = np.linalg.norm(normals, axis=1)
            zero = lengths < 1e-10
            if zero.any():
                positions = arrays[attributes["POSITION"]]
                faces = arrays[primitive["indices"]].astype(np.uint32).reshape((-1,3))
                geometric = np.cross(positions[faces[:,1]]-positions[faces[:,0]], positions[faces[:,2]]-positions[faces[:,0]])
                weighted = np.zeros_like(normals)
                for corner in range(3):
                    np.add.at(weighted, faces[:,corner], geometric)
                normals[zero] = weighted[zero]
                lengths = np.linalg.norm(normals, axis=1)
                changes["geometric_normals_for_source_zero"] += int(zero.sum())
            if (lengths < 1e-10).any():
                raise ValueError("Source zero normal has no nondegenerate adjacent triangle")
            changed = abs(lengths-1) > 1e-5
            changes["normalized_normals"] += int(changed.sum())
            normals[:] /= lengths[:,None]
            if "WEIGHTS_0" in attributes:
                weights = arrays[attributes["WEIGHTS_0"]]
                sums = weights.sum(axis=1)
                if "WEIGHTS_1" in attributes:
                    sums += arrays[attributes["WEIGHTS_1"]].sum(axis=1)
                drift = float(abs(sums-1).max())
                if drift > .05 or (weights < 0).any():
                    raise ValueError("Source skin weights require unsupported correction greater than5percent")
                changes["maximum_skin_weight_sum_correction"] = max(changes["maximum_skin_weight_sum_correction"], drift)
                changes["normalized_skin_weight_vertices"] += int((abs(sums-1)>1e-5).sum())
                weights[:] /= sums[:,None]
                if "WEIGHTS_1" in attributes:
                    arrays[attributes["WEIGHTS_1"]][:] /= sums[:,None]
    return changes


def omit_invisible_degenerate_geometry(doc,binary):
    """Omit zero-area faces only when they prevent a valid source normal.

    No visible triangle or source texture changes. Remaining attributes,
    including original skin influences, are remapped together.
    """
    arrays=[array.copy() for array in accessor_arrays(doc,binary)]
    policy={"removed_zero_area_faces":0,"removed_unreferenced_vertices":0}
    for mesh in doc["meshes"]:
        for primitive in mesh["primitives"]:
            attributes=primitive["attributes"]
            positions=arrays[attributes["POSITION"]];normals=arrays[attributes["NORMAL"]]
            zeros=np.linalg.norm(normals,axis=1)<1e-10
            if not zeros.any():continue
            faces=arrays[primitive["indices"]].astype(np.uint32).reshape((-1,3))
            area=np.linalg.norm(np.cross(positions[faces[:,1]]-positions[faces[:,0]],positions[faces[:,2]]-positions[faces[:,0]]),axis=1)
            degenerate=area<1e-10
            impossible=[vertex for vertex in np.where(zeros)[0] if not ((faces==vertex).any(axis=1)&~degenerate).any()]
            if not impossible:continue
            kept=faces[~degenerate]
            if not len(kept):raise ValueError("Native mesh contains no visible triangle")
            used=np.unique(kept);mapping=np.full(len(positions),-1,dtype=np.int64);mapping[used]=np.arange(len(used))
            for name,index in list(attributes.items()):
                value=arrays[index]
                if len(value)!=len(positions):raise ValueError("Vertex attribute count mismatch")
                accessor=doc["accessors"][index]
                attributes[name]=append_accessor(doc,binary,value[used],accessor["type"],accessor["componentType"])
            primitive["indices"]=append_accessor(doc,binary,mapping[kept].astype("<u4").reshape((-1,1)),"SCALAR",5125)
            policy["removed_zero_area_faces"]+=int(degenerate.sum())
            policy["removed_unreferenced_vertices"]+=len(positions)-len(used)
    return policy


def unpack_actor(pack,destination):
    # This one pinned resource contains a large opaque appendix. Native
    # CGameData stops at the declared entry count; no appendix bytes interpreted.
    known_appendix="8ae6d4d6ad6da3e5f1126c3b007e3e85b9c709618aeeab68cca00b875ee65262"
    if sha(pack.read_bytes())!=known_appendix:
        return unpack(pack,destination)
    previous=terrain_format.MAX_TRAILING
    try:
        terrain_format.MAX_TRAILING=2*1024*1024
        manifest=unpack(pack,destination)
        manifest["pinned_appendix_policy"]="Native loader ignores appendix after declared entries; known source SHA admits up to2MiB opaque tail."
        return manifest
    finally:
        terrain_format.MAX_TRAILING=previous


def omit_empty_x_meshes(raw):
    """Remove native text Mesh{0;...} records containing no visible geometry.

    Assimp rejects the native empty-array spelling `0; ; 0; ;`. Frames, skin
    data of real meshes and all nonempty vertices remain byte-for-byte intact.
    """
    if raw[:16]!=b"xof 0303txt 0032":
        return raw,0
    matches=list(re.finditer(rb"\bMesh(?:\s+[A-Za-z0-9_]+)?\s*\{\s*0\s*;",raw))
    spans=[]
    for match in matches:
        start=raw.find(b"{",match.start(),match.end());depth=1;offset=start+1;quoted=False
        while offset<len(raw) and depth:
            value=raw[offset]
            if quoted:
                if value==92:offset+=2;continue
                if value==34:quoted=False
            elif value==34:quoted=True
            elif raw[offset:offset+2]==b"//":
                end=raw.find(b"\n",offset+2);offset=len(raw) if end<0 else end;continue
            elif raw[offset:offset+2]==b"/*":
                end=raw.find(b"*/",offset+2)
                if end<0:raise ValueError("Unterminated X comment")
                offset=end+2;continue
            elif value==123:depth+=1
            elif value==125:depth-=1
            offset+=1
        if depth:raise ValueError("Unterminated empty X mesh")
        # A zero-vertex Mesh can have only zero faces. Reject an unexpected
        # nonzero count rather than removing meaningful invalid geometry.
        prefix=raw[start+1:match.end()]
        rest=raw[match.end():offset]
        if not re.match(rb"\s*;\s*0\s*;",rest):
            raise ValueError("Zero-vertex native mesh has unsupported face array")
        spans.append((match.start(),offset))
    output=bytearray(raw)
    for start,end in reversed(spans):output[start:end]=b"\n// Empty original mesh omitted; no vertices or faces.\n"
    return bytes(output),len(spans)


def bind_pose_bounds(doc, binary):
    """Evaluate glTF skin joint matrices, rather than treating mesh-local as world."""
    arrays = accessor_arrays(doc, binary)
    nodes = doc["nodes"]
    worlds = {}

    def walk(index, parent, stack):
        if index in stack or index in worlds or len(stack) > 256 or not 0 <= index < len(nodes):
            raise ValueError("Invalid scene hierarchy")
        matrix = parent @ node_matrix(nodes[index])
        worlds[index] = matrix
        for child in nodes[index].get("children", []):
            walk(child, matrix, stack | {index})

    for index in doc["scenes"][doc.get("scene", 0)]["nodes"]:
        walk(index, np.eye(4), set())
    minimum = np.full(3, math.inf); maximum = np.full(3, -math.inf)
    positions_count = 0
    for index, matrix in worlds.items():
        node = nodes[index]
        if "mesh" not in node:
            continue
        for primitive in doc["meshes"][node["mesh"]]["primitives"]:
            attributes = primitive["attributes"]
            positions = arrays[attributes["POSITION"]].astype(np.float64)
            points = np.column_stack((positions, np.ones(len(positions))))
            if "skin" in node:
                skin = doc["skins"][node["skin"]]
                joints = arrays[attributes["JOINTS_0"]].astype(np.uint32)
                weights = arrays[attributes["WEIGHTS_0"]]
                if "JOINTS_1" in attributes:
                    joints = np.column_stack((joints,arrays[attributes["JOINTS_1"]].astype(np.uint32)))
                    weights = np.column_stack((weights,arrays[attributes["WEIGHTS_1"]]))
                if joints.max() >= len(skin["joints"]) or abs(weights.sum(axis=1)-1).max() > .001:
                    raise ValueError("Invalid skin joints or weights")
                inverse = arrays[skin["inverseBindMatrices"]]
                palette = np.asarray([worlds[j] @ inverse[n].reshape((4, 4), order="F") for n, j in enumerate(skin["joints"])])
                transformed = np.zeros_like(points)
                for column in range(weights.shape[1]):
                    transformed += np.einsum("nij,nj->ni", palette[joints[:, column]], points) * weights[:, column, None]
            else:
                transformed = (matrix @ points.T).T
            if not np.isfinite(transformed).all():
                raise ValueError("Nonfinite evaluated bind pose")
            minimum = np.minimum(minimum, transformed[:, :3].min(axis=0))
            maximum = np.maximum(maximum, transformed[:, :3].max(axis=0))
            positions_count += len(positions)
    if positions_count == 0 or not np.isfinite(minimum).all() or np.max(np.abs([minimum, maximum])) > 1e8:
        raise ValueError("Empty or unsupported actor bounds")
    return {"min": minimum.tolist(), "max": maximum.tolist(), "size": (maximum-minimum).tolist(),
            "center": ((maximum+minimum)*.5).tolist(), "method": "Evaluated glTF world bind pose including weighted skin matrices"}


def validate_actor_glb(path):
    """Validate both four- and eight-influence skins and embedded source images."""
    doc,binary=read_glb(path)
    arrays=accessor_arrays(doc,binary)
    if any("uri" in item for item in doc.get("images",[])+doc["buffers"]):
        raise ValueError("Actor GLB must be self contained")
    triangles=0;normal_error=0.0
    for mesh in doc["meshes"]:
        for primitive in mesh["primitives"]:
            attributes=primitive["attributes"]
            positions=arrays[attributes["POSITION"]]
            indices=arrays[primitive["indices"]].reshape(-1)
            if len(indices)%3 or indices.max()>=len(positions):
                raise ValueError("Actor indices outside geometry")
            triangles+=len(indices)//3
            error=float(abs(np.linalg.norm(arrays[attributes["NORMAL"]],axis=1)-1).max())
            normal_error=max(normal_error,error)
            if error>.025:
                raise ValueError("Actor normals are not unit length")
            if "WEIGHTS_0" in attributes:
                weights=arrays[attributes["WEIGHTS_0"]].sum(axis=1)
                if "WEIGHTS_1" in attributes:
                    weights+=arrays[attributes["WEIGHTS_1"]].sum(axis=1)
                if abs(weights-1).max()>.001:
                    raise ValueError("Actor skin weights do not sum to1")
    images=[]
    for item in doc["images"]:
        view=doc["bufferViews"][item["bufferView"]];offset=view.get("byteOffset",0)
        raw=binary[offset:offset+view["byteLength"]]
        with Image.open(io.BytesIO(raw)) as image:
            image.load();images.append({"name":item.get("name"),"dimensions":list(image.size),"decoded_rgba_sha256":sha(image.convert("RGBA").tobytes())})
    bounds=bind_pose_bounds(doc,binary)
    return {"path":str(path),"sha256":sha(path.read_bytes()),"triangles":triangles,"images":images,
            "accessors_finite":True,"indices_in_bounds":True,"self_contained":True,"maximum_normal_length_error":normal_error,
            "skin_weights_valid":True,"bounds":bounds}


def import_source(job):
    code, texture_index, alpha_values, source, stage, output, reports = job
    source, stage, output, reports = map(Path, (source, stage, output, reports))
    try:
        manifest = unpack_actor(source / f"{code:08d}.obj", stage / f"{code:08d}")
        source_model=next(e for e in manifest["entries"] if e["kind"]=="model")
        original_x_sha=source_model["source_sha256"]
        raw=Path(source_model["path"]).read_bytes();filtered,omitted_empty=omit_empty_x_meshes(raw)
        if omitted_empty:
            filtered_path=Path(source_model["path"]).with_name(f"{code:08d}-without-empty-meshes.x")
            filtered_path.write_bytes(filtered)
            source_model.update(path=str(filtered_path),source_sha256=sha(filtered),size=len(filtered),
                                original_payload_sha256=original_x_sha,empty_meshes_omitted=omitted_empty)
            (stage/f"{code:08d}"/"manifest.json").write_text(json.dumps(manifest,indent=2)+"\n")
        name = f"{code:08d}_t{texture_index}"
        initial = output / (name + "_a1.glb")
        report = convert(stage / f"{code:08d}", initial, reports, code, texture_index)
        doc, binary = read_glb(initial)
        model_entry = next(e for e in manifest["entries"] if e["kind"] == "model")
        matrix_policy = restore_native_matrices(doc, Path(model_entry["path"]))
        weight_policy = restore_native_weights(doc, binary, Path(model_entry["path"]),matrix_policy["mesh_bindings"])
        degenerate_policy=omit_invisible_degenerate_geometry(doc,binary)
        attribute_policy = standardize_vertex_attributes(doc, binary)
        # MonRender overrides all material textures with TextureIndex through
        # AnotherTexture. Force this even if a stale X material had no filename.
        doc["textures"] = [{"source": 0, "sampler": 0}]
        doc["samplers"] = [{"magFilter": 9729, "minFilter": 9987, "wrapS": 10497, "wrapT": 10497}]
        for material in doc.get("materials", []):
            material.setdefault("pbrMetallicRoughness", {})["baseColorTexture"] = {"index": 0}
            material.setdefault("extras", {})["source_texture_selection"] = "MonRender.cpp:188,194 native AnotherTexture(TextureIndex); sorted CGameData image order, not stale X filename."
        bounds = bind_pose_bounds(doc, binary)
        results = []
        for alpha in alpha_values:
            for material in doc.get("materials", []):
                material["alphaMode"] = "BLEND" if alpha else "OPAQUE"
                material["extras"]["source_alpha_policy"] = {"enabled": bool(alpha), "threshold_uint8": 8 if alpha else None,
                    "blend": "SRCALPHA/INVSRCALPHA" if alpha else "disabled", "evidence": "EP35 MonRender.cpp:149-164",
                    "limitation": "glTF BLEND alone does not encode the simultaneous native alpha>=8 test."}
            target = output / f"{name}_a{alpha}.glb"
            digest = write_glb(target, doc, bytearray(binary))
            verification = validate_actor_glb(target)
            if verification["images"][0]["decoded_rgba_sha256"] != report["texture"]["decoded_rgba_sha256"]:
                raise ValueError("Embedded texture differs from original decoded pixels")
            row = {"role": "monster", "source_code": code, "texture_index": texture_index, "alpha_blending": bool(alpha),
                   "available": True, "filename": target.name, "scene_path": "res://assets/original_library/actors/" + target.name,
                   "resource_path": "res://assets/original_library/actors/" + target.name, "sha256": digest, "bytes": target.stat().st_size,
                   "bounds": bounds, "aabb": bounds, "triangles": verification["triangles"], "scale": 1.0, "rotation_degrees": [0,0,0],
                   "source_pack": "Res-obj/" + f"{code:08d}.obj", "source_pack_sha256": report["source_pack_sha256"],
                   "source_x_sha256": original_x_sha,"converted_x_sha256":report["source_x_sha256"],
                   "empty_native_meshes_omitted":omitted_empty,"texture": report["texture"],
                   "skin_count": report["skin_count"], "skin_joint_counts": report["skin_joint_counts"],
                   "orientation": report["orientation"], "source_animation_count": report["source_animation_count"],
                   "animation_tracks_exported": len(doc.get("animations", [])), "native_matrix_policy": matrix_policy,
                   "vertex_attribute_policy": attribute_policy, "native_weight_policy":weight_policy,"degenerate_geometry_policy":degenerate_policy,
                   "omitted_nonfinite_animation_samplers": report["omitted_nonfinite_animation_samplers"],
                   "source_container": manifest["container"], "validation": verification,
                   "unit_note": "Original model units. Apply each MEX ScaleValue at runtime; no assumed physical meters.",
                   "animation_note": "Original static bind pose and skin retained with exact affine node matrices. Animation omitted; no tick rate or motion invented."}
            results.append(row)
        if 1 not in alpha_values and initial.exists():
            initial.unlink()
        return {"source_code": code, "ok": True, "models": results}
    except Exception as exc:
        for path in output.glob(f"{code:08d}_t{texture_index}_a*.glb"):
            path.unlink()
        return {"source_code": code, "ok": False, "models": [], "error": type(exc).__name__ + ": " + str(exc),
                "traceback": traceback.format_exc()}


def registry(rows, results, failures, complete, source):
    models = [m for result in results for m in result["models"]]
    by_variant = {(m["source_code"], m["texture_index"], int(m["alpha_blending"])): m for m in models}
    by_monster = {}
    unavailable = []
    for row in rows:
        key = (row["SourceIndex"], row["TextureIndex"], row["AlphaBlending"])
        code = str(row["MonsterUnitKind"])
        if key in by_variant:
            entry = by_variant[key]
            entry.setdefault("monster_codes", []).append(row["MonsterUnitKind"])
            by_monster[code] = {"source_code": row["SourceIndex"], "scene_path": entry["scene_path"],
                                "resource_path": entry["resource_path"], "scale": row["ScaleValue"],
                                "bounds": entry["bounds"], "texture_index": row["TextureIndex"],
                                "alpha_blending": bool(row["AlphaBlending"]), "available": True,
                                "native_level": row["Level"], "native_hp": row["HP"], "native_size": row["Size"],
                                "source_record_sha256": row["_source"]["sha256"]}
        else:
            reason = failures.get(row["SourceIndex"], "conversion_pending")
            unavailable.append({"monster_code": row["MonsterUnitKind"], "source_code": row["SourceIndex"], "reason": reason})
    for model in models:
        model["monster_codes"] = sorted(set(model.get("monster_codes", [])))
    by_source = {}
    for model in models:
        by_source.setdefault(str(model["source_code"]), []).append({k: model[k] for k in ("scene_path", "texture_index", "alpha_blending", "sha256", "bounds")})
    return {"schema_version": 1, "complete": complete, "source": source, "record_count": len(rows),
            "unique_source_count": len({r["SourceIndex"] for r in rows}), "model_count": len(models),
            "available_monster_count": len(by_monster), "by_monster_code": by_monster, "by_source_index": by_source,
            "models": sorted(models, key=lambda m:(m["source_code"],m["texture_index"],m["alpha_blending"])),
            "unavailable": unavailable, "limitations": ["Client appearance and HP/level do not provide native server spawn locations, defense, AI or weapons.",
                "Animations with nonfinite exporter timing are omitted explicitly; valid skins and original bind poses are retained.",
                "PBR lighting and glTF BLEND are approximations of DirectX Phong and simultaneous alpha test/blend."]}


def import_gear_source(job):
    result=import_source(job)
    if not result["ok"]:
        return result
    try:
        for row in result["models"]:
            old=Path(job[5])/row["filename"]
            doc,binary=read_glb(old)
            for material in doc["materials"]:
                material["alphaMode"]="MASK";material["alphaCutoff"]=1/255
                material["extras"]["source_alpha_policy"]={"enabled":True,"threshold_uint8":1,
                    "blend":"disabled","evidence":"EP35 UnitRender.cpp:163,182-184"}
                material["extras"]["source_texture_selection"]="UnitRender.cpp:176,210 and SkinnedMesh.cpp:2613-2620: default armor color selects first native texture. Additional color textures and multi-texture glow are not baked."
            target=old.parent/f"{job[0]:08d}.glb"
            digest=write_glb(target,doc,binary)
            old.unlink()
            validation=validate_actor_glb(target)
            row.update(role="gear_appearance",filename=target.name,model_id=job[0],native_source_index=job[0]-4000000,
                scene_path="res://assets/original_library/gears/"+target.name,resource_path="res://assets/original_library/gears/"+target.name,
                sha256=digest,bytes=target.stat().st_size,validation=validation,
                render_policy={"alpha_test_uint8":1,"blend":False,"native_default_texture_index":1,
                    "additional_layers":"Original multi-texture glow, alternative armor colors and descriptor effects are not baked."},
                binding_evidence="EP35 Common/AtumGlobal.cpp:1402-1463 GetUnitNum degree2: model_id=12000000+(ITEM.SourceIndex-8000000).")
            row.pop("alpha_blending",None)
        return result
    except Exception as exc:
        return {"source_code":job[0],"ok":False,"models":[],"error":type(exc).__name__+": "+str(exc),"traceback":traceback.format_exc()}


def import_gears(args):
    catalog=json.loads(args.items.read_text())
    rows=[row for row in catalog["records"] if row["Kind"]==16]
    if len(rows)!=7980:
        raise ValueError("Unknown native armor item catalog")
    grouped={}
    for row in rows:
        if not 8000000<=row["SourceIndex"]<9000000:
            raise ValueError("Armor SourceIndex outside proven native profile")
        grouped.setdefault(row["SourceIndex"]+4000000,[]).append(row)
    args.output.mkdir(parents=True,exist_ok=True);args.reports.mkdir(parents=True,exist_ok=True)
    failures={};jobs=[]
    for code in sorted(grouped):
        if not(args.source/f"{code:08d}.obj").is_file():
            failures[code]="source_pack_missing_from_original_archive"
        else:
            jobs.append((code,1,[0],str(args.source),str(args.stage),str(args.output),str(args.reports)))
    if args.limit:jobs=jobs[:args.limit]
    results=[]
    gear_masks={15:"B-GEAR",240:"M-GEAR",3840:"A-GEAR",61440:"I-GEAR",61695:"B/M/I-GEAR"}
    def publish(complete=False):
        models=[model for result in results for model in result["models"]]
        by_code={row["model_id"]:row for row in models}
        by_item={};unavailable=[]
        for code,items in grouped.items():
            for item in items:
                if code in by_code:
                    model=by_code[code]
                    by_item[str(item["ItemNum"]) ]={"available":True,"model_id":code,"native_source_index":item["SourceIndex"],
                        "scene_path":model["scene_path"],"resource_path":model["scene_path"],"gear_class":gear_masks.get(item["ReqUnitKind"],"unknown"),
                        "req_unit_kind":item["ReqUnitKind"],"name":item["ItemName"],"scale":1.0,"bounds":model["bounds"]}
                else:
                    unavailable.append({"item_num":item["ItemNum"],"native_source_index":item["SourceIndex"],"model_id":code,
                                        "reason":failures.get(code,"conversion_pending")})
        for model in models:
            model["item_nums"]=sorted(item["ItemNum"] for item in grouped[model["model_id"]])
            model["gear_classes"]=sorted(set(gear_masks.get(item["ReqUnitKind"],"unknown") for item in grouped[model["model_id"]]))
            model["unit_kind_mask"]=0
            for item in grouped[model["model_id"]]:
                model["unit_kind_mask"] |= item["ReqUnitKind"]
        payload={"schema_version":1,"complete":complete,"source":{"archive_sha256":ARCHIVE_SHA,"items_sha256":sha(args.items.read_bytes()),
                    "importer_sha256":sha(Path(__file__).read_bytes())},"model_count":len(models),"native_armor_items":len(rows),
                    "available_item_count":len(by_item),"unique_native_source_indices":len(grouped),"models":sorted(models,key=lambda m:m["model_id"]),
                    "by_item_num":by_item,"by_source_index":{str(m["native_source_index"]):{"scene_path":m["scene_path"],"resource_path":m["scene_path"],
                      "source_id":m["native_source_index"],"model_id":m["model_id"],"gear_classes":m["gear_classes"],
                      "unit_kind_mask":m["unit_kind_mask"],"bounds":m["bounds"],"expected_bounds":m["bounds"],"triangles":m["triangles"],
                      "available":True}for m in models},"unavailable":unavailable,
                    "binding":{"native_function":"GetUnitNum","degree":2,"formula":"model_id=12000000+(ITEM.SourceIndex-8000000)",
                        "evidence":"EP35 Common/AtumGlobal.cpp:1402-1463; UnitData.cpp:2495"},
                    "limitations":["Static original frame1/default-color appearance; animations, original multi-texture glow, alternative armor colors and descriptor effects are not baked.",
                      "Native required gear masks retained. Availability does not grant ownership or imply original server default equipment.",
                      "Original model units and Phong-to-PBR approximation; no native executable or shader run."]}
        path=args.output/"gears.json";temporary=path.with_suffix(".tmp")
        temporary.write_text(json.dumps(payload,indent=2,ensure_ascii=False,allow_nan=False)+"\n");temporary.replace(path)
        return payload
    publish()
    with ProcessPoolExecutor(max_workers=args.workers) as pool:
        for future in as_completed([pool.submit(import_gear_source,job)for job in jobs]):
            result=future.result();results.append(result)
            if not result["ok"]:
                failures[result["source_code"]]=result["error"]
                print(json.dumps({"failed_gear":result["source_code"],"reason":result["error"]}),flush=True)
            if len(results)%20==0 or len(results)==len(jobs):
                payload=publish()
                print(json.dumps({"processed_gears":len(results),"total":len(jobs),"models":len(payload["models"]),
                                  "available_items":payload["available_item_count"]}),flush=True)
    payload=publish(complete=not args.limit)
    (args.reports/"gear-import-results.json").write_text(json.dumps({"registry_sha256":sha((args.output/"gears.json").read_bytes()),
        "models":payload["model_count"],"available_items":payload["available_item_count"],"failures":failures,"results":results},indent=2,allow_nan=False)+"\n")
    print(json.dumps({"complete":payload["complete"],"models":payload["model_count"],"available_items":payload["available_item_count"]}),flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--monsters", type=Path)
    parser.add_argument("--items", type=Path, help="Import all armor appearances instead of MEX actors")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--stage", type=Path, required=True)
    parser.add_argument("--reports", type=Path, required=True)
    parser.add_argument("--workers", type=int, default=2)
    parser.add_argument("--limit", type=int)
    args = parser.parse_args()
    if not 1 <= args.workers <= 3:
        parser.error("workers must be between1 and3")
    if args.items:
        import_gears(args)
        return
    if not args.monsters:
        parser.error("--monsters or --items required")
    metadata = json.loads(args.monsters.read_text())
    if metadata["source"]["sha256"] != "4831431a42bd37ac3ecffc067989330f6304ce214c0a77e8062d28f1fffb5f48":
        raise ValueError("Unknown MEX source profile")
    rows = metadata["records"]
    args.output.mkdir(parents=True, exist_ok=True); args.reports.mkdir(parents=True, exist_ok=True)
    variants = {}
    for row in rows:
        if row["AlphaBlending"] not in (0,1) or not 1 <= row["TextureIndex"] <= 255:
            raise ValueError("Unsupported native texture/alpha field")
        variants.setdefault((row["SourceIndex"], row["TextureIndex"]), set()).add(row["AlphaBlending"])
    failures = {}; jobs = []
    for (code, texture), alphas in sorted(variants.items()):
        pack = args.source / f"{code:08d}.obj"
        if not pack.is_file():
            failures[code] = "source_pack_missing_from_original_archive"
            continue
        jobs.append((code, texture, sorted(alphas), str(args.source), str(args.stage), str(args.output), str(args.reports)))
    if args.limit:
        jobs = jobs[:args.limit]
    source = {"archive_sha256": ARCHIVE_SHA, "mex": metadata["source"],
              "importer_sha256": sha(Path(__file__).read_bytes()),
              "actor_converter_sha256": sha(Path(__file__).with_name("convert_original_actor.py").read_bytes())}
    results = []

    def publish(complete=False):
        payload = registry(rows, results, failures, complete, source)
        path = args.output / "actors.json"
        temp = path.with_suffix(".tmp")
        temp.write_text(json.dumps(payload, indent=2, ensure_ascii=False, allow_nan=False) + "\n")
        temp.replace(path)
        return payload

    publish()
    with ProcessPoolExecutor(max_workers=args.workers) as pool:
        futures = {pool.submit(import_source, job):job[0] for job in jobs}
        for future in as_completed(futures):
            result = future.result(); results.append(result)
            if not result["ok"]:
                failures[result["source_code"]] = result["error"]
                print(json.dumps({"failed": result["source_code"], "reason": result["error"]}), flush=True)
            if len(results) % 20 == 0 or len(results) == len(jobs):
                payload = publish()
                print(json.dumps({"processed": len(results), "total": len(jobs), "models": payload["model_count"],
                                  "available_monsters": payload["available_monster_count"], "failed_sources": len(failures)}), flush=True)
    payload = publish(complete=not args.limit)
    (args.reports / "actor-import-results.json").write_text(json.dumps({"registry_sha256": sha((args.output/"actors.json").read_bytes()),
        "models": payload["model_count"], "available_monsters": payload["available_monster_count"],
        "complete": payload["complete"], "failures": failures, "results": results}, indent=2, allow_nan=False) + "\n")
    print(json.dumps({"complete": payload["complete"], "models": payload["model_count"],
                      "available_monsters": payload["available_monster_count"], "unavailable_monsters":len(payload["unavailable"])}), flush=True)


if __name__ == "__main__":
    main()
