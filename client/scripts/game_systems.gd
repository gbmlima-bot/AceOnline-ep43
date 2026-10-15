extends Node
## New local services and LAN orchestration. Original account/server state is absent.

const Skills = preload("res://scripts/skill_model.gd")
const Services = preload("res://scripts/service_model.gd")
const Network = preload("res://scripts/local_multiplayer.gd")
const Assets = preload("res://scripts/original_asset.gd")
const SERVICE_KINDS := {"buy": [0, 1, 2, 3, 4, 13, 35, 36], "sell": [0, 1, 2, 3, 4, 13, 35, 36], "recipes": [10, 11], "maintenance": [9], "skills": [14]}

var game: Node3D
var _online_suspended := false
var skills = Skills.new()
var services = Services.new()
var network: Node
var query := {"mode": "buy", "query": "", "offset": 0, "limit": 8, "available": true}
var _ui_elapsed := 0.0
var _network_elapsed := 0.0
var _ghosts: Dictionary = {}
var _last_message := ""


func setup(scene: Node3D) -> bool:
	game = scene
	if not services.configure(game.combat_runtime.inventory) or not skills.configure(_profile()):
		return false
	# New offline training policy, separate from purchased ranks and ITEM ownership.
	skills.learn_base_skills()
	network = Network.new()
	add_child(network)
	network.chat_received.connect(_receive_chat)
	network.status_changed.connect(_network_status)
	sync_profile()
	refresh_ui()
	return true


func _profile() -> Dictionary:
	var inventory = game.combat_runtime.inventory
	var result: Dictionary = inventory.combat_profile()
	result["gear_id"] = inventory.gear_id
	result["gear_unit_mask"] = int(inventory.GEAR_KINDS.get(inventory.gear_id, 0))
	return result


func sync_profile() -> void:
	if _online_suspended: return
	if game == null or not is_instance_valid(game.combat_runtime): return
	var inventory = game.combat_runtime.inventory
	var profile := _profile()
	game.combat_runtime.model.apply_player_stats(profile)
	skills.set_profile(profile)
	skills.sync_combat(game.combat_runtime.model)
	if game.model.has_method("configure_resources"):
		game.model.configure_resources({"max_ep": profile.get("max_ep", 30.0)})
	if inventory.has_method("weight_profile"):
		game.model.weight_ratio = float(inventory.weight_profile().get("ratio", 0.0))
	if game.world_runtime.has_method("set_inventory_counts"):
		game.world_runtime.set_inventory_counts(inventory.export_state().items)
	if game.world_runtime.has_method("sync_inventory_wallet"):
		game.world_runtime.sync_inventory_wallet(inventory.credits, inventory.experience)
	game.combat_runtime.model.player["credits"] = inventory.credits
	game.combat_runtime.model.player["experience"] = inventory.experience
	if services.inventory != inventory: services.configure(inventory)
	sync_resources()


func advance(delta: float) -> void:
	if _online_suspended: return
	skills.advance(delta, game.combat_runtime.model)
	if game.model.has_method("set_skill_modifiers"):
		game.model.set_skill_modifiers(skills.modifiers())
	if game.model.has_method("configure_fuel_context"):
		var info: Dictionary = game.world_runtime.current_map.get("source_map_info", {})
		game.model.configure_fuel_context(game.current_map_id, int(info.get("MapInfluenceType", info.get("MapInflTy", 0))))
	sync_resources()


func sync_resources() -> void:
	if _online_suspended: return
	game.combat_runtime.model.player["ep"] = game.model.fuel_fraction * game.model.fuel_capacity
	game.combat_runtime.model.player["max_ep"] = game.model.fuel_capacity


func _process(delta: float) -> void:
	if _online_suspended: return
	if game == null or not is_instance_valid(network): return
	_network_elapsed += delta
	if _network_elapsed >= 0.1:
		_network_elapsed = 0.0
		var p: Vector3 = game.model.position
		var rotation: Vector3 = Basis(game.model.orientation).get_euler()
		network.publish_state({"map_index": game.current_map_id, "gear_id": game.model.gear_id, "position": [p.x,p.y,p.z], "rotation": [rotation.x,rotation.y,rotation.z], "speed": game.model.travel_speed, "name": "Piloto", "appearance_id": int(game._appearance_overrides.get(game.model.gear_id, 0))})
	_update_peers(delta)
	_ui_elapsed += delta
	if _ui_elapsed >= 0.2:
		_ui_elapsed = 0.0
		refresh_ui()


func handle_action(action: String) -> bool:
	if _online_suspended: return false
	var parts := action.split(":")
	var result: Dictionary = {}
	match str(parts[0]):
		"systems_query":
			var parsed: Variant = JSON.parse_string(action.trim_prefix("systems_query:"))
			if parsed is Dictionary:
				for key: String in ["mode", "query", "offset", "limit", "available"]:
					if parsed.has(key): query[key] = parsed[key]
				query.offset = clampi(int(query.offset), 0, 100000)
				query.limit = 8
			refresh_ui()
			return true
		"network":
			_network_action(action.trim_prefix("network:"))
			return true
		"skill_use":
			if parts.size() == 2 and parts[1].is_valid_int(): cast_slot(int(parts[1]))
			return true
		"skill_assign":
			if parts.size() == 3 and parts[1].is_valid_int() and parts[2].is_valid_int(): result = skills.assign_slot(int(parts[1]), int(parts[2]))
		"skill_learn":
			if parts.size() == 2 and parts[1].is_valid_int():
				result = _learn_skill(int(parts[1]))
		"allocate_stat":
			if parts.size() == 3 and parts[2].is_valid_int(): result = game.combat_runtime.inventory.allocate_stat(parts[1], int(parts[2]))
		"equip_item":
			if parts.size() == 3 and parts[2].is_valid_int():
				result = game.combat_runtime.equip_item(int(parts[2]), parts[1])
				if bool(result.get("ok", false)) and parts[1] == "engine": game.model.configure(result.get("item", {}))
		"unequip_item":
			if parts.size() == 2:
				if parts[1] in ["primary", "secondary", "engine"]:
					result = {"ok": false, "message": "Mantenha as armas e o motor essenciais equipados."}
				else: result = game.combat_runtime.inventory.unequip_item(parts[1])
		"shop_buy", "shop_sell":
			if parts.size() == 3 and parts[1].is_valid_int() and parts[2].is_valid_int():
				result = _access("buy" if parts[0] == "shop_buy" else "sell")
				if bool(result.ok): result = services.buy(int(parts[1]), int(parts[2])) if parts[0] == "shop_buy" else services.sell(int(parts[1]), int(parts[2]))
		"craft_recipe":
			result = _access("recipes")
			if bool(result.ok): result = services.craft(action.trim_prefix("craft_recipe:"))
		"service_repair", "service_ammo":
			if parts.size() == 2: result = _maintain(parts[1] + "_ammo" if parts[0] == "service_ammo" else parts[1])
		_:
			return false
	if result.is_empty(): result = {"ok": false, "message": "Ação ou seleção inválida."}
	_finish(result)
	return true


func cast_slot(slot: int) -> Dictionary:
	if game.is_paused or game.legacy_hud.wants_keyboard() or game.legacy_hud.inventory_items.visible or game.legacy_hud._help_panel.visible:
		return {"ok": false, "message": "Feche o inventário ou a entrada de texto para usar a habilidade."}
	var result: Dictionary = skills.cast_slot(slot, game.combat_runtime.model)
	if bool(result.get("ok", false)) and game.world_runtime.has_method("receive_local_event"):
		game.world_runtime.receive_local_event(result)
	_finish(result)
	return result


func _learn_skill(identifier: int) -> Dictionary:
	var access := _access("skills")
	if not bool(access.ok): return access
	var result: Dictionary = skills.can_learn(identifier)
	if not bool(result.get("ok", false)): return result
	var debit: Dictionary = game.combat_runtime.inventory.exchange([], [], -int(result.get("cost", 0)))
	if not bool(debit.get("ok", false)): return debit
	return skills.learn(identifier)


func _access(mode: String) -> Dictionary:
	if bool(game.combat_runtime.model.player.get("dead", false)):
		return {"ok": false, "message": "Aguarde o reaparecimento para usar serviços."}
	var kinds: Array = SERVICE_KINDS.get(mode, [])
	if game.world_runtime.has_method("service_contacts"):
		for contact: Dictionary in game.world_runtime.service_contacts():
			var kind := int(contact.get("building_kind", contact.get("BuildingKind", -1)))
			if not kind in kinds: continue
			# City service console replaces the absent on-foot character/controller.
			if game.current_map_id in [2001, 2002, 2006]:
				return {"ok": true, "contact": contact, "policy": "Console local da cidade, vinculado a NPC original; personagem a pé ainda ausente."}
			if bool(contact.get("native_position", false)) and contact.get("position") is Vector3 and game.model.position.distance_to(contact.position) <= float(contact.get("range", 120.0)):
				return {"ok": true, "contact": contact, "policy": "Serviço original ao alcance do GEAR local."}
	return {"ok": false, "message": "Visite uma cidade com o serviço original correspondente (por exemplo, mapa 2001)."}


func _resource(kind: String) -> Dictionary:
	var player: Dictionary = game.combat_runtime.model.player
	if kind == "hp": return {"current": player.hp, "maximum": player.max_hp}
	if kind == "dp": return {"current": player.shield, "maximum": player.max_shield}
	if kind == "sp": return {"current": skills.sp, "maximum": skills.max_sp}
	if kind == "ep":
		var max_ep := float(_profile().get("max_ep", 30.0))
		return {"current": game.model.fuel_fraction * max_ep, "maximum": max_ep}
	if kind in ["primary_ammo", "secondary_ammo"]:
		var slot := kind.trim_suffix("_ammo")
		var inventory = game.combat_runtime.inventory
		var identifier := int(inventory.equipped.get(slot, 0))
		var item: Dictionary = inventory.catalog.get(identifier, {})
		var starter := 1000 if slot == "primary" else 48
		var capacity := int(item.get("Charging", starter))
		return {"current": player.get(kind, 0), "maximum": capacity if capacity > 0 else starter, "weapon_item_num": identifier}
	return {}


func _maintain(kind: String) -> Dictionary:
	var access := _access("maintenance")
	if not bool(access.ok): return access
	var resource := _resource(kind)
	if resource.is_empty(): return {"ok": false, "message": "Recurso desconhecido."}
	var result: Dictionary = services.service(kind, float(resource.current), float(resource.maximum), int(resource.get("weapon_item_num", 0)))
	if not bool(result.get("ok", false)): return result
	var next := minf(float(resource.maximum), float(resource.current) + float(result.get("amount", 0.0)))
	var player: Dictionary = game.combat_runtime.model.player
	match kind:
		"hp": player.hp = next
		"dp": player.shield = next
		"sp": skills.sp = next
		"ep": game.model.set_fuel_state(next, float(resource.maximum))
		"primary_ammo", "secondary_ammo": player[kind] = int(next)
	return result


func _finish(result: Dictionary) -> void:
	_last_message = str(result.get("message", result.get("reason", "Operação concluída." if bool(result.get("ok", false)) else result.get("error", "Operação indisponível."))))
	game.legacy_hud.append_system_note(_last_message)
	game._sync_player_profile()
	if bool(result.get("ok", false)) and result.get("event") is Dictionary and game.world_runtime.has_method("receive_local_event"):
		game.world_runtime.receive_local_event(result.event)
	refresh_ui()


func refresh_ui() -> void:
	if _online_suspended: return
	if game == null or not game.legacy_hud.has_method("set_systems_state"): return
	var modal: bool = game.legacy_hud.is_world_panel_open()
	var data: Dictionary = {"mode": query.mode, "rows": [], "total": 0, "offset": int(query.offset), "quotes": []}
	if modal:
		if query.mode == "recipes": data = services.recipe_catalog(str(query.query), int(query.offset), 8, bool(query.available), true)
		elif query.mode in ["buy", "sell"]: data = services.shop_catalog(str(query.query), int(query.offset), 8, bool(query.available), str(query.mode))
		data["mode"] = query.mode
		var access := _access(str(query.mode))
		data["allowed"] = bool(access.get("ok", false))
		data["reason"] = str(access.get("message", access.get("policy", "")))
		data["contact"] = access.get("contact", {})
		var quotes: Array[Dictionary] = []
		for kind: String in ["hp", "dp", "ep", "sp", "primary_ammo", "secondary_ammo"]:
			var resource := _resource(kind)
			var quote: Dictionary = services.quote_service(kind, float(resource.current), float(resource.maximum), int(resource.get("weapon_item_num", 0)))
			quote["kind"] = kind
			quote["current"] = resource.current
			quote["maximum"] = resource.maximum
			quotes.append(quote)
		data["quotes"] = quotes
	var skill_state: Dictionary = skills.snapshot(modal)
	if modal:
		var learn_access := _access("skills")
		skill_state["learn_allowed"] = bool(learn_access.get("ok", false))
		skill_state["learn_reason"] = str(learn_access.get("message", learn_access.get("policy", "")))
	game.legacy_hud.set_systems_state({"services": data, "skills": skill_state, "equipment": game.combat_runtime.inventory.snapshot(), "network": network.snapshot() if is_instance_valid(network) else {}, "message": _last_message})


func _network_action(encoded: String) -> void:
	var value: Variant = JSON.parse_string(encoded)
	if not value is Dictionary: return
	match str(value.get("action", "")):
		"host": network.host(int(value.get("port", Network.DEFAULT_PORT)))
		"join": network.join(str(value.get("address", "")), int(value.get("port", Network.DEFAULT_PORT)))
		"disconnect": network.leave()
		"chat": network.send_chat(str(value.get("text", "")))
	refresh_ui()


func _receive_chat(identifier: int, text: String) -> void:
	game.legacy_hud.append_local_note("LAN #%d · %s" % [identifier, text])


func _network_status(_status: String) -> void:
	if is_instance_valid(game.legacy_hud):
		game.legacy_hud.append_system_note(str(network.snapshot().get("message", "")))


func _update_peers(delta: float) -> void:
	var state: Dictionary = network.snapshot()
	var visible: Dictionary = {}
	for key: Variant in state.get("peers", {}):
		if int(key) == int(state.get("peer_id", 0)): continue
		var peer: Dictionary = state.peers[key]
		if int(peer.get("map_index", -1)) != game.current_map_id: continue
		visible[key] = true
		var signature := str(peer.get("gear_id", "")) + ":" + str(peer.get("appearance_id", 0))
		if _ghosts.has(key) and str(_ghosts[key].get_meta("signature", "")) != signature:
			(_ghosts[key] as Node).queue_free()
			_ghosts.erase(key)
		if not _ghosts.has(key):
			var profile: Dictionary = game._appearance_profile(int(peer.get("appearance_id", 0)), str(peer.gear_id))
			if profile.is_empty():
				for candidate: Dictionary in game.original_scene_profile.gear_profiles:
					if str(candidate.source_id) == str(peer.gear_id): profile = candidate
			if profile.is_empty(): continue
			var imported: Dictionary = Assets.instantiate(profile)
			if imported.node == null: continue
			var node: Node3D = imported.node
			node.name = "LANPeer" + str(key)
			node.set_meta("signature", signature)
			game.add_child(node)
			_ghosts[key] = node
			var label := Label3D.new()
			label.text = "LAN #%s · %s" % [key, str(peer.get("name", "Piloto"))]
			label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			label.position.y = 10.0
			label.font_size = 24
			node.add_child(label)
		var target := Vector3(float(peer.position[0]), float(peer.position[1]), float(peer.position[2]))
		var rotation := Vector3(float(peer.rotation[0]), float(peer.rotation[1]), float(peer.rotation[2]))
		var ghost: Node3D = _ghosts[key]
		ghost.position = ghost.position.lerp(target, clampf(delta * 12.0, 0.0, 1.0))
		ghost.quaternion = ghost.quaternion.slerp(Basis.from_euler(rotation).get_rotation_quaternion(), clampf(delta * 12.0, 0.0, 1.0))
	for key: Variant in _ghosts.keys():
		if not visible.has(key):
			(_ghosts[key] as Node).queue_free()
			_ghosts.erase(key)


func export_state() -> Dictionary:
	return {"schema_version": 1, "skills": skills.export_state(), "services": services.export_state()}


func import_state(state: Dictionary) -> Dictionary:
	var next_skills = Skills.new()
	var next_services = Services.new()
	if not next_skills.configure(_profile()) or not next_services.configure(game.combat_runtime.inventory):
		return {"ok": false, "error": "systems_not_configured"}
	if state.is_empty():
		next_skills.learn_base_skills()
	else:
		if int(state.get("schema_version", 0)) != 1 or not state.get("skills") is Dictionary or not state.get("services") is Dictionary:
			return {"ok": false, "error": "systems_schema"}
		if not next_skills.import_state(state.skills) or not bool(next_services.import_state(state.services).get("ok", false)):
			return {"ok": false, "error": "systems_saved_state"}
	skills = next_skills
	services = next_services
	sync_profile()
	refresh_ui()
	return {"ok": true}


func _exit_tree() -> void:
	if is_instance_valid(network): network.leave()


func suspend_for_online(suspended: bool) -> void:
	_online_suspended = suspended
	if suspended:
		if is_instance_valid(network): network.leave()
		for node: Node in _ghosts.values(): node.queue_free()
		_ghosts.clear()
	else:
		sync_profile()
		refresh_ui()
