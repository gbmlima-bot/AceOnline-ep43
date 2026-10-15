#!/usr/bin/env python3
"""Read numeric literal tables from pinned C++ source without evaluating C++."""
from __future__ import annotations
from decimal import Decimal
import hashlib
import json
from pathlib import Path
import re

EXP_FIELDS=("Level","ExperienceIncreament","Experience","ExperienceLossOnDeath","PenaltySPIOnDead")
STAT_FIELDS=("LevelOrStat","AttackPart_AttackIncreaseRate","AttackPart_AttackIncreaseProbability",
    "AttackPart_PierceAttackProbability","DefensePart_DefenseDecreaseRate","ShieldPart_DP",
    "DodgePart_DefenseProbabilityRate","HPOfLevel","Level_MonsertPierceAttackProbability")


def atomic_text(path: Path, value: str) -> None:
    temporary=path.with_suffix(path.suffix+".tmp");temporary.write_text(value,encoding="utf-8");temporary.replace(path)


def literal_array(text: str, name: str, fields: tuple[str,...]) -> tuple[list[dict],str]:
    # Tables are numeric literals, so stripping comments cannot alter a string.
    clean=re.sub(r"/\*.*?\*/|//[^\r\n]*", "", text, flags=re.S)
    pattern=rf"\bconst\s+\w+\s+{re.escape(name)}\s*\[\s*\]\s*=\s*\{{(.*?)\}}\s*;"
    matches=list(re.finditer(pattern,clean,re.S))
    if len(matches)!=1:raise ValueError("Expected exactly one active literal array: "+name)
    payload=matches[0].group(1); rows=[];end=0
    for row in re.finditer(r"\{([^{}]*)\}",payload):
        if payload[end:row.start()].strip(" \r\n\t,"):raise ValueError("Unsupported numeric array syntax")
        values=[v.strip() for v in row.group(1).split(",")]
        if len(values)!=len(fields) or any(not re.fullmatch(r"[-+]?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?",v) for v in values):
            raise ValueError("Only fixed-width numeric literal rows are supported")
        numbers=[Decimal(value) for value in values]
        records={field:int(value) if value==int(value) else float(value) for field,value in zip(fields,numbers)}
        records["source_literals"]=values
        rows.append(records);end=row.end()
        if len(rows)>4096:raise ValueError("Literal table count exceeds policy")
    if payload[end:].strip(" \r\n\t,"):raise ValueError("Trailing unsupported numeric array syntax")
    return rows,payload


def export_progression(legacy_source: Path, output: Path) -> dict:
    source=legacy_source/"Client/Common/AtumSJ.cpp";raw=source.read_bytes();text=raw.decode("cp949",errors="surrogateescape")
    if hashlib.sha256(raw).hexdigest()!="cdaeb9585cc7a3d26c4d1e1807baca71d34a73d8c29c1189b1d67353528b854f":
        raise ValueError("Unknown AtumSJ.cpp source profile")
    params=(legacy_source/"Client/Common/AtumParam.h").read_bytes()
    if hashlib.sha256(params).hexdigest()!="0bee3d02698d3c9e49c968c7a37db4f608de5fa004bf93c732021f89dcc7c897":
        raise ValueError("Unknown AtumParam.h source profile")
    caps=re.findall(rb"^\s*#define\s+CHARACTER_LEVEL_110\s+(\d+)",params,re.M)
    if len(caps)!=1:raise ValueError("Expected one native character level cap")
    cap=int(caps[0]);rows,body=literal_array(text,"arrLevelExperienceNew",EXP_FIELDS)
    if cap!=125 or len(rows)!=126 or [r["Level"] for r in rows]!=list(range(cap+1)):
        raise ValueError("Unexpected pinned experience table dimensions/cap")
    if rows[0]["Experience"]!=0 or any(rows[i]["Experience"]>=rows[i+1]["Experience"] for i in range(len(rows)-1)):
        raise ValueError("Native cumulative XP must be strictly increasing")
    source_info={"path":"Client/Common/AtumSJ.cpp","sha256":hashlib.sha256(raw).hexdigest(),
        "repository":"https://github.com/bhsdp1/AceOnline-ep35","commit":"7c3e47ac47844e5c415d356a94d6201a0b9a38c4",
        "array":"arrLevelExperienceNew","line":4233}
    by_level={}
    for level in range(1,cap+1):
        by_level[str(level)]={"level":level,"initial_experience":rows[level-1]["Experience"],
            "next_level_experience":rows[level]["Experience"] if level<cap else None,
            "experience_loss_on_death":rows[level]["ExperienceLossOnDeath"],
            "spi_penalty_on_death":rows[level]["PenaltySPIOnDead"]}
    result={"schema_version":1,"source":source_info,"max_level":cap,"records":rows,"by_level":by_level,
        "threshold_authority":"Experience cumulative column; ExperienceIncreament includes native inconsistencies and is preserved without correction.",
        "semantics":{"GetInitialExperienceOfLevel":"arrLevelExperienceNew[clamp(level,1,125)-1].Experience",
            "GetLevelExperience":"arrLevelExperienceNew[clamp(level,1,125)]",
            "GetPercentageOfExperience":"0 at cap; otherwise (exp-initial(level))/(initial(level+1)-initial(level))*100"},
        "evidence":["Client/Common/AtumSJ.cpp:1171-1209", "Client/Common/AtumParam.h:6362 CHARACTER_LEVEL_110=125"],
        "limits":["This is the pinned public legacy source table, not a claimed export of the 2025 server database.",
            "A level9 local starting character requires the source initial XP8008. Earned XP is a separate local ledger.",
            "Native cumulative values are authoritative; native high-level increment inconsistencies remain visible."]}
    output.mkdir(parents=True,exist_ok=True)
    atomic_text(output/"level_experience.json",json.dumps(result,ensure_ascii=False,separators=(",",":"))+"\n")
    stats,stat_body=literal_array(text,"g_arrLevelStatValue",STAT_FIELDS)
    # Original declarations use INT for these columns; VC++ truncated literals.
    integer_fields={"LevelOrStat","AttackPart_PierceAttackProbability","HPOfLevel","Level_MonsertPierceAttackProbability"}
    for row in stats:
        for field in integer_fields:row[field]=int(row[field])
    stat_result={"schema_version":1,"source":dict(source_info,array="g_arrLevelStatValue",line=4510),"records":stats,
        "evidence":["Client/Common/AtumSJ.h:31-43 field types", "Client/Common/AtumSJ.cpp:1886-1898 lookup"],
        "limits":["Source literal spellings are retained; declared INT fields use truncation matching the legacy struct.",
            "This lookup is metadata for original formulas. Loading it does not implement skills, stat allocation or server balancing."]}
    atomic_text(output/"level_stat_values.json",json.dumps(stat_result,ensure_ascii=False,separators=(",",":"))+"\n")
    evidence=output/"progression-native-evidence.txt"
    atomic_text(evidence,"Public source commit "+source_info["commit"]+"\nAtumSJ.cpp SHA256 "+source_info["sha256"]+"\n\nconst LEVEL_EXPERIENCE arrLevelExperienceNew[] = {"+body+"};\n\nconst LEVEL_STAT_VALUE g_arrLevelStatValue[] = {"+stat_body+"};\n")
    return {"experience_rows":len(rows),"max_level":cap,"stat_rows":len(stats),"level9_initial_xp":by_level["9"]["initial_experience"]}


if __name__=="__main__":
    import argparse
    p=argparse.ArgumentParser(description=__doc__);p.add_argument("--source",type=Path,required=True);p.add_argument("--output",type=Path,required=True)
    a=p.parse_args();print(json.dumps(export_progression(a.source,a.output)))
