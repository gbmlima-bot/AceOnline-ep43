#!/usr/bin/env python3
"""Test native spawn offsets, stream boundaries, source coverage and guards."""
import hashlib
import io
import json
from pathlib import Path
import struct
import unittest
from unittest.mock import patch

import export_native_spawns as exporter

ASSETS = Path(__file__).resolve().parents[1] / "client/assets"


def fixture_dat(event_enabled=1, event_type=6):
    record = bytearray(112)
    struct.pack_into("<I", record, 0, 3018500)  # Visual object code.
    struct.pack_into("<3f", record, 8, 123.5, 45.0, 678.0)
    struct.pack_into("<3f", record, 20, 0.0, 0.0, 1.0)
    struct.pack_into("<3f", record, 32, 0.0, 1.0, 0.0)
    struct.pack_into("<I", record, 44, 2124000)  # Actual MonsterUID.
    record[48] = 1
    struct.pack_into("<I", record, 52, 3018500)  # Next event is NOT MonsterUID.
    record[56] = 7
    struct.pack_into("<i", record, 60, event_enabled)
    record[64] = event_type
    struct.pack_into("<3h", record, 66, 506, 0, 4320)
    payload = bytes(20) + struct.pack("<fiii", 40.0, 9, 4, 1)
    payload += bytes(9 * 24 + 4 * 24) + record
    container = struct.pack("<5i", 1000, 1000, 0, 1, 0)
    container += struct.pack("<3i10s2s", 0, len(payload), 0, b"3004", b"\0\0") + payload
    return container, bytes(record)


class SpawnDecoderTests(unittest.TestCase):
    def test_monster_identity_pose_flags_and_record_hash(self):
        data, record = fixture_dat()
        metadata, rows = exporter.parse_dat(data, 3004)
        self.assertEqual(len(rows), 1)
        row = rows[0]
        self.assertEqual(row["monster_uid"], 2124000)
        self.assertNotEqual(row["monster_uid"], row["object_code"])
        self.assertEqual(row["next_event_index"], 3018500)
        self.assertEqual(row["position_native"], [123.5, 45.0, 678.0])
        self.assertEqual(row["parameters"], [506, 0, 4320])
        self.assertEqual((row["is_city_war_raw"], row["body_condition_raw"]), (1, 7))
        self.assertEqual(row["source"]["sha256"], hashlib.sha256(record).hexdigest())
        self.assertEqual(data[row["source"]["offset"]:row["source"]["offset"] + 112], record)
        self.assertEqual(metadata["tile_count_x"], 2)

    def test_event_flag_is_retained_not_invented_as_native_type_gate(self):
        data, _ = fixture_dat(event_enabled=0)
        _, rows = exporter.parse_dat(data, 3004)
        self.assertEqual(len(rows), 1)
        self.assertFalse(rows[0]["event_enabled"])
        self.assertEqual(rows[0]["event_enabled_raw"], 0)
        _, rows = exporter.parse_dat(fixture_dat(event_type=9)[0], 3004)
        self.assertEqual(rows, [])

    def test_truncated_payload_and_wrong_map_entry_refused(self):
        data, _ = fixture_dat()
        with self.assertRaises(ValueError):
            exporter.parse_dat(data[:-1], 3004)
        with self.assertRaises(ValueError):
            exporter.parse_dat(data, 3005)

    def test_stream_read_never_crosses_source_boundary(self):
        stream = io.BytesIO(b"fileOnefileTwo")
        self.assertEqual(exporter.read_exact(stream, 7), b"fileOne")
        self.assertEqual(exporter.read_exact(stream, 7), b"fileTwo")
        with self.assertRaises(ValueError):
            exporter.read_exact(stream, 1)

    def test_region_padding_units_and_source_hash(self):
        record = struct.pack("<40sI6hHBx", b"region", 2008200, 0, 0, 1, 1, 1, 1, 15, 1)
        raw = bytes(20 + 4 * 76) + struct.pack("<i", 1) + record
        with patch.object(exporter, "SMA_SHA", exporter.sha(raw)):
            metadata, rows = exporter.parse_sma(raw, 4001, 2, 2, 40.0)
        self.assertEqual(metadata["region_count"], 1)
        self.assertEqual(rows[0]["monster_uid"], 2008200)
        self.assertEqual(rows[0]["respawn_time"], 15)
        self.assertEqual(rows[0]["spawn_type"], 1)
        self.assertEqual(rows[0]["source"]["size"], 60)
        self.assertEqual(rows[0]["source"]["sha256"], exporter.sha(record))
        with self.assertRaises(ValueError):
            exporter.parse_sma(raw, 4001, 2, 2, 40.0)


class SpawnArtifactTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.path = ASSETS / "legacy_rules/native_spawns.json"
        cls.data = json.loads(cls.path.read_text())
        cls.inventory_path = ASSETS / "original_library/source_inventory.json"
        cls.inventory = {row["path"]: row for row in json.loads(cls.inventory_path.read_text())["records"]}

    def test_all_native_source_file_sizes_and_hashes_match_full_client_inventory(self):
        data = self.data
        self.assertEqual(data["source_archive"]["sha256"], exporter.ARCHIVE_SHA)
        self.assertEqual(exporter.file_sha(self.inventory_path), data["source_inventory_sha256"])
        self.assertEqual(len(data["source_files"]), 222)
        for source in data["source_files"]:
            original = self.inventory[source["archive_path"]]
            self.assertEqual(source["sha256"], original["sha256"])
            self.assertEqual(source["size"], original["size"])
        self.assertEqual(data["coverage"]["source_bytes_streamed"], 689105288)

    def test_spawn_counts_current_monster_membership_map_sources_and_record_extents(self):
        current_path = ASSETS / "original_library/catalogs/monsters.json"
        current_ids = {m["MonsterUnitKind"] for m in json.loads(current_path.read_text())["records"]}
        self.assertEqual(exporter.file_sha(current_path), self.data["current_monster_catalog_sha256"])
        sources = {r["id"]: r for r in self.data["source_files"]}
        objects = self.data["object_spawns"]
        self.assertEqual(len(objects), 3498)
        self.assertEqual(len({r["map_id"] for r in objects}), 132)
        self.assertEqual(sum(r["event_enabled"] for r in objects), 3458)
        self.assertEqual(sum(not r["monster_in_current_catalog"] for r in objects), 5)
        self.assertTrue(all(r["monster_uid"] == 0 for r in objects if not r["monster_in_current_catalog"]))
        for row in objects + self.data["region_spawns"]:
            self.assertEqual(row["monster_in_current_catalog"], row["monster_uid"] in current_ids)
            source = sources[row["source"]["id"]]
            self.assertTrue(0 <= row["source"]["offset"] <= source["size"] - row["source"]["size"])
            self.assertRegex(row["source"]["sha256"], r"^[0-9a-f]{64}$")
            self.assertEqual(row["map_id"], int(source["id"].split(":")[1]))
        self.assertTrue(all(row["event_type"] == 6 and row["parameters"][2] >= 0 for row in objects))
        self.assertEqual(len(self.data["region_spawns"]), 5)
        self.assertTrue(all(row["map_id"] == 4001 and row["monster_uid"] == 2008200
                            and row["respawn_time"] == 15 and row["spawn_type"] == 1
                            for row in self.data["region_spawns"]))

    def test_original_event_record_provenance_and_pose_match_existing_catalog(self):
        previous = json.loads((ASSETS / "original_worlds/events-catalog.json").read_text())
        old = {(r["map_id"], r["_source"]["record_index"]): r for r in previous["events"] if r["event_type"] == 6}
        new = {(r["map_id"], r["source"]["record_index"]): r for r in self.data["object_spawns"]}
        self.assertEqual(len(old), 3458)
        self.assertEqual(len(new), 3498)
        for key, record in old.items():
            recovered = new[key]
            self.assertEqual(record["_source"]["sha256"], recovered["source"]["sha256"])
            self.assertEqual(record["_source"]["offset"], recovered["source"]["offset"])
            self.assertEqual(record["position_legacy"], recovered["position_native"])
            self.assertEqual(record["parameters"], recovered["parameters"])
        sample = new[(3004, 68)]
        self.assertEqual(sample["monster_uid"], 2124000)
        self.assertEqual(sample["next_event_index"], 3018500)

    def test_runtime_native_gates_and_time_units_are_explicit(self):
        rules = self.data["native_rules"]
        self.assertEqual(rules["object"]["automatic_spawn_excluded_belligerence"], [12, 13, 18, 19])
        self.assertEqual(rules["object"]["respawn_time_unit"], "seconds")
        self.assertEqual(rules["region"]["normal_respawn_time_unit"], "seconds")
        self.assertEqual(rules["region"]["boss_respawn_time_unit"], "minutes")
        self.assertEqual(rules["region"]["boss_initial_delay_seconds"], 300)
        self.assertEqual(rules["region"]["spawn_types"]["0"], "boss")


if __name__ == "__main__":
    unittest.main(verbosity=2)
