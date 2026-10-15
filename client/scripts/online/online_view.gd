extends Node
## Authoritative arena presentation and input. No client-side damage or progression.
const Client = preload("res://scripts/online/online_client.gd")
const Flight = preload("res://scripts/flight_model.gd")
const Assets = preload("res://scripts/original_asset.gd")
const NativeInventory = preload("res://scripts/inventory_model.gd")
const MAP_ID := 3002
const GEAR_ID := "12003100"
const GEAR_IDS := ["12000100", "12001100", "12002100", "12003100"]
const INPUT_STEP := 1.0 / 30.0
const MAX_COORD := 2000000.0
const STATS := ["attack", "defense", "fuel", "soul", "shield", "dodge"]

var game: Node3D
var client: Node
var active := false
var _restoring := false
var _closing := false
var _starting := false
var _checkpoint: Dictionary = {}
var _offline_model: RefCounted
var _offline_paused := false
var _offline_loading := false
var _state: Dictionary = {}
var _combat: Dictionary = {}
var _inventory: Dictionary = {}
var _skills: Dictionary = {}
var _self: Dictionary = {}
var _input_sequence := -1
var _input_elapsed := 0.0
var _command_serial := 0
var _command_prefix := Crypto.new().generate_random_bytes(8).hex_encode()
var _peers: Dictionary = {}
var _visual_signature := ""
var _last_status := "offline"


func setup(owner_game: Node3D, transport: Node = null) -> void:
	game = owner_game
	client = transport if transport != null else Client.new()
	if client.get_parent() == null: add_child(client)
	client.status_changed.connect(_status_changed)
	client.snapshot_received.connect(_receive_snapshot)
	client.event_received.connect(_receive_event)
	client.command_result.connect(_command_result)
	_publish_status()


func connect_online(url: String, token: String, gear_id: String = "") -> Dictionary:
	if active or game == null or not game._combat_ready or game._loading_progress:
		return {"ok": false, "message": "Aguarde a sessão atual ou desconecte antes de conectar."}
	if not Client.valid_url(url):
		return {"ok": false, "message": "Informe um endereço WSS válido; WS é permitido apenas em loopback."}
	if not gear_id.is_empty() and gear_id not in GEAR_IDS:
		return {"ok": false, "message": "Escolha uma das quatro classes de GEAR."}
	_checkpoint = game._capture_local_progress().duplicate(true)
	_offline_model = game.model
	_offline_paused = game.is_paused
	_offline_loading = game._loading_progress
	active = true # Authority changes before connection/auth callbacks or input can run.
	game._loading_progress = true
	game._primary_held = false
	game._secondary_held = false
	game._target_next = false
	game.is_paused = false
	_state.clear()
	_combat.clear()
	_inventory.clear()
	_skills.clear()
	_self.clear()
	_input_sequence = -1
	_input_elapsed = 0.0
	_visual_signature = ""
	game.ship.visible = false
	if is_instance_valid(game.systems): game.systems.suspend_for_online(true)
	game.combat_runtime.set_remote_mode(true)
	game.legacy_hud.set_systems_state({"skills":{},"equipment":{},"services":{"allowed":false,"rows":[],"total":0},"network":{},"message":"Aguardando o estado do servidor; o perfil offline foi preservado."})
	game.model = Flight.new()
	game.model.load_gear_profile(GEAR_ID)
	game.model.position = _offline_model.position
	game.model.orientation = _offline_model.orientation
	for ring: Node3D in game.rings: ring.visible = false
	_starting = true
	var result: int = client.connect_to(url, token, gear_id)
	_starting = false
	if result != OK:
		_finish_offline()
		_publish_status()
		return {"ok": false, "message": "Não foi possível iniciar a conexão com o servidor."}
	_publish_status()
	return {"ok": true}


func disconnect_online() -> void:
	if not active:
		client.disconnect_from_server()
		_publish_status()
		return
	_closing = true
	client.disconnect_from_server()
	_finish_offline()
	_closing = false
	_publish_status()


func shutdown() -> void:
	_closing = true
	if is_instance_valid(client): client.disconnect_from_server()
	# Main skips autosave while active. Do not import into nodes leaving the tree.


func _finish_offline() -> void:
	if not active or _restoring: return
	_restoring = true
	_clear_peer_visuals()
	game.combat_runtime.set_remote_mode(false)
	game.model = _offline_model
	# active stays true until restoration is complete, keeping all local guards shut.
	game._loading_progress = true
	var restored: Dictionary = game._restore_local_progress(_checkpoint)
	active = false
	game.is_paused = _offline_paused
	game._loading_progress = _offline_loading
	game._primary_held = false
	game._secondary_held = false
	game._target_next = false
	game._autosave_time = 0.0
	game.ship.visible = true
	if is_instance_valid(game.systems): game.systems.suspend_for_online(false)
	game._library_revision = -1
	for ring: Node3D in game.rings: ring.visible = game.current_map_id == MAP_ID
	if not bool(restored.get("ok", false)):
		game._loading_progress = true # Fail closed: never save a partially restored session.
		game.legacy_hud.append_system_note("Não foi possível restaurar o perfil offline; o salvamento permanece bloqueado.")
	_state.clear()
	_combat.clear()
	_inventory.clear()
	_skills.clear()
	_self.clear()
	_checkpoint.clear()
	_offline_model = null
	_restoring = false
	game._update_hud()


func handle_action(action: String) -> bool:
	if action.begins_with("online:"):
		var payload: Variant = JSON.parse_string(action.trim_prefix("online:"))
		if not payload is Dictionary: return true
		match str(payload.get("action", "")):
			"connect":
				var result := connect_online(str(payload.get("url", "")), str(payload.get("token", "")), str(payload.get("gear_id", "")))
				if not bool(result.ok): game.legacy_hud.append_system_note(str(result.message))
			"disconnect": disconnect_online()
			"chat":
				if active: client.send_chat(str(payload.get("text", "")))
		return true
	if not active: return false
	if action.begins_with("skill_use:"):
		var value := action.trim_prefix("skill_use:")
		if value.is_valid_int(): cast_skill(int(value))
		return true
	if action.begins_with("skill_assign:"):
		var parts := action.split(":")
		if parts.size() == 3 and parts[1].is_valid_int() and parts[2].is_valid_int():
			assign_skill(int(parts[1]), int(parts[2]))
		return true
	if action.begins_with("equip_item:"):
		var parts := action.split(":")
		if parts.size() == 3 and parts[2].is_valid_int(): equip_item(parts[1], int(parts[2]))
		return true
	if action.begins_with("allocate_stat:"):
		var parts := action.split(":")
		if parts.size() == 3 and parts[2].is_valid_int(): allocate_stat(parts[1], int(parts[2]))
		return true
	# Pure inspection, library navigation and audio remain local presentation.
	if action == "toggle_audio" or action == "refresh_library" or action.begins_with("mission_details:"):
		return false
	game.legacy_hud.append_system_note("A arena online é controlada pelo servidor. O perfil offline foi preservado.")
	return true


func cast_skill(slot: int) -> bool:
	if not active or _state.is_empty() or slot < 1 or slot > 8 or game.legacy_hud.blocks_weapons(): return false
	_command_serial += 1
	return client.command("view:%s:%d" % [_command_prefix, _command_serial], "skill_use", {"slot": slot})


func assign_skill(slot: int, item_num: int) -> bool:
	if not active or _state.is_empty() or slot < 1 or slot > 8 or item_num < 0: return false
	return _send_command("skill_assign", {"slot": slot, "item_num": item_num})


func toggle_landing() -> bool:
	return _send_command("toggle_landing")


func toggle_siege() -> bool:
	return _send_command("toggle_siege")


func equip_item(slot: String, item_num: int) -> bool:
	if not bool(_inventory.get("equip_available", false)) or not NativeInventory.SLOT_POSITIONS.has(slot) or item_num <= 0: return false
	for entry: Dictionary in _inventory.get("entries", []):
		if int(entry.item_num) == item_num and slot in entry.get("equippable_slots", []):
			return _send_command("equip", {"slot": slot, "item_num": item_num})
	return false


func allocate_stat(stat: String, count: int) -> bool:
	if not bool(_inventory.get("allocate_stats_available", false)) or stat not in STATS or count < 1 or count > 1000 or count > int(_inventory.get("bonus_stats", 0)): return false
	return _send_command("allocate_stat", {"stat": stat, "count": count})


func _send_command(action: String, args: Dictionary = {}) -> bool:
	if not active or _state.is_empty() or not client.is_connected_to_server(): return false
	_command_serial += 1
	return client.command("view:%s:%d" % [_command_prefix, _command_serial], action, args)


func physics_tick(delta: float) -> void:
	if not active or _state.is_empty() or not client.is_connected_to_server(): return
	_input_elapsed = minf(_input_elapsed + maxf(0.0, delta), INPUT_STEP * 3.0)
	while _input_elapsed + 0.000001 >= INPUT_STEP:
		_input_elapsed -= INPUT_STEP
		var masked: bool = game.legacy_hud.blocks_weapons() or game.legacy_hud.wants_keyboard()
		var aim: Vector3 = game.model.forward()
		if is_instance_valid(game.camera): aim = game.camera.project_ray_normal(game._aim_position()).normalized()
		if not aim.is_finite() or aim.length_squared() < 0.9: aim = Vector3.FORWARD
		var controls := input_controls(masked, aim, game._primary_held, game._secondary_held, game._target_next)
		if _input_sequence >= Client.MAX_SEQUENCE:
			disconnect_online()
			return
		var next := _input_sequence + 1
		if client.send_input(next, controls):
			_input_sequence = next
			game._target_next = false


static func input_controls(masked: bool, aim: Vector3, primary: bool, secondary: bool, next_target: bool) -> Dictionary:
	var direction := aim.normalized() if aim.is_finite() and aim.length_squared() > 0.001 else Vector3.FORWARD
	return {"pitch": 0.0 if masked else Input.get_axis("pitch_down", "pitch_up"), "ground_throttle": 0.0 if masked else Input.get_axis("pitch_down", "pitch_up"), "roll": 0.0 if masked else Input.get_axis("roll_right", "roll_left"), "yaw": 0.0 if masked else Input.get_axis("yaw_right", "yaw_left"), "boost": not masked and Input.is_action_pressed("boost"), "brake": not masked and Input.is_action_pressed("brake"), "primary": not masked and primary, "secondary": not masked and secondary, "target_next": not masked and next_target, "aim_direction": [direction.x,direction.y,direction.z]}


func frame(delta: float) -> void:
	if not active: return
	game.combat_runtime.advance_remote_visuals(delta)
	for key: Variant in _peers:
		var node: Node3D = _peers[key]
		var target: Vector3 = node.get_meta("position", node.position)
		var orientation: Quaternion = node.get_meta("orientation", node.quaternion)
		node.position = node.position.lerp(target, clampf(delta * 15.0, 0, 1))
		node.quaternion = node.quaternion.slerp(orientation, clampf(delta * 15.0, 0, 1))


func _receive_snapshot(raw: Dictionary) -> void:
	if not active or _restoring: return
	var public: Dictionary = client.snapshot()
	var pilot_id := str(public.get("pilot_id", ""))
	var parsed := decode_snapshot(raw, pilot_id, game.combat_runtime.inventory.catalog, game.combat_runtime.inventory._icons)
	if not bool(parsed.get("ok", false)):
		client.disconnect_from_server("O servidor enviou um estado de arena incompatível.")
		return
	var data: Dictionary = parsed.data
	if not _state.is_empty() and int(data.tick) <= int(_state.tick): return
	_state = data
	_self = data.player
	_inventory = data.inventory
	_skills = data.skills
	_input_sequence = maxi(_input_sequence, int(data.input_seq))
	if game.current_map_id != MAP_ID:
		var loaded: Dictionary = game.world_runtime.load_map(MAP_ID)
		if not bool(loaded.get("ok", false)):
			client.disconnect_from_server("Os recursos originais do mapa da arena não estão disponíveis.")
			return
	var gear_id := str(_self.gear_id)
	game.original_scene_profile.active_gear_id = gear_id
	var signature := gear_id + ":" + str(_inventory.get("equipped", {}).get("armor", 0))
	if signature != _visual_signature:
		_visual_signature = signature
		if game._create_ship(false): game.legacy_hud.set_gear_preview(game.ship)
	game.model.position = _self.position
	game.model.orientation = _self.orientation
	game.model.gear_id = gear_id
	var flight: Dictionary = _self.flight
	for field: String in ["speed", "travel_speed", "boost_energy", "fuel_fraction", "weight_ratio", "bank_angle", "ground_speed"]:
		if flight.has(field): game.model.set(field, flight[field])
	for field: String in ["boosting", "overheated", "airborne", "boundary_hit", "landing", "taking_off", "hyper_booster"]:
		if flight.has(field): game.model.set(field, flight[field])
	game.model.siege = str(flight.get("mode", "")) == "siege"
	if flight.get("fuel") is Dictionary: game.model.fuel_capacity = float(flight.fuel.get("max",game.model.fuel_capacity))
	game.ship.position = _self.position
	game.ship.quaternion = _self.orientation
	game.ship.visible = not bool(_self.dead)
	game.flight_time = float(data.elapsed)
	_combat = _combat_snapshot(data)
	game.combat_runtime.apply_remote_presentation(data.targets, data.projectiles, _combat)
	_update_peer_visuals(data.pilots, pilot_id)
	_publish_status()
	_publish_systems()
	game._update_hud()


func ship_profile() -> Dictionary:
	var identifier := int(_inventory.get("equipped", {}).get("armor", 0))
	var item: Dictionary = game.combat_runtime.inventory.catalog.get(identifier, {})
	return game._appearance_profile(int(item.get("SourceIndex", 0)), str(_self.get("gear_id", GEAR_ID))) if not item.is_empty() else {}


func _combat_snapshot(data: Dictionary) -> Dictionary:
	var result: Dictionary = data.player.duplicate(true)
	result.erase("orientation")
	result.erase("flight")
	result["available"] = true
	result["inventory"] = data.inventory
	result["experience"] = int(data.inventory.get("experience", 0))
	result["gear_id"] = str(data.player.gear_id)
	result["map_index"] = MAP_ID
	result["locked"] = float(result.get("lock_progress", 0)) >= 1.0
	result["targets"] = data.targets
	result["projectiles"] = data.projectiles
	result["weapons"] = {}
	for slot: String in ["primary", "secondary"]:
		var identifier := int(data.inventory.get("equipped", {}).get(slot, 0))
		var native: Dictionary = game.combat_runtime.inventory.catalog.get(identifier, {})
		result.weapons[slot] = {"item_num": identifier, "name": native.get("ItemName", "Arma original")}
	result["target"] = {}
	for target: Dictionary in data.targets:
		if int(target.id) == int(data.player.get("target_id", -1)):
			result.target = target.duplicate(true)
			result.target["distance"] = data.player.position.distance_to(target.position)
			result.target["name"] = str(game.combat_runtime._native_monsters.get(int(target.monster_code), {}).get("MonsterName", target.monster_code))
			break
	return result


func hud_world() -> Dictionary:
	return {"map_id": MAP_ID if not _state.is_empty() else game.current_map_id, "map_index": MAP_ID, "map_title": "Arena PvE · Stone's Ruin" if not _state.is_empty() else "Aguardando o servidor", "missions": [], "active_missions": [], "wallet": {"credits": int(_inventory.get("credits", 0)), "experience": int(_inventory.get("experience", 0))}, "revision": int(_state.get("tick", 0))}


func hud_flight() -> Dictionary:
	return _self.get("flight", {})


func _publish_systems() -> void:
	if _state.is_empty(): return
	var skills := _skills.duplicate(true)
	skills["learn_allowed"] = false
	skills["learn_reason"] = "Esta arena não possui uma escola de habilidades confirmada; atalhos aprendidos seguem o servidor."
	game.legacy_hud.set_systems_state({"authoritative_online": true, "skills": skills, "equipment": _inventory, "services": {"allowed": false, "rows": [], "total": 0, "reason": "Serviços do perfil offline não estão disponíveis na arena."}, "network": {}, "message": "Combate e progresso sob autoridade do servidor."})


func _publish_status() -> void:
	if not is_instance_valid(game) or not is_instance_valid(game.legacy_hud): return
	var value: Dictionary = client.snapshot()
	game.legacy_hud.set_online_state({"status": value.get("status", "offline"), "message": value.get("message", ""), "connected": active and value.get("connected", false), "server_url": value.get("url", ""), "pilot_id": value.get("pilot_id", ""), "gear_id": _self.get("gear_id", ""), "player_count": _state.get("pilots", []).size(), "revision": _state.get("tick", 0), "shared_combat": true})


func _status_changed(status: String) -> void:
	_last_status = status
	if active and not _closing and not _starting and not _restoring and status in ["offline", "error"]:
		_finish_offline()
	_publish_status()


func _receive_event(event: Dictionary) -> void:
	if not active: return
	var type := str(event.get("type", ""))
	if type == "chat":
		game.legacy_hud.append_online_chat(str(event.get("pilot_id", "Piloto")), str(event.get("text", "")))
	elif type == "pilot_reward" and str(event.get("pilot_id", "")) == str(client.snapshot().get("pilot_id", "")):
		game.legacy_hud.append_system_note("Recompensa da arena: %d SPI, registrada pelo servidor." % int(event.get("credits", 0)))
	elif type in ["fired", "enemy_fired", "hit", "target_destroyed", "player_died", "player_respawned"]:
		if type in ["fired","enemy_fired"] and _vector_ok(event.get("position"),3) and _vector_ok(event.get("endpoint"),3): game.combat_runtime.present_remote_event(event)
		if is_instance_valid(game.original_audio):
			if type=="fired" and _integer(event.get("item_num")): game.original_audio.play_weapon(int(event.item_num),str(_self.get("gear_id", GEAR_ID)))
			elif type=="target_destroyed" and _integer(event.get("monster_code")): game.original_audio.play_binding("monster_effects",int(event.monster_code),"destroyed")


func _command_result(result: Dictionary) -> void:
	if active:
		game.legacy_hud.append_system_note("Comando confirmado pelo servidor." if bool(result.get("ok", false)) else "O servidor recusou este comando no estado atual.")


func _update_peer_visuals(players: Array, own_id: String) -> void:
	var live: Dictionary = {}
	for player: Dictionary in players:
		var identifier := str(player.pilot_id)
		if identifier == own_id or not bool(player.connected): continue
		live[identifier] = true
		if _peers.has(identifier) and str((_peers[identifier] as Node).get_meta("gear_id", "")) != str(player.gear_id):
			(_peers[identifier] as Node).queue_free()
			_peers.erase(identifier)
		if not _peers.has(identifier):
			var profile: Dictionary = {}
			for candidate: Dictionary in game.original_scene_profile.get("gear_profiles", []):
				if str(candidate.get("source_id", "")) == str(player.gear_id): profile = candidate
			var result: Dictionary = Assets.instantiate(profile)
			if result.node == null: continue
			var node: Node3D = result.node
			game.add_child(node)
			node.position = player.position
			node.set_meta("gear_id", str(player.gear_id))
			_peers[identifier] = node
		var visual: Node3D = _peers[identifier]
		visual.visible = not bool(player.dead)
		visual.set_meta("position", player.position)
		visual.set_meta("orientation", player.orientation)
	for identifier: Variant in _peers.keys():
		if not live.has(identifier):
			(_peers[identifier] as Node).queue_free()
			_peers.erase(identifier)


func _clear_peer_visuals() -> void:
	for node: Node in _peers.values(): node.queue_free()
	_peers.clear()


static func decode_snapshot(raw: Dictionary, own_id: String, catalog: Dictionary = {}, icons: Dictionary = {}) -> Dictionary:
	if int(raw.get("schema_version", 0)) != 1 or raw.get("map_index") != MAP_ID or not _integer(raw.get("tick")) or int(raw.tick) < 0 or not _number(raw.get("elapsed")) or float(raw.elapsed)<0:
		return {"ok": false, "error":"invalid_snapshot_367"}
	if not raw.get("pilots") is Array or raw.pilots.is_empty() or raw.pilots.size() > 8 or not raw.get("targets") is Array or raw.targets.size() > 128 or not raw.get("projectiles") is Array or raw.projectiles.size() > 24 or not raw.get("self") is Dictionary:
		return {"ok": false, "error":"invalid_snapshot_369"}
	var private_state: Dictionary = raw.self
	if str(private_state.get("pilot_id", "")) != own_id or own_id.is_empty() or not _integer(private_state.get("input_seq")) or int(private_state.input_seq) < -1 or int(private_state.input_seq) >= Client.MAX_SEQUENCE or not private_state.get("inventory") is Dictionary or not private_state.get("skills") is Dictionary:
		return {"ok": false, "error":"invalid_snapshot_372"}
	var players: Array = []
	var self_player: Dictionary = {}
	var identities: Dictionary = {}
	for value: Variant in raw.pilots:
		if not value is Dictionary or str(value.get("gear_id", "")) not in GEAR_IDS or not _vector_ok(value.get("position"), 3) or not _vector_ok(value.get("orientation"), 4) or not value.get("flight") is Dictionary or not value.get("connected") is bool or not value.get("dead") is bool:
			return {"ok": false, "error":"invalid_snapshot_378"}
		var id := str(value.get("pilot_id", ""))
		if id.is_empty() or id.length() > 128 or identities.has(id): return {"ok": false, "error":"invalid_snapshot_380"}
		identities[id] = true
		var q: Array = value.orientation
		var rotation := Quaternion(float(q[0]),float(q[1]),float(q[2]),float(q[3]))
		if rotation.length_squared() < 0.98 or rotation.length_squared() > 1.02: return {"ok": false, "error":"invalid_snapshot_384"}
		var player := {"pilot_id": id, "gear_id": str(value.gear_id), "position": vector(value.position), "orientation": rotation.normalized(), "connected": value.connected, "dead": value.dead, "flight": {}}
		for key: String in ["hp", "max_hp", "shield", "max_shield", "sp", "max_sp", "primary_ammo", "secondary_ammo", "respawn_remaining", "lock_progress"]:
			if not _number(value.get(key)) or float(value[key]) < 0 or float(value[key]) > 1000000000: return {"ok": false, "error":"invalid_snapshot_387"}
			player[key] = value[key]
		if float(player.hp) > float(player.max_hp) or float(player.shield) > float(player.max_shield) or float(player.sp) > float(player.max_sp) or float(player.lock_progress) > 1.0 or not _integer(value.get("target_id")):
			return {"ok": false, "error":"invalid_snapshot_390"}
		player["target_id"] = int(value.target_id)
		for key: String in ["speed", "travel_speed", "boost_energy", "fuel_fraction", "weight_ratio", "bank_angle", "min_speed", "cruise_speed", "booster_speed", "ground_speed", "takeoff_remaining"]:
			if value.flight.has(key):
				if not _number(value.flight[key]) or absf(float(value.flight[key])) > MAX_COORD: return {"ok": false, "error":"invalid_snapshot_394"}
				player.flight[key] = value.flight[key]
		if value.flight.has("engine_item_num"):
			if not _integer(value.flight.engine_item_num) or int(value.flight.engine_item_num)<0 or int(value.flight.engine_item_num)>2147483647: return {"ok":false}
			if not catalog.is_empty() and not catalog.has(int(value.flight.engine_item_num)): return {"ok":false}
			player.flight["engine_item_num"] = int(value.flight.engine_item_num)
		for key: String in ["boosting", "overheated", "airborne", "boundary_hit", "landing", "taking_off", "hyper_booster", "siege"]:
			if value.flight.has(key):
				if not value.flight[key] is bool: return {"ok": false, "error":"invalid_snapshot_398"}
				player.flight[key] = value.flight[key]
		if id == own_id:
			var fuel: Variant = value.flight.get("fuel")
			if not fuel is Dictionary or not _number(fuel.get("current")) or not _number(fuel.get("max")) or float(fuel.max)<=0 or float(fuel.current)<0 or float(fuel.current)>float(fuel.max): return {"ok":false}
			var clean_fuel := {"current":fuel.current,"max":fuel.max}
			for key: String in ["configured","exempt","falling","stranded"]:
				if not fuel.get(key) is bool: return {"ok":false}
				clean_fuel[key] = fuel[key]
			var mode: Variant = value.flight.get("mode")
			if not mode is String or mode not in ["airborne", "fuel_falling", "fuel_stranded", "landing", "taking_off", "ground", "landed", "siege"]: return {"ok":false}
			if mode in ["ground", "siege"] and player.gear_id != "12002100": return {"ok": false}
			player.flight["fuel"] = clean_fuel
			player.flight["mode"] = mode
		player.flight["gear_id"] = player.gear_id
		if not player.flight.has("mode"): player.flight["mode"] = "airborne"
		if id == own_id: self_player = player
		players.append(player)
	if self_player.is_empty() or not bool(self_player.connected): return {"ok": false, "error":"invalid_snapshot_408"}
	var inventory := clean_inventory(private_state.inventory, catalog, icons)
	if inventory.is_empty() or str(inventory.gear_id) != str(self_player.gear_id): return {"ok": false, "error":"invalid_snapshot_410"}
	var skills: Dictionary = private_state.skills
	if not _number(skills.get("sp")) or not _number(skills.get("max_sp")) or float(skills.sp) < 0 or float(skills.max_sp) <= 0 or float(skills.sp) > float(skills.max_sp) or not skills.get("hotbar") is Array or skills.hotbar.size() != 8:
		return {"ok": false, "error":"invalid_snapshot_413"}
	var clean_skills := {"sp": skills.sp, "max_sp": skills.max_sp, "hotbar": []}
	if not skills.get("assignment_available", false) is bool or not skills.get("learning_available", false) is bool:
		return {"ok": false}
	clean_skills["assignment_available"] = skills.get("assignment_available", false)
	clean_skills["rows"] = []
	var learned_rows: Variant = skills.get("learned_rows", [])
	if not learned_rows is Array or learned_rows.size() > 557: return {"ok": false}
	var learned_ids: Dictionary = {}
	for value: Variant in learned_rows:
		if not value is Dictionary or not _integer(value.get("id")) or int(value.id) <= 0 or learned_ids.has(int(value.id)) or not value.get("learned") is bool or not value.learned or not value.get("learnable") is bool or value.learnable or not value.get("supported") is bool:
			return {"ok": false}
		var native: Dictionary = catalog.get(int(value.id), {})
		if not catalog.is_empty() and native.is_empty(): return {"ok": false}
		var row := {"id": int(value.id), "item_num": int(value.id), "iconitem": int(value.id), "name": str(native.get("ItemName", "Habilidade aprendida")), "description": str(native.get("Description", "")), "learned": true, "learnable": false, "supported": value.supported}
		for key: String in ["cost", "min_level", "level", "sp_cost"]:
			if not _number(value.get(key, 0)) or float(value.get(key, 0)) < 0 or float(value.get(key, 0)) > 1000000000: return {"ok": false}
			row[key] = value.get(key, 0)
		learned_ids[int(value.id)] = true
		clean_skills.rows.append(row)
	for index in range(8):
		var slot: Variant = skills.hotbar[index]
		if not slot is Dictionary or not _integer(slot.get("id")) or int(slot.id) < 0 or not _number(slot.get("sp_cost", 0)) or not _number(slot.get("cooldown", 0)) or not _number(slot.get("remaining", 0)) or not slot.get("usable") is bool:
			return {"ok": false, "error":"invalid_snapshot_418"}
		for key: String in ["sp_cost", "cooldown", "remaining"]:
			if float(slot.get(key, 0)) < 0 or float(slot.get(key, 0)) > 90000: return {"ok": false}
		if clean_skills.assignment_available and int(slot.id) > 0 and not learned_ids.has(int(slot.id)): return {"ok": false}
		var item: Dictionary = catalog.get(int(slot.id), {})
		if int(slot.id) > 0 and not catalog.is_empty() and item.is_empty(): return {"ok": false, "error":"invalid_snapshot_420"}
		clean_skills.hotbar.append({"slot": index+1, "id": int(slot.id), "iconitem": int(slot.id), "name": str(item.get("ItemName", "Habilidade" if int(slot.id)>0 else "Vazio")), "sp_cost": float(slot.get("sp_cost",0)), "cooldown": float(slot.get("cooldown",0)), "remaining": float(slot.get("remaining",0)), "usable": bool(slot.usable), "reason": "" if bool(slot.usable) else "O servidor não permite usar este atalho no estado atual."})
	var targets: Array = []
	identities.clear()
	for value: Variant in raw.targets:
		if not value is Dictionary or not _integer(value.get("id")) or identities.has(int(value.id)) or not _integer(value.get("monster_code")) or not _vector_ok(value.get("position"),3) or not _vector_ok(value.get("velocity"),3) or not value.get("dead") is bool: return {"ok": false, "error":"invalid_snapshot_425"}
		identities[int(value.id)] = true
		var row := {"id": int(value.id), "monster_code": int(value.monster_code), "position": vector(value.position), "velocity": vector(value.velocity), "dead": value.dead}
		for key: String in ["hp","max_hp","shield","max_shield","respawn_remaining"]:
			if not _number(value.get(key)) or float(value[key]) < 0: return {"ok": false, "error":"invalid_snapshot_429"}
			row[key] = value[key]
		if float(row.hp)>float(row.max_hp) or float(row.shield)>float(row.max_shield): return {"ok": false, "error":"invalid_snapshot_431"}
		targets.append(row)
	var rounds: Array = []
	identities.clear()
	for value: Variant in raw.projectiles:
		if not value is Dictionary or not _integer(value.get("id")) or identities.has(int(value.id)) or not _vector_ok(value.get("position"),3) or not _vector_ok(value.get("direction"),3): return {"ok": false, "error":"invalid_snapshot_436"}
		identities[int(value.id)] = true
		var direction := vector(value.direction)
		if direction.length_squared()<0.98 or direction.length_squared()>1.02: return {"ok": false, "error":"invalid_snapshot_439"}
		rounds.append({"id": int(value.id), "position": vector(value.position), "direction": direction.normalized()})
	return {"ok":true,"data":{"tick":int(raw.tick),"elapsed":float(raw.elapsed),"player":self_player,"pilots":players,"targets":targets,"projectiles":rounds,"inventory":inventory,"skills":clean_skills,"input_seq":int(private_state.input_seq)}}


static func clean_inventory(value: Dictionary, catalog: Dictionary, icons: Dictionary) -> Dictionary:
	if str(value.get("gear_id","")) not in GEAR_IDS or not value.get("entries") is Array or value.entries.size()>256 or not value.get("equipped") is Dictionary:
		return {}
	var result := {"gear_id":str(value.gear_id),"entries":[],"equipped":{},"allocated_stats":{},"total_stats":{},"catalog_count":catalog.size()}
	for key: String in ["equip_available", "allocate_stats_available"]:
		if not value.get(key, false) is bool: return {}
		result[key] = value.get(key, false)
	for key: String in ["credits","experience","level","bonus_stats","stat_cap"]:
		if not _integer(value.get(key,0)) or int(value.get(key,0))<0 or int(value.get(key,0))>2147483647: return {}
		result[key] = int(value.get(key,0))
	if int(result.stat_cap) > 1000000 or int(result.bonus_stats) > 1000000: return {}
	if bool(result.allocate_stats_available) and int(result.stat_cap) <= 0: return {}
	var owned: Dictionary = {}
	for entry: Variant in value.entries:
		if not entry is Dictionary or not _integer(entry.get("item_num")) or not _integer(entry.get("count")) or int(entry.count)<=0 or int(entry.count)>2147483647 or owned.has(int(entry.item_num)): return {}
		var id := int(entry.item_num)
		var native: Dictionary = catalog.get(id,{})
		if not catalog.is_empty() and native.is_empty(): return {}
		var slots: Variant = entry.get("equippable_slots", [])
		if not slots is Array or slots.size() > NativeInventory.SLOT_POSITIONS.size(): return {}
		var clean_slots: Array[String] = []
		for slot: Variant in slots:
			if not slot is String or not NativeInventory.SLOT_POSITIONS.has(slot) or slot in clean_slots: return {}
			if not native.is_empty():
				if int(native.get("Position", -1)) != int(NativeInventory.SLOT_POSITIONS[slot]): return {}
				if NativeInventory.SLOT_KINDS.has(slot) and int(native.get("Kind", -1)) not in NativeInventory.SLOT_KINDS[slot]: return {}
			clean_slots.append(slot)
		owned[id] = true
		result.entries.append({"item_num":id,"count":int(entry.count),"name":str(native.get("ItemName",id)),"kind":native.get("Kind",0),"icon_path":str(icons.get(id,"")),"equippable_slots":clean_slots,"source":"Perfil online do servidor"})
	for key: Variant in value.equipped:
		if not key is String or key not in ["primary","secondary","engine","armor","cpu","radar","accessory"] or not _integer(value.equipped[key]) or not owned.has(int(value.equipped[key])): return {}
		result.equipped[key] = int(value.equipped[key])
	for key: String in ["allocated_stats","total_stats"]:
		if not value.get(key,{}) is Dictionary: return {}
		for stat: String in STATS:
			var number: Variant = value.get(key,{}).get(stat,0)
			if not _number(number) or float(number)<0 or float(number)>1000000: return {}
			if key == "allocated_stats" and not _integer(number): return {}
			result[key][stat] = number
	return result


static func vector(value: Array) -> Vector3:
	return Vector3(float(value[0]),float(value[1]),float(value[2]))


static func _number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))


static func _integer(value: Variant) -> bool:
	return _number(value) and float(value)==floor(float(value))


static func _vector_ok(value: Variant, count: int) -> bool:
	if not value is Array or value.size()!=count: return false
	for field: Variant in value:
		if not _number(field) or absf(float(field))>MAX_COORD: return false
	return true


func snapshot() -> Dictionary:
	return {"active":active,"ready":not _state.is_empty(),"status":str(client.snapshot().get("status","offline")) if is_instance_valid(client) else "offline","tick":int(_state.get("tick",0)),"input_seq":_input_sequence,"pilot_id":str(client.snapshot().get("pilot_id","")) if is_instance_valid(client) else "","player_count":(_state.get("pilots",[]) as Array).size(),"map_index":MAP_ID,"gear_id":str(_self.get("gear_id", GEAR_ID)),"restoring":_restoring}
