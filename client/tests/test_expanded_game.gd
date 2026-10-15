extends SceneTree
## Integration of the new local systems against converted original resources.
const Save = preload("res://scripts/local_save.gd")
const PATH := "user://test-expanded-game.json"
var scene: Node
var checks := 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	scene = (load("res://main.tscn") as PackedScene).instantiate()
	root.add_child(scene)
	scene.set_physics_process(false)
	scene.set_process(false)
	scene._save_path = PATH
	await process_frame
	_check(scene._combat_ready, "real scene starts with world and combat ready")
	if not scene._combat_ready:
		await _finish()
		return
	_check(is_instance_valid(scene.systems) and scene.systems.game == scene and scene.systems.services.inventory == scene.combat_runtime.inventory and scene.systems.services.snapshot().configured, "main binds native skills/services to the actual combat inventory")
	_check(is_instance_valid(scene.original_water) and scene.original_water.get_meta("source_patch_count", 0) == scene.world_runtime.current_map.metadata.water.active_patch_count, "native water texture and every selected patch are mounted in the playable world")
	var maps: Array = scene.world_runtime.map_catalog()
	var available := 0
	for row: Dictionary in maps:
		if bool(row.get("available", false)): available += 1
	_check(maps.size() == 238 and available == 217, "main exposes217 original regions:158 terrains and59 native object/sky worlds from238 map records")
	_check(scene.combat_runtime.inventory.catalog.size() == 16079, "all16079 native item definitions reach the game inventory")
	_check(int(scene.combat_runtime.snapshot().actor_catalog_count) >= 1200, "original actors are available to encounter creation")
	scene._on_local_action("refresh_library")
	_check(scene._library_revision >= 0, "library UI refresh uses runtime revision")
	var state: Dictionary = scene.combat_runtime.snapshot()
	_check(state.inventory.entries.size() > 0 and not str(state.inventory.entries[0].icon_path).is_empty(), "owned inventory has real native icon bindings")
	var own_engine := int(state.inventory.equipped.engine)
	scene._on_local_action("equip_item:engine:" + str(own_engine))
	_check(scene.model.engine_item_num == own_engine, "UI equip action applies the actual owned native engine")
	scene._on_local_action("equip_item:engine:7002590")
	_check(scene.model.engine_item_num == own_engine, "incompatible A-GEAR engine does not change I-GEAR physics")
	var gear_source := _compatible_appearance()
	_check(gear_source > 0, "converted appearance library contains current native GEAR class")
	if gear_source > 0:
		var before: Dictionary = scene.combat_runtime.snapshot()
		var position: Vector3 = scene.model.position
		scene._on_local_action("preview_gear:" + str(gear_source))
		_check(int(scene._appearance_overrides.get(scene.model.gear_id, 0)) == gear_source and scene.ship.get_meta("original_resource_path", "").contains("/original_library/gears/"), "appearance action mounts original converted armor geometry")
		_check(scene.model.engine_item_num == own_engine and scene.model.position == position and scene.combat_runtime.snapshot().hp == before.hp and scene.combat_runtime.snapshot().primary_ammo == before.primary_ammo, "cosmetic test preserves engine, pose, HP and ammunition")
	var cast_result: Dictionary = {}
	var skill_before: Dictionary = scene.systems.skills.snapshot(false)
	for slot: Dictionary in skill_before.hotbar:
		if bool(slot.get("usable", false)) and float(slot.get("sp_cost", 0)) > 0.0:
			cast_result = scene.systems.cast_slot(int(slot.slot))
			if bool(cast_result.get("ok", false)):break
	_check(bool(cast_result.get("ok", false)) and scene.systems.skills.sp < float(skill_before.sp) and int(scene.systems.skills.export_state().serial) > 0, "production systems cast a learned native skill, debit SP and record its persisted operation")
	var saved_systems: Dictionary = scene.systems.export_state()
	var combat = scene.combat_runtime.model
	var saved_hp := minf(321.0, float(combat.player.max_hp) - 1.0)
	var saved_shield := maxf(0.0, minf(43.0, float(combat.player.max_shield) - 1.0))
	_check(saved_hp > 0.0 and saved_hp < float(combat.player.max_hp) and saved_shield < float(combat.player.max_shield), "checkpoint fixture spends actual native HP/DP without exceeding recovered character limits")
	combat.player.hp = saved_hp
	combat.player.shield = saved_shield
	combat.player.primary_ammo = 903
	combat.player.secondary_ammo = 34
	scene.model.position += Vector3(0, 40, -25)
	scene.systems.advance(0.0)
	var fuel_capacity := float(scene.model.fuel_capacity)
	scene.model.set_fuel_state(0.65 * fuel_capacity, fuel_capacity)
	# Produce real native pending consumption through the flight integrator.
	scene.model.advance({}, 0.125)
	scene.systems.sync_resources()
	scene.ship.position = scene.model.position
	scene.model.boost_energy = 0.37
	var saved_fuel: Dictionary = scene.model.snapshot().fuel
	_check(fuel_capacity > 0.0 and is_equal_approx(scene.model.fuel_fraction, 0.65) and saved_fuel.distance_pending > 0.0 and saved_fuel.seconds_pending > 0.0, "native fuel fixture configures real capacity and records pending distance/time through production flight integration")
	var saved_position: Vector3 = scene.model.position
	var saved_map: int = scene.current_map_id
	_check(scene._save_local_game(false).ok, "production scene writes atomic local checkpoint")
	var loaded: Dictionary = Save.read_game(PATH)
	_check(loaded.ok and loaded.snapshot.combat.player.hp == saved_hp and loaded.snapshot.combat.player.shield == saved_shield and is_equal_approx(float(loaded.snapshot.combat.player.ep), float(saved_fuel.current)), "checkpoint contains native runtime character state")
	scene._cycle_gear()
	scene._on_local_action("travel_map:2001")
	await process_frame
	_check(scene.current_map_id == 2001 and scene.original_scene_profile.terrain.source_id == "2001", "local exploration action loads actual native city terrain")
	_check(scene.original_audio.current_bgm == int(scene.world_runtime.current_map.source_map_info.Bgm) and scene.original_audio.music.stream != null, "city selects the original MAP_INFO BGM binding")
	_check(scene._load_local_game().ok, "production scene restores checkpoint across map and GEAR change")
	await process_frame
	state = scene.combat_runtime.snapshot()
	_check(scene.current_map_id == saved_map and scene.model.gear_id == "12003100" and state.gear_id == "12003100", "load restores consistent native class in flight, inventory and combat")
	_check(scene.model.position.distance_to(saved_position) < 0.01 and is_equal_approx(scene.model.boost_energy, 0.37) and is_equal_approx(scene.model.fuel_fraction, 0.65), "load restores pose and flight resources")
	_check(state.hp == saved_hp and state.shield == saved_shield and state.primary_ammo == 903 and state.secondary_ammo == 34, "load preserves damage and spent ammunition")
	var restored_fuel: Dictionary = scene.model.snapshot().fuel
	_check(is_equal_approx(float(restored_fuel.distance_pending), float(saved_fuel.distance_pending)) and is_equal_approx(float(restored_fuel.seconds_pending), float(saved_fuel.seconds_pending)) and is_equal_approx(float(state.ep), float(saved_fuel.current)), "load restores native pending fuel consumption and keeps combat EP synchronized")
	_check(scene.systems.export_state() == saved_systems and scene.systems.services.inventory == scene.combat_runtime.inventory, "load restores learned skills, hotbar, active durations, cooldowns, SP and service RNG against the replacement inventory")
	_check(gear_source <= 0 or int(scene._appearance_overrides.get("12003100", 0)) == gear_source, "local appearance persists in the saved class")
	var invalid: Dictionary = scene._capture_local_progress()
	invalid.world.wallet.credits = 1000
	_check(not scene._restore_local_progress(invalid).ok and scene.current_map_id == saved_map and scene.combat_runtime.snapshot().hp == saved_hp, "inconsistent currency ledger is rejected without changing live session")
	invalid = scene._capture_local_progress()
	invalid.combat.player.hp = 999999
	_check(not scene._restore_local_progress(invalid).ok and scene.model.position.distance_to(saved_position) < 0.01 and scene.combat_runtime.snapshot().hp == saved_hp, "invalid nested combat state rolls back world transition and preserves live damage")
	var mute_before: bool = scene.original_audio.muted
	scene._on_local_action("toggle_audio")
	_check(scene.original_audio.muted != mute_before, "UI music action controls native local audio")
	scene._on_local_action("toggle_audio")
	scene._on_local_action("reset_appearance")
	_check(not scene._appearance_overrides.has(scene.model.gear_id), "appearance reset restores baseline model selection")
	scene._process(1.0 / 60.0)
	_check(scene.legacy_hud._world_state.map_id == scene.current_map_id, "expanded systems update original blue HUD together")
	await _finish()


func _compatible_appearance() -> int:
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets/original_library/gears/gears.json"))
	for identifier: String in data.get("by_source_index", {}):
		if not scene._appearance_profile(int(identifier), "12003100").is_empty(): return int(identifier)
	return 0


func _finish() -> void:
	if is_instance_valid(scene):
		scene.queue_free()
		await process_frame
	for suffix: String in ["", ".bak", ".tmp"]:
		DirAccess.remove_absolute(PATH + suffix)
	print(JSON.stringify({"suite": "expanded_game", "checks": checks, "failures": failures.size()}))
	for failure: String in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)


func _check(value: bool, description: String) -> void:
	checks += 1
	if not value: failures.append(description)
