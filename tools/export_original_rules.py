#!/usr/bin/env python3
"""Export bounded, pinned plaintext ACE rules without running legacy code.

The current OMI has a newer ITEM layout than the historical source. Only the
explicit field offsets below are exported; pointers and unknown tail bytes are
never interpreted. Unknown source hashes are rejected, not guessed.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import math
from pathlib import Path
import struct

PROFILE_SHA = '4831431a42bd37ac3ecffc067989330f6304ce214c0a77e8062d28f1fffb5f48'
SECTIONS = {'ITEM': (0, 0, 16079, 576), 'MEX_MONSTER_INFO': (1, 9261512, 1340, 136),
 'MAPOBJECTINFO': (2, 9443760, 2462, 12), 'BUILDINGNPC': (4, 9777400, 215, 1100),
 'MAP_INFO': (6, 10013908, 238, 1188)}
ITEM_FIELDS = {
 'ItemNum':(0,'i'),'Kind':(4,'B'),'AbilityMin':(48,'f'),'AbilityMax':(52,'f'),
 'ReqRace':(56,'H'),'ReqUnitKind':(70,'H'),'ReqMinLevel':(72,'B'),'ReqMaxLevel':(73,'B'),
 'ReqItemKind':(74,'B'),'Weight':(76,'H'),'HitRate':(80,'f'),'Defense':(84,'B'),
 'FractionResistance':(88,'f'),'NaturalFaction':(92,'B'),'SpeedPenalty':(93,'B'),
 'Range':(94,'H'),'Position':(96,'B'),'Scarcity':(97,'B'),'Endurance':(100,'f'),
 'AbrasionRate':(104,'h'),'Charging':(106,'H'),'Luck':(108,'B'),'MinTradeQuantity':(110,'H'),
 'Price':(112,'I'),'CashPrice':(116,'I'),
 'ReAttacktime':(168,'I'),'Time':(172,'i'),'RepeatTime':(176,'H'),
 'Material':(178,'H'),'ReqMaterial':(180,'H'),'RangeAngle':(184,'f'),'UpgradeNum':(188,'B'),
 'LinkItem':(192,'i'),'MultiTarget':(196,'B'),'ExplosionRange':(198,'H'),'ReactionRange':(200,'H'),
 'ShotNum':(202,'B'),'MultiNum':(203,'B'),'AttackTime':(204,'H'),'ReqSP':(206,'B'),
 'SummonMonster':(208,'i'),'NextSkill':(212,'i'),'SkillLevel':(216,'B'),'SkillHitRate':(218,'h'),
 'SkillType':(220,'B'),'SkillTargetType':(221,'B'),'Caliber':(222,'B'),'OrbitType':(223,'B'),
 'ItemAttribute':(224,'Q'),'BoosterAngle':(232,'f'),'CameraPattern':(236,'i'),'SourceIndex':(240,'i'),
}
MONSTER_FIELDS = {'MonsterUnitKind':(0,'i'),'Level':(44,'B'),'HP':(48,'i'),'Size':(52,'B'),
 'Belligerence':(53,'B'),'AlphaBlending':(54,'B'),'RenderIndex':(56,'H'),'ScaleValue':(60,'f'),
 'TextureIndex':(64,'B'),'SourceIndex':(68,'I'),'MPOption':(72,'Q'),'ClickEvent':(80,'B')}
OBJECT_FIELDS = {'Code':(0,'i'),'Alpha':(4,'B'),'Collision':(5,'B'),'CollisionForServer':(6,'B'),'ObjectRenderType':(7,'B'),'RenderIndex':(8,'H')}
MAP_FIELDS = {'MapIndex':(0,'H'),'RenderMapIndex':(2,'H'),'BeforeMapIndex':(4,'H'),
 'MapInfluenceType':(46,'h'),'CityMapIndex':(48,'H'),'CityWarQuestIndex':(52,'i'),
 'CityWarQuestNPCIndex':(56,'i'),'CityWarQuestMonsterUID':(60,'i'),'MaxUserCount':(64,'h'),
 'MaxGroundHeight':(66,'h'),'MinGroundHeight':(68,'h'),'WaterHeight':(70,'h'),
 'UserVisibleDistance':(72,'h'),'MonsterVisibleDistance':(74,'h'),'QuestIndexForWarp':(76,'i'),
 'FrontPositionDistance':(80,'h'),'AutoRecoveryFlag':(82,'B'),'DefaultMapIndex':(84,'H'),
 'CityWarpTargetPosition':(86,'3h'),'ClientMaxAltitudeHeight':(92,'h'),
 'DayFogColor':(96,'I'),'NightFogColor':(100,'I'),'DayFogStartDistance':(104,'h'),
 'DayFogEndDistance':(106,'h'),'NightFogStartDistance':(108,'h'),'NightFogEndDistance':(110,'h'),
 'DaySunDirection':(112,'3h'),'NightSunDirection':(118,'3h'),'WaterType':(124,'B'),
 'PKZoneFlag':(125,'B'),'TileRenderingFlag':(126,'B'),'SkyRenderingFlag':(127,'B'),
 'SunRenderingFlag':(128,'B'),'FogRenderingFlag':(129,'B'),'VCNWarpObjectIndex':(132,'i'),
 'ANIWarpObjectIndex':(136,'i'),'Dat':(140,'H'),'Map':(142,'H'),'Tex':(144,'H'),
 'Cloud':(146,'H'),'Sky':(148,'H'),'Nsky':(150,'H'),'Bgm':(152,'H'),
 'TeleportWarpObjectIndex':(156,'i'),'BeforeMapIndex2':(160,'H')}
NPC_FIELDS = {'BuildingIndex':(0,'I'),'BuildingKind':(44,'B'),'MapIndex':(46,'H'),
 'NPCIndex':(48,'I'),'OwnerCityMapIndex':(1092,'H'),'OwnerOrderNumber':(1096,'i')}
GEARS = {'12000100':7001230,'12001100':7002580,'12003100':7002570,'12002100':7002590}


def digest(data: bytes) -> str:
 return hashlib.sha256(data).hexdigest()


def textz(data: bytes) -> str:
 return data.split(b'\0',1)[0].decode('cp949', errors='replace')


def fields(data: bytes, schema: dict) -> dict:
 result={}
 for name,(offset,kind) in schema.items():
  values=struct.unpack_from('<'+kind,data,offset)
  result[name]=values[0] if len(values)==1 else list(values)
 if any(isinstance(v,float) and not math.isfinite(v) for v in result.values()):
  raise ValueError('Non-finite native scalar')
 return result


def load_omi(path: Path) -> dict:
 raw=path.read_bytes()
 if digest(raw)!=PROFILE_SHA:
  raise ValueError('Unsupported OMI SHA-256; this exporter accepts only the documented plaintext profile')
 catalogs={}
 for name,(typ,start,count,stride) in SECTIONS.items():
  if struct.unpack_from('<ii',raw,start)!=(typ,count):
   raise ValueError('Section header mismatch: '+name)
  end=start+8+count*stride
  if end>len(raw):raise ValueError('Section outside source file')
  records=[]
  schema,key={'ITEM':(ITEM_FIELDS,'ItemNum'),'MEX_MONSTER_INFO':(MONSTER_FIELDS,'MonsterUnitKind'),
   'MAPOBJECTINFO':(OBJECT_FIELDS,'Code'),'BUILDINGNPC':(NPC_FIELDS,'BuildingIndex'),
   'MAP_INFO':(MAP_FIELDS,'MapIndex')}[name]
  for index in range(count):
   offset=start+8+index*stride;data=raw[offset:offset+stride];record=fields(data,schema)
   if name=='ITEM':
    record['ItemName']=textz(data[5:45]);record['ItemAttributeHex']=f"0x{record['ItemAttribute']:016x}"
   if name=='MEX_MONSTER_INFO':
    record['MonsterName']=textz(data[4:44]);record['PortraitFileName']=textz(data[81:131])
    record.update({'Defense':None,'DefenseProbability':None,'Speed':None,'Shield':None,'weapons':None})
    record['MPOptionHex']=f"0x{record['MPOption']:016x}"
   if name=='MAP_INFO':
    record['MapName']=textz(data[6:46]);record['MapDescription']=textz(data[162:1186])
    record['project']=None;record['terrain']=None
   if name=='BUILDINGNPC':
    record['BuildingName']=textz(data[4:44]);record['NPCName']=textz(data[52:92]);record['GreetingTalk']=textz(data[92:1092])
    record['position']=None
   record['_source']={'id':'omi','offset':offset,'size':stride,'record_index':index,'sha256':digest(data)}
   records.append(record)
  if len({r[key] for r in records})!=count:raise ValueError('Duplicate native key in '+name)
  catalogs[name]=records
 if SECTIONS['ITEM'][1]+8+SECTIONS['ITEM'][2]*SECTIONS['ITEM'][3]!=SECTIONS['MEX_MONSTER_INFO'][1]:raise ValueError('ITEM boundary mismatch')
 if SECTIONS['MEX_MONSTER_INFO'][1]+8+SECTIONS['MEX_MONSTER_INFO'][2]*SECTIONS['MEX_MONSTER_INFO'][3]!=SECTIONS['MAPOBJECTINFO'][1]:raise ValueError('Monster boundary mismatch')
 catalogs['source']={'id':'omi','filename':path.name,'size':len(raw),'sha256':digest(raw),'profile':'current_plaintext_576_136_12'}
 return catalogs


def load_workspace(path: Path) -> tuple[dict,dict]:
 raw=path.read_bytes()
 if len(raw)<64:raise ValueError('Workspace header truncated')
 count=struct.unpack_from('<i',raw,60)[0]
 if not 0<=count<=10000 or 64+count*148!=len(raw):raise ValueError('Workspace size/count mismatch')
 records={}
 for i in range(count):
  off=64+i*148;r=raw[off:off+148];name=textz(r[4:44])
  if not name.isdecimal():raise ValueError('Non-numeric workspace project name')
  sx,sz=struct.unpack_from('<hh',r,84)
  if not 1<=sx<=4096 or not 1<=sz<=4096:raise ValueError('Invalid workspace dimensions')
  vals=struct.unpack_from('<15f',r,88)
  if not all(math.isfinite(v) for v in vals):raise ValueError('Non-finite workspace scalar')
  records[int(name)]={'tile_count_x':sx,'tile_count_z':sz,'tile_size':40,'bounds_x':[0,sx*40],
   'bounds_z':[0,sz*40],'editor_height_max':vals[0],'editor_height_min':vals[1],
   'water_height':vals[2],'diffuse_day':list(vals[3:6]),'ambient_day':list(vals[6:9]),
   'diffuse_night':list(vals[9:12]),'ambient_night':list(vals[12:15]),
   '_source':{'id':'workspace','offset':off,'size':148,'sha256':digest(r)}}
 return records,{'id':'workspace','filename':path.name,'size':len(raw),'sha256':digest(raw)}


def load_terrain_events(path: Path) -> tuple[dict,list[dict]]:
 raw=path.read_bytes()
 if len(raw)<20:raise ValueError('Terrain container truncated')
 count=struct.unpack_from('<i',raw,12)[0]
 if not 0<=count<=10000:raise ValueError('Invalid terrain entry count')
 off=20;entries={}
 for _ in range(count):
  if off+24>len(raw):raise ValueError('Terrain entry header truncated')
  size=struct.unpack_from('<i',raw,off+4)[0];name=raw[off+12:off+22].split(b'\0',1)[0].decode('ascii');off+=24
  if size<0 or off+size>len(raw) or name in entries:raise ValueError('Invalid terrain entry bounds/name')
  entries[name]=(off,raw[off:off+size]);off+=size
 entry_name=path.stem
 if entry_name not in entries:raise ValueError('Expected terrain entry missing: '+entry_name)
 po,payload=entries[entry_name]
 if len(payload)<36:raise ValueError('Terrain payload truncated')
 tile,nv,nt,no=struct.unpack_from('<fiii',payload,20);side=math.isqrt(nv)
 if not math.isfinite(tile) or tile<=0 or side*side!=nv or (side-1)**2!=nt or no<0:
  raise ValueError('Terrain grid/count mismatch')
 if 36+nv*24+nt*24+no*112!=len(payload):raise ValueError('Terrain record extent mismatch')
 object_start=36+nv*24+nt*24;center=(side-1)*tile/2
 events=[]
 for i in range(no):
  ro=object_start+i*112;r=payload[ro:ro+112]
  if not struct.unpack_from('<i',r,60)[0]:continue
  pos=list(struct.unpack_from('<3f',r,8));vel=list(struct.unpack_from('<3f',r,20));up=list(struct.unpack_from('<3f',r,32))
  if not all(math.isfinite(v) for v in pos+vel+up):raise ValueError('Non-finite event placement')
  pa,pb,pc=struct.unpack_from('<3h',r,66);typ=r[64]
  events.append({'map_id':int(entry_name),'event_id':pa,'event_type':typ,'kind':'warp' if typ==1 else 'pattern_point' if typ==8 else 'other_event',
   'object_code':struct.unpack_from('<I',r)[0],'destination_map_id':pc if typ==1 else None,
   'destination_event_id':pb if typ==1 else None,'parameters':[pa,pb,pc],
   'next_event_index':struct.unpack_from('<I',r,52)[0],
   'position_legacy':pos,'position':[pos[0]-center,pos[1],center-pos[2]],
   'direction_legacy':vel,'up_legacy':up,'event_text':textz(r[72:112]),
   '_source':{'id':'dat:'+entry_name,'offset':po+ro,'size':112,'record_index':i,'sha256':digest(r)}})
 source={'id':'dat:'+entry_name,'filename':path.name,'size':len(raw),'sha256':digest(raw),
  'tile_size':tile,'tile_count_x':side-1,'tile_count_z':side-1,'vertex_count':nv,'object_count':no,
  'entry_offset':po,'opaque_trailing_size':len(raw)-off,'opaque_trailing_sha256':digest(raw[off:])}
 return source,events


def load_mission_catalog(path: Path) -> tuple[dict,dict]:
 """Import the separately audited DSL parser result; never evaluate quest code."""
 raw=path.read_bytes();document=json.loads(raw)
 if not isinstance(document,dict) or document.get('schema_version')!=1:
  raise ValueError('Mission catalog schema_version must be1')
 records=document.get('records')
 if not isinstance(records,list) or len(records)>10000:
  raise ValueError('Mission catalog records must be a bounded list')
 ids=set()
 for record in records:
  if not isinstance(record,dict):raise ValueError('Mission record must be an object')
  key=record.get('QuestIndex')
  if isinstance(key,bool) or not isinstance(key,int) or key<=0 or key in ids:
   raise ValueError('Mission QuestIndex must be unique and positive')
  ids.add(key)
  if not isinstance(record.get('QuestName'),str):raise ValueError('Mission QuestName must be a string')
 if not isinstance(document.get('source'),dict):raise ValueError('Mission catalog source provenance missing')
 source={'id':'mission_catalog','filename':path.name,'size':len(raw),'sha256':digest(raw)}
 result=dict(document);result['status']='recovered_original_records';result['input_catalog']=source
 return result,source


def envelope(catalog: dict, fields_schema: dict, evidence: list[str]) -> dict:
 return {'schema_version':1,'source':catalog['source'],'field_offsets':{k:{'offset':v[0],'format':'<'+v[1]} for k,v in fields_schema.items()},'evidence':evidence}


def export(args) -> None:
 c=load_omi(args.metadata);items={r['ItemNum']:r for r in c['ITEM']}
 out=args.output;out.mkdir(parents=True,exist_ok=True)
 sources=[c['source']];events=[]
 archive_paths=None
 if args.archive_listing:
  listing=args.archive_listing.read_bytes()
  archive_paths={line[7:].strip().lower() for line in listing.decode('utf-8',errors='replace').splitlines() if line.startswith('Path = ')}
  sources.append({'id':'archive_listing','filename':args.archive_listing.name,'size':len(listing),'sha256':digest(listing)})
 for row in c['MAP_INFO']:
  row['resource_bindings']={'terrain_dat':f"Res-map/{row['Dat'] or row['MapIndex']:04d}.dat",
   'terrain_entry':f"{row['RenderMapIndex'] or row['MapIndex']:04d}",
   'ground_textures':f"Res-map/{row['Map']:04d}.map",'minimap_detail':f"Res-map/{row['Tex']:04d}.tex"}
  if archive_paths is not None:
   row['archive_availability']={key:path.lower() in archive_paths for key,path in row['resource_bindings'].items() if key!='terrain_entry'}
 if args.workspace_data:
  projects,source=load_workspace(args.workspace_data);sources.append(source)
  for row in c['MAP_INFO']:row['project']=projects.get(row['MapIndex'])
 for path in args.terrain:
  source,terrain_events=load_terrain_events(path);sources.append(source);events.extend(terrain_events)
  for row in c['MAP_INFO']:
   if row['MapIndex']==int(path.stem):row['terrain']=source
 common_refs=['EP3.5 Client/Common/AtumParam.h:2544-2620 (field order; current ITEM includes layout changes)', 'EP3.5 Client/ProjectAtum/main/AtumDatabase.cpp:113-121 (raw ITEM load)']
 engine=envelope(c,ITEM_FIELDS,common_refs+['EP3.5 Client/DataRenderLib/main/ShuttleChild.cpp:3943-3948,3994'])
 engine.update({'by_gear':{gear:items[item] for gear,item in GEARS.items()},'records':[r for r in c['ITEM'] if r['Kind']==17],
  'selection':{'kind':'local_explicit_loadout','description':'Level1 original engines selected per compatible ReqUnitKind. This is not a claim about original character default equipment.','gear_masks':{'B':15,'M':240,'A':3840,'I':61440}},
  'layout_limit':'Only explicitly mapped scalar fields exported. Current ITEM stride576 differs from historical source; unknown parameter array and tail omitted.'})
 weapons=envelope(c,ITEM_FIELDS,common_refs+['EP3.5 Client/Common/AtumParam.h:1228-1259'])
 weapons.update({'primary':items[7000040],'secondary':items[7901000],'records':[r for r in c['ITEM'] if 0<=r['Kind']<=15],
  'selection':{'kind':'local_explicit_loadout','description':'Original level1 worn primary and secondary records compatible with B/M/I masks; original default equipment is not asserted.'}})
 monsters=envelope(c,MONSTER_FIELDS,['EP3.5 Client/Common/AtumProtocol.h:9304-9337','EP3.5 Client/ProjectAtum/main/AtumDatabase.cpp:126-134'])
 monsters.update({'records':c['MEX_MONSTER_INFO'],'missing_fields':['Defense','DefenseProbability','Speed','Shield','weapons'],'spawn_points':[],
  'limitations':['MEX_MONSTER_INFO is the client subset; server combat fields are absent, not zero. No map3002 spawns have been proven.']})
 obj=envelope(c,OBJECT_FIELDS,['EP3.5 Client/Common/AtumParam.h:3077-3106','EP3.5 Client/DataRenderLib/main/ObjRender.cpp:63-101'])
 obj['records']=c['MAPOBJECTINFO']
 maps=envelope(c,MAP_FIELDS,['EP3.5 Client/Common/AtumParam.h:199-205 (AVECTOR3 is three int16)',
  'EP3.5 Client/Common/AtumParam.h:4012-4060','EP3.5 Client/ProjectAtum/main/AtumDatabase.cpp:205-214'])
 maps.update({'sources':sources,'records':c['MAP_INFO'],'by_id':{str(r['MapIndex']):r for r in c['MAP_INFO']},
  'section':{'type':6,'header_offset':10013908,'record_offset':10013916,'count':238,'stride':1188,
   'next_header_offset':10296660,'next_header_type':7,'next_header_count':39230},
  'availability_note':'Catalog bindings do not assert that a runtime scene or server map is available. Consumers must check imported resources.',
  'coordinates':'Native Y-up, X/Z horizontal. Event position uses target=(native.x-gridWidth/2,native.y,gridDepth/2-native.z). Editor height limits are not ClientMaxAltitudeHeight.'})
 npcs=envelope(c,NPC_FIELDS,['EP3.5 Client/Common/AtumParam.h:1483-1493',
  'EP3.5 Client/ProjectAtum/main/AtumDatabase.cpp:169-180'])
 npcs.update({'records':c['BUILDINGNPC'],'section':{'type':4,'header_offset':9777400,'count':215,'stride':1100,'next_header_offset':10013908},
  'limitations':['Building/NPC metadata and native greeting text are available. A position requires a matching map event/object; no positions are invented.']})
 mission={'schema_version':1,'records':[],'status':'unavailable_in_plaintext_inputs',
  'evidence':['EP3.5 Client/DataRenderLib/main/QuestData.cpp:33,49-74'],
  'limitations':['The source routes quest.tex through an encoded resource path. No quest decoding, bypass, or original objectives/rewards are claimed by this plaintext exporter. Local missions must be labeled separately.']}
 if args.mission_catalog:
  mission,source=load_mission_catalog(args.mission_catalog);sources.append(source)
 world={'schema_version':1,'sources':sources,'maps':c['MAP_INFO'],'npcs':c['BUILDINGNPC'],
  'events':events,'portals':[r for r in events if r['event_type']==1],
  'missions':mission['records'],'mission_status':mission['status'],'spawn_points':[],
  'evidence':['EP3.5 Client/Common/AtumParam.h:2292,2300 (warp versus pattern point)',
   'EP3.5 Server/GameServer/FieldServer/Main/FieldIOCPSocket.cpp:12706,13088-13104 (param3 destination map, param2 destination warp index)'],
  'gaps':['Original monster spawns are not present in the inspected DAT map container.',
   'Server MONSTER_INFO defense/AI/weapons are absent from client MEX_MONSTER_INFO.',
   'Catalog map/NPC/mission records do not guarantee available geometry, original server services, or sessions.']}
 combat={'schema_version':1,'source':c['source'],'primary':items[7000040],'secondary':items[7901000],
  'monster':c['MEX_MONSTER_INFO'][0],'monster_weapon':None,'player':None,'spawn_points':[],
  'scenario':{'kind':'local_adaptation_pending','description':'Weapons and monster presentation/HP are native records. Local placement, player stats, monster defense/speed/weapon require explicit adaptation; no original map spawn claimed.'},
  'missing_fields':['player','monster.Defense','monster.DefenseProbability','monster.Speed','monster.Shield','monster_weapon','spawn_points']}
 documents={'engines.json':engine,'weapons.json':weapons,'monsters.json':monsters,'map_objects.json':obj,
  'combat.json':combat,'maps.json':maps,'npcs.json':npcs,'missions.json':mission,'world_rules.json':world}
 for filename,data in documents.items():
  (out/filename).write_text(json.dumps(data,ensure_ascii=False,indent=2,allow_nan=False)+'\n')
 manifest={'schema_version':1,'exporter_sha256':digest(Path(__file__).read_bytes()),'sources':sources,
  'files':{filename:{'sha256':digest((out/filename).read_bytes()),'size':(out/filename).stat().st_size} for filename in documents},
  'item_layout_status':'Current source-specific offsets verified for the pinned576-byte dataset; unknown parameter array/tail omitted.',
  'native_names_encoding':'CP949 decoded to Unicode; raw record hashes/offsets retain byte provenance.',
  'uint64_note':'Godot JSON may lose precision for native64-bit numeric flags. Use ItemAttributeHex/MPOptionHex for exact masks.'}
 if archive_paths is not None:
  manifest['archive_map_resource_counts']={ext:sum(path.startswith('res-map/') and path.endswith('.'+ext) for path in archive_paths) for ext in ['dat','map','tex','sky','cld','sma','wok']}
 if args.source_root:
  source_files=['Client/Common/AtumParam.h','Client/Common/AtumProtocol.h','Client/ProjectAtum/main/AtumDatabase.cpp',
   'Client/DataRenderLib/main/ShuttleChild.cpp','Client/DataRenderLib/main/QuestData.cpp',
   'Server/GameServer/FieldServer/Main/FieldIOCPSocket.cpp']
  manifest['source_commit']='7c3e47ac47844e5c415d356a94d6201a0b9a38c4'
  manifest['source_files']={p:digest((args.source_root/p).read_bytes()) for p in source_files}
 (out/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
 print(json.dumps({'output':str(out),'records':{k:len(v.get('records',[])) for k,v in documents.items()},'source_sha256':c['source']['sha256']}))


def main() -> None:
 parser=argparse.ArgumentParser(description=__doc__)
 parser.add_argument('--metadata',type=Path,required=True)
 parser.add_argument('--workspace-data',type=Path)
 parser.add_argument('--terrain',type=Path,action='append',default=[])
 parser.add_argument('--source-root',type=Path)
 parser.add_argument('--archive-listing',type=Path)
 parser.add_argument('--mission-catalog',type=Path,help='Audited schema1 quest DSL parser JSON with native QuestIndex/QuestName records')
 parser.add_argument('--output',type=Path,default=Path(__file__).resolve().parents[1]/'client/assets/legacy_rules')
 args=parser.parse_args()
 try:export(args)
 except (OSError,ValueError,struct.error) as exc:parser.exit(1,str(exc)+'\n')

if __name__=='__main__':main()
