extends SceneTree

const Combat = preload("res://scripts/combat_model.gd")
const Runtime = preload("res://scripts/combat_runtime.gd")
const World = preload("res://scripts/world_model.gd")
var failures: Array[String] = []


func _initialize() -> void:
	_test_native_rules()
	_test_damage_equations()
	_test_shield_and_death()
	_test_native_defensive_skills()
	_test_npc_native_weapon_execution()
	_test_npc_projectile_pilot_isolation()
	_test_cadence_and_ammo()
	_test_lock_projectile_and_kill()
	_test_determinism_and_invalid_delta()
	_test_collision_rates()
	_test_occlusion()
	_test_overheat()
	_test_real_world_ridge_query()
	_test_native_monster_catalog_and_belligerence()
	if failures.is_empty():
		print("PASS: combat — native ITEM damage/DP/protections; verified NPC weights/preparation/bursts/travel/occlusion; multiplayer missile target/life isolation; cadence/ammo, death/respawn and deterministic ticks")
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


func _test_native_defensive_skills() -> void:
	# DES121 applies at DP→HP, after defense and before ordinary shield damage.
	var model = _model()
	model.set_skill_modifiers({"shield_damage_reduction": 0.5})
	model.damage_player(60.0, "npc")
	_check(model.player.shield == 10.0 and model.player.hp == 100.0, "Native shield reduction must absorb30DP from60 incoming damage")
	model = _model()
	model.set_skill_modifiers({"shield_damage_reduction": 0.5})
	model.damage_player(100.0, "npc")
	_check(model.player.shield == 0.0 and model.player.hp == 60.0, "Native DP-break remainder must be100-40*(1+0.5), preserving recovered formula")
	model = _model()
	model.set_skill_modifiers({"shield_damage_reduction": 0.5})
	model.damage_player(80.0, "npc")
	_check(model.player.shield == 0.0 and model.player.hp == 100.0, "Exact reduced DP equality must not leak HP damage")
	model.player.shield = 0.0
	model.damage_player(20.0, "npc")
	_check(model.player.hp == 80.0, "Shield reduction must not protect exposed HP")
	model = _model()
	model.set_skill_modifiers({"shield_damage_reduction": 1.0})
	model.damage_player(1000.0, "npc")
	_check(model.player.shield == 40.0 and model.player.hp == 100.0, "100percent shield reduction damaged protected DP")
	# DES140 scales collisions first, and must never reduce incoming weapon fire.
	for cause: String in ["collision", "terrain", "object", "boundary", "water", "native_navigation_floor"]:
		model = _model()
		model.set_skill_modifiers({"collision_damage_reduction": 0.5, "shield_damage_reduction": 0.5})
		model.damage_player(60.0, cause)
		_check(model.player.shield == 25.0 and model.player.hp == 100.0, "Collision then shield modifier order failed for " + cause)
	model = _model()
	model.set_skill_modifiers({"collision_damage_reduction": 0.5})
	model.damage_player(60.0, "npc")
	_check(model.player.shield == 0.0 and model.player.hp == 80.0, "Collision reduction incorrectly reduced NPC weapon damage")
	# Protection must precede minimum damage and consume no hit/defense RNG.
	model = _model()
	var before_rng: int = model._rng_state
	model.set_skill_modifiers({"invincible": 1.0})
	for weapon: Dictionary in [model.weapons.primary, model.weapons.secondary]:
		var outcome: Dictionary = model.resolve_attack(weapon, {"level": 9}, model.player, 100.0, true, "M2C")
		_check(float(outcome.damage) == 0.0 and str(outcome.get("blocked", "")) == "invincible", "Invincibility allowed native minimum damage")
	model.damage_player(10000.0, "boundary")
	_check(model._rng_state == before_rng and model.player.shield == 40.0 and model.player.hp == 100.0 and model.drain_events().is_empty(), "Invincibility consumed RNG or applied collision damage/events")
	var outgoing: Dictionary = model.resolve_attack(model.weapons.primary, model.player, {"level": 9}, 100.0)
	_check(float(outgoing.damage) == 20.0, "Defender invincibility incorrectly changed outgoing weapon damage")
	model.set_skill_modifiers({"missile_barrier": 1.0})
	var secondary_hit: Dictionary = model.resolve_attack(model.weapons.secondary, {"level": 9}, model.player, 100.0, true, "M2C")
	var primary_hit: Dictionary = model.resolve_attack(model.weapons.primary, {"level": 9}, model.player, 100.0, true, "M2C")
	_check(float(secondary_hit.damage) == 0.0 and str(secondary_hit.get("blocked", "")) == "missile_barrier", "Barrier did not zero secondary damage")
	_check(float(primary_hit.damage) == 20.0, "Barrier must not stop primary weapon damage")
	# Exercise the real NPC attack path and effect removal, not just the formula.
	var monster_weapon := _item()
	monster_weapon.Kind = 152 # native ITEMKIND_FOR_MON_MISSILE
	monster_weapon.ShotNum = 1
	model.add_target({"HP": 200.0, "Level": 9, "MoveSpeed": 0.0, "hostile": true, "weapon": monster_weapon}, Vector3(0, 0, -100))
	model.targets[0].attack_cooldown = 0.0
	model.advance(0.35)
	_check(model.player.shield == 40.0 and model.player.hp == 100.0, "Active missile barrier was not consumed by actual NPC attack")
	model.set_skill_modifiers({})
	model.advance(0.5)
	model.advance(0.2)
	_check(model.player.shield == 20.0 and model.player.hp == 100.0, "Expired missile barrier kept preventing actual NPC attacks")
	model.set_skill_modifiers({"invincible": NAN, "collision_damage_reduction": INF, "shield_damage_reduction": NAN})
	_check(model.skill_modifiers.is_empty(), "Nonfinite defensive skill modifiers were retained")
	# Shared encounters must not borrow the last active pilot's protections.
	model = _model()
	_check(model.register_pilot("protected", _profile()), "Protected shared pilot did not register")
	model.set_skill_modifiers({"invincible": 1.0})
	_check(model.register_pilot("vulnerable", _profile()), "Vulnerable shared pilot did not register")
	model.damage_player(60.0, "npc")
	_check(model.player.hp == 80.0 and model.player.shield == 0.0, "Another pilot inherited shared invincibility")
	model.activate_pilot("protected")
	model.damage_player(10000.0, "npc")
	_check(model.player.hp == 100.0 and model.player.shield == 40.0, "Pilot switch discarded active protection")
	model.activate_pilot("vulnerable")
	_check(model.player.hp == 80.0 and model.player.shield == 0.0, "Pilot switch reset damage on another participant")


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


func _advance_time(model: RefCounted, seconds: float, pilots: Dictionary = {}) -> void:
	var remaining := seconds
	while remaining > 0.000001:
		var delta := minf(0.5, remaining)
		if pilots.is_empty():
			model.advance(delta)
		else:
			model.advance_shared(delta, pilots)
		remaining -= delta


func _test_npc_native_weapon_execution() -> void:
	var inventory := preload("res://scripts/inventory_model.gd").new()
	inventory.configure()
	var catalog: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets/legacy_rules/monsters.json"))
	var monsters: Dictionary = {}
	for row: Dictionary in catalog.records:
		monsters[int(row.MonsterUnitKind)] = row
	var data := preload("res://scripts/native_server_data.gd").new()
	_check(bool(data.load_catalogs(inventory.catalog, monsters).get("ok", false)), "Verified native NPC catalogs did not load")
	var hornian: Dictionary = data.npc_attack_profile(2000000)
	_check(bool(hornian.get("ok", false)) and hornian.options.size() == 1, "Native Hornian ordinary weapon profile unavailable")
	if not bool(hornian.get("ok", false)) or hornian.options.is_empty():
		return
	var model = _model()
	model.player.hp = 10000.0
	model.player.max_hp = 10000.0
	model.player.shield = 10000.0
	model.player.max_shield = 10000.0
	var npc: Dictionary = monsters[2000000].duplicate(true)
	npc.npc_weapon_options = hornian.options
	npc.MoveSpeed = 0.0
	npc.hostile = true
	npc.Belligerence = 0
	model.add_target(npc, Vector3(0, 0, -500))
	model.targets[0].attack_cooldown = 0.0
	_check(model.targets[0].max_hp == monsters[2000000].HP, "Native weapon attachment replaced current client HP with old server HP")
	model.advance(0.35)
	_check(model.projectiles.is_empty(), "Hornian fired before native350ms AttackTime")
	model.advance(0.15)
	_check(model.projectiles.size() == 2 and model.player.shield == 10000.0, "Hornian rocket salvo must travel before any M2C damage")
	model.advance(0.15)
	var fired: Array[Dictionary] = []
	var hits: Array[Dictionary] = []
	for event: Dictionary in model.drain_events():
		if event.type == "enemy_fired":
			fired.append(event)
		elif event.type == "player_hit":
			hits.append(event)
	_check(fired.size() == 3, "Native Hornian ShotNum3 did not produce exactly3 salvos")
	if fired.size() == 3:
		_check(int(fired[0].item_num) == 7500020 and fired[0].slot == "secondary" and is_equal_approx(float(fired[1].time) - float(fired[0].time), Combat.NPC_BURST_INTERVAL) and is_equal_approx(float(fired[2].time) - float(fired[1].time), Combat.NPC_BURST_INTERVAL), "NPC burst cadence must use native100ms minimum, not ReAttacktime/ShotNum")
	_check(not hits.is_empty(), "Real native Hornian projectile never produced an M2C hit")
	for hit: Dictionary in hits:
		_check(float(hit.damage) >= 28.88 and float(hit.damage) <= 35.30, "Native Hornian damage changed original ITEM AbilityMin/Max")
	_advance_time(model, 3.0)
	var early_cycle := false
	for event: Dictionary in model.drain_events():
		if event.type == "enemy_fired":
			early_cycle = true
	_check(not early_cycle, "NPC ignored full3670ms item recast after first burst salvo")
	_advance_time(model, 1.0)
	var second_cycle: Array[Dictionary] = []
	for event: Dictionary in model.drain_events():
		if event.type == "enemy_fired":
			second_cycle.append(event)
	_check(second_cycle.size() == 3, "Native Hornian second recast+preparation did not execute ShotNum3 again")
	if not second_cycle.is_empty() and not fired.is_empty():
		_check(float(second_cycle[0].time) - float(fired[0].time) >= 3.67 + 0.35 - Combat.STEP, "Native NPC recast and preparation were collapsed into player shot cadence")
	# Verified Bombing Exerciser ordinary slots preserve70/30, no renormalization.
	var bomber: Dictionary = data.npc_attack_profile(2028100)
	_check(bool(bomber.get("ok", false)) and bomber.options.size() == 2, "Verified Bombing Exerciser weapon profile unavailable")
	model = _model()
	model.add_target({"HP": 100, "npc_weapon_options": bomber.options}, Vector3(0, 0, -100))
	var selected := [0, 0]
	for draw in range(1000):
		selected[model._select_npc_option(model.targets[0])] += 1
	_check(selected[0] >= 650 and selected[0] <= 750 and selected[1] == 1000 - selected[0], "Charging70/30 was replaced with uniform/first-weapon selection")
	model.targets[0].npc_option_ready_at = {"0": model.elapsed + 10.0, "1": model.elapsed + 20.0}
	_check(model._select_npc_option(model.targets[0]) == 1, "Native fallback must preserve source longest-remaining cooldown comparator")
	model.targets[0].npc_option_ready_at = {}
	# Secondary MultiNum creates separate traveling rounds, never multiplied instant damage.
	model.targets[0].npc_selected_option = 1
	model.targets[0].weapon = model.targets[0].npc_weapon_options[1].weapon
	model.targets[0].attack_cooldown = 0.0
	model.advance(Combat.STEP)
	_check(model.projectiles.size() == 2 and model.player.shield == 40.0, "Native MultiNum2 secondary did not create2 traveling rounds")
	model.obstacle_query = func(start: Vector3, finish: Vector3, radius: float) -> Dictionary: return _wall(finish, start, radius)
	model.advance(0.3)
	_check(model.projectiles.is_empty() and model.player.shield == 40.0 and model.player.hp == 100.0, "Incoming NPC rockets traversed world obstruction after launch")
	# Explicit unavailable native profiles may not regain the legacy fallback.
	model = _model()
	model.add_target({"HP": 100, "weapon": _item(), "npc_weapon_options": []}, Vector3(0, 0, -100))
	model.targets[0].attack_cooldown = 0.0
	model.advance(0.5)
	_check(model.targets[0].weapon.is_empty() and model.projectiles.is_empty() and model.player.shield == 40.0, "Unavailable native ordinary weapons silently became a generic player weapon")
	# The ordinary primary path still resolves every native ShotNum/MultiNum.
	var gun := _item(5.0, 5.0)
	gun.Kind = 101
	gun.MultiNum = 2
	model = _model()
	model.add_target({"HP": 100, "MoveSpeed": 0, "weapon": gun}, Vector3(0, 0, -100))
	model.targets[0].attack_cooldown = 0.0
	model.advance(0.25)
	_check(model.player.shield == 10.0 and model.player.hp == 100.0 and model.projectiles.is_empty(), "Native NPC primary ShotNum3/MultiNum2 did not resolve6 M2C attacks")
	# DAT supplies verified per-instance death timers; fallback remains explicit.
	model.targets[0].respawn_seconds = 0.5
	model._attack_target(model.targets[0], Combat.weapon_from_item(_item(100.0, 100.0), true), 100.0)
	_check(model.targets[0].dead and is_equal_approx(float(model.targets[0].respawn_remaining), 0.5), "Per-instance native respawn timer did not begin on death")
	model.advance(0.5)
	_check(not model.targets[0].dead and int(model.targets[0].life) == 1, "Native respawn seconds did not restore a new NPC life")


func _test_npc_projectile_pilot_isolation() -> void:
	var missile := _item()
	missile.Kind = 152
	missile.ShotNum = 1
	missile.ReAttacktime = 10000
	missile.RepeatTime = 100.0
	missile.Range = 2000.0
	var model = _model()
	model.register_pilot("victim", _profile())
	model.set_player_pose(Vector3.ZERO, Vector3.FORWARD)
	model.register_pilot("bystander", _profile())
	model.set_player_pose(Vector3(0, 0, 1000), Vector3.FORWARD)
	model.add_target({"HP": 100, "Level": 9, "MoveSpeed": 0, "weapon": missile}, Vector3(0, 0, -100))
	model.targets[0].attack_cooldown = 0.0
	var controls := {"victim": {}, "bystander": {}}
	model.advance_shared(Combat.STEP, controls)
	_check(model.projectiles.size() == 1 and model.projectiles[0].pilot_id == "victim", "NPC projectile lost its intended multiplayer victim")
	var pending_round: Dictionary = model.projectiles[0].duplicate(true)
	model.advance_shared(0.5, {"bystander": {}})
	_check(model.projectiles.size() == 1 and model.projectiles[0] == pending_round, "Disconnected victim's private incoming round lost its target, TTL or travel before reconnect")
	# Change the active/nearest pilot after launch: the existing round retains target identity.
	model.activate_pilot("bystander")
	model.set_player_pose(Vector3.ZERO, Vector3.FORWARD)
	model.activate_pilot("victim")
	model.set_player_pose(Vector3(0, 0, 10), Vector3.FORWARD)
	_advance_time(model, 1.2, controls)
	_check(model.pilot_states.victim.player.shield == 20.0 and model.pilot_states.bystander.player.shield == 40.0, "Incoming projectile damaged the last active/nearest pilot rather than its original victim")
	# Old incoming rounds cannot damage a later respawn with the same pilot ID.
	model.activate_pilot("victim")
	model.set_player_pose(Vector3.ZERO, Vector3.FORWARD)
	model._fire_npc_salvo(model.targets[0], model.targets[0].weapon)
	model.damage_player(1000.0, "fixture")
	model._respawn_player()
	var next_life: int = model.player.life
	_advance_time(model, 1.5, controls)
	_check(next_life == 1 and model.pilot_states.victim.player.shield == 40.0 and model.pilot_states.victim.player.hp == 100.0 and model.projectiles.is_empty(), "An old NPC missile hit a new player life after respawn")


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
