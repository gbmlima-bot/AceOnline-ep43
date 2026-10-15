#!/usr/bin/env python3
"""Share exact converted model bytes while reading independent source poses."""
import argparse
import copy
import json
from pathlib import Path
from convert_complete_props import read_placements
from convert_original_terrain import require, sha256


def export(dat: Path, resource_id: int, template: Path, output: Path, client: Path):
    layout = json.loads(template.read_text()); poses, source = read_placements(dat.read_bytes(), resource_id)
    require({p["code"] for p in poses} == {m["code"] for m in layout["models"]}, "shared model set differs")
    layout = copy.deepcopy(layout); layout.update(resource_id=resource_id, source=source, instance_count=len(poses))
    for model in layout["models"]:
        require(model["scene"].startswith("res://assets/"), "unsafe shared scene")
        scene = client / model["scene"].removeprefix("res://")
        require(scene.resolve().is_relative_to(client.resolve()), "shared scene escapes client")
        require(sha256(scene.read_bytes()) == model["sha256"], "shared GLB hash mismatch")
        model["placements"] = [p for p in poses if p["code"] == model["code"]]
        model["shared_original_model"] = True
    output.mkdir(parents=True, exist_ok=True)
    (output / "placements.json").write_text(json.dumps(layout, indent=2, allow_nan=False) + "\n")
    manifest = {"schema_version": 1, "resource_id": resource_id, "model_count": len(layout["models"]), "instance_count": len(poses),
                "models": [{"code": m["code"], "scene": m["scene"], "sha256": m["sha256"], "source_mapobjectinfo": m["source_mapobjectinfo"], "shared_with_resource3002": True} for m in layout["models"]],
                "placements_sha256": sha256((output / "placements.json").read_bytes()), "source_placements": source,
                "provenance": {"method": "Same numeric render codes select same source packs; converted GLBs shared by exactSHA. Poses parsed independently from selected DAT.",
                               "source_archive_sha256": "8395f1f33dda8165f70f30d2a6ad094c5f64e144403fce98337e5012be795841", "converter_sha256": sha256(Path(__file__).read_bytes())}}
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2, allow_nan=False) + "\n")
    return manifest


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    for name in ("dat", "template", "output", "client"):
        p.add_argument("--" + name, type=Path, required=True)
    p.add_argument("--resource-id", type=int, required=True)
    a = p.parse_args(); r = export(a.dat, a.resource_id, a.template, a.output, a.client)
    print(json.dumps({"resource_id": r["resource_id"], "model_count": r["model_count"], "instance_count": r["instance_count"]}))
