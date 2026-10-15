class_name WorldRuntime
extends Node3D
## Local world session. Native map/portal/NPC data and explicitly labeled local
## scenario data remain separate. Missing maps never acquire replacement art.

signal map_changed(map_data: Dictionary)
signal local_event(event: Dictionary)

const CollisionModel = preload("res://scripts/world_model.gd")
const SOURCE_RULES: String = "res://assets/legacy_rules/world_rules.json"
const SOURCE_MISSIONS: String = "res://assets/legacy_rules/missions.json"
const LOCAL_SCENARIO: String = "res://assets/local_world/scenario.json"
const BASE_VISUAL: String = "res://assets/original_3d/runtime_scene.json"
const WORLD_CATALOG: String = "res://assets/original_worlds/catalog.json"
const MISSION_SUPPORT: String = "res://assets/local_world/mission_support.json"
const ACTOR_CATALOG: String = "res://assets/original_library/actors/actors.json"
const SERVICE_CATALOG: String = "res://assets/original_library/catalogs/npc_services.json"

var collision_model: RefCounted
var current_map_id: int = 0
var current_map: Dictionary = {}
var _maps: Dictionary = {}
var _source_rules: Dictionary = {}
var _scenario: Dictionary = {}
var _missions: Dictionary = {}
var _mission_content: Dictionary = {}
var _progress: Dictionary = {}
var _events: Array[Dictionary] = []
var _seen_targets: Dictionary = {}
var _wallet: Dictionary = {"credits": 0, "credits_earned": 0, "experience": 0}
var _npcs: Array[Dictionary] = []
var _portals: Array[Dictionary] = []
var _current_events: Array[Dictionary] = []
var _active_visit_events: Dictionary = {}
var _player_position: Vector3 = Vector3.ZERO
var _nearby: Dictionary = {}
var _markers: Node3D
var _transfer_cooldown: float = 0.0
var _last_transfer: Dictionary = {}
var _mission_return_maps: Dictionary = {}
var _catalog_cache: Array[Dictionary] = []
var _player_profile: Dictionary = {"level": 9, "influence": 1, "unit_kind": 1, "start_city_map_id": 2001}
var _library: Dictionary = {}
var _actor_codes: Dictionary = {}
var _mission_support_summary: Dictionary = {}
var _revision: int = 0
var _session_id: String = "local"
var _mission_page: int = 0
var _mission_page_size: int = 12
var _frame_mission_ids: Array[String] = []
var _services: Dictionary = {}
var _inventory_counts: Dictionary = {}
var _inventory_synchronized: bool = false
var _rng_state: int = 1732541
var _proof_serial: int = 0
var _seen_local_events: Dictionary = {}


func setup(catalog: Dictionary = {}) -> Dictionary:
	return configure(catalog)


func configure(catalog: Dictionary = {}) -> Dictionary:
	_maps.clear()
	_catalog_cache.clear()
	_missions.clear()
	_mission_content.clear()
	_frame_mission_ids.clear()
	_source_rules = catalog.duplicate(true) if not catalog.is_empty() else _read_dictionary(SOURCE_RULES)
	_scenario = _source_rules.get("local_scenario", {}) if _source_rules.has("local_scenario") else _read_dictionary(LOCAL_SCENARIO)
	_library = _read_dictionary(WORLD_CATALOG) if catalog.is_empty() else catalog.get("asset_catalog", {})
	var rows: Array = _source_rules.get("maps", [])
	for value: Variant in rows:
		if not value is Dictionary:
			continue
		var row: Dictionary = value
		var definition: Dictionary = row.duplicate(true) if row.has("map_id") else _source_map_definition(row)
		var identifier: int = int(definition.get("map_id", 0))
		if identifier > 0:
			_maps[identifier] = definition
	_merge_library_events()
	_load_actor_codes()
	_services.clear()
	for row: Variant in _read_dictionary(SERVICE_CATALOG).get("records", []):
		if row is Dictionary:
			_services[int(row.get("BuildingIndex", 0))] = row
	var original_missions: Array = _source_rules.get("missions", [])
	if original_missions.is_empty() and catalog.is_empty():
		original_missions = _read_dictionary(SOURCE_MISSIONS).get("records", [])
	for value: Variant in original_missions:
		if value is Dictionary:
			var identifier: String = _identifier(value.get("id", value.get("QuestIndex", "")))
			_mission_content[identifier] = {"description": value.get("description", ""), "dialogue": value.get("dialogue", {}), "_source": value.get("_source", {})}
	var compiled: Dictionary = _read_dictionary(MISSION_SUPPORT) if catalog.is_empty() else catalog.get("mission_support", {})
	var mission_rows: Array = compiled.get("records", original_missions)
	for value: Variant in mission_rows:
		if value is Dictionary:
			_register_mission(value, true)
	for value: Variant in _scenario.get("missions", []):
		if value is Dictionary:
			_register_mission(value, false)
	_mission_support_summary = compiled.get("summary", {"total": original_missions.size(), "supported": _missions.size(), "blocked": 0})
	for identifier: Variant in _missions:
		if bool(_missions[identifier].get("runtime_supported", true)):
			_frame_mission_ids.append(str(identifier))
	_build_catalog_cache()
	_revision += 1
	return {"ok": not _maps.is_empty(), "map_count": _maps.size(), "mission_count": _missions.size(), "source_mission_count": original_missions.size(), "supported_mission_count": _mission_support_summary.get("supported", 0), "scope": "local_world_session"}


func _merge_library_events() -> void:
	for key: String in ["events", "portals"]:
		var combined: Array = _source_rules.get(key, []).duplicate(true)
		var seen: Dictionary = {}
		for value: Variant in combined:
			if value is Dictionary:
				seen[_event_key(value)] = true
		var incoming: Array = _library.get(key, [])
		for value: Variant in incoming:
			if not value is Dictionary:
				continue
			var identifier: String = _event_key(value)
			if not seen.has(identifier):
				combined.append(value)
				seen[identifier] = true
		_source_rules[key] = combined


func _event_key(event: Dictionary) -> String:
	var source: Dictionary = event.get("_source", {})
	return "%s:%s:%s" % [event.get("map_id", 0), event.get("event_id", 0), source.get("offset", str(event.get("position", [])))]


func _load_actor_codes() -> void:
	_actor_codes.clear()
	var catalog: Dictionary = _read_dictionary(ACTOR_CATALOG)
	for key: Variant in catalog.get("by_monster_code", {}):
		var entry: Dictionary = catalog["by_monster_code"][key]
		var path: String = str(entry.get("scene_path", entry.get("resource_path", "")))
		if bool(entry.get("available", false)) and ResourceLoader.exists(path):
			_actor_codes[int(str(key))] = true
	for code: int in [2000000, 2028100, 2028200]:
		if ResourceLoader.exists("res://assets/original_combat/%08d.glb" % code):
			_actor_codes[code] = true
	# The first release names each model explicitly in its source descriptor.
	var combat_catalog: Dictionary = _read_dictionary("res://assets/original_combat/manifest.json")
	for entry: Variant in combat_catalog.get("models", []):
		if entry is Dictionary and str(entry.get("role", "")) == "monster":
			var code: int = int(entry.get("monster_code", entry.get("source_code", entry.get("code", 0))))
			var path: String = str(entry.get("scene_path", entry.get("resource_path", "")))
			if code > 0 and not path.is_empty() and ResourceLoader.exists(path):
				_actor_codes[code] = true


func configure_player_profile(profile: Dictionary) -> void:
	var changed: bool = false
	for key: String in ["level", "influence", "unit_kind", "start_city_map_id"]:
		if profile.has(key) and int(_player_profile.get(key, -1)) != int(profile[key]):
			_player_profile[key] = int(profile[key])
			changed = true
	if changed:
		_revision += 1


func load_map(map_id: int, spawn: Vector3 = Vector3.INF) -> Dictionary:
	if _maps.is_empty():
		configure()
	if not _maps.has(map_id):
		return _failure("unknown_map", "Mapa não consta no catálogo recuperado.")
	if not _map_available(map_id):
		return _failure("map_assets_unavailable", "O mapa está catalogado, mas seus recursos originais ainda não estão completos.")
	var definition: Dictionary = _maps[map_id]
	var metadata: Dictionary = definition.get("metadata", {})
	var metadata_path: String = str(definition.get("metadata_path", ""))
	if metadata.is_empty():
		metadata = _read_dictionary(metadata_path)
	var height_bytes: PackedByteArray = definition.get("height_bytes", PackedByteArray())
	if height_bytes.is_empty():
		height_bytes = FileAccess.get_file_as_bytes(str(definition.get("height_path", ""))) if FileAccess.file_exists(str(definition.get("height_path", ""))) else PackedByteArray()
	if metadata.is_empty() or height_bytes.is_empty():
		return _failure("map_assets_unavailable", "O mapa está catalogado, mas seus recursos ainda não foram convertidos.")
	metadata = metadata.duplicate(true)
	metadata["map_id"] = map_id
	metadata["boundary_margin"] = float(definition.get("boundary_margin", 40.0))
	metadata["flight_ceiling"] = float(definition.get("flight_ceiling", INF))
	metadata["ceiling_is_center_limit"] = true
	var water_data: Dictionary = metadata.get("water", {})
	var landing_data: Dictionary = metadata.get("landing", {})
	var water_path: String = _relative_resource(metadata_path, str(water_data.get("active_tile_flags", "")))
	var landing_path: String = _relative_resource(metadata_path, str(landing_data.get("tile_flags", "")))
	var water: PackedByteArray = definition.get("water_bytes", PackedByteArray())
	var landing: PackedByteArray = definition.get("landing_bytes", PackedByteArray())
	if water.is_empty() and FileAccess.file_exists(water_path):
		water = FileAccess.get_file_as_bytes(water_path)
	if landing.is_empty() and FileAccess.file_exists(landing_path):
		landing = FileAccess.get_file_as_bytes(landing_path)
	var collider_result: Dictionary = _read_colliders(str(definition.get("props_layout_path", "")))
	var next_model: RefCounted = CollisionModel.new()
	var errors: PackedStringArray = next_model.configure(metadata, height_bytes, collider_result["colliders"], water, landing)
	if not errors.is_empty():
		return {"ok": false, "error": "invalid_map_collision_data", "message": "; ".join(errors)}
	collision_model = next_model
	current_map_id = map_id
	current_map = definition.duplicate(true)
	current_map["metadata"] = metadata
	current_map["collision_gaps"] = collider_result["gaps"] + definition.get("library_entry", {}).get("coverage_gaps", [])
	var requested: Vector3 = spawn if spawn.is_finite() else _vector(definition.get("spawn_position", [0, 105, 170]))
	var safe_spawn: Vector3 = _safe_spawn(requested)
	_player_position = safe_spawn
	_transfer_cooldown = 2.0
	_setup_interactions(safe_spawn)
	_revision += 1
	_record_objective("visit_map", map_id)
	var bounds: Dictionary = collision_model.get_bounds()
	var result: Dictionary = {"ok": true, "map_id": map_id, "map_index": map_id, "map_title": str(definition.get("map_title", "Mapa %d" % map_id)), "visual_profile": definition.get("visual_profile", {"terrain": {}, "props": {}, "sky": {}, "clouds": {}, "environment": {}}), "spawn_position": safe_spawn, "bounds_min": bounds["min"], "bounds_max": bounds["max"], "collision_gaps": current_map["collision_gaps"]}
	current_map["spawn_position"] = safe_spawn
	current_map["bounds_min"] = bounds["min"]
	current_map["bounds_max"] = bounds["max"]
	map_changed.emit(result)
	_emit({"type": "map_loaded", "map_id": map_id, "map_title": result["map_title"], "message": "Mapa carregado: " + str(result["map_title"])})
	return result


func resolve_motion(previous: Vector3, desired: Vector3, radius: float = 4.0) -> Dictionary:
	return collision_model.resolve_motion(previous, desired, radius) if collision_model != null else _empty_collision(previous, "world_not_loaded")


func resolve_ground_motion(previous: Vector3, desired: Vector3, radius: float = 4.0) -> Dictionary:
	return collision_model.resolve_ground_motion(previous, desired, radius) if collision_model != null else _empty_collision(previous, "world_not_loaded")


func trace_segment(start: Vector3, end: Vector3, radius: float = 0.0) -> Dictionary:
	return collision_model.trace_segment(start, end, radius) if collision_model != null else _empty_collision(end, "world_not_loaded")


func sample_ground_height(x: float, z: float, include_water: bool = true) -> float:
	return collision_model.sample_ground_height(x, z, include_water) if collision_model != null else NAN


func sample_height(position: Vector3) -> float:
	return sample_ground_height(position.x, position.z)


func probe_landing(position: Vector3, radius: float = 4.0, max_distance: float = 180.0, gear_id: String = "12003100") -> Dictionary:
	return collision_model.probe_landing(position, radius, max_distance, gear_id) if collision_model != null else {"ok": false, "position": position, "normal": Vector3.UP, "distance": INF, "reason": "world_not_loaded"}


func ground_contact(position: Vector3, radius: float = 4.0) -> Dictionary:
	return collision_model.ground_contact(position, radius) if collision_model != null else {"ok": false, "position": position, "normal": Vector3.UP, "distance": INF}


func get_bounds() -> Dictionary:
	return collision_model.get_bounds() if collision_model != null else {"min": Vector3.ZERO, "max": Vector3.ZERO}


func advance(delta: float, player_position: Vector3) -> void:
	if is_finite(delta) and delta > 0.0:
		_transfer_cooldown = maxf(0.0, _transfer_cooldown - minf(delta, 1.0))
		_advance_mission_timers(delta)
	if player_position.is_finite():
		_player_position = player_position
	_nearby = _nearest_interaction(_player_position)
	_record_nearby_event_objectives()


func _record_nearby_event_objectives() -> void:
	if _active_visit_events.is_empty():
		return
	for value: Dictionary in _current_events:
		if not _active_visit_events.has(int(value.get("event_id", 0))):
			continue
		if _player_position.distance_to(_vector(value.get("position", []))) <= float(value.get("interaction_range", 120.0)):
			_record_objective("visit_event", int(value.get("event_id", 0)))


func interact_nearest(player_position: Vector3) -> Dictionary:
	_player_position = player_position
	_nearby = _nearest_interaction(player_position)
	if _nearby.is_empty():
		return _failure("nothing_nearby", "Nenhum NPC ou portal ao alcance.")
	if str(_nearby["kind"]) == "portal":
		return use_portal(str(_nearby["id"]))
	var npc: Dictionary = _nearby
	_record_objective("dialogue", int(npc.get("source_npc_index", 0)))
	var offered: Array[Dictionary] = []
	for value: Variant in _missions.values():
		var mission: Dictionary = value
		if not _mission_matches_npc(mission, npc):
			continue
		var state: Dictionary = _mission_snapshot(mission)
		offered.append(state)
	_emit({"type": "npc_dialogue", "npc_id": npc["id"], "source_npc_index": npc.get("source_npc_index", 0), "message": str(npc.get("greeting", npc.get("title", "")))})
	return {"ok": true, "kind": "npc", "npc": npc.duplicate(true), "missions": offered, "message": str(npc.get("greeting", ""))}


func accept_mission(identifier: String) -> Dictionary:
	if not _missions.has(identifier):
		return _failure("unknown_mission", "Missão não encontrada.")
	var mission: Dictionary = _missions[identifier]
	var before: Dictionary = _mission_snapshot(mission)
	if str(before["status"]) != "available":
		return _failure("mission_not_available", str(before.get("unavailable_reason", "Missão já aceita ou ainda bloqueada.")))
	if not _mission_npc_in_range(mission, false):
		return _failure("npc_required", "Aproxime-se do NPC para aceitar a missão.")
	var event_map: int = int(mission.get("event_map_id", 0))
	var on_accept: Dictionary = mission.get("on_accept", {})
	var target_map: int = int(on_accept.get("warp_map_id", event_map))
	if target_map > 0 and target_map != current_map_id and not _map_available(target_map):
		return _failure("mission_map_unavailable", "Os recursos do mapa da missão ainda não estão disponíveis.")
	_mission_return_maps[identifier] = current_map_id
	var counters: Array[int] = []
	for _objective: Variant in mission.get("objectives", []):
		counters.append(0)
	_progress[identifier] = {"status": "active", "counts": counters, "claimed": false, "elapsed_seconds": 0.0, "proof_counts": {}}
	_refresh_active_visit_events()
	if target_map > 0 and target_map != current_map_id:
		var loaded: Dictionary = load_map(target_map)
		if not bool(loaded.get("ok", false)):
			_progress.erase(identifier)
			_mission_return_maps.erase(identifier)
			_refresh_active_visit_events()
			return loaded
	_record_objective("visit_map", current_map_id)
	if not _nearby.is_empty() and str(_nearby.get("kind", "")) == "npc":
		_record_objective("dialogue", int(_nearby.get("source_npc_index", 0)))
	_revision += 1
	var granted_items: Array = _gear_items(on_accept.get("items", []))
	_emit({"type": "mission_accepted", "mission_id": identifier, "items": granted_items, "reward_id": "mission-start:" + identifier, "message": "Missão aceita: " + str(mission["title"])})
	if bool(mission.get("native", false)) and int(mission.get("end_type", -1)) == 0 and str(_mission_snapshot(mission)["status"]) == "ready":
		claim_reward(identifier)
	return {"ok": true, "mission": _mission_snapshot(mission)}


func record_target_destroyed(monster_code: int, instance_id: String = "", _position: Vector3 = Vector3.INF) -> Dictionary:
	if not instance_id.is_empty():
		if _seen_targets.has(instance_id):
			return {"ok": false, "duplicate": true}
		_seen_targets[instance_id] = true
	_record_objective("kill", monster_code)
	return {"ok": true}


func set_inventory_counts(items: Array) -> Dictionary:
	# Trusted local integration only: this cache never creates or grants an item.
	var candidate: Dictionary = {}
	for value: Variant in items:
		if not value is Dictionary:
			return _failure("invalid_inventory_snapshot", "Inventário local inválido.")
		var item: Variant = value.get("item_num", 0)
		var count: Variant = value.get("count", 0)
		if not _nonnegative_integer(item, 2147483647) or int(item) == 0 or not _nonnegative_integer(count, 1000000000):
			return _failure("invalid_inventory_snapshot", "Quantidade de item inválida.")
		candidate[int(item)] = int(candidate.get(int(item), 0)) + int(count)
		if int(candidate[int(item)]) > 1000000000:
			return _failure("invalid_inventory_snapshot", "Quantidade de item inválida.")
	if candidate != _inventory_counts or not _inventory_synchronized:
		_inventory_counts = candidate
		_inventory_synchronized = true
		_revision += 1
	return {"ok": true}


func sync_inventory_wallet(credits: int, earned_experience: int) -> Dictionary:
	# Balance may change through verified shop/craft transactions; earned XP is
	# still the exact mission ledger and cannot be minted by an economic sync.
	if credits < 0 or credits > 1000000000 or earned_experience != int(_wallet.get("experience", 0)):
		return _failure("inventory_ledger_mismatch", "Saldo ou experiência não correspondem ao progresso local.")
	if int(_wallet.get("credits", 0)) != credits:
		_wallet["credits"] = credits
		_revision += 1
	return {"ok": true}


func receive_local_event(event: Dictionary) -> Dictionary:
	# Only call after a successful game-system operation, never directly from UI.
	var kind: String = str(event.get("type", ""))
	if kind == "crafted":
		kind = "item_crafted"
	if kind == "inventory_changed":
		return set_inventory_counts(event.get("items", [])) if event.get("items", []) is Array else _failure("invalid_inventory_snapshot", "Inventário local inválido.")
	if kind not in ["skill_used", "item_used", "item_crafted"]:
		return _failure("unsupported_local_event", "Evento local não suportado.")
	if not _nonnegative_integer(event.get("item_num", 0), 2147483647) or int(event.get("item_num", 0)) <= 0 or not _nonnegative_integer(event.get("count", 1), 1000) or int(event.get("count", 1)) <= 0:
		return _failure("invalid_local_event", "Evento de item inválido.")
	var event_id: String = str(event.get("event_id", ""))
	if event_id.length() > 256:
		return _failure("invalid_local_event", "Identificador de evento inválido.")
	if not event_id.is_empty():
		if _seen_local_events.has(event_id):
			return {"ok": false, "duplicate": true}
		_seen_local_events[event_id] = true
	# Native C_REQ_USE_ITEM is deliberately still blocked: it is absent from
	# pinned EP3.5/EP4.3 grammars, so its four class alternatives are not guessed.
	var objective_kind: String = "use_item" if kind in ["skill_used", "item_used"] else "craft_item"
	for _index: int in range(int(event.get("count", 1))):
		_record_objective(objective_kind, int(event["item_num"]))
	return {"ok": true}


func service_contacts() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for npc: Dictionary in _npcs:
		var building: int = int(npc.get("source_building_index", 0))
		var service: Dictionary = _services.get(building, {})
		if service.is_empty():
			continue
		var row: Dictionary = npc.duplicate(true)
		row["building_kind"] = int(service.get("BuildingKind", -1))
		row["service_symbol"] = str(service.get("service_symbol", "")) if service.get("service_symbol") != null else ""
		row["map_id"] = current_map_id
		row["native_position"] = npc.has("source_event")
		row["source_service"] = service.duplicate(true)
		row["distance"] = _player_position.distance_to(npc["position"])
		row["in_range"] = bool(row["native_position"]) and float(row["distance"]) <= float(npc.get("range", 120.0))
		result.append(row)
	return result


func nearby_service(position: Vector3) -> Dictionary:
	if not position.is_finite():
		return {}
	var nearest: Dictionary = {}
	var distance: float = INF
	for contact: Dictionary in service_contacts():
		if not bool(contact.get("native_position", false)):
			continue
		var gap: float = position.distance_to(contact["position"])
		if gap <= float(contact.get("range", 120.0)) and gap < distance:
			nearest = contact.duplicate(true)
			nearest["distance"] = gap
			nearest["in_range"] = true
			distance = gap
	return nearest


func claim_reward(identifier: String) -> Dictionary:
	if not _missions.has(identifier):
		return _failure("unknown_mission", "Missão não encontrada.")
	var mission: Dictionary = _missions[identifier]
	if str(_mission_snapshot(mission)["status"]) != "ready":
		return _failure("mission_not_ready", "Os objetivos ainda não foram concluídos ou a recompensa já foi recebida.")
	if not _mission_npc_in_range(mission, true):
		return _failure("npc_required", "Retorne ao NPC para receber a recompensa.")
	var progress: Dictionary = _progress[identifier]
	for entry: Dictionary in mission.get("random_item_rewards", []):
		if int(entry.get("source_item_num", 0)) > 0 and _mission_item_count(int(entry["source_item_num"]), progress) > 100000:
			return _failure("local_reward_operation_limit", "Quantidade excede o limite local de sorteios por operação.")
	var prior_rng: int = _rng_state
	var reward: Dictionary = _resolved_reward(mission, progress)
	if int(reward.get("credits", 0)) < 0 or int(_wallet.get("credits", 0)) + int(reward.get("credits", 0)) > 1000000000 or reward.get("items", []).any(func(item: Variant) -> bool: return not item is Dictionary or not _nonnegative_integer(item.get("count", 0), 1000000000)):
		_rng_state = prior_rng
		return _failure("local_reward_operation_limit", "Recompensa excede o limite de uma transação local.")
	progress["status"] = "completed"
	progress["claimed"] = true
	progress["reward_credits"] = int(reward.get("credits", 0))
	progress["reward_experience"] = int(reward.get("experience", 0))
	progress["reward_items"] = reward.get("items", []).duplicate(true)
	# Persist the current inventory objective before the transaction removes it.
	for index: int in range(mission.get("objectives", []).size()):
		if str(mission.objectives[index].get("kind", "")) == "inventory":
			progress["counts"][index] = int(mission.objectives[index].get("required", 1))
	_progress[identifier] = progress
	_refresh_active_visit_events()
	var credits: int = maxi(0, int(reward.get("credits", reward.get("SPI", 0))))
	var experience: int = maxi(0, int(reward.get("experience", reward.get("XP", 0))))
	_wallet["credits"] = int(_wallet["credits"]) + credits
	_wallet["credits_earned"] = int(_wallet.get("credits_earned", 0)) + credits
	_wallet["experience"] = int(_wallet["experience"]) + experience
	var event: Dictionary = {"type": "mission_reward", "reward_id": "mission:" + identifier, "mission_id": identifier, "credits": credits, "experience": experience, "items": _gear_items(reward.get("items", [])), "removals": reward.get("removals", []), "bonus_stats": int(reward.get("bonus_stats", 0)), "message": "Recompensa recebida: " + str(mission["title"])}
	_emit(event)
	var on_complete: Dictionary = mission.get("on_complete", {})
	var return_map: int = int(on_complete.get("warp_map_id", 0))
	if return_map == 9999:
		var city: int = faction_city_map()
		if _map_available(city):
			return_map = city
			_emit({"type": "faction_city_return", "mission_id": identifier, "source_destination": 9999, "target_map": city, "adaptation": false, "message": "Retorno à cidade da facção conforme a regra original."})
		else:
			var local_return: int = int(_mission_return_maps.get(identifier, 0))
			_emit({"type": "local_return_policy", "mission_id": identifier, "source_destination": 9999, "target_map": local_return, "adaptation": true, "message": "A cidade da facção ainda não está disponível. Retorno local ao mapa de partida."})
			return_map = local_return
	_revision += 1
	if return_map > 0 and return_map != current_map_id and _map_available(return_map):
		var loaded: Dictionary = load_map(return_map)
		if not bool(loaded.get("ok", false)):
			_emit({"type": "mission_return_failed", "mission_id": identifier, "target_map": return_map, "message": "Recompensa preservada; o mapa de retorno não pôde ser carregado: " + str(loaded.get("message", ""))})
	return {"ok": true, "reward": event, "mission": _mission_snapshot(mission)}


func use_portal(identifier: String) -> Dictionary:
	if _transfer_cooldown > 0.0:
		return _failure("portal_cooldown", "Aguarde a conclusão da transferência.")
	for portal: Dictionary in _portals:
		if str(portal["id"]) != identifier:
			continue
		if _player_position.distance_to(portal["position"]) > float(portal["range"]):
			return _failure("portal_out_of_range", "Aproxime-se do portal.")
		var target: int = resolve_destination_map(int(portal["destination_map_id"]))
		if not _map_available(target):
			return _failure("destination_assets_unavailable", "O destino está catalogado, mas seus recursos ainda não estão disponíveis.")
		var destination: Vector3 = _destination_spawn(target, int(portal.get("destination_event_id", 0)))
		var from_map: int = current_map_id
		var loaded: Dictionary = load_map(target, destination)
		if bool(loaded.get("ok", false)):
			_last_transfer = {"from_map": from_map, "target_map": target, "spawn": loaded["spawn_position"], "portal_id": identifier}
			_emit({"type": "map_transfer", "from_map": from_map, "target_map": target, "spawn": loaded["spawn_position"], "message": "Transferência concluída."})
		return loaded
	return _failure("unknown_portal", "Portal não encontrado.")


func get_state() -> Dictionary:
	var active: Array[Dictionary] = []
	var primary: Dictionary = {}
	for identifier: Variant in _progress:
		if not _missions.has(identifier) or str(_progress[identifier].get("status", "")) != "active":
			continue
		var state: Dictionary = _mission_snapshot(_missions[identifier])
		if str(state["status"]) in ["active", "ready"]:
			active.append(state)
			if primary.is_empty():
				primary = state
	var missions: Array[Dictionary] = []
	var first: int = _mission_page * _mission_page_size
	for identifier: String in _frame_mission_ids.slice(first, mini(_frame_mission_ids.size(), first + _mission_page_size)):
		missions.append(_mission_snapshot(_missions[identifier]))
	if primary.is_empty():
		for candidate: Dictionary in missions:
			if primary.is_empty() or _mission_priority(str(candidate.get("status", ""))) > _mission_priority(str(primary.get("status", ""))):
				primary = candidate
	for state: Dictionary in active:
		if not missions.any(func(candidate: Dictionary) -> bool: return candidate["id"] == state["id"]):
			missions.append(state)
	return {"map_id": current_map_id, "map_index": current_map_id, "map_title": str(current_map.get("map_title", "")), "nearby_interaction": _nearby.duplicate(true), "mission": primary, "missions": missions, "active_missions": active, "wallet": _wallet.duplicate(), "map_transfer": {"cooldown": _transfer_cooldown, "last": _last_transfer.duplicate()}, "map_catalog": map_catalog(), "npc_count": _npcs.size(), "portal_count": _portals.size(), "collision_object_count": collision_model.collider_count() if collision_model != null else 0, "collision_gaps": current_map.get("collision_gaps", []), "support_diagnostics": _mission_support_summary, "world_coverage": _library.get("coverage", {}), "revision": _revision, "scope": "local_session;original_rules_and_labeled_adaptations"}


func _mission_priority(status: String) -> int:
	return int({"ready": 6, "active": 5, "available": 4, "locked": 2, "unavailable": 1, "completed": 0, "unsupported": -1}.get(status, -1))


func active_objectives() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for identifier: Variant in _progress:
		if not _missions.has(identifier) or str(_progress[identifier].get("status", "")) != "active":
			continue
		var mission: Dictionary = _missions[identifier]
		if bool(mission.get("inventory_objectives_override_drops", false)) and str(_mission_snapshot(mission).get("status", "")) == "ready":
			continue
		for objective: Dictionary in _mission_snapshot(mission).get("objectives", []):
			if int(objective.get("current", 0)) >= int(objective.get("required", 1)):
				continue
			var entry: Dictionary = objective.duplicate(true)
			entry["mission_id"] = str(identifier)
			entry["map_id"] = int(objective.get("map_id", mission.get("event_map_id", 0)))
			entry["event_map_id"] = entry["map_id"]
			entry["monster_code"] = int(objective.get("target_code", 0))
			result.append(entry)
	return result


func mission_catalog(page: int = 0, page_size: int = 12, include_blocked: bool = true) -> Dictionary:
	var rows: Array[Dictionary] = []
	for value: Variant in _missions.values():
		if include_blocked or bool(value.get("runtime_supported", true)):
			rows.append(_mission_snapshot(value))
	page_size = clampi(page_size, 1, 1000)
	var total: int = rows.size()
	var page_count: int = maxi(1, ceili(float(total) / page_size))
	page = clampi(page, 0, page_count - 1)
	return {"records": rows.slice(page * page_size, mini(total, (page + 1) * page_size)), "total": total, "page": page, "page_count": page_count, "supported_count": int(_mission_support_summary.get("supported", 0)), "blocked_count": int(_mission_support_summary.get("blocked", 0)), "revision": _revision}


func mission_details(identifier: String) -> Dictionary:
	if not _missions.has(identifier):
		return _failure("unknown_mission", "Missão não encontrada.")
	var result: Dictionary = _mission_snapshot(_missions[identifier])
	var content: Dictionary = _mission_content.get(identifier, {})
	result["description"] = str(content.get("description", ""))
	result["dialogue"] = content.get("dialogue", _missions[identifier].get("dialogue", {})).duplicate(true)
	result["_source"] = content.get("_source", {}).duplicate(true)
	result["ok"] = true
	return result


func set_mission_page(page: int, page_size: int = 12) -> void:
	_mission_page = maxi(0, page)
	_mission_page_size = clampi(page_size, 1, 1000)


func faction_city_map() -> int:
	# AtumSJ::GetCityMapIndexByInfluence:2334-2375; AtumParam.h:407-411,679-681.
	var influence: int = int(_player_profile.get("influence", 1))
	if (influence & 2) != 0:
		return 2001
	if (influence & 4) != 0:
		return 2002
	return 2002 if int(_player_profile.get("start_city_map_id", 2001)) == 2002 else 2001


func _gear_items(items: Array) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for item: Variant in items:
		if item is Dictionary and (int(item.get("gear_mask", 65535)) & int(_player_profile.get("unit_kind", 1))) != 0:
			result.append({"item_num": int(item.get("item_num", 0)), "count": int(item.get("count", 0))})
	return result


func snapshot() -> Dictionary:
	return get_state()


func map_catalog() -> Array[Dictionary]:
	return _catalog_cache


func _build_catalog_cache() -> void:
	var rows: Array[Dictionary] = []
	for identifier: Variant in _maps:
		var map: Dictionary = _maps[identifier]
		var library: Dictionary = map.get("library_entry", {})
		rows.append({"map_id": int(identifier), "map_index": int(identifier), "unavailable_reasons": map.get("unavailable_reasons", []), "coverage_gaps": library.get("coverage_gaps", []), "status": str(library.get("status", "complete" if _map_available(int(identifier)) else "unavailable")), "tile_rendering_enabled": int(map.get("source_map_info", {}).get("TileRenderingFlag", 1)) != 0, "native_non_tile_world": bool(library.get("native_non_tile_world", false)), "terrain_available": bool(library.get("terrain_available", _map_available(int(identifier)))), "props_total": int(library.get("props_total", 0)), "props_imported": int(library.get("props_imported", 0)), "title": str(map.get("map_title", "Mapa %d" % int(identifier))), "available": _map_available(int(identifier)), "source_id": int(map.get("source_map_info", {}).get("MapIndex", identifier))})
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["map_id"]) < int(b["map_id"]))
	_catalog_cache = rows


func drain_events() -> Array[Dictionary]:
	var result: Array[Dictionary] = _events.duplicate(true)
	_events.clear()
	return result


func reset_session() -> void:
	_progress.clear()
	_active_visit_events.clear()
	_seen_targets.clear()
	_wallet = {"credits": 0, "credits_earned": 0, "experience": 0}
	_rng_state = 1732541
	_proof_serial = 0
	_seen_local_events.clear()
	_mission_return_maps.clear()
	_events.clear()
	_last_transfer.clear()
	_revision += 1


func export_state() -> Dictionary:
	return {"schema_version": 1, "map_id": current_map_id, "position": [_player_position.x, _player_position.y, _player_position.z], "profile": _player_profile.duplicate(), "progress": _progress.duplicate(true), "wallet": _wallet.duplicate(), "wallet_policy": "local_balance_with_separate_native_earned_ledger", "rng_state": _rng_state, "proof_serial": _proof_serial, "seen_local_events": _seen_local_events.keys(), "seen_targets": _seen_targets.keys(), "mission_return_maps": _mission_return_maps.duplicate(), "session_id": _session_id}


func import_state(state: Dictionary) -> Dictionary:
	if int(state.get("schema_version", 0)) != 1:
		return _failure("invalid_save_version", "Formato de progresso do mundo incompatível.")
	var map_id: int = int(state.get("map_id", 0))
	if not _map_available(map_id):
		return _failure("saved_map_unavailable", "O mapa salvo ainda não possui recursos originais disponíveis.")
	var position_values: Variant = state.get("position", [])
	if not position_values is Array or position_values.size() != 3:
		return _failure("invalid_world_save", "Posição salva inválida.")
	for component: Variant in position_values:
		if not (component is int or component is float) or not is_finite(float(component)):
			return _failure("invalid_world_save", "Posição salva inválida.")
	var position: Vector3 = _vector(position_values)
	if not position.is_finite() or not state.get("progress", {}) is Dictionary or not state.get("wallet", {}) is Dictionary or not state.get("profile", {}) is Dictionary:
		return _failure("invalid_world_save", "Progresso do mundo inválido.")
	var progress: Dictionary = {}
	for key: Variant in state.get("progress", {}):
		var identifier: String = _identifier(key)
		var value: Variant = state["progress"][key]
		if not _missions.has(identifier) or not bool(_missions[identifier].get("runtime_supported", false)) or not value is Dictionary:
			return _failure("invalid_saved_mission", "Missão salva indisponível ou não suportada.")
		var status: String = str(value.get("status", ""))
		var counts: Variant = value.get("counts", [])
		var objectives: Array = _missions[identifier].get("objectives", [])
		if not status in ["active", "completed", "failed"] or not counts is Array or counts.size() != objectives.size() or not value.get("claimed", false) is bool or bool(value.get("claimed", false)) != (status == "completed"):
			return _failure("invalid_saved_mission", "Contadores de missão inválidos.")
		for index: int in range(counts.size()):
			if not (counts[index] is int or counts[index] is float) or not is_finite(float(counts[index])) or float(counts[index]) != float(int(counts[index])) or int(counts[index]) < 0 or int(counts[index]) > int(objectives[index].get("required", 1)):
				return _failure("invalid_saved_mission", "Quantidade de objetivos inválida.")
			if status == "completed" and int(counts[index]) != int(objectives[index].get("required", 1)) and not (bool(_missions[identifier].get("inventory_objectives_override_drops", false)) and str(objectives[index].get("kind", "")) == "kill"):
				return _failure("invalid_saved_mission", "Missão concluída sem objetivos completos.")
		var elapsed: Variant = value.get("elapsed_seconds", 0.0)
		if not (elapsed is int or elapsed is float) or not is_finite(float(elapsed)) or float(elapsed) < 0.0 or float(elapsed) > 604801.0:
			return _failure("invalid_saved_mission", "Tempo de missão inválido.")
		var proofs: Variant = value.get("proof_counts", {})
		if not proofs is Dictionary or proofs.size() > objectives.size():
			return _failure("invalid_saved_mission", "Itens-prova de missão inválidos.")
		for item: Variant in proofs:
			if not str(item).is_valid_int() or not _nonnegative_integer(proofs[item], 1000000000) or not objectives.any(func(objective: Variant) -> bool: return objective is Dictionary and int(objective.get("quest_item_num", 0)) == int(str(item))):
				return _failure("invalid_saved_mission", "Itens-prova de missão inválidos.")
		var limit: int = int(_missions[identifier].get("time_limit_seconds", 0))
		if status == "failed" and (limit <= 0 or float(elapsed) <= limit):
			return _failure("invalid_saved_mission", "Falha de missão sem limite de tempo excedido.")
		if status != "failed" and limit > 0 and float(elapsed) > limit:
			return _failure("invalid_saved_mission", "Tempo de missão excedido.")
		progress[identifier] = {"status": status, "counts": counts.duplicate(), "claimed": status == "completed", "elapsed_seconds": float(elapsed), "proof_counts": proofs.duplicate(), "legacy_proof_counters": bool(value.get("legacy_proof_counters", not value.has("proof_counts")))}
		if status == "completed":
			var base_reward: Dictionary = _missions[identifier].get("reward", {})
			var paid_credits: Variant = value.get("reward_credits", int(base_reward.get("credits", 0)))
			var paid_experience: Variant = value.get("reward_experience", int(base_reward.get("experience", 0)))
			if not _nonnegative_integer(paid_credits, 9000000000000000) or int(paid_credits) < int(base_reward.get("credits", 0)) or not _nonnegative_integer(paid_experience, 9000000000000000) or int(paid_experience) != int(base_reward.get("experience", 0)):
				return _failure("invalid_saved_reward", "Recompensa de missão inválida.")
			if _missions[identifier].get("per_item_rewards", []).is_empty() and int(paid_credits) != int(base_reward.get("credits", 0)):
				return _failure("invalid_saved_reward", "Saldo ganho não corresponde à missão original.")
			progress[identifier]["reward_credits"] = int(paid_credits)
			progress[identifier]["reward_experience"] = int(paid_experience)
			progress[identifier]["reward_items"] = value.get("reward_items", []).duplicate(true) if value.get("reward_items", []) is Array else []
	var wallet: Dictionary = state.get("wallet", {})
	for key: String in ["credits", "experience", "credits_earned"]:
		var value: Variant = wallet.get(key, 0)
		if not (value is int or value is float) or not is_finite(float(value)) or float(value) != float(int(value)) or int(value) < 0 or float(value) > 9.0e15:
			return _failure("invalid_saved_wallet", "Saldo salvo inválido.")
	var expected_credits: int = 0
	var expected_experience: int = 0
	for value: Dictionary in progress.values():
		if str(value.get("status", "")) == "completed":
			expected_credits += int(value.get("reward_credits", 0))
			expected_experience += int(value.get("reward_experience", 0))
	if expected_credits != int(wallet.get("credits_earned", wallet.get("credits", 0))) or expected_experience != int(wallet.get("experience", 0)):
		return _failure("invalid_saved_reward_ledger", "Saldo ganho não corresponde às missões concluídas.")
	var profile: Dictionary = state.get("profile", {})
	for key: String in ["level", "influence", "unit_kind", "start_city_map_id"]:
		var value: Variant = profile.get(key, _player_profile.get(key, 0))
		if not (value is int or value is float) or not is_finite(float(value)) or float(value) != float(int(value)) or float(value) < 0 or float(value) > 2147483647.0:
			return _failure("invalid_saved_profile", "Perfil salvo inválido.")
	var targets: Variant = state.get("seen_targets", [])
	if not targets is Array or targets.size() > 100000:
		return _failure("invalid_saved_targets", "Histórico de alvos inválido.")
	var local_events: Variant = state.get("seen_local_events", [])
	if not local_events is Array or local_events.size() > 100000:
		return _failure("invalid_saved_targets", "Histórico de eventos inválido.")
	for value: Variant in local_events:
		if not value is String or value.length() > 256:
			return _failure("invalid_saved_targets", "Histórico de eventos inválido.")
	if not _nonnegative_integer(state.get("rng_state", 1732541), 2147483647) or not _nonnegative_integer(state.get("proof_serial", 0), 1000000000):
		return _failure("invalid_saved_rng", "Estado de coleta aleatória inválido.")
	var return_maps: Variant = state.get("mission_return_maps", {})
	if not return_maps is Dictionary:
		return _failure("invalid_saved_returns", "Mapas de retorno salvos inválidos.")
	for key: Variant in return_maps:
		var value: Variant = return_maps[key]
		if not _missions.has(_identifier(key)) or not (value is int or value is float) or not is_finite(float(value)) or float(value) != float(int(value)) or not _maps.has(int(value)):
			return _failure("invalid_saved_returns", "Mapa de retorno salvo inválido.")
	var previous: Dictionary = export_state()
	_progress = progress
	_wallet = {"credits": int(wallet.get("credits", 0)), "credits_earned": int(wallet.get("credits_earned", wallet.get("credits", 0))), "experience": int(wallet.get("experience", 0))}
	_rng_state = int(state.get("rng_state", 1732541))
	_proof_serial = int(state.get("proof_serial", 0))
	_seen_local_events.clear()
	for value: String in local_events:
		_seen_local_events[value] = true
	_player_profile = profile.duplicate()
	_mission_return_maps = return_maps.duplicate()
	_seen_targets.clear()
	for value: Variant in targets:
		if value is String and value.length() <= 256:
			_seen_targets[value] = true
	_session_id = str(state.get("session_id", "local")).left(128)
	var loaded: Dictionary = load_map(map_id, position)
	if not bool(loaded.get("ok", false)):
		_progress = previous["progress"]
		_wallet = previous["wallet"]
		_player_profile = previous["profile"]
		_mission_return_maps = previous["mission_return_maps"]
		_session_id = str(previous.get("session_id", "local"))
		_rng_state = int(previous.get("rng_state", 1732541))
		_proof_serial = int(previous.get("proof_serial", 0))
		_seen_local_events.clear()
		for value: String in previous.get("seen_local_events", []):
			_seen_local_events[value] = true
		_refresh_active_visit_events()
		_seen_targets.clear()
		for value: Variant in previous["seen_targets"]:
			_seen_targets[value] = true
		return loaded
	_revision += 1
	_emit({"type": "world_progress_restored", "message": "Progresso local restaurado."})
	return {"ok": true, "map_id": current_map_id, "position": _player_position, "revision": _revision}


func _source_map_definition(row: Dictionary) -> Dictionary:
	var identifier: int = int(row.get("MapIndex", 0))
	var dat_id: int = int(row.get("Dat", identifier))
	if dat_id == 0:
		dat_id = identifier
	var base: String = "res://assets/original_worlds/%d/" % dat_id
	if not FileAccess.file_exists(base + "%d_terrain.json" % dat_id) and dat_id == 3002:
		base = "res://assets/original_world/"
	var props_path: String = "res://assets/original_worlds/%d/props/placements.json" % dat_id
	if dat_id == 3002:
		props_path = "res://assets/original_props/placements.json"
	var definition: Dictionary = {"map_id": identifier, "map_title": str(row.get("MapName", "Mapa %d" % identifier)), "source_map_info": row, "metadata_path": base + "%d_terrain.json" % dat_id, "height_path": base + "%d_heights.f32" % dat_id, "props_layout_path": props_path if FileAccess.file_exists(props_path) else "", "flight_ceiling": float(row.get("ClientMaxAltitudeHeight", 2400)) + float(row.get("WaterHeight", 0)), "boundary_margin": 40.0, "spawn_position": [0,105,170]}
	var library_entry: Dictionary = _library_map(identifier)
	if not library_entry.is_empty():
		for pair: Array in [["terrain_metadata", "metadata_path"], ["height_path", "height_path"], ["props_path", "props_layout_path"]]:
			if library_entry.has(pair[0]):
				definition[pair[1]] = library_entry[pair[0]]
		definition["library_entry"] = library_entry
		definition["unavailable_reasons"] = library_entry.get("unavailable_reasons", [])
	definition["visual_profile"] = library_entry.get("visual_profile", _visual_profile(row, definition))
	return definition


func _library_map(identifier: int) -> Dictionary:
	var by_id: Dictionary = _library.get("by_map_id", _library.get("by_id", {}))
	if by_id.has(str(identifier)):
		return by_id[str(identifier)]
	for value: Variant in _library.get("records", []):
		if value is Dictionary and int(value.get("map_id", value.get("MapIndex", value.get("map_index", 0)))) == identifier:
			return value
	return {}


func _visual_profile(row: Dictionary, definition: Dictionary) -> Dictionary:
	var baseline: Dictionary = _read_dictionary(BASE_VISUAL)
	var result: Dictionary = {"terrain": {}, "props": {}, "sky": {}, "clouds": {}, "environment": {}}
	var metadata: Dictionary = _read_dictionary(str(definition["metadata_path"]))
	var dat_id: int = int(row.get("Dat", row.get("MapIndex", 0)))
	var terrain_path: String = str(definition.get("library_entry", {}).get("terrain_path", str(definition["metadata_path"]).get_base_dir() + "/%d_terrain.glb" % dat_id))
	if not metadata.is_empty() and ResourceLoader.exists(terrain_path):
		var bounds: Array = metadata.get("target_bounds", [])
		result["terrain"] = {"source_id": str(dat_id), "name": "OriginalTerrain%d" % int(row.get("MapIndex", dat_id)), "resource_path": terrain_path, "position": [0,0,0], "rotation_degrees": [0,0,0], "scale": [1,1,1], "expected_triangles": int(metadata.get("geometry", {}).get("triangle_count", 0)), "expected_aabb_min": bounds[0] if bounds.size() == 2 else [], "expected_aabb_max": bounds[1] if bounds.size() == 2 else []}
	var props_path: String = str(definition.get("props_layout_path", ""))
	if FileAccess.file_exists(props_path):
		result["props"] = {"layout_path": props_path}
	for pair: Array in [["sky","Sky","sky"],["clouds","Cloud","cloud"]]:
		var kind: String = pair[0]
		var resource_id: int = int(row.get(pair[1], 0))
		var path: String = str(definition.get("library_entry", {}).get("%s_path" % kind, "res://assets/original_sky/%d_%s.glb" % [resource_id, pair[2]]))
		if ResourceLoader.exists(path):
			var original: Dictionary = baseline.get(kind, {})
			if resource_id == 3002 and not original.is_empty():
				result[kind] = original.duplicate(true)
			else:
				var scale_value: float = float(row.get("DayFogEndDistance", 3500)) / 133.0
				result[kind] = {"resource_path": path, "position": [0,0,0], "rotation_degrees": [0,90,0], "scale": [scale_value,scale_value,scale_value], "name": "Original%s%d" % [kind,resource_id]}
	var project_value: Variant = row.get("project", {})
	var project: Dictionary = project_value if project_value is Dictionary else {}
	result["environment"] = baseline.get("environment", {}).duplicate(true)
	result["environment"]["source_diffuse_day"] = project.get("diffuse_day", [1,1,1])
	result["environment"]["source_ambient_day"] = project.get("ambient_day", [0.35,0.35,0.35])
	result["environment"]["source_day_sun_direction"] = row.get("DaySunDirection", [1,-2,1])
	result["environment"]["source_day_fog_color"] = row.get("DayFogColor", 0)
	return result


func _map_available(identifier: int) -> bool:
	if not _maps.has(identifier):
		return false
	var definition: Dictionary = _maps[identifier]
	if definition.get("height_bytes", PackedByteArray()).size() > 0:
		return not (definition.get("metadata", {}) as Dictionary).is_empty()
	var library_entry: Dictionary = definition.get("library_entry", {})
	if library_entry.has("available") and not bool(library_entry["available"]):
		return false
	var terrain_path: String = str(definition.get("visual_profile", {}).get("terrain", {}).get("resource_path", ""))
	var native_grid: bool = FileAccess.file_exists(str(definition.get("height_path", ""))) and FileAccess.file_exists(str(definition.get("metadata_path", "")))
	if int(definition.get("source_map_info", {}).get("TileRenderingFlag", 1)) == 0:
		# MAP is deliberately absent on native object/sky-only maps. A recovered
		# DAT/grid/layout is still required; never authorize invented terrain.
		return native_grid and bool(library_entry.get("native_non_tile_world", false)) and FileAccess.file_exists(str(definition.get("props_layout_path", "")))
	return native_grid and ResourceLoader.exists(terrain_path)


func _safe_spawn(requested: Vector3) -> Vector3:
	var bounds: Dictionary = collision_model.get_bounds()
	var minimum: Vector3 = bounds["min"]
	var maximum: Vector3 = bounds["max"]
	var position: Vector3 = requested.clamp(minimum + Vector3(8,0,8), maximum - Vector3(8,0,8))
	var ground: float = collision_model.sample_ground_height(position.x, position.z)
	position.y = minf(maxf(position.y, ground + 120.0), maximum.y - 20.0)
	return position


func _setup_interactions(spawn: Vector3) -> void:
	_npcs.clear()
	_portals.clear()
	_current_events.clear()
	for value: Variant in _source_rules.get("events", []):
		if value is Dictionary and int(value.get("map_id", 0)) == current_map_id:
			_current_events.append(value)
	_refresh_active_visit_events()
	_nearby.clear()
	for value: Variant in _source_rules.get("portals", []):
		if not value is Dictionary or int(value.get("map_id", 0)) != current_map_id:
			continue
		var portal: Dictionary = value.duplicate(true)
		portal["id"] = "portal:%d:%d" % [current_map_id,int(portal.get("event_id",0))]
		portal["position"] = _vector(portal.get("position", [0,0,0]))
		portal["range"] = 500.0
		portal["kind"] = "portal"
		portal["title"] = "Portal → " + _map_title(resolve_destination_map(int(portal.get("destination_map_id",0))))
		_portals.append(portal)
	var source_npc_ids: Dictionary = {}
	for value: Variant in _source_rules.get("events", []):
		if not value is Dictionary or int(value.get("map_id", 0)) != current_map_id or int(value.get("event_type", 0)) != 9:
			continue
		var parameters: Array = value.get("parameters", [])
		if parameters.size() < 2:
			continue
		var building: int = int(parameters[1])
		var source: Dictionary = _source_npc_by_building(building)
		if source.is_empty():
			continue
		var identifier: String = "npc:%d:%d:%s:%s" % [current_map_id, building, value.get("event_id", 0), value.get("_source", {}).get("record_index", 0)]
		var npc: Dictionary = {"id": identifier, "kind": "npc", "source_npc_index": int(source.get("NPCIndex", 0)), "source_building_index": building, "title": str(source.get("NPCName", "NPC")), "greeting": str(source.get("GreetingTalk", "")), "position": _vector(value.get("position", [])), "range": 120.0, "source_record": source, "source_event": value.get("_source", {}), "provenance_label": "Nome, edifício e posição originais; interação local a 120 unidades"}
		_npcs.append(npc)
		source_npc_ids[int(source.get("NPCIndex", 0))] = true
	for value: Variant in _scenario.get("npc_placements", []):
		if not value is Dictionary:
			continue
		var data: Dictionary = value
		if source_npc_ids.has(int(data.get("source_npc_index", 0))):
			continue
		var map_ids: Array = data.get("map_ids", [])
		var map_matches: bool = bool(data.get("all_available_maps", false))
		for map_value: Variant in map_ids:
			if int(map_value) == current_map_id:
				map_matches = true
		if not map_matches:
			continue
		var source: Dictionary = _source_npc(int(data.get("source_npc_index",0)), int(data.get("source_building_index",0)))
		var npc: Dictionary = data.duplicate(true)
		npc["kind"] = "npc"
		npc["title"] = str(source.get("NPCName", "NPC local"))
		npc["greeting"] = str(source.get("GreetingTalk", "Missões e diálogo nesta sessão local."))
		npc["position"] = spawn + _vector(data.get("offset_from_spawn", [55,0,-10]))
		npc["range"] = float(data.get("interaction_range",120.0))
		npc["source_record"] = source
		_npcs.append(npc)
	_build_markers()
	_nearby = _nearest_interaction(spawn)


func _source_npc_by_building(building_index: int) -> Dictionary:
	for value: Variant in _source_rules.get("npcs", []):
		if value is Dictionary and int(value.get("BuildingIndex", 0)) == building_index:
			return value
	return {}


func resolve_destination_map(identifier: int) -> int:
	if identifier == 9999:
		return faction_city_map()
	if identifier == 9998:
		# AtumSJ::GetGargenMapIndexByInfluence:2388-2400.
		return 3018 if (int(_player_profile.get("influence", 1)) & 4) != 0 else 3002
	return identifier


func _source_npc(npc_index: int, building_index: int = 0) -> Dictionary:
	for value: Variant in _source_rules.get("npcs", []):
		if value is Dictionary and int(value.get("NPCIndex",0)) == npc_index and (building_index == 0 or int(value.get("BuildingIndex",0)) == building_index):
			return value
	return {}


func _nearest_interaction(position: Vector3) -> Dictionary:
	var nearest: Dictionary = {}
	var distance: float = INF
	var candidates: Array = []
	candidates.append_array(_npcs)
	candidates.append_array(_portals)
	for candidate: Dictionary in candidates:
		var gap: float = position.distance_to(candidate["position"])
		if gap <= float(candidate["range"]) and gap < distance:
			nearest = candidate.duplicate(true)
			nearest["distance"] = gap
			distance = gap
	return nearest


func _destination_spawn(map_id: int, event_id: int) -> Vector3:
	for value: Variant in _source_rules.get("events", []):
		if value is Dictionary and int(value.get("map_id",0)) == map_id and int(value.get("event_id",0)) == event_id:
			var position: Vector3 = _vector(value.get("position", [0,0,0]))
			var direction: Vector3 = _vector(value.get("direction_legacy", [0,0,1]))
			direction.z = -direction.z
			var front_distance: float = float(_maps.get(map_id, {}).get("source_map_info", {}).get("FrontPositionDistance", 80.0))
			return position + direction.normalized() * front_distance
	return Vector3.INF


func _register_mission(raw: Dictionary, native: bool) -> void:
	var data: Dictionary = raw.get("runtime", raw.get("normalized", raw))
	var identifier: String = _identifier(data.get("id", data.get("QuestIndex", "")))
	if identifier.is_empty():
		return
	var mission: Dictionary = data.duplicate(true)
	mission["id"] = identifier
	mission["title"] = str(data.get("title", data.get("QuestName", identifier)))
	mission["provenance_label"] = str(data.get("provenance_label", "Missão original recuperada" if native else "Missão local de demonstração"))
	mission["native"] = native
	var objectives: Array = data.get("objectives", [])
	if objectives.is_empty() and data.get("objective", {}) is Dictionary and not (data.get("objective", {}) as Dictionary).is_empty():
		objectives.append(data["objective"])
	mission["objectives"] = objectives
	mission["reward"] = data.get("reward", {})
	mission["runtime_supported"] = bool(data.get("runtime_supported", not native))
	if native and not data.has("runtime_supported"):
		mission["blocked_reasons"] = ["missing_verified_runtime_compilation"]
	if native:
		mission["required_level_min"] = int(data.get("required_level_min", _quest_level_min(data)))
	# Retain raw AST/provenance in source_rules only, outside frame snapshots.
	for key: String in ["dsl_ast", "_source", "runtime", "normalized", "description", "QuestName"]:
		mission.erase(key)
	_missions[identifier] = mission


func _quest_level_min(data: Dictionary) -> int:
	for section: Variant in data.get("dsl_ast", []):
		if not section is Dictionary or str(section.get("name", "")) != "START_REQ":
			continue
		for requirement: Variant in section.get("children", []):
			if requirement is Dictionary and str(requirement.get("name", "")) == "S_REQ_LEVEL":
				for token: Variant in requirement.get("tokens", []):
					if str(token).is_valid_int():
						return int(token)
	return 1


func _mission_snapshot(mission: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for key: String in ["id", "title", "provenance_label", "native", "reward", "giver_npc_id", "turn_in_npc_id", "npc_id", "event_map_id", "on_accept", "on_complete", "next_quest_id", "runtime_supported", "blocked_reasons", "required_level_min", "required_level_max", "required_influence", "required_gear_mask", "start_type", "end_type", "adaptations", "prerequisites", "time_limit_seconds", "per_item_rewards", "random_item_rewards", "inventory_objectives_override_drops"]:
		if mission.has(key):
			result[key] = mission[key].duplicate(true) if mission[key] is Dictionary or mission[key] is Array else mission[key]
	var identifier: String = str(mission["id"])
	var progress: Dictionary = _progress.get(identifier, {})
	var state: String = str(progress.get("status", "available"))
	if progress.is_empty():
		var level: int = int(_player_profile.get("level", 9))
		var influence: int = int(_player_profile.get("influence", 1))
		var unit_kind: int = int(_player_profile.get("unit_kind", 1))
		if level < int(mission.get("required_level_min", 1)) or level > int(mission.get("required_level_max", 2147483647)) or (int(mission.get("required_influence", 0)) > 0 and (influence & int(mission["required_influence"])) == 0) or (int(mission.get("required_gear_mask", 65535)) & unit_kind) == 0:
			state = "locked"
			result["unavailable_reason"] = "Perfil local não atende nível, facção ou classe exigidos pela missão original."
		for required_id: Variant in mission.get("prerequisites", []):
			if str(_progress.get(_identifier(required_id), {}).get("status", "")) != "completed":
				state = "locked"
				result["unavailable_reason"] = "Conclua a missão anterior: " + _identifier(required_id)
		var availability: String = _mission_asset_block(mission)
		if not availability.is_empty():
			state = "unavailable"
			result["unavailable_reason"] = availability
		if not bool(mission.get("runtime_supported", true)):
			state = "unsupported"
			result["unavailable_reason"] = "Script preservado; condições ainda não implementadas: " + ", ".join(mission.get("blocked_reasons", []))
	var counts: Array = progress.get("counts", [])
	var objectives: Array = mission.get("objectives", []).duplicate(true)
	var ready: bool = not objectives.is_empty()
	var mixed_override: bool = bool(mission.get("inventory_objectives_override_drops", false))
	for index: int in range(objectives.size()):
		var current: int = int(counts[index]) if index < counts.size() else 0
		if state == "active" and str(objectives[index].get("kind", "")) == "inventory":
			current = mini(int(objectives[index].get("required", 1)), int(_inventory_counts.get(int(objectives[index].get("item_num", 0)), 0)))
		elif state == "active" and objectives[index].has("quest_item_num") and _inventory_synchronized and not bool(progress.get("legacy_proof_counters", false)):
			current = mini(int(objectives[index].get("required", 1)), int(_inventory_counts.get(int(objectives[index]["quest_item_num"]), 0)))
		objectives[index]["current"] = current
		if current < int(objectives[index].get("required", 1)) and not (mixed_override and str(objectives[index].get("kind", "")) == "kill"):
			ready = false
	if state == "active" and ready:
		state = "ready"
	result["status"] = state
	result["disabled_reason"] = result.get("unavailable_reason", "")
	result["available"] = state == "available"
	result["objectives"] = objectives
	result["objective"] = objectives[0] if not objectives.is_empty() else {}
	if int(mission.get("time_limit_seconds", 0)) > 0:
		result["elapsed_seconds"] = float(progress.get("elapsed_seconds", 0.0))
		result["remaining_seconds"] = maxf(0.0, int(mission["time_limit_seconds"]) - float(progress.get("elapsed_seconds", 0.0)))
	if state == "failed":
		result["disabled_reason"] = "Limite de tempo original excedido; nenhuma recompensa foi concedida."
	return result


func _refresh_active_visit_events() -> void:
	_active_visit_events.clear()
	for identifier: Variant in _progress:
		if not _missions.has(identifier) or str(_progress[identifier].get("status", "")) != "active":
			continue
		for objective: Variant in _missions[identifier].get("objectives", []):
			if objective is Dictionary and str(objective.get("kind", "")) == "visit_event" and int(objective.get("map_id", 0)) == current_map_id:
				_active_visit_events[int(objective.get("event_id", 0))] = true


func _mission_asset_block(mission: Dictionary) -> String:
	var map_id: int = int(mission.get("on_accept", {}).get("warp_map_id", mission.get("event_map_id", 0)))
	if map_id > 0 and not _map_available(map_id):
		return "Mapa da missão ainda sem recursos originais completos: %d" % map_id
	for objective: Variant in mission.get("objectives", []):
		if not objective is Dictionary:
			return "Objetivo inválido; execução bloqueada."
		if str(objective.get("kind", "")) == "kill" and not _actor_codes.has(int(objective.get("target_code", 0))):
			return "Modelo original do inimigo ainda indisponível: %d" % int(objective.get("target_code", 0))
		if str(objective.get("kind", "")) == "visit_event":
			if not _map_available(int(objective.get("map_id", 0))):
				return "Mapa do objetivo de navegação ainda indisponível."
			var found: bool = false
			for event: Variant in _source_rules.get("events", []):
				if event is Dictionary and int(event.get("map_id", 0)) == int(objective.get("map_id", 0)) and int(event.get("event_id", 0)) == int(objective.get("event_id", 0)):
					found = true
			if not found:
				return "Posição original do objetivo de navegação ainda indisponível."
	return ""


func _record_objective(kind: String, target: int) -> void:
	for identifier: Variant in _progress.keys():
		var progress: Dictionary = _progress[identifier]
		if str(progress.get("status", "")) != "active":
			continue
		var mission: Dictionary = _missions[identifier]
		var required_map: int = int(mission.get("event_map_id", mission.get("map_id", 0)))
		if kind == "kill" and required_map > 0 and current_map_id != required_map:
			continue
		var objectives: Array = mission.get("objectives", [])
		var counts: Array = progress.get("counts", [])
		var changed: bool = false
		for index: int in range(objectives.size()):
			var objective: Dictionary = objectives[index]
			var expected: int = int(objective.get("target_code", objective.get("npc_id", objective.get("event_id", objective.get("map_id", 0)))))
			if kind == "visit_event" and int(objective.get("map_id", 0)) != current_map_id:
				continue
			if str(objective.get("kind", "")) == kind and expected == target:
				var amount: int = 1
				if kind == "kill" and objective.has("quest_item_num"):
					var probability: int = int(objective.get("drop_probability", 1000000))
					if probability <= 0 or probability < _random_int(0, 999999):
						continue
					amount = _random_int(int(objective.get("drop_min", 1)), int(objective.get("drop_max", 1)))
					if amount <= 0:
						continue
					var item: int = int(objective["quest_item_num"])
					var proofs: Dictionary = progress.get("proof_counts", {})
					proofs[str(item)] = int(proofs.get(str(item), 0)) + amount
					progress["proof_counts"] = proofs
					changed = true
					_proof_serial += 1
					_emit({"type": "mission_item_collected", "mission_id": str(identifier), "reward_id": "mission-proof:%s:%d" % [str(identifier), _proof_serial], "items": [{"item_num": item, "count": amount}], "message": "Item de missão recuperado: %d ×%d" % [item, amount], "native_drop_probability": probability, "scope": "native_drop_rule;local_persisted_rng;local_encounter"})
				var next: int = mini(int(objective.get("required", 1)), int(counts[index]) + amount)
				changed = changed or next != int(counts[index])
				counts[index] = next
		if changed:
			progress["counts"] = counts
			_progress[identifier] = progress
			_revision += 1
			_emit({"type": "mission_progress", "mission_id": str(identifier), "message": "Objetivo atualizado: " + str(mission["title"])})


func _advance_mission_timers(delta: float) -> void:
	for identifier: Variant in _progress:
		var progress: Dictionary = _progress[identifier]
		var limit: int = int(_missions.get(identifier, {}).get("time_limit_seconds", 0))
		if limit <= 0 or str(progress.get("status", "")) != "active":
			continue
		var before: float = float(progress.get("elapsed_seconds", 0.0))
		var elapsed: float = minf(limit + 1.0, before + delta)
		progress["elapsed_seconds"] = elapsed
		if elapsed > limit:
			progress["status"] = "failed"
			_emit({"type": "mission_failed", "mission_id": str(identifier), "message": "Limite de tempo excedido: " + str(_missions[identifier].get("title", identifier))})
		if int(before) != int(elapsed) or str(progress.get("status", "")) == "failed":
			_revision += 1
		_progress[identifier] = progress
	_refresh_active_visit_events()


func _random_int(minimum: int, maximum: int) -> int:
	# This local sequence is portable and safely representable in save JSON.
	# Native numeric probabilities/count ranges are preserved; sequence differs.
	_rng_state = (_rng_state * 1103515245 + 12345) & 2147483647
	return minimum + _rng_state % maxi(1, maximum - minimum + 1)


func _mission_item_count(item: int, progress: Dictionary) -> int:
	if _inventory_synchronized:
		return int(_inventory_counts.get(item, 0))
	return int(progress.get("proof_counts", {}).get(str(item), 0))


func _resolved_reward(mission: Dictionary, progress: Dictionary) -> Dictionary:
	var reward: Dictionary = mission.get("reward", {}).duplicate(true)
	reward["items"] = reward.get("items", []).duplicate(true)
	for entry: Dictionary in mission.get("per_item_rewards", []):
		if (int(entry.get("gear_mask", 65535)) & int(_player_profile.get("unit_kind", 1))) == 0:
			continue
		var count: int = _mission_item_count(int(entry["source_item_num"]), progress)
		reward["credits"] = int(reward.get("credits", 0)) + count * int(entry.get("credits", 0))
		if int(entry.get("item_num", 0)) > 0 and count > 0:
			reward["items"].append({"item_num": int(entry["item_num"]), "count": count * int(entry.get("count", 1)), "gear_mask": int(entry.get("gear_mask", 65535))})
	for entry: Dictionary in mission.get("random_item_rewards", []):
		var count: int = _mission_item_count(int(entry.get("source_item_num", 0)), progress) if int(entry.get("source_item_num", 0)) > 0 else 1
		var additions: Dictionary = {}
		for _index: int in range(count):
			var roll: int = _random_int(0, 99)
			var cumulative: int = 0
			for choice: Dictionary in entry.get("choices", []):
				cumulative += int(choice.get("weight", 0))
				if roll < cumulative:
					var item: int = int(choice.get("item_num", 0))
					additions[item] = int(additions.get(item, 0)) + int(choice.get("count", 0))
					break
		for item: int in additions:
			reward["items"].append({"item_num": item, "count": int(additions[item]), "gear_mask": 65535})
	var removals: Array[Dictionary] = []
	for entry: Dictionary in mission.get("delete_items", []):
		if (int(entry.get("gear_mask", 65535)) & int(_player_profile.get("unit_kind", 1))) == 0:
			continue
		# Legacy v0.6 proof counters never created physical items. Delete only
		# actual inventory here; a restored old mission cannot remove a phantom.
		var available: int = int(_inventory_counts.get(int(entry.get("item_num", 0)), 0)) if _inventory_synchronized else 0
		var count: int = available if int(entry.get("count", -1)) == -1 else mini(available, int(entry.get("count", 0)))
		if count > 0:
			removals.append({"item_num": int(entry["item_num"]), "count": count})
	reward["removals"] = removals
	return reward


static func _nonnegative_integer(value: Variant, maximum: int) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) == float(int(value)) and int(value) >= 0 and int(value) <= maximum


func _mission_matches_npc(mission: Dictionary, npc: Dictionary) -> bool:
	var giver: String = str(mission.get("giver_npc_id", ""))
	var native_npc: int = int(mission.get("npc_id", 0))
	return (giver.is_empty() and native_npc == 0) or giver == str(npc["id"]) or native_npc == int(npc.get("source_npc_index", 0))


func _mission_npc_in_range(mission: Dictionary, claiming: bool) -> bool:
	# QUEST_END_TYPE_REQESTED_BY_CLIENT is completed from the mission UI.
	if claiming and bool(mission.get("native", false)) and int(mission.get("end_type", -1)) == 1:
		return true
	var key: String = "turn_in_npc_id" if claiming else "giver_npc_id"
	var required: String = str(mission.get(key, ""))
	var native_npc: int = int(mission.get("npc_id", 0))
	if required.is_empty() and native_npc == 0:
		return true
	for npc: Dictionary in _npcs:
		if (required == str(npc["id"]) or (required.is_empty() and native_npc == int(npc.get("source_npc_index",0)))) and _player_position.distance_to(npc["position"]) <= float(npc["range"]):
			return true
	return false


func _read_colliders(layout_path: String) -> Dictionary:
	var colliders: Array[Dictionary] = []
	var gaps: Array[String] = []
	var layout: Dictionary = _read_dictionary(layout_path)
	for value: Variant in layout.get("models", []):
		if not value is Dictionary:
			continue
		var model: Dictionary = value
		var source: Dictionary = model.get("source_mapobjectinfo", {})
		if int(source.get("collision",0)) != 1:
			continue
		var mesh: Dictionary = model.get("collision_mesh", {})
		var path: String = str(mesh.get("path", ""))
		var geometry: Dictionary = _read_dictionary(path)
		if geometry.is_empty():
			gaps.append("source_collision_mesh_unavailable:%s" % str(model.get("code", "")))
			continue
		if not str(mesh.get("sha256", "")).is_empty() and FileAccess.get_sha256(path) != str(mesh["sha256"]):
			gaps.append("source_collision_mesh_hash_mismatch:%s" % str(model.get("code", "")))
			continue
		var triangles: Array = geometry.get("triangles", [])
		for placement: Dictionary in model.get("placements", []):
			var values: Array = placement.get("transform_columns", [])
			if values.size() != 12:
				gaps.append("invalid_source_collision_placement")
				continue
			var basis: Basis = Basis(_vector(values.slice(0,3)),_vector(values.slice(3,6)),_vector(values.slice(6,9)))
			colliders.append({"id": "%s:%s" % [str(model.get("code", "")),str(placement.get("source_record_index", ""))], "source_code": int(model.get("code",0)), "collision":1, "transform":Transform3D(basis,_vector(values.slice(9,12))), "triangles":triangles})
	return {"colliders":colliders,"gaps":gaps}


func _build_markers() -> void:
	if is_instance_valid(_markers):
		remove_child(_markers)
		_markers.queue_free()
	_markers = Node3D.new()
	_markers.name = "WorldInteractionLabels"
	add_child(_markers)
	if DisplayServer.get_name() == "headless":
		return
	var candidates: Array = []
	candidates.append_array(_npcs)
	candidates.append_array(_portals)
	for interaction: Dictionary in candidates:
		var label: Label3D = Label3D.new()
		label.name = str(interaction["id"]).validate_node_name()
		label.text = str(interaction["title"])
		label.position = (interaction["position"] as Vector3) + Vector3.UP * (80.0 if str(interaction["kind"]) == "portal" else 12.0)
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		if ResourceLoader.exists("res://assets/fonts/ACE-Korean.otf"):
			label.font = load("res://assets/fonts/ACE-Korean.otf")
		label.font_size = 24
		label.pixel_size = 0.12
		label.layers = 1
		label.set_meta("provenance_label", str(interaction.get("provenance_label", "Evento original recuperado")))
		_markers.add_child(label)


func _map_title(identifier: int) -> String:
	return str(_maps.get(identifier, {}).get("map_title", "Mapa %d" % identifier))


func _emit(event: Dictionary) -> void:
	_events.append(event.duplicate(true))
	local_event.emit(event.duplicate(true))


static func _identifier(value: Variant) -> String:
	return str(int(value)) if value is int or value is float else str(value)


static func _failure(error: String, message: String) -> Dictionary:
	return {"ok":false,"error":error,"message":message}


static func _empty_collision(position: Vector3, error: String) -> Dictionary:
	return {"collided":false,"position":position,"normal":Vector3.ZERO,"kind":"","object_id":"","t":1.0,"error":error}


static func _read_dictionary(path: String) -> Dictionary:
	if path.is_empty() or not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


static func _relative_resource(metadata_path: String, filename: String) -> String:
	if filename.is_empty() or filename.begins_with("res://") or filename.begins_with("user://"):
		return filename
	return metadata_path.get_base_dir().path_join(filename)


static func _vector(value: Variant) -> Vector3:
	if value is Vector3:
		return value
	if value is Array and value.size() >= 3:
		return Vector3(float(value[0]),float(value[1]),float(value[2]))
	return Vector3.ZERO
