#!/usr/bin/env python3
"""Import the pinned ACE client library as data, never execute client programs.

Known OMI fields use the separately reviewed current-client profile. Unknown
bytes remain in a binary source copy and are never treated as gameplay rules.
Image and audio payloads are decoded by standard offline readers. Every source
file, including resources deliberately not interpreted, has a SHA/CRC inventory.
"""
from __future__ import annotations

import argparse
import collections
import hashlib
import io
import json
import math
from pathlib import Path, PurePosixPath
import re
import shutil
import struct
import subprocess
import wave
import zlib

from PIL import Image, UnidentifiedImageError
from export_original_rules import ITEM_FIELDS, PROFILE_SHA, load_omi
from export_original_progression import export_progression

ARCHIVE_SHA = "8395f1f33dda8165f70f30d2a6ad094c5f64e144403fce98337e5012be795841"
HEADER = struct.Struct("<5i")
ENTRY = struct.Struct("<3i10s2s")
MAX_PACK = 512 * 1024 * 1024
MAX_ENTRIES = 100_000
MAX_IMAGE_PIXELS = 4096 * 4096


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def file_hash(path: Path) -> tuple[str, str]:
    h = hashlib.sha256(); crc = 0
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(chunk); crc = zlib.crc32(chunk, crc)
    return h.hexdigest(), f"{crc & 0xffffffff:08X}"


def lossless_text(raw: bytes) -> str:
    """Keep an invalid CP949 byte visible as a literal \\xNN, without U+FFFD."""
    text = raw.split(b"\0", 1)[0].decode("cp949", errors="surrogateescape")
    return "".join(f"\\x{ord(c)-0xdc00:02x}" if 0xdc80 <= ord(c) <= 0xdcff else c for c in text)


def write_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary=path.with_suffix(path.suffix+".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, separators=(",", ":"), allow_nan=False) + "\n", encoding="utf-8")
    temporary.replace(path)


def res(path: Path, output: Path) -> str:
    return "res://assets/original_library/" + path.relative_to(output).as_posix()


def parse_pack(data: bytes) -> tuple[list[dict], dict]:
    if not HEADER.size <= len(data) <= MAX_PACK:
        raise ValueError("Resource size outside bounded policy")
    encoded, identification, declared, count, parity = HEADER.unpack_from(data)
    if (encoded, identification) != (1000, 1000):
        raise ValueError("Not a plaintext CGameData 1000/1000 resource")
    if not 0 <= count <= MAX_ENTRIES:
        raise ValueError("Resource entry count outside bounded policy")
    offset = HEADER.size; records = []; names = set()
    for index in range(count):
        if offset + ENTRY.size > len(data):
            raise ValueError("Truncated CGameData entry header")
        identifier, size, entry_parity, raw_name, padding = ENTRY.unpack_from(data, offset)
        offset += ENTRY.size
        if size < 0 or size > len(data) - offset:
            raise ValueError("CGameData entry payload outside source")
        name = raw_name.split(b"\0", 1)[0].decode("ascii", errors="strict")
        if not name or any(c in name for c in "/\\\0") or name in (".", ".."):
            raise ValueError("Unsafe CGameData entry name")
        duplicate = name in names
        names.add(name); payload = data[offset:offset + size]
        records.append({"name": name, "identifier": identifier, "offset": offset,
                        "size": size, "sha256": sha(payload), "index": index,
                        "parity": entry_parity, "raw_name_hex": raw_name.hex(),
                        "padding_hex": padding.hex(), "duplicate_name": duplicate, "payload": payload})
        offset += size
    return records, {"header": {"encode": encoded, "identification": identification,
                    "declared_payload_size": declared, "count": count, "parity": parity},
                    "size": len(data), "sha256": sha(data),
                    "opaque_trailing": {"offset": offset, "size": len(data)-offset,
                                        "sha256": sha(data[offset:])}}


def item_icon_key(item: dict) -> tuple[str, str]:
    # Skill icons are explicitly normalized by the original character skill UI.
    number = int(item["SourceIndex"])
    if 50 <= int(item["Kind"]) <= 53:
        return f"{number // 10 * 10:08d}", "SKILL_BASE_NUM(SourceIndex)"
    return f"{number:08d}", "SourceIndex"


def catalogs(source: Path, output: Path, legacy_source: Path) -> dict:
    omi_path = source / "Res-tex/omi.tex"; native = load_omi(omi_path)
    raw = omi_path.read_bytes(); root = output / "catalogs"
    root.mkdir(parents=True, exist_ok=True)
    (root / "omi-native.bin").write_bytes(raw)
    items = native["ITEM"]
    for item in items:
        off = item["_source"]["offset"]; name = raw[off+5:off+45]
        item["ItemName"] = lossless_text(name)
        item["ItemNameRawHex"] = name.hex()
        # Bounded native description region: validated current offset after
        # SourceIndex and 32-bit pointer, with source SIZE_MAX_ITEM_DESCRIPTION200.
        item["Description"] = lossless_text(raw[off+248:off+448])
        item["unknown_fields"] = "Preserved in omi-native.bin; not interpreted as gameplay rules"
    document = {"schema_version": 1, "source": native["source"],
                "record_count": len(items), "records": items,
                "field_offsets": {k: {"offset": v[0], "format": "<"+v[1]} for k,v in ITEM_FIELDS.items()},
                "native_binary": res(root / "omi-native.bin", output),
                "description_field":{"offset":248,"size":200,"encoding":"CP949 lossless",
                    "evidence":"SourceIndex240, pointer244, Description248; AtumParam.h:312,2614 and all16,079 observed records"},
                "evidence": ["EP3.5 Client/Common/AtumParam.h:2544-2620; validated current ITEM stride576",
                             "Client/ProjectAtum/main/AtumDatabase.cpp:113-121"],
                "limits": ["Current ITEM size576 differs from historical source. Only reviewed fields are interpreted.",
                           "All16,079 definitions are a catalog; this does not grant equipment or activate every skill."]}
    write_json(root / "items.json", document)
    existing_icons=output/"icons/items.json"
    bindings=json.loads(existing_icons.read_text()).get("by_item",{}) if existing_icons.exists() else {}
    write_item_index(items, output,bindings)
    write_json(root / "item_kinds.json", {"schema_version": 1,
        "counts": dict(sorted(collections.Counter(str(i["Kind"]) for i in items).items())),
        "total": len(items), "definitions_are_not_runtime_implementations": True})
    write_json(root/"skills.json",{"schema_version":1,"source":native["source"],
        "records":[r for r in items if 50<=r["Kind"]<=53],
        "evidence":["Client/Common/AtumParam.h:1296-1301 IS_SKILL_ITEM bounds50..53"],
        "limits":["Skill definitions are recovered metadata; full casting/stat/effect behavior is a separate runtime implementation.",
            "Unknown destination-parameter layout is preserved in native binary without assigning guessed effects."]})
    definitions=(legacy_source/"Client/Common/AtumParam.h").read_bytes().decode("cp949",errors="replace")
    constants={}
    for m in re.finditer(r"^\s*#define\s+((?:ITEMKIND|BUILDINGKIND)_\w+)\s+\(BYTE\)\s*(\d+)",definitions,re.M):
        constants[m.group(1)]=int(m.group(2))
    write_json(root/"native_constants.json",{"schema_version":1,"source":"Client/Common/AtumParam.h",
        "source_sha256":sha((legacy_source/"Client/Common/AtumParam.h").read_bytes()),"constants":constants})
    service_names={value:key for key,value in constants.items() if key.startswith("BUILDINGKIND_")}
    write_json(root/"npc_services.json",{"schema_version":1,"source":native["source"],
        "records":[{"BuildingIndex":r["BuildingIndex"],"NPCIndex":r["NPCIndex"],"BuildingKind":r["BuildingKind"],
                    "service_symbol":service_names.get(r["BuildingKind"]),"MapIndex":r["MapIndex"],"NPCName":r["NPCName"]} for r in native["BUILDINGNPC"]],
        "limits":["Original service kinds are metadata; shop stock, prices, economy services and positions are not inferred from a kind identifier."]})
    progression=export_progression(legacy_source,root)
    # Reuse verified metadata without inventing positions or services.
    for name, key in (("npcs", "BUILDINGNPC"), ("map_objects", "MAPOBJECTINFO"), ("monsters", "MEX_MONSTER_INFO")):
        write_json(root / (name+".json"), {"schema_version": 1, "source": native["source"], "records": native[key]})
    extended=extended_omi(raw,root,native["source"])
    documents=original_documents(source,root)
    return {"items": len(items), "skill_definitions":sum(50<=r["Kind"]<=53 for r in items),
            "native_binary_sha256": sha(raw), "native_binary_size": len(raw),"progression":progression,
            "extended":extended,"documents":documents}


def extended_omi(raw: bytes, output: Path, source: dict) -> dict:
    """Known prefix of current rare/mixing tables; never interpret unknown tail."""
    if sha(raw)!=PROFILE_SHA:raise ValueError("Unknown extended OMI profile")
    sections=((3,9473312,2715,112,"rare_item_info"),(7,10296660,39230,60,"mixing_recipes"))
    counts={}
    for typ,start,count,stride,name in sections:
        if struct.unpack_from("<2i",raw,start)!=(typ,count):raise ValueError("Extended OMI section header mismatch")
        end=start+8+count*stride
        expected=(4,215) if typ==3 else (8,24824)
        if struct.unpack_from("<2i",raw,end)!=expected:raise ValueError("Extended OMI next section boundary mismatch")
        records=[]
        for index in range(count):
            off=start+8+index*stride;r=raw[off:off+stride]
            if typ==3:
                values=struct.unpack_from("<9f",r,72)
                if not all(math.isfinite(v) for v in values):raise ValueError("Nonfinite rare-item parameter")
                record={"CodeNum":struct.unpack_from("<i",r)[0],"Name":lossless_text(r[4:34]),
                    "ReqUseType":struct.unpack_from("<i",r,36)[0],"ReqMinLevel":struct.unpack_from("<i",r,40)[0],
                    "ReqMaxLevel":struct.unpack_from("<i",r,44)[0],"ReqItemKind":r[48],
                    "ReqGearStat":list(struct.unpack_from("<6h",r,50)),"DesParameter":list(r[62:71]),
                    "ParameterValue":list(values),"ProbabilityRaw":struct.unpack_from("<i",r,108)[0]}
            else:
                target,probability,cost=struct.unpack_from("<3i",r)
                n=struct.unpack_from("<i",r,52)[0]
                if not 0<=probability<=10000 or not 0<=n<=5 or cost<0:raise ValueError("Unsupported mixing record bounds")
                record={"TargetItemNum":target,"MixingProbability":probability,"MixingCost":cost,
                    "SourceItem":[{"ItemNum":a,"Count":b} for a,b in struct.iter_unpack("<2i",r[12:52])],
                    "NumOfSourceItems":n,"opaque_tail_hex":r[56:60].hex()}
            record["_source"]={"id":"omi","offset":off,"size":stride,"record_index":index,"sha256":sha(r)}
            records.append(record)
        write_json(output/(name+".json"),{"schema_version":1,"source":source,"records":records,
            "section":{"header_offset":start,"type":typ,"count":count,"stride":stride,"end":end},
            "evidence":["Client/Common/AtumParam.h:3439-3481 native field order", "Current pinned OMI exact neighboring section bounds"],
            "limits":["Recovered metadata is not an implemented economy, crafting or rarity service.",
                "Rare ProbabilityRaw is preserved without a claimed current probability scale; values exceed the old source100000 scale.",
                "Current mixing stride60 has4 opaque tail bytes absent from the old source; those bytes are not assigned a behavior."]})
        counts[name]=count
    return counts


def original_documents(source: Path, output: Path) -> dict:
    rows=[]
    for relative in ("FAQ_Main.txt","FAQ_Sub.txt","Res-tex/FAQ_Main.txt","Res-tex/FAQ_Sub.txt","Res-tex/ToolTipList.tex"):
        path=source/relative;data=path.read_bytes()
        # The full raw data lives in source evidence; no external network/config
        # settings are imported. These specific files contain native help text.
        text=data.decode("cp949",errors="surrogateescape")
        text="".join(f"\\x{ord(c)-0xdc00:02x}" if 0xdc80<=ord(c)<=0xdcff else c for c in text)
        rows.append({"path":relative,"size":len(data),"sha256":sha(data),"encoding":"CP949 lossless","text":text})
    write_json(output/"documents.json",{"schema_version":1,"records":rows,
        "limits":["Original help text is retained as documentation. Its descriptions are not proof that every described service is implemented."]})
    # Preserve encoded definition files for future bounded readers; never run
    # or evaluate them as scripts or assume they are plaintext images.
    encoded=[]
    for name in ("AFList.tex","helptext.tex","quext.tex","omi1.tex","omi_o.tex"):
        path=source/"Res-tex"/name;data=path.read_bytes();dest=output/"opaque"/(name+".bin")
        dest.parent.mkdir(parents=True,exist_ok=True);dest.write_bytes(data)
        encoded.append({"source":"Res-tex/"+name,"size":len(data),"sha256":sha(data),"path":str(dest.name),"status":"opaque_not_executed"})
    write_json(output/"opaque/index.json",{"schema_version":1,"records":encoded})
    return {"help_files":len(rows),"opaque_definition_files":len(encoded)}


def write_item_index(items: list[dict], output: Path, bindings: dict | None = None) -> None:
    keys = ("ItemNum", "ItemName", "Kind", "Position", "ReqUnitKind", "ReqMinLevel", "ReqMaxLevel", "Price", "SourceIndex")
    records=[]
    for item in items:
        row={key:item[key] for key in keys}
        icon=(bindings or {}).get(str(item["ItemNum"]), {})
        row.update({"icon_path": icon.get("small", ""), "big_icon_path": icon.get("large", "")})
        records.append(row)
    write_json(output / "catalogs/items_index.json", {"schema_version": 1, "record_count": len(records), "records": records})


def import_images(source: Path, output: Path) -> dict:
    results=[]; pack_reports=[]; by_pack={}; total_pixels=0
    for path in sorted((source / "Res-tex").iterdir()):
        if path.suffix.lower() != ".tex" and path.name != "lens":
            continue
        data=path.read_bytes()
        if data[:8] != struct.pack("<2i", 1000, 1000):
            pack_reports.append({"path": "Res-tex/"+path.name, "sha256": sha(data), "size": len(data), "status": "not_plain_image_container"})
            continue
        entries, profile = parse_pack(data); pack_name=path.stem.lower(); images={}; skipped=[]
        directory=output / "icons" / pack_name; directory.mkdir(parents=True, exist_ok=True)
        for entry in entries:
            payload=entry.pop("payload")
            try:
                im=Image.open(io.BytesIO(payload))
                if not 0 < im.width * im.height <= MAX_IMAGE_PIXELS:
                    raise ValueError("Image dimensions exceed bounded policy")
                fmt=im.format; im.load(); rgba=im.convert("RGBA")
            except (UnidentifiedImageError, OSError, ValueError) as exc:
                opaque=output/"catalogs/opaque/resources"/pack_name/(str(entry["index"])+"-"+entry["sha256"][:12]+".bin")
                opaque.parent.mkdir(parents=True,exist_ok=True);opaque.write_bytes(payload)
                skipped.append(dict(entry, status="opaque_nonimage", path=res(opaque,output),reason=type(exc).__name__)); continue
            # Entry names come from a bounded ASCII record and are never paths.
            filename = re.sub(r"[^A-Za-z0-9_-]", "_", entry["name"])
            if not filename: filename=entry["sha256"]
            if entry["duplicate_name"]: filename += "-entry"+str(entry["index"])
            dest=directory/(filename+".png"); rgba.save(dest, format="PNG", optimize=True)
            record=dict(entry, pack="Res-tex/"+path.name, path=res(dest,output),
                        source_format=fmt, dimensions=[rgba.width,rgba.height],
                        rgba_sha256=sha(rgba.tobytes()), png_sha256=file_hash(dest)[0], png_size=dest.stat().st_size)
            results.append(record);images.setdefault(entry["name"],record);total_pixels+=rgba.width*rgba.height
        by_pack[pack_name]=images
        pack_reports.append(dict(profile,path="Res-tex/"+path.name,status="parsed",image_count=len(images),opaque_entries=skipped))
        print(f"images {path.name}: {len(images)} decoded, {len(skipped)} opaque", flush=True)
    items_doc=json.loads((output/"catalogs/items.json").read_text());bindings={}
    default=by_pack.get("item",{}).get("07900270",{}).get("path", "")
    for item in items_doc["records"]:
        key,method=item_icon_key(item)
        small=by_pack.get("item",{}).get(key,{})
        large=by_pack.get("bigitem",{}).get(key,{})
        bindings[str(item["ItemNum"])]={"small":small.get("path",default), "large":large.get("path", ""),
            "source_key":key,"binding":method,"uses_original_fallback":not bool(small),
            "evidence":["Client/InterfaceLib/main/INFInven.cpp:1271-1284 SourceIndex and shape override",
                        "Client/InterfaceLib/main/INFItemInfo.cpp:2971-2980 big icon SourceIndex",
                        "Client/InterfaceLib/main/INFCharacterInfoExtend.cpp:2024 SKILL_BASE_NUM(SourceIndex)",
                        "Client/InterfaceLib/main/INFIcon.cpp:12,46-63 default07900270 and item.tex"]}
    write_json(output/"icons/index.json",{"schema_version":1,"by_item":bindings,"default_icon":default,
        "image_count":len(results),"records":results,"packs":pack_reports,
        "limits":["Images preserve decoded RGBA pixels; UI composition remains a separate implementation.",
                  "Template icon mapping has no shape-item override because a template has no equipped instance.",
                  "A fallback icon is native but is not evidence of a resource binding."]})
    # Small UI index avoids parsing per-image hashes and all source entries.
    compact_bindings={key:{k:v for k,v in value.items() if k!="evidence"} for key,value in bindings.items()}
    write_json(output/"icons/items.json",{"schema_version":1,"by_item":compact_bindings,"default_icon":default,
        "evidence":"Full per-binding source citations and per-image pixel hashes are in icons/index.json"})
    write_item_index(items_doc["records"],output,bindings)
    return {"image_count":len(results),"pack_count":len(pack_reports),"decoded_pixels":total_pixels,
            "item_bindings":len(bindings),"exact_item_icons":sum(not r["uses_original_fallback"] for r in bindings.values()),
            "output_bytes":sum(r["png_size"] for r in results)}


def wave_info(data: bytes) -> dict:
    if len(data)<12 or data[:4]!=b"RIFF" or data[8:12]!=b"WAVE":
        raise ValueError("Not a RIFF WAVE payload")
    declared=struct.unpack_from("<I",data,4)[0]+8
    if declared > len(data): raise ValueError("RIFF length extends beyond payload")
    with wave.open(io.BytesIO(data), "rb") as stream:
        if stream.getcomptype()!="NONE": raise ValueError("Unsupported nonPCM WAV")
        info={"channels":stream.getnchannels(),"sample_width":stream.getsampwidth(),
              "sample_rate":stream.getframerate(),"frames":stream.getnframes()}
        if not 1<=info["channels"]<=2 or info["sample_width"] not in (1,2,3,4) or not 1<=info["sample_rate"]<=192000:
            raise ValueError("WAV parameters outside bounded profile")
        pcm=stream.readframes(info["frames"])
        if len(pcm)!=info["frames"]*info["channels"]*info["sample_width"]:
            raise ValueError("Truncated WAV data")
        info.update(duration_seconds=info["frames"]/info["sample_rate"],pcm_sha256=sha(pcm))
        return info


def import_audio(source: Path, output: Path, legacy_source: Path) -> dict:
    root=output/"audio";root.mkdir(parents=True,exist_ok=True)
    entries=[];bgm={};effects={};by_name={};opaque=[]
    for path in sorted((source/"Res-snd").iterdir()):
        if path.suffix.lower()!=".mp3":continue
        info=json.loads(subprocess.check_output(["ffprobe","-v","error","-show_entries","format=duration:stream=codec_name,sample_rate,channels","-of","json",str(path)],text=True))
        streams=info.get("streams",[])
        if not streams or any(s.get("codec_name")!="mp3" for s in streams):raise ValueError("MP3 payload is not a decodable MP3: "+path.name)
        dest=root/"mp3"/path.name.lower();dest.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(path,dest)
        record={"name":path.stem,"source":"Res-snd/"+path.name,"path":res(dest,output),
                "size":dest.stat().st_size,"sha256":file_hash(dest)[0],"kind":"bgm" if path.stem.upper().startswith("BGM_") else "narration",
                "duration_seconds":float(info["format"]["duration"]),"streams":streams}
        entries.append(record);by_name[path.stem.lower()]=record
        m=re.fullmatch(r"BGM_(\d+)",path.stem,re.I)
        if m:bgm[str(int(m[1]))]=record
    sound=source/"Res-snd/sound.dat";records,profile=parse_pack(sound.read_bytes())
    for record in records:
        data=record.pop("payload")
        try: info=wave_info(data)
        except (ValueError,wave.Error,EOFError) as exc:
            opaque.append(dict(record,reason=str(exc)));continue
        dest=root/"wav"/(record["name"]+".wav");dest.parent.mkdir(parents=True,exist_ok=True);dest.write_bytes(data)
        item=dict(record,kind="effect",source="Res-snd/sound.dat",path=res(dest,output),**info)
        entries.append(item);by_name[record["name"]]=item
    define=(legacy_source/"Client/Common/AtumDefine.h").read_bytes().decode("cp949",errors="replace")
    constants={m.group(1):int(m.group(2)) for m in re.finditer(r"^\s*#define\s+(SOUND_\w+)\s+(\d+)",define,re.M)}
    wanted={"open_menu":"SOUND_OPEN_MENU","close_menu":"SOUND_CLOSE_MENU","select_button":"SOUND_SELECT_BUTTON",
            "lock_on":"SOUND_LOCKON_PRIMARY","lock_on_secondary":"SOUND_LOCKON_SECONDARY","takeoff":"SOUND_TAKINGOFF",
            "landing":"SOUND_LANDING_DONE","warp":"SOUND_WARP","warp_alt":"SOUND_WARP_2",
            "boost_start":"SOUND_HIGH_BOOSTER_START","boost_loop":"SOUND_HIGH_BOOSTER","boost_end":"SOUND_HIGH_BOOSTER_END",
            "boost_end_low":"SOUND_LOW_BOOSTER_END","warning":"SOUND_WARNING","warning_hp":"SOUND_WARNING_HP",
            "ground_moving":"SOUND_GROUND_MOVING_A_GEAR","reload":"SOUND_WEAPON_RELOAD","get_item":"SOUND_GET_ITEM"}
    for key,native in wanted.items():
        index=constants[native]; payload=by_name.get(f"{index:08d}")
        if payload:
            effects[key]=dict(payload,source_name=native,source_id=index,
                evidence=["Client/Common/AtumDefine.h:68-115", "Client/Common/AtumSound.cpp:290-295 numeric name to sound.dat", "Client/DataRenderLib/main/ShuttleChild.cpp and Client/InterfaceLib/main/INFGameMain.cpp native calls"])
    result={"schema_version":1,"bgm_by_id":bgm,"effects":effects,"library":entries,"by_name":by_name,
            "sound_bank":dict(profile,source="Res-snd/sound.dat",opaque_entries=opaque),
            "bgm_evidence":["Client/Common/AtumGlobal.cpp:1578-1583 MAP_INFO.Bgm", "Client/Common/AtumSound.cpp:908 BGM_%d.mp3"],
            "limits":["All MP3/WAV media are imported; event bindings are only provided where legacy source proves them.","Weapon sound playback requires a matching weapon/effect descriptor; no generic shot sound is invented."]}
    if (output/"catalogs/items.json").exists():
        from export_original_weapon_audio import add_weapon_audio
        result=add_weapon_audio(result,source,output,Path(__file__).resolve().parents[1]/"docs/evidence/weapon-audio-descriptors.json")
    write_json(root/"registry.json",result)
    return {"mp3_count":sum(i["kind"]!="effect" for i in entries),"wav_count":sum(i["kind"]=="effect" for i in entries),
            "effect_bindings":len(effects),"bgm_bindings":len(bgm),"opaque_bank_entries":len(opaque),"output_bytes":sum(i["size"] for i in entries)}


def classify(path: str) -> str:
    p=PurePosixPath(path);ext=p.suffix.lower()
    if path.startswith(("WebView2/","Xigncode/")) or ext in (".exe",".dll",".sys",".atm",".xem",".nexe",".bat"):
        return "native_program_not_executed_or_imported"
    if path.startswith("Res-snd/"):return "audio_source"
    if path.startswith("Res-map/"):return "world_source"
    if path.startswith("Res-obj/"):return "model_source"
    if path.startswith("Res-eff/"):return "effect_source"
    if path.startswith("Res-tex/"):return "definition_or_image_source"
    return "other_static_source"


def archive_inventory(source: Path, output: Path, listing: Path, archive: Path) -> dict:
    actual_hash,_=file_hash(archive)
    if actual_hash!=ARCHIVE_SHA:raise ValueError("Unknown client archive SHA-256")
    listing_bytes=listing.read_bytes();original=json.loads(listing_bytes); records=[]
    for entry in original:
        relative=PurePosixPath(entry["Path"])
        if relative.is_absolute() or ".." in relative.parts:raise ValueError("Unsafe archive inventory path")
        path=source.joinpath(*relative.parts)
        if "D" in entry.get("Attributes",""):
            if not path.is_dir():raise ValueError("Missing source directory: "+str(relative))
            records.append({"path":str(relative),"kind":"directory","size":0});continue
        if not path.is_file() or path.stat().st_size!=int(entry["Size"]):raise ValueError("Source size mismatch: "+str(relative))
        digest,crc=file_hash(path)
        if entry.get("CRC","").upper()!=crc:raise ValueError("Source CRC mismatch: "+str(relative))
        records.append({"path":str(relative),"kind":"file","size":path.stat().st_size,"sha256":digest,"crc32":crc,"classification":classify(str(relative)),
                        "interpreted":False,"interpretation_note":"Hash inventory is coverage of source bytes; runtime implementation is reported separately."})
    file_records=[r for r in records if r["kind"]=="file"]
    result={"schema_version":1,"archive":{"filename":archive.name,"sha256":actual_hash,"size":archive.stat().st_size},
            "inventory_source":{"sha256":sha(listing_bytes),"entries":len(original)},"records":records,
            "counts":{"entries":len(records),"files":len(file_records),"directories":len(records)-len(file_records),"bytes":sum(r["size"] for r in file_records)},
            "limits":["All source files were checked by exact length, archive CRC32 and computed SHA256.","A hash or catalog entry is not a claim that a proprietary module runs in the new game.","Windows executables, DLLs, browser and anti-cheat components were never executed and are not copied into the game."]}
    write_json(output/"source_inventory.json",result)
    return result["counts"]


def main() -> None:
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source",type=Path,required=True)
    parser.add_argument("--output",type=Path,default=Path(__file__).resolve().parents[1]/"client/assets/original_library")
    parser.add_argument("--legacy-source",type=Path,default=Path("/workspace/targets/ace-online-ep35"))
    parser.add_argument("--inventory",type=Path,default=Path("/workspace/analysis/ace-online-ui/archive-inventory.json"))
    parser.add_argument("--archive",type=Path,default=Path("/workspace/downloads/ace-client/ACEonline-20250709.7z"))
    parser.add_argument("--phase",choices=("all","catalogs","images","audio","inventory"),default="all")
    args=parser.parse_args();args.output.mkdir(parents=True,exist_ok=True)
    summary={"schema_version":1,"archive_sha256":ARCHIVE_SHA}
    for phase,function in (("catalogs",lambda:catalogs(args.source,args.output,args.legacy_source)),
            ("audio",lambda:import_audio(args.source,args.output,args.legacy_source)),
            ("images",lambda:import_images(args.source,args.output)),
            ("inventory",lambda:archive_inventory(args.source,args.output,args.inventory,args.archive))):
        if args.phase in ("all",phase):
            summary[phase]=function();print(json.dumps({phase:summary[phase]},ensure_ascii=False),flush=True)
    write_json(args.output/("catalog-import-manifest.json" if args.phase=="all" else args.phase+"-manifest.json"),summary)


if __name__=="__main__":main()
