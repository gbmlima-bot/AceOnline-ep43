#!/usr/bin/env python3
"""Absorb every remaining original MAPOBJECT code into the source library.

These resources are a library, not invented map placements. The .gdignore marker
keeps concurrent Godot imports isolated until the caller removes it at freeze.
"""
from concurrent.futures import ProcessPoolExecutor
import argparse
import json
from pathlib import Path
from import_available_worlds import (ARCHIVE_SHA, ROOT, ASSETS, convert_model,
    digest, run_pool, write)
from convert_complete_props import read_rows


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("--source",type=Path,required=True)
    p.add_argument("--inventory",type=Path,default=Path("/workspace/analysis/ace-online-ui/archive-inventory.json"))
    p.add_argument("--work",type=Path,default=Path("/workspace/analysis/ace-absorb"))
    p.add_argument("--workers",type=int,default=4)
    args=p.parse_args()
    assert 1<=args.workers<=4
    output=ASSETS/"original_library/extra_props"
    output.mkdir(parents=True,exist_ok=True)
    (output/".gdignore").write_text("Import in progress; root integrator removes this marker at final freeze.\n")
    inventory={r["Path"]:r for r in json.loads(args.inventory.read_text()) if r.get("CRC")}
    rows=read_rows((args.source/"Res-tex/omi.tex").read_bytes())
    existing=json.loads((ASSETS/"original_library/props/manifest.json").read_text())["models"]
    known={r["code"] for r in existing}
    codes=sorted(set(rows)-known)
    common={"source":str(args.source),"work":str(args.work),"inventory":inventory,
            "output":str(output),"asset_prefix":"res://assets/original_library/extra_props/"}
    models=run_pool(convert_model,[{**common,"code":code,"metadata":rows[code]} for code in codes],args.workers,"remaining-props")
    all_models=[r for r in existing if r["code"] in rows]+models
    all_models.sort(key=lambda r:r["code"])
    assert {r["code"] for r in all_models}==set(rows)
    for row in all_models:
        row["source_mapobjectinfo"]=rows[row["code"]]
        row["placed_in_playable_world"]=row["code"] in known and row["available"]
    coverage={"native_mapobject_codes":len(rows),"converted_models":sum(r["available"] for r in all_models),
              "extra_codes_processed":len(models),"extra_models_converted":sum(r["available"] for r in models),
              "unsupported_or_missing":sum(not r["available"] for r in all_models)}
    result={"schema_version":1,"source_archive_sha256":ARCHIVE_SHA,"source_omi_sha256":digest(args.source/"Res-tex/omi.tex"),"coverage":coverage,
            "models":all_models,"extra_models":models,"limitations":["Resources not referenced by a playable DAT remain library assets; no positions or server gameplay are invented.","Static original source hierarchy/bind pose and exact embedded texture pixels; source animation/effects are explicitly omitted.","Missing packs and unsupported original data remain unavailable entries with reasons."]}
    write(output/"manifest.json",result)
    write(ROOT/"reports/import-worlds-extra-props.json",result)
    print(json.dumps({"complete":True,"coverage":coverage,"ignored_until_integrator_freeze":str(output/".gdignore")}),flush=True)


if __name__=="__main__":main()
