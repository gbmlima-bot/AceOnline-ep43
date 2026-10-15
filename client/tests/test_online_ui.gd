extends SceneTree
## Public-state and action contracts; fixture bypasses imported artwork only.
const HUD = preload("res://scripts/legacy_hud.gd")
const Arena = preload("res://scripts/online/arena_model.gd")
const ArenaWorld = preload("res://scripts/online/headless_world.gd")
const OnlineView = preload("res://scripts/online/online_view.gd")
const NativeInventory = preload("res://scripts/inventory_model.gd")

class UntexturedHUD extends HUD:
	func _texture(_key: String) -> Texture2D:
		return null
	func _item_texture(_item: Dictionary) -> Texture2D:
		return null
	func _ready() -> void:
		root = Control.new()
		root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		add_child(root)
		_create_gauges()
		_create_radar()
		_create_quick_slots()
		_create_chat()
		_create_inventory()
		_create_annotations()
		_create_simulation_ui()
		_layout()

var _hud: CanvasLayer
var _checks := 0
var _failures: Array[String] = []
var _actions: Array[String] = []
var _cleared_at_submit := false

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	root.size = Vector2i(960, 600)
	root.content_scale_size = Vector2i(960, 600)
	_hud = UntexturedHUD.new()
	root.add_child(_hud)
	await process_frame
	_hud.local_action_requested.connect(func(action: String) -> void:
		if action.begins_with("online:"):
			var data: Dictionary = JSON.parse_string(action.trim_prefix("online:"))
			if data.get("action", "") == "connect": _cleared_at_submit = _hud._online_token.text.is_empty()
		_actions.append(action)
	)
	_hud.toggle_world_panel()
	_hud._select_library_tab("online")
	await process_frame
	_check(_hud._library_tabs.has("online"), "online PvE is a visible library mode")
	_check(_hud._online_token.secret and _hud._online_token.text.is_empty(), "pilot credential is masked and starts empty")
	_check(_hud._online_gear.item_count == 4 and _hud._online_gear.selected == 3, "all four original GEAR classes are offered with I-GEAR as the initial choice")
	_hud._online_gear.select(2)
	_hud._online_gear.item_selected.emit(2)
	_check(_hud._online_connect.disabled and _hud._online_disconnect.disabled, "incomplete offline connection cannot submit")
	_check(_hud._world_maps.text.contains("servidor dedicado") and _hud._world_maps.text.contains("progresso separado"), "online mode states its server and progression scope")
	_check(_hud._world_summary.custom_minimum_size.y >= 32, "map summary has readable height instead of a clipped one-pixel line")
	_check(Rect2(Vector2.ZERO, Vector2(root.size)).encloses(_hud._world_panel.get_global_rect()), "online connection panel fits 960x600")
	_hud._online_url.text = "wss://play.example.test/play"
	_hud._online_url.text_changed.emit(_hud._online_url.text)
	_hud._online_token.text = "fixture_credential_not_real"
	_hud._online_token.text_changed.emit(_hud._online_token.text)
	_check(not _hud._online_connect.disabled, "valid server address and credential enable a connection request")
	_hud._online_token.grab_focus()
	_check(_hud.wants_keyboard(), "secret field captures flight and hotkeys while typing")
	_hud._online_connect.pressed.emit()
	var payload: Dictionary = JSON.parse_string(_actions.back().trim_prefix("online:"))
	_check(payload.action == "connect" and payload.url == "wss://play.example.test/play" and payload.token == "fixture_credential_not_real" and payload.gear_id == "12002100", "connection action binds the selected A-GEAR class to explicit URL and credential")
	_check(_cleared_at_submit and _hud._online_token.text.is_empty(), "credential is erased before the synchronous connection callback")
	_check(not JSON.stringify(_hud._online_state).contains("fixture_credential_not_real") and not JSON.stringify(_hud._systems_state).contains("fixture_credential_not_real"), "credential never enters HUD public snapshots")
	_check(_hud._system_notes.is_empty() and _hud._chat_notes.is_empty(), "connection does not echo the credential or a synthetic success into logs")
	_check(_hud._valid_online_url("ws://127.0.0.1:24681/play") and not _hud._valid_online_url("ws://public.example/play"), "unencrypted development transport is restricted to loopback")
	_check(not _hud._valid_online_url("wss://host/play?token=secret") and not _hud._valid_online_url("wss://secret@host/play"), "credentials cannot be remembered in a URL query or user info")
	_hud.set_online_state({"status":"connecting", "message":"Conectando", "connected":false, "server_url":"wss://play.example.test/play"})
	_check(_hud._online_connect.disabled and not _hud._online_disconnect.disabled, "pending connection can be canceled without duplicating the connect")
	_check(_hud._online_gear.disabled, "class choice cannot change during an authentication attempt")
	_check(_hud._help_text.text.contains("ONLINE PvE") and _hud._help_text.text.contains("servidor"),"help switches to authoritative controls as soon as an online session starts")
	var pending_actions := _actions.size()
	_hud._emit_local_action("save_game")
	_hud._emit_local_action("shop_buy:7000040:1")
	_check(_hud.is_online_active() and _actions.size() == pending_actions and _hud._world_panel.find_child("SaveLocalGame",true,false).disabled, "pending authentication already guards offline mutations and persistence")
	_hud._select_library_tab("network")
	_check(_hud._world_missions.find_child("NetworkHost",true,false).disabled and _hud._world_missions.find_child("NetworkJoin",true,false).disabled and _hud._world_missions.find_child("NetworkLeave",true,false).disabled,"pending online authentication disables incompatible LAN controls rather than showing dead buttons")
	_hud.set_library_data([{"map_id":2001,"title":"Cidade","available":true}], [])
	_hud._select_library_tab("maps")
	_check(_hud._world_missions.find_child("TravelMap_2001",true,false).disabled,"pending online authentication disables local travel before a server snapshot arrives")
	_hud._select_library_tab("online")
	_hud.set_online_state({"status":"connected", "message":"Arena pronta", "connected":true, "server_url":"wss://play.example.test/play", "pilot_id":"pilot-7", "player_count":2, "revision":42, "shared_combat":true, "token":"ignored_private_fixture"})
	_check(_hud.is_online_connected() and not _hud._online_state.has("token"), "only whitelisted public server state is retained")
	_check(_hud._online_status_label.text.contains("2 jogadores") and _hud._online_status_label.text.contains("42") and _hud._online_status_label.text.contains("pilot-7"), "status identifies real participants, pilot and server revision")
	_check(_hud._online_connect.disabled and not _hud._online_disconnect.disabled and _hud._online_token.text.is_empty(), "connected form has no editable or retained credential")
	for name: String in ["SaveLocalGame", "LoadLocalGame"]:
		_check(_hud._world_panel.find_child(name,true,false).disabled, "online authority disables " + name)
	var before := _actions.size()
	_hud._world_panel.find_child("SaveLocalGame",true,false).pressed.emit()
	_hud._emit_local_action("travel_map:2001")
	_hud._emit_local_action("shop_buy:7000040:1")
	_hud._emit_local_action("allocate_stat:attack:1")
	_check(_actions.size() == before, "even forced disabled controls cannot emit offline mutations while online")
	_hud.set_systems_state({"skills":{"rows":[],"sp":12,"max_sp":30,"hotbar":[{"id":7830011,"usable":true,"name":"Habilidade do servidor","sp_cost":5}]}})
	_check(_hud._skill_buttons[0].disabled, "a local hotbar cannot cast into an authoritative session")
	_hud.set_systems_state({"authoritative_online":true,"skills":{"rows":[],"sp":12,"max_sp":30,"hotbar":[{"id":7830011,"usable":true,"name":"Habilidade do servidor","sp_cost":5}]}})
	_hud._skill_buttons[0].pressed.emit()
	_check(not _hud._skill_buttons[0].disabled and _actions.back() == "skill_use:1" and _hud._vital_labels[4].text == "12", "server-owned hotbar emits only the skill command and mirrors native SP")
	before = _actions.size()
	_hud._emit_local_action("skill_learn:7830011")
	_hud._emit_local_action("shop_buy:7000040:1")
	_check(_actions.size() == before, "server hotbar permission does not unlock offline learning or economy")
	_hud.set_systems_state({"authoritative_online":true,"skills":{"assignment_available":true,"learn_allowed":false,"rows":[{"id":7830011,"name":"Habilidade aprendida","learned":true,"learnable":false,"supported":true}],"sp":12,"max_sp":30,"hotbar":[]}})
	_hud._select_library_tab("skills")
	_hud._skill_slot.value = 4
	var assign: Button = _hud._world_missions.find_child("AssignSkill_7830011", true, false)
	_check(not assign.disabled and _hud._world_missions.find_child("LearnSkill_7830011", true, false).disabled, "server capability enables learned rank assignment while tuition remains unavailable")
	assign.pressed.emit()
	_check(_actions.back() == "skill_assign:4:7830011", "online learned skill assignment routes exact authoritative slot and rank")
	_hud._systems_toolbar.get_child(2).pressed.emit()
	_check(_actions.back() == "skill_assign:4:0", "online shortcut can be cleared through the server instead of editing the offline profile")
	var equipment := {"equip_available":true,"allocate_stats_available":true,"bonus_stats":2,"stat_cap":300,"total_stats":{"attack":20},"allocated_stats":{"attack":0},"entries":[{"item_num":7000970,"count":1,"name":"Radar possuído","equippable_slots":["radar"]}],"equipped":{}}
	_hud.set_systems_state({"authoritative_online":true,"equipment":equipment,"skills":{}})
	_hud.set_inventory_state(equipment)
	_hud._select_inventory_cell(0)
	_check(not _hud._inventory_equip.disabled,"explicit server equipment capability enables owned-item selection")
	_hud._inventory_equip.pressed.emit()
	_check(_actions.back()=="equip_item:radar:7000970" and _hud._inventory_state.equipped.is_empty(),"owned-item equip requests the server without mutating the local equipment display")
	_hud._select_library_tab("equipment")
	var allocate: Button = _hud._world_missions.find_child("AllocateStat_attack",true,false).get_child(1)
	allocate.pressed.emit()
	_check(not allocate.disabled and _actions.back()=="allocate_stat:attack:1" and equipment.bonus_stats==2,"online allocation requests one validated point without spending or granting points in the HUD")
	_check(_hud._world_missions.get_child(7).get_child(0).disabled,"server equipment capability does not invent an unsupported unequip command")
	equipment.total_stats.attack=300
	_hud.set_systems_state({"authoritative_online":true,"equipment":equipment,"skills":{}})
	_check(_hud._world_missions.find_child("AllocateStat_attack",true,false).get_child(1).disabled,"a server stat limit disables further allocation")
	var no_ownership := equipment.duplicate(true)
	no_ownership.entries=[]
	_hud.set_inventory_state(no_ownership)
	_check(_hud._inventory_selected.is_empty() and _hud._inventory_equip.disabled,"server removal of an owned item clears a stale selected item")
	_hud.set_library_data([{"map_id":2001,"title":"Cidade","available":true}], [])
	_hud._select_library_tab("maps")
	var travel: Button = _hud._world_missions.get_child(0).find_child("TravelMap_2001",true,false)
	_check(travel.disabled and travel.tooltip_text.contains("servidor"), "world browser shows the authority reason for blocked travel")
	_hud.append_online_chat("pilot-8", "[url]mensagem literal[/url]")
	_hud.set_chat_filter(1)
	_check(not _hud._chat_log.bbcode_enabled and _hud._chat_log.text.contains("[url]mensagem literal[/url]"), "server chat never interprets remote markup")
	_hud._chat_input.text_submitted.emit("olá arena")
	payload = JSON.parse_string(_actions.back().trim_prefix("online:"))
	_check(payload.action == "chat" and payload.text == "olá arena", "connected chat sends to the authoritative transport")
	_hud._select_library_tab("online")
	_hud._online_disconnect.pressed.emit()
	payload = JSON.parse_string(_actions.back().trim_prefix("online:"))
	_check(payload.action == "disconnect", "disconnect action is explicit")
	_hud.set_online_state({"status":"offline", "connected":false, "message":"Sessão encerrada"})
	_check(not _hud.is_online_connected() and not _hud._world_panel.find_child("SaveLocalGame",true,false).disabled, "disconnect restores local-profile controls")
	_check(_hud._help_text.text.contains("SESSÃO LOCAL") and _hud._help_text.text.contains("F2"),"disconnect restores the offline class and pause help")
	_check(_hud._online_url.text == "wss://play.example.test/play" and _hud._online_token.text.is_empty(), "only the public server address is remembered after disconnect")
	_check(not _hud._online_gear.disabled and _hud._online_gear.selected == 2, "disconnect restores the selected class control without retaining a credential")
	_hud._chat_input.text_submitted.emit("nota offline")
	_check(_hud._chat_notes.back() == "Local › nota offline", "disconnected chat returns to personal notes")
	_hud._online_token.grab_focus()
	_hud.toggle_world_panel()
	await process_frame
	_check(not _hud.wants_keyboard(), "closing M releases online credential input focus")
	var arena = Arena.new()
	var arena_world = ArenaWorld.new()
	var catalog = NativeInventory.new()
	_check(arena_world.configure() and arena.configure({"map_index":3002,"max_players":2},arena_world) and arena.add_player("fuel-fixture").ok and catalog.configure(), "real arena and native catalog configure the EP presentation fixture")
	var wire: Dictionary = arena.snapshot("fuel-fixture")
	var decoded: Dictionary = OnlineView.decode_snapshot(wire,"fuel-fixture",catalog.catalog,catalog._icons)
	_check(decoded.ok and decoded.data.player.flight.fuel.current == 30.0, "native arena snapshot preserves absolute EP30 rather than a percentage")
	if decoded.ok:
		var view_combat: Dictionary = decoded.data.player.duplicate(true)
		view_combat["available"] = true
		view_combat["inventory"] = decoded.data.inventory
		_hud.update_simulation(decoded.data.player.flight, view_combat, {}, null)
		_check(_hud._vital_labels[6].text == "30", "production HUD renders the decoded native EP30")
		arena.pilots["fuel-fixture"].flight.set_fuel_state(0.0,30.0)
		arena.pilots["fuel-fixture"].flight.fuel_falling = true
		arena.pilots["fuel-fixture"].flight.fuel_stranded = false
		wire = arena.snapshot("fuel-fixture")
		decoded = OnlineView.decode_snapshot(wire,"fuel-fixture",catalog.catalog,catalog._icons)
		_hud.update_simulation(decoded.data.player.flight, view_combat, {}, null)
		_check(decoded.ok and decoded.data.player.flight.fuel.falling and decoded.data.player.flight.mode == "fuel_falling" and _hud._vital_labels[6].text == "0" and _hud._interaction_prompt.text.contains("QUEDA"), "server fuel depletion reaches the absolute EP and falling warning in the real HUD")
		arena.pilots["fuel-fixture"].flight.fuel_falling = false
		arena.pilots["fuel-fixture"].flight.fuel_stranded = true
		arena.pilots["fuel-fixture"].flight.airborne = false
		wire = arena.snapshot("fuel-fixture")
		decoded = OnlineView.decode_snapshot(wire,"fuel-fixture",catalog.catalog,catalog._icons)
		_hud.update_simulation(decoded.data.player.flight, view_combat, {}, null)
		_check(decoded.ok and decoded.data.player.flight.fuel.stranded and _hud._interaction_prompt.text.contains("PARADO"), "server stranded mode remains visible without advancing the local flight model")
		wire.pilots[0].flight.fuel["untrusted_path"] = "res://not-a-native-resource"
		decoded = OnlineView.decode_snapshot(wire,"fuel-fixture",catalog.catalog,catalog._icons)
		_check(decoded.ok and decoded.data.player.flight.fuel.size()==6 and not decoded.data.player.flight.fuel.has("untrusted_path"), "fuel snapshot carries only six validated public resource fields")
		wire.pilots[0].flight.fuel.falling = "yes"
		_check(not OnlineView.decode_snapshot(wire,"fuel-fixture",catalog.catalog,catalog._icons).ok, "untyped remote fuel flags fail closed")
		wire = arena.snapshot("fuel-fixture")
		wire.pilots[0].flight.mode = "unnegotiated-ground-mode"
		_check(not OnlineView.decode_snapshot(wire,"fuel-fixture",catalog.catalog,catalog._icons).ok, "unnegotiated flight modes fail closed")
	_hud.queue_free()
	await process_frame
	for failure: String in _failures: push_error(failure)
	print(JSON.stringify({"suite":"online_ui", "status":"pass" if _failures.is_empty() else "fail", "checks":_checks, "failures":_failures.size()}))
	quit(0 if _failures.is_empty() else 1)

func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition: _failures.append(message)
