#!/usr/bin/env python3
"""Recover only allowlisted static ACE definitions from the pinned SQL backup.

This is a deliberately narrow, read-only native-page decoder, not a SQL Server
restore utility. It refuses other backups and never exports account, login,
character, stored procedure, or raw page content. SQL Server system catalogs
provide physical column offsets, allocation ownership and expected row counts.
"""
from __future__ import annotations

import argparse
from collections import Counter, defaultdict
from datetime import datetime, timedelta
import hashlib
import json
import math
from pathlib import Path
import struct

BACKUP_SHA256 = "e5ae92ac1b2e89ee2ef480d85785aa95d3c2588d386092b988efac558b4a4674"
SOURCE_COMMIT = "7c3e47ac47844e5c415d356a94d6201a0b9a38c4"
SOURCE_REPOSITORY = "https://github.com/bhsdp1/AceOnline-ep35"
STATIC_TABLES = frozenset("""
ti_Monster ti_LevelAdjustment ti_LevelAdjustmentReward ti_InfluenceRate
ti_HPAction ti_Item ti_PetLevel ti_pet ti_OperatorAction ti_DissolutionItem
ti_BurningMap ti_WayPointMove ti_EnchantInfo ti_WayPoint ti_MonsterMultiTarget
ti_InfinityMonster ti_HappyHourEvent ti_InfluenceWar ti_Revision
ti_MysteryItemDrop ti_InfinityMode ti_CityTargetWarpMap ti_InfinityShop
ti_StrategyPointSummonMapIndex ti_ItemParamOverlap ti_InvokingWearItemDPNum
ti_ArenaInfo ti_InvokingWearItemDPNumByUse ti_ArenaMapinfo ti_TutorialInfo
ti_ActionByLevel ti_EventMonster ti_ItemMixingInfo
ti_Cinema ti_RareItemInfo ti_Shop ti_MonsterItem ti_MapObject ti_BuildingNPC
ti_CityTargetWarpMap1 ti_MapInfo ti_LuckyMachine ti_QuestMatching
ti_ItemMatching ti_ItemEvent
""".split())
WITHHELD_OPERATIONAL_TABLES = {
    "ti_Tender": "TenderUID may refer to a live auction identity; not needed for static definitions.",
    "ti_OutPostNextWarTime": "Live outpost war scheduling state, not a static game definition.",
}
TYPE_NAMES = {48: "tinyint", 52: "smallint", 56: "int", 61: "datetime",
              62: "float", 104: "bit", 127: "bigint", 167: "varchar"}
U16 = lambda data, off: struct.unpack_from("<H", data, off)[0]
I16 = lambda data, off: struct.unpack_from("<h", data, off)[0]
U32 = lambda data, off: struct.unpack_from("<I", data, off)[0]
U64 = lambda data, off: struct.unpack_from("<Q", data, off)[0]


class DecodeError(ValueError):
    pass


def native_pages(data: bytes):
    """SQL backup blocks can shift page alignment, so scan 512-byte sectors."""
    for off in range(0, len(data) - 8191, 512):
        page = data[off:off + 8192]
        if page[0] != 1 or page[1] not in (1, 2, 3, 13):
            continue
        slots, free = U16(page, 22), U16(page, 30)
        if slots >= 2000 or not 96 <= free <= 8192 - slots * 2:
            continue
        offsets = [U16(page, 8190 - i * 2) for i in range(slots)]
        # A zero slot is a deleted/unused heap slot, not a record at byte zero.
        if any(p != 0 and not 96 <= p < free for p in offsets):
            continue
        yield off, page


def page_records(page: bytes):
    count = U16(page, 22)
    offsets = [U16(page, 8190 - i * 2) for i in range(count)]
    boundaries = sorted(set(offsets + [U16(page, 30)]))
    for slot, off in enumerate(offsets):
        if off == 0:
            continue
        end = next(value for value in boundaries if value > off)
        record = page[off:end]
        if len(record) < 4:
            raise DecodeError("Truncated record header")
        yield slot, record


def record_parts(record: bytes):
    fixed_end = U16(record, 2)
    if not 4 <= fixed_end <= len(record) - 2:
        raise DecodeError("Invalid fixed-data boundary")
    count = U16(record, fixed_end)
    null_start = fixed_end + 2
    null_end = null_start + (count + 7) // 8
    if null_end > len(record):
        raise DecodeError("Truncated null bitmap")
    variables = []
    if record[0] & 0x20:
        if null_end + 2 > len(record):
            raise DecodeError("Truncated variable-count field")
        variable_count = U16(record, null_end)
        start = null_end + 2 + variable_count * 2
        if start > len(record):
            raise DecodeError("Truncated variable-offset array")
        for index in range(variable_count):
            raw_end = U16(record, null_end + 2 + index * 2)
            if raw_end & 0x8000:
                raise DecodeError("Off-row/complex variable value is unsupported")
            end = raw_end
            if not start <= end <= len(record):
                raise DecodeError("Invalid variable-data boundary")
            variables.append(record[start:end])
            start = end
    return fixed_end, count, record[null_start:null_end], variables


def first_name(record: bytes):
    variables = record_parts(record)[3]
    return variables[0].decode("utf-16le") if variables else None


def read_catalogs(pages):
    tables, columns, rowsets, allocations = {}, defaultdict(dict), {}, {}
    physical = defaultdict(dict)
    for _, page in pages:
        if page[1] != 1:
            continue
        obj, index = U32(page, 24), U16(page, 6)
        if obj not in (3, 5, 7, 34, 41) or (obj in (34, 41) and index != 1):
            continue
        for _, r in page_records(page):
            if ((r[0] >> 1) & 7) != 0:
                continue
            if obj == 34 and len(r) >= 48 and r[17:19] == b"U ":
                name = first_name(r)
                # The explicit names, not a broad prefix, define export scope.
                if name in STATIC_TABLES:
                    tables[U32(r, 4)] = name
            elif obj == 41 and len(r) >= 45:
                name = first_name(r)
                if name:
                    columns[U32(r, 4)][U32(r, 10)] = {
                        "id": U32(r, 10), "name": name, "type_id": r[14],
                        "sql_type": TYPE_NAMES.get(r[14], "unsupported"),
                        "length": U16(r, 19), "collation_id": U32(r, 23),
                    }
            elif obj == 5 and len(r) >= 57:
                rowsets[U64(r, 4)] = {
                    "object_id": U32(r, 13), "index_id": U32(r, 17),
                    "expected_rows": U64(r, 31),
                }
            elif obj == 7 and len(r) >= 73:
                auid = U64(r, 4)
                allocations[auid] = {"type": r[12], "rowset_id": U64(r, 13),
                                     "page_object": auid >> 16 & 0xffffffff,
                                     "page_index": auid >> 48}
            elif obj == 3 and len(r) >= 58:
                physical[U64(r, 4)][U32(r, 12)] = {
                    "offset": I16(r, 44), "nullbit": U16(r, 48),
                    "bitpos": U16(r, 52),
                }
    return tables, columns, rowsets, allocations, physical


def decode_row(record: bytes, schema: list[dict]):
    fixed_end, count, nulls, variables = record_parts(record)
    result = []
    for column in schema:
        nullbit = column["nullbit"] - 1
        if not 0 <= nullbit < count:
            raise DecodeError("Column null bit is outside this row schema")
        if nulls[nullbit // 8] & (1 << (nullbit % 8)):
            result.append(None)
            continue
        offset, kind = column["offset"], column["type_id"]
        if kind == 167:
            if offset >= 0:
                raise DecodeError("varchar has a non-variable physical offset")
            # SQL Server omits trailing empty variable values. NULL is determined
            # by the bitmap above, so a missing non-null trailing value is empty.
            value = variables[-offset - 1] if -offset <= len(variables) else b""
            if len(value) > column["length"]:
                raise DecodeError("varchar exceeds schema maximum length")
            codecs = {0x3400d008: "cp1252", 0xd011: "cp949"}
            if column["collation_id"] not in codecs:
                raise DecodeError("Unrecognized varchar collation/code page")
            result.append(value.decode(codecs[column["collation_id"]]))
            continue
        length = column["length"]
        if not 4 <= offset <= fixed_end - length:
            raise DecodeError("Fixed value extends outside this row")
        if kind in (48, 52, 56, 127):
            result.append(int.from_bytes(record[offset:offset + length], "little",
                                         signed=kind != 48))
        elif kind == 62:
            value = struct.unpack_from("<d", record, offset)[0]
            if not math.isfinite(value):
                raise DecodeError("Non-finite SQL float")
            result.append(value)
        elif kind == 104:
            result.append(bool(record[offset] & (1 << column["bitpos"])))
        elif kind == 61:
            # Native row storage writes time ticks first, unlike TDS datetime.
            ticks, days = struct.unpack_from("<Ii", record, offset)
            value = datetime(1900, 1, 1) + timedelta(days=days, seconds=ticks / 300)
            result.append(value.isoformat(timespec="milliseconds"))
        else:
            raise DecodeError("Unsupported SQL value type")
    return result


def semantic_checks(output: Path):
    def rows(name):
        document = json.loads((output / (name + ".json")).read_text())
        return [dict(zip(document["columns"], row)) for row in document["rows"]]

    monsters, items, drops = rows("ti_Monster"), rows("ti_Item"), rows("ti_MonsterItem")
    monster_ids = {m["UniqueNumber"] for m in monsters}
    item_ids = {i["ItemNum"] for i in items if isinstance(i["ItemNum"], int)}
    return {
        "monster_distinct_ids": len(monster_ids),
        "monsters_with_nonpositive_hp": sum(m["HP"] <= 0 for m in monsters),
        "monsters_with_negative_experience": sum(m["Experience"] < 0 for m in monsters),
        "drop_monster_ids_missing_from_native_catalog": sum(d["MonsterUniqueNumber"] not in monster_ids for d in drops),
        "drop_item_ids_missing_from_native_catalog": sum(d["ItemNum"] not in item_ids for d in drops),
        "drop_invalid_count_ranges": sum(not 0 <= d["MinCount"] <= d["MaxCount"] for d in drops),
        "drop_probability_outside_0_to_1000000": sum(not 0 <= d["Probability"] <= 1_000_000 for d in drops),
        "drop_type_counts": dict(Counter(d["DropType"] for d in drops)),
        "anomalies": {
            "item_rows_with_null_item_num": sum(i["ItemNum"] is None for i in items),
            "prefix_probability_above_cpp_documented_100000_scale": sum(d["PrefixProbability"] > 100_000 for d in drops),
            "suffix_probability_above_cpp_documented_100000_scale": sum(d["SuffixProbability"] > 100_000 for d in drops),
            "rare_probability_note": "Raw backup values reach 600000; do not assume the documented 100000 rare-probability scale or normalize these values without further source reconciliation.",
        },
    }


def export_backup(backup: Path, output: Path):
    data = backup.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    if digest != BACKUP_SHA256:
        raise DecodeError("Backup SHA-256 differs from the reviewed static-data source")
    if not data.startswith(b"TAPE"):
        raise DecodeError("Expected an uncompressed SQL Server native backup")
    pages = list(native_pages(data))
    tables, columns, rowsets, allocations, physical = read_catalogs(pages)
    if set(tables.values()) != STATIC_TABLES:
        raise DecodeError("Static-table catalog differs from the reviewed backup")
    source = {
        "repository": SOURCE_REPOSITORY, "commit": SOURCE_COMMIT,
        "path": "Database/acc.bak", "sha256": digest, "bytes": len(data),
        "logical_database": "atum2_db_account", "engine_family": "SQL Server 2017",
        "backup_created_at": None,
        "backup_date_note": "Backup header timestamp has not been independently decoded.",
        "encodings": {"0x3400d008": "Windows-1252 (SQL_Latin1_General_CP1_CI_AS)",
                      "0xd011": "Windows-949 (Korean_Wansung_CI_AS)"},
    }
    boot_pages = [p for _, p in pages if p[1] == 13 and U16(p, 36) == 1 and U32(p, 32) == 9]
    if len(boot_pages) != 1:
        raise DecodeError("Expected exactly one primary database boot page")
    source["database_format_version"] = U16(boot_pages[0], 100)
    source["creation_format_version"] = U16(boot_pages[0], 102)
    if (source["database_format_version"], source["creation_format_version"]) != (869, 611):
        raise DecodeError("Unexpected database format versions")
    report = {"schema_version": 1, "source": source, "exported": [], "withheld": [],
              "operational_tables_withheld": WITHHELD_OPERATIONAL_TABLES,
              "privacy_review": {
                  "ti_InfluenceWar": "Static faction/stage enums, rates, item/monster definitions and summon coordinates; no account, character or ownership IDs.",
                  "ti_InfluenceRate": "Static StartLevel/EndLevel ranges only.",
                  "ti_OperatorAction": "Static action type, item/function/source IDs, numeric value and action description; no admin credentials.",
                  "ti_ItemEvent.CheckWithCharacterUID": "A BOOL validation-mode flag in AtumParam.h:2714, not a character identity. Observed values are 0/NULL.",
              },
              "excluded": "All non-allowlisted account, credential, player and operational tables; all raw pages and SQL modules.",
              "limitations": [
                  "Read-only offline extraction, not a SQL Server RESTORE validation.",
                  "Only primary leaf rows from catalog-owned allocations are exported; ghost rows are excluded.",
                  "Each table must match its catalog row count exactly or its entire export is withheld.",
                  "Definitions retain legacy units and IDs; no current-client catalog is overwritten.",
                  "Map-object definitions are not monster spawn placements.",
                  "Native object/regional spawn placements are recovered separately in legacy_rules/native_spawns.json; they are not supplied by this static SQL table catalog.",
                  "Nullable and invalid legacy rows are preserved; consumers must validate usable IDs and fields.",
              ]}
    output.mkdir(parents=True, exist_ok=True)
    for name in WITHHELD_OPERATIONAL_TABLES:
        if (output / (name + ".json")).exists():
            raise DecodeError("Output contains a withheld operational table; choose a clean output directory")
    for oid, name in sorted(tables.items(), key=lambda entry: entry[1]):
        candidates = [(rsid, rs) for rsid, rs in rowsets.items()
                      if rs["object_id"] == oid and rs["index_id"] in (0, 1)]
        if len(candidates) != 1:
            raise DecodeError("Expected exactly one heap or clustered rowset")
        rsid, rowset = candidates[0]
        schema = []
        for column_id, col in sorted(columns[oid].items()):
            if column_id not in physical[rsid]:
                raise DecodeError("Missing physical column metadata")
            schema.append({**col, **physical[rsid][column_id]})
        owned = {(a["page_object"], a["page_index"])
                 for a in allocations.values() if a["rowset_id"] == rsid and a["type"] == 1}
        rows, ghosts, seen_pages, errors = [], 0, set(), Counter()
        for _, page in pages:
            if page[1] != 1 or (U32(page, 24), U16(page, 6)) not in owned:
                continue
            identity = (U16(page, 36), U32(page, 32))
            if identity in seen_pages:
                errors["duplicate_page_identity"] += 1
                continue
            seen_pages.add(identity)
            for _, record in page_records(page):
                kind = record[0] >> 1 & 7
                if kind in (4, 5, 6, 7):
                    ghosts += 1
                    continue
                if kind != 0:
                    errors["unsupported_nonprimary_record"] += 1
                    continue
                try:
                    rows.append(decode_row(record, schema))
                except (DecodeError, UnicodeError, OverflowError) as exc:
                    errors[type(exc).__name__ + ": " + str(exc)] += 1
        expected = rowset["expected_rows"]
        entry = {"table": name, "object_id": oid, "columns": len(schema),
                 "catalog_rows": expected, "decoded_rows": len(rows),
                 "leaf_pages": len(seen_pages), "excluded_ghost_rows": ghosts}
        if errors or len(rows) != expected:
            entry["errors"] = dict(errors)
            if len(rows) != expected:
                entry["errors"]["row_count_mismatch"] = {"expected": expected, "decoded": len(rows)}
            report["withheld"].append(entry)
            continue
        columns_out = [col["name"] for col in schema]
        # Physical page order is intentionally preserved, with no deduplication.
        document = {"schema_version": 1, "table": name, "source_sha256": digest,
                    "columns": columns_out, "rows": rows}
        target = output / (name + ".json")
        raw = (json.dumps(document, ensure_ascii=False, separators=(",", ":"),
                          allow_nan=False) + "\n").encode("utf-8")
        target.write_bytes(raw)
        entry.update({"file": target.name, "sha256": hashlib.sha256(raw).hexdigest(),
                      "bytes": len(raw), "schema": schema})
        report["exported"].append(entry)
    report["exported_tables"] = len(report["exported"])
    report["exported_rows"] = sum(table["decoded_rows"] for table in report["exported"])
    required = {"ti_Monster", "ti_MonsterItem", "ti_Item"}
    if required.issubset({table["table"] for table in report["exported"]}):
        report["semantic_checks"] = semantic_checks(output)
    (output / "manifest.json").write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--backup", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        report = export_backup(args.backup, args.output)
    except (DecodeError, OSError) as exc:
        parser.exit(1, f"Static extraction refused: {exc}\n")
    print(json.dumps({key: report[key] for key in
                      ("exported_tables", "exported_rows", "withheld")}, indent=2))


if __name__ == "__main__":
    main()
