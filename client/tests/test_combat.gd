extends SceneTree

const Combat = preload("res://scripts/combat_model.gd")
const Runtime = preload("res://scripts/combat_runtime.gd")
const World = preload("res://scripts/world_model.gd")
var failures: Array[String] = []


func _initialize() -> void:
	_test_native_rules()
	_test_damage_equations()
	_test_shield_and_death()
	_test_cadence_and_ammo()
	_test_lock_projectile_and_kill()
	_test_determinism_and_invalid_delta()
	_test_collision_rates()
	_test_occlusion()
	_test_overheat()
	_test_real_world_ridge_query()
	_test_native_monster_catalog_and_belligerence()
	if failures.is_empty():
		print("PASS: combat — native ITEM values, damage/hit/defense, DP→HP, cadence/ammo, lock/missiles, death/respawn, deterministic ticks, collision bands")
		quit(0)
	else:
		for message in failures:
			push_error(message)
		quit(1)


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _item(minimum: float = 20.0, maximum: float = 20.0) -> Dictionary:
	return {"ItemNum": -1, "Kind": 0, "AbilityMin": minimum, "AbilityMax": maximum, "HitRate": 100.0,
		"ReAttacktime": 650, "Range": 460.0, "ShotNum": 3, "MultiNum": 1, "AttackTime": 0,
		"RepeatTime": 300, "RangeAngle": 0.2, "FractionResistance": 0.0, "_fixture": "synthetic test only"}


func _profile() -> Dictionary:
	var secondary := _item(30.0, 30.0)
	secondary.Kind = 9
	secondary.ReAttacktime = 1000
	secondary.ShotNum = 1
	secondary.MultiNum = 2
	secondary.AttackTime = 300
	return {"primary": _item(), "secondary": secondary, "primary_ammo": 20, "secondary_ammo": 4,
		"player": {"max_hp": 100.0, "max_shield": 40.0, "level": 9}}


func _model() -> RefCounted:
	var model = Combat.new()
	_check(model.configure(_profile(), 12345), "Synthetic fixture did not configure")
	model.set_player_pose(Vector3.ZERO, Vector3.FORWARD)
	return model


func _test_native_rules() -> void:
	var native: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets/legacy_rules/combat.json"))
	var primary := Combat.weapon_from_item(native.primary, true)
	var secondary := Combat.weapon_from_item(native.secondary, false)
	_check(int(primary.item_num) == 7000040 and int(secondary.item_num) == 7901000, "Native selected ITEM identities changed")
	_check(is_equal_approx(float(primary.interval), 0.650 / 3.0), "Primary native ms/ShotNum cadence conversion is wrong")
	_check(is_equal_approx(float(secondary.interval), 1.8) and int(secondary.multi_num) == 2, "Native secondary volley/cadence is wrong")
	_check(is_equal_approx(float(secondary.projectile_speed), 300.0), "RepeatTime warhead speed is not preserved")
	_check(is_equal_approx(float(native.monster.HP), 303.0), "Native monster HP was not preserved")


func _test_damage_equations() -> void:
	var model = _model()
	var weapon := Combat.weapon_from_item(_item(), true)
	var attacker := {"level": 9}
	var defender := {"level": 9, "defense": 0.0, "dodge": 0.0}
	var outcome: Dictionary = model.resolve_attack(weapon, attacker, defender, 100.0)
	_check(outcome.hit and is_equal_approx(float(outcome.damage), 20.0) and not outcome.critical, "Base damage or disabled critical differs from source")
	defender.defense = 100.0
	outcome = model.resolve_attack(weapon, attacker, defender, 100.0, false, "C2C")
	_check(is_equal_approx(float(outcome.damage), 1.0), "C2C source minimum must be1, not10percent")
	outcome = model.resolve_attack(weapon, attacker, defender, 100.0, true, "M2C")
	_check(is_equal_approx(float(outcome.damage), 2.0), "M2C source minimum must be10percent maximum attack")
	defender.defense = 50.0
	weapon.pierce = 30.0
	outcome = model.resolve_attack(weapon, attacker, defender, 100.0, true, "M2C")
	_check(is_equal_approx(float(outcome.damage), 16.0), "Pierce must subtract from defense percentage before damage")
	defender.dodge = 150.0
	outcome = model.resolve_attack(weapon, attacker, defender, 100.0)
	_check(not outcome.hit and float(outcome.damage) == 0.0, "Negative hit probability must miss")
	_check(is_equal_approx(Combat.effective_range_factor(460.0, 460.0), 1.0), "Range breakpoint1")
	_check(is_equal_approx(Combat.effective_range_factor(690.0, 460.0), 0.3), "Range breakpoint1.5")
	_check(is_equal_approx(Combat.effective_range_factor(920.0, 460.0), 0.3), "Range breakpoint2")
	_check(Combat.effective_range_factor(920.01, 460.0) == 0.0, "Beyond double range must have no primary hit chance")


func _test_shield_and_death() -> void:
	var unit := {"hp": 100.0, "shield": 40.0}
	var result := Combat.apply_damage(unit, 55.0)
	_check(unit.hp == 85.0 and unit.shield == 0.0 and result.hp == 15.0 and result.shield == 40.0, "DP overflow must reach HP exactly")
	Combat.apply_damage(unit, NAN)
	_check(unit.hp == 85.0, "Invalid damage mutated HP")
	var model = _model()
	model.damage_player(140.0, "fixture")
	model.damage_player(140.0, "fixture")
	var deaths := 0
	for event: Dictionary in model.drain_events():
		if event.type == "player_died":
			deaths += 1
	_check(model.player.dead and model.player.hp == 0.0 and deaths == 1, "Exact HP+DP lethal equality/death deduplication failed")
	for step in range(8):
		model.advance(0.5)
	_check(not model.player.dead and model.player.hp == 100.0 and model.player.shield == 40.0, "Local respawn did not restore HP/DP")


func _test_cadence_and_ammo() -> void:
	var model = _model()
	model.advance(0.5, {"primary": true})
	_check(int(model.player.primary_ammo) == 17, "Three native ShotNum shots must fit first650ms cycle, with no frame-dependent surplus")
	var count := 0
	for event: Dictionary in model.drain_events():
		if event.type == "fired":
			count += 1
	_check(count == 3, "Cadence event count differs from consumed ammo")
	model.player.primary_ammo = 0
	model.advance(0.5, {"primary": true})
	_check(model.drain_events().is_empty(), "Empty ammunition fired")


func _test_lock_projectile_and_kill() -> void:
	var model = _model()
	var target_id: int = model.add_target({"HP": 60.0, "DP": 0.0, "Level": 9, "MoveSpeed": 0.0, "hostile": false,
		"radius": 10.0, "MonsterUnitKind": 123}, Vector3(0, 0, -100))
	model.select_target(target_id)
	model.advance(0.2, {"secondary": true})
	_check(model.projectiles.is_empty() and int(model.player.secondary_ammo) == 4, "Missile fired before native preparation timer")
	model.advance(0.2, {"secondary": true})
	_check(model.projectiles.size() == 2 and int(model.player.secondary_ammo) == 2, "Locked secondary should consume one ammo per native MultiNum2 projectile")
	for step in range(3):
		model.advance(0.2)
	var kills: Array[Dictionary] = []
	for event: Dictionary in model.drain_events():
		if event.type == "target_destroyed":
			kills.append(event)
	_check(kills.size() == 1 and model.targets[0].dead and model.targets[0].hp == 0.0, "Real projectile damage did not produce one unique kill")
	if not kills.is_empty():
		_check(int(kills[0].monster_code) == 123 and str(kills[0].instance_id) == "local/0:0", "Kill lost source code or deduplication identity")
	for step in range(24):
		model.advance(0.5)
	_check(not model.targets[0].dead and int(model.targets[0].life) == 1, "Enemy local respawn did not advance unique life identity")
	model.select_target(target_id)
	model.advance(0.1, {"aim_direction": Vector3.BACK})
	_check(model.lock_progress == 0.0, "Lock survived leaving native RangeAngle cone")


func _test_determinism_and_invalid_delta() -> void:
	var states: Array = []
	for rate in [30, 60, 144]:
		var model = _model()
		model.add_target({"HP": 1000.0, "Level": 9, "MoveSpeed": 0.0, "hostile": false, "radius": 15.0}, Vector3(0, 0, -100))
		for frame in range(rate * 2):
			model.advance(1.0 / float(rate), {"primary": true})
		states.append(model.snapshot())
	_check(states[0].primary_ammo == states[1].primary_ammo and states[1].primary_ammo == states[2].primary_ammo, "Ammo depends on render frame rate")
	_check(is_equal_approx(float(states[0].targets[0].hp), float(states[2].targets[0].hp)), "Damage/RNG depends on render frame rate")
	var model = _model()
	for value in [NAN, INF, -1.0, 0.0]:
		model.advance(value, {"primary": true})
	_check(model.elapsed == 0.0 and int(model.player.primary_ammo) == 20, "Invalid delta changed combat")
	model.advance(999.0)
	_check(model.elapsed <= 0.5 + 0.00001, "Delta spike exceeded bounded combat update")


func _test_collision_rates() -> void:
	_check(is_equal_approx(Runtime.collision_damage_rate(149.0), 0.1), "Collision speed band under150")
	_check(is_equal_approx(Runtime.collision_damage_rate(150.0), 0.15), "Collision speed band at150")
	_check(is_equal_approx(Runtime.collision_damage_rate(569.0), 0.45), "Collision speed band under570")
	_check(is_equal_approx(Runtime.collision_damage_rate(570.0), 0.5), "Collision speed band570plus")


func _wall(start: Vector3, finish: Vector3, _radius: float) -> Dictionary:
	if start.z >= -50.0 and finish.z <= -50.0 and not is_equal_approx(start.z, finish.z):
		var parameter := (-50.0 - start.z) / (finish.z - start.z)
		return {"collided": true, "position": start.lerp(finish, parameter), "t": parameter, "kind": "fixture_wall"}
	return {"collided": false}


func _test_occlusion() -> void:
	var model = _model()
	model.add_target({"HP": 200.0, "Level": 9, "hostile": false, "radius": 10.0}, Vector3(0, 0, -100))
	model.obstacle_query = Callable(self, "_wall")
	model.advance(0.5, {"primary": true, "secondary": true})
	_check(model.targets[0].hp == 200.0 and model.projectiles.is_empty() and model.lock_progress == 0.0, "Enemy behind a surface received hitscan damage or lock")
	model = _model()
	model.add_target({"HP": 200.0, "Level": 9, "hostile": false, "radius": 10.0}, Vector3(0, 0, -100))
	model.advance(0.31, {"secondary": true})
	_check(model.projectiles.size() == 2, "Occlusion projectile fixture did not launch")
	model.obstacle_query = Callable(self, "_wall")
	model.advance(0.4)
	_check(model.targets[0].hp == 200.0 and model.projectiles.is_empty(), "Guided missiles traversed a wall")
	model = _model()
	model.add_target({"HP": 200.0, "Level": 9, "MoveSpeed": 0.0, "hostile": true, "radius": 10.0, "weapon": _item()}, Vector3(0, 0, -100))
	model.targets[0].attack_cooldown = 0.0
	model.obstacle_query = func(start: Vector3, finish: Vector3, radius: float) -> Dictionary: return _wall(finish, start, radius)
	model.advance(0.5)
	_check(model.player.shield == 40.0 and model.player.hp == 100.0, "Enemy fired through world occlusion")


func _test_overheat() -> void:
	var profile := _profile()
	profile.primary.Time = 200
	var model = Combat.new()
	model.configure(profile, 1)
	model.advance(0.25, {"primary": true})
	_check(model.player.primary_overheated, "Native Time milliseconds did not trigger overheat")
	var remaining: float = model.player.primary_heat_remaining
	model.advance(0.5)
	_check(float(model.player.primary_heat_remaining) > remaining and model.player.primary_overheated, "Overheat should recover over10seconds, not instantly")
	for step in range(20):
		model.advance(0.5)
	_check(not model.player.primary_overheated and is_equal_approx(float(model.player.primary_heat_remaining), 0.2), "Native10second overheat recovery failed")


func _test_real_world_ridge_query() -> void:
	var world = World.new()
	var bytes := PackedByteArray()
	bytes.resize(9 * 4)
	var heights := [0.0, 0.0, 0.0, 40.0, 40.0, 40.0, 0.0, 0.0, 0.0]
	for index in range(heights.size()):
		bytes.encode_float(index * 4, heights[index])
	var errors: PackedStringArray = world.configure({"map_id": -1, "vertex_side": 3, "tile_size": 40.0}, bytes)
	_check(errors.is_empty(), "Synthetic ridge did not configure through production WorldModel")
	var model = _model()
	model.set_player_pose(Vector3(-35, 20, 0), Vector3.RIGHT)
	model.add_target({"HP": 200.0, "Level": 9, "hostile": false, "radius": 2.0}, Vector3(35, 20, 0))
	model.obstacle_query = Callable(world, "trace_segment")
	model.advance(0.5, {"primary": true})
	_check(model.targets[0].hp == 200.0, "Production terrain query allowed damage through a hill with both endpoints above ground")


func _test_native_monster_catalog_and_belligerence() -> void:
	var catalog: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets/legacy_rules/monsters.json"))
	var strongest: Dictionary = {}
	for record: Dictionary in catalog.records:
		if float(record.get("HP", 0)) > float(strongest.get("HP", 0)):
			strongest = record
	var profile: Dictionary = strongest.duplicate(true)
	profile.Defense = 0.0
	profile.DefenseProbability = 0.0
	profile.MoveSpeed = 0.0
	var model = _model()
	model.add_target(profile, Vector3(0, 0, -100))
	_check(int(model.targets[0].monster_code) == 2131100 and float(model.targets[0].max_hp) == 65626208.0, "Original strategic boss HP replaced with generated stats")
	_check(not Combat.native_aggression({"belligerence": 4}), "BELL_NOTATTACK native flag ignored")
	_check(not Combat.native_aggression({"belligerence": 1, "aggressed": false}) and Combat.native_aggression({"belligerence": 1, "aggressed": true}), "BELL_DEFENSE native retaliation condition ignored")
	_check(Combat.native_aggression({"belligerence": 0}), "BELL_ATATTACK native aggression ignored")
	_check(not Combat.native_aggression({"belligerence": 10}, 2) and Combat.native_aggression({"belligerence": 11}, 2), "Native VCN/ANI faction parity ignored")
	_check(not Combat.native_aggression({"belligerence": 11}, 4) and Combat.native_aggression({"belligerence": 10}, 4), "Native ANI/VCN faction parity ignored")
