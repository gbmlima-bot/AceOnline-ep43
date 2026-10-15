extends SceneTree

const Runtime = preload("res://scripts/combat_runtime.gd")
var failures: Array[String] = []

class LocalWorld:
	extends Node
	var map_index := 3002
	var objectives: Array = []
	var missions: Variant = null
	func active_objectives() -> Array:
		return objectives
	func get_state() -> Dictionary:
		var state := {"map_index": map_index}
		if missions is Array:
			state["active_missions"] = missions
		return state
	func sample_ground_height(_x: float, _z: float, _water: bool = true) -> float:
		return -1000.0
	func trace_segment(_start: Vector3, finish: Vector3, _radius: float = 0.0) -> Dictionary:
		return {"collided": false, "position": finish, "t": 1.0}
	func resolve_motion(_start: Vector3, finish: Vector3, _radius: float = 4.0) -> Dictionary:
		return {"collided": false, "position": finish}


func _initialize() -> void:
	call_deferred("_run")


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _run() -> void:
	var holder := Node3D.new()
	root.add_child(holder)
	var world := LocalWorld.new()
	holder.add_child(world)
	var player := Node3D.new()
	holder.add_child(player)
	player.position = Vector3(0, 100, 0)
	var runtime := Runtime.new()
	holder.add_child(runtime)
	_check(runtime.setup(world, player), "Native monster runtime did not set up")
	var state := runtime.snapshot()
	_check(state.available and state.targets.size() == 3, "Map3002 local native-monster encounter missing")
	for target: Dictionary in state.targets:
		_check(int(target.monster_code) == 2000000 and float(target.max_hp) == 303.0, "Runtime changed native Hornian identity/HP")
	var initial_vitals: Dictionary = runtime.snapshot()
	var collision_damage := (float(initial_vitals.max_hp) + float(initial_vitals.max_shield)) * 0.1
	var expected_shield := maxf(0.0, float(initial_vitals.shield) - collision_damage)
	var expected_hp := maxf(0.0, float(initial_vitals.hp) - maxf(0.0, collision_damage - float(initial_vitals.shield)))
	runtime.receive_collision({"collided": true, "impact_speed": 100.0, "kind": "fixture"})
	_check(is_equal_approx(float(runtime.snapshot().shield), expected_shield) and is_equal_approx(float(runtime.snapshot().hp), expected_hp), "Runtime collision did not apply native10percent maxHP+maxDP through shield before HP")
	runtime.receive_collision({"collided": true, "impact_speed": 100.0, "kind": "fixture"})
	_check(is_equal_approx(float(runtime.snapshot().shield), expected_shield) and is_equal_approx(float(runtime.snapshot().hp), expected_hp), "Local sustained-contact debounce failed")
	var reward := {"reward_id": "test:mission:1", "credits": 50, "experience": 20}
	_check(runtime.apply_reward(reward) and not runtime.apply_reward(reward), "Runtime reward ledger was not idempotent")
	world.map_index = 3302
	runtime.respawn_at(Vector3(100, 120, 300), 3302)
	state = runtime.snapshot()
	var codes: Dictionary = {}
	for target: Dictionary in state.targets:
		codes[int(target.monster_code)] = int(codes.get(int(target.monster_code), 0)) + 1
	_check(state.targets.size() == 4 and int(codes.get(2028200, 0)) == 1 and int(codes.get(2028100, 0)) == 3, "Native quest102 identity/count encounter not selected for3302")
	_check(int(state.get("credits", 0)) == 50 and int(state.get("experience", 0)) == 20, "Encounter reset lost session rewards")
	var target: Dictionary = state.targets[0]
	var direction: Vector3 = (target.position - player.global_position).normalized()
	runtime.advance(1.0 / 60.0, {"primary": true, "secondary": true, "aim_direction": direction}, {"position": player.global_position, "forward": direction})
	_check(int(runtime.snapshot().primary_ammo) == 999, "Runtime did not fire selected native primary")
	_check(not runtime._traces.is_empty() and bool(runtime._traces[0].get("original", false)), "Primary uses a substitute while its native effect is available")
	_check(not runtime._projectile_nodes.is_empty(), "Native secondary projectile visual did not instantiate")
	var node: Node3D = runtime._projectile_nodes.values()[0]
	_check(str(node.get_meta("original_resource_path")).ends_with("/06502160.glb"), "Secondary visual is not descriptor-linked native body")
	_check(node.get_child_count() >= 2, "Native secondary glow was not attached")
	var before: Dictionary = runtime.snapshot()
	runtime.configure_gear("12002100")
	state = runtime.snapshot()
	_check(int(state.weapons.primary.item_num) == 7000050 and int(state.weapons.secondary.item_num) == 7900440, "F2 A-Gear retained incompatible B/M/I equipment")
	_check((int(state.weapons.primary.req_unit_kind) & 256) != 0 and (int(state.weapons.secondary.req_unit_kind) & 256) != 0, "A-Gear loadout fails native ReqUnitKind")
	_check(int(state.weapons.primary.equip_position) == 2 and int(state.weapons.secondary.equip_position) == 4, "Native primary/secondary equipment positions changed")
	_check(float(state.hp) == float(before.hp) and float(state.shield) == float(before.shield) and int(state.experience) == int(before.experience), "F2 reset vitals or XP")
	_check(int(state.primary_ammo) == int(before.primary_ammo) and int(state.secondary_ammo) == int(before.secondary_ammo), "F2 refilled ammunition")
	_check(is_equal_approx(float(state.weapons.primary.interval), 0.45) and is_equal_approx(float(state.weapons.secondary.interval), 2.0 / 6.0), "A-Gear native ShotNum/cadence conversion changed")
	_check(str(state.weapon_visual_scope) == "shared_BMI_effects_local_adaptation", "A-Gear borrowed visuals are not identified as an adaptation")
	# A fresh reset represents different local creatures; world kill deduplication
	# must not suppress kills after R or returning to this map.
	var first_kill := _kill_first(runtime)
	runtime.respawn_at(Vector3(100, 120, 300), 3302)
	var second_kill := _kill_first(runtime)
	_check(not first_kill.is_empty() and not second_kill.is_empty() and first_kill != second_kill, "Reset reused a previous target life identity")
	_check(int(runtime.snapshot().weapons.primary.item_num) == 7000050, "Encounter reset lost selected A-Gear loadout")
	runtime.configure_gear("12003100")
	_check(int(runtime.snapshot().weapons.primary.item_num) == 7000040, "F2 back to I-Gear retained A-only equipment")
	_test_class_equipment_transition(runtime)
	_test_map_transfer(runtime, world)
	_test_inventory_and_save(runtime, world)
	_test_native_mission_encounter(runtime, world)
	_test_native_level_reward(runtime)
	_test_mission_refresh_preserves_live_combat(runtime, world)
	holder.queue_free()
	await process_frame
	if failures.is_empty():
		print("PASS: combat runtime — original enemy/projectile/effect assets,3002/3302 encounters, collision DP, rewards, F2 compatible equipment, reset kill identities")
		quit(0)
	else:
		for message in failures:
			push_error(message)
		quit(1)


func _kill_first(runtime: Variant) -> String:
	var target: Dictionary = runtime.model.targets[0]
	target.hp = 0.01
	target.dodge = -100.0
	runtime.model._attack_target(target, runtime.model.weapons.primary, 100.0)
	for event: Dictionary in runtime.model.drain_events():
		if event.type == "target_destroyed":
			return str(event.instance_id)
	return ""


func _test_map_transfer(runtime: Variant, world: Variant) -> void:
	runtime.model.damage_player(475.0, "transfer_fixture")
	runtime.model.player.primary_ammo = 17
	runtime.model.player.secondary_ammo = 3
	runtime.model.player.primary_cooldown = 0.2
	runtime.model.player.secondary_cooldown = 0.9
	runtime.model.player.primary_heat_remaining = 2.5
	runtime.model.player.primary_overheated = true
	var before: Dictionary = runtime.snapshot()
	for map_index in [3002, 3003, 3302]:
		world.map_index = map_index
		var destination := Vector3(float(map_index), 120, -30)
		runtime.transfer_to_map(destination, map_index)
		var after: Dictionary = runtime.snapshot()
		for key in ["hp", "shield", "primary_ammo", "secondary_ammo", "primary_cooldown", "secondary_cooldown", "primary_heat_remaining", "primary_overheated", "credits", "experience", "dead", "respawn_remaining"]:
			_check(after[key] == before[key], "Map transfer changed player field " + key)
		_check(after.position == destination, "Map transfer kept the previous player pose")
		_check(after.targets.size() == (4 if map_index == 3302 else 3), "Map transfer did not rebuild destination encounter")
	# A portal must not bypass death or restart its countdown.
	runtime.model.damage_player(10000.0, "transfer_death_fixture")
	runtime.model.player.respawn_remaining = 1.25
	world.map_index = 3003
	runtime.transfer_to_map(Vector3(300, 200, 100), 3003)
	var dead: Dictionary = runtime.snapshot()
	_check(dead.dead and float(dead.hp) == 0.0 and is_equal_approx(float(dead.respawn_remaining), 1.25), "Map transfer resurrected a dead player or restarted respawn")
	_check(int(dead.primary_ammo) == 17 and float(dead.primary_heat_remaining) == 2.5 and dead.primary_overheated, "Dead map transfer refilled supplies or heat")


func _test_inventory_and_save(runtime: Variant, world: Variant) -> void:
	_check(runtime.inventory.catalog.size() >= 1913, "Native weapons/engine item catalog missing")
	_check(runtime.snapshot().inventory.entries.size() >= 8, "Explicit local starter inventory not seeded")
	runtime.model.player.dead = false
	runtime.model.player.hp = 321.0
	runtime.model.player.shield = 19.0
	runtime.model.player.respawn_remaining = 0.0
	runtime.model.player.primary_ammo = 13
	runtime.model.player.secondary_ammo = 2
	var primary_id: int = runtime.inventory.equipped.primary
	_check(bool(runtime.equip_item(primary_id, "primary").ok), "Owned native weapon cannot be equipped")
	_check(not bool(runtime.equip_item(primary_id, "engine").ok), "Weapon equipped in native rear/engine position")
	var reward := {"reward_id": "inventory:reward:1", "credits": 320, "experience": 91, "items": [{"item_num": primary_id, "count": 2}]}
	var previous_count: int = runtime.inventory.quantities[primary_id]
	_check(runtime.apply_reward(reward) and not runtime.apply_reward(reward), "Native item reward did not remain idempotent")
	_check(runtime.inventory.quantities[primary_id] == previous_count + 2, "Native item reward quantity lost")
	var exported: Dictionary = runtime.export_state()
	var encoded: Variant = JSON.parse_string(JSON.stringify(exported))
	_check(encoded is Dictionary, "Combat state cannot round-trip through JSON")
	world.map_index = 3002
	runtime.transfer_to_map(Vector3(100, 150, 300), 3002)
	var imported: Dictionary = runtime.import_state(encoded)
	_check(bool(imported.ok), "Valid local combat save rejected: " + str(imported))
	_check(runtime.snapshot().hp == 321.0 and runtime.snapshot().shield == 19.0 and runtime.snapshot().primary_ammo == 13, "Load lost DP/HP/ammo")
	_check(not runtime.apply_reward(reward), "Load allowed replaying a claimed mission item reward")
	var before: Dictionary = runtime.export_state()
	for path: String in ["hp", "primary_ammo", "inventory"]:
		var corrupt: Dictionary = before.duplicate(true)
		if path == "hp":
			corrupt.player.hp = corrupt.player.max_hp + 1.0
		elif path == "primary_ammo":
			corrupt.player.primary_ammo = 2.5
		else:
			corrupt.inventory.items.append({"item_num": 123, "count": 1})
		_check(not bool(runtime.import_state(corrupt).ok), "Corrupt save accepted: " + path)
		_check(runtime.export_state() == before, "Rejected save mutated running state: " + path)
	var first_kill := _kill_first(runtime)
	_check(bool(runtime.import_state(before).ok), "Second valid import rejected")
	var second_kill := _kill_first(runtime)
	_check(not first_kill.is_empty() and first_kill != second_kill, "Reload reused an old kill identity")


func _test_native_mission_encounter(runtime: Variant, world: Variant) -> void:
	if not world.has_method("active_objectives"):
		return
	var code := 2000000
	var native: Dictionary = runtime._native_monsters[code]
	world.objectives = [{"kind": "kill", "monster_code": code, "required": 1, "map_id": 3003, "mission_id": "fixture"}]
	world.map_index = 3003
	runtime.transfer_to_map(Vector3(100, 150, 300), 3003)
	var found := false
	for target: Dictionary in runtime.model.targets:
		if int(target.monster_code) == code:
			found = true
			_check(float(target.max_hp) == float(native.HP), "Generic mission encounter generated HP instead of MEX HP")
	_check(found, "Native mission target omitted from generic map encounter")


func _test_native_level_reward(runtime: Variant) -> void:
	runtime.model.player.dead = false
	runtime.model.player.hp = 55.0
	runtime.model.player.shield = 17.0
	var next_threshold: int = runtime.inventory._experience_rows[runtime.inventory.level]
	var remaining := int(ceilf(float(next_threshold) - float(runtime.inventory.effective_experience)))
	var before_level: int = runtime.inventory.level
	_check(runtime.apply_reward({"reward_id": "native:runtime:levelup", "experience": remaining}), "Native level-up reward rejected")
	var state: Dictionary = runtime.snapshot()
	_check(state.level == before_level + 1 and state.inventory.level == state.level, "Native level-up did not synchronize combat and inventory")
	_check(state.hp == state.max_hp and state.shield == 17.0, "Native level-up did not heal only HP")
	var exported: Dictionary = JSON.parse_string(JSON.stringify(runtime.export_state()))
	_check(bool(runtime.import_state(exported).ok), "Native level-up state cannot be restored")


func _test_mission_refresh_preserves_live_combat(runtime: Variant, world: Variant) -> void:
	world.map_index = 3302
	world.missions = [{"id": "102", "status": "active", "event_map_id": 3302, "objectives": [
		{"kind": "kill", "target_code": 2028200, "required": 1, "current": 0},
		{"kind": "kill", "target_code": 2028100, "required": 3, "current": 0}]}]
	world.objectives = [{"kind": "kill", "monster_code": 2028200, "map_id": 3302}, {"kind": "kill", "monster_code": 2028100, "map_id": 3302}]
	runtime.transfer_to_map(Vector3(100, 200, 300), 3302)
	for target: Dictionary in runtime.model.targets:
		target.hostile = false
	var signature: String = runtime._objective_signature()
	var epoch: int = runtime._encounter_serial
	var first_kill := _kill_first(runtime)
	runtime.model.targets[1].hp = 20.0
	world.missions[0].objectives[0].current = 1
	world.objectives.remove_at(0)
	_check(runtime._objective_signature() == signature, "Completed objective counter changed the encounter signature")
	runtime.advance(0.5, {})
	_check(runtime._encounter_serial == epoch and runtime.model.targets.size() == 4, "Completing the fighter objective reset the native encounter")
	_check(runtime.model.targets[0].dead and runtime.model.targets[1].hp == 20.0, "Mission progress resurrected a killed fighter or healed an injured bomber")
	_check(not first_kill.is_empty(), "Positive native weapon kill fixture did not execute")
	# A newly accepted mission in this same map may add an actor; it must not
	# reset any existing creature, player target lock or in-flight missile.
	runtime.model.selected_id = 1
	runtime.model.lock_progress = 1.0
	runtime.model.player.secondary_cooldown = 0.0
	runtime.model.player.secondary_ammo = 5
	runtime.model._fire_secondary(Vector3.FORWARD)
	var rounds: Array = runtime.model.projectiles.duplicate(true)
	world.missions.append({"id": "native:new", "status": "active", "event_map_id": 3302, "objectives": [{"kind": "kill", "target_code": 2000000, "required": 1, "current": 0}]})
	runtime.refresh_encounter()
	_check(runtime.model.targets.size() == 5 and runtime.model.targets[0].dead and runtime.model.targets[1].hp == 20.0, "New mission rebuilt living/dead targets instead of adding its native actor")
	_check(runtime.model.projectiles == rounds and runtime.model.selected_id == 1 and runtime.model.lock_progress == 1.0, "New mission discarded guided rounds or current lock")
	_check(runtime._encounter_serial == epoch, "Incremental mission refresh replaced the current encounter epoch")
	world.missions = null
	world.objectives = []


func _test_class_equipment_transition(runtime: Variant) -> void:
	var starting_resources: Dictionary = runtime.model.player.duplicate(true)
	for gear: String in ["12000100", "12001100", "12002100", "12003100"]:
		var changed: Dictionary = runtime.configure_gear(gear)
		_check(bool(changed.get("ok", false)), "Valid class equipment transaction failed:" + gear)
		for slot: String in runtime.inventory.equipped:
			_check(bool(runtime.inventory.can_equip(int(runtime.inventory.equipped[slot]), slot).ok), "Class change retained incompatible native equipment:" + gear + ":" + slot)
		_check(int(runtime.inventory.equipped.get("armor", 0)) == int(runtime.STARTER_ARMOR[gear]), "Class change failed to select the owned native starter armor:" + gear)
		_check(int(runtime.inventory.equipped.get("radar", 0)) == int(runtime.STARTER_RADAR[gear]), "Class change failed to select the native class radar:" + gear)
		_check(runtime.model.player.primary_ammo == starting_resources.primary_ammo and runtime.model.player.secondary_ammo == starting_resources.secondary_ammo, "Class equipment transaction refilled ammunition")
	var before: Dictionary = runtime.export_state()
	# Missing an essential class-specific weapon must roll back the whole switch.
	var previous_quantities: Dictionary = runtime.inventory.quantities.duplicate()
	runtime.inventory.quantities.erase(7000050)
	var invalid_before: Dictionary = runtime.export_state()
	_check(not bool(runtime.configure_gear("12002100").get("ok", false)), "Missing essential destination weapon did not fail class transaction")
	_check(runtime.export_state() == invalid_before, "Failed class switch partially changed inventory/player/legacy exceptions")
	runtime.inventory.quantities = previous_quantities
	_check(runtime.export_state() == before, "Class rollback fixture changed persisted state")
