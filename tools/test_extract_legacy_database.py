#!/usr/bin/env python3
"""Focused native-page decoder and published static-data integrity checks."""
import hashlib
import json
from pathlib import Path
import struct
import tempfile
import unittest

import extract_legacy_database as decoder

ASSETS = Path(__file__).resolve().parents[1] / "client/assets/native_server"


def integer_schema(name="id", nullbit=1):
    return {"name": name, "nullbit": nullbit, "offset": 4, "type_id": 56,
            "length": 4, "bitpos": 0}


def varchar_schema(offset=-1, collation=0x3400d008, nullbit=1):
    return {"name": "text", "nullbit": nullbit, "offset": offset,
            "type_id": 167, "length": 100, "collation_id": collation}


def row(fixed=b"", columns=1, nulls=b"\0", variable_values=None):
    has_variables = variable_values is not None
    end = 4 + len(fixed)
    prefix = struct.pack("<BBH", 0x30 if has_variables else 0x10, 0, end)
    prefix += fixed + struct.pack("<H", columns) + nulls
    if not has_variables:
        return prefix
    base = len(prefix) + 2 + len(variable_values) * 2
    ends, payload = [], b""
    for value in variable_values:
        payload += value
        ends.append(base + len(payload))
    return prefix + struct.pack("<H", len(ends)) + b"".join(
        struct.pack("<H", end) for end in ends) + payload


class NativePageTests(unittest.TestCase):
    def test_physical_null_bit_and_signed_integer(self):
        record = row(struct.pack("<i", -32768), columns=2, nulls=b"\x02")
        self.assertEqual(decoder.decode_row(record, [integer_schema()]), [-32768])
        self.assertEqual(decoder.decode_row(record, [integer_schema(nullbit=2)]), [None])

    def test_variable_order_includes_hidden_uniqueifier(self):
        record = row(columns=2, nulls=b"\0", variable_values=[b"", b"NPC"])
        self.assertEqual(decoder.decode_row(record, [varchar_schema(offset=-2, nullbit=2)]), ["NPC"])

    def test_korean_wansung_and_trailing_empty(self):
        record = row(columns=2, nulls=b"\0", variable_values=["상점".encode("cp949")])
        self.assertEqual(decoder.decode_row(record, [varchar_schema(collation=0xd011)]), ["상점"])
        self.assertEqual(decoder.decode_row(record, [varchar_schema(offset=-2, nullbit=2)]), [""])

    def test_null_and_empty_varchar_remain_different(self):
        self.assertEqual(decoder.decode_row(row(nulls=b"\x01"), [varchar_schema()]), [None])
        self.assertEqual(decoder.decode_row(row(), [varchar_schema()]), [""])

    def test_datetime_native_storage_is_ticks_then_days(self):
        record = row(struct.pack("<Ii", 450, 1))
        schema = [{"name": "date", "nullbit": 1, "offset": 4, "type_id": 61, "length": 8}]
        self.assertEqual(decoder.decode_row(record, schema), ["1900-01-02T00:00:01.500"])

    def test_rejects_bad_variable_offset_and_unknown_collation(self):
        record = bytearray(row(variable_values=[b"x"]))
        record[9:11] = b"\xff\xff"
        with self.assertRaises(decoder.DecodeError):
            decoder.decode_row(bytes(record), [varchar_schema()])
        with self.assertRaises(decoder.DecodeError):
            decoder.decode_row(row(variable_values=[b"x"]), [varchar_schema(collation=123)])

    def test_zero_heap_slots_are_not_records(self):
        page = bytearray(8192)
        record = row(struct.pack("<i", 123))
        struct.pack_into("<H", page, 22, 2)
        struct.pack_into("<H", page, 30, 96 + len(record))
        page[96:96 + len(record)] = record
        struct.pack_into("<HH", page, 8188, 0, 96)
        self.assertEqual(list(decoder.page_records(bytes(page))), [(0, record)])

    def test_rejects_unreviewed_backup_before_creating_output(self):
        with tempfile.TemporaryDirectory() as directory:
            backup = Path(directory) / "other.bak"
            backup.write_bytes(b"TAPE arbitrary unreviewed content")
            output = Path(directory) / "output"
            with self.assertRaises(decoder.DecodeError):
                decoder.export_backup(backup, output)
            self.assertFalse(output.exists())


class StaticArtifactTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.manifest = json.loads((ASSETS / "manifest.json").read_text())

    def load(self, name):
        obj = json.loads((ASSETS / (name + ".json")).read_text())
        return [dict(zip(obj["columns"], row)) for row in obj["rows"]]

    def test_explicit_allowlist_and_privacy_boundary(self):
        exported = self.manifest["exported"]
        self.assertEqual({entry["table"] for entry in exported},
                         decoder.STATIC_TABLES - {"ti_DissolutionItem"})
        expected = {entry["file"] for entry in exported} | {"manifest.json"}
        self.assertEqual({path.name for path in ASSETS.iterdir()}, expected)
        banned = ("account", "password", "passwd", "characteruid", "charactername", "guildname", "tenderuid")
        for entry in exported:
            for column in entry["schema"]:
                if entry["table"] == "ti_ItemEvent" and column["name"] == "CheckWithCharacterUID":
                    continue  # Explicitly reviewed BOOL mode flag, never an identity.
                self.assertFalse(any(token in column["name"].lower() for token in banned))
        self.assertTrue(all(row["CheckWithCharacterUID"] in (None, 0, 1)
                            for row in self.load("ti_ItemEvent")))
        self.assertFalse((ASSETS / "ti_Tender.json").exists())
        self.assertFalse((ASSETS / "ti_OutPostNextWarTime.json").exists())

    def test_every_file_digest_size_row_count_and_shape(self):
        total = 0
        for entry in self.manifest["exported"]:
            data = (ASSETS / entry["file"]).read_bytes()
            self.assertEqual(len(data), entry["bytes"])
            self.assertEqual(hashlib.sha256(data).hexdigest(), entry["sha256"])
            obj = json.loads(data)
            self.assertEqual(obj["source_sha256"], decoder.BACKUP_SHA256)
            self.assertEqual(len(obj["rows"]), entry["catalog_rows"])
            self.assertEqual(len(obj["rows"]), entry["decoded_rows"])
            self.assertEqual(len(obj["columns"]), entry["columns"])
            self.assertTrue(all(len(row) == len(obj["columns"]) for row in obj["rows"]))
            total += len(obj["rows"])
        self.assertEqual(total, self.manifest["exported_rows"])

    def test_drop_units_bounds_and_all_native_foreign_keys(self):
        monsters, items, drops = self.load("ti_Monster"), self.load("ti_Item"), self.load("ti_MonsterItem")
        monster_ids = {m["UniqueNumber"] for m in monsters}
        item_ids = {i["ItemNum"] for i in items if isinstance(i["ItemNum"], int)}
        self.assertEqual(len(monsters), 1300)
        self.assertEqual(len(monster_ids), 1300)
        self.assertEqual(len(drops), 70406)
        self.assertTrue(all(m["HP"] > 0 and m["Experience"] >= 0 for m in monsters))
        for drop in drops:
            self.assertIn(drop["MonsterUniqueNumber"], monster_ids)
            self.assertIn(drop["ItemNum"], item_ids)
            self.assertTrue(0 <= drop["MinCount"] <= drop["MaxCount"])
            self.assertTrue(0 <= drop["Probability"] <= 1_000_000)
            self.assertGreaterEqual(drop["PrefixProbability"], 0)
            self.assertGreaterEqual(drop["SuffixProbability"], 0)
            self.assertIn(drop["DropType"], (0, 1))

    def test_known_item_anomaly_and_withheld_count_mismatch_are_visible(self):
        self.assertEqual(sum(item["ItemNum"] is None for item in self.load("ti_Item")), 1)
        anomalies = self.manifest["semantic_checks"]["anomalies"]
        self.assertEqual(anomalies["item_rows_with_null_item_num"], 1)
        drops = self.load("ti_MonsterItem")
        self.assertEqual(anomalies["prefix_probability_above_cpp_documented_100000_scale"],
                         sum(row["PrefixProbability"] > 100_000 for row in drops))
        self.assertEqual(anomalies["suffix_probability_above_cpp_documented_100000_scale"],
                         sum(row["SuffixProbability"] > 100_000 for row in drops))
        self.assertEqual(anomalies["prefix_probability_above_cpp_documented_100000_scale"], 1401)
        self.assertEqual([entry["table"] for entry in self.manifest["withheld"]], ["ti_DissolutionItem"])
        self.assertFalse((ASSETS / "ti_DissolutionItem.json").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
