class_name CombatRuntime
extends Node3D
## Local encounter presentation around the deterministic combat model.
## Native rules and converted assets are local files; no account/network access.

const Combat = preload("res://scripts/combat_model.gd")
const Inventory = preload("res://scripts/inventory_model.gd")
const ServerData = preload("res://scripts/native_server_data.gd")
const SpawnData = preload("res://scripts/native_spawn_data.gd")
const ACTOR_REGISTRY := "res://assets/original_library/actors/actors.json"
const Assets = preload("res://scripts/original_asset.gd")
const RULES_PATH := "res://assets/legacy_rules/combat.json"
const ENCOUNTER_PATH := "res://assets/local_encounter.json"
const ASSET_MANIFEST := "res://assets/original_combat/manifest.json"
const STARTER_ARMOR := {"12000100": 8010100, "12001100": 8011100, "12002100": 8012100, "12003100": 8013100}
const STARTER_RADAR := {"12000100": 7000970, "12001100": 7000970, "12002100": 7011500, "12003100": 7000970}

var model = Combat.new()
var inventory = Inventory.new()
var native_server = ServerData.new()
var native_spawns = SpawnData.new()
var _native_spawn_cache: Dictionary = {}
var _native_channel_clock := 0.0
var _native_actor_states: Dictionary = {}
var _restoring_native_state := false
var _native_spawn_required := false
var _pve_consumed: Dictionary = {}
var _encounter_signature := ""
var _refresh_timer := 0.0
var _encounter_gaps: Array[String] = []
var world: Node
var player_node: Node3D
var _profile: Dictionary = {}
var _encounter: Dictionary = {}
var _monster: Dictionary = {}
var _monster_asset: Dictionary = {}
var _monster_assets: Dictionary = {}
var _native_monsters: Dictionary = {}
var _native_weapons: Dictionary = {}
var _projectile_asset: Dictionary = {}
var _primary_effect_asset: Dictionary = {}
var _secondary_effect_asset: Dictionary = {}
var _target_nodes: Dictionary = {}
var _projectile_nodes: Dictionary = {}
var _traces: Array[Dictionary] = []
var _events: Array[Dictionary] = []
var _reward_ids: Dictionary = {}
var _collision_ready_at := 0.0
var _ready_to_play := false
var _gear_id := "12003100"
var _scene_spawn := Vector3.ZERO
var _map_index := 3002
var _encounter_serial := 0
var _remote_active := false
var _remote_state: Dictionary = {}
var _remote_targets: Dictionary = {}
var _remote_projectiles: Dictionary = {}
var _offline_traces: Array[Dictionary] = []


func setup(world_runtime: Node, player: Node3D) -> bool:
	world = world_runtime
	player_node = player
	if not is_instance_valid(player_node):
		return false
	_profile = _read_json(RULES_PATH)
	_encounter = _read_json(ENCOUNTER_PATH)
	if _profile.is_empty() or _encounter.is_empty():
		push_error("Missing native combat rules or explicit local encounter profile")
		return false
	var assets := _read_json(ASSET_MANIFEST)
	for value: Variant in _read_json("res://assets/legacy_rules/weapons.json").get("records", []):
		if value is Dictionary:
			_native_weapons[int(value.get("ItemNum", 0))] = value
	for value: Variant in _read_json("res://assets/legacy_rules/monsters.json").get("records", []):
		if value is Dictionary:
			_native_monsters[int(value.get("MonsterUnitKind", 0))] = value
	for value: Variant in assets.get("models", assets.get("entries", [])):
		if not value is Dictionary:
			continue
		var role := str(value.get("role", ""))
		if role == "monster" or role == "enemy":
			_monster_asset = _asset_profile(value)
			_monster_assets[int(value.get("source_code", 0))] = _monster_asset
		elif role in ["secondary_projectile", "projectile", "missile"]:
			_projectile_asset = _asset_profile(value)
		elif role == "primary_effect":
			_primary_effect_asset = _asset_profile(value)
		elif role == "secondary_effect":
			_secondary_effect_asset = _asset_profile(value)
	# Actor registry maps appearance variants to MEX monster IDs, not model filenames.
	var registry := _read_json(ACTOR_REGISTRY)
	for key: Variant in registry.get("by_monster_code", {}):
		var entry: Variant = registry.by_monster_code[key]
		if entry is Dictionary and bool(entry.get("available", true)):
			var path := str(entry.get("scene_path", entry.get("resource_path", "")))
			if ResourceLoader.exists(path):
				var profile := _asset_profile(entry)
				var native: Dictionary = _native_monsters.get(int(key), {})
				var factor := float(native.get("ScaleValue", 1.0))
				profile.scale = [factor, factor, factor]
				_monster_assets[int(key)] = profile
	if _monster_asset.is_empty() and _monster_assets.is_empty():
		push_error("Original combat monster asset is missing; no substitute enemy model was created")
		return false
	if not inventory.configure():
		push_error("Native inventory item catalog missing")
		return false
	native_server.load_catalogs(inventory.catalog, _native_monsters)
	var native_maps: Dictionary = {}
	for definition: Dictionary in _read_json("res://assets/legacy_rules/world_rules.json").get("maps", []):
		native_maps[int(definition.get("MapIndex", 0))] = definition
	_native_spawn_required = true
	native_spawns.load_catalog(native_maps, _native_monsters)
	_native_spawn_cache.clear()
	inventory.set_starting_level(int(_encounter.get("player", {}).get("level", 9)))
	inventory.gear_id = _gear_id
	# This small reserve is an explicit local starter kit, not recovered account data.
	for value: Dictionary in _encounter.get("gear_loadouts", {}).values():
		for slot: String in ["primary", "secondary"]:
			var item_num := int(value.get(slot, 0))
			if int(inventory.quantities.get(item_num, 0)) == 0:
				inventory.add_item(item_num)
	var engines := _read_json("res://assets/legacy_rules/engines.json")
	for value: Dictionary in engines.get("by_gear", {}).values():
		var item: Dictionary = value.get("item", value)
		var item_num := int(item.get("ItemNum", 0))
		if int(inventory.quantities.get(item_num, 0)) == 0:
			inventory.add_item(item_num)
	grant_local_starter_equipment()
	configure_gear(_gear_id)
	_scene_spawn = player_node.global_position
	reset()
	return _ready_to_play


static func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var value: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return value if value is Dictionary else {}


static func _asset_profile(entry: Dictionary) -> Dictionary:
	return {"resource_path": str(entry.get("scene_path", entry.get("resource_path", ""))),
		"name": "OriginalCombat" + str(entry.get("id", "")), "source_id": str(entry.get("source_code", entry.get("id", ""))),
		"position": entry.get("position", [0, 0, 0]), "rotation_degrees": entry.get("rotation_degrees", [0, 0, 0]),
		"scale": entry.get("scale", [1, 1, 1]) if entry.get("scale", [1, 1, 1]) is Array else [float(entry.get("scale", 1.0)), float(entry.get("scale", 1.0)), float(entry.get("scale", 1.0))], "render_policy": entry.get("render_policy", {}),
		"attachment": entry.get("attachment_target_position", [0, 0, 0]), "texture_frames": entry.get("texture_frames", [])}


func reset() -> void:
	if _profile.is_empty():
		return
	if not _restoring_native_state:
		_capture_native_population()
	var credits: int = inventory.credits
	var experience: int = inventory.experience
	for value: Variant in _target_nodes.values():
		(value as Node).queue_free()
	for value: Variant in _projectile_nodes.values():
		(value as Node).queue_free()
	for trace: Dictionary in _traces:
		(trace.node as Node).queue_free()
	_target_nodes.clear()
	_projectile_nodes.clear()
	_traces.clear()
	_events.clear()
	var profile := _profile.duplicate(true)
	if is_instance_valid(world) and world.has_method("get_state"):
		var state: Variant = world.call("get_state")
		if state is Dictionary:
			_map_index = int(state.get("map_index", _map_index))
	_encounter_serial += 1
	profile.encounter_id = "%s:%s" % [_map_index, _encounter_serial]
	profile.player = _encounter.get("player", {}).duplicate(true)
	profile.player.level = inventory.level
	profile.player.merge(inventory.combat_profile(), true)
	var loadout := _gear_loadout(_gear_id)
	if not loadout.is_empty():
		profile.primary = loadout.primary
		profile.secondary = loadout.secondary
	profile.primary_ammo = int(_encounter.get("primary_ammo", 1000))
	profile.secondary_ammo = int(_encounter.get("secondary_ammo", 48))
	var next_rng: int = model._rng_state if not model.player.is_empty() else 20251015
	if not model.configure(profile, next_rng):
		return
	model.player["credits"] = credits
	model.player["experience"] = experience
	model.obstacle_query = Callable(self, "_trace_world")
	model.npc_motion_query = Callable(self, "_resolve_npc_motion")
	model.set_player_pose(player_node.global_position, -player_node.global_basis.z)
	_encounter_gaps.clear()
	var spawns := _encounter_spawns()
	_encounter_signature = _objective_signature()
	for index in range(spawns.size()):
		_create_target(spawns[index], index)
	_collision_ready_at = 0.0
	_ready_to_play = true # Missing artwork is reported and omitted, never substituted.


func _monster_profile_for_spawn(spawn: Dictionary) -> Dictionary:
	var monster_code := int(spawn.get("monster_code", 2000000))
	if not _native_monsters.has(monster_code):return {}
	var native_placement := bool(spawn.get("native_spawn", false))
	var monster_profile: Dictionary = _native_monsters[monster_code].duplicate(true)
	# Training conveniences do not replace data on verified DAT placements.
	# Unknown server-only MEX fields stay unknown; CombatModel retains its
	# documented local defaults and Belligerence aggression policy.
	if not native_placement:
		for key: String in _encounter.get("monster_overrides", {}):
			monster_profile[key] = _encounter.monster_overrides[key]
	# Original server slots are separate from client HP/appearance. Unsupported
	# old/new weapon mismatches remain unarmed with a diagnostic.
	var native_attack: Dictionary = native_server.npc_attack_profile(monster_code)
	if bool(native_attack.get("ok", false)):
		monster_profile.npc_weapon_options = native_attack.options.duplicate(true)
		monster_profile.weapon = native_attack.options[0].item.duplicate(true) if not native_attack.options.is_empty() else {}
		monster_profile.npc_weapon_source = native_attack.source_kind
		monster_profile.npc_weapon_source_sha256 = native_attack.source_sha256
	else:
		monster_profile.weapon = {}
		monster_profile.npc_weapon_options = []
		monster_profile.npc_weapon_source = "native_weapon_execution_blocked"
		monster_profile.npc_weapon_block = str(native_attack.get("error", "native_npc_loadout_unavailable"))
		if not native_placement and bool(spawn.get("allow_training_weapon_bridge",false)) and str(_encounter.get("kind","")) == "explicit_local_encounter" and monster_profile.npc_weapon_block == "native_npc_loadout_unavailable":
			monster_profile.weapon = _profile.primary
			monster_profile.erase("npc_weapon_options")
			monster_profile.npc_weapon_source = "explicit_training_player_weapon_bridge_without_native_loadout"
		_encounter_gaps.append("native_npc_weapon_block:%s:%s" % [monster_code,monster_profile.npc_weapon_block])
	if native_placement:
		monster_profile.native_spawn = true
		monster_profile.source_placement_id = str(spawn.source_placement_id)
		monster_profile.source_map_id = int(spawn.map_id)
		monster_profile.source_data = spawn.source_data.duplicate(true)
		monster_profile.respawn_seconds = float(spawn.respawn_seconds)
	return monster_profile


func _create_target(spawn: Dictionary, identifier: int) -> bool:
	var monster_code := int(spawn.get("monster_code", 2000000))
	if not _native_monsters.has(monster_code) or not _monster_assets.has(monster_code):
		_encounter_gaps.append("original_actor_unavailable:" + str(monster_code))
		return false
	var monster_profile := _monster_profile_for_spawn(spawn)
	var native_placement := bool(spawn.get("native_spawn", false))
	var position := _vector(spawn.position) if native_placement else _scene_spawn + _vector(spawn.get("offset", [0, 0, -250]))
	if not native_placement and is_instance_valid(world) and world.has_method("get_bounds"):
		var bounds: Dictionary = world.call("get_bounds")
		if bounds.get("min") is Vector3 and bounds.get("max") is Vector3:
			position = position.clamp(bounds.min + Vector3(30, 0, 30), bounds.max - Vector3(30, 30, 30))
	if not native_placement and is_instance_valid(world) and world.has_method("sample_ground_height"):
		var ground := float(world.call("sample_ground_height", position.x, position.z, true))
		if is_finite(ground):
			position.y = maxf(position.y, ground + 60.0)
	var instance := Assets.instantiate(_monster_assets[monster_code])
	if instance.node == null:
		push_error("Original monster failed to load: " + str(instance.errors))
		return false
	var node: Node3D = instance.node
	node.name = "OriginalMonster_%s" % identifier
	node.set_meta("local_spawn", not native_placement)
	if native_placement:
		node.set_meta("native_placement_id", str(spawn.source_placement_id))
	add_child(node)
	node.global_position = position
	var bounds: AABB = instance.bounds
	monster_profile.radius = maxf(4.0, bounds.size.length() * 0.32)
	model.add_target(monster_profile, position, identifier)
	_restore_native_target(model.targets[-1])
	node.global_position = model.targets[-1].position
	node.visible = not bool(model.targets[-1].dead)
	if native_placement:
		var direction: Vector3 = spawn.get("direction", Vector3.ZERO)
		var up: Vector3 = spawn.get("up", Vector3.UP)
		if not direction.is_zero_approx() and not up.is_zero_approx() and direction.cross(up).length_squared() > 0.000001:
			node.look_at(node.global_position + direction, up)
	_target_nodes[identifier] = node
	return true


func respawn_at(position: Vector3, map_index: int = -1) -> void:
	if not position.is_finite():
		return
	_scene_spawn = position
	if map_index >= 0:
		_map_index = map_index
	reset()


func transfer_to_map(position: Vector3, map_index: int = -1) -> void:
	if not position.is_finite():
		return
	# Portals change the local encounter, not the character life or supplies.
	# Keep the entire player state, including death/respawn countdown and weapon
	# thermal/cooldown progress; only targets and in-flight rounds are map-local.
	var saved_player: Dictionary = model.player.duplicate(true)
	var saved_elapsed: float = model.elapsed
	var saved_collision_ready := _collision_ready_at
	respawn_at(position, map_index)
	if not saved_player.is_empty():
		model.player = saved_player
		model.elapsed = saved_elapsed
		_collision_ready_at = saved_collision_ready
		model.set_player_pose(position, -player_node.global_basis.z)


func configure_gear(gear_id: Variant) -> Dictionary:
	var identifier := str(gear_id)
	if not Inventory.GEAR_KINDS.has(identifier):
		return {"ok": false, "error": "unknown_native_gear"}
	var previous: String = inventory.gear_id
	var eligibility: Dictionary = inventory.can_change_gear(identifier)
	if not bool(eligibility.get("ok", false)):
		return eligibility
	var previous_equipped: Dictionary = inventory.equipped.duplicate()
	var previous_legacy: Dictionary = inventory.grandfathered_equipment.duplicate()
	# Validate a complete destination loadout, never a transient combination of
	# the previous class's engine/armor and the new class's baseline attributes.
	inventory.gear_id = identifier
	inventory.equipped = {}
	inventory.grandfathered_equipment = previous_legacy.duplicate() if identifier == previous else {}
	# CPU may supply the source requirements of the selected weapons/engine.
	if previous_equipped.has("cpu"):
		inventory.equip_item(int(previous_equipped.cpu), "cpu")
	var selected: Dictionary = _encounter.get("gear_loadouts", {}).get(identifier, {})
	var engine_candidates := _read_json("res://assets/legacy_rules/engines.json").get("by_gear", {}) as Dictionary
	var engine_selection: Dictionary = engine_candidates.get(identifier, {})
	var engine_item: Dictionary = engine_selection.get("item", engine_selection)
	for slot: String in ["primary", "secondary", "engine"]:
		var old_id := int(previous_equipped.get(slot, 0))
		if old_id > 0 and bool(inventory.equip_item(old_id, slot).get("ok", false)):
			continue
		var fallback := int(engine_item.get("ItemNum", 0)) if slot == "engine" else int(selected.get(slot, 0))
		var equipped_result: Dictionary = inventory.equip_item(fallback, slot)
		if not bool(equipped_result.get("ok", false)):
			inventory.gear_id = previous
			inventory.equipped = previous_equipped
			inventory.grandfathered_equipment = previous_legacy
			return {"ok": false, "error": "native_gear_loadout_unavailable", "slot": slot, "cause": equipped_result}
	for slot: String in ["armor", "radar", "accessory"]:
		if previous_equipped.has(slot):
			inventory.equip_item(int(previous_equipped[slot]), slot)
	for slot: String in ["armor", "radar"]:
		if not inventory.equipped.has(slot):
			var item_num := int((STARTER_ARMOR if slot == "armor" else STARTER_RADAR).get(identifier, 0))
			if int(inventory.quantities.get(item_num, 0)) > 0: inventory.equip_item(item_num, slot)
	for slot: String in inventory.grandfathered_equipment.keys():
		if int(inventory.equipped.get(slot, 0)) != int(inventory.grandfathered_equipment[slot]):
			inventory.grandfathered_equipment.erase(slot)
	var loadout := _gear_loadout(identifier)
	if loadout.is_empty():
		inventory.gear_id = previous
		inventory.equipped = previous_equipped
		inventory.grandfathered_equipment = previous_legacy
		return {"ok": false, "error": "native_gear_weapon_profile_unavailable"}
	_gear_id = identifier
	if not model.player.is_empty():
		model.equip_weapons(loadout.primary, loadout.secondary)
		model.apply_player_stats(inventory.combat_profile())
	return {"ok": true, "gear_id": identifier}


func grant_local_starter_equipment() -> void:
	# Explicit v0.7 local starter reserve, analogous to the existing class engines.
	# Native level-one/zero-price armor and radars; no CPU or stat points granted.
	var additions: Array[Dictionary] = []
	var included: Dictionary = {}
	for identifier: int in STARTER_ARMOR.values() + STARTER_RADAR.values():
		if not included.has(identifier) and int(inventory.quantities.get(identifier, 0)) == 0:
			additions.append({"item_num": identifier, "count": 1})
		included[identifier] = true
	inventory.apply_reward({"reward_id": "local-v07-armor-radar-reserve", "items": additions})


func equip_item(item_num: int, slot: String) -> Dictionary:
	var result: Dictionary = inventory.equip_item(item_num, slot)
	if bool(result.ok) and slot in ["primary", "secondary"] and not model.player.is_empty():
		model.equip_weapons(inventory.catalog[int(inventory.equipped.primary)], inventory.catalog[int(inventory.equipped.secondary)])
	if bool(result.ok) and not model.player.is_empty(): model.apply_player_stats(inventory.combat_profile())
	return result


func _gear_loadout(identifier: String) -> Dictionary:
	var selected: Dictionary = _encounter.get("gear_loadouts", {}).get(identifier, {})
	if selected.is_empty():
		return {}
	var unit_kind := int(selected.get("unit_kind", 0))
	var level: int = inventory.level if not inventory.catalog.is_empty() else int(_encounter.get("player", {}).get("level", 1))
	var result: Dictionary = {}
	for slot: String in ["primary", "secondary"]:
		var selected_id := int(selected.get(slot, 0))
		if inventory.gear_id == identifier and inventory.equipped.has(slot) and bool(inventory.can_equip(int(inventory.equipped[slot]), slot).ok):
			selected_id = int(inventory.equipped[slot])
		var item: Dictionary = _native_weapons.get(selected_id, {})
		var expected_position := 2 if slot == "primary" else 4
		if item.is_empty() or (int(item.get("ReqUnitKind", 0)) & unit_kind) == 0 or int(item.get("Position", -1)) != expected_position:
			return {}
		if int(item.get("ReqMinLevel", 0)) > level or (int(item.get("ReqMaxLevel", 0)) > 0 and level > int(item.ReqMaxLevel)):
			return {}
		result[slot] = item
	return result


func _active_objectives() -> Array:
	if is_instance_valid(world) and world.has_method("get_state"):
		var state: Variant = world.call("get_state")
		if state is Dictionary and state.has("active_missions"):
			var result: Array[Dictionary] = []
			for mission: Dictionary in state.get("active_missions", []):
				for objective: Dictionary in mission.get("objectives", []):
					var entry: Dictionary = objective.duplicate(true)
					entry["mission_id"] = str(mission.get("id", ""))
					entry["map_id"] = int(objective.get("map_id", mission.get("event_map_id", 0)))
					entry["monster_code"] = int(objective.get("monster_code", objective.get("target_code", 0)))
					result.append(entry)
			return result
	if is_instance_valid(world) and world.has_method("active_objectives"):
		var value: Variant = world.call("active_objectives")
		return value if value is Array else []
	return []


func _objective_signature() -> String:
	var codes: Array[String] = []
	for value: Variant in _active_objectives():
		if value is Dictionary and str(value.get("kind", "")) == "kill":
			var map_id := int(value.get("map_id", value.get("event_map_id", 0)))
			if map_id in [0, _map_index]:
				codes.append(str(value.get("mission_id", "")) + ":" + str(value.get("monster_code", value.get("target_code", 0))))
	codes.sort()
	return ",".join(codes)


func _encounter_spawns() -> Array:
	var source: Dictionary = _native_map_spawns(_map_index)
	if _native_spawn_required and not bool(source.get("ok", false)):
		if not _encounter_gaps.has("native_spawn_catalog_unavailable"):_encounter_gaps.append("native_spawn_catalog_unavailable")
		return []
	if int(source.get("source_object_count", 0)) + int(source.get("source_region_count", 0)) > 0:
		var native_records: Array[Dictionary] = []
		for record: Dictionary in source.get("records", []):
			# The legacy channel checks once per second against a monotonic tick.
			# Offline uses persisted active-session time; OS uptime is not portable.
			if _native_actor_states.has(record.source_placement_id) or floorf(_native_channel_clock + 0.000001) >= float(record.respawn_seconds):
				var spawn := record.duplicate(true)
				spawn.native_spawn = true
				native_records.append(spawn)
		for reason: String in source.get("blocked_reasons", {}):
			var diagnostic := "native_spawn_block:%s:%s" % [_map_index, reason]
			if not _encounter_gaps.has(diagnostic):_encounter_gaps.append(diagnostic)
		return native_records
	# City service areas do not receive fabricated hostile spawns.
	if _map_index in [2001, 2002]:
		return []
	var map_encounter: Dictionary = _encounter.get("maps", {}).get(str(_map_index), {})
	var explicit: Array = map_encounter.get("targets", []).duplicate(true)
	var objective_codes: Array[int] = []
	for value: Variant in _active_objectives():
		if not value is Dictionary or str(value.get("kind", "")) != "kill":
			continue
		var map_id := int(value.get("map_id", value.get("event_map_id", 0)))
		var code := int(value.get("monster_code", value.get("target_code", 0)))
		if map_id in [0, _map_index] and not objective_codes.has(code):
			objective_codes.append(code)
	for code: int in objective_codes:
		var found := false
		for spawn: Dictionary in explicit:
			found = found or int(spawn.get("monster_code", 0)) == code
		if not found and _monster_assets.has(code) and _native_monsters.has(code):
			explicit.append({"monster_code": code, "offset": _local_spawn_offset(explicit.size()), "scope": "native_mission_identity_local_position"})
	if not explicit.is_empty():
		return explicit
	# Other available regions receive three deterministic local encounters. No
	# map-specific spawn ownership can be inferred from the client MEX catalog.
	var candidates: Array[int] = []
	for code: int in _monster_assets:
		var monster: Dictionary = _native_monsters.get(code, {})
		if int(monster.get("HP", 0)) > 0 and int(monster.get("Belligerence", 0)) < 10 and abs(int(monster.get("Level", 0)) - inventory.level) <= 5:
			candidates.append(code)
	candidates.sort()
	for index in range(3 if not candidates.is_empty() else 0):
		var code: int = candidates[(absi(_map_index) + index) % candidates.size()]
		explicit.append({"monster_code": code, "offset": _local_spawn_offset(index), "scope": "local_encounter_near_character_level_not_original_spawn"})
	return explicit


func _native_map_spawns(map_id: int) -> Dictionary:
	if not _native_spawn_cache.has(map_id):
		_native_spawn_cache[map_id] = native_spawns.object_spawn_profiles(map_id)
	return _native_spawn_cache[map_id]


func _capture_native_population() -> void:
	for target: Dictionary in model.targets:
		var profile: Dictionary = target.get("profile", {})
		var placement := str(profile.get("source_placement_id", ""))
		if not bool(profile.get("native_spawn", false)) or placement.is_empty():continue
		var position: Vector3 = target.position
		_native_actor_states[placement] = {
			"placement_id":placement,"map_id":int(profile.source_map_id),"monster_code":int(target.monster_code),
			"hp":float(target.hp),"shield":float(target.shield),"dead":bool(target.dead),
			"respawn_remaining":float(target.respawn_remaining),"life":int(target.life),
			"position":[position.x,position.y,position.z],"saved_clock":_native_channel_clock}


func _restore_native_target(target: Dictionary) -> void:
	var profile: Dictionary = target.get("profile", {})
	var placement := str(profile.get("source_placement_id", ""))
	if not bool(profile.get("native_spawn", false)) or not _native_actor_states.has(placement):return
	var saved: Dictionary = _native_actor_states[placement]
	target.hp = minf(float(saved.hp), float(target.max_hp))
	target.shield = minf(float(saved.shield), float(target.max_shield))
	target.dead = bool(saved.dead)
	target.life = int(saved.life)
	target.position = _vector(saved.position)
	target.velocity = Vector3.ZERO
	target.respawn_remaining = maxf(0.0, float(saved.respawn_remaining) - maxf(0.0, _native_channel_clock - float(saved.saved_clock))) if target.dead else 0.0
	if target.dead and float(target.respawn_remaining) <= 0.000001:
		target.dead = false
		target.hp = target.max_hp
		target.shield = target.max_shield
		target.position = target.spawn_position
		target.life += 1


func _validate_native_population(state: Dictionary) -> Dictionary:
	var raw_clock: Variant = state.get("native_channel_clock", 0.0)
	var raw_states: Variant = state.get("native_actor_states", [])
	if not _bounded_native_number(raw_clock, 1000000000000.0) or not raw_states is Array or raw_states.size() > 3498:
		return {"ok":false,"error":"combat_native_population_schema"}
	var candidates: Dictionary = {}
	for value: Variant in raw_states:
		if not value is Dictionary:return {"ok":false,"error":"combat_native_population_row"}
		var record: Dictionary = value
		var placement: Variant = record.get("placement_id")
		var map_id := Inventory._bounded_integer(record.get("map_id", -1))
		if not placement is String or placement.is_empty() or placement.length() > 80 or candidates.has(placement) or map_id <= 0:
			return {"ok":false,"error":"combat_native_population_identity"}
		var source: Dictionary = {}
		for row: Dictionary in _native_map_spawns(map_id).get("records", []):
			if str(row.source_placement_id) == placement:source = row;break
		if source.is_empty() or Inventory._bounded_integer(record.get("monster_code", -1)) != int(source.monster_code):
			return {"ok":false,"error":"combat_native_population_source"}
		var monster: Dictionary = _native_monsters.get(int(source.monster_code), {})
		var max_hp := Combat._number_or(monster.get("HP"), 0.0)
		var max_shield := Combat._number_or(monster.get("DP"), 0.0)
		if not _bounded_native_number(record.get("hp"), max_hp) or not _bounded_native_number(record.get("shield"), max_shield) or not record.get("dead") is bool or bool(record.dead) != (float(record.hp) <= 0.0):
			return {"ok":false,"error":"combat_native_population_vitals"}
		if not _bounded_native_number(record.get("respawn_remaining"), float(source.respawn_seconds)) or not _bounded_native_number(record.get("saved_clock"), float(raw_clock)) or Inventory._bounded_integer(record.get("life", -1)) < 0:
			return {"ok":false,"error":"combat_native_population_timing"}
		if not bool(record.dead) and float(record.respawn_remaining) > 0.0:return {"ok":false,"error":"combat_native_population_timing"}
		if not record.get("position") is Array or record.position.size() != 3:return {"ok":false,"error":"combat_native_population_position"}
		for component: Variant in record.position:
			if not (component is int or component is float) or not is_finite(float(component)) or absf(float(component)) > 10000000.0:
				return {"ok":false,"error":"combat_native_population_position"}
		candidates[placement] = record.duplicate(true)
	return {"ok":true,"clock":float(raw_clock),"states":candidates}


static func _bounded_native_number(value: Variant, maximum: float) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) >= 0.0 and float(value) <= maximum


static func _local_spawn_offset(index: int) -> Array:
	return [float((index % 3 - 1) * 80), 40.0 + float(index % 2) * 25.0, -220.0 - float(index / 3) * 100.0 - float(index % 3) * 90.0]


func refresh_encounter() -> void:
	if model.player.is_empty():
		return
	# A mission update adds actors only. Existing creatures retain their exact
	# dictionaries/IDs, HP, life, cooldowns, projectiles and target locks.
	var existing: Dictionary = {}
	var placements: Dictionary = {}
	var next_id := 0
	for target: Dictionary in model.targets:
		var code := int(target.monster_code)
		var placement := str(target.get("profile", {}).get("source_placement_id", ""))
		if not placement.is_empty():placements[placement] = true
		existing[code] = int(existing.get(code, 0)) + 1
		next_id = maxi(next_id, int(target.id) + 1)
	var requested: Dictionary = {}
	for spawn: Dictionary in _encounter_spawns():
		if bool(spawn.get("native_spawn", false)):
			if not placements.has(spawn.source_placement_id) and _create_target(spawn, next_id):
				placements[spawn.source_placement_id] = true
				next_id += 1
			continue
		var code := int(spawn.get("monster_code", 0))
		requested[code] = int(requested.get(code, 0)) + 1
		if int(requested[code]) > int(existing.get(code, 0)):
			if _create_target(spawn, next_id):
				next_id += 1
	_encounter_signature = _objective_signature()


func available_monsters() -> Array:
	return _monster_assets.keys()


func _trace_world(start: Vector3, finish: Vector3, radius: float) -> Dictionary:
	if is_instance_valid(world) and world.has_method("trace_segment"):
		var result: Variant = world.call("trace_segment", start, finish, radius)
		return result if result is Dictionary else {}
	return {}


func _resolve_npc_motion(previous: Vector3, desired: Vector3, radius: float) -> Vector3:
	if not is_instance_valid(world):
		return desired
	# Collision and a small local altitude margin prevent the adapted AI entering terrain.
	if world.has_method("sample_ground_height"):
		var ground := float(world.call("sample_ground_height", desired.x, desired.z, true))
		if is_finite(ground):
			desired.y = maxf(desired.y, ground + radius + 10.0)
	if world.has_method("resolve_motion"):
		var result: Variant = world.call("resolve_motion", previous, desired, radius)
		if result is Dictionary and result.get("position") is Vector3:
			return result.position
	return desired


func advance(delta: float, controls: Dictionary, flight: Dictionary = {}) -> void:
	if _remote_active: return
	if not _ready_to_play or not is_instance_valid(player_node):
		return
	_refresh_timer += maxf(0.0, delta)
	if _refresh_timer >= 0.5:
		_refresh_timer = 0.0
		if _objective_signature() != _encounter_signature:
			refresh_encounter()
	var position: Vector3 = flight.get("position", player_node.global_position)
	var forward: Vector3 = flight.get("forward", -player_node.global_basis.z)
	model.set_player_pose(position, forward)
	var previous_elapsed: float = model.elapsed
	model.advance(delta, controls)
	var previous_clock := _native_channel_clock
	_native_channel_clock += maxf(0.0, model.elapsed - previous_elapsed)
	if floorf(previous_clock) < floorf(_native_channel_clock + 0.000001):
		refresh_encounter()
	for event: Dictionary in model.drain_events():
		_events.append(event)
		if event.type == "target_destroyed":
			_award_native_pve(event)
		if event.type in ["fired", "enemy_fired"] and event.get("slot", "primary") == "primary":
			_add_trace(event.get("position", position), event.get("endpoint", position), event.type == "enemy_fired")
	_update_visuals(delta)


func _update_visuals(delta: float) -> void:
	for target: Dictionary in model.targets:
		var node: Node3D = _target_nodes.get(int(target.id))
		if not is_instance_valid(node):
			continue
		node.visible = not bool(target.dead)
		node.global_position = target.position
		var velocity: Vector3 = target.velocity
		if velocity.length_squared() > 0.01 and absf(velocity.normalized().dot(Vector3.UP)) < 0.99:
			node.look_at(node.global_position + velocity, Vector3.UP)
	var live: Dictionary = {}
	for projectile: Dictionary in model.projectiles:
		var identifier: int = projectile.id
		live[identifier] = true
		if not _projectile_nodes.has(identifier) and not _projectile_asset.is_empty():
			var visual := _instantiate_effect(_projectile_asset)
			if visual != null:
				_projectile_nodes[identifier] = visual
				add_child(visual)
				if not _secondary_effect_asset.is_empty():
					var effect := _instantiate_effect(_secondary_effect_asset)
					if effect != null:
						visual.add_child(effect)
						effect.position = _vector(_secondary_effect_asset.get("attachment", [0, 0, 0]))
		var node: Node3D = _projectile_nodes.get(identifier)
		if is_instance_valid(node):
			node.global_position = projectile.position
			_advance_effect(node, delta)
			var direction: Vector3 = projectile.direction
			if absf(direction.dot(Vector3.UP)) < 0.99:
				node.look_at(node.global_position + direction, Vector3.UP)
	for identifier: Variant in _projectile_nodes.keys():
		if not live.has(identifier):
			(_projectile_nodes[identifier] as Node).queue_free()
			_projectile_nodes.erase(identifier)
	for index in range(_traces.size() - 1, -1, -1):
		_traces[index].remaining = float(_traces[index].remaining) - maxf(0.0, delta)
		if bool(_traces[index].get("original", false)):
			var node: Node3D = _traces[index].node
			var parameter := clampf(1.0 - float(_traces[index].remaining) / 0.08, 0.0, 1.0)
			node.global_position = (_traces[index].start as Vector3).lerp(_traces[index].finish, parameter)
			_advance_effect(node, delta)
		if float(_traces[index].remaining) <= 0.0:
			(_traces[index].node as Node).queue_free()
			_traces.remove_at(index)


func _add_trace(start: Vector3, finish: Vector3, hostile: bool) -> void:
	if _traces.size() >= 64:
		return
	if not _primary_effect_asset.is_empty():
		var original := _instantiate_effect(_primary_effect_asset)
		if original != null:
			add_child(original)
			original.global_position = start
			var direction := finish - start
			if direction.length_squared() > 0.001 and absf(direction.normalized().dot(Vector3.UP)) < 0.99:
				original.look_at(finish, Vector3.UP)
			_traces.append({"node": original, "remaining": 0.08, "start": start, "finish": finish, "original": true})
			return
	# Explicit local diagnostic trace if no verified effect is available.
	var mesh := ImmediateMesh.new()
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(1.0, 0.25, 0.12) if hostile else Color(0.6, 0.95, 1.0)
	mesh.surface_begin(Mesh.PRIMITIVE_LINES, material)
	mesh.surface_add_vertex(start)
	mesh.surface_add_vertex(finish)
	mesh.surface_end()
	var node := MeshInstance3D.new()
	node.name = "LocalHitscanTrace"
	node.mesh = mesh
	add_child(node)
	_traces.append({"node": node, "remaining": 0.08})


func _instantiate_effect(profile: Dictionary) -> Node3D:
	var result := Assets.instantiate(profile)
	if result.node == null:
		return null
	var node: Node3D = result.node
	var policy: Dictionary = profile.get("render_policy", {})
	var materials: Array[Material] = []
	_configure_effect_materials(node, policy, materials)
	node.set_meta("effect_materials", materials)
	node.set_meta("effect_frames", profile.get("texture_frames", []))
	node.set_meta("effect_policy", policy)
	node.set_meta("effect_frame", 0)
	node.set_meta("effect_time", 0.0)
	return node


func _configure_effect_materials(node: Node, policy: Dictionary, materials: Array[Material]) -> void:
	if node is MeshInstance3D and node.mesh != null:
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		for surface in range(node.mesh.get_surface_count()):
			var original: Material = node.get_active_material(surface)
			if not original is StandardMaterial3D:
				continue
			var material: StandardMaterial3D = original.duplicate()
			material.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL if int(policy.get("environment_light", 1)) != 0 else BaseMaterial3D.SHADING_MODE_UNSHADED
			if int(policy.get("alpha_blend", 0)) != 0:
				material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
				if int(policy.get("src_blend", 0)) == 2 and int(policy.get("dst_blend", 0)) == 2:
					material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
			else:
				material.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
			material.no_depth_test = int(policy.get("z_test", 1)) == 0
			material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_ALWAYS if int(policy.get("z_write", 1)) != 0 else BaseMaterial3D.DEPTH_DRAW_DISABLED
			var rendered: Material = material
			if int(policy.get("alpha_blend", 0)) != 0 and int(policy.get("src_blend", 0)) == 2 and int(policy.get("dst_blend", 0)) == 2:
				# Godot blend_add weights by ALPHA; fixed ALPHA1 preserves native ONE/ONE.
				var shader := Shader.new()
				var modes := "blend_add, depth_draw_never, cull_back"
				if int(policy.get("environment_light", 1)) == 0:
					modes += ", unshaded"
				shader.code = "shader_type spatial;\nrender_mode " + modes + ";\nuniform sampler2D original_albedo : source_color, filter_linear_mipmap, repeat_enable;\nuniform vec4 original_factor : source_color = vec4(1.0);\nvoid fragment(){ALBEDO=texture(original_albedo,UV).rgb*original_factor.rgb;ALPHA=1.0;ROUGHNESS=1.0;METALLIC=0.0;}"
				var additive := ShaderMaterial.new()
				additive.shader = shader
				additive.set_shader_parameter("original_albedo", material.albedo_texture)
				additive.set_shader_parameter("original_factor", material.albedo_color)
				rendered = additive
			node.set_surface_override_material(surface, rendered)
			materials.append(rendered)
	for child: Node in node.get_children():
		_configure_effect_materials(child, policy, materials)


func _advance_effect(node: Node, delta: float) -> void:
	var frames: Array = node.get_meta("effect_frames", [])
	var policy: Dictionary = node.get_meta("effect_policy", {})
	if frames.size() > 1 and int(policy.get("animation_type", 0)) == 1:
		var timer := float(node.get_meta("effect_time", 0.0)) + maxf(0.0, delta)
		if timer > float(policy.get("texture_animation_velocity", 1.0)):
			var frame := int(node.get_meta("effect_frame", 0)) + 1
			frame = frame % frames.size() if int(policy.get("animation_loop", 0)) != 0 else mini(frame, frames.size() - 1)
			node.set_meta("effect_frame", frame)
			timer = 0.0 # CObjectAni::Tick resets its accumulator when changing texture.
			var texture: Texture2D = load(str(frames[frame].get("path", ""))) as Texture2D
			for material: Material in node.get_meta("effect_materials", []):
				if material is ShaderMaterial:
					material.set_shader_parameter("original_albedo", texture)
				elif material is StandardMaterial3D:
					material.albedo_texture = texture
		node.set_meta("effect_time", timer)
	for child: Node in node.get_children():
		_advance_effect(child, delta)


func receive_collision(impact: Dictionary) -> void:
	if not _ready_to_play or model.elapsed < _collision_ready_at or not bool(impact.get("collided", true)):
		return
	if bool(impact.get("fuel_stranded", false)) or float(impact.get("damage_scale", 1.0)) <= 0.0:
		return
	var speed := absf(float(impact.get("impact_speed", impact.get("speed", 0.0))))
	if speed <= 0.01:
		return
	# AtumSJ::GetPenaltyCollisionBYSpeed + server Process_FC_CHARACTER_APPLY_COLLISION_DAMAGE.
	var rate := collision_damage_rate(speed)
	model.damage_player((float(model.player.max_hp) + float(model.player.max_shield)) * rate, str(impact.get("kind", "collision")))
	_collision_ready_at = model.elapsed + 0.75 # local contact debounce, not a native timer claim


static func collision_damage_rate(speed: float) -> float:
	for index in range(8):
		if speed < 150.0 + 60.0 * index:
			return 0.1 + 0.05 * index
	return 0.5


func _award_native_pve(event: Dictionary) -> Dictionary:
	# Only a real death from this local combat model can create a reward. Remote
	# snapshots and arbitrary stale event IDs never become a second authority.
	if _remote_active or event.get("type", "") != "target_destroyed" or model.player.is_empty():
		return {"ok":false,"error":"native_reward_requires_local_death"}
	var instance: Variant = event.get("instance_id", "")
	var code := ServerData._integer(event.get("monster_code", 0), 2147483647)
	var target_id := ServerData._integer(event.get("id", -1), 2147483647)
	if not instance is String or instance.is_empty() or instance.length() > 200 or code <= 0 or target_id < 0 or not _native_monsters.has(code):
		return {"ok":false,"error":"invalid_native_death_identity"}
	var matched := false
	for target: Dictionary in model.targets:
		if int(target.id) != target_id or int(target.monster_code) != code or not bool(target.dead):continue
		var expected := "%s/%s:%s" % [model._initial_profile.get("encounter_id", "local"), target.id, target.life]
		matched = expected == instance
	if not matched:return {"ok":false,"error":"native_reward_requires_current_dead_target"}
	var reward_id: String = "native-pve:" + instance
	if _pve_consumed.has(instance) or inventory.reward_ids.has(reward_id):
		return {"ok":false,"duplicate":true}
	if _pve_consumed.size() >= 100000:return {"ok":false,"error":"native_death_history_limit"}
	_pve_consumed[instance] = true
	var resolved: Dictionary = native_server.roll_rewards(code, inventory.level, Callable(self,"_native_reward_random_int"))
	if not bool(resolved.get("ok", false)):
		_events.append({"type":"native_pve_reward_blocked","monster_code":code,"reason":str(resolved.get("error", "native_reward_unavailable")),"source_kind":"monster"})
		return resolved
	var reward: Dictionary = {"type":"native_pve_reward","source_kind":"monster","reward_id":reward_id,"monster_code":code,"credits":int(resolved.credits),"experience":int(resolved.experience),"items":resolved.items,"native_drop_blocks":resolved.blocked_rows,"source_sha256":ServerData.SOURCE_SHA,"scope":"native_database_solo_base_rates;local_automatic_collection;unchanged_client_HP"}
	var applied := apply_reward(reward)
	if not applied and (int(reward.credits) > 0 or not reward.items.is_empty()):
		# Native EXPDivision precedes item pickup. A refused collection cannot
		# erase earned XP; the same kill receipt consumes the attempted loot.
		reward["credits"] = 0
		reward["items"] = []
		reward["loot_rejected"] = true
		applied = apply_reward(reward)
	if not applied:
		_events.append({"type":"native_pve_reward_rejected","reward_id":reward_id,"monster_code":code,"source_kind":"monster","message":"A recompensa PvE foi recusada pelo inventário; o alvo não pode gerar outro sorteio."})
		return {"ok":false,"error":"native_pve_inventory_rejected"}
	reward["inventory_applied"] = true
	reward["message"] = "PvE original: +%d XP · +%d SPI" % [int(reward.experience),int(reward.credits)]
	if bool(reward.get("loot_rejected", false)):
		reward.message += " · itens não recolhidos: inventário recusou a transação"
	_events.append(reward.duplicate(true))
	return {"ok":true,"reward":reward}


func _native_reward_random_int(minimum: int, maximum: int) -> int:
	# Share the existing explicit saved combat stream; no global random state.
	# Native numeric ranges/comparators are exact, the local PRNG differs.
	model._rng_state = (model._rng_state * 48271) % 2147483647
	return minimum + model._rng_state % (maximum - minimum + 1)


func apply_reward(event: Dictionary) -> bool:
	var previous_level: int = inventory.level
	if model.player.is_empty() or not inventory.apply_reward(event):
		return false
	_reward_ids = inventory.reward_ids.duplicate()
	model.player["credits"] = inventory.credits
	model.player["experience"] = inventory.experience
	model.player["level"] = inventory.level
	if inventory.level > previous_level:
		if not bool(model.player.dead):
			model.player.hp = model.player.max_hp
		_events.append({"type": "level_up", "level": inventory.level, "message": "Nível " + str(inventory.level)})
	return true


func export_state() -> Dictionary:
	_capture_native_population()
	var player_state: Dictionary = model.player.duplicate(true)
	for key: String in ["position", "forward"]:
		var vector: Vector3 = player_state.get(key, Vector3.ZERO)
		player_state[key] = [vector.x, vector.y, vector.z]
	return {"schema_version": 1, "stats_schema_version": 2, "inventory": inventory.export_state(), "player": player_state,
		"encounter_serial": _encounter_serial, "elapsed": model.elapsed, "rng_state": model._rng_state,
		"pve_consumed": _pve_consumed.keys(),
		"native_channel_clock":_native_channel_clock,"native_actor_states":_native_actor_states.values(),
		"scope": "local_character_and_native_DAT_population;unsupported_regions_gated"}


func import_state(state: Dictionary) -> Dictionary:
	if int(state.get("schema_version", -1)) != 1 or not state.get("inventory") is Dictionary or not state.get("player") is Dictionary:
		return {"ok": false, "error": "combat_state_schema"}
	var candidate := Inventory.new()
	candidate.configure(inventory.catalog.values())
	candidate.starting_level = inventory.starting_level
	var result: Dictionary = candidate.import_state(state.inventory)
	if not bool(result.ok):
		return result
	var player_state: Dictionary = state.player.duplicate(true)
	for key: String in ["max_hp", "hp", "max_shield", "shield", "primary_ammo", "secondary_ammo", "primary_cooldown", "secondary_cooldown", "primary_heat_remaining", "secondary_heat_remaining", "respawn_remaining"]:
		var value: Variant = player_state.get(key)
		if not (value is int or value is float) or not is_finite(float(value)) or float(value) < 0.0 or float(value) > Inventory.MAX_COUNT:
			return {"ok": false, "error": "combat_player_" + key}
	for key: String in ["primary_ammo", "secondary_ammo"]:
		if Inventory._bounded_integer(player_state[key]) < 0:
			return {"ok": false, "error": "combat_ammunition"}
	if float(player_state.max_hp) <= 0.0 or float(player_state.hp) > float(player_state.max_hp) or float(player_state.shield) > float(player_state.max_shield):
		return {"ok": false, "error": "combat_vitals"}
	var derived: Dictionary = candidate.combat_profile()
	if int(state.get("stats_schema_version", 1)) == 1:
		if not is_equal_approx(float(player_state.max_hp), 600.0) or not is_equal_approx(float(player_state.max_shield), 400.0):
			return {"ok": false, "error": "combat_legacy_vitals"}
		var hp_fraction := float(player_state.hp) / float(player_state.max_hp)
		var shield_fraction := float(player_state.shield) / maxf(1.0, float(player_state.max_shield))
		player_state.max_hp = float(derived.max_hp)
		player_state.max_shield = float(derived.max_shield)
		player_state.hp = hp_fraction * float(derived.max_hp)
		player_state.shield = shield_fraction * float(derived.max_shield)
	elif int(state.get("stats_schema_version", 0)) != 2 or not is_equal_approx(float(player_state.max_hp), float(derived.max_hp)) or not is_equal_approx(float(player_state.max_shield), float(derived.max_shield)):
		return {"ok": false, "error": "combat_derived_vitals"}
	for key: String in ["dead", "primary_overheated", "secondary_overheated"]:
		if not player_state.get(key) is bool:
			return {"ok": false, "error": "combat_flag_" + key}
	if bool(player_state.dead) != (float(player_state.hp) <= 0.0):
		return {"ok": false, "error": "combat_death_state"}
	for key: String in ["position", "forward"]:
		var value: Variant = player_state.get(key)
		if not value is Array or value.size() != 3:
			return {"ok": false, "error": "combat_pose"}
		for axis: Variant in value:
			if not (axis is int or axis is float) or not is_finite(float(axis)):
				return {"ok": false, "error": "combat_pose"}
		player_state[key] = _vector(value)
	if (player_state.forward as Vector3).length_squared() < 0.00001:
		return {"ok": false, "error": "combat_direction"}
	for key: String in ["defense", "dodge", "attack_bonus", "attack_probability_bonus", "pierce"]:
		var value: Variant = player_state.get(key)
		if not (value is int or value is float) or not is_finite(float(value)) or absf(float(value)) > 1000000.0:
			return {"ok": false, "error": "combat_stat_" + key}
	if int(player_state.get("credits", -1)) != candidate.credits or int(player_state.get("experience", -1)) != candidate.experience or int(player_state.get("level", -1)) != candidate.level:
		return {"ok": false, "error": "combat_inventory_ledger_mismatch"}
	for slot: String in ["primary", "secondary", "engine"]:
		if not candidate.equipped.has(slot):
			return {"ok": false, "error": "combat_missing_equipment"}
	var elapsed_value: Variant = state.get("elapsed", -1)
	var serial_value := Inventory._bounded_integer(state.get("encounter_serial", -1))
	var rng_raw: Variant = state.get("rng_state", -1)
	var rng_value := int(rng_raw) if (rng_raw is int or rng_raw is float) and is_finite(float(rng_raw)) and float(rng_raw) == floorf(float(rng_raw)) and float(rng_raw) <= 2147483646.0 else -1
	if not (elapsed_value is int or elapsed_value is float) or not is_finite(float(elapsed_value)) or float(elapsed_value) < 0.0 or serial_value < 0 or rng_value < 1:
		return {"ok": false, "error": "combat_timing"}
	var consumed: Variant = state.get("pve_consumed", [])
	if not consumed is Array or consumed.size() > 100000:
		return {"ok":false,"error":"combat_pve_history"}
	var next_consumed: Dictionary = {}
	for value: Variant in consumed:
		if not value is String or value.is_empty() or value.length() > 200 or next_consumed.has(value):
			return {"ok":false,"error":"combat_pve_history"}
		next_consumed[value] = true
	var native_state: Dictionary = _validate_native_population(state)
	if not bool(native_state.get("ok", false)):return native_state
	inventory = candidate
	_pve_consumed = next_consumed
	_native_channel_clock = float(native_state.clock)
	_native_actor_states = native_state.states
	_gear_id = inventory.gear_id
	if int(state.get("stats_schema_version", 1)) == 1:
		# Migrate the source-compatible zero-price starting appearance/radar that
		# the0.6 character displayed without recording as owned equipment.
		grant_local_starter_equipment()
		configure_gear(_gear_id)
	_reward_ids = inventory.reward_ids.duplicate()
	_encounter_serial = maxi(_encounter_serial, serial_value) + 1
	_restoring_native_state = true
	reset()
	_restoring_native_state = false
	model.player = player_state
	model.apply_player_stats(derived)
	model.elapsed = float(elapsed_value)
	model._rng_state = rng_value
	_collision_ready_at = model.elapsed + 0.75
	return {"ok": true, "gear_id": _gear_id, "engine": inventory.catalog[int(inventory.equipped.engine)]}


func snapshot() -> Dictionary:
	if _remote_active: return _remote_state.duplicate(true)
	if model.player.is_empty():
		return {"available": false, "target": {}, "dead": false}
	var state: Dictionary = model.snapshot()
	state["available"] = _ready_to_play
	state["gear_id"] = _gear_id
	state["map_index"] = _map_index
	state["encounter_id"] = "%s:%s" % [_map_index, _encounter_serial]
	state["weapon_visual_scope"] = "shared_BMI_effects_local_adaptation" if _gear_id == "12002100" else "descriptor_linked_BMI_effects"
	var source_map: Dictionary = _native_map_spawns(_map_index)
	var native_population := int(source_map.get("source_object_count", 0)) + int(source_map.get("source_region_count", 0)) > 0
	state["encounter_label"] = "POSIÇÕES NATIVAS · SIMULAÇÃO LOCAL" if native_population else "ENCONTRO LOCAL · DADOS ORIGINAIS"
	state["source_rules"] = RULES_PATH
	state["local_encounter"] = ENCOUNTER_PATH
	state["inventory"] = inventory.snapshot()
	state["actor_catalog_count"] = _monster_assets.size()
	state["native_server_rewards"] = native_server.diagnostics()
	state["native_spawns"] = native_spawns.diagnostics()
	state["native_channel_clock"] = _native_channel_clock
	state["native_map_spawns"] = source_map.duplicate(true)
	state.native_map_spawns.erase("records")
	state.native_map_spawns.erase("blocked_records")
	state["encounter_gaps"] = _encounter_gaps.duplicate()
	state["encounter_scope"] = "verified_native_DAT_positions_timers_and_SQL_weapons;local_channel_clock_AI_bridge;unsupported_states_blocked" if native_population else "explicit_local_positions;current_MEX_appearance_HP;verified_SQL_rewards_and_compatible_weapons"
	state["sp"] = model.player.get("sp", null)
	return state


func drain_events() -> Array[Dictionary]:
	var pending: Array[Dictionary] = _events.duplicate(true)
	_events.clear()
	return pending


static func _vector(value: Variant) -> Vector3:
	if value is Vector3:
		return value
	if value is Array and value.size() >= 3:
		return Vector3(float(value[0]), float(value[1]), float(value[2]))
	return Vector3.ZERO


func set_remote_mode(enabled: bool) -> void:
	if _remote_active == enabled: return
	_remote_active = enabled
	for node: Node3D in _target_nodes.values(): node.visible = not enabled
	for node: Node3D in _projectile_nodes.values(): node.visible = not enabled
	if enabled:
		_offline_traces = _traces
		_traces = []
		for trace: Dictionary in _offline_traces:
			if is_instance_valid(trace.get("node")): (trace.node as Node3D).hide()
		_remote_state = {"available":false,"target":{},"dead":false,"inventory":{}}
	else:
		for node: Node in _remote_targets.values(): node.queue_free()
		for node: Node in _remote_projectiles.values(): node.queue_free()
		_remote_targets.clear()
		_remote_projectiles.clear()
		for trace: Dictionary in _traces:
			if is_instance_valid(trace.get("node")): (trace.node as Node).queue_free()
		_traces = _offline_traces
		_offline_traces = []
		for trace: Dictionary in _traces:
			if is_instance_valid(trace.get("node")): (trace.node as Node3D).show()
		_remote_state.clear()


func apply_remote_presentation(targets: Array, projectiles: Array, state: Dictionary) -> void:
	if not _remote_active: return
	_remote_state = state.duplicate(true)
	var live: Dictionary = {}
	for target: Dictionary in targets:
		var id := int(target.id)
		live[id] = true
		if not _remote_targets.has(id) and _monster_assets.has(int(target.monster_code)):
			var result: Dictionary = Assets.instantiate(_monster_assets[int(target.monster_code)])
			if result.node != null:
				add_child(result.node)
				_remote_targets[id] = result.node
		var visual: Node3D = _remote_targets.get(id)
		if is_instance_valid(visual):
			visual.visible = not bool(target.dead)
			visual.global_position = target.position
			var velocity: Vector3 = target.velocity
			if velocity.length_squared()>0.001 and absf(velocity.normalized().dot(Vector3.UP))<0.99:
				visual.look_at(visual.global_position+velocity, Vector3.UP)
	for id: Variant in _remote_targets.keys():
		if not live.has(id):
			(_remote_targets[id] as Node).queue_free()
			_remote_targets.erase(id)
	live.clear()
	for projectile: Dictionary in projectiles:
		var id := int(projectile.id)
		live[id] = true
		if not _remote_projectiles.has(id) and not _projectile_asset.is_empty():
			var visual := _instantiate_effect(_projectile_asset)
			if visual != null:
				add_child(visual)
				_remote_projectiles[id] = visual
		var visual: Node3D = _remote_projectiles.get(id)
		if is_instance_valid(visual):
			visual.global_position = projectile.position
			var direction: Vector3 = projectile.direction
			if absf(direction.dot(Vector3.UP))<0.99: visual.look_at(visual.global_position+direction,Vector3.UP)
	for id: Variant in _remote_projectiles.keys():
		if not live.has(id):
			(_remote_projectiles[id] as Node).queue_free()
			_remote_projectiles.erase(id)


func advance_remote_visuals(delta: float) -> void:
	if not _remote_active: return
	for node: Node3D in _remote_projectiles.values(): _advance_effect(node,delta)
	for index in range(_traces.size()-1,-1,-1):
		var trace: Dictionary = _traces[index]
		trace.remaining = float(trace.remaining)-maxf(0,delta)
		if float(trace.remaining)<=0:
			(trace.node as Node).queue_free()
			_traces.remove_at(index)
		elif bool(trace.get("original",false)):
			var node: Node3D = trace.node
			node.global_position = (trace.start as Vector3).lerp(trace.finish,clampf(1.0-float(trace.remaining)/0.08,0,1))
			_advance_effect(node,delta)


func present_remote_event(event: Dictionary) -> void:
	if not _remote_active: return
	if str(event.get("type","")) in ["fired","enemy_fired"] and str(event.get("slot","primary"))=="primary":
		var start: Variant = event.get("position")
		var finish: Variant = event.get("endpoint")
		if start is Array and finish is Array and start.size()==3 and finish.size()==3:
			var origin := _vector(start)
			var endpoint := _vector(finish)
			if origin.is_finite() and endpoint.is_finite(): _add_trace(origin,endpoint,str(event.type)=="enemy_fired")
