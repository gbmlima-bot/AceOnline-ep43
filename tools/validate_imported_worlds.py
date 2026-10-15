#!/usr/bin/env python3
"""Independent binary, source-pose and resource validation of every imported map."""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import numpy as np
from import_world_profile import parse_resource
from validate_original_data_assets import validate_glb


def sha(raw):return hashlib.sha256(raw).hexdigest()


def validate(project: Path, source: Path, report: Path):
    client=project/"client";assets=client/"assets"
    catalog=json.loads((assets/"original_worlds/catalog.json").read_text())
    native_maps_path=assets/"legacy_rules/maps.json"
    assert sha(native_maps_path.read_bytes())==catalog["source_maps_sha256"]
    native_maps={row["MapIndex"]:row for row in json.loads(native_maps_path.read_text())["records"]}
    models={};worlds=[];colliders={};pose_count=0;source_rows=0
    def path(resource):
        assert resource.startswith("res://assets/") and ".." not in resource.split("/")
        return client/resource.removeprefix("res://")
    def model(resource):
        if resource not in models:
            result=validate_glb(path(resource))
            models[resource]={k:v for k,v in result.items() if k!="images"}
            models[resource]["image_count"]=len(result["images"])
            if len(models)%100==0:print(json.dumps({"validated_models":len(models)}),flush=True)
        return models[resource]
    for item in catalog["records"]:
        if not item["available"]:
            assert item["status"]=="unavailable" and item["unavailable_reasons"]
            continue
        metadata_path=path(item["terrain_metadata"])
        metadata=json.loads(metadata_path.read_text());grid=metadata["grid"]
        native_row=native_maps[item["map_index"]]
        if item.get("native_non_tile_world",False):
            assert native_row["TileRenderingFlag"]==0
            assert metadata["source_map_info"]==native_row
            assert metadata["tile_rendering_enabled"] is False and item["tile_rendering_enabled"] is False
            assert item["terrain_path"]=="" and item["visual_profile"]["terrain"]=={}
            assert metadata["geometry"]["path"] is None and metadata["geometry"]["triangle_count"]==0
            assert metadata["geometry"]["rendered"] is False
            assert metadata["navigation_floor"]=={"height":0,"kind":"native_craft_center_bound","projectiles_collide":False,"source":"ShuttleChild.cpp2165; tile-ground weapon tests skip non-tile maps"}
        else:
            assert native_row["TileRenderingFlag"]==1
            terrain=model(item["terrain_path"])
            assert terrain["sha256"]==metadata["geometry"]["sha256"]
        heights=path(item["height_path"]).read_bytes()
        assert len(heights)==grid["vertex_side"]**2*4 and sha(heights)==grid["heightmap_sha256"]
        array=np.frombuffer(heights,dtype="<f4")
        assert np.isfinite(array).all()
        for key,field in (("water","active_tile_flags"),("landing","tile_flags")):
            row=metadata[key];raw=(metadata_path.parent/row[field]).read_bytes()
            assert sha(raw)==row[field+"_sha256"] and len(raw)==grid["tile_side"]**2 and set(raw)<={0,1}
        dat_id=int(metadata["resource_id"])
        source_raw=(source/f"Res-map/{dat_id}.dat").read_bytes()
        entries,container=parse_resource(source_raw)
        assert container["sha256"]==item["source_dat"]["sha256"]
        entry=entries[str(dat_id)]
        tile,nv,nt,no=struct.unpack_from("<fiii",entry.data,20)
        assert nv==grid["vertex_side"]**2 and nt==grid["tile_side"]**2 and tile==grid["tile_size"]
        native=np.frombuffer(entry.data,dtype="<f4",count=nv*6,offset=36).reshape((-1,6))
        np.testing.assert_array_equal(array,native[:,1])
        center=(grid["vertex_side"]-1)*tile/2
        layout=json.loads(path(item["props_path"]).read_text())
        count=0
        for row in layout["models"]:
            converted=model(row["scene"])
            assert converted["sha256"]==row["sha256"]
            if row.get("collision_mesh"):
                collision=row["collision_mesh"]
                if collision["path"] not in colliders:
                    raw=path(collision["path"]).read_bytes()
                    assert sha(raw)==collision["sha256"]
                    parsed=json.loads(raw)
                    triangles=np.array(parsed["triangles"])
                    assert triangles.shape==(parsed["triangle_count"]*3,3) and np.isfinite(triangles).all()
                    assert parsed["triangle_count"]==converted["triangles"] and parsed["source_glb_sha256"]==converted["sha256"]
                    colliders[collision["path"]]=True
            for pose in row["placements"]:
                offset=pose["source_record_offset"]
                record=source_raw[offset:offset+112]
                assert len(record)==112 and sha(record)==pose["source_record_sha256"]
                assert struct.unpack_from("<I",record)[0]==row["code"]
                original=np.array(struct.unpack_from("<3f",record,8))
                direction=np.array(struct.unpack_from("<3f",record,20));direction/=np.linalg.norm(direction)
                transform=np.array(pose["transform_columns"])
                assert transform.shape==(12,) and np.isfinite(transform).all()
                rotation=transform[:9].reshape((3,3)).T
                np.testing.assert_allclose(rotation.T@rotation,np.eye(3),atol=1e-6)
                assert abs(np.linalg.det(rotation)-1)<1e-6
                np.testing.assert_allclose(transform[9:],[original[0]-center,original[1],center-original[2]],atol=1e-5)
                np.testing.assert_allclose(rotation[:,2],[-direction[0],-direction[1],direction[2]],atol=1e-6)
                assert pose["source_is_event"]==struct.unpack_from("<i",record,60)[0]
                count+=1
        assert count==layout["instance_count"]==item["props_imported"]
        assert no==item["props_total"] and count<=no
        assert item["complete_static_scenery"]==(item["status"]=="complete")
        assert not item["complete_static_scenery"] or not item["coverage_gaps"]
        worlds.append({"map_index":item["map_index"],"props":count,"status":item["status"],"native_non_tile_world":bool(item.get("native_non_tile_world",False)),"source_heights_exact":True,"source_poses_exact":True,"grid_flags_hashed":True})
        pose_count+=count;source_rows+=no
    for filename in ("props","sky","extra_props"):
        manifest_path=assets/f"original_library/{filename}/manifest.json"
        if not manifest_path.exists():continue
        manifest=json.loads(manifest_path.read_text())
        for row in manifest["models"]:
            if row["available"]:
                assert model(row["scene"])["sha256"]==row["sha256"]
    assert len(worlds)==catalog["coverage"]["available_maps"]
    assert pose_count==catalog["coverage"]["placed_prop_instances"]
    result={"status":"passed","world_count":len(worlds),"native_non_tile_worlds":sum(w["native_non_tile_world"]for w in worlds),"rendered_native_terrains":sum(not w["native_non_tile_world"]for w in worlds),"validated_glb_count":len(models),"validated_collision_meshes":len(colliders),"source_prop_records":source_rows,"retained_prop_instances":pose_count,"worlds":worlds,"models":models,"scope":"Independent data validation; native render flags, all imported GLBs, native height samples, water/landing flags and source poses. Native client/server were not executed."}
    report.parent.mkdir(parents=True,exist_ok=True);report.write_text(json.dumps(result,indent=2,allow_nan=False)+"\n")
    return result


if __name__=="__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project",type=Path,default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--source",type=Path,required=True)
    parser.add_argument("--report",type=Path,required=True)
    args=parser.parse_args();result=validate(args.project,args.source,args.report)
    print(json.dumps({k:result[k] for k in ("status","world_count","validated_glb_count","validated_collision_meshes","retained_prop_instances")}),flush=True)
