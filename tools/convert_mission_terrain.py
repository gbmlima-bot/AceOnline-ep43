#!/usr/bin/env python3
"""Convert mission resource3302 using its independently bound ground map3002."""
import argparse
import json
from pathlib import Path
import struct
import convert_original_terrain as c
from convert_additional_terrain import water_tiles, landing_tiles


def convert(dat_path, map_path, workspace, rules_path, output):
    c.require(c.sha256(dat_path.read_bytes()) == "2f4f4b3d652904669d542bc13ea4f8fff4c0f668d45768338c87e36ce014f6b2", "unknown3302DAT")
    c.require(c.sha256(map_path.read_bytes()) == c.EXPECTED_RESOURCES["3002.map"], "unknown ground map")
    rules = json.loads(rules_path.read_text()); native = rules["by_id"]["3302"]
    c.require((native["Dat"], native["Map"], native["Sky"], native["Cloud"]) == (3302, 3002, 3002, 3002), "MAP_INFO binding changed")
    dat, dm = c.parse_resource(dat_path.read_bytes()); textures, mm = c.parse_resource(map_path.read_bytes())
    terrain = c.parse_terrain(dat["3302"].data); project = c.parse_project(workspace.read_bytes(), "3302")
    c.require(project["tile_dimensions"] == [terrain.tiles, terrain.tiles], "project/terrain dimensions differ")
    output.mkdir(parents=True, exist_ok=True)
    geometry = c.export_glb(terrain, textures, output / "3302_terrain.glb", resource_id="3302")
    heights = struct.pack("<" + "f" * len(terrain.vertices), *(v[1] for v in terrain.vertices))
    (output / "3302_heights.f32").write_bytes(heights)
    flags = water_tiles(dat["3302"].data, terrain, project["water_height"])
    land = landing_tiles(dat["3302"].data, terrain)
    (output / "3302_water_flags.u8").write_bytes(flags); (output / "3302_landing_flags.u8").write_bytes(land)
    water = c.water_patches(dat["3302"].data, terrain, project["water_height"])
    water.update(active_tile_flags="3302_water_flags.u8", active_tile_flags_sha256=c.sha256(flags), active_tile_count=sum(flags), texture_note="Current MAP_INFO.WaterType1 selects water.tex; texture remains external to terrain GLB.")
    center = terrain.tiles * terrain.tile_size / 2
    report = {"schema_version": 1, "resource_id": 3302, "display_name": native["MapName"], "identity_note": "Current plaintext MAP_INFO name and independent Dat/Map/Sky/Cloud bindings. Geometry differs from3002; no alias used.",
              "source_code": {"ep35_commit": c.SOURCE_SHA, "ep43_commit": c.EP43_SHA},
              "source_package": {"name": "ACEonline-20250709.7z", "sha256": "8395f1f33dda8165f70f30d2a6ad094c5f64e144403fce98337e5012be795841"},
              "converter": {"filename": Path(__file__).name, "sha256": c.sha256(Path(__file__).read_bytes()), "core_sha256": c.sha256(Path(c.__file__).read_bytes())},
              "source_resources": {"dat": dm, "map": mm}, "source_map_info": native, "geometry": geometry,
              "native_bounds": terrain.native_bounds, "target_bounds": [[-center, terrain.native_bounds[0][1], -center], [center, terrain.native_bounds[1][1], center]],
              "transform": {"formula": "target=(source.x-center,source.y,center-source.z)", "scale": [1, 1, -1], "translation": [-center, 0, center]},
              "grid": {"vertex_side": terrain.tiles + 1, "tile_side": terrain.tiles, "tile_size": terrain.tile_size, "heightmap": "3302_heights.f32", "heightmap_sha256": c.sha256(heights), "heightmap_format": "little-endian float32; source-x-major/source-z-minor"},
              "project_environment": project, "water": water,
              "landing": {"tile_flags": "3302_landing_flags.u8", "tile_flags_sha256": c.sha256(land), "enabled_tile_count": sum(land), "tile_flags_format": "uint8 source-x-major/source-z-minor; TILEINFOCLIENT BOOL@16 normalized by nonzero"},
              "omitted": {"object_records": terrain.object_count, "sky_clouds": "Separate original_sky3002 according to MAP_INFO", "detail_texture": True, "legacy_lighting_fog_LOD": True},
              "compatibility_note": "Original terrain geometry and bound JPEG bytes; glTF renderer adaptation. Native collision B-D diagonal is distinct from visual A-C."}
    (output / "3302_terrain.json").write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")
    return report


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    for name in ("dat", "map", "workspace", "rules", "output"):
        p.add_argument("--" + name, type=Path, required=True)
    a = p.parse_args(); r = convert(a.dat, a.map, a.workspace, a.rules, a.output)
    print(json.dumps({"resource_id": r["resource_id"], "geometry_sha256": r["geometry"]["sha256"], "triangles": r["geometry"]["triangle_count"]}))
