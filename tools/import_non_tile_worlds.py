#!/usr/bin/env python3
"""Recover native object-only worlds without inventing terrain or textures.

MAP_INFO.TileRenderingFlag=0 intentionally bypasses .map loading and QuadGround
creation in Background.cpp and AtumGlobal::IsTileMapRenderEnable. DAT supplies
bounds, original object poses and events; source meshes are reused from the
already verified complete prop library. The absent MAP is not a resource gap.
"""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import struct

import import_available_worlds as native
from convert_additional_terrain import water_tiles, landing_tiles

ROOT = Path(__file__).resolve().parents[1]
SOURCE_EVIDENCE = [
    'EP35 Client/ProjectAtum/main/Background.cpp:201-220,734-748: MAP/QuadGround only if IsTileMapRenderEnable',
    'EP43 Common/AtumGlobal.cpp:1640-1661: IsTileMapRenderEnable returns MAP_INFO.TileRenderingFlag',
    'EP35 Client/DataRenderLib/main/ShuttleChild.cpp:2165-2170: no-tile craft center minimum Y0',
    'EP35 Client/DataRenderLib/main/WeaponRocketData.cpp:501 and WeaponMissileData.cpp:767: tile collisions gated by IsTileMapRenderEnable',
]

def write(path, value):
    path.parent.mkdir(parents=True,exist_ok=True)
    path.write_text(json.dumps(value,ensure_ascii=True,indent=2,allow_nan=False)+'\n')

def source_rows(root=ROOT):
    return json.loads((root/'client/assets/legacy_rules/maps.json').read_text())['records']

def selected_rows(rows,inventory):
    return [row for row in rows if row['TileRenderingFlag']==0 and f"Res-map/{row['Dat']}.dat" in inventory]

def props_layout(row, source, poses, errors, models):
    grouped={};omitted=list(errors)
    for pose in poses:
        code=pose['code'];model=models.get(code,{})
        if model.get('available'):
            if code not in grouped:
                grouped[code]={key:model[key]for key in ['code','scene','sha256','source_mapobjectinfo']}
                grouped[code]['placements']=[]
                if model.get('collision_mesh'):grouped[code]['collision_mesh']=model['collision_mesh']
            grouped[code]['placements'].append(pose)
        else:
            omitted.append({'code':code,'source_record_index':pose['source_record_index'],'reason':model.get('reason','native prop not converted'),'source_mapobjectinfo':model.get('source_mapobjectinfo'),'collision_expected':bool(model.get('source_mapobjectinfo',{}).get('collision',0))})
    return {'schema_version':1,'resource_id':row['Dat'],'map_index':row['MapIndex'],'source':source,'instance_count':sum(len(m['placements'])for m in grouped.values()),'model_count':len(grouped),'coordinate_profile':'F*inverse(LookAtLH)*F, terrain-centered; no ship heading','matrix_layout':'12 floats: basisX.xyz,basisY.xyz,basisZ.xyz,origin.xyz','alpha_pipeline':{'enabled':True,'per_model':True,'source_alpha_flag':'models[].source_mapobjectinfo.alpha','function':'GREATER_EQUAL','reference_uint8':127,'cutoff':127/255,'blend':'SRCALPHA/INVSRCALPHA'},'models':list(grouped.values()),'omitted':omitted}

def visual_profile(row,project,props_path,skies,gaps):
    out={'terrain':{},'props':{'layout_path':props_path},'sky':{},'clouds':{},'environment':{'mode':'original_source_bindings','source_day_sun_direction':row['DaySunDirection'],'source_day_fog_color':row['DayFogColor'],'source_diffuse_day':project.get('diffuse_day',[]),'source_ambient_day':project.get('ambient_day',[]),'viewer_fog_end':row['DayFogEndDistance'],'native_sky_rendering_flag':row['SkyRenderingFlag'],'native_sun_rendering_flag':row['SunRenderingFlag'],'native_fog_rendering_flag':row['FogRenderingFlag']}}
    if project.get('ambient_day'):out['environment'].update(ambient_light_color=project['ambient_day'],ambient_light_energy=1.)
    if project.get('diffuse_day'):out['environment'].update(sun_color=project['diffuse_day'],sun_energy=1.)
    if not row['SkyRenderingFlag']:return out
    for key,binding,kind in [('sky','Sky','sky'),('clouds','Cloud','cloud')]:
        model=skies.get((row[binding],kind),{})
        if model.get('available'):
            scale=float(row['DayFogEndDistance'])/133
            out[key]={'name':f'Original{kind}{row[binding]}','resource_path':model['scene'],'position':[0,0,0],'rotation_degrees':[0,90,0],'scale':[scale]*3,'source_binding':row['_source'],'source_fog_end':row['DayFogEndDistance'],'expected_mesh_count':model['meshes'],'expected_triangles':model['triangles']}
            if model.get('texture_binding_adaptation'):gaps.append({'kind':key,'resource_id':row[binding],'reason':'Native material name unresolved; explicit unique-image binding adaptation','texture_binding_adaptation':model['texture_binding_adaptation']})
        elif row[binding]:gaps.append({'kind':key,'resource_id':row[binding],'reason':model.get('reason','bound native sky/cloud unavailable')})
    return out

def convert(row,source,output,inventory,models,skies,workspace):
    code=row['Dat'];index=row['MapIndex'];relative=f'Res-map/{code}.dat'
    origin=native.verify_source(source/relative,relative,inventory)
    entries,container=native.extended.parse_resource((source/relative).read_bytes())
    native.terrain_core.require(str(code) in entries,'bound terrain entry missing')
    entry=entries[str(code)];terrain=native.terrain_core.parse_terrain(entry.data)
    poses,errors=native.placements(entry.data,entry.offset,terrain)
    try:project=native.terrain_core.parse_project(workspace,str(code))
    except native.terrain_core.FormatError:project={'water_height':row['WaterHeight'],'tile_dimensions':[terrain.tiles,terrain.tiles],'provenance':'native MAP_INFO; no matching workspace PROJECTINFO'}
    center=terrain.tiles*terrain.tile_size/2
    base=output/'client/assets/original_worlds'/str(index)
    resource=f'res://assets/original_worlds/{index}/'
    heights=struct.pack('<'+'f'*len(terrain.vertices),*(v[1]for v in terrain.vertices))
    water=water_tiles(entry.data,terrain,project['water_height']);landing=landing_tiles(entry.data,terrain)
    metadata={'schema_version':1,'resource_id':code,'map_index':index,'display_name':row['MapName'],'tile_rendering_enabled':False,'source_map_info':row,'source_package':{'name':'ACEonline-20250709.7z','sha256':native.ARCHIVE_SHA},'source_resources':{'dat':container,'map':{'required':False,'reason':'native MAP_INFO.TileRenderingFlag=0'}},'source_code':{'ep35_commit':native.terrain_core.SOURCE_SHA,'ep43_commit':native.terrain_core.EP43_SHA},'source_evidence':SOURCE_EVIDENCE,'geometry':{'path':None,'triangle_count':0,'rendered':False,'reason':'native TileRenderingFlag0 suppresses tiled ground; no substitute mesh or material created'},'native_bounds':terrain.native_bounds,'target_bounds':[[-center,terrain.native_bounds[0][1],-center],[center,terrain.native_bounds[1][1],center]],'transform':{'formula':'target=(source.x-center,source.y,center-source.z)','scale':[1,1,-1],'translation':[-center,0,center]},'grid':{'vertex_side':terrain.tiles+1,'tile_side':terrain.tiles,'tile_size':terrain.tile_size,'heightmap':f'{code}_heights.f32','heightmap_sha256':native.terrain_core.sha256(heights),'heightmap_format':'little-endian float32; native DAT heights preserved but not used as tiled collision on non-tile world'},'project_environment':project,'water':{'height':project['water_height'],'active_tile_flags':f'{code}_water_flags.u8','active_tile_flags_sha256':native.terrain_core.sha256(water),'active_tile_count':sum(water),'active_patch_count':0,'note':'DAT flags preserved; no tiled collision in native non-tile map'},'landing':{'tile_flags':f'{code}_landing_flags.u8','tile_flags_sha256':native.terrain_core.sha256(landing),'enabled_tile_count':sum(landing)},'navigation_floor':{'height':0,'kind':'native_craft_center_bound','projectiles_collide':False,'source':'ShuttleChild.cpp2165; tile-ground weapon tests skip non-tile maps'},'compatibility_note':'Native object/sky world. No terrain exists visually; original props and their Collision1 meshes are reused without replacements.'}
    base.mkdir(parents=True,exist_ok=True)
    for filename,data in [(f'{code}_heights.f32',heights),(f'{code}_water_flags.u8',water),(f'{code}_landing_flags.u8',landing)]: (base/filename).write_bytes(data)
    write(base/f'{code}_terrain.json',metadata)
    layout=props_layout(row,origin,poses,errors,models);write(base/'props/placements.json',layout)
    event_source,events=native.load_terrain_events(source/relative);write(base/'events.json',{'source':event_source,'events':events,'portals':[e for e in events if e['event_type']==1]})
    gaps=layout['omitted'].copy();visual=visual_profile(row,project,resource+'props/placements.json',skies,gaps)
    return {'map_index':index,'native_name':row['MapName'],'available':True,'unavailable_reasons':[],'coverage_gaps':gaps,'terrain_available':False,'tile_rendering_enabled':False,'native_non_tile_world':True,'terrain_path':'','terrain_metadata':resource+f'{code}_terrain.json','height_path':resource+f'{code}_heights.f32','props_path':resource+'props/placements.json','source_dat':origin,'source_map':{'required':False,'reason':'native MAP_INFO.TileRenderingFlag0'},'source_map_info':row['_source'],'source_bindings':{k:row[k]for k in ['Dat','Map','Tex','Sky','Cloud','Nsky']},'object_count':terrain.object_count,'pose_errors':errors,'prop_model_count':layout['model_count'],'prop_instance_count':layout['instance_count'],'props_total':terrain.object_count,'props_imported':layout['instance_count'],'missing_prop_codes':sorted({g['code']for g in gaps if 'code'in g}),'visual_profile':visual,'complete_static_scenery':not gaps,'status':'complete'if not gaps else'partial','source_evidence':SOURCE_EVIDENCE}

def run(source,output,inventory_path):
    inventory={r['Path']:r for r in json.loads(inventory_path.read_text())if r.get('CRC')}
    rows=selected_rows(source_rows(),inventory)
    models={r['code']:r for r in json.loads((ROOT/'reports/import-worlds-extra-props.json').read_text())['models']}
    skies={(r['id'],r['kind']):r for r in json.loads((ROOT/'client/assets/original_library/sky/manifest.json').read_text())['models']if 'id'in r and not r.get('night')and not r.get('variant')}
    native.verify_source(source/'Res-map/ms.wok','Res-map/ms.wok',inventory);workspace=(source/'Res-map/ms.wok').read_bytes()
    result=[convert(row,source,output,inventory,models,skies,workspace)for row in rows]
    by_id={r['map_index']:r for r in result}
    catalog=json.loads((ROOT/'client/assets/original_worlds/catalog.json').read_text());catalog['schema_version']=2
    catalog['records']=[by_id.get(r['map_index'],r)for r in catalog['records']]
    coverage=catalog['coverage'];coverage.update(available_maps=sum(r['available']for r in catalog['records']),complete_static_scenery_maps=sum(r.get('complete_static_scenery',False)for r in catalog['records']),placed_prop_instances=sum(r.get('prop_instance_count',0)for r in catalog['records']),native_non_tile_worlds=len(result),rendered_native_terrains=sum(r.get('available',False)and r.get('terrain_available',False)for r in catalog['records']))
    catalog['limitations'][2]='Available means a real DAT, height/flags and original prop layout plus textured terrain when TileRenderingFlag1. Native non-tile worlds intentionally have no terrain mesh/MAP; complete_static_scenery additionally requires all expected source props and sky/cloud resources.'
    write(output/'client/assets/original_worlds/catalog.json',catalog)
    report={'schema_version':1,'source_archive_sha256':native.ARCHIVE_SHA,'source_catalog_sha256':hashlib.sha256((ROOT/'client/assets/original_worlds/catalog.json').read_bytes()).hexdigest(),'converter_sha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),'coverage':coverage,'recovered_maps':len(result),'new_prop_instances':sum(r['prop_instance_count']for r in result),'native_source_prop_instances':sum(r['props_total']for r in result),'missing_prop_instances':sum(r['props_total']-r['props_imported']for r in result),'source_evidence':SOURCE_EVIDENCE,'records':result,'source_files':[native.verify_source(source/f'Res-map/{r["Dat"]}.dat',f'Res-map/{r["Dat"]}.dat',inventory)for r in rows]}
    write(output/'reports/import-non-tile-worlds-v07.json',report)
    print(json.dumps({'recovered_maps':len(result),'new_prop_instances':report['new_prop_instances'],'missing_prop_instances':report['missing_prop_instances'],'coverage':coverage}),flush=True)
    return report

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--source',type=Path,required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--inventory',type=Path,default=Path('/workspace/analysis/ace-online-ui/archive-inventory.json'));a=p.parse_args();run(a.source,a.output,a.inventory)
if __name__=='__main__':main()
