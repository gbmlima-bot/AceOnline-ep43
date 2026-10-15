class_name ArenaModel
extends RefCounted
## Small authoritative cooperative room. Client messages contain controls only.
## One shared CombatModel owns all NPCs, missiles, RNG and simulation ticks.

const Combat = preload("res://scripts/combat_model.gd")
const Flight = preload("res://scripts/flight_model.gd")
const Inventory = preload("res://scripts/inventory_model.gd")
const Skills = preload("res://scripts/skill_model.gd")
const STEP := 1.0 / 120.0
const GEAR_ID := "12003100"
const MAP_ID := 3002
const AXES := ["pitch", "yaw", "roll"]
const BUTTONS := ["boost", "brake", "primary", "secondary", "target_next"]
const INPUT_TIMEOUT := 0.35
const MAX_COMMANDS := 4096
static var _starter_rows: Array = []

var combat: RefCounted
var pilots: Dictionary = {}
var dirty := false
var tick := 0
var world: Object
var config: Dictionary = {}
var _accumulator := 0.0
var _events: Array[Dictionary] = []
var _contributions: Dictionary = {}
var _rewarded: Dictionary = {}
var _commands: Dictionary = {}
var _native: Dictionary = {}
var _encounter: Dictionary = {}
var _engines: Dictionary = {}
var _max_players := 2
var _room_id := "pilot3002"


func configure(settings: Dictionary, world_model: Object) -> bool:
	if world_model == null or not world_model.has_method("get_bounds") or not world_model.has_method("resolve_motion") or not world_model.has_method("trace_segment") or not world_model.has_method("sample_ground_height"):
		return false
	if int(settings.get("map_index", MAP_ID)) != MAP_ID:
		return false
	var requested_cap := int(settings.get("max_players", 2))
	if requested_cap < 1 or requested_cap > 8:
		return false
	world = world_model
	config = settings.duplicate(true)
	config["map_index"] = MAP_ID
	_max_players = requested_cap
	_room_id = str(settings.get("room_id", "pilot3002"))
	if not _identifier(_room_id):
		return false
	_native = _read("res://assets/legacy_rules/combat.json")
	_encounter = _read("res://assets/local_encounter.json")
	_engines = _read("res://assets/legacy_rules/engines.json")
	if _native.is_empty() or _encounter.is_empty() or not _engines.get("by_gear", {}).has(GEAR_ID):
		return false
	combat = Combat.new()
	var profile := _base_profile()
	if not combat.configure(profile, maxi(1, int(settings.get("seed", 104729)))):
		return false
	combat.obstacle_query = Callable(world, "trace_segment")
	if world.has_method("resolve_npc_motion"):
		combat.npc_motion_query = Callable(world, "resolve_npc_motion")
	pilots.clear()
	_contributions.clear()
	_rewarded.clear()
	_commands.clear()
	_events.clear()
	tick = 0
	_accumulator = 0.0
	var origin := _spawn(0)
	for row: Dictionary in _encounter.get("maps", {}).get(str(MAP_ID), {}).get("targets", []):
		var monster: Dictionary = _native.monster.duplicate(true)
		monster.merge(_encounter.get("monster_overrides", {}), true)
		monster.weapon = _native.primary.duplicate(true)
		monster.radius = 12.0 # Explicit headless encounter collision envelope, source model not loaded.
		var position: Vector3 = origin + _vec(row.get("offset", [0, 0, -240]))
		position.y = maxf(position.y, float(world.call("sample_ground_height", position.x, position.z, true)) + 60.0)
		combat.add_target(monster, position)
	if combat.targets.size() != 3:
		return false
	dirty = true
	return true


func _base_profile() -> Dictionary:
	return {"primary": _native.get("primary", {}), "secondary": _native.get("secondary", {}),
		"player": {"max_hp": 600.0, "max_shield": 400.0, "level": 9},
		"primary_ammo": 1000, "secondary_ammo": 48, "encounter_id": _room_id + ":3002"}


func add_player(pilot_id: String, saved: Dictionary = {}) -> Dictionary:
	if combat == null or not _identifier(pilot_id):
		return _failure("invalid_pilot")
	if pilots.has(pilot_id) and bool(pilots[pilot_id].connected):
		return _failure("pilot_already_connected")
	if _connected_count() >= _max_players:
		return _failure("room_full")
	if pilots.has(pilot_id):
		pilots[pilot_id].connected = true
		pilots[pilot_id].controls = {}
		pilots[pilot_id].input_age = INPUT_TIMEOUT
		dirty = true
		_events.append({"type": "pilot_joined", "pilot_id": pilot_id, "returning": true})
		return {"ok": true, "pilot_id": pilot_id, "returning": true, "input_seq": int(pilots[pilot_id].seq)}
	var record := _new_pilot(pilot_id)
	if record.is_empty():
		return _failure("native_starter_unavailable")
	if not saved.is_empty():
		var restored := _restore_pilot_record(pilot_id, saved, record)
		if restored.is_empty():
			return _failure("invalid_saved_pilot")
		record = restored
	if not combat.register_pilot(pilot_id, record.profile):
		return _failure("combat_registration_failed")
	pilots[pilot_id] = record
	if not saved.is_empty():
		combat.pilot_states[pilot_id] = _unpack(saved.get("combat", {}))
		combat._current_pilot_id = ""
		combat.activate_pilot(pilot_id)
	else:
		combat.set_player_pose(record.flight.position, record.flight.forward())
		combat.player["credits"] = record.inventory.credits
		combat.player["experience"] = record.inventory.experience
		combat.player["sp"] = record.skills.sp
		combat.player["max_sp"] = record.skills.max_sp
		combat.store_pilot()
	record.connected = true
	dirty = true
	_events.append({"type": "pilot_joined", "pilot_id": pilot_id, "returning": not saved.is_empty()})
	return {"ok": true, "pilot_id": pilot_id, "returning": not saved.is_empty(), "input_seq": int(record.seq)}


func _new_pilot(pilot_id: String) -> Dictionary:
	var inventory = Inventory.new()
	if not inventory.configure(_starter_catalog()):
		return {}
	var starter_icons: Dictionary = {}
	for item_num: Variant in inventory.catalog:
		starter_icons[item_num] = str(inventory._icons.get(item_num, ""))
	inventory._icons = starter_icons
	inventory.gear_id = GEAR_ID
	inventory.set_starting_level(9)
	var engine: Dictionary = _engines.by_gear[GEAR_ID]
	var starter := {"primary": int(_native.primary.ItemNum), "secondary": int(_native.secondary.ItemNum), "engine": int(engine.ItemNum), "armor": 8013100, "radar": 7000970}
	for slot: String in starter:
		if not inventory.add_item(int(starter[slot])) or not bool(inventory.equip_item(int(starter[slot]), slot).get("ok", false)):
			return {}
	var stats: Dictionary = inventory.combat_profile()
	var profile := _base_profile()
	profile.player = stats
	profile.primary = inventory.catalog[int(starter.primary)]
	profile.secondary = inventory.catalog[int(starter.secondary)]
	var flight = Flight.new()
	if not flight.configure(engine) or not flight.configure_resources({"max_ep": stats.max_ep, "current_ep": stats.max_ep}):
		return {}
	flight.configure_fuel_context(MAP_ID, 0, false)
	flight.weight_ratio = float(inventory.weight_profile().get("ratio", 0.0))
	var bounds: Dictionary = world.call("get_bounds")
	if not flight.configure_world(bounds.min, bounds.max):
		return {}
	flight.position = _spawn(pilots.size())
	var skills = Skills.new()
	if not skills.configure({"gear_id": GEAR_ID, "player": stats}):
		return {}
	skills.learn_base_skills() # Explicit pilot starter training; at level9 only FireShot.
	return {"id": pilot_id, "connected": false, "inventory": inventory, "flight": flight, "skills": skills,
		"profile": profile, "seq": -1, "controls": {}, "input_age": INPUT_TIMEOUT, "collision_wait": 0.0}


func remove_player(pilot_id: String) -> void:
	if not pilots.has(pilot_id):
		return
	pilots[pilot_id].connected = false
	pilots[pilot_id].controls = {}
	dirty = true
	_events.append({"type": "pilot_left", "pilot_id": pilot_id})


func submit_input(pilot_id: String, sequence: int, controls: Dictionary) -> Dictionary:
	if not pilots.has(pilot_id) or not bool(pilots[pilot_id].connected):
		return _failure("pilot_not_connected")
	if sequence < 0 or sequence > 9007199254740990 or sequence <= int(pilots[pilot_id].seq):
		return _failure("stale_input")
	var clean: Dictionary = {}
	for key: Variant in controls:
		if str(key) == "aim_direction":
			if not _vector_array(controls[key], 3):
				return _failure("invalid_aim_direction")
			var aim := _vec(controls[key])
			if aim.length_squared() < 0.98 or aim.length_squared() > 1.02:
				return _failure("invalid_aim_direction")
			clean["aim_direction"] = aim.normalized()
		elif str(key) in AXES:
			var value: Variant = controls[key]
			if not _finite(value) or absf(float(value)) > 1.0:
				return _failure("invalid_control_axis")
			clean[str(key)] = float(value)
		elif str(key) in BUTTONS:
			if not controls[key] is bool:
				return _failure("invalid_control_button")
			clean[str(key)] = controls[key]
		else:
			return _failure("untrusted_control_field")
	pilots[pilot_id].seq = sequence
	pilots[pilot_id].controls = clean
	pilots[pilot_id].input_age = 0.0
	return {"ok": true, "input_seq": sequence, "tick": tick}


func command(pilot_id: String, request_id: String, action: String, args: Dictionary) -> Dictionary:
	if not pilots.has(pilot_id) or not bool(pilots[pilot_id].connected):
		return _failure("pilot_not_connected")
	if not _request_identifier(request_id):
		return _failure("invalid_request_id")
	var key := pilot_id + "/" + request_id
	var fingerprint := JSON.stringify([action, _canonical(args)])
	if _commands.has(key):
		if str(_commands[key].fingerprint) != fingerprint:
			return _failure("request_id_conflict")
		var previous: Dictionary = _commands[key].result.duplicate(true)
		previous["replayed"] = true
		return previous
	if _commands.size() >= MAX_COMMANDS:
		# This is a bounded replay cache, not a lifetime command quota. The
		# server's SQLite receipt transaction is the durable replay boundary.
		# Dictionary iteration preserves insertion order, so discard the oldest.
		_commands.erase(_commands.keys()[0])
	var pilot: Dictionary = pilots[pilot_id]
	combat.activate_pilot(pilot_id)
	var result: Dictionary
	if action == "skill_use" and args.keys().size() == 1 and args.has("slot") and _integer(args.slot):
		result = pilot.skills.cast_slot(int(args.slot), combat)
		if bool(result.get("ok", false)):
			pilot.flight.set_skill_modifiers(pilot.skills.modifiers())
	elif action == "skill_assign" and args.keys().size() == 2 and _integer(args.get("slot")) and _integer(args.get("item_num")):
		result = pilot.skills.assign_slot(int(args.slot), int(args.item_num))
	elif action == "equip" and args.keys().size() == 2 and args.get("slot") is String and _integer(args.get("item_num")):
		result = pilot.inventory.equip_item(int(args.item_num), str(args.slot))
		if bool(result.get("ok", false)):
			_refresh_equipment(pilot)
	elif action == "allocate_stat" and args.keys().size() <= 2 and args.get("stat") is String and _integer(args.get("count", 1)):
		result = pilot.inventory.allocate_stat(str(args.stat), int(args.get("count", 1)))
		if bool(result.get("ok", false)):
			_refresh_equipment(pilot)
	else:
		result = _failure("command_unavailable_in_field")
	combat.store_pilot()
	# Do not return native ITEM internals from equip_item to the network boundary.
	result = result.duplicate(true)
	result.erase("item")
	result["request_id"] = request_id
	result["pilot_id"] = pilot_id
	result["tick"] = tick
	_commands[key] = {"fingerprint": fingerprint, "result": result.duplicate(true)}
	dirty = true
	_events.append({"type": "command_result", "pilot_id": pilot_id, "request_id": request_id, "ok": bool(result.get("ok", false))})
	return result


func _refresh_equipment(pilot: Dictionary) -> void:
	var inventory: RefCounted = pilot.inventory
	combat.equip_weapons(inventory.catalog[int(inventory.equipped.primary)], inventory.catalog[int(inventory.equipped.secondary)])
	var stats: Dictionary = inventory.combat_profile()
	combat.apply_player_stats(stats)
	pilot.skills.set_profile({"gear_id": GEAR_ID, "player": stats})
	pilot.flight.configure(inventory.catalog[int(inventory.equipped.engine)])
	pilot.flight.configure_resources({"max_ep": stats.max_ep})
	pilot.flight.weight_ratio = float(inventory.weight_profile().get("ratio", 0.0))


func advance(delta: float) -> void:
	if combat == null or not is_finite(delta) or delta <= 0.0:
		return
	_accumulator += minf(delta, 0.5)
	while _accumulator + 0.000000001 >= STEP:
		_tick()
		_accumulator = maxf(0.0, _accumulator - STEP)


func _tick() -> void:
	tick += 1
	var controls_by_pilot: Dictionary = {}
	var ids: Array = pilots.keys()
	ids.sort()
	for identifier: String in ids:
		var pilot: Dictionary = pilots[identifier]
		if not bool(pilot.connected):
			continue
		combat.activate_pilot(identifier)
		pilot.input_age = float(pilot.input_age) + STEP
		var controls: Dictionary = pilot.controls if float(pilot.input_age) <= INPUT_TIMEOUT else {}
		pilot.skills.advance(STEP, combat)
		pilot.flight.set_skill_modifiers(pilot.skills.modifiers())
		pilot.flight.movement_enabled = not bool(combat.player.dead)
		var from: Vector3 = pilot.flight.position
		pilot.flight.advance(controls, STEP)
		var resolution: Dictionary = world.call("resolve_motion", from, pilot.flight.position, {"radius": 4.0, "grounded": false})
		pilot.collision_wait = maxf(0.0, float(pilot.collision_wait) - STEP)
		if bool(resolution.get("collided", false)):
			var speed: float = absf(float(pilot.flight.speed))
			pilot.flight.resolve_collision(resolution.position, resolution.get("normal", Vector3.UP), str(resolution.get("kind", "terrain")))
			if float(pilot.collision_wait) <= 0.0:
				combat.damage_player(float(combat.player.max_hp) * _collision_rate(speed), "collision")
				pilot.collision_wait = 0.5
		combat.set_player_pose(pilot.flight.position, pilot.flight.forward())
		combat.store_pilot()
		controls_by_pilot[identifier] = controls.duplicate()
	combat.advance_shared(STEP, controls_by_pilot)
	for event: Dictionary in combat.drain_events():
		_process_event(event)
	# Every server movement/HP/resource transition is persistent room state.
	# The host may batch periodic writes; rewards/commands require immediate commit.
	dirty = true


func _process_event(event: Dictionary) -> void:
	var type := str(event.get("type", ""))
	var pilot_id := str(event.get("pilot_id", ""))
	if type == "hit" and pilots.has(pilot_id):
		var life_key := "%s/%d:%d" % [_room_id, int(event.id), int(event.get("target_life", 0))]
		if not _contributions.has(life_key):
			_contributions[life_key] = {}
		_contributions[life_key][pilot_id] = true
	elif type == "target_destroyed":
		var target: Dictionary = combat._target(int(event.id))
		var life_key := "%s/%d:%d" % [_room_id, int(event.id), int(target.get("life", 0))]
		if not _rewarded.has(life_key):
			_rewarded[life_key] = true
			for contributor: String in _contributions.get(life_key, {}):
				if not pilots.has(contributor):
					continue
				var reward_id := "online-pilot/" + life_key + "/" + contributor
				var inventory: RefCounted = pilots[contributor].inventory
				if inventory.apply_reward({"reward_id": reward_id, "credits": 10, "experience": 0}):
					combat.pilot_states[contributor].player.credits = inventory.credits
					_events.append({"type": "pilot_reward", "pilot_id": contributor, "reward_id": reward_id, "credits": 10, "monster_code": int(event.get("monster_code", 0)), "scope": "explicit_online_pilot_reward_not_native_drop_database"})
			_contributions.erase(life_key)
			dirty = true
	elif type == "player_respawned" and pilots.has(pilot_id):
		var flight: RefCounted = pilots[pilot_id].flight
		flight.reset()
		flight.position = _spawn(pilots.keys().find(pilot_id))
		combat.activate_pilot(pilot_id)
		combat.set_player_pose(flight.position, flight.forward())
		combat.store_pilot()
	_events.append(event.duplicate(true))


func snapshot(for_pilot_id: String = "") -> Dictionary:
	combat.store_pilot()
	var states: Array[Dictionary] = []
	var ids: Array = pilots.keys()
	ids.sort()
	for identifier: String in ids:
		var record: Dictionary = pilots[identifier]
		# Persistence retains departed identities; public room snapshots describe
		# live participants only. Historic pilots must not exhaust the frame budget.
		if not bool(record.connected) and identifier != for_pilot_id:
			continue
		var state: Dictionary = combat.pilot_states[identifier]
		var vitals: Dictionary = state.player
		var orientation: Quaternion = record.flight.orientation
		states.append({"id": identifier, "pilot_id": identifier, "connected": bool(record.connected), "gear_id": GEAR_ID,
			"position": _array(record.flight.position), "orientation": [orientation.x, orientation.y, orientation.z, orientation.w],
			"hp": vitals.hp, "max_hp": vitals.max_hp, "shield": vitals.shield, "max_shield": vitals.max_shield,
			"sp": record.skills.sp, "max_sp": record.skills.max_sp, "primary_ammo": vitals.primary_ammo, "secondary_ammo": vitals.secondary_ammo,
			"dead": vitals.dead, "respawn_remaining": vitals.respawn_remaining, "target_id": state.selected_id, "lock_progress": state.lock_progress,
			"flight": record.flight.snapshot() if identifier == for_pilot_id else {"speed": record.flight.speed, "boosting": record.flight.boosting, "boost_energy": record.flight.boost_energy}, "input_seq": int(record.seq)})
	var targets: Array[Dictionary] = []
	for target: Dictionary in combat.targets:
		targets.append({"id": int(target.id), "monster_code": int(target.monster_code), "position": _array(target.position), "velocity": _array(target.velocity), "hp": target.hp, "max_hp": target.max_hp, "shield": target.shield, "max_shield": target.max_shield, "dead": target.dead, "life": int(target.life), "respawn_remaining": target.respawn_remaining})
	var rounds: Array[Dictionary] = []
	for projectile: Dictionary in combat.projectiles:
		if rounds.size() >= 24:
			break # Snapshot visual budget only; all authoritative rounds still simulate.
		rounds.append({"id": int(projectile.id), "position": _array(projectile.position), "direction": _array(projectile.direction), "pilot_id": str(projectile.get("pilot_id", "")), "target_id": int(projectile.target_id), "item_num": int(projectile.weapon.item_num)})
	var result := {"schema_version": 1, "room_id": _room_id, "map_index": MAP_ID, "tick": tick, "elapsed": combat.elapsed, "max_players": _max_players, "pilots": states, "targets": targets, "projectiles": rounds, "projectile_count": combat.projectiles.size(), "scope": "authoritative_cooperative_pilot_IGEAR_map3002_no_original_MMO_protocol"}
	if pilots.has(for_pilot_id):
		var inventory: Dictionary = pilots[for_pilot_id].inventory.snapshot()
		inventory.erase("combat_profile")
		for entry: Dictionary in inventory.entries:
			for key: String in ["source", "native_parameters", "required_stats"]:
				entry.erase(key)
		result["self"] = {"pilot_id": for_pilot_id, "inventory": inventory, "skills": pilots[for_pilot_id].skills.snapshot(false), "input_seq": int(pilots[for_pilot_id].seq)}
	return result


func export_state() -> Dictionary:
	combat.store_pilot()
	var saved_pilots: Dictionary = {}
	for identifier: String in pilots:
		saved_pilots[identifier] = _export_pilot(identifier)
	return {"schema_version": 1, "map_index": MAP_ID, "room_id": _room_id, "config": config.duplicate(true), "tick": tick,
		"accumulator": _accumulator, "pilots": saved_pilots, "targets": _pack(combat.targets), "projectiles": _pack(combat.projectiles),
		"rng_state": combat._rng_state, "next_projectile_id": combat._next_projectile_id, "combat_elapsed": combat.elapsed,
		"combat_accumulator": combat._accumulator, "contributions": _contributions.duplicate(true), "rewarded": _rewarded.duplicate(true), "commands": _commands.duplicate(true)}


func _export_pilot(identifier: String) -> Dictionary:
	var pilot: Dictionary = pilots[identifier]
	return {"id": identifier, "inventory": pilot.inventory.export_state(), "skills": pilot.skills.export_state(),
		"flight": _capture_flight(pilot.flight), "combat": _pack(combat.pilot_states[identifier]), "seq": int(pilot.seq), "collision_wait": float(pilot.collision_wait)}


func import_state(state: Dictionary) -> bool:
	# Trusted server persistence only; transport must never expose this method.
	if int(state.get("schema_version", -1)) != 1 or int(state.get("map_index", -1)) != MAP_ID or str(state.get("room_id", "")) != _room_id or not state.get("pilots") is Dictionary or state.pilots.size() > 512:
		return false
	if not _integer(state.get("tick")) or int(state.tick) < 0 or not _integer(state.get("rng_state")) or int(state.rng_state) < 1 or int(state.rng_state) >= 2147483647 or not _integer(state.get("next_projectile_id")) or int(state.next_projectile_id) < 0:
		return false
	for field: String in ["accumulator", "combat_accumulator", "combat_elapsed"]:
		if not _finite(state.get(field)) or float(state[field]) < 0.0:
			return false
	if float(state.accumulator) > STEP + 0.000001 or float(state.combat_accumulator) > STEP + 0.000001 or not state.get("contributions") is Dictionary or not state.get("rewarded") is Dictionary or not state.get("commands") is Dictionary or state.commands.size() > MAX_COMMANDS:
		return false
	var candidate = get_script().new()
	if not candidate.configure(config, world):
		return false
	for identifier: Variant in state.pilots:
		if not identifier is String or not _identifier(identifier) or not state.pilots[identifier] is Dictionary:
			return false
		var record: Dictionary = candidate._new_pilot(identifier)
		record = candidate._restore_pilot_record(identifier, state.pilots[identifier], record)
		if record.is_empty() or not candidate.combat.register_pilot(identifier, record.profile):
			return false
		candidate.pilots[identifier] = record
		candidate.combat.pilot_states[identifier] = _unpack(state.pilots[identifier].combat)
		candidate.combat._current_pilot_id = ""
		candidate.combat.activate_pilot(identifier)
	var targets: Variant = _unpack(state.get("targets"))
	var rounds: Variant = _unpack(state.get("projectiles"))
	if not targets is Array or targets.size() != 3 or not rounds is Array or rounds.size() > 1024:
		return false
	for index in range(targets.size()):
		var target: Variant = targets[index]
		if not target is Dictionary or not _target_valid(target, candidate.combat.targets[index]):
			return false
	for round_value: Variant in rounds:
		if not round_value is Dictionary or not candidate.pilots.has(str(round_value.get("pilot_id", ""))) or not round_value.get("position") is Vector3 or not round_value.get("direction") is Vector3 or not _integer(round_value.get("target_id")) or int(round_value.target_id) < 0 or int(round_value.target_id) >= 3 or not round_value.get("weapon") is Dictionary:
			return false
		for field: String in ["speed", "remaining", "traveled"]:
			if not _finite(round_value.get(field)) or float(round_value[field]) < 0.0:
				return false
	combat = candidate.combat
	pilots = candidate.pilots
	combat.targets.assign(targets)
	combat.projectiles.assign(rounds)
	combat._rng_state = int(state.rng_state)
	combat._next_projectile_id = int(state.next_projectile_id)
	combat.elapsed = float(state.combat_elapsed)
	combat._accumulator = float(state.combat_accumulator)
	combat._current_pilot_id = ""
	combat._shared_active_ids.clear()
	tick = int(state.tick)
	_accumulator = float(state.accumulator)
	_contributions = state.contributions.duplicate(true)
	_rewarded = state.rewarded.duplicate(true)
	_commands = state.commands.duplicate(true)
	_events.clear()
	dirty = false
	return true


func _restore_pilot_record(identifier: String, saved: Dictionary, record: Dictionary) -> Dictionary:
	if record.is_empty() or str(saved.get("id", "")) != identifier or not saved.get("inventory") is Dictionary or not saved.get("skills") is Dictionary or not saved.get("flight") is Dictionary or not saved.get("combat") is Dictionary or not _integer(saved.get("seq")) or int(saved.seq) < -1:
		return {}
	if not bool(record.inventory.import_state(saved.inventory).get("ok", false)) or str(record.inventory.gear_id) != GEAR_ID:
		return {}
	for slot: String in ["primary", "secondary", "engine"]:
		if not record.inventory.equipped.has(slot):
			return {}
	var stats: Dictionary = record.inventory.combat_profile()
	record.profile.player = stats
	record.profile.primary = record.inventory.catalog[int(record.inventory.equipped.primary)]
	record.profile.secondary = record.inventory.catalog[int(record.inventory.equipped.secondary)]
	record.skills.set_profile({"gear_id": GEAR_ID, "player": stats})
	if not record.skills.import_state(saved.skills) or not _restore_flight(record.flight, saved.flight):
		return {}
	var shared: Variant = _unpack(saved.combat)
	if not shared is Dictionary or not shared.get("player") is Dictionary or not shared.get("weapons") is Dictionary or not shared.get("profile") is Dictionary or not shared.get("skill_modifiers") is Dictionary:
		return {}
	var player: Dictionary = shared.player
	for field: String in ["hp", "max_hp", "shield", "max_shield", "primary_ammo", "secondary_ammo", "primary_cooldown", "secondary_cooldown", "primary_heat_remaining", "secondary_heat_remaining", "respawn_remaining"]:
		if not _finite(player.get(field)) or float(player[field]) < 0.0:
			return {}
	if not is_equal_approx(float(player.max_hp), float(stats.max_hp)) or not is_equal_approx(float(player.max_shield), float(stats.max_shield)) or float(player.hp) > float(player.max_hp) or float(player.shield) > float(player.max_shield) or not player.get("dead") is bool or bool(player.dead) != (float(player.hp) <= 0.0):
		return {}
	if not player.get("position") is Vector3 or not player.get("forward") is Vector3 or not _finite(shared.get("lock_progress")) or float(shared.lock_progress) < 0.0 or float(shared.lock_progress) > 1.0:
		return {}
	if not _integer(shared.get("selected_id")) or not shared.get("previous_next") is bool or int(player.get("credits", -1)) != int(record.inventory.credits):
		return {}
	var wait: Variant = saved.get("collision_wait", 0.0)
	if not _finite(wait) or float(wait) < 0.0 or float(wait) > 0.5:
		return {}
	record.seq = int(saved.seq)
	record.collision_wait = float(wait)
	record.connected = false
	record.controls = {}
	record.input_age = INPUT_TIMEOUT
	return record


static func _target_valid(target: Dictionary, native_target: Dictionary) -> bool:
	for field: String in ["id", "monster_code", "max_hp", "max_shield"]:
		if not target.has(field) or target[field] != native_target[field]:
			return false
	for field: String in ["position", "spawn_position", "velocity"]:
		if not target.get(field) is Vector3:
			return false
	for field: String in ["hp", "shield", "respawn_remaining", "attack_cooldown", "life"]:
		if not _finite(target.get(field)) or float(target[field]) < 0.0:
			return false
	return target.get("dead") is bool and bool(target.dead) == (float(target.hp) <= 0.0) and float(target.hp) <= float(target.max_hp) and float(target.shield) <= float(target.max_shield)


static func _capture_flight(flight: RefCounted) -> Dictionary:
	var result: Dictionary = {}
	for property: Dictionary in flight.get_property_list():
		if (int(property.usage) & PROPERTY_USAGE_SCRIPT_VARIABLE) != 0:
			result[str(property.name)] = _pack(flight.get(str(property.name)))
	return result


static func _restore_flight(flight: RefCounted, data: Dictionary) -> bool:
	var expected := _capture_flight(flight)
	if data.size() != expected.size():
		return false
	for key: Variant in data:
		if not expected.has(key):
			return false
		var original: Variant = flight.get(str(key))
		var value: Variant = _unpack(data[key])
		if value == null or (typeof(original) != typeof(value) and not (_finite(original) and _finite(value))):
			return false
		flight.set(str(key), value)
	return (flight.position as Vector3).is_finite() and (flight.orientation as Quaternion).is_finite() and absf((flight.orientation as Quaternion).length() - 1.0) < 0.001 and float(flight.fuel_fraction) >= 0.0 and float(flight.fuel_fraction) <= 1.0


func drain_events() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for event: Dictionary in _events:
		result.append(_json_event(event))
	_events.clear()
	return result


func _spawn(index: int) -> Vector3:
	var position := Vector3(float(index % 8) * 18.0, 105.0, 170.0)
	var ground := float(world.call("sample_ground_height", position.x, position.z, true))
	if is_finite(ground):
		position.y = maxf(position.y, ground + 100.0)
	return position


func _connected_count() -> int:
	var result := 0
	for pilot: Dictionary in pilots.values():
		if bool(pilot.connected):
			result += 1
	return result


static func _pack(value: Variant) -> Variant:
	if value is Vector3:
		var bits := PackedByteArray()
		bits.resize(12)
		bits.encode_float(0, value.x)
		bits.encode_float(4, value.y)
		bits.encode_float(8, value.z)
		return {"_vector3": _array(value), "_bits": bits.hex_encode()}
	if value is Quaternion:
		var bits := PackedByteArray()
		bits.resize(16)
		for index in range(4):
			bits.encode_float(index * 4, value[index])
		return {"_quaternion": [value.x, value.y, value.z, value.w], "_bits": bits.hex_encode()}
	if value is Dictionary:
		var result: Dictionary = {}
		for key: Variant in value:
			result[str(key)] = _pack(value[key])
		return result
	if value is Array:
		var result: Array = []
		for element: Variant in value:
			result.append(_pack(element))
		return result
	return value


static func _unpack(value: Variant) -> Variant:
	if value is Dictionary:
		if value.has("_vector3"):
			if value.size() > 2 or not _vector_array(value._vector3, 3):
				return null
			if value.has("_bits"):
				if not value._bits is String or value._bits.length() != 24 or not value._bits.is_valid_hex_number(false):
					return null
				var bits: PackedByteArray = value._bits.hex_decode()
				var vector := Vector3(bits.decode_float(0), bits.decode_float(4), bits.decode_float(8))
				return vector if vector.is_finite() else null
			return _vec(value._vector3)
		if value.has("_quaternion"):
			if value.size() > 2 or not _vector_array(value._quaternion, 4):
				return null
			if value.has("_bits"):
				if not value._bits is String or value._bits.length() != 32 or not value._bits.is_valid_hex_number(false):
					return null
				var bits: PackedByteArray = value._bits.hex_decode()
				var quaternion := Quaternion(bits.decode_float(0), bits.decode_float(4), bits.decode_float(8), bits.decode_float(12))
				return quaternion if quaternion.is_finite() else null
			var row: Array = value._quaternion
			return Quaternion(float(row[0]), float(row[1]), float(row[2]), float(row[3]))
		var result: Dictionary = {}
		for key: Variant in value:
			result[key] = _unpack(value[key])
		return result
	if value is Array:
		var result: Array = []
		for element: Variant in value:
			result.append(_unpack(element))
		return result
	if value is float and not is_finite(value):
		return null
	return value


static func _json_event(value: Variant) -> Variant:
	if value is Vector3:
		return _array(value)
	if value is Dictionary:
		var result: Dictionary = {}
		for key: Variant in value:
			result[str(key)] = _json_event(value[key])
		return result
	if value is Array:
		var result: Array = []
		for element: Variant in value:
			result.append(_json_event(element))
		return result
	return value


static func _canonical(value: Variant) -> Variant:
	if value is float and _integer(value):
		return int(value)
	if value is Dictionary:
		var keys: Array = value.keys()
		keys.sort()
		var result: Dictionary = {}
		for key: Variant in keys:
			result[str(key)] = _canonical(value[key])
		return result
	if value is Array:
		var result: Array = []
		for element: Variant in value:
			result.append(_canonical(element))
		return result
	return value


static func _read(path: String) -> Dictionary:
	var result: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return result if result is Dictionary else {}


static func _starter_catalog() -> Array:
	# The online pilot has no shops/drops and owns only this explicit five-item
	# kit. Load/enrich these records instead of duplicating16,079 definitions
	# for every connected or retained pilot in a small server process.
	if _starter_rows.is_empty():
		var catalog := _read("res://assets/original_library/catalogs/items.json")
		for row: Dictionary in catalog.get("records", []):
			if int(row.get("ItemNum", 0)) in [7000040, 7901000, 7002570, 8013100, 7000970]:
				_starter_rows.append(row.duplicate(true))
	return _starter_rows


static func _identifier(value: String) -> bool:
	if value.is_empty() or value.length() > 96:
		return false
	for character: String in value:
		if character not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.:@":
			return false
	return true


static func _request_identifier(value: String) -> bool:
	# Same public contract as SQLiteStore.valid_request_id, without depending
	# on a server-only script from the portable shared simulation project.
	if value.is_empty() or value.length() > 128:
		return false
	for character: String in value:
		if character not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.:-":
			return false
	return true


static func _finite(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))


static func _integer(value: Variant) -> bool:
	return _finite(value) and float(value) == floorf(float(value)) and absf(float(value)) < 9007199254740991.0


static func _vector_array(value: Variant, count: int) -> bool:
	if not value is Array or value.size() != count:
		return false
	for component: Variant in value:
		if not _finite(component) or absf(float(component)) > 10000000.0:
			return false
	return true


static func _array(value: Vector3) -> Array:
	return [value.x, value.y, value.z]


static func _vec(value: Array) -> Vector3:
	return Vector3(float(value[0]), float(value[1]), float(value[2]))


static func _collision_rate(speed: float) -> float:
	for pair: Array in [[150.0, 0.1], [210.0, 0.15], [270.0, 0.2], [330.0, 0.25], [390.0, 0.3], [450.0, 0.35], [510.0, 0.4], [570.0, 0.45]]:
		if speed < float(pair[0]):
			return float(pair[1])
	return 0.5


static func _failure(error: String) -> Dictionary:
	return {"ok": false, "error": error}
