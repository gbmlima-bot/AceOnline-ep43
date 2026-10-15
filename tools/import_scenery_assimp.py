#!/usr/bin/env python3
"""Recover static scenery via the C++ importer when its Python binding fails.

The native X importer is only a data parser. Original source hierarchy and skin
bind pose are evaluated into static, terrain-independent vertices. Animations
and effects are explicitly omitted. No arbitrary model heading is introduced.
"""
from __future__ import annotations
import io
import json
from pathlib import Path
import struct
import subprocess
import numpy as np
from PIL import Image
from convert_original_terrain import require, sha256


def read_accessor(doc, binary, index):
    item = doc["accessors"][index]
    require("sparse" not in item, "sparse accessor unsupported")
    view = doc["bufferViews"][item["bufferView"]]
    require("byteStride" not in view, "strided accessor unsupported")
    width = {"SCALAR":1,"VEC2":2,"VEC3":3,"VEC4":4,"MAT4":16}[item["type"]]
    dtype = {5126:"<f4",5125:"<u4",5123:"<u2",5121:"u1"}[item["componentType"]]
    offset = view.get("byteOffset",0) + item.get("byteOffset",0)
    length = item["count"] * width * np.dtype(dtype).itemsize
    require(0 <= offset <= offset + length <= len(binary), "accessor exceeds exported buffer")
    array = np.frombuffer(binary,dtype=dtype,count=item["count"]*width,offset=offset).reshape((-1,width))
    require(np.isfinite(array).all(), "nonfinite geometry accessor")
    return array


def node_matrix(node):
    if "matrix" in node:
        result = np.array(node["matrix"],dtype=float).reshape((4,4),order="F")
    else:
        x,y,z,w = node.get("rotation",[0,0,0,1])
        require(abs(x*x+y*y+z*z+w*w-1) < .002, "nonunit rotation quaternion")
        rotation = np.array([[1-2*y*y-2*z*z,2*x*y-2*z*w,2*x*z+2*y*w],
                             [2*x*y+2*z*w,1-2*x*x-2*z*z,2*y*z-2*x*w],
                             [2*x*z-2*y*w,2*y*z+2*x*w,1-2*x*x-2*y*y]])
        result = np.eye(4)
        result[:3,:3] = rotation @ np.diag(node.get("scale",[1,1,1]))
        result[:3,3] = node.get("translation",[0,0,0])
    require(np.isfinite(result).all(), "nonfinite hierarchy transform")
    return result


def evaluated_meshes(doc, binary):
    worlds = {}
    def walk(index,parent,stack):
        require(index not in stack and index not in worlds and len(stack) < 256, "cyclic or duplicate hierarchy")
        node = doc["nodes"][index]
        worlds[index] = parent @ node_matrix(node)
        for child in node.get("children",[]):
            walk(child,worlds[index],stack | {index})
    for index in doc["scenes"][doc.get("scene",0)]["nodes"]:
        walk(index,np.eye(4),set())
    result = []
    for index,world in worlds.items():
        node = doc["nodes"][index]
        if "mesh" not in node:
            continue
        for primitive in doc["meshes"][node["mesh"]]["primitives"]:
            require(primitive.get("mode",4) == 4, "nontriangle source primitive")
            attributes = primitive["attributes"]
            pos = read_accessor(doc,binary,attributes["POSITION"]).astype(float)
            if len(pos) == 0 or "indices" not in primitive:
                continue
            indices = read_accessor(doc,binary,primitive["indices"]).reshape(-1).astype(np.uint32)
            if len(indices) == 0:
                continue
            require(len(indices)%3 == 0 and int(indices.max()) < len(pos), "invalid triangle indices")
            normals = read_accessor(doc,binary,attributes["NORMAL"]).astype(float) if "NORMAL" in attributes else np.zeros_like(pos)
            uv = read_accessor(doc,binary,attributes["TEXCOORD_0"]).astype(float) if "TEXCOORD_0" in attributes else np.zeros((len(pos),2))
            points = np.column_stack((pos,np.ones(len(pos))))
            if "skin" in node:
                skin = doc["skins"][node["skin"]]
                joints = read_accessor(doc,binary,attributes["JOINTS_0"]).astype(np.uint32)
                weights = read_accessor(doc,binary,attributes["WEIGHTS_0"])
                require(joints.max() < len(skin["joints"]) and abs(weights.sum(axis=1)-1).max() < .002, "invalid source skin weights")
                inverse = read_accessor(doc,binary,skin["inverseBindMatrices"])
                palette = np.array([worlds[j] @ inverse[n].reshape((4,4),order="F") for n,j in enumerate(skin["joints"])])
                transformed = np.zeros_like(points)
                transformed_normals = np.zeros_like(normals)
                normal_palette = np.array([np.linalg.inv(m[:3,:3]).T for m in palette])
                for column in range(4):
                    transformed += np.einsum("nij,nj->ni",palette[joints[:,column]],points) * weights[:,column,None]
                    transformed_normals += np.einsum("nij,nj->ni",normal_palette[joints[:,column]],normals) * weights[:,column,None]
                pos, normals = transformed[:,:3], transformed_normals
            else:
                pos = (world @ points.T).T[:,:3]
                normals = (np.linalg.inv(world[:3,:3]).T @ normals.T).T
                if np.linalg.det(world[:3,:3]) < 0:
                    indices = indices.reshape((-1,3))[:,[0,2,1]].reshape(-1)
            faces = indices.reshape((-1,3))
            lengths = np.linalg.norm(normals,axis=1)
            zero = lengths <= 1e-12
            if zero.any():
                geometric = np.cross(pos[faces[:,1]]-pos[faces[:,0]],pos[faces[:,2]]-pos[faces[:,0]])
                accum = np.zeros_like(normals)
                for column in range(3):
                    np.add.at(accum,faces[:,column],geometric)
                require(np.all(np.linalg.norm(accum[zero],axis=1) > 1e-12), "zero normal on degenerate-only vertex")
                normals[zero] = accum[zero]
                lengths = np.linalg.norm(normals,axis=1)
            normals /= lengths[:,None]
            require(all(np.isfinite(a).all() for a in (pos,normals,uv)), "nonfinite evaluated source mesh")
            result.append({"positions":pos,"normals":normals,"uv":uv,"indices":indices,"material":primitive.get("material",0),"node":node.get("name",str(index))})
    require(bool(result), "source contains no nonempty renderable triangle mesh")
    return result


def convert(unpacked: Path, output: Path, report_root: Path, metadata: dict):
    manifest = json.loads((unpacked/"manifest.json").read_text())
    require(sha256(Path(manifest["source_pack"]).read_bytes()) == manifest["source_pack_sha256"], "source container changed")
    for entry in manifest["entries"]:
        data = Path(entry["path"]).read_bytes()
        require(len(data) == entry["size"] and sha256(data) == entry["source_sha256"], "source payload changed")
    models = [e for e in manifest["entries"] if e["kind"] == "model"]
    images = sorted((e for e in manifest["entries"] if e["kind"] == "image"),key=lambda e:e["entry_name"])
    require(len(models) == 1 and bool(images), "ambiguous source model or missing AnotherTexture1")
    report_root.mkdir(parents=True,exist_ok=True)
    stage = report_root/(output.stem+"-cpp.gltf")
    with (report_root/(output.stem+"-cpp.log")).open("w") as stream:
        subprocess.run(["/workspace/tools/assimp/root/usr/bin/assimp","export",models[0]["path"],str(stage),"-fgltf2"],stdout=stream,stderr=subprocess.STDOUT,check=True,timeout=60)
    source = json.loads(stage.read_bytes().decode("utf-8","surrogateescape"))
    require(len(source["buffers"]) == 1, "unexpected exporter buffer count")
    uri = source["buffers"][0]["uri"]
    require(Path(uri).name == uri, "unsafe generated buffer path")
    source_binary = (stage.parent/uri).read_bytes()
    require(len(source_binary) == source["buffers"][0]["byteLength"], "source buffer length mismatch")
    meshes = evaluated_meshes(source,source_binary)
    binary = bytearray()
    doc = {"asset":{"version":"2.0","generator":"ACE bounded source scenery, C++ Assimp bind-pose fallback"},"scene":0,"scenes":[{"nodes":[0]}],"nodes":[{"name":"OriginalScenery"+output.stem,"children":[]}],"meshes":[],"bufferViews":[],"accessors":[],"materials":source["materials"],"images":[],"textures":[{"source":0,"sampler":0}],"samplers":[{"wrapS":10497,"wrapT":10497,"magFilter":9729,"minFilter":9987}]}
    def view(raw,target=None):
        binary.extend(b"\0"*(-len(binary)%4))
        record={"buffer":0,"byteOffset":len(binary),"byteLength":len(raw)}
        if target:record["target"]=target
        binary.extend(raw);doc["bufferViews"].append(record)
        return len(doc["bufferViews"])-1
    def accessor(array,kind,indices=False):
        encoded=np.asarray(array,dtype="<u4" if indices else "<f4")
        record={"bufferView":view(encoded.tobytes(),34963 if indices else 34962),"componentType":5125 if indices else 5126,"count":len(encoded),"type":kind}
        if kind=="VEC3":record.update(min=encoded.min(axis=0).tolist(),max=encoded.max(axis=0).tolist())
        doc["accessors"].append(record)
        return len(doc["accessors"])-1
    image=images[0];raw=Path(image["path"]).read_bytes()
    with Image.open(io.BytesIO(raw)) as im:
        im.load()
        if im.format=="JPEG":embedded,mime=raw,"image/jpeg"
        else:
            stream=io.BytesIO();im.convert("RGBA").save(stream,"PNG");embedded,mime=stream.getvalue(),"image/png"
    doc["images"]=[{"name":image["entry_name"],"bufferView":view(embedded),"mimeType":mime}]
    for material in doc["materials"]:
        material["alphaMode"]="BLEND" if metadata["alpha"] else "OPAQUE"
        material.setdefault("pbrMetallicRoughness",{})["baseColorTexture"]={"index":0}
        for name in ("normalTexture","occlusionTexture","emissiveTexture"):
            material.pop(name,None)
        material["pbrMetallicRoughness"].pop("metallicRoughnessTexture",None)
        material.setdefault("extras",{})["source_texture_evidence"]="CObjRender.cpp:90 AnotherTexture(1); source sorted first image; no filesystem material paths read."
    for mesh in meshes:
        primitive={"attributes":{"POSITION":accessor(mesh["positions"],"VEC3"),"NORMAL":accessor(mesh["normals"],"VEC3"),"TEXCOORD_0":accessor(mesh["uv"],"VEC2")},"indices":accessor(mesh["indices"],"SCALAR",True),"material":mesh["material"],"mode":4}
        doc["meshes"].append({"name":mesh["node"],"primitives":[primitive]})
        node=len(doc["nodes"]);doc["nodes"].append({"name":mesh["node"],"mesh":len(doc["meshes"])-1});doc["nodes"][0]["children"].append(node)
    doc["buffers"]=[{"byteLength":len(binary)}]
    encoded=json.dumps(doc,separators=(",",":"),ensure_ascii=True,allow_nan=False).encode();encoded+=b" "*(-len(encoded)%4);binary.extend(b"\0"*(-len(binary)%4))
    glb=struct.pack("<4sII",b"glTF",2,28+len(encoded)+len(binary))+struct.pack("<I4s",len(encoded),b"JSON")+encoded+struct.pack("<I4s",len(binary),b"BIN\0")+binary
    output.write_bytes(glb)
    report={"model_id":output.stem,"output_sha256":sha256(glb),"output_size":len(glb),"source_pack_sha256":manifest["source_pack_sha256"],"source_x_sha256":models[0]["source_sha256"],"source_animation_count":len(source.get("animations",[])),"source_skin_count":len(source.get("skins",[])),"triangles":sum(len(m["indices"])//3 for m in meshes),"source_mapobjectinfo":metadata,"fallback":"C++ importer used because Python binding did not expose this source model correctly.","pose":"Static original hierarchy/weighted skin bind pose evaluated, no actor heading, no runtime placement baked.","omitted":"Animation and attached effects not exported; original source poses retained in the per-map layouts.","texture":{"entry_name":image["entry_name"],"source_sha256":image["source_sha256"],"embedded_sha256":sha256(embedded)}}
    (report_root/(output.stem+"-fallback.json")).write_text(json.dumps(report,indent=2,allow_nan=False)+"\n")
    return report
