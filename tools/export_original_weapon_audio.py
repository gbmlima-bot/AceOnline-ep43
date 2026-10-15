#!/usr/bin/env python3
"""Bind existing WAVs through native ITEM -> wear/projectile descriptors."""
from __future__ import annotations
import hashlib
import json
from pathlib import Path
import struct

OBJECT_INFO_SHA="667d289a89953b30a1ce7504431aca26b79f7338c8e92379e2fc3a8609ed4ab1"
GEARS={"12000100":(1,0),"12001100":(16,10),"12002100":(256,20),"12003100":(4096,30)}


def sha(data):return hashlib.sha256(data).hexdigest()


def parse_body_audio(payload: bytes, base: int=0) -> dict:
    if not 24<=len(payload)<=1024*1024:raise ValueError("Descriptor size outside bounded profile")
    count=struct.unpack_from("<i",payload,20)[0]
    if not 0<=count<=256:raise ValueError("Descriptor body count outside bounded profile")
    result={};off=24
    for _ in range(count):
        if off+88>len(payload):raise ValueError("Truncated native body descriptor")
        body=payload[off:off+88];mask=struct.unpack_from("<Q",body)[0]
        effects=struct.unpack_from("<i",body,44)[0]
        if not 0<=effects<=1024 or off+88+effects*96>len(payload):raise ValueError("Native effects outside descriptor")
        if mask in result:raise ValueError("Duplicate body mask")
        sound=body[68:88].split(b"\0",1)[0].decode("ascii",errors="strict")
        result[mask]={"body_mask":mask,"body_name":body[8:28].split(b"\0",1)[0].decode("ascii",errors="replace"),
            "sound_filename":sound,"effect_count":effects,"source_offset":base+off,"size":88,
            "sha256":sha(body),"native_body_hex":body.hex()}
        off+=88+effects*96
    if off!=len(payload):raise ValueError("Descriptor does not close at exact declared arrays")
    return result


def add_weapon_audio(registry: dict, source: Path, library: Path, evidence_path: Path | None=None) -> dict:
    from import_original_library import parse_pack,write_json
    raw=(source/"Res-eff/objectinfo.inf").read_bytes()
    if sha(raw)!=OBJECT_INFO_SHA:raise ValueError("Unknown current objectinfo.inf profile")
    entries,container=parse_pack(raw);entry_map={}
    for entry in entries:entry_map.setdefault(entry["name"],entry)
    proof={};cache={};gaps=[]
    def bodies(identifier):
        key=f"{identifier:08d}"
        if key in cache:return cache[key]
        entry=entry_map.get(key)
        if not entry:cache[key]={};return {}
        try:value=parse_body_audio(entry["payload"],entry["offset"])
        except (ValueError,UnicodeError) as exc:
            gaps.append({"descriptor":key,"reason":str(exc)});value={}
        cache[key]=value;return value
    def bind(identifier,mask,chain):
        key=f"{identifier:08d}";body=bodies(identifier).get(mask)
        if not body:return {"status":"missing_descriptor_body","descriptor":key,"body_mask":mask}
        ref=key+":"+str(mask);proof[ref]=dict(body,descriptor=key)
        if not body["sound_filename"]:
            return {"status":"native_sound_field_empty","descriptor":key,"body_mask":mask,"body_ref":ref}
        name=body["sound_filename"][:8]
        if len(name)!=8 or not name.isdecimal():
            return {"status":"unsupported_native_sound_name","descriptor":key,"body_mask":mask,"body_ref":ref}
        audio=registry["by_name"].get(name)
        if not audio:return {"status":"native_sound_missing_in_bank","source_name":name,"body_ref":ref}
        return {"status":"bound","path":audio["path"],"source_id":int(name),"source_name":body["sound_filename"],
            "sha256":audio["sha256"],"descriptor":key,"body_mask":mask,"body_ref":ref,
            "evidence":[chain,"CharacterInfo.h:BodyConditionData size88/sound_offset68",
                "CharacterInfo.cpp:1399-1416 structured load;797-807 sound dispatch",
                "AtumSound.cpp:476-490 first8chars lookup in sound.dat"]}
    items=json.loads((library/"catalogs/items.json").read_text())["records"]
    weapons={};fire_bound=0;hit_bound=0
    for item in items:
        if not 0<=item["Kind"]<=15:continue
        primary=item["Kind"]<=7;source_index=item["SourceIndex"]
        wear=source_index+(100000 if primary else -700000)
        fire_by_gear={}
        for gear,(unit,shift) in GEARS.items():
            if item["ReqUnitKind"] and not item["ReqUnitKind"]&unit:continue
            fire_by_gear[gear]=bind(wear,4<<shift,
                "AtumDefine.h:647,682-686,737-748 wearSource=SourceIndex+100000(primary)/-700000(secondary);fire4<<gearShift; UnitData.cpp:789-791,890-892,1759-1774,2933-2940;ShuttleChild.cpp:12969-12980")
        bound=[b for b in fire_by_gear.values() if b.get("status")=="bound"]
        common=bound[0] if bound and len(bound)==len(fire_by_gear) and len({b["source_id"] for b in bound})==1 else {}
        hit=bind(source_index,524288,"WeaponFastData.cpp:567 and WeaponMissileData.cpp hit state BODYCON_HIT_MASK;AtumParam.h:884")
        weapons[str(item["ItemNum"])]={"item_num":item["ItemNum"],"source_index":source_index,"wear_descriptor":f"{wear:08d}",
            "fire_by_gear":fire_by_gear,"fire":common,"hit":hit}
        fire_bound+=bool(bound);hit_bound+=hit.get("status")=="bound"
    monsters={};monster_records=json.loads((library/"catalogs/monsters.json").read_text())["records"]
    for monster in monster_records:
        code=monster["MonsterUnitKind"];identifier=monster["SourceIndex"]
        destroyed=bind(identifier,4096,"MEX_MONSTER_INFO.SourceIndex;MonsterData.cpp:286 and dead/explosion BODYCON_EXPLOSION_MASK AtumParam.h:877")
        monsters[str(code)]={"monster_code":code,"source_index":identifier,"destroyed":destroyed}
    gear_effects={gear:{"destroyed":bind(int(gear),4096,"Gear source presentation descriptor; BODYCON_EXPLOSION_MASK AtumParam.h:877")}
                  for gear in GEARS}
    registry.update(weapon_effects=weapons,monster_effects=monsters,gear_effects=gear_effects)
    registry["weapon_audio_provenance"]={"source":"Res-eff/objectinfo.inf","sha256":OBJECT_INFO_SHA,"size":len(raw),
        "character_bytes":24,"body_bytes":88,"effect_bytes":96,"sound_field_offset":68,"sound_field_size":20,
        "proof":"docs/evidence/weapon-audio-descriptors.json","unavailable_profiles":gaps,
        "limits":["A weapon firing sound follows the equipped wear descriptor and gear shift, not the projectile's FIRE body.",
            "A missing sound field stays silent; no filename-based or generic audio fallback is chosen.",
            "ShapeItemNum overrides and advanced skill alternate firing states require their own active descriptor.",
            "NPC weapon/attack-slot mappings are absent from client MEX; no generic enemy-fire event is inferred."]}
    registry["limits"]=[x for x in registry.get("limits",[]) if not x.startswith("Weapon sound playback requires")]
    registry["limits"].append("Weapon sounds now use proven ITEM->wear body/gear shift or projectile-hit descriptor bindings. Missing bindings remain explicit.")
    if evidence_path:
        write_json(evidence_path,{"schema_version":1,"source":{"path":"Res-eff/objectinfo.inf","sha256":OBJECT_INFO_SHA,"size":len(raw)},
            "layout":{"character":24,"body":88,"effect":96,"sound_offset":68,"sound_size":20},"bodies":proof,
            "counts":{"weapons":len(weapons),"weapons_with_fire":fire_bound,"weapons_with_hit":hit_bound,
                "monsters":len(monsters),"monsters_with_destroyed":sum(r["destroyed"].get("status")=="bound" for r in monsters.values()),"gears":len(gear_effects)}})
    return registry


if __name__=="__main__":
    import argparse
    from import_original_library import write_json
    p=argparse.ArgumentParser(description=__doc__);p.add_argument("--source",type=Path,required=True);p.add_argument("--library",type=Path,required=True)
    p.add_argument("--evidence",type=Path,required=True);a=p.parse_args()
    path=a.library/"audio/registry.json";doc=add_weapon_audio(json.loads(path.read_text()),a.source,a.library,a.evidence)
    write_json(path,doc);print(json.dumps({"weapons":len(doc["weapon_effects"]),"monsters":len(doc["monster_effects"]),"gears":len(doc["gear_effects"])}))
