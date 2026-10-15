class_name CombatModel
extends RefCounted
## Fixed-tick local combat. Native ITEM values remain in original units / ms / percent.
## See docs/combate-original.txt for the ported formulas and explicit local adaptations.

const STEP := 1.0 / 120.0
const MAX_DELTA := 0.5
const PLAYER_RADIUS := 8.0
const NPC_BURST_INTERVAL := 0.1 # CommonGameServer/Monster.h: MONSTER_MIN_ATTACK_TERM_TICK100ms.

var player: Dictionary = {}
var targets: Array[Dictionary] = []
var projectiles: Array[Dictionary] = []
var weapons: Dictionary = {}
var selected_id := -1
var lock_progress := 0.0
var elapsed := 0.0
var _accumulator := 0.0
var _rng_state := 1
var _next_projectile_id := 0
var _events: Array[Dictionary] = []
var _initial_profile: Dictionary = {}
var _previous_next := false
var obstacle_query: Callable = Callable()
var npc_motion_query: Callable = Callable()
var skill_modifiers: Dictionary = {}
const MODIFIER_SUFFIXES := ["min_attack", "max_attack", "hit", "defense", "dodge", "reattack", "shot_num", "multi_num", "range_angle"]
const PROTECTION_MODIFIERS := ["shield_damage_reduction", "collision_damage_reduction", "invincible", "missile_barrier"]
const COLLISION_CAUSES := ["collision", "terrain", "water", "object", "boundary", "blocked_tile", "native_navigation_floor"]
var pilot_states: Dictionary = {}
var _current_pilot_id := ""
var _shared_active_ids: Array[String] = []


func configure(profile: Dictionary, seed_value: int = 1) -> bool:
	if not profile.get("primary", {}) is Dictionary or not profile.get("secondary", {}) is Dictionary:
		return false
	if profile.get("primary", {}).is_empty() or profile.get("secondary", {}).is_empty():
		return false
	_initial_profile = profile.duplicate(true)
	_rng_state = maxi(1, seed_value & 0x7fffffff)
	weapons = {"primary": weapon_from_item(profile.primary, true), "secondary": weapon_from_item(profile.secondary, false)}
	var stats: Dictionary = profile.get("player", {})
	player = {
		"hp": maxf(1.0, float(stats.get("max_hp", 600.0))), "max_hp": maxf(1.0, float(stats.get("max_hp", 600.0))),
		"shield": maxf(0.0, float(stats.get("max_shield", 400.0))), "max_shield": maxf(0.0, float(stats.get("max_shield", 400.0))),
		"level": int(stats.get("level", 1)), "defense": float(stats.get("defense", 0.0)), "dodge": float(stats.get("dodge", 0.0)),
		"attack_bonus": float(stats.get("attack_bonus", 0.0)), "attack_probability_bonus": float(stats.get("attack_probability_bonus", 0.0)),
		"pierce": float(stats.get("pierce", 0.0)), "influence": int(stats.get("influence", 1)), "position": Vector3.ZERO, "forward": Vector3.FORWARD,
		"primary_ammo": maxi(0, int(profile.get("primary_ammo", 1000))), "secondary_ammo": maxi(0, int(profile.get("secondary_ammo", 48))),
		"primary_cooldown": 0.0, "secondary_cooldown": 0.0, "dead": false, "respawn_remaining": 0.0, "life": 0,
		"primary_heat_remaining": float(weapons.primary.overheat_seconds), "secondary_heat_remaining": float(weapons.secondary.overheat_seconds),
		"primary_overheated": false, "secondary_overheated": false,
	}
	targets.clear()
	projectiles.clear()
	_events.clear()
	selected_id = -1
	lock_progress = 0.0
	elapsed = 0.0
	_accumulator = 0.0
	_next_projectile_id = 0
	_previous_next = false
	skill_modifiers.clear()
	pilot_states.clear()
	_current_pilot_id = ""
	_shared_active_ids.clear()
	apply_player_stats(stats)
	return true


func register_pilot(pilot_id: String, profile: Dictionary) -> bool:
	if pilot_id.is_empty() or pilot_states.has(pilot_id):
		return false
	var candidate = get_script().new()
	if not candidate.configure(profile):
		return false
	pilot_states[pilot_id] = {"player": candidate.player, "weapons": candidate.weapons,
		"profile": candidate._initial_profile, "selected_id": -1, "lock_progress": 0.0,
		"previous_next": false, "skill_modifiers": {}}
	activate_pilot(pilot_id)
	return true


func activate_pilot(pilot_id: String) -> bool:
	if not pilot_states.has(pilot_id):
		return false
	store_pilot()
	_current_pilot_id = pilot_id
	var state: Dictionary = pilot_states[pilot_id]
	player = state.player
	weapons = state.weapons
	_initial_profile = state.profile
	selected_id = int(state.selected_id)
	lock_progress = float(state.lock_progress)
	_previous_next = bool(state.previous_next)
	skill_modifiers = state.skill_modifiers
	return true


func store_pilot() -> void:
	if not pilot_states.has(_current_pilot_id):
		return
	var state: Dictionary = pilot_states[_current_pilot_id]
	state.player = player
	state.weapons = weapons
	state.profile = _initial_profile
	state.selected_id = selected_id
	state.lock_progress = lock_progress
	state.previous_next = _previous_next
	state.skill_modifiers = skill_modifiers


func advance_shared(delta: float, controls_by_pilot: Dictionary) -> void:
	if not is_finite(delta) or delta <= 0.0:
		return
	_shared_active_ids.clear()
	for identifier: Variant in controls_by_pilot:
		if pilot_states.has(str(identifier)):
			_shared_active_ids.append(str(identifier))
	_shared_active_ids.sort()
	_accumulator += minf(delta, MAX_DELTA)
	while _accumulator + 0.000000001 >= STEP:
		elapsed += STEP
		for identifier: String in _shared_active_ids:
			activate_pilot(identifier)
			var controls: Dictionary = controls_by_pilot[identifier]
			var next := bool(controls.get("target_next", false))
			if next and not _previous_next:
				_cycle_target()
			_previous_next = next
			_integrate_player(STEP, controls)
			store_pilot()
		_update_npcs(STEP)
		_update_projectiles(STEP)
		store_pilot()
		_accumulator = maxf(0.0, _accumulator - STEP)


func _nearest_shared_pilot(position: Vector3) -> String:
	var nearest := ""
	var distance := INF
	for identifier: String in _shared_active_ids:
		var state: Dictionary = pilot_states[identifier].player
		if bool(state.get("dead", false)):
			continue
		var current := position.distance_squared_to(state.position)
		if current < distance:
			distance = current
			nearest = identifier
	return nearest


func _emit(event: Dictionary) -> void:
	if not _current_pilot_id.is_empty() and str(event.get("type", "")) != "target_respawned":
		event["pilot_id"] = _current_pilot_id
	_events.append(event)


func apply_player_stats(stats: Dictionary) -> void:
	# Equipment changes are attribute updates, never encounter/session resets.
	# Preserve absolute resources, so increasing capacity does not grant free HP.
	if player.is_empty():
		return
	for key: String in ["max_hp", "max_shield", "max_sp", "max_ep"]:
		if stats.has(key) and is_finite(float(stats[key])):
			player[key] = maxf(1.0 if key == "max_hp" or key == "max_sp" else 0.0, float(stats[key]))
	player.hp = minf(float(player.hp), float(player.max_hp))
	player.shield = minf(float(player.shield), float(player.max_shield))
	for key: String in ["attack_bonus", "attack_probability_bonus", "pierce", "defense", "dodge", "transport", "radar_range", "radar_primary_range", "radar_secondary_range"]:
		if stats.has(key) and is_finite(float(stats[key])):
			player[key] = float(stats[key])
	if stats.has("level"):
		player.level = maxi(1, int(stats.level))
	for slot: String in ["primary", "secondary"]:
		for suffix: String in MODIFIER_SUFFIXES:
			var key := slot + "_" + suffix
			player[key] = float(stats.get(key, 0.0)) if is_finite(float(stats.get(key, 0.0))) else 0.0
	for resource: String in ["sp", "ep"]:
		if player.has(resource) and player.has("max_" + resource):
			player[resource] = minf(float(player[resource]), float(player["max_" + resource]))


func set_skill_modifiers(modifiers: Dictionary) -> void:
	skill_modifiers.clear()
	for slot: String in ["primary", "secondary"]:
		for suffix: String in MODIFIER_SUFFIXES:
			var key := slot + "_" + suffix
			if modifiers.has(key) and is_finite(float(modifiers[key])):
				skill_modifiers[key] = float(modifiers[key])
	for key: String in PROTECTION_MODIFIERS:
		if modifiers.has(key) and is_finite(float(modifiers[key])):
			skill_modifiers[key] = float(modifiers[key])
	# Existing rounds, weapon recasts, damage, heat and target locks are untouched.


func _unit_modifier(unit: Dictionary, slot: String, suffix: String) -> float:
	var key := slot + "_" + suffix
	var value := float(unit.get(key, 0.0))
	if is_same(unit, player):
		value += float(skill_modifiers.get(key, 0.0))
	return value


func _protection_modifier(unit: Dictionary, key: String) -> float:
	var value := float(unit.get(key, 0.0))
	if is_same(unit, player):
		value += float(skill_modifiers.get(key, 0.0))
	return value if is_finite(value) else 0.0


func _weapon_interval(weapon: Dictionary) -> float:
	var slot := "primary" if bool(weapon.primary) else "secondary"
	var shots := maxi(1, int(weapon.shot_num) + int(_unit_modifier(player, slot, "shot_num")))
	return maxf(STEP, float(weapon.interval) * float(weapon.shot_num) / float(shots) * maxf(0.01, 1.0 + _unit_modifier(player, slot, "reattack")))


func _weapon_multinum(weapon: Dictionary) -> int:
	var slot := "primary" if bool(weapon.primary) else "secondary"
	return clampi(int(weapon.multi_num) + int(_unit_modifier(player, slot, "multi_num")), 1, 32)


func _secondary_lock_angle() -> float:
	# AtumSJ::GetAttackRangeAngle uses an additive angle in radians.
	return clampf(float(weapons.secondary.lock_angle) + _unit_modifier(player, "secondary", "range_angle"), 0.001, PI)


func equip_weapons(primary: Dictionary, secondary: Dictionary) -> void:
	# F2 is a local equipment selection, not a new character/session.
	# Keep vitals, ammunition, rewards and in-flight rounds. Preserve cooldowns
	# and heat fractions so changing presentation cannot refill or quick-fire.
	for slot: String in ["primary", "secondary"]:
		var item: Dictionary = primary if slot == "primary" else secondary
		var replacement := weapon_from_item(item, slot == "primary")
		var old_capacity := float(weapons[slot].overheat_seconds)
		var heat_fraction := 1.0 if old_capacity <= 0.0 else clampf(float(player[slot + "_heat_remaining"]) / old_capacity, 0.0, 1.0)
		weapons[slot] = replacement
		_initial_profile[slot] = item.duplicate(true)
		player[slot + "_heat_remaining"] = heat_fraction * float(replacement.overheat_seconds)
		player[slot + "_overheated"] = bool(player[slot + "_overheated"]) and float(replacement.overheat_seconds) > 0.0
	lock_progress = 0.0


static func weapon_from_item(item: Dictionary, primary: bool) -> Dictionary:
	# AtumSJ::GetReattackTime/GetShotNumReattackTime/GetPrepareTime/GetWarHeadSpeed.
	var shots := maxi(1, int(item.get("ShotNum", item.get("shot_num", 1))))
	var reattack := maxf(1.0, float(item.get("ReAttacktime", item.get("reattack_ms", 1000.0))))
	return {
		"item_num": int(item.get("ItemNum", item.get("item_num", 0))), "name": str(item.get("ItemName", item.get("name", ""))),
		"kind": int(item.get("Kind", 0)), "primary": primary,
		"req_unit_kind": int(item.get("ReqUnitKind", 0)), "equip_position": int(item.get("Position", 0)),
		"min_level": int(item.get("ReqMinLevel", 0)), "source_index": int(item.get("SourceIndex", 0)),
		"minimum": maxf(0.0, float(item.get("AbilityMin", item.get("minimum", 0.0)))),
		"maximum": maxf(0.0, float(item.get("AbilityMax", item.get("maximum", 0.0)))),
		"hit_rate": float(item.get("HitRate", item.get("hit_rate", 100.0))),
		"pierce": float(item.get("FractionResistance", item.get("pierce", 0.0))),
		"range": maxf(0.1, float(item.get("Range", item.get("range", 500.0)))),
		"interval": reattack / 1000.0 / float(shots), "shot_num": shots,
		"multi_num": clampi(int(item.get("MultiNum", item.get("multi_num", 1))), 1, 32),
		"lock_seconds": maxf(0.0, float(item.get("AttackTime", item.get("lock_ms", 0.0))) / 1000.0),
		"lock_angle": clampf(float(item.get("RangeAngle", item.get("lock_angle", 0.35))), 0.001, PI),
		"projectile_speed": maxf(1.0, float(item.get("RepeatTime", item.get("projectile_speed", 300.0)))),
		"cycle_seconds": reattack / 1000.0,
		"overheat_seconds": maxf(0.0, float(item.get("Time", 0.0)) / 1000.0),
	}


func add_target(profile: Dictionary, position: Vector3, instance_id: int = -1) -> int:
	var identifier := targets.size() if instance_id < 0 else instance_id
	var hp := maxf(1.0, _number_or(profile.get("HP", profile.get("max_hp")), 100.0))
	var shield := maxf(0.0, _number_or(profile.get("DP", profile.get("max_shield")), 0.0))
	var respawn_seconds := _number_or(profile.get("respawn_seconds"), -1.0 if bool(profile.get("native_spawn", false)) else 12.0)
	if not is_finite(respawn_seconds) or respawn_seconds <= 0.0:
		respawn_seconds = -1.0 if bool(profile.get("native_spawn", false)) else 12.0
	var options := _npc_options_from_profile(profile)
	targets.append({
		"id": identifier, "monster_code": int(profile.get("MonsterUnitKind", profile.get("MonsterCode", profile.get("monster_code", 0)))),
		"name": str(profile.get("MonsterName", profile.get("name", "NPC"))), "profile": profile.duplicate(true),
		"position": position, "spawn_position": position, "velocity": Vector3.ZERO,
		"hp": hp, "max_hp": hp, "shield": shield, "max_shield": shield,
		"level": int(profile.get("Level", profile.get("level", 1))),
		"defense": _number_or(profile.get("Defense", profile.get("defense")), 0.0),
		"dodge": _number_or(profile.get("DefenseProbability", profile.get("dodge")), 0.0),
		"speed": maxf(0.0, _number_or(profile.get("MoveSpeed", profile.get("speed")), 25.0)),
		"radius": maxf(1.0, _number_or(profile.get("radius"), 12.0)),
		"weapon": options[0].weapon if not options.is_empty() else {}, "npc_weapon_options": options,
		"npc_selected_option": -1, "npc_option_ready_at": {},
		"npc_cycle_started": false,
		"npc_preparing": false, "npc_prepare_remaining": 0.0,
		"npc_burst_remaining": 0, "npc_burst_wait": 0.0,
		"attack_cooldown": 2.0 + float(identifier % 3) * 0.7,
		"dead": false, "respawn_remaining": 0.0, "respawn_seconds": respawn_seconds, "life": 0,
		"hostile": bool(profile.get("hostile", true)), "belligerence": int(profile.get("Belligerence", -1)), "aggressed": false,
	})
	return identifier


static func _number_or(value: Variant, fallback: float) -> float:
	# Current MEX intentionally marks unrecovered server-only fields null.
	return float(value) if (value is int or value is float) and is_finite(float(value)) else fallback


static func _npc_options_from_profile(profile: Dictionary) -> Array[Dictionary]:
	var options: Array[Dictionary] = []
	# An explicitly unavailable native profile remains unarmed. Never replace
	# a failed native identity/unsupported skill check with a player weapon.
	var raw_value: Variant = profile.get("npc_weapon_options", [])
	if not raw_value is Array or raw_value.size() > 5:
		return []
	var raw: Array = raw_value
	if not profile.has("npc_weapon_options"):
		var item: Dictionary = profile.get("weapon", {})
		if not item.is_empty():
			raw = [{"item": item, "weight": 100, "source_slot": 1}]
	var total := 0
	for value: Variant in raw:
		if not value is Dictionary or not value.get("item") is Dictionary:
			return []
		var item: Dictionary = value.item
		var kind := int(item.get("Kind", -1))
		var primary := (kind >= 0 and kind <= 7) or (kind >= 100 and kind <= 105)
		var secondary := (kind >= 8 and kind <= 15) or (kind >= 150 and kind <= 162)
		var weight := int(value.get("weight", 0))
		if (not primary and not secondary) or kind == 104 or weight <= 0 or weight > 100:
			return []
		total += weight
		options.append({"weapon": weapon_from_item(item, primary), "weight": weight,
			"source_slot": int(value.get("source_slot", 1))})
	if total != 100:
		return []
	# MonsterDBAccess sorts Charging descending before cumulative RAND100.
	options.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.weight) > int(b.weight))
	return options


func set_player_pose(position: Vector3, forward: Vector3) -> void:
	if player.is_empty() or not position.is_finite() or not forward.is_finite():
		return
	player.position = position
	if forward.length_squared() > 0.00001:
		player.forward = forward.normalized()


func select_target(identifier: int) -> void:
	if identifier != selected_id:
		selected_id = identifier
		lock_progress = 0.0


func advance(delta: float, controls: Dictionary = {}) -> void:
	if player.is_empty() or not is_finite(delta) or delta <= 0.0:
		return
	var next := bool(controls.get("target_next", false))
	if next and not _previous_next:
		_cycle_target()
	_previous_next = next
	_accumulator += minf(delta, MAX_DELTA)
	while _accumulator + 0.000000001 >= STEP:
		_integrate(STEP, controls)
		_accumulator -= STEP


func _integrate(delta: float, controls: Dictionary) -> void:
	elapsed += delta
	_integrate_player(delta, controls)
	_update_npcs(delta)
	_update_projectiles(delta)


func _integrate_player(delta: float, controls: Dictionary) -> void:
	for slot: String in ["primary", "secondary"]:
		player[slot + "_cooldown"] = maxf(0.0, float(player[slot + "_cooldown"]) - delta)
		var capacity := float(weapons[slot].overheat_seconds)
		if capacity > 0.0:
			if bool(controls.get(slot, false)) and not player.dead and not bool(player[slot + "_overheated"]) and int(player[slot + "_ammo"]) > 0:
				player[slot + "_heat_remaining"] = maxf(0.0, float(player[slot + "_heat_remaining"]) - delta)
				if float(player[slot + "_heat_remaining"]) <= 0.000001:
					player[slot + "_overheated"] = true
			else:
				player[slot + "_heat_remaining"] = minf(capacity, float(player[slot + "_heat_remaining"]) + delta * capacity / 10.0)
				if float(player[slot + "_heat_remaining"]) >= capacity - 0.000001:
					player[slot + "_overheated"] = false
	if player.dead:
		player.respawn_remaining = maxf(0.0, float(player.respawn_remaining) - delta)
		if float(player.respawn_remaining) <= 0.000001:
			_respawn_player()
	else:
		var aim: Vector3 = controls.get("aim_direction", player.forward)
		if not aim.is_finite() or aim.length_squared() < 0.00001:
			aim = player.forward
		aim = aim.normalized()
		var origin: Vector3 = controls.get("aim_origin", player.position)
		if not origin.is_finite():
			origin = player.position
		_update_lock(delta, aim)
		if bool(controls.get("primary", false)):
			_fire_primary(origin, aim)
		if bool(controls.get("secondary", false)):
			_fire_secondary(aim)


func _target(identifier: int) -> Dictionary:
	for target: Dictionary in targets:
		if int(target.id) == identifier:
			return target
	return {}


func _cycle_target() -> void:
	var living: Array[int] = []
	for target: Dictionary in targets:
		if not target.dead:
			living.append(int(target.id))
	if living.is_empty():
		select_target(-1)
		return
	var current := living.find(selected_id)
	select_target(living[(current + 1) % living.size()])


func _update_lock(delta: float, aim: Vector3) -> void:
	var target := _target(selected_id)
	if target.is_empty() or target.dead:
		var best := -1
		var best_dot := cos(_secondary_lock_angle())
		for candidate: Dictionary in targets:
			if candidate.dead:
				continue
			var offset: Vector3 = candidate.position - player.position
			if offset.length() <= float(weapons.secondary.range) and offset.length_squared() > 0.001:
				var alignment := aim.dot(offset.normalized())
				if alignment > best_dot:
					best_dot = alignment
					best = int(candidate.id)
		select_target(best)
		target = _target(selected_id)
	if target.is_empty():
		lock_progress = 0.0
		return
	var offset: Vector3 = target.position - player.position
	var valid := offset.length() <= float(weapons.secondary.range) and offset.length_squared() > 0.001
	valid = valid and aim.dot(offset.normalized()) >= cos(_secondary_lock_angle())
	valid = valid and _obstacle_distance(player.position, target.position, 0.0) < 0.0
	if valid:
		var required := float(weapons.secondary.lock_seconds)
		lock_progress = 1.0 if required <= 0.0 else minf(1.0, lock_progress + delta / required)
	else:
		lock_progress = 0.0


static func ray_sphere(origin: Vector3, direction: Vector3, center: Vector3, radius: float, maximum: float) -> float:
	var offset := origin - center
	var b := offset.dot(direction)
	var c := offset.length_squared() - radius * radius
	var discriminant := b * b - c
	if discriminant < 0.0:
		return -1.0
	var near := -b - sqrt(discriminant)
	var far := -b + sqrt(discriminant)
	var distance := maxf(0.0, near) if far >= 0.0 else -1.0
	return distance if distance >= 0.0 and distance <= maximum else -1.0


func _fire_primary(origin: Vector3, aim: Vector3) -> void:
	if float(player.primary_cooldown) > 0.000001 or int(player.primary_ammo) <= 0 or player.primary_overheated:
		return
	var weapon: Dictionary = weapons.primary
	player.primary_cooldown = _weapon_interval(weapon)
	player.primary_ammo -= 1
	var limit := float(weapon.range) * (2.0 if int(weapon.kind) >= 0 and int(weapon.kind) <= 7 else 1.0)
	var nearest := limit
	var hit: Dictionary = {}
	var obstruction := _obstacle_distance(origin, origin + aim * limit, 0.0)
	if obstruction >= 0.0:
		nearest = minf(nearest, obstruction)
	for target: Dictionary in targets:
		if target.dead:
			continue
		var distance := ray_sphere(origin, aim, target.position, float(target.radius), limit)
		if distance >= 0.0 and distance < nearest:
			nearest = distance
			hit = target
	var endpoint := origin + aim * nearest
	_emit({"type": "fired", "slot": "primary", "position": player.position, "endpoint": endpoint, "item_num": weapon.item_num})
	if not hit.is_empty():
		if _obstacle_distance(player.position, hit.position, 0.0) >= 0.0:
			return # third-person camera cannot fire through a surface in front of the muzzle
		for shot in range(_weapon_multinum(weapon)):
			if hit.dead:
				break
			_attack_target(hit, weapon, player.position.distance_to(hit.position))


func _fire_secondary(aim: Vector3) -> void:
	if float(player.secondary_cooldown) > 0.000001 or int(player.secondary_ammo) <= 0 or lock_progress < 1.0 or player.secondary_overheated:
		return
	var target := _target(selected_id)
	if target.is_empty() or target.dead:
		return
	var weapon: Dictionary = weapons.secondary
	player.secondary_cooldown = _weapon_interval(weapon)
	var projectile_count := mini(_weapon_multinum(weapon), int(player.secondary_ammo))
	player.secondary_ammo -= projectile_count
	for shot in range(projectile_count):
		_next_projectile_id += 1
		projectiles.append({"id": _next_projectile_id, "position": player.position + aim * 12.0,
			"direction": aim, "target_id": int(target.id), "target_life": int(target.life),
			"speed": float(weapon.projectile_speed), "remaining": maxf(1.0, float(weapon.range) / float(weapon.projectile_speed) * 2.0),
			"traveled": 0.0, "weapon": weapon, "hostile": false, "pilot_id": _current_pilot_id})
	_emit({"type": "fired", "slot": "secondary", "position": player.position, "target_id": int(target.id), "item_num": weapon.item_num})


func _update_projectiles(delta: float) -> void:
	# A lethal incoming round may remove the victim's outgoing rounds. Iterate
	# a shallow stable list so that cleanup cannot shift an unrelated round.
	for projectile: Dictionary in projectiles.duplicate():
		if not projectiles.has(projectile):
			continue
		var hostile := bool(projectile.get("hostile", false))
		var target: Dictionary = {}
		var radius := PLAYER_RADIUS
		if hostile:
			var victim := str(projectile.get("pilot_id", ""))
			if not victim.is_empty():
				if not pilot_states.has(victim):
					projectiles.erase(projectile)
					continue
				var intended: Dictionary = pilot_states[victim].player
				if bool(intended.get("dead", false)) or int(intended.get("life", 0)) != int(projectile.target_life) or float(projectile.remaining) <= 0.0:
					projectiles.erase(projectile)
					continue
				if not _shared_active_ids.has(victim):
					# A private incoming round survives server restart/reconnect.
					# Its TTL, position and intended life pause with this pilot.
					continue
				activate_pilot(victim)
			target = player
		else:
			target = _target(int(projectile.target_id))
			if not target.is_empty():
				radius = float(target.radius)
		projectile.remaining = float(projectile.remaining) - delta
		if float(projectile.remaining) <= 0.0 or target.is_empty() or target.dead or int(target.get("life", 0)) != int(projectile.target_life):
			projectiles.erase(projectile)
			continue
		var offset: Vector3 = target.position - projectile.position
		var direction: Vector3 = projectile.direction
		if offset.length_squared() > 0.001:
			# Local pursuit adaptation: original missiles use effect/cinema trajectories.
			direction = direction.slerp(offset.normalized(), 1.0 - exp(-4.0 * delta)).normalized()
		projectile.direction = direction
		var distance := float(projectile.speed) * delta
		var collision := ray_sphere(projectile.position, direction, target.position, radius, distance)
		var obstruction := _obstacle_distance(projectile.position, projectile.position + direction * distance, 0.6)
		if obstruction >= 0.0 and (collision < 0.0 or obstruction <= collision):
			_emit({"type": "projectile_blocked", "position": projectile.position + direction * obstruction, "id": int(projectile.id)})
			projectiles.erase(projectile)
			continue
		if collision >= 0.0:
			var owner := str(projectile.get("pilot_id", ""))
			if not owner.is_empty():
				activate_pilot(owner)
			if hostile:
				_damage_player_from_npc(projectile.weapon, projectile.attacker, float(projectile.traveled) + collision)
			else:
				_attack_target(target, projectile.weapon, float(projectile.traveled) + collision)
			store_pilot()
			projectiles.erase(projectile)
			continue
		projectile.position += direction * distance
		projectile.traveled = float(projectile.traveled) + distance


func _update_npcs(delta: float) -> void:
	for target: Dictionary in targets:
		if target.dead:
			if float(target.get("respawn_seconds", 12.0)) < 0.0:
				continue # Native zero/invalid interval requires original creation-tick context.
			target.respawn_remaining = maxf(0.0, float(target.respawn_remaining) - delta)
			if float(target.respawn_remaining) <= 0.000001:
				target.dead = false
				target.hp = target.max_hp
				target.shield = target.max_shield
				target.position = target.spawn_position
				target.life += 1
				target.attack_cooldown = 2.0
				target.npc_selected_option = -1
				target.npc_option_ready_at = {}
				target.npc_cycle_started = false
				target.npc_preparing = false
				target.npc_burst_remaining = 0
				target.npc_burst_wait = 0.0
				target.aggressed = false
				_emit({"type": "target_respawned", "id": int(target.id), "monster_code": int(target.monster_code)})
			continue
		if not pilot_states.is_empty():
			var nearest := _nearest_shared_pilot(target.position)
			if nearest.is_empty():
				target.velocity = Vector3.ZERO
				continue
			activate_pilot(nearest)
		if not target.hostile or not native_aggression(target, int(player.get("influence", 1))) or player.dead:
			target.velocity = Vector3.ZERO
			continue
		var to_player: Vector3 = player.position - target.position
		var distance := to_player.length()
		var direction := to_player.normalized() if distance > 0.001 else Vector3.FORWARD
		# Local encounter AI; source NPC movement scheduler is not reproduced.
		if int(target.get("belligerence", -1)) == 2 and float(target.hp) < float(target.max_hp) * 0.3:
			direction = -direction
		elif distance < 120.0:
			direction = direction.cross(Vector3.UP).normalized()
		target.velocity = direction * float(target.speed)
		var desired: Vector3 = target.position + target.velocity * delta
		if npc_motion_query.is_valid():
			var resolved: Variant = npc_motion_query.call(target.position, desired, float(target.radius))
			if resolved is Vector3 and resolved.is_finite():
				desired = resolved
		target.position = desired
		_update_npc_attack(target, delta)


func _select_npc_option(target: Dictionary) -> int:
	# CNPCMonster::SelectUsingMonsterItem, ordinary slots01..05 only.
	var roll := int(_random_unit() * 100.0)
	var cumulative := 0
	var fallback := -1
	var longest_remaining := -INF
	for index in range(target.npc_weapon_options.size()):
		var option: Dictionary = target.npc_weapon_options[index]
		cumulative += int(option.weight)
		var remaining := float(target.npc_option_ready_at.get(str(index), 0.0)) - elapsed
		if cumulative > roll and remaining < 3.0:
			return index
		# Preserve the source fallback comparator, including its selection of
		# the longest remaining cooldown rather than renormalizing weights.
		if fallback < 0 or longest_remaining < remaining:
			fallback = index
			longest_remaining = remaining
	return fallback


func _update_npc_attack(target: Dictionary, delta: float) -> void:
	var options: Array = target.get("npc_weapon_options", [])
	if options.is_empty():
		return
	target.attack_cooldown = maxf(0.0, float(target.attack_cooldown) - delta)
	if float(target.attack_cooldown) > 0.000001:
		return
	var previous := int(target.get("npc_selected_option", -1))
	if previous >= 0 and bool(target.get("npc_cycle_started", false)) and int(target.npc_burst_remaining) <= 0 and float(target.npc_option_ready_at.get(str(previous), 0.0)) <= elapsed + 0.000001:
		target.npc_selected_option = -1
		target.npc_cycle_started = false
	if int(target.npc_selected_option) < 0:
		target.npc_selected_option = _select_npc_option(target)
		if int(target.npc_selected_option) < 0:
			return
		target.weapon = options[int(target.npc_selected_option)].weapon
	var weapon: Dictionary = target.weapon
	var distance: float = target.position.distance_to(player.position)
	# World occlusion is checked for every salvo; preparation never bypasses
	# a new wall. This is a conservative physical bridge to native attacks.
	if distance > float(weapon.range) or _obstacle_distance(target.position, player.position, 0.0) >= 0.0:
		target.npc_preparing = false
		target.npc_prepare_remaining = 0.0
		return
	if int(target.npc_burst_remaining) > 0:
		target.npc_burst_wait = maxf(0.0, float(target.npc_burst_wait) - delta)
		if float(target.npc_burst_wait) > 0.000001:
			return
		_fire_npc_salvo(target, weapon)
		target.npc_burst_remaining -= 1
		target.npc_burst_wait = NPC_BURST_INTERVAL
		return
	var selected := int(target.npc_selected_option)
	if float(target.npc_option_ready_at.get(str(selected), 0.0)) > elapsed + 0.000001:
		return
	if bool(target.npc_preparing):
		target.npc_prepare_remaining = maxf(0.0, float(target.npc_prepare_remaining) - delta)
		if float(target.npc_prepare_remaining) > 0.000001:
			return
	elif float(weapon.lock_seconds) > 0.0:
		target.npc_preparing = true
		target.npc_prepare_remaining = float(weapon.lock_seconds)
		return
	target.npc_preparing = false
	target.npc_prepare_remaining = 0.0
	target.npc_option_ready_at[str(selected)] = elapsed + float(weapon.cycle_seconds)
	target.npc_burst_remaining = maxi(0, int(weapon.shot_num) - 1)
	target.npc_burst_wait = NPC_BURST_INTERVAL
	_fire_npc_salvo(target, weapon)
	# Complete this item's recast before choosing another weighted weapon.
	# The pending burst keeps its original item and completes first.
	target["npc_cycle_started"] = true


func _fire_npc_salvo(target: Dictionary, weapon: Dictionary) -> void:
	_emit({"type": "enemy_fired", "position": target.position, "endpoint": player.position,
		"id": int(target.id), "item_num": int(weapon.item_num), "slot": "primary" if bool(weapon.primary) else "secondary",
		"shot_count": int(weapon.shot_num), "multi_count": int(weapon.multi_num), "time": elapsed})
	var distance: float = target.position.distance_to(player.position)
	for round_index in range(int(weapon.multi_num)):
		if bool(weapon.primary):
			_damage_player_from_npc(weapon, target, distance)
		else:
			var direction: Vector3 = (player.position - target.position).normalized()
			if direction.length_squared() < 0.00001:
				direction = Vector3.FORWARD
			_next_projectile_id += 1
			# Local pursuit/swept-collision bridge, shared with player missiles.
			# Original Cinema/Orbit trajectories are not claimed as reproduced.
			projectiles.append({"id": _next_projectile_id, "position": target.position,
				"direction": direction, "target_id": int(target.id), "target_life": int(player.get("life", 0)),
				"speed": float(weapon.projectile_speed), "remaining": maxf(1.0, float(weapon.range) / float(weapon.projectile_speed) * 2.0),
				"traveled": 0.0, "weapon": weapon, "hostile": true, "pilot_id": _current_pilot_id,
				"attacker": {"level": int(target.level)}})


func _damage_player_from_npc(weapon: Dictionary, attacker: Dictionary, distance: float) -> void:
	var outcome := resolve_attack(weapon, attacker, player, distance, true, "M2C")
	if bool(outcome.hit):
		damage_player(float(outcome.damage), "npc")


static func native_aggression(target: Dictionary, influence: int = 1) -> bool:
	# AtumParam.h: BELL_DEFENSE1, BELL_NOTATTACK4 and faction parity10..29.
	# The higher-level scheduler/path selection remains an explicit local AI.
	var bell := int(target.get("belligerence", -1))
	if bell == 4:
		return false
	if bell == 1:
		return bool(target.get("aggressed", false))
	if bell >= 10 and bell <= 29:
		if ((influence & 3) != 0 and bell % 2 == 0) or ((influence & 4) != 0 and bell % 2 == 1):
			return false
	return true


func _obstacle_distance(start: Vector3, finish: Vector3, radius: float) -> float:
	if not obstacle_query.is_valid():
		return -1.0
	var result: Variant = obstacle_query.call(start, finish, radius)
	if not result is Dictionary or not bool(result.get("collided", result.get("hit", false))):
		return -1.0
	var distance := start.distance_to(finish)
	if result.has("distance"):
		return clampf(float(result.distance), 0.0, distance)
	if result.has("t"):
		return distance * clampf(float(result.t), 0.0, 1.0)
	var position: Variant = result.get("position")
	return start.distance_to(position) if position is Vector3 else 0.0


func _attack_target(target: Dictionary, weapon: Dictionary, distance: float) -> void:
	target.aggressed = true
	var outcome := resolve_attack(weapon, player, target, distance, false)
	if not outcome.hit:
		_emit({"type": "miss", "id": int(target.id), "position": target.position})
		return
	var split := apply_damage(target, float(outcome.damage))
	_emit({"type": "hit", "id": int(target.id), "position": target.position, "damage": outcome.damage,
		"shield_damage": split.shield, "hp_damage": split.hp, "critical": false,
		"source_id": int(weapon.item_num), "monster_code": int(target.monster_code), "target_life": int(target.life)})
	if float(target.hp) <= 0.0 and not target.dead:
		target.dead = true
		target.respawn_remaining = maxf(0.0, float(target.get("respawn_seconds", 12.0)))
		_emit({"type": "target_destroyed", "id": int(target.id), "instance_id": "%s/%s:%s" % [_initial_profile.get("encounter_id", "local"), target.id, target.life],
			"monster_code": int(target.monster_code), "position": target.position, "source_id": int(weapon.item_num)})
		if selected_id == int(target.id):
			select_target(-1)


func resolve_attack(weapon: Dictionary, attacker: Dictionary, defender: Dictionary, distance: float, monster_attacker: bool = false, battle_type: String = "C2M") -> Dictionary:
	# FieldIOCPSocket::CalcDamageOfAttackNew: percentages are 0..100 after 2010 update.
	# The native protection checks precede hit/defense RNG and minimum damage.
	# Barrier negates secondary damage; it does not erase a missile in flight.
	if _protection_modifier(defender, "missile_barrier") > 0.0 and not bool(weapon.primary):
		return {"hit": true, "damage": 0.0, "critical": false, "blocked": "missile_barrier"}
	if _protection_modifier(defender, "invincible") > 0.0:
		return {"hit": true, "damage": 0.0, "critical": false, "blocked": "invincible"}
	var slot := "primary" if bool(weapon.primary) else "secondary"
	var chance := float(weapon.hit_rate) + float(attacker.get("attack_probability_bonus", 0.0)) + _unit_modifier(attacker, slot, "hit") - float(defender.get("dodge", 0.0)) - _unit_modifier(defender, slot, "dodge")
	var level_difference := int(defender.get("level", 1)) - int(attacker.get("level", 1))
	if monster_attacker:
		chance += 2.0 * maxi(0, -level_difference)
	elif battle_type == "C2M":
		chance -= 5.0 * maxi(0, level_difference)
	if bool(weapon.primary) and int(weapon.kind) >= 0 and int(weapon.kind) <= 7 and not monster_attacker:
		chance *= effective_range_factor(distance, float(weapon.range))
	if _random_unit() * 100.0 > chance:
		return {"hit": false, "damage": 0.0, "critical": false}
	var bonus := float(attacker.get("attack_bonus", 0.0))
	var low := float(weapon.minimum) * maxf(0.0, 1.0 + _unit_modifier(attacker, slot, "min_attack")) * (1.0 + bonus)
	var high := maxf(low, float(weapon.maximum) * maxf(0.0, 1.0 + _unit_modifier(attacker, slot, "max_attack")) * (1.0 + bonus))
	var attack := lerpf(low, high, _random_unit())
	var defense := float(defender.get("defense", 0.0)) + _unit_modifier(defender, slot, "defense")
	if not monster_attacker and battle_type == "C2M":
		defense *= _random_unit() # AtumSJ::GetDefenseM outside arena.
	defense = clampf(defense - float(weapon.pierce) - float(attacker.get("pierce", 0.0)), 0.0, 100.0)
	var minimum_damage := 1.0 if battle_type == "C2C" else high * 0.1
	var damage := minf(high, maxf(minimum_damage, attack * (100.0 - defense) / 100.0))
	# The legacy critical-hit branch is commented out, not a live multiplier.
	return {"hit": true, "damage": damage, "critical": false}


static func effective_range_factor(distance: float, effective_range: float) -> float:
	if effective_range <= 0.0 or distance > effective_range * 2.0:
		return 0.0
	if distance <= effective_range:
		return 1.0
	if distance <= effective_range * 1.5:
		return 2.0 * (0.3 - 1.0) * distance / effective_range + 3.0 - 2.0 * 0.3
	return 0.3


static func apply_damage(unit: Dictionary, damage: float, shield_damage_reduction: float = 0.0) -> Dictionary:
	if not is_finite(damage) or damage <= 0.0:
		return {"shield": 0.0, "hp": 0.0}
	var shield := maxf(0.0, float(unit.get("shield", 0.0)))
	var shield_damage := 0.0
	var reduction := clampf(shield_damage_reduction, 0.0, 1.0) if is_finite(shield_damage_reduction) else 0.0
	if shield > 0.0 and reduction > 0.0:
		# DecreaseCharacterHPDP (FieldIOCPSocket.cpp1693..1709). Preserve
		# the original overflow formula: shield*(1+r), not shield/(1-r).
		var reduced_damage := damage * (1.0 - reduction)
		if shield >= reduced_damage:
			unit.shield = shield - reduced_damage
			return {"shield": reduced_damage, "hp": 0.0}
		shield_damage = shield
		damage -= shield * (1.0 + reduction)
		shield = 0.0
	var remaining_shield_damage := minf(shield, damage)
	shield_damage += remaining_shield_damage
	var hp_damage := minf(maxf(0.0, float(unit.get("hp", 0.0))), damage - remaining_shield_damage)
	unit.shield = maxf(0.0, shield - remaining_shield_damage)
	unit.hp = maxf(0.0, float(unit.get("hp", 0.0)) - hp_damage)
	return {"shield": shield_damage, "hp": hp_damage}


func damage_player(damage: float, cause: String = "collision") -> void:
	if player.is_empty() or player.dead or not is_finite(damage) or damage <= 0.0:
		return
	# Invincibility also protects collision penalties in the native handler.
	if _protection_modifier(player, "invincible") > 0.0:
		return
	if cause in COLLISION_CAUSES:
		damage *= 1.0 - clampf(_protection_modifier(player, "collision_damage_reduction"), 0.0, 1.0)
	if damage <= 0.0:
		return
	var split := apply_damage(player, damage, _protection_modifier(player, "shield_damage_reduction"))
	_emit({"type": "player_hit", "damage": damage, "shield_damage": split.shield, "hp_damage": split.hp, "cause": cause})
	if float(player.hp) <= 0.0:
		player.dead = true
		player.respawn_remaining = 4.0
		lock_progress = 0.0
		# Remove only this pilot's outgoing rounds. Incoming missiles keep their
		# target life token and expire without touching a later respawn or pilot.
		for index in range(projectiles.size() - 1, -1, -1):
			if not bool(projectiles[index].get("hostile", false)) and str(projectiles[index].get("pilot_id", "")) == _current_pilot_id:
				projectiles.remove_at(index)
		_emit({"type": "player_died", "cause": cause})


func _respawn_player() -> void:
	player.hp = player.max_hp
	player.shield = player.max_shield
	player.dead = false
	player.life = int(player.get("life", 0)) + 1
	player.respawn_remaining = 0.0
	player.primary_ammo = maxi(0, int(_initial_profile.get("primary_ammo", 1000)))
	player.secondary_ammo = maxi(0, int(_initial_profile.get("secondary_ammo", 48)))
	for slot: String in ["primary", "secondary"]:
		player[slot + "_heat_remaining"] = float(weapons[slot].overheat_seconds)
		player[slot + "_overheated"] = false
	_emit({"type": "player_respawned"})


func _random_unit() -> float:
	# Explicit Park-Miller stream, independent of the engine/global random state.
	_rng_state = (_rng_state * 48271) % 2147483647
	return float(_rng_state) / 2147483647.0


func snapshot() -> Dictionary:
	var result := player.duplicate(true)
	result["target"] = _target(selected_id).duplicate(true)
	if not result.target.is_empty():
		result.target["distance"] = player.position.distance_to(result.target.position)
	result["target_id"] = selected_id
	result["lock_progress"] = lock_progress
	result["locked"] = lock_progress >= 1.0
	result["targets"] = targets.duplicate(true)
	result["projectiles"] = projectiles.duplicate(true)
	result["weapons"] = weapons.duplicate(true)
	result["elapsed"] = elapsed
	return result


func drain_events() -> Array[Dictionary]:
	var result: Array[Dictionary] = _events.duplicate(true)
	_events.clear()
	return result
