#!/usr/bin/env python3
"""Source identity, parser boundary and imported-media regression checks."""
import hashlib
import io
import json
from pathlib import Path
import struct
import unittest
import wave

from PIL import Image
from export_original_progression import EXP_FIELDS,literal_array
from export_original_weapon_audio import parse_body_audio
from import_original_library import ENTRY,HEADER,PROFILE_SHA,item_icon_key,lossless_text,parse_pack,wave_info

ROOT=Path(__file__).resolve().parents[1]
LIB=ROOT/"client/assets/original_library"


def read_json(path):return json.loads(path.read_text())
def digest(data):return hashlib.sha256(data).hexdigest()
def local(path):
    if not path.startswith("res://"):raise ValueError("Expected project resource")
    result=ROOT/"client"/path[6:]
    if not result.resolve().is_relative_to((ROOT/"client").resolve()):raise ValueError("Resource outside project")
    return result
def pack(payloads):
    result=HEADER.pack(1000,1000,sum(len(b) for _,b in payloads),len(payloads),0)
    for name,payload in payloads:
        result+=ENTRY.pack(12,len(payload),0,name.encode().ljust(10,b"\0"),b"\0\0")+payload
    return result


class BoundedReaders(unittest.TestCase):
    def test_truncated_negative_and_unsafe_container_entries_rejected(self):
        valid=pack([("00000001",b"abc")])
        for invalid in (valid[:15],valid[:-1],HEADER.pack(1000,1000,0,-1,0),
                        HEADER.pack(1000,1000,0,1,0)+ENTRY.pack(0,-1,0,b"x\0".ljust(10,b"\0"),b"\0\0"),
                        pack([("../x",b"bad")])):
            with self.assertRaises(ValueError):parse_pack(invalid)

    def test_real_format_duplicate_names_keep_both_payloads(self):
        entries,profile=parse_pack(pack([("BackItemV_",b"first"),("BackItemV_",b"second")])+b"opaque")
        self.assertEqual([e["payload"] for e in entries],[b"first",b"second"])
        self.assertFalse(entries[0]["duplicate_name"]);self.assertTrue(entries[1]["duplicate_name"])
        self.assertEqual(profile["opaque_trailing"]["size"],6)
        self.assertEqual(profile["opaque_trailing"]["sha256"],digest(b"opaque"))

    def test_lossless_cp949_has_no_replacement_character(self):
        self.assertEqual(lossless_text("파일럿".encode("cp949")+b"\0ignored"),"파일럿")
        self.assertEqual(lossless_text(b"ok\x81"),"ok\\x81")

    def test_skill_icon_rule_does_not_round_color_items(self):
        self.assertEqual(item_icon_key({"Kind":50,"SourceIndex":7100013})[0],"07100010")
        self.assertEqual(item_icon_key({"Kind":53,"SourceIndex":7100013})[0],"07100010")
        self.assertEqual(item_icon_key({"Kind":60,"SourceIndex":7100013})[0],"07100013")

    def test_wav_parser_rejects_truncated_pcm(self):
        stream=io.BytesIO()
        with wave.open(stream,"wb") as writer:
            writer.setnchannels(1);writer.setsampwidth(2);writer.setframerate(8000);writer.writeframes(b"\0\0"*8)
        self.assertEqual(wave_info(stream.getvalue())["frames"],8)
        with self.assertRaises(ValueError):wave_info(stream.getvalue()[:-1])

    def test_numeric_table_parser_ignores_comments_and_rejects_expressions(self):
        source="/*const LEVEL_EXPERIENCE example[]={{9,9,9,9,9}};*/\nconst LEVEL_EXPERIENCE example[]={{0,0,0,0,0},{1,91,91,0,0}};"
        rows,_=literal_array(source,"example",EXP_FIELDS);self.assertEqual(rows[1]["Experience"],91)
        for payload in ("1+1","native_call()","__import__('os')"):
            with self.assertRaises(ValueError):literal_array("const LEVEL_EXPERIENCE example[]={{0,"+payload+",0,0,0}};","example",EXP_FIELDS)


class NativeLibrary(unittest.TestCase):
    def test_weapon_fire_follows_wear_descriptor_and_gear_shift(self):
        doc=read_json(LIB/"audio/registry.json")
        self.assertEqual(len(doc["weapon_effects"]),1435)
        for item,fire,hit in (("7000040",260,302),("7901000",174,6),("7000050",266,1123),("7900440",410901,25)):
            row=doc["weapon_effects"][item]
            self.assertEqual(row["fire"]["source_id"],fire);self.assertEqual(row["hit"]["source_id"],hit)
        for gear,shift in (("12000100",0),("12001100",10),("12003100",30)):
            row=doc["weapon_effects"]["7000040"]
            self.assertEqual(row["wear_descriptor"],"07101950")
            self.assertEqual(row["fire_by_gear"][gear]["body_mask"],4<<shift)
        self.assertEqual(doc["weapon_effects"]["7000050"]["fire_by_gear"]["12002100"]["body_mask"],4<<20)
        self.assertEqual(doc["monster_effects"]["2000000"]["destroyed"]["source_id"],400500)
        self.assertEqual(doc["monster_effects"]["2028100"]["destroyed"]["source_id"],400516)
        self.assertEqual(doc["gear_effects"]["12003100"]["destroyed"]["source_id"],44)

    def test_every_bound_sound_matches_raw_native_body_field(self):
        doc=read_json(LIB/"audio/registry.json")
        evidence=read_json(ROOT/"docs/evidence/weapon-audio-descriptors.json")
        for group in ("weapon_effects","monster_effects","gear_effects"):
            for row in doc[group].values():
                values=[x for x in row.values() if isinstance(x,dict) and "status" in x]
                values+=list(row.get("fire_by_gear",{}).values())
                for entry in values:
                    if entry.get("status")!="bound":continue
                    body=evidence["bodies"][entry["body_ref"]]
                    raw=bytes.fromhex(body["native_body_hex"])
                    self.assertEqual(len(raw),88);self.assertEqual(digest(raw),body["sha256"])
                    self.assertEqual(struct.unpack_from("<Q",raw)[0],entry["body_mask"])
                    self.assertEqual(raw[68:88].split(b"\0",1)[0].decode(),entry["source_name"])
                    self.assertEqual(int(entry["source_name"][:8]),entry["source_id"])
                    self.assertTrue(local(entry["path"]).is_file())
        # A body cannot advertise effects beyond the descriptor's own payload.
        invalid=bytearray(24+88);struct.pack_into("<i",invalid,20,1);struct.pack_into("<i",invalid,24+44,999)
        with self.assertRaises(ValueError):parse_body_audio(bytes(invalid))

    def test_every_item_matches_its_exact_original_record(self):
        raw=(LIB/"catalogs/omi-native.bin").read_bytes();self.assertEqual(digest(raw),PROFILE_SHA)
        doc=read_json(LIB/"catalogs/items.json");records=doc["records"]
        self.assertEqual(len(records),16079);self.assertEqual(len({r["ItemNum"] for r in records}),16079)
        for index,row in enumerate(records):
            off=8+index*576;native=raw[off:off+576]
            self.assertEqual(row["_source"]["offset"],off)
            self.assertEqual(row["_source"]["sha256"],digest(native))
            self.assertEqual(row["ItemNum"],struct.unpack_from("<i",native)[0])
            self.assertEqual(row["ItemName"],lossless_text(native[5:45]))
            self.assertEqual(row["Description"],lossless_text(native[248:448]))
            self.assertEqual(row["SourceIndex"],struct.unpack_from("<i",native,240)[0])
        skills=read_json(LIB/"catalogs/skills.json")["records"]
        self.assertEqual(len(skills),557);self.assertTrue(all(50<=r["Kind"]<=53 for r in skills))

    def test_recovered_extended_sections_have_source_bounds_and_opaque_tail(self):
        raw=(LIB/"catalogs/omi-native.bin").read_bytes()
        for name,count,stride in (("rare_item_info",2715,112),("mixing_recipes",39230,60)):
            doc=read_json(LIB/"catalogs"/(name+".json"));self.assertEqual(len(doc["records"]),count)
            for row in doc["records"]:
                off=row["_source"]["offset"];record=raw[off:off+stride]
                self.assertEqual(row["_source"]["sha256"],digest(record))
                if name=="mixing_recipes":
                    self.assertEqual(row["opaque_tail_hex"],record[56:60].hex())
                    self.assertEqual(row["TargetItemNum"],struct.unpack_from("<i",record)[0])

    def test_all_imported_images_preserve_recorded_source_pixels(self):
        doc=read_json(LIB/"icons/index.json");images=doc["records"]
        self.assertEqual(len(images),10127);self.assertEqual(len({r["path"] for r in images}),10127)
        for record in images:
            path=local(record["path"]);data=path.read_bytes()
            self.assertEqual(digest(data),record["png_sha256"])
            with Image.open(io.BytesIO(data)) as image:
                rgba=image.convert("RGBA");self.assertEqual([rgba.width,rgba.height],record["dimensions"])
                self.assertEqual(digest(rgba.tobytes()),record["rgba_sha256"])
        opaque=[entry for pack in doc["packs"] for entry in pack.get("opaque_entries",[])]
        self.assertEqual(len(opaque),290)
        for entry in opaque:
            data=local(entry["path"]).read_bytes()
            self.assertEqual(len(data),entry["size"]);self.assertEqual(digest(data),entry["sha256"])
        items=read_json(LIB/"catalogs/items_index.json")["records"]
        self.assertEqual(len(items),16079);self.assertTrue(all(row["icon_path"] for row in items))
        self.assertEqual(sum(not row["uses_original_fallback"] for row in doc["by_item"].values()),14139)

    def test_all_audio_identity_and_pcm_frame_counts(self):
        doc=read_json(LIB/"audio/registry.json");entries=doc["library"]
        self.assertEqual(len(entries),734);self.assertEqual(len(doc["bgm_by_id"]),72)
        self.assertEqual(len(doc["effects"]),18)
        for entry in entries:
            data=local(entry["path"]).read_bytes();self.assertEqual(digest(data),entry["sha256"])
            if entry["kind"]=="effect":
                info=wave_info(data);self.assertEqual(info["frames"],entry["frames"])
                self.assertEqual(info["pcm_sha256"],entry["pcm_sha256"])
        self.assertEqual(doc["effects"]["open_menu"]["source_id"],80)
        self.assertTrue(doc["bgm_by_id"]["3002"]["path"].endswith("bgm_3002.mp3"))

    def test_experience_thresholds_match_literal_source_evidence(self):
        doc=read_json(LIB/"catalogs/level_experience.json")
        evidence=(LIB/"catalogs/progression-native-evidence.txt").read_text()
        rows,_=literal_array(evidence,"arrLevelExperienceNew",EXP_FIELDS)
        self.assertEqual(rows,doc["records"]);self.assertEqual(doc["max_level"],125)
        self.assertEqual(doc["by_level"]["1"]["initial_experience"],0)
        self.assertEqual(doc["by_level"]["1"]["next_level_experience"],91)
        self.assertEqual(doc["by_level"]["9"]["initial_experience"],8008)
        self.assertEqual(doc["by_level"]["125"]["next_level_experience"],None)
        self.assertEqual(len(read_json(LIB/"catalogs/level_stat_values.json")["records"]),342)

    def test_complete_archive_inventory_distinguishes_bytes_from_runtime(self):
        doc=read_json(LIB/"source_inventory.json");c=doc["counts"]
        self.assertEqual(c,{"entries":10823,"files":10798,"directories":25,"bytes":4767808277})
        self.assertEqual(len(doc["records"]),10823)
        self.assertEqual(len({r["path"] for r in doc["records"]}),10823)
        for record in doc["records"]:
            if record["kind"]=="file":
                self.assertEqual(len(record["sha256"]),64);self.assertEqual(len(record["crc32"]),8)
                self.assertFalse(record["interpreted"])
        self.assertTrue(any(r.get("classification")=="native_program_not_executed_or_imported" for r in doc["records"]))


if __name__=="__main__":unittest.main(verbosity=2)
