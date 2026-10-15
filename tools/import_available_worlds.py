#!/usr/bin/env python3
"""Import every bounded terrain and its source scenery from the pinned client.

Only data is read: no game executable, script, service or network is invoked.
Unknown layouts fail per resource and remain explicit in the coverage report.
Converted meshes are pooled by native render code, never substituted.
"""
from __future__ import annotations

import argparse
from concurrent.futures import ProcessPoolExecutor, as_completed
from collections import Counter
import hashlib
import json
import math
import io
from pathlib import Path
import re
import struct
import sys
import zlib

import numpy as np
from PIL import Image
import convert_original_terrain as terrain_core
import convert_original_gears as model_core
import convert_complete_props as props_core
import import_world_profile as extended
import import_scenery_assimp as scenery_fallback
from pyassimp.errors import AssimpError
from convert_additional_terrain import water_tiles, landing_tiles
from export_original_rules import load_terrain_events

ARCHIVE_SHA = "8395f1f33dda8165f70f30d2a6ad094c5f64e144403fce98337e5012be795841"
ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "client/assets"
POOL = ASSETS / "original_library"
WORLD = ASSETS / "original_worlds"
PREFIX = "res://assets/original_library/"
EXISTING = {3002, 3003, 3302}


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def write(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, ensure_ascii=True, allow_nan=False) + "\n")


def res(path: Path) -> str:
    return "res://" + path.relative_to(ROOT / "client").as_posix()


def verify_source(path: Path, relative: str, inventory: dict) -> dict:
    row = inventory.get(relative)
    terrain_core.require(row is not None, "source not present in pinned archive inventory: " + relative)
    raw = path.read_bytes()
    terrain_core.require(len(raw) == int(row["Size"]), "extracted source size mismatch: " + relative)
    terrain_core.require(f"{zlib.crc32(raw) & 0xffffffff:08X}" == row["CRC"].upper(), "archive CRC mismatch: " + relative)
    return {"archive_path": relative, "size": len(raw), "sha256": terrain_core.sha256(raw), "archive_crc32": row["CRC"]}


def unpack_resource(pack: Path, output: Path) -> dict:
    entries, container = extended.parse_resource(pack.read_bytes())
    output.mkdir(parents=True, exist_ok=True)
    records = []
    for name, entry in entries.items():
        terrain_core.require(re.fullmatch(r"[A-Za-z0-9_,.-]{1,40}",name) and name not in (".",".."), "unsafe resource entry name")
        if entry.data.startswith(b"xof "):
            terrain_core.require(entry.data[:16] in (b"xof 0303txt 0032",b"xof 0303bzip0032",b"xof 0303bin 0032"), "unsupported X format")
            kind, extension = "model", "x"
        else:
            with Image.open(io.BytesIO(entry.data)) as image:
                terrain_core.require(0 < image.width*image.height <= 4096*4096, "image outside bounded profile")
                image.load()
                kind, extension = "image", image.format.lower()
        path = output/(name+"."+extension)
        path.write_bytes(entry.data)
        records.append({"entry_name":name,"kind":kind,"path":str(path.resolve()),"size":len(entry.data),"source_sha256":terrain_core.sha256(entry.data),"source_payload_offset":entry.offset})
    manifest = {"source_pack":str(pack.resolve()),"source_pack_sha256":container["sha256"],"container":container,"entries":records}
    write(output/"manifest.json",manifest)
    return manifest


def placements(payload: bytes, entry_offset: int, terrain) -> tuple[list, list]:
    start = 36 + len(terrain.vertices) * 24 + terrain.tiles * terrain.tiles * 24
    center = terrain.tiles * terrain.tile_size / 2
    poses, errors = [], []
    reflection = np.diag([1., 1., -1.])
    for index in range(terrain.object_count):
        record = payload[start + index * 112:start + (index + 1) * 112]
        code = struct.unpack_from("<I", record)[0]
        position, forward, up = [np.array(struct.unpack_from("<3f", record, offset), dtype=float) for offset in (8, 20, 32)]
        try:
            terrain_core.require(all(np.isfinite(v).all() for v in (position, forward, up)), "non-finite pose")
            terrain_core.require(np.linalg.norm(forward) > 1e-8 and np.linalg.norm(up) > 1e-8, "zero direction/up")
            forward /= np.linalg.norm(forward)
            up /= np.linalg.norm(up)
            right = np.cross(up, forward)
            terrain_core.require(np.linalg.norm(right) > 1e-8, "parallel direction/up")
            right /= np.linalg.norm(right)
            basis = reflection @ np.column_stack((right, np.cross(forward, right), forward)) @ reflection
            origin = reflection @ position + np.array([-center, 0, center])
            terrain_core.require(abs(np.linalg.det(basis) - 1) < 1e-8, "invalid rotation")
            poses.append({"source_record_index": index, "source_record_offset": entry_offset + start + index * 112,
                          "source_record_sha256": terrain_core.sha256(record), "code": code,
                          "source_position": struct.unpack_from("<3f", record, 8),
                          "source_direction": struct.unpack_from("<3f", record, 20),
                          "source_up": struct.unpack_from("<3f", record, 32),
                          "body_condition_byte": record[56], "body_condition_mask": 1 << record[56],
                          "source_texture_index": record[48], "source_is_event": struct.unpack_from("<i", record, 60)[0],
                          "transform_columns": np.concatenate((basis.T.reshape(-1), origin)).tolist()})
        except (ValueError, OverflowError) as exc:
            errors.append({"record_index": index, "code": code, "reason": str(exc), "sha256": terrain_core.sha256(record)})
    return poses, errors


def convert_terrain(job: dict) -> dict:
    row, source, inventory = job["row"], Path(job["source"]), job["inventory"]
    identifier, dat_id = row["MapIndex"], row["Dat"]
    result = {"map_index": identifier, "native_name": row["MapName"], "available": False, "unavailable_reasons": []}
    try:
        source_dat = verify_source(source / f"Res-map/{dat_id}.dat", f"Res-map/{dat_id}.dat", inventory)
        source_map = verify_source(source / f"Res-map/{row['Map']}.map", f"Res-map/{row['Map']}.map", inventory)
        entries, dat_manifest = extended.parse_resource((source / source_dat["archive_path"]).read_bytes())
        textures, map_manifest = extended.parse_resource((source / source_map["archive_path"]).read_bytes())
        terrain_core.require(str(dat_id) in entries, "bound DAT terrain entry absent")
        entry = entries[str(dat_id)]
        terrain = terrain_core.parse_terrain(entry.data)
        # The source quadtree's fixed sixteen-entry texture table is established
        # for 256 tiles. Other sizes are kept unavailable rather than guessed.
        terrain_core.require(terrain.tiles == 256, "unsupported source texture-block layout: tiles=" + str(terrain.tiles))
        try:
            project = terrain_core.parse_project((source / "Res-map/ms.wok").read_bytes(), str(dat_id))
            terrain_core.require(project["tile_dimensions"] == [terrain.tiles, terrain.tiles], "workspace dimensions differ from DAT")
        except terrain_core.FormatError:
            project = {"water_height": row["WaterHeight"], "tile_dimensions": [terrain.tiles, terrain.tiles],
                       "provenance": "MAP_INFO WaterHeight; no matching PROJECTINFO, source lighting unavailable"}
        poses, pose_errors = placements(entry.data, entry.offset, terrain)
        events_source, events = load_terrain_events(source / source_dat["archive_path"])
        result.update(source_dat=source_dat, source_map=source_map, source_map_info=row["_source"],
                      source_bindings={k: row[k] for k in ("Dat", "Map", "Tex", "Sky", "Cloud", "Nsky")},
                      object_count=terrain.object_count, pose_errors=pose_errors,
                      events=events, portals=[v for v in events if v["event_type"] == 1], poses=poses)
        if identifier in EXISTING:
            base = ASSETS / "original_world" if identifier == 3002 else WORLD / str(identifier)
            layout = ASSETS / "original_props/placements.json" if identifier == 3002 else base / "props/placements.json"
            metadata_path = base / f"{dat_id}_terrain.json"
            result.update(available=True, preserved_existing=True, terrain_path=res(base / f"{dat_id}_terrain.glb"),
                          terrain_metadata=res(metadata_path), height_path=res(base / f"{dat_id}_heights.f32"), props_path=res(layout))
            return result
        output = WORLD / str(identifier)
        output.mkdir(parents=True, exist_ok=True)
        geometry = extended.export_glb(terrain, textures, output / f"{dat_id}_terrain.glb", resource_id=str(dat_id))
        heights = struct.pack("<" + "f" * len(terrain.vertices), *(v[1] for v in terrain.vertices))
        (output / f"{dat_id}_heights.f32").write_bytes(heights)
        water_flags = water_tiles(entry.data, terrain, project["water_height"])
        land_flags = landing_tiles(entry.data, terrain)
        (output / f"{dat_id}_water_flags.u8").write_bytes(water_flags)
        (output / f"{dat_id}_landing_flags.u8").write_bytes(land_flags)
        water = terrain_core.water_patches(entry.data, terrain, project["water_height"])
        water.update(active_tile_flags=f"{dat_id}_water_flags.u8", active_tile_flags_sha256=terrain_core.sha256(water_flags), active_tile_count=sum(water_flags), texture_note="WaterType from current MAP_INFO; water mesh/material is reconstructed by the new runtime.")
        center = terrain.tiles * terrain.tile_size / 2
        report = {"schema_version": 1, "resource_id": dat_id, "map_index": identifier, "display_name": row["MapName"],
                  "source_code": {"ep35_commit": terrain_core.SOURCE_SHA, "ep43_commit": terrain_core.EP43_SHA},
                  "source_package": {"name": "ACEonline-20250709.7z", "sha256": ARCHIVE_SHA},
                  "source_resources": {"dat": dat_manifest, "map": map_manifest}, "source_map_info": row,
                  "geometry": geometry, "native_bounds": terrain.native_bounds,
                  "target_bounds": [[-center, terrain.native_bounds[0][1], -center], [center, terrain.native_bounds[1][1], center]],
                  "transform": {"formula": "target=(source.x-center,source.y,center-source.z)", "scale": [1,1,-1], "translation": [-center,0,center]},
                  "grid": {"vertex_side": terrain.tiles+1, "tile_side": terrain.tiles, "tile_size": terrain.tile_size,
                           "heightmap": f"{dat_id}_heights.f32", "heightmap_sha256": terrain_core.sha256(heights), "heightmap_format": "little-endian float32; source-x-major/source-z-minor"},
                  "project_environment": project, "water": water,
                  "landing": {"tile_flags": f"{dat_id}_landing_flags.u8", "tile_flags_sha256": terrain_core.sha256(land_flags), "enabled_tile_count": sum(land_flags), "tile_flags_format": "uint8 source-x-major/source-z-minor; original BOOL@16 normalized by nonzero"},
                  "events_source": events_source, "event_count": len(events),
                  "omitted": {"detail_texture": True, "legacy_lighting_fog_LOD": True},
                  "compatibility_note": "Original static geometry, normals, bound JPEG bytes, poses, flags and events. New glTF renderer; source collision B-D diagonal differs from visual A-C diagonal."}
        write(output / f"{dat_id}_terrain.json", report)
        write(output / "events.json", {"source": events_source, "events": events, "portals": result["portals"]})
        result.update(available=True, terrain_path=res(output / f"{dat_id}_terrain.glb"), terrain_metadata=res(output / f"{dat_id}_terrain.json"),
                      height_path=res(output / f"{dat_id}_heights.f32"), props_path=res(output / "props/placements.json"))
    except Exception as exc:
        result["unavailable_reasons"].append(type(exc).__name__ + ": " + str(exc))
    return result


def convert_model(job: dict) -> dict:
    code, source, inventory = job["code"], Path(job["source"]), job["inventory"]
    row = job["metadata"]
    result = {"code": code, "available": False}
    try:
        terrain_core.require(row is not None, "source MAPOBJECTINFO absent")
        terrain_core.require(row["render_type"] in (0, 1, 2, 3, 4, 7, 10, 11), "unsupported native object renderer: " + str(row["render_type"]))
        name = f"{code:08d}"
        result["source"] = verify_source(source / f"Res-obj/{name}.obj", f"Res-obj/{name}.obj", inventory)
        unpacked = Path(job["work"]) / "unpacked-props"
        manifest = unpack_resource(source / f"Res-obj/{name}.obj", unpacked / name)
        images = sorted(e["entry_name"] for e in manifest["entries"] if e["kind"] == "image")
        terrain_core.require(bool(images), "source AnotherTexture1 missing")
        model_core.SOURCE_ROOT, model_core.OUTPUT_ROOT = unpacked, Path(job.get("output", POOL / "props"))
        asset_prefix = job.get("asset_prefix", PREFIX + "props/")
        model_core.REPORT_ROOT = Path(job["work"]) / "props-reports"
        model_core.OUTPUT_ROOT.mkdir(parents=True, exist_ok=True)
        model_core.REPORT_ROOT.mkdir(parents=True, exist_ok=True)
        cache = model_core.REPORT_ROOT / (name + "-conversion.json")
        report = json.loads(cache.read_text()) if cache.exists() else {}
        output_file = model_core.OUTPUT_ROOT / (name + ".glb")
        if not report or not output_file.exists() or digest(output_file) != report.get("output_sha256") or report.get("source_pack_sha256") != manifest["source_pack_sha256"]:
            try:
                report = model_core.convert(name, "SCENERY", profile="scenery", alpha_mode="BLEND" if row["alpha"] else "OPAQUE", texture_entry_override=images[0], generate_zero_normals=True)
            except (Exception, AssimpError):
                report = scenery_fallback.convert(unpacked/name,output_file,model_core.REPORT_ROOT,row)
            write(cache,report)
        report["source_mapobjectinfo"] = row
        result.update(available=True, scene=asset_prefix + name + ".glb", sha256=report["output_sha256"],
                      source_mapobjectinfo=row, triangles=report["triangles"], animation_tracks_omitted=report["source_animation_count"])
        if row["collision"] or row["server_collision"]:
            result["collision_mesh"] = props_core.collision_mesh(model_core.OUTPUT_ROOT / (name + ".glb"), row, model_core.OUTPUT_ROOT / (name + "_collision.json"), asset_prefix)
        write(model_core.REPORT_ROOT / (name + ".json"), report)
    except (Exception, AssimpError) as exc:
        result["available"] = False
        result["reason"] = type(exc).__name__ + ": " + str(exc)
    return result


def convert_sky(job: dict) -> dict:
    identifier, kind, source = job["id"], job["kind"], Path(job["source"])
    extension = "sky" if kind == "sky" else "cld"
    night = job.get("night",False)
    variant = job.get("variant", "")
    terrain_core.require(not variant or re.fullmatch(r"[a-z]",variant), "unsafe source variant suffix")
    suffix = variant or ("n" if night else "")
    name = f"{identifier}_{variant+'_' if variant else 'night_' if night else ''}{kind}"
    result = {"id": identifier, "kind": kind, "night":night, "available": False}
    if variant:
        result["variant"] = variant
        result["binding_note"] = "Available original source variant retained in library; no MAP_INFO association is inferred."
    try:
        result["source"] = verify_source(source / f"Res-map/{identifier}{suffix}.{extension}", f"Res-map/{identifier}{suffix}.{extension}", job["inventory"])
        unpacked = Path(job["work"]) / "unpacked-sky"
        manifest = unpack_resource(source / f"Res-map/{identifier}{suffix}.{extension}", unpacked / name)
        models = [e["entry_name"] for e in manifest["entries"] if e["kind"] == "model"]
        terrain_core.require(len(models) == 1, "sky/cloud requires exactly one unambiguous source model")
        model_core.SOURCE_ROOT, model_core.OUTPUT_ROOT = unpacked, POOL / "sky"
        model_core.REPORT_ROOT = Path(job["work"]) / "sky-reports"
        model_core.OUTPUT_ROOT.mkdir(parents=True, exist_ok=True)
        model_core.REPORT_ROOT.mkdir(parents=True, exist_ok=True)
        texture_adaptation = None
        try:
            report = model_core.convert(name, kind.upper(), profile=kind, source_model_entry=models[0])
        except ValueError as exc:
            images = [e["entry_name"] for e in manifest["entries"] if e["kind"] == "image"]
            if not str(exc).startswith("Unresolved exact material texture entry:") or len(images) != 1:
                raise
            # Two native cloud packs retain a stale material entry name. The
            # only embedded source image is retained with explicit adaptation,
            # rather than claiming the missing native binding was established.
            report = model_core.convert(name, kind.upper(), profile=kind, source_model_entry=models[0],texture_entry_override=images[0])
            texture_adaptation = {"missing_material_binding":str(exc),"selected_embedded_source_image":images[0],"reason":"Unique image in the same original pack; adapted binding, native visual equivalence is unverified."}
            report["texture_binding_adaptation"] = texture_adaptation
        result.update(available=True, scene=PREFIX + "sky/" + name + ".glb", sha256=report["output_sha256"], triangles=report["triangles"], meshes=report["source_mesh_count"])
        if texture_adaptation:
            result["texture_binding_adaptation"] = texture_adaptation
        write(model_core.REPORT_ROOT / (name + ".json"), report)
    except (Exception, AssimpError) as exc:
        result["available"] = False
        result["reason"] = type(exc).__name__ + ": " + str(exc)
    return result


def visual_profile(row: dict, item: dict, skies: dict) -> dict:
    meta = json.loads((ROOT / "client" / item["terrain_metadata"].removeprefix("res://")).read_text())
    bounds = meta["target_bounds"]
    result = {"terrain": {"source_id": str(row["Dat"]), "name": f"OriginalTerrain{row['MapIndex']}", "resource_path": item["terrain_path"],
                          "position": [0,0,0], "rotation_degrees": [0,0,0], "scale": [1,1,1],
                          "expected_triangles": meta["geometry"]["triangle_count"], "expected_aabb_min": bounds[0], "expected_aabb_max": bounds[1]},
              "props": {"layout_path": item["props_path"]}, "sky": {}, "clouds": {}, "environment": {}}
    for key, binding, kind in (("sky","Sky","sky"),("clouds","Cloud","cloud")):
        sky = skies.get((row[binding], kind), {})
        if sky.get("available"):
            item[key + "_path"] = sky["scene"]
            scale = float(row["DayFogEndDistance"]) / 133.
            result[key] = {"name": f"Original{kind}{row[binding]}", "resource_path": sky["scene"], "position": [0,0,0], "rotation_degrees": [0,90,0], "scale": [scale]*3,
                           "source_binding": row["_source"], "source_fog_end": row["DayFogEndDistance"],
                           "expected_mesh_count": sky["meshes"], "expected_triangles": sky["triangles"]}
            if sky.get("texture_binding_adaptation"):
                item["coverage_gaps"].append({"kind":key,"resource_id":row[binding],"reason":"Original material entry missing; unique embedded source image adapted explicitly.","texture_binding_adaptation":sky["texture_binding_adaptation"]})
        elif row[binding] != 0:
            item["coverage_gaps"].append({"kind": key, "resource_id": row[binding], "reason": sky.get("reason", "bound source unavailable")})
    project = meta.get("project_environment", {})
    env = {"mode": "original_source_bindings", "source_day_sun_direction": row["DaySunDirection"], "source_day_fog_color": row["DayFogColor"],
           "source_diffuse_day": project.get("diffuse_day", []), "source_ambient_day": project.get("ambient_day", []), "viewer_fog_end": row["DayFogEndDistance"]}
    if project.get("ambient_day"):
        env.update(ambient_light_color=project["ambient_day"], ambient_light_energy=1.)
    if project.get("diffuse_day"):
        env.update(sun_color=project["diffuse_day"], sun_energy=1.)
    result["environment"] = env
    return result


def run_pool(function, jobs, workers, stage):
    result = []
    with ProcessPoolExecutor(max_workers=workers) as pool:
        pending = {pool.submit(function, job): job for job in jobs}
        for future in as_completed(pending):
            try:
                item = future.result()
            except (Exception, AssimpError) as exc:
                job = pending[future]
                item = {"available": False, "reason": type(exc).__name__ + ": " + str(exc), "job": {k:v for k,v in job.items() if k not in ("inventory", "metadata")}}
            result.append(item)
            if len(result) % 10 == 0 or len(result) == len(jobs):
                print(json.dumps({"stage": stage, "done": len(result), "total": len(jobs), "available": sum(bool(r.get("available")) for r in result)}), flush=True)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--archive", type=Path, default=Path("/workspace/downloads/ace-client/ACEonline-20250709.7z"))
    parser.add_argument("--inventory", type=Path, default=Path("/workspace/analysis/ace-online-ui/archive-inventory.json"))
    parser.add_argument("--work", type=Path, default=Path("/workspace/analysis/ace-absorb"))
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--resume", action="store_true")
    args = parser.parse_args()
    terrain_core.require(1 <= args.workers <= 4, "worker policy: 1..4")
    terrain_core.require(digest(args.archive) == ARCHIVE_SHA, "original archive identity mismatch")
    inventory = {r["Path"]: r for r in json.loads(args.inventory.read_text()) if r.get("CRC")}
    rules = json.loads((ASSETS / "legacy_rules/maps.json").read_text())
    rows = rules["records"]
    common = {"source": str(args.source), "inventory": inventory, "work": str(args.work)}
    verify_source(args.source / "Res-map/ms.wok", "Res-map/ms.wok", inventory)
    verify_source(args.source / "Res-tex/omi.tex", "Res-tex/omi.tex", inventory)
    metadata = props_core.read_rows((args.source / "Res-tex/omi.tex").read_bytes())
    args.work.mkdir(parents=True, exist_ok=True)
    checkpoint = args.work / "world-terrain-checkpoint.json"
    if args.resume and checkpoint.exists():
        terrains = json.loads(checkpoint.read_text())
        failed = {r["map_index"] for r in terrains if not r["available"]}
        retry = run_pool(convert_terrain, [{**common,"row":row} for row in rows if row["MapIndex"] in failed], args.workers, "terrain-retry")
        retried = {r["map_index"]:r for r in retry}
        terrains = [retried.get(r["map_index"],r) for r in terrains]
        write(checkpoint, terrains)
    else:
        jobs = [{**common, "row": row} for row in rows if f"Res-map/{row['Dat']}.dat" in inventory and f"Res-map/{row['Map']}.map" in inventory]
        terrains = run_pool(convert_terrain, jobs, args.workers, "terrain")
        write(checkpoint, terrains)
    codes = sorted({p["code"] for item in terrains if item.get("available") and not item.get("preserved_existing") for p in item["poses"]})
    checkpoint = args.work / "world-props-checkpoint.json"
    if args.resume and checkpoint.exists():
        models = json.loads(checkpoint.read_text())
        retry_codes = {r["code"] for r in models if not r["available"]}
        retry = run_pool(convert_model,[{**common,"code":code,"metadata":metadata.get(code)} for code in sorted(retry_codes)],args.workers,"props-retry")
        by_retry_code = {r["code"]:r for r in retry if "code" in r}
        models = [by_retry_code.get(r["code"],r) for r in models]
        write(checkpoint,models)
    else:
        models = run_pool(convert_model, [{**common,"code": code,"metadata": metadata.get(code)} for code in codes], args.workers, "props")
        write(checkpoint, models)
    by_code = {r["code"]: r for r in models if "code" in r}
    sky_bindings = {(row[binding],kind,night) for row in rows for binding,kind,night in (("Sky","sky",False),("Cloud","cloud",False),("Nsky","sky",True),("Cloud","cloud",True)) if row[binding] > 0}
    for name in inventory:
        match = re.fullmatch(r"Res-map/(\d+)(n?)\.(sky|cld)",name)
        if match:
            sky_bindings.add((int(match[1]),"sky" if match[3]=="sky" else "cloud",bool(match[2])))
    sky_bindings = sorted(sky_bindings)
    checkpoint = args.work / "world-sky-checkpoint.json"
    if args.resume and checkpoint.exists():
        skies_list = json.loads(checkpoint.read_text())
        previous = {(r["id"],r["kind"],r.get("night",False)):r for r in skies_list if "id" in r}
        retry = run_pool(convert_sky,[{**common,"id":identifier,"kind":kind,"night":night} for identifier,kind,night in sky_bindings if not previous.get((identifier,kind,night),{}).get("available")],args.workers,"sky-retry")
        previous.update({(r["id"],r["kind"],r.get("night",False)):r for r in retry if "id" in r})
        skies_list = [previous[key] for key in sky_bindings]
        write(checkpoint,skies_list)
    else:
        skies_list = run_pool(convert_sky, [{**common,"id": identifier,"kind": kind,"night":night} for identifier,kind,night in sky_bindings], args.workers, "sky")
        write(checkpoint, skies_list)
    for filename in sorted(inventory):
        match = re.fullmatch(r"Res-map/(\d+)([a-mo-z])\.(sky|cld)",filename)
        if match:
            skies_list.append(convert_sky({**common,"id":int(match[1]),"kind":"sky" if match[3]=="sky" else "cloud","variant":match[2]}))
    skies = {(r["id"],r["kind"]):r for r in skies_list if "id" in r and not r.get("night") and not r.get("variant")}
    all_events, event_sources, event_failures = [], [], []
    for filename in sorted(inventory):
        if not re.fullmatch(r"Res-map/\d+\.dat",filename):
            continue
        try:
            verify_source(args.source/filename,filename,inventory)
            extended.parse_resource((args.source/filename).read_bytes())
            source_record, recovered_events = load_terrain_events(args.source/filename)
            event_sources.append(source_record)
            all_events.extend(recovered_events)
        except Exception as exc:
            event_failures.append({"source":filename,"reason":type(exc).__name__+": "+str(exc)})
    alpha = {"enabled": True, "per_model": True, "source_alpha_flag": "models[].source_mapobjectinfo.alpha", "function": "GREATER_EQUAL", "reference_uint8":127,"cutoff":127/255,"blend":"SRCALPHA/INVSRCALPHA"}
    results, events = [], []
    terrain_by_id = {t["map_index"]:t for t in terrains}
    for row in rows:
        item = terrain_by_id.get(row["MapIndex"], {"map_index":row["MapIndex"],"native_name":row["MapName"],"available":False,"unavailable_reasons":["bound DAT or MAP absent from original client"]})
        item["coverage_gaps"] = []
        item["terrain_available"] = item.get("available", False)
        if item.get("available"):
            events.extend(item["events"])
            if not item.get("preserved_existing"):
                grouped = {}
                omitted = []
                for pose in item["poses"]:
                    code = pose["code"]
                    model = by_code.get(code,{})
                    if model.get("available"):
                        if code not in grouped:
                            grouped[code] = {k:model[k] for k in ("code","scene","sha256","source_mapobjectinfo")}
                            grouped[code]["placements"] = []
                            if model.get("collision_mesh"):
                                grouped[code]["collision_mesh"] = model["collision_mesh"]
                        grouped[code]["placements"].append(pose)
                    else:
                        omitted.append({"code":code,"source_record_index":pose["source_record_index"],"reason":model.get("reason","conversion unavailable"),"source_mapobjectinfo":metadata.get(code),"collision_expected":bool((metadata.get(code) or {}).get("collision",0))})
                item["prop_model_count"], item["prop_instance_count"] = len(grouped), sum(len(m["placements"]) for m in grouped.values())
                item["coverage_gaps"].extend(omitted)
                item["coverage_gaps"].extend(item["pose_errors"])
                layout = {"schema_version":1,"resource_id":row["Dat"],"map_index":row["MapIndex"],"source":item["source_dat"],"instance_count":item["prop_instance_count"],"model_count":len(grouped),
                          "coordinate_profile":"F*inverse(LookAtLH)*F, terrain-centered; no ship heading", "matrix_layout":"12 floats: basisX.xyz,basisY.xyz,basisZ.xyz,origin.xyz", "alpha_pipeline":alpha,"models":list(grouped.values()),"omitted":omitted}
                write(ROOT / "client" / item["props_path"].removeprefix("res://"),layout)
            else:
                layout = json.loads((ROOT / "client" / item["props_path"].removeprefix("res://")).read_text())
                item["prop_model_count"], item["prop_instance_count"] = layout["model_count"], layout["instance_count"]
            item["visual_profile"] = visual_profile(row,item,skies)
            item["complete_static_scenery"] = not item["coverage_gaps"]
            item["props_total"] = item.get("object_count",0)
            item["props_imported"] = item.get("prop_instance_count",0)
            item["missing_prop_codes"] = sorted({int(v["code"]) for v in item["coverage_gaps"] if "code" in v})
            item["status"] = "complete" if item["complete_static_scenery"] else "partial"
        else:
            item["status"] = "unavailable"
        item.pop("poses",None)
        item.pop("events",None)
        item.pop("portals",None)
        results.append(item)
    events = all_events
    catalog = {"schema_version":1,"source_archive_sha256":ARCHIVE_SHA,"source_maps_sha256":digest(ASSETS / "legacy_rules/maps.json"),"source_inventory_sha256":digest(args.inventory),
               "records":results,"events":events,"portals":[e for e in events if e["event_type"]==1],
               "coverage":{"catalog_maps":len(results),"available_maps":sum(r["available"] for r in results),"complete_static_scenery_maps":sum(r.get("complete_static_scenery",False) for r in results),
                           "source_prop_models":len(codes),"converted_pooled_prop_models":sum(r["available"] for r in models),"placed_prop_instances":sum(r.get("prop_instance_count",0) for r in results),"sky_cloud_bindings":len(skies_list),"source_sky_cloud_files":sum(bool(re.fullmatch(r"Res-map/\d+[a-z]?\.(sky|cld)",name)) for name in inventory),"converted_sky_cloud_models":sum(r["available"] for r in skies_list),"events":len(events),"portals":sum(e["event_type"]==1 for e in events),"source_event_dats":len(event_sources)},
               "limitations":["Static source geometry and source data only; server spawns, full NPC AI and missing original model animation are not supplied by this import.","Coverage gaps list original resources that could not be decoded; no generic replacements are invented.","Available means validated terrain/height/flags and an explicit prop layout; complete_static_scenery additionally requires all source props and bound sky/cloud assets.","Original files retain their original rights; import does not grant redistribution rights."]}
    write(WORLD / "catalog.json",catalog)
    write(WORLD / "events-catalog.json",{"schema_version":1,"source_archive_sha256":ARCHIVE_SHA,"sources":event_sources,"events":all_events,"unsupported":event_failures})
    write(POOL / "props/manifest.json",{"schema_version":1,"source_archive_sha256":ARCHIVE_SHA,"models":models})
    write(POOL / "sky/manifest.json",{"schema_version":1,"source_archive_sha256":ARCHIVE_SHA,"models":skies_list})
    write(ROOT / "reports/import-worlds.json",{"schema_version":1,"coverage":catalog["coverage"],"records":results,"props":models,"sky_cloud":skies_list,"source_archive_sha256":ARCHIVE_SHA,"converter_sha256":digest(Path(__file__))})
    print(json.dumps({"complete":True,"coverage":catalog["coverage"]}),flush=True)


if __name__ == "__main__":
    main()
