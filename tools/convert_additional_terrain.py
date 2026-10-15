#!/usr/bin/env python3
"""Convert the explicitly observed second terrain, resource3003, offline."""
import argparse
import json
from pathlib import Path
import struct
import convert_original_terrain as c

EXPECTED = {"3003.dat": "ad1d44cf704355fb335c99b171595f2c3b65e9443867cd0138340cc31d15337b", "3003.map": "9eef1193e26dab132b5fbec1bae7ca922ab11a6a92e726e5bc02d808b7f9d40c"}


def water_tiles(payload, terrain, height):
    start = 36 + len(terrain.vertices) * 24
    side = terrain.tiles + 1
    flags = bytearray(terrain.tiles * terrain.tiles)
    for x in range(terrain.tiles):
        for z in range(terrain.tiles):
            index = x * terrain.tiles + z
            flag = struct.unpack_from("<I", payload, start + index * 24 + 4)[0]
            corners = (x * side + z, (x + 1) * side + z, x * side + z + 1, (x + 1) * side + z + 1)
            flags[index] = int(flag == 1 and any(terrain.vertices[v][1] < height for v in corners))
    return bytes(flags)


def landing_tiles(payload, terrain):
    start = 36 + len(terrain.vertices) * 24
    return bytes(int(struct.unpack_from("<i", payload, start + i * 24 + 16)[0] != 0) for i in range(terrain.tiles * terrain.tiles))


def convert(source: Path, workspace: Path, output: Path):
    output.mkdir(parents=True, exist_ok=True)
    for name, digest in EXPECTED.items():
        c.require(c.sha256((source / name).read_bytes()) == digest, "additional terrain identity mismatch")
    dat, dm = c.parse_resource((source / "3003.dat").read_bytes())
    maps, mm = c.parse_resource((source / "3003.map").read_bytes())
    t = c.parse_terrain(dat["3003"].data)
    project = c.parse_project(workspace.read_bytes(), "3003")
    c.require(project["tile_dimensions"] == [t.tiles, t.tiles], "project/terrain dimensions disagree")
    geometry = c.export_glb(t, maps, output / "3003_terrain.glb", resource_id="3003")
    heights = struct.pack("<" + "f" * len(t.vertices), *(v[1] for v in t.vertices))
    (output / "3003_heights.f32").write_bytes(heights)
    flags = water_tiles(dat["3003"].data, t, project["water_height"])
    (output / "3003_water_flags.u8").write_bytes(flags)
    land = landing_tiles(dat["3003"].data, t)
    (output / "3003_landing_flags.u8").write_bytes(land)
    center = t.tiles * t.tile_size / 2
    water = c.water_patches(dat["3003"].data, t, project["water_height"])
    water.update(active_tile_flags="3003_water_flags.u8", active_tile_flags_sha256=c.sha256(flags), active_tile_flags_format="uint8 source-x-major/source-z-minor, 1 only when original flag1 survives four-corner height filter", active_tile_count=sum(flags))
    report = {"schema_version": 1, "resource_id": 3003, "display_name": None,
              "identity_note": "Numeric resource3003; localized name must come from separately verified current MAP_INFO.",
              "source_code": {"ep35_commit": c.SOURCE_SHA, "ep43_commit": c.EP43_SHA},
              "source_package": {"name": "ACEonline-20250709.7z", "sha256": "8395f1f33dda8165f70f30d2a6ad094c5f64e144403fce98337e5012be795841"},
              "converter": {"filename": Path(__file__).name, "sha256": c.sha256(Path(__file__).read_bytes()), "core_sha256": c.sha256(Path(c.__file__).read_bytes())},
              "source_resources": {"dat": dm, "map": mm}, "geometry": geometry, "native_bounds": t.native_bounds,
              "target_bounds": [[-center, t.native_bounds[0][1], -center], [center, t.native_bounds[1][1], center]],
              "transform": {"formula": "target=(source.x-center,source.y,center-source.z)", "scale": [1, 1, -1], "translation": [-center, 0, center]},
              "grid": {"vertex_side": t.tiles + 1, "tile_side": t.tiles, "tile_size": t.tile_size, "heightmap": "3003_heights.f32", "heightmap_sha256": c.sha256(heights), "heightmap_format": "little-endian float32; source-x-major/source-z-minor"},
              "project_environment": project, "water": water,
              "landing": {"tile_flags": "3003_landing_flags.u8", "tile_flags_sha256": c.sha256(land), "enabled_tile_count": sum(land), "tile_flags_format": "uint8 source-x-major/source-z-minor; original TILEINFOCLIENT BOOL bEnableLand@16 normalized by nonzero", "source_evidence": "ObjectDefine.h TILEINFOCLIENT24bytes; ShuttleChild.cpp:1349,1379,1418,9170-9173"},
              "omitted": {"object_records": t.object_count, "sky_clouds": "separate asset manifest", "detail_texture": True, "legacy_lighting_fog_LOD": True},
              "compatibility_note": "Original positions, normals and JPEG texture bytes; new static glTF renderer. Source render diagonal A-C differs from collision B-D; runtime uses original height rules."}
    (output / "3003_terrain.json").write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")
    return report


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    for name in ("source", "workspace", "output"):
        p.add_argument("--" + name, type=Path, required=True)
    a = p.parse_args(); r = convert(a.source, a.workspace, a.output)
    print(json.dumps({"resource_id": r["resource_id"], "geometry": r["geometry"]["sha256"], "triangles": r["geometry"]["triangle_count"]}))
