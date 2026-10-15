#!/usr/bin/env python3
"""Generate a real v0.8 room with pinned Git scripts, then test current import.

Historical source is extracted from Git, never approximated by stripping fields
from a current save. Numeric assets are copied byte-for-byte from this checkout.
"""
from __future__ import annotations
import argparse
import ast
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

COMMIT = 'c7a18413cf13383876a00db77ad724ffb02158f8'
GENERATOR = '''extends SceneTree
const Arena = preload("res://scripts/online/arena_model.gd")
const World = preload("res://scripts/online/headless_world.gd")
func _initialize() -> void:
	var world = World.new()
	if not world.configure(3002):quit(2);return
	var arena = Arena.new()
	if not arena.configure({"room_id":"migration-v08","seed":12345,"max_players":2},world):quit(3);return
	arena.add_player("alice")
	arena.add_player("bob")
	for id: String in ["alice","bob"]:
		arena.pilots[id].flight.position=Vector3(0,1500,100)
		arena.pilots[id].flight.profile_ready=false
	for index in range(3):
		arena.combat.targets[index].position=Vector3(0,1500,-100-index*700)
		arena.combat.targets[index].spawn_position=arena.combat.targets[index].position
		arena.combat.targets[index].speed=0.0
		arena.combat.targets[index].hostile=false
	for frame in range(55):
		for id: String in ["alice","bob"]:
			arena.submit_input(id,frame,{"primary":true,"secondary":true})
		arena.advance(0.1)
	arena.combat.activate_pilot("alice")
	arena.combat.player.hp-=17.0
	arena.combat.player.primary_ammo-=7
	arena.combat.player.primary_cooldown=0.125
	arena.combat.select_target(1)
	arena.combat.lock_progress=1.0
	arena.combat.player.secondary_cooldown=0.0
	arena.combat._fire_secondary(Vector3.FORWARD)
	arena.combat.store_pilot()
	arena.command("bob","historical-skill","skill_use",{"slot":1})
	arena._process_event({"type":"hit","id":1,"target_life":0,"pilot_id":"alice"})
	var output:=OS.get_cmdline_user_args()[0]
	var file:=FileAccess.open(output,FileAccess.WRITE)
	file.store_string(JSON.stringify(arena.export_state()))
	file.close()
	print("V08_FIXTURE="+JSON.stringify({"pilots":arena.pilots.size(),"projectiles":arena.combat.projectiles.size(),"rewarded":arena._rewarded.size(),"contributions":arena._contributions.size(),"tick":arena.tick}))
	quit(0)
'''

def main() -> int:
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source',type=Path,default=Path(__file__).resolve().parents[2])
    parser.add_argument('--godot',type=Path,required=True)
    parser.add_argument('--fixture',type=Path,default=Path('/tmp/ace-real-v08-room.json'))
    parser.add_argument('--report',type=Path,default=Path('/tmp/ace-real-v08-migration.json'))
    parser.add_argument('--generate-only',action='store_true')
    args=parser.parse_args()
    root=args.source.resolve()
    def historical(path:str)->bytes:
        return subprocess.run(['git','show',f'{COMMIT}:{path}'],cwd=root,check=True,capture_output=True).stdout
    builder=ast.parse(historical('tools/build_server_bundle.py').decode())
    constants={}
    for node in builder.body:
        if isinstance(node,ast.Assign) and len(node.targets)==1 and isinstance(node.targets[0],ast.Name) and node.targets[0].id in ('CORE_SCRIPTS','ONLINE_SCRIPTS','DATA_FILES'):
            constants[node.targets[0].id]=ast.literal_eval(node.value)
    world_files=('assets/original_world/3002_terrain.json','assets/original_world/3002_heights.f32','assets/original_world/3002_water_flags.u8','assets/original_world/3002_landing_flags.u8','assets/original_props/placements.json')+tuple(f'assets/original_props/{code}_collision.json' for code in ('03001700','03001800','03002000','03002600','03002700','03002800','03002900','03003000','03003500','03003800'))
    provenance={'historical_commit':COMMIT,'historical_scripts':[],'numeric_assets':[]}
    args.fixture.parent.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='ace-real-v08-source-') as name:
        temp=Path(name)
        scripts=[*(f'scripts/{name}' for name in constants['CORE_SCRIPTS']),*(f'scripts/online/{name}' for name in constants['ONLINE_SCRIPTS'])]
        for name in ['project.godot',*scripts]:
            data=historical('client/'+name)
            target=temp/name;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(data)
            provenance['historical_scripts'].append({'path':'client/'+name,'sha256':hashlib.sha256(data).hexdigest()})
        for name in [*constants['DATA_FILES'],*world_files]:
            source=root/'client'/name
            target=temp/name;target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(source,target)
            digest=hashlib.sha256(target.read_bytes()).hexdigest()
            if digest!=hashlib.sha256(source.read_bytes()).hexdigest():raise RuntimeError('Numeric asset changed during fixture generation')
            provenance['numeric_assets'].append({'path':'client/'+name,'sha256':digest,'bytes':target.stat().st_size})
        (temp/'generate.gd').write_text(GENERATOR)
        process=subprocess.run([str(args.godot),'--headless','--path',str(temp),'--script','res://generate.gd','--',str(args.fixture.resolve())],capture_output=True,text=True,timeout=60)
        if process.returncode or 'SCRIPT ERROR' in process.stderr or not args.fixture.is_file():
            raise RuntimeError('Real historical fixture generation failed: '+process.stdout+process.stderr)
        result=[json.loads(line.removeprefix('V08_FIXTURE=')) for line in process.stdout.splitlines() if line.startswith('V08_FIXTURE=')]
        provenance['historical_fixture']=result[0]
        provenance['fixture_sha256']=hashlib.sha256(args.fixture.read_bytes()).hexdigest()
    if not args.generate_only:
        current_builder=ast.parse((root/'tools/build_server_bundle.py').read_text())
        current={}
        for node in current_builder.body:
            if isinstance(node,ast.Assign) and len(node.targets)==1 and isinstance(node.targets[0],ast.Name) and node.targets[0].id in ('CORE_SCRIPTS','ONLINE_SCRIPTS','DATA_FILES'):
                current[node.targets[0].id]=ast.literal_eval(node.value)
        with tempfile.TemporaryDirectory(prefix='ace-current-migration-source-') as name:
            temp=Path(name)
            for name in ['project.godot',*(f'scripts/{n}' for n in current['CORE_SCRIPTS']),*(f'scripts/online/{n}' for n in current['ONLINE_SCRIPTS']),*current['DATA_FILES'],*world_files]:
                target=temp/name;target.parent.mkdir(parents=True,exist_ok=True)
                shutil.copyfile(root/'client'/name,target)
            (temp/'tests').mkdir()
            shutil.copyfile(root/'server/tests/test_arena_migration.gd',temp/'tests/test_arena_migration.gd')
            process=subprocess.run([str(args.godot),'--headless','--path',str(temp),'--script','res://tests/test_arena_migration.gd','--',str(args.fixture.resolve())],capture_output=True,text=True,timeout=90)
            output=process.stdout+process.stderr
            results=[json.loads(line.removeprefix('ARENA_MIGRATION_TEST=')) for line in process.stdout.splitlines() if line.startswith('ARENA_MIGRATION_TEST=')]
            passed=process.returncode==0 and len(results)==1 and not results[0].get('failures') and results[0].get('checks',0)>0 and not any(marker in output for marker in ('SCRIPT ERROR','ERROR:','Parse Error'))
            provenance['current_test_returncode']=0 if passed else 1
            provenance['current_test_output']=output
            provenance['current_test_result']=results[0] if len(results)==1 else {}
            print(process.stdout,end='');print(process.stderr,end='')
    args.report.parent.mkdir(parents=True,exist_ok=True)
    args.report.write_text(json.dumps(provenance,indent=2,ensure_ascii=False)+'\n')
    print('REAL_V08_MIGRATION_REPORT='+str(args.report))
    return 0 if args.generate_only else int(provenance['current_test_returncode'])

if __name__=='__main__':raise SystemExit(main())
