class_name ArenaModel
extends RefCounted
## Small authoritative cooperative room. Client messages contain controls only.
## One shared CombatModel owns all NPCs, missiles, RNG and simulation ticks.

const Combat = preload("res://scripts/combat_model.gd")
const Flight = preload("res://scripts/flight_model.gd")
const Inventory = preload("res://scripts/inventory_model.gd")
const Skills = preload("res://scripts/skill_model.gd")
const NativeData = preload("res://scripts/native_server_data.gd")
const STEP := 1.0 / 120.0
const GEAR_ID := "12003100" # Default for pre-class-selection clients and v0.8 saved pilots.
const GEAR_IDS := ["12000100", "12001100", "12002100", "12003100"]
# Explicit reconstruction starter kits; ITEM identities/requirements remain native.
# These are not recovered character-creation grants from the original server.
const STARTER_KITS := {
	"12000100": {"primary": 7000040, "secondary": 7901000, "armor": 8010100, "radar": 7000970},
	"12001100": {"primary": 7000040, "secondary": 7901000, "armor": 8011100, "radar": 7000970},
	"12002100": {"primary": 7000050, "secondary": 7900440, "armor": 8012100, "radar": 7009310},
	"12003100": {"primary": 7000040, "secondary": 7901000, "armor": 8013100, "radar": 7000970},
}
const MAP_ID := 3002
const AXES := ["pitch", "yaw", "roll", "ground_throttle"]
const BUTTONS := ["boost", "brake", "primary", "secondary", "target_next", "unit_stop"]
const INPUT_TIMEOUT := 0.35
const MAX_COMMANDS := 4096
const NPC_STATE_FIELDS := ["npc_weapon_options", "npc_selected_option", "npc_option_ready_at", "npc_cycle_started", "npc_preparing", "npc_prepare_remaining", "npc_burst_remaining", "npc_burst_wait", "respawn_seconds"]
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
var _legacy_contribution_lives: Dictionary = {}
var _native_rewards: RefCounted
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
	if _native.is_empty() or _encounter.is_empty():
		return false
	for gear: String in GEAR_IDS:
		if not _engines.get("by_gear", {}).has(gear):
			return false
	if _starter_catalog().is_empty():
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
	_legacy_contribution_lives.clear()
	_rewarded.clear()
	_commands.clear()
	_events.clear()
	tick = 0
	_accumulator = 0.0
	var native_items: Dictionary = {}
	for item: Dictionary in _starter_catalog():
		native_items[int(item.ItemNum)] = item
	_native_rewards = NativeData.new()
	if not bool(_native_rewards.load_npc_catalog(native_items, {int(_native.monster.MonsterUnitKind): {}}).get("ok", false)):
		return false
	var npc_profile: Dictionary = _native_rewards.npc_attack_profile(int(_native.monster.MonsterUnitKind))
	if not bool(npc_profile.get("ok", false)) or npc_profile.get("options", []).is_empty():
		return false
	var origin := _spawn(0)
	for row: Dictionary in _encounter.get("maps", {}).get(str(MAP_ID), {}).get("targets", []):
		var monster: Dictionary = _native.monster.duplicate(true)
		monster.merge(_encounter.get("monster_overrides", {}), true)
		monster.npc_weapon_options = npc_profile.options.duplicate(true)
		monster.weapon = npc_profile.options[0].item.duplicate(true)
		monster.radius = 12.0 # Explicit headless encounter collision envelope, source model not loaded.
		var position: Vector3 = origin + _vec(row.get("offset", [0, 0, -240]))
		position.y = maxf(position.y, float(world.call("sample_ground_height", position.x, position.z, true)) + 60.0)
		combat.add_target(monster, position)
	if combat.targets.size() != 3:
		return false
	var monster_codes: Dictionary = {}
	for target: Dictionary in combat.targets:
		monster_codes[int(target.monster_code)] = {}
	for code: int in monster_codes:
		if int(_native_rewards.monster_experience(code)) < 0:
			return false
	dirty = true
	return true


func _base_profile() -> Dictionary:
	return {"primary": _native.get("primary", {}), "secondary": _native.get("secondary", {}),
		"player": {"max_hp": 600.0, "max_shield": 400.0, "level": 9},
		"primary_ammo": 1000, "secondary_ammo": 48, "encounter_id": _room_id + ":3002"}


func add_player(pilot_id: String, saved: Dictionary = {}, requested_gear_id: String = "") -> Dictionary:
	if not requested_gear_id.is_empty() and requested_gear_id not in GEAR_IDS:
		return _failure("invalid_gear_class")
	if combat == null or not _identifier(pilot_id):
		return _failure("invalid_pilot")
	if pilots.has(pilot_id) and bool(pilots[pilot_id].connected):
		return _failure("pilot_already_connected")
	if _connected_count() >= _max_players:
		return _failure("room_full")
	if pilots.has(pilot_id):
		if not requested_gear_id.is_empty() and requested_gear_id != str(pilots[pilot_id].inventory.gear_id):
			return _failure("character_gear_locked")
		pilots[pilot_id].connected = true
		pilots[pilot_id].controls = {}
		pilots[pilot_id].input_age = INPUT_TIMEOUT
		dirty = true
		_events.append({"type": "pilot_joined", "pilot_id": pilot_id, "returning": true})
		return {"ok": true, "pilot_id": pilot_id, "returning": true, "input_seq": int(pilots[pilot_id].seq)}
	if not saved.is_empty() and not saved.get("inventory") is Dictionary:
		return _failure("invalid_saved_pilot")
	var initial_gear := str(saved.get("inventory", {}).get("gear_id", GEAR_ID)) if not saved.is_empty() else (GEAR_ID if requested_gear_id.is_empty() else requested_gear_id)
	if not requested_gear_id.is_empty() and requested_gear_id != initial_gear:
		return _failure("character_gear_locked")
	var record := _new_pilot(pilot_id, initial_gear)
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
		combat.pilot_states[pilot_id] = record._restored_combat
		record.erase("_restored_combat")
		combat._current_pilot_id = ""
		combat.activate_pilot(pilot_id)
	else:
		combat.set_player_pose(record.flight.position, record.flight.forward())
		combat.player["credits"] = record.inventory.credits
		combat.player["experience"] = record.inventory.experience
		combat.player["sp"] = record.skills.sp
		combat.player["max_sp"] = record.skills.max_sp
		_sync_flight_resources(record)
		combat.store_pilot()
	record.connected = true
	dirty = true
	_events.append({"type": "pilot_joined", "pilot_id": pilot_id, "returning": not saved.is_empty()})
	return {"ok": true, "pilot_id": pilot_id, "returning": not saved.is_empty(), "input_seq": int(record.seq)}


func _new_pilot(pilot_id: String, selected_gear: String = GEAR_ID) -> Dictionary:
	if selected_gear not in GEAR_IDS:
		return {}
	var inventory = Inventory.new()
	if not inventory.configure(_starter_catalog()):
		return {}
	var starter_icons: Dictionary = {}
	for item_num: Variant in inventory.catalog:
		starter_icons[item_num] = str(inventory._icons.get(item_num, ""))
	inventory._icons = starter_icons
	inventory.gear_id = selected_gear
	inventory.set_starting_level(9)
	var engine: Dictionary = _engines.by_gear[selected_gear]
	var starter: Dictionary = STARTER_KITS[selected_gear].duplicate()
	starter["engine"] = int(engine.ItemNum)
	for slot: String in starter:
		if not inventory.add_item(int(starter[slot])) or not bool(inventory.equip_item(int(starter[slot]), slot).get("ok", false)):
			return {}
	var stats: Dictionary = inventory.combat_profile()
	var profile := _base_profile()
	profile.player = stats
	profile["gear_id"] = selected_gear
	profile.primary = inventory.catalog[int(starter.primary)]
	profile.secondary = inventory.catalog[int(starter.secondary)]
	var flight = Flight.new()
	if not flight.load_gear_profile(selected_gear) or not flight.configure_resources({"max_ep": stats.max_ep, "current_ep": stats.max_ep}):
		return {}
	flight.configure_fuel_context(MAP_ID, 0, false)
	flight.weight_ratio = float(inventory.weight_profile().get("ratio", 0.0))
	var bounds: Dictionary = world.call("get_bounds")
	if not flight.configure_world(bounds.min, bounds.max):
		return {}
	flight.position = _spawn(pilots.size())
	var skills = Skills.new()
	if not skills.configure({"gear_id": selected_gear, "player": stats}):
		return {}
	skills.learn_base_skills() # Explicit reconstruction starter training, not native account entitlement.
	return {"id": pilot_id, "connected": false, "inventory": inventory, "flight": flight, "skills": skills,
		"profile": profile, "xp_fraction": 0.0, "seq": -1, "controls": {}, "input_age": INPUT_TIMEOUT, "collision_wait": 0.0}


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
	if action == "toggle_landing" and args.is_empty():
		result = _toggle_landing(pilot)
	elif action == "toggle_siege" and args.is_empty():
		if bool(combat.player.dead) or not pilot.flight.set_siege(not bool(pilot.flight.siege)):
			result = _failure("siege_requires_live_grounded_agear")
		else:
			result = {"ok": true, "siege": bool(pilot.flight.siege)}
	elif action == "skill_learn":
		# A catalog and enough SPI do not imply contact with an original school.
		result = _failure("native_school_contact_unavailable")
	elif action == "skill_use" and args.keys().size() == 1 and args.has("slot") and _integer(args.slot):
		_sync_flight_resources(pilot)
		result = pilot.skills.cast_slot(int(args.slot), combat, {"airborne": bool(pilot.flight.airborne)})
		if bool(result.get("ok", false)):
			if result.has("ep_current") and result.has("ep_max"):
				pilot.flight.set_fuel_state(float(result.ep_current), float(result.ep_max))
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


func _sync_flight_resources(pilot: Dictionary) -> void:
	# Flight owns EP; clients never supply resource totals or grounded context.
	combat.player["max_ep"] = float(pilot.flight.fuel_capacity)
	combat.player["ep"] = float(pilot.flight.fuel_fraction) * float(pilot.flight.fuel_capacity)


func _toggle_landing(pilot: Dictionary) -> Dictionary:
	if bool(combat.player.dead):
		return _failure("pilot_dead")
	var flight: RefCounted = pilot.flight
	if not bool(flight.airborne) or bool(flight.landing):
		return {"ok": true, "mode": "taking_off"} if flight.take_off() else _failure("takeoff_unavailable")
	if not world.has_method("probe_landing"):
		return _failure("native_landing_query_unavailable")
	var contact: Dictionary = world.call("probe_landing", flight.position, 4.0, 180.0, str(pilot.inventory.gear_id))
	if not bool(contact.get("ok", false)):
		return _failure(str(contact.get("reason", "landing_surface_unavailable")))
	if not flight.begin_landing(contact.position, contact.get("normal", Vector3.UP)):
		return _failure("landing_state_unavailable")
	return {"ok": true, "mode": "landing"}


func _update_surface_contact(flight: RefCounted) -> void:
	if bool(flight.landing) and world.has_method("probe_landing"):
		var contact: Dictionary = world.call("probe_landing", flight.position, 4.0, 180.0, str(flight.gear_id))
		if bool(contact.get("ok", false)):
			flight.update_landing_contact(contact.position, contact.get("normal", Vector3.UP))
		else:
			flight.take_off()
	elif not bool(flight.airborne) and world.has_method("ground_contact"):
		var contact: Dictionary = world.call("ground_contact", flight.position, 4.0)
		if bool(contact.get("ok", false)):
			flight.set_ground_contact(contact.position, contact.get("normal", Vector3.UP))
		else:
			flight.take_off()


func _refresh_equipment(pilot: Dictionary) -> void:
	var inventory: RefCounted = pilot.inventory
	combat.equip_weapons(inventory.catalog[int(inventory.equipped.primary)], inventory.catalog[int(inventory.equipped.secondary)])
	pilot.flight.configure(inventory.catalog[int(inventory.equipped.engine)])
	_refresh_native_stats(pilot)


func _refresh_native_stats(pilot: Dictionary) -> void:
	# XP/level changes update attributes without re-equipping identical weapons:
	# equip_weapons intentionally clears target lock when equipment changes.
	var inventory: RefCounted = pilot.inventory
	var stats: Dictionary = inventory.combat_profile()
	pilot.profile["player"] = stats.duplicate(true)
	combat._initial_profile["player"] = stats.duplicate(true)
	combat.apply_player_stats(stats)
	pilot.skills.set_profile({"gear_id": str(inventory.gear_id), "player": stats})
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
		_update_surface_contact(pilot.flight)
		var from: Vector3 = pilot.flight.position
		pilot.flight.advance(controls, STEP)
		var resolution: Dictionary = world.call("resolve_motion", from, pilot.flight.position, {"radius": 4.0, "grounded": not bool(pilot.flight.airborne)})
		pilot.collision_wait = maxf(0.0, float(pilot.collision_wait) - STEP)
		if bool(resolution.get("collided", false)):
			var speed: float = absf(float(pilot.flight.speed))
			var impact: Dictionary = pilot.flight.resolve_collision(resolution.position, resolution.get("normal", Vector3.UP), str(resolution.get("kind", "terrain")))
			if float(impact.get("damage_scale", 1.0)) > 0.0 and float(pilot.collision_wait) <= 0.0:
				combat.damage_player(float(combat.player.max_hp) * _collision_rate(speed), "collision")
				pilot.collision_wait = 0.5
		elif not bool(pilot.flight.airborne):
			pilot.flight.set_ground_contact(resolution.position, resolution.get("normal", Vector3.UP))
		combat.set_player_pose(pilot.flight.position, pilot.flight.forward())
		_sync_flight_resources(pilot)
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
		# Combat.apply_damage clamps hp_damage/shield_damage to the actual
		# remaining HP/DP. Nominal attack damage can include overkill and must
		# never buy a larger share of the monster's native experience.
		var damage: Variant = event.get("damage")
		var hp_damage: Variant = event.get("hp_damage")
		var shield_damage: Variant = event.get("shield_damage")
		if _finite(damage) and _finite(hp_damage) and _finite(shield_damage) and float(hp_damage) >= 0.0 and float(shield_damage) >= 0.0:
			var actual := minf(float(damage), float(hp_damage) + float(shield_damage))
			var life_key := "%s/%d:%d" % [_room_id, int(event.id), int(event.get("target_life", 0))]
			if actual > 0.0 and not _rewarded.has(life_key):
				if not _contributions.has(life_key):
					_contributions[life_key] = {}
				_contributions[life_key][pilot_id] = float(_contributions[life_key].get(pilot_id, 0.0)) + actual
	elif type == "target_destroyed":
		var target: Dictionary = combat._target(int(event.id))
		if target.is_empty():
			return
		var life_key := "%s/%d:%d" % [_room_id, int(event.id), int(target.get("life", 0))]
		if not _rewarded.has(life_key):
			_rewarded[life_key] = true
			_reward_contributors(life_key, int(target.monster_code))
			_contributions.erase(life_key)
			_legacy_contribution_lives.erase(life_key)
			dirty = true
	elif type == "player_respawned" and pilots.has(pilot_id):
		var flight: RefCounted = pilots[pilot_id].flight
		flight.reset()
		flight.position = _spawn(pilots.keys().find(pilot_id))
		combat.activate_pilot(pilot_id)
		combat.set_player_pose(flight.position, flight.forward())
		combat.store_pilot()
	_events.append(event.duplicate(true))


func _reward_contributors(life_key: String, monster_code: int) -> void:
	var contributions: Dictionary = _contributions.get(life_key, {})
	var total_damage := 0.0
	for amount: Variant in contributions.values():
		total_damage += float(amount)
	var base_xp := int(_native_rewards.monster_experience(monster_code))
	var legacy := _legacy_contribution_lives.has(life_key)
	for contributor: String in contributions:
		if not pilots.has(contributor):
			continue
		var pilot: Dictionary = pilots[contributor]
		var inventory: RefCounted = pilot.inventory
		var share := 0.0
		if base_xp >= 0 and not legacy and total_damage > 0.0:
			# EXPDivisionManager.cpp260: Experience * contributorDamage/totalDamage
			# for non-party pilots. No party/nation/premium multiplier is inferred.
			share = float(base_xp) * float(contributions[contributor]) / total_damage
		var accumulated: float = float(pilot.xp_fraction) + share
		var whole_xp := int(floorf(accumulated))
		var fraction: float = accumulated - float(whole_xp)
		var reward_id := "online-pilot/" + life_key + "/" + contributor
		# SPI10 remains the explicit cooperative-room policy. Original drop
		# ownership/party rules are separate from recovered base monster XP.
		if inventory.apply_reward({"reward_id": reward_id, "credits": 10, "experience": whole_xp}):
			pilot.xp_fraction = fraction
			combat.activate_pilot(contributor)
			_refresh_native_stats(pilot)
			pilot.skills.sync_combat(combat)
			_sync_flight_resources(pilot)
			combat.player["credits"] = inventory.credits
			combat.player["experience"] = inventory.experience
			combat.store_pilot()
			_events.append({"type": "pilot_reward", "pilot_id": contributor, "reward_id": reward_id,
				"credits": 10, "experience": whole_xp, "experience_share": share, "experience_fraction": fraction,
				"damage_share": 0.0 if legacy or total_damage <= 0.0 else float(contributions[contributor]) / total_damage,
				"monster_code": monster_code, "native_base_experience": maxi(0, base_xp), "source_sha256": NativeData.SOURCE_SHA,
				"experience_policy": "legacy_live_encounter_missing_damage_no_xp" if legacy else "native_nonparty_damage_share;integer_ledger_fraction_carry",
				"credits_policy": "explicit_room_10_SPI_per_contributor_not_native_drops"})


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
		states.append({"id": identifier, "pilot_id": identifier, "connected": bool(record.connected), "gear_id": str(record.inventory.gear_id),
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
		rounds.append({"id": int(projectile.id), "position": _array(projectile.position), "direction": _array(projectile.direction), "pilot_id": str(projectile.get("pilot_id", "")), "target_id": int(projectile.target_id), "item_num": int(projectile.weapon.item_num), "hostile": bool(projectile.get("hostile", false))})
	var result := {"schema_version": 1, "room_id": _room_id, "map_index": MAP_ID, "tick": tick, "elapsed": combat.elapsed, "max_players": _max_players, "pilots": states, "targets": targets, "projectiles": rounds, "projectile_count": combat.projectiles.size(), "scope": "authoritative_cooperative_four_GEAR_map3002_no_original_MMO_protocol", "gear_classes": GEAR_IDS.duplicate(), "character_policy": "immutable_first_creation_class;explicit_level9_starter_kit_not_original_account_data"}
	if pilots.has(for_pilot_id):
		var inventory: Dictionary = pilots[for_pilot_id].inventory.snapshot()
		inventory.erase("combat_profile")
		inventory["equip_available"] = true
		inventory["allocate_stats_available"] = true
		inventory["experience_fraction"] = float(pilots[for_pilot_id].xp_fraction)
		for entry: Dictionary in inventory.entries:
			for key: String in ["source", "native_parameters", "required_stats"]:
				entry.erase(key)
		var skills: Dictionary = pilots[for_pilot_id].skills.snapshot(false)
		skills["learned_rows"] = _learned_skill_rows(pilots[for_pilot_id].skills)
		skills["assignment_available"] = true
		skills["learning_available"] = false
		skills["learning_reason"] = "native_school_contact_unavailable"
		skills["local_policy"] = "Explicit server starter training; native school contact unavailable in this room."
		result["self"] = {"pilot_id": for_pilot_id, "inventory": inventory, "skills": skills, "input_seq": int(pilots[for_pilot_id].seq)}
	return result


static func _learned_skill_rows(skills: RefCounted) -> Array[Dictionary]:
	# Send owned ranks only, not the full native catalog on every 15Hz frame.
	var rows: Array[Dictionary] = []
	var ids: Array = skills.learned.keys()
	ids.sort()
	for item_num: Variant in ids:
		var record: Dictionary = skills.definitions[int(item_num)]
		rows.append({"id": int(item_num), "item_num": int(item_num), "name": str(record.ItemName),
			"learned": true, "learnable": false, "supported": str(record.blocked_reason).is_empty(),
			"min_level": int(record.get("ReqMinLevel", 0)), "level": int(record.get("SkillLevel", 1)),
			"cost": int(record.get("Price", 0)), "sp_cost": skills._sp_cost(record), "iconitem": int(item_num)})
	return rows


func export_state() -> Dictionary:
	combat.store_pilot()
	var saved_pilots: Dictionary = {}
	for identifier: String in pilots:
		saved_pilots[identifier] = _export_pilot(identifier)
	return {"schema_version": 1, "combat_state_version": 2, "map_index": MAP_ID, "room_id": _room_id, "config": config.duplicate(true), "tick": tick,
		"accumulator": _accumulator, "pilots": saved_pilots, "targets": _pack(combat.targets), "target_resource_bits": _capture_target_resource_bits(), "projectiles": _pack(combat.projectiles),
		"rng_state": combat._rng_state, "next_projectile_id": combat._next_projectile_id, "combat_elapsed": combat.elapsed,
		"combat_accumulator": combat._accumulator, "contributions_version": 2, "contributions": _contributions.duplicate(true), "contribution_bits": _capture_contribution_bits(), "legacy_contribution_lives": _legacy_contribution_lives.duplicate(true), "rewarded": _rewarded.duplicate(true), "commands": _commands.duplicate(true)}


func _export_pilot(identifier: String) -> Dictionary:
	var pilot: Dictionary = pilots[identifier]
	return {"id": identifier, "combat_state_version": 2, "inventory": pilot.inventory.export_state(), "skills": pilot.skills.export_state(),
		"flight": _capture_flight(pilot.flight), "combat": _pack(combat.pilot_states[identifier]), "xp_fraction": float(pilot.xp_fraction), "xp_fraction_bits": _double_bits(float(pilot.xp_fraction)), "seq": int(pilot.seq), "collision_wait": float(pilot.collision_wait)}


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
	var combat_version: Variant = state.get("combat_state_version", 1)
	if not _integer(combat_version) or int(combat_version) not in [1, 2]:
		return false
	var candidate = get_script().new()
	if not candidate.configure(config, world):
		return false
	for identifier: Variant in state.pilots:
		if not identifier is String or not _identifier(identifier) or not state.pilots[identifier] is Dictionary or not state.pilots[identifier].get("inventory") is Dictionary:
			return false
		if int(combat_version) == 2 and state.pilots[identifier].get("combat_state_version", 1) != 2:
			return false
		var saved_gear := str(state.pilots[identifier].get("inventory", {}).get("gear_id", GEAR_ID))
		var record: Dictionary = candidate._new_pilot(identifier, saved_gear)
		record = candidate._restore_pilot_record(identifier, state.pilots[identifier], record)
		if record.is_empty() or not candidate.combat.register_pilot(identifier, record.profile):
			return false
		candidate.pilots[identifier] = record
		candidate.combat.pilot_states[identifier] = record._restored_combat
		record.erase("_restored_combat")
		candidate.combat._current_pilot_id = ""
		candidate.combat.activate_pilot(identifier)
	var targets: Variant = _unpack(state.get("targets"))
	var rounds: Variant = _unpack(state.get("projectiles"))
	if not targets is Array or targets.size() != 3 or not rounds is Array or rounds.size() > 1024:
		return false
	var target_bits: Variant = state.get("target_resource_bits", [])
	if not target_bits is Array or (not target_bits.is_empty() and target_bits.size() != targets.size()):
		return false
	for index in range(targets.size()):
		var target: Variant = targets[index]
		if not target is Dictionary:
			return false
		if not target_bits.is_empty():
			if not target_bits[index] is Dictionary or target_bits[index].size() != 2:
				return false
			for field: String in ["hp", "shield"]:
				if not _finite(target.get(field)):
					return false
				var exact: Variant = _double_from_bits(float(target[field]), target_bits[index].get(field))
				if exact == null:
					return false
				target[field] = exact
		if not candidate._restore_npc_fields(target, candidate.combat.targets[index], int(combat_version)) or not _target_valid(target, candidate.combat.targets[index]):
			return false
	var projectile_ids: Dictionary = {}
	for round_value: Variant in rounds:
		if not round_value is Dictionary or not candidate._restore_projectile(round_value, targets, int(combat_version), int(state.next_projectile_id)) or projectile_ids.has(int(round_value.id)):
			return false
		projectile_ids[int(round_value.id)] = true
	var contribution_state: Dictionary = candidate._restore_contributions(state, targets)
	if not bool(contribution_state.get("ok", false)):
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
	_contributions = contribution_state.contributions
	_legacy_contribution_lives = contribution_state.legacy_lives
	_rewarded = state.rewarded.duplicate(true)
	_commands = state.commands.duplicate(true)
	_events.clear()
	dirty = false
	return true


func _restore_pilot_record(identifier: String, saved: Dictionary, record: Dictionary) -> Dictionary:
	if record.is_empty() or str(saved.get("id", "")) != identifier or not saved.get("inventory") is Dictionary or not saved.get("skills") is Dictionary or not saved.get("flight") is Dictionary or not saved.get("combat") is Dictionary or not _integer(saved.get("seq")) or int(saved.seq) < -1:
		return {}
	if not bool(record.inventory.import_state(saved.inventory).get("ok", false)) or str(record.inventory.gear_id) not in GEAR_IDS:
		return {}
	for slot: String in ["primary", "secondary", "engine"]:
		if not record.inventory.equipped.has(slot):
			return {}
	var stats: Dictionary = record.inventory.combat_profile()
	record.profile.player = stats
	record.profile.primary = record.inventory.catalog[int(record.inventory.equipped.primary)]
	record.profile.secondary = record.inventory.catalog[int(record.inventory.equipped.secondary)]
	record.profile["gear_id"] = str(record.inventory.gear_id)
	record.skills.set_profile({"gear_id": str(record.inventory.gear_id), "player": stats})
	if not record.skills.import_state(saved.skills) or not _restore_flight(record.flight, saved.flight) or str(record.flight.gear_id) != str(record.inventory.gear_id) or int(record.flight.engine_item_num) != int(record.inventory.equipped.engine):
		return {}
	var shared: Variant = _unpack(saved.combat)
	if not shared is Dictionary or not shared.get("player") is Dictionary or not shared.get("weapons") is Dictionary or not shared.get("profile") is Dictionary or not shared.get("skill_modifiers") is Dictionary:
		return {}
	var player: Dictionary = shared.player
	var combat_version: Variant = saved.get("combat_state_version", 1)
	if not _integer(combat_version) or int(combat_version) not in [1, 2]:
		return {}
	if not player.has("life") and int(combat_version) == 1:
		player["life"] = 0
	if not _integer(player.get("life")) or int(player.life) < 0:
		return {}
	for slot: String in ["primary", "secondary"]:
		var expected: Dictionary = Combat.weapon_from_item(record.profile[slot], slot == "primary")
		if not shared.weapons.get(slot) is Dictionary or not _restore_weapon(shared.weapons[slot], expected, int(combat_version)):
			return {}
	for field: String in ["hp", "max_hp", "shield", "max_shield", "primary_ammo", "secondary_ammo", "primary_cooldown", "secondary_cooldown", "primary_heat_remaining", "secondary_heat_remaining", "respawn_remaining"]:
		if not _finite(player.get(field)) or float(player[field]) < 0.0:
			return {}
	if not is_equal_approx(float(player.max_hp), float(stats.max_hp)) or not is_equal_approx(float(player.max_shield), float(stats.max_shield)) or float(player.hp) > float(player.max_hp) or float(player.shield) > float(player.max_shield) or not player.get("dead") is bool or bool(player.dead) != (float(player.hp) <= 0.0):
		return {}
	if not player.get("position") is Vector3 or not player.get("forward") is Vector3 or not _finite(shared.get("lock_progress")) or float(shared.lock_progress) < 0.0 or float(shared.lock_progress) > 1.0:
		return {}
	if not _integer(shared.get("selected_id")) or not shared.get("previous_next") is bool or int(player.get("credits", -1)) != int(record.inventory.credits):
		return {}
	var fraction: Variant = saved.get("xp_fraction", 0.0)
	if not _finite(fraction) or float(fraction) < 0.0 or float(fraction) >= 1.0:
		return {}
	if saved.has("xp_fraction_bits"):
		var exact: Variant = _double_from_bits(float(fraction), saved.xp_fraction_bits)
		if exact == null or float(exact) < 0.0 or float(exact) >= 1.0:
			return {}
		fraction = exact
	record.xp_fraction = float(fraction)
	var wait: Variant = saved.get("collision_wait", 0.0)
	if not _finite(wait) or float(wait) < 0.0 or float(wait) > 0.5:
		return {}
	record["_restored_combat"] = shared
	record.seq = int(saved.seq)
	record.collision_wait = float(wait)
	record.connected = false
	record.controls = {}
	record.input_age = INPUT_TIMEOUT
	return record


static func _same_values(left: Variant, right: Variant) -> bool:
	if right is int:
		return _integer(left) and int(left) == right
	if _finite(left) and _finite(right):
		return absf(float(left) - float(right)) <= 0.000000000001 * maxf(1.0, absf(float(right)))
	if left is Dictionary and right is Dictionary:
		if left.size() != right.size():
			return false
		for key: Variant in right:
			if not left.has(key) or not _same_values(left[key], right[key]):
				return false
		return true
	if left is Array and right is Array:
		if left.size() != right.size():
			return false
		for index in range(right.size()):
			if not _same_values(left[index], right[index]):
				return false
		return true
	return typeof(left) == typeof(right) and left == right


static func _restore_weapon(weapon: Dictionary, native_weapon: Dictionary, version: int) -> bool:
	# The sole new normalized ITEM field is the un-divided NPC cycle timer.
	if not weapon.has("cycle_seconds") and version == 1:
		weapon["cycle_seconds"] = float(native_weapon.cycle_seconds)
	return _same_values(weapon, native_weapon)


func _restore_npc_fields(target: Dictionary, native_target: Dictionary, version: int) -> bool:
	var missing: Array[String] = []
	for field: String in NPC_STATE_FIELDS:
		if not target.has(field):
			missing.append(field)
	if not missing.is_empty():
		if version != 1 or missing.size() != NPC_STATE_FIELDS.size():
			return false
		# Real v0.8 stored no option/burst state and used a generic player gun.
		# Upgrade its loadout once while retaining old HP/DP, position, life,
		# attack_cooldown, RNG, rewards and projectiles already in flight.
		for field: String in NPC_STATE_FIELDS:
			target[field] = native_target[field].duplicate(true) if native_target[field] is Array or native_target[field] is Dictionary else native_target[field]
		target.weapon = native_target.weapon.duplicate(true)
		if not target.get("profile") is Dictionary:
			return false
		target.profile["npc_weapon_options"] = native_target.profile.npc_weapon_options.duplicate(true)
		target.profile["weapon"] = native_target.profile.weapon.duplicate(true)
	if not target.get("npc_weapon_options") is Array or not _same_values(target.npc_weapon_options, native_target.npc_weapon_options):
		return false
	var options: Array = target.npc_weapon_options
	if options.is_empty() or not _integer(target.get("npc_selected_option")) or int(target.npc_selected_option) < -1 or int(target.npc_selected_option) >= options.size():
		return false
	var selected := int(target.npc_selected_option)
	var expected: Dictionary = options[maxi(0, selected)].weapon
	if not target.get("weapon") is Dictionary or not _restore_weapon(target.weapon, expected, version):
		return false
	for field: String in ["npc_cycle_started", "npc_preparing"]:
		if not target.get(field) is bool:
			return false
	if not _integer(target.get("npc_burst_remaining")) or int(target.npc_burst_remaining) < 0 or int(target.npc_burst_remaining) > maxi(0, int(expected.shot_num) - 1):
		return false
	for field: String in ["npc_prepare_remaining", "npc_burst_wait"]:
		if not _finite(target.get(field)) or float(target[field]) < 0.0:
			return false
	if float(target.npc_prepare_remaining) > float(expected.lock_seconds) + 0.000001 or float(target.npc_burst_wait) > Combat.NPC_BURST_INTERVAL + 0.000001:
		return false
	if (selected < 0 and (bool(target.npc_cycle_started) or bool(target.npc_preparing) or int(target.npc_burst_remaining) > 0)) or (bool(target.npc_preparing) and int(target.npc_burst_remaining) > 0):
		return false
	if not _finite(target.get("respawn_seconds")) or not is_equal_approx(float(target.respawn_seconds), float(native_target.respawn_seconds)):
		return false
	if not target.get("npc_option_ready_at") is Dictionary or target.npc_option_ready_at.size() > options.size():
		return false
	for key: Variant in target.npc_option_ready_at:
		if not key is String or not key.is_valid_int() or str(int(key)) != key or int(key) < 0 or int(key) >= options.size() or not _finite(target.npc_option_ready_at[key]) or float(target.npc_option_ready_at[key]) < 0.0:
			return false
	return true


func _restore_projectile(round_value: Dictionary, targets: Array, version: int, last_id: int) -> bool:
	if not round_value.has("hostile") and version == 1:
		round_value["hostile"] = false
	if not round_value.get("hostile") is bool or not round_value.get("pilot_id") is String or not pilots.has(round_value.pilot_id) or not _integer(round_value.get("id")) or int(round_value.id) <= 0 or int(round_value.id) > last_id:
		return false
	if not round_value.get("position") is Vector3 or not round_value.position.is_finite() or not round_value.get("direction") is Vector3 or not round_value.direction.is_finite() or absf(round_value.direction.length_squared() - 1.0) > 0.001:
		return false
	if not _integer(round_value.get("target_id")) or int(round_value.target_id) < 0 or int(round_value.target_id) >= targets.size() or not _integer(round_value.get("target_life")) or int(round_value.target_life) < 0 or not round_value.get("weapon") is Dictionary:
		return false
	for field: String in ["speed", "remaining", "traveled"]:
		if not _finite(round_value.get(field)) or float(round_value[field]) < 0.0:
			return false
	if float(round_value.speed) <= 0.0:
		return false
	var target: Dictionary = targets[int(round_value.target_id)]
	var expected: Dictionary = {}
	if bool(round_value.hostile):
		var victim: Dictionary = combat.pilot_states[round_value.pilot_id].player
		if int(round_value.target_life) > int(victim.life) or not round_value.get("attacker") is Dictionary or round_value.attacker.size() != 1 or not _integer(round_value.attacker.get("level")) or int(round_value.attacker.level) != int(target.level):
			return false
		for option: Dictionary in target.npc_weapon_options:
			if int(option.weapon.item_num) == int(round_value.weapon.get("item_num", 0)) and not bool(option.weapon.primary):
				expected = option.weapon
				break
	else:
		if int(round_value.target_life) > int(target.life) or not round_value.weapon.get("primary") is bool:
			return false
		var inventory: RefCounted = pilots[round_value.pilot_id].inventory
		var item_num := int(round_value.weapon.get("item_num", 0))
		if not inventory.catalog.has(item_num) or int(inventory.quantities.get(item_num, 0)) <= 0:
			return false
		expected = Combat.weapon_from_item(inventory.catalog[item_num], bool(round_value.weapon.primary))
	if expected.is_empty() or not _restore_weapon(round_value.weapon, expected, version):
		return false
	return is_equal_approx(float(round_value.speed), float(expected.projectile_speed))


static func _double_bits(value: float) -> String:
	var bits := PackedByteArray()
	bits.resize(8)
	bits.encode_double(0, value)
	return bits.hex_encode()


static func _double_from_bits(number: float, encoded: Variant) -> Variant:
	# Godot's JSON text rounds arbitrary doubles. Preserve authoritative XP
	# fractions and observed damage weights exactly without changing their
	# readable numeric persistence fields or accepting a mismatched payload.
	if not encoded is String or encoded.length() != 16 or not encoded.is_valid_hex_number(false):
		return null
	var bits: PackedByteArray = encoded.hex_decode()
	var exact := bits.decode_double(0)
	if not is_finite(exact) or absf(exact - number) > 0.000000000001 * maxf(1.0, absf(number)):
		return null
	return exact


func _capture_target_resource_bits() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for target: Dictionary in combat.targets:
		result.append({"hp": _double_bits(float(target.hp)), "shield": _double_bits(float(target.shield))})
	return result


func _capture_contribution_bits() -> Dictionary:
	var result: Dictionary = {}
	for life_key: String in _contributions:
		var weights: Dictionary = {}
		for identifier: String in _contributions[life_key]:
			weights[identifier] = _double_bits(float(_contributions[life_key][identifier]))
		result[life_key] = weights
	return result


func _restore_contributions(state: Dictionary, targets: Array) -> Dictionary:
	var version: Variant = state.get("contributions_version", 1)
	if not _integer(version) or int(version) not in [1, 2] or state.contributions.size() > targets.size():
		return {"ok": false}
	var contributions: Dictionary = {}
	var legacy_lives: Dictionary = {}
	var source_bits: Variant = state.get("contribution_bits", {})
	if not source_bits is Dictionary or (not source_bits.is_empty() and (int(version) != 2 or source_bits.size() != state.contributions.size())):
		return {"ok": false}
	var source_legacy: Variant = state.get("legacy_contribution_lives", {})
	if not source_legacy is Dictionary or source_legacy.size() > targets.size() or (int(version) == 1 and not source_legacy.is_empty()):
		return {"ok": false}
	for key: Variant in state.contributions:
		if not key is String or not state.contributions[key] is Dictionary or state.contributions[key].is_empty() or state.contributions[key].size() > pilots.size():
			return {"ok": false}
		var target_id := -1
		for target: Dictionary in targets:
			if key == "%s/%d:%d" % [_room_id, int(target.id), int(target.life)]:
				target_id = int(target.id)
				break
		if target_id < 0 or state.rewarded.has(key):
			return {"ok": false}
		if not source_bits.is_empty() and (not source_bits.get(key) is Dictionary or source_bits[key].size() != state.contributions[key].size()):
			return {"ok": false}
		var weights: Dictionary = {}
		var total := 0.0
		for identifier: Variant in state.contributions[key]:
			if not identifier is String or not pilots.has(identifier):
				return {"ok": false}
			var amount: Variant = state.contributions[key][identifier]
			if int(version) == 1:
				if not amount is bool or not bool(amount):
					return {"ok": false}
				weights[identifier] = 1.0
				legacy_lives[key] = true
			else:
				if not _finite(amount) or float(amount) <= 0.0:
					return {"ok": false}
				if not source_bits.is_empty():
					amount = _double_from_bits(float(amount), source_bits[key].get(identifier))
					if amount == null or float(amount) <= 0.0:
						return {"ok": false}
				weights[identifier] = float(amount)
			total += float(weights[identifier])
		if not is_finite(total) or (int(version) == 2 and not source_legacy.has(key) and total > float(targets[target_id].max_hp) + float(targets[target_id].max_shield) + 0.0001):
			return {"ok": false}
		contributions[key] = weights
	for key: Variant in source_legacy:
		if not key is String or not contributions.has(key) or not source_legacy[key] is bool or not bool(source_legacy[key]):
			return {"ok": false}
		legacy_lives[key] = true
	return {"ok": true, "contributions": contributions, "legacy_lives": legacy_lives}


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
	const LEGACY_TRANSITION_FIELDS := ["landing", "taking_off", "_takeoff_remaining", "_landing_contact", "_landing_normal"]
	var missing: Array = []
	for key: Variant in expected:
		if not data.has(key):
			missing.append(key)
	if not missing.is_empty():
		if missing.size() != LEGACY_TRANSITION_FIELDS.size():
			return false
		for key: Variant in missing:
			if key not in LEGACY_TRANSITION_FIELDS:
				return false
	for key: Variant in data:
		if not expected.has(key):
			return false
		var original: Variant = flight.get(str(key))
		var value: Variant = _unpack(data[key])
		if value == null or (typeof(original) != typeof(value) and not (_finite(original) and _finite(value))):
			return false
		flight.set(str(key), value)
	return (flight.position as Vector3).is_finite() and (flight.orientation as Quaternion).is_finite() and absf((flight.orientation as Quaternion).length() - 1.0) < 0.001 and float(flight.fuel_fraction) >= 0.0 and float(flight.fuel_fraction) <= 1.0 and Flight.validate_transition_progress(flight.transition_progress(), bool(flight.airborne), str(flight.gear_id))


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
	# Shared native kit catalog plus the verified Hornian weapon for all four classes; avoid copying
	# 16,079 immutable ITEM definitions per active or retained pilot.
	if _starter_rows.is_empty():
		var wanted: Dictionary = {7500020: true} # Verified native Hornian missile, never owned by pilots.
		for kit: Dictionary in STARTER_KITS.values():
			for item_num: Variant in kit.values():
				wanted[int(item_num)] = true
		for engine: Dictionary in _read("res://assets/legacy_rules/engines.json").get("by_gear", {}).values():
			wanted[int(engine.ItemNum)] = true
		for row: Dictionary in _read("res://assets/original_library/catalogs/items.json").get("records", []):
			if wanted.has(int(row.get("ItemNum", 0))):
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
