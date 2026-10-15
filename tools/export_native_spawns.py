#!/usr/bin/env python3
"""Stream the pinned client archive and recover native object/region spawns.

Only one resource (at most 4 MiB in this pinned archive) is retained in memory.
No game executable is run, no resource tree is written, and all source files and
spawn records retain SHA-256 provenance. Unresolved native gates remain explicit.
"""
from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
import math
from pathlib import Path
import re
import struct
import subprocess
import tempfile

ARCHIVE_SHA = "8395f1f33dda8165f70f30d2a6ad094c5f64e144403fce98337e5012be795841"
EP35_COMMIT = "7c3e47ac47844e5c415d356a94d6201a0b9a38c4"
SMA_SHA = "7752010d9e020e7d261ae46268867ff6ceebda6d8aaa9e3073966043c6804493"
MAX_SOURCE_SIZE = 4 * 1024 * 1024
ROOT = Path(__file__).resolve().parents[1]


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def file_sha(path):
    h = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def parse_dat(raw, map_id):
    require(20 <= len(raw) <= MAX_SOURCE_SIZE, "DAT size outside reviewed bounds")
    encoded, identification, _, count, _ = struct.unpack_from("<5i", raw)
    require((encoded, identification) == (1000, 1000), "Unknown DAT container encoding")
    require(1 <= count <= 100, "Invalid DAT entry count")
    offset, matches = 20, []
    for _ in range(count):
        require(offset + 24 <= len(raw), "Truncated DAT entry header")
        _, size, _, name, _ = struct.unpack_from("<3i10s2s", raw, offset)
        offset += 24
        require(0 <= size <= len(raw) - offset, "DAT entry extends outside source")
        if name.split(b"\0")[0].decode("ascii") == str(map_id):
            matches.append((offset, raw[offset:offset + size]))
        offset += size
    require(len(matches) == 1, "Expected one numeric terrain entry")
    entry_offset, payload = matches[0]
    require(len(payload) >= 36, "Truncated terrain header")
    tile_size, vertices, tiles, objects = struct.unpack_from("<fiii", payload, 20)
    side = math.isqrt(vertices) if vertices >= 0 else 0
    require(math.isfinite(tile_size) and tile_size > 0 and side >= 2 and side * side == vertices
            and (side - 1) ** 2 == tiles and objects >= 0, "Invalid terrain grid/counts")
    object_start = 36 + vertices * 24 + tiles * 24
    require(object_start + objects * 112 == len(payload), "Terrain array extent mismatch")
    result = []
    for index in range(objects):
        pos = object_start + index * 112
        record = payload[pos:pos + 112]
        if record[64] != 6:
            continue
        vectors = [list(struct.unpack_from("<3f", record, at)) for at in (8, 20, 32)]
        require(all(math.isfinite(x) for v in vectors for x in v), "Non-finite spawn pose")
        params = list(struct.unpack_from("<3h", record, 66))
        result.append({
            "map_id": map_id, "event_id": params[0], "monster_uid": struct.unpack_from("<I", record, 44)[0],
            "object_code": struct.unpack_from("<I", record)[0], "position_native": vectors[0],
            "direction_native": vectors[1], "up_native": vectors[2], "event_type": 6,
            "event_enabled": bool(struct.unpack_from("<i", record, 60)[0]),
            "event_enabled_raw": struct.unpack_from("<i", record, 60)[0],
            "body_condition_raw": record[56], "is_city_war_raw": record[48],
            "parameters": params, "next_event_index": struct.unpack_from("<I", record, 52)[0],
            "source": {"id": f"dat:{map_id}", "offset": entry_offset + pos,
                       "size": 112, "record_index": index, "sha256": sha(record)},
        })
    metadata = {"id": f"dat:{map_id}", "archive_path": f"Res-map/{map_id}.dat",
                "size": len(raw), "sha256": sha(raw), "entry_offset": entry_offset,
                "tile_size_native": tile_size, "tile_count_x": side - 1,
                "tile_count_z": side - 1, "object_count": objects,
                "object_spawn_count": len(result)}
    return metadata, result


def parse_sma(raw, map_id, tiles_x, tiles_z, tile_size):
    require(map_id == 4001 and sha(raw) == SMA_SHA, "SMA is not the reviewed 4001 source")
    # Win32 _TILEINFO4LOADING is 76 bytes; MONSTER_CREATE_REGION_INFO is 60.
    offset = 20 + tiles_x * tiles_z * 76
    require(offset + 4 <= len(raw), "SMA tile array extends outside source")
    count = struct.unpack_from("<i", raw, offset)[0]
    offset += 4
    require(0 <= count <= 10_000 and offset + count * 60 == len(raw), "SMA region extent mismatch")
    rows = []
    for index in range(count):
        start = offset + index * 60
        record = raw[start:start + 60]
        values = struct.unpack("<40sI6hHBx", record)
        name, uid, sx, sz, ex, ez, maximum, respawn_count, respawn_time, spawn_type = values
        require(0 <= sx <= ex < tiles_x and 0 <= sz <= ez < tiles_z, "SMA region outside native grid")
        require(maximum >= 0 and respawn_count >= 0 and spawn_type in range(5), "Invalid SMA region values")
        rows.append({"map_id": map_id, "region_name": name.split(b"\0")[0].decode("cp949"),
                     "monster_uid": uid, "start_x_tile": sx, "start_z_tile": sz,
                     "end_x_tile": ex, "end_z_tile": ez, "max_monsters": maximum,
                     "respawn_count": respawn_count, "respawn_time": respawn_time,
                     "spawn_type": spawn_type, "tile_size_native": tile_size,
                     "source": {"id": "sma:4001", "offset": start, "size": 60,
                                "record_index": index, "sha256": sha(record)}})
    return {"id": "sma:4001", "archive_path": "Res-map/4001.sma", "size": len(raw),
            "sha256": sha(raw), "tile_record_size": 76, "region_record_size": 60,
            "region_count": count, "header_words": list(struct.unpack_from("<5i", raw))}, rows


def native_rules():
    return {
        "ep35_commit": EP35_COMMIT,
        "coordinate_units": "Native map world units; X/Z origin unchanged, Y altitude; no handedness/center conversion.",
        "object": {
            "function": "CNPCMapChannel::CreateMonstersBYObject",
            "source": "Server/GameServer/NPCServer/Main/NPCMapChannel.cpp:665",
            "classification": "EVENT_TYPE_OBJECT_MONSTER=6 at AtumParam.h:2297; MonsterUID is OBJECTINFOCLIENT offset44, not next_event_index52.",
            "respawn_time_field": "parameters[2]", "respawn_time_unit": "seconds",
            "tick_term_ms": 1000,
            "normal_interval_test": "parameters[2]*1000 <= now_ms-last_object_creation_or_deletion_ms",
            "one_alive_per_placement": True,
            "on_delete": "Set last timestamp to now and object_created=false (NPCMapChannel.cpp:5138).",
            "forced_creation": "MustCreate bypasses strategy/teleport automatic-spawn exclusion, interval and channel-count checks, but not every later native gate.",
            "automatic_spawn_excluded_belligerence": [12, 13, 18, 19],
            "war_belligerence_range": [10, 29],
            "gates": [
                "AutoCreateMonsterChannel must be enabled; tutorial/outpost maps skip automatic creation (NPCMapChannel.cpp:238).",
                "An existing live object monster blocks another creation.",
                "Infinity maps initialize object creation blocked and require cinema/regeneration state (MapProject.cpp:773; NPCMapChannel.cpp:675,2778).",
                "Strategy-point/teleport monsters require an explicit server trigger during normal automatic spawning.",
                "Respect channel monster capacity, disabled-spawn state, faction/channel0 checks, and IsEnableCreateMonster war/arena/Jaco conditions.",
                "Current monster definition must exist; constructor drops placements with unknown MonsterUID.",
            ],
            "raw_fields_note": "is_city_war_raw is copied to m_byBossMonster by this server revision; preserve it. event_enabled/body_condition fields are retained, not newly invented spawn gates.",
        },
        "region": {
            "function": "CNPCMapChannel::CreateMonstersBYRegion",
            "source": "Server/GameServer/NPCServer/Main/NPCMapChannel.cpp:466",
            "loader": "CMapProject::LoadMap MapProject.cpp:244,449; map/%04d.sma; debug-only .sma2 fallback.",
            "spawn_types": {"0": "boss", "1": "large", "2": "middle", "3": "small", "4": "summon"},
            "bounds_unit": "tile indices; SIZE_MAP_TILE_SIZE=40 (MapBlock.h:12)",
            "normal_respawn_time_unit": "seconds", "boss_respawn_time_unit": "minutes",
            "boss_initial_delay_seconds": 300,
            "boss_later_delay_minutes": "max(1, floor(respawn_time/3) + RANDI(1,max(1,floor(respawn_time*2/3))))",
            "normal_first_delay_seconds": "respawn_time; per-region last timestamp initializes to channel creation time.",
            "population": "Count matching monster type in map blocks covering the tile rectangle (NPCGetMonsterCountInRegion:5725); deficit=min(max_monsters-current,respawn_count); spawn RANDI(1,deficit) if positive, bounded by channel/region limits.",
            "position": "NPCGetCreatablePosition applies native form, size, tile rectangle, altitude, terrain/water and clearance rules; no fixed center is stored in SMA.",
            "position_randomization": "NPCMapChannel.cpp:5809: x=start_x_tile*40+rand()%((end_x_tile-start_x_tile)*40), and similarly z. The upper bound is EXCLUSIVE. Try at most requested_count*2 candidate positions; reject invalid monster tiles and nearby characters.",
            "altitude": "For flying forms, native non-absolute altitude is terrain_or_water_height+MinGroundHeight+rand()%(MaxGroundHeight-MinGroundHeight). Ground movers use terrain_or_water_height+monster_size; swimming forms have separate water rules (NPCMapChannel.cpp:5828).",
            "on_delete": "Decrease current region count and reset region last-creation timestamp.",
            "gates": "Native auto-create, tutorial/outpost, war/channel, capacity, valid-position and IsEnableCreateMonster gates still apply; caller MustCreate bypasses timing/count prechecks.",
        },
        "additional_source_evidence": [
            "Server/GameServer/CommonGameServer/MapProject.h:64 (60-byte region structure)",
            "Server/GameServer/CommonGameServer/MapProject.cpp:761 (DAT MonsterUID mapping)",
            "Client/Common/ObjectDefine.h:639 (112-byte object structure)",
            "Server/GameServer/NPCServer/Main/NPCMapChannel.cpp:6989 (war gate)",
        ],
    }


def archive_order(sevenzip, archive, expected):
    result = subprocess.run([str(sevenzip), "l", "-slt", "-ba", str(archive)],
                            check=True, capture_output=True, text=True)
    selected = []
    for block in result.stdout.split("\n\n"):
        record = dict(line.split(" = ", 1) for line in block.splitlines() if " = " in line)
        path = record.get("Path")
        if path not in expected:
            continue
        require(int(record.get("Size", -1)) == expected[path]["size"], "Archive listing size mismatch")
        require(record.get("CRC", "").lower() == expected[path]["crc32"].lower(), "Archive listing CRC mismatch")
        selected.append(path)
    require(len(selected) == len(set(selected)) == len(expected), "Archive source listing mismatch")
    return selected


def read_exact(stream, size):
    chunks, remaining = [], size
    while remaining:
        block = stream.read(min(remaining, 1024 * 1024))
        if not block:
            raise ValueError("Truncated 7-Zip output stream")
        chunks.append(block)
        remaining -= len(block)
    return b"".join(chunks)


def export(archive, sevenzip, inventory_path, current_monsters_path, output):
    require(file_sha(archive) == ARCHIVE_SHA, "Unknown client archive SHA-256")
    inventory = json.loads(inventory_path.read_text())
    require(inventory["archive"]["sha256"] == ARCHIVE_SHA, "Inventory archive identity mismatch")
    expected = {r["path"]: r for r in inventory["records"]
                if re.fullmatch(r"Res-map/[0-9]{4}\.dat", r["path"]) or r["path"] == "Res-map/4001.sma"}
    require(len(expected) == 222, "Expected all 221 DATs and the single available SMA")
    require(all(0 < r["size"] <= MAX_SOURCE_SIZE for r in expected.values()), "Source exceeds bounded streaming profile")
    order = archive_order(sevenzip, archive, expected)
    current_monsters = json.loads(current_monsters_path.read_text())
    monster_ids = {r["MonsterUnitKind"] for r in current_monsters["records"]}
    source_files, objects, regions, sma = [], [], [], None
    by_map = {}
    with tempfile.TemporaryDirectory(prefix="ace-spawn-stream-") as temporary:
        names = Path(temporary) / "sources.txt"
        names.write_text("\n".join(order) + "\n")
        errors = Path(temporary) / "7zip-errors.txt"
        with errors.open("wb") as error_stream:
            process = subprocess.Popen([str(sevenzip), "e", "-so", "-spd", "-y", str(archive), "@" + str(names)],
                                       stdout=subprocess.PIPE, stderr=error_stream)
            try:
                for path in order:
                    row = expected[path]
                    raw = read_exact(process.stdout, row["size"])
                    require(sha(raw) == row["sha256"], "Streamed file SHA-256 mismatch: " + path)
                    if path.endswith(".sma"):
                        sma = raw
                    else:
                        map_id = int(Path(path).stem)
                        metadata, rows = parse_dat(raw, map_id)
                        by_map[map_id] = metadata
                        source_files.append(metadata)
                        objects.extend(rows)
                require(process.stdout.read(1) == b"", "Unexpected additional 7-Zip output")
                require(process.wait() == 0, "7-Zip extraction failed")
            finally:
                if process.poll() is None:
                    process.terminate()
                    process.wait()
    require(sma is not None and 4001 in by_map, "Missing paired SMA/DAT 4001")
    grid = by_map[4001]
    metadata, regions = parse_sma(sma, 4001, grid["tile_count_x"], grid["tile_count_z"], grid["tile_size_native"])
    source_files.append(metadata)
    for record in objects + regions:
        record["monster_in_current_catalog"] = record["monster_uid"] in monster_ids
    objects.sort(key=lambda row: (row["map_id"], row["source"]["record_index"]))
    coverage = {"dat_sources_verified": len(by_map), "sma_sources_available": 1,
                "source_bytes_streamed": sum(row["size"] for row in expected.values()),
                "object_spawn_records": len(objects), "object_spawn_maps": len({r["map_id"] for r in objects}),
                "object_spawns_with_event_flag_enabled": sum(r["event_enabled"] for r in objects),
                "object_spawns_unknown_current_monster": sum(not r["monster_in_current_catalog"] for r in objects),
                "object_spawns_with_negative_respawn_parameter": sum(r["parameters"][2] < 0 for r in objects),
                "region_spawn_records": len(regions), "region_spawn_maps": [4001],
                "region_spawns_unknown_current_monster": sum(not r["monster_in_current_catalog"] for r in regions),
                "object_records_by_map": dict(sorted(Counter(r["map_id"] for r in objects).items()))}
    document = {"schema_version": 1,
                "source_archive": {"filename": archive.name, "sha256": ARCHIVE_SHA, "size": archive.stat().st_size},
                "source_inventory_sha256": file_sha(inventory_path),
                "current_monster_catalog_sha256": file_sha(current_monsters_path),
                "source_files": sorted(source_files, key=lambda r: r["archive_path"]),
                "object_spawns": objects, "region_spawns": regions, "native_rules": native_rules(),
                "coverage": coverage,
                "limitations": [
                    "Native data availability is partial: object placements cover only their recorded types; only one map has regional SMA data.",
                    "No unsupplied regional SMA records or flying-monster populations are inferred.",
                    "Native war/Infinity/cinema/teleport/strategy-point conditions are preserved and require runtime implementation.",
                    "Native units and axes are retained; a target runtime must apply its existing map transform exactly once.",
                ]}
    output.parent.mkdir(parents=True, exist_ok=True)
    raw = (json.dumps(document, ensure_ascii=False, separators=(",", ":"), allow_nan=False) + "\n").encode()
    output.write_bytes(raw)
    return {"file": str(output), "sha256": sha(raw), "bytes": len(raw), "coverage": coverage}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--sevenzip", type=Path, required=True)
    parser.add_argument("--inventory", type=Path, default=ROOT / "client/assets/original_library/source_inventory.json")
    parser.add_argument("--current-monsters", type=Path, default=ROOT / "client/assets/original_library/catalogs/monsters.json")
    parser.add_argument("--output", type=Path, default=ROOT / "client/assets/legacy_rules/native_spawns.json")
    args = parser.parse_args()
    try:
        report = export(args.archive, args.sevenzip, args.inventory, args.current_monsters, args.output)
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        parser.exit(1, f"Native spawn export refused: {exc}\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
