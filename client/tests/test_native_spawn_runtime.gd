extends SceneTree
const Runtime = preload("res://scripts/combat_runtime.gd")
const Spawn = preload("res://scripts/native_spawn_data.gd")
var checks := 0
var failures: Array[String] = []


class PopulationRuntime extends Runtime:
	# Exercise scheduling/state without importing the multi-gigabyte visual pack.
	func _create_target(spawn: Dictionary, identifier: int) -> bool:
		var profile: Dictionary = _monster_profile_for_spawn(spawn)
		model.add_target(profile,spawn.position,identifier)
		_restore_native_target(model.targets[-1])
		return true


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_scheduling()
	_test_population_state()
	_test_source_fail_closed()
	_test_native_profile_overrides()
	_test_save_transaction()
	print(JSON.stringify({"suite":"native-spawn-runtime","checks":checks,"failures":failures.size(),"scope":"native_position_identity_and_timers;persisted_offline_channel_clock;data_only_population"}))
	for message: String in failures:printerr(JSON.stringify({"failure":message}))
	quit(0 if failures.is_empty() else 1)


func _row(index: int = 0) -> Dictionary:
	return {"map_id":3004,"event_id":7+index,"monster_uid":2000000,"object_code":3018500,"position_native":[100.0+index,20.0,200.0],"direction_native":[0.0,0.0,1.0],"up_native":[0.0,1.0,0.0],"event_type":6,"event_enabled":true,"event_enabled_raw":1,"body_condition_raw":2,"is_city_war_raw":0,"parameters":[7+index,0,10],"next_event_index":3018500,"source":{"id":"dat:3004","offset":44+112*index,"size":112,"record_index":index,"sha256":"a".repeat(64)}}


func _catalog(rows: Array) -> Dictionary:
	return {"schema_version":1,"source_files":[{"id":"dat:3004","sha256":"b".repeat(64),"size":1000,"object_count":8,"tile_count_x":8,"tile_count_z":16,"tile_size_native":40.0}],"object_spawns":rows,"region_spawns":[]}


func _fixture() -> Node3D:
	var runtime := PopulationRuntime.new()
	root.add_child(runtime)
	runtime.player_node = Node3D.new()
	runtime.add_child(runtime.player_node)
	runtime._native_monsters = {2000000:{"MonsterUnitKind":2000000,"Belligerence":1,"HP":303,"DP":null,"Level":9,"MoveSpeed":0}}
	var maps := {3004:{"MapIndex":3004,"Dat":3004,"MapInfluenceType":1001}}
	_check(runtime.native_spawns.configure(_catalog([_row(),_row(1)]),maps,runtime._native_monsters).ok,"two exact native placements configure")
	runtime._native_spawn_required = true
	runtime._profile = Runtime._read_json("res://assets/legacy_rules/combat.json")
	runtime._encounter = {"kind":"explicit_local_encounter","player":{"level":9},"maps":{"3004":{"targets":[{"monster_code":999,"offset":[0,0,0]}]}}}
	runtime._map_index = 3004
	runtime.inventory.configure()
	runtime.inventory.set_starting_level(9)
	runtime.reset()
	return runtime


func _test_scheduling() -> void:
	var runtime: Node3D = _fixture()
	_check(runtime.model.targets.is_empty() and runtime._encounter_spawns().is_empty(),"native initial interval prevents fabricated local actors")
	runtime._native_channel_clock = 9.99
	_check(runtime._encounter_spawns().is_empty(),"one-second native creation check waits until exact due tick")
	runtime._native_channel_clock = 10.0
	runtime.refresh_encounter()
	_check(runtime.model.targets.size() == 2 and runtime.model.targets[0].position == Vector3(-60,20,120) and runtime.model.targets[1].position == Vector3(-59,20,120),"same-UID placements retain both exact original positions")
	runtime.refresh_encounter()
	_check(runtime.model.targets.size() == 2,"refresh cannot add a second living actor for one native placement")
	var clock: float = runtime._native_channel_clock
	runtime.advance(50.0,{})
	_check(runtime._native_channel_clock > clock and runtime._native_channel_clock - clock <= 0.501,"offline native clock advances only by bounded actual simulated time")
	runtime._remote_active = true
	clock = runtime._native_channel_clock
	runtime.advance(1.0,{})
	_check(runtime._native_channel_clock == clock,"online snapshots never advance or create offline native population")
	runtime.free()


func _test_population_state() -> void:
	var runtime: Node3D = _fixture()
	runtime._native_channel_clock = 20.0
	runtime.refresh_encounter()
	runtime.model.targets[0].hp = 100.0
	runtime.model.targets[0].position = Vector3(-40,30,100)
	runtime.model.targets[0].life = 3
	runtime.model.targets[1].hp = 0.0
	runtime.model.targets[1].dead = true
	runtime.model.targets[1].respawn_remaining = 7.0
	runtime.model.targets[1].life = 2
	runtime.reset()
	_check(runtime.model.targets[0].hp == 100.0 and runtime.model.targets[0].position == Vector3(-40,30,100) and runtime.model.targets[0].life == 3,"reset preserves native living HP, position and life")
	_check(runtime.model.targets[1].dead and runtime.model.targets[1].respawn_remaining == 7.0 and runtime.model.targets[1].life == 2,"portal/reset cannot refill a killed placement or bypass respawn delay")
	var saved: Dictionary = runtime.export_state()
	_check(saved.native_actor_states.size() == 2 and saved.native_channel_clock == 20.0 and runtime._validate_native_population(saved).ok,"save captures complete validated native population and active clock")
	var target: Dictionary = runtime.model.targets[1]
	runtime._native_channel_clock = 24.0
	runtime._restore_native_target(target)
	_check(target.dead and target.respawn_remaining == 3.0,"off-map active time reduces native respawn countdown")
	runtime._native_channel_clock = 27.0
	runtime._restore_native_target(target)
	_check(not target.dead and target.hp == 303.0 and target.life == 3 and target.position == target.spawn_position,"elapsed native respawn restores current-client HP exactly once with new life")
	_check(runtime._validate_native_population({}).ok,"old saves without population fields remain loadable")
	for patch: Dictionary in [{"placement_id":"forged"},{"monster_code":123},{"hp":304},{"hp":NAN},{"saved_clock":21},{"life":1.5},{"position":[0,INF,0]},{"respawn_remaining":11}]:
		var bad: Dictionary = saved.duplicate(true)
		bad.native_actor_states[0].merge(patch,true)
		_check(not runtime._validate_native_population(bad).ok,"invalid source/vitals/time cannot enter population:"+str(patch.keys()))
	var duplicate: Dictionary = saved.duplicate(true)
	duplicate.native_actor_states.append(duplicate.native_actor_states[0])
	_check(not runtime._validate_native_population(duplicate).ok,"duplicate persisted native placement is rejected")
	runtime.free()


func _test_source_fail_closed() -> void:
	var runtime: Node3D = _fixture()
	var row := _row()
	row.is_city_war_raw = 1
	runtime.native_spawns.configure(_catalog([row]),{3004:{"MapIndex":3004,"Dat":3004,"MapInfluenceType":1001}},runtime._native_monsters)
	runtime._native_spawn_cache.clear()
	runtime._native_channel_clock = 100.0
	_check(runtime._encounter_spawns().is_empty() and not runtime._encounter_gaps.is_empty(),"gated source placement never receives generic local substitute")
	var catalog := _catalog([])
	catalog.region_spawns = [{"map_id":3004,"monster_uid":2000000}]
	runtime.native_spawns.configure(catalog,{3004:{"MapIndex":3004}},runtime._native_monsters)
	runtime._native_spawn_cache.clear()
	_check(runtime._encounter_spawns().is_empty(),"source SMA region never becomes an invented center encounter")
	runtime.native_spawns.configure({}, {}, {})
	runtime._native_spawn_cache.clear()
	_check(runtime._encounter_spawns().is_empty(),"production missing/corrupt source catalog fails closed")
	runtime.free()


func _test_save_transaction() -> void:
	var runtime: Node3D = _fixture()
	# Use actual owned native starter equipment to validate the entire import path.
	runtime._encounter = Runtime._read_json("res://assets/local_encounter.json")
	for row: Dictionary in Runtime._read_json("res://assets/legacy_rules/weapons.json").records:runtime._native_weapons[int(row.ItemNum)] = row
	for gear: Dictionary in runtime._encounter.gear_loadouts.values():
		for slot: String in ["primary","secondary"]:runtime.inventory.add_item(int(gear[slot]))
	for entry: Dictionary in Runtime._read_json("res://assets/legacy_rules/engines.json").by_gear.values():runtime.inventory.add_item(int(entry.get("item",entry).ItemNum))
	runtime.grant_local_starter_equipment()
	_check(runtime.configure_gear("12003100").ok,"actual native starter inventory supplies a valid complete save fixture")
	runtime._native_channel_clock = 30.0
	runtime.reset()
	runtime.model.targets[0].hp = 99.0
	runtime.model.targets[1].hp = 0.0
	runtime.model.targets[1].dead = true
	runtime.model.targets[1].respawn_remaining = 8.0
	var saved: Dictionary = runtime.export_state()
	runtime.model.targets[0].hp = 1.0
	var restored: Dictionary = runtime.import_state(saved)
	_check(restored.ok and runtime.model.targets[0].hp == 99.0 and runtime.model.targets[1].dead and runtime.model.targets[1].respawn_remaining == 8.0,"entire save/import restores native population without overwriting it from current actors")
	var bad: Dictionary = saved.duplicate(true)
	bad.native_actor_states[0].hp = 10000
	var before: Dictionary = runtime.export_state()
	_check(not runtime.import_state(bad).ok and runtime.export_state() == before,"invalid native population rejects full save before inventory/model mutation")
	runtime.free()


func _test_native_profile_overrides() -> void:
	var runtime: Node3D = _fixture()
	# Synthetic current-client values expose accidental training replacement;
	# these are not asserted to be recovered SQL defense/speed conversions.
	var current: Dictionary = runtime._native_monsters[2000000]
	current.merge({"Defense":17.0,"DefenseProbability":9.0,"DP":7.0,"MoveSpeed":11.0,"hostile":false,"Belligerence":4},true)
	runtime._encounter.monster_overrides = {"Defense":0.0,"DefenseProbability":0.0,"DP":0.0,"MoveSpeed":25.0,"hostile":true}
	var spawn: Dictionary = runtime._native_map_spawns(3004).records[0].duplicate(true)
	spawn.native_spawn = true
	spawn.allow_training_weapon_bridge = true
	var native: Dictionary = runtime._monster_profile_for_spawn(spawn)
	_check(native.Defense == 17.0 and native.DefenseProbability == 9.0 and native.DP == 7.0 and native.MoveSpeed == 11.0 and not native.hostile,"production native profile retains current-client stats and hostility instead of training overrides")
	_check(native.HP == 303 and native.Belligerence == 4 and native.source_placement_id == "dat:3004:0" and native.respawn_seconds == 10.0,"native placement metadata and current HP/Belligerence survive profile construction")
	_check(native.npc_weapon_options.is_empty() and native.weapon.is_empty(),"native placement cannot opt into generic training weapon bridge")
	runtime.model.add_target(native,spawn.position,10)
	var target: Dictionary = runtime.model.targets[-1]
	_check(target.defense == 17.0 and target.dodge == 9.0 and target.max_shield == 7.0 and target.speed == 11.0 and not target.hostile,"actual native combat target receives preserved source profile fields")
	var local: Dictionary = runtime._monster_profile_for_spawn({"monster_code":2000000})
	_check(local.Defense == 0.0 and local.DefenseProbability == 0.0 and local.DP == 0.0 and local.MoveSpeed == 25.0 and local.hostile and local.HP == 303,"explicit local encounter keeps its training overrides without replacing current HP")
	current.Defense = null
	current.DefenseProbability = null
	current.erase("DP")
	current.erase("MoveSpeed")
	current.erase("hostile")
	current.Belligerence = 1
	native = runtime._monster_profile_for_spawn(spawn)
	_check(native.Defense == null and native.DefenseProbability == null and not native.has("DP") and not native.has("MoveSpeed") and not native.has("hostile"),"unknown MEX server-only fields remain unknown instead of acquiring training or SQL guesses")
	runtime.model.add_target(native,spawn.position,11)
	target = runtime.model.targets[-1]
	_check(not Runtime.Combat.native_aggression(target) and Runtime.Combat.native_aggression({"belligerence":1,"aggressed":true}) and not Runtime.Combat.native_aggression({"belligerence":4,"aggressed":true}),"native defensive and nonattacking Belligerence policies are not forced hostile by training")
	runtime.free()


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:failures.append(message)
