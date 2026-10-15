extends SceneTree
## UI contracts for real model actions; fixtures never grant or debit resources.

const HUD = preload("res://scripts/legacy_hud.gd")
var _hud: CanvasLayer
var _checks := 0
var _failures: Array[String] = []
var _actions: Array[String] = []
var _state: Dictionary = {}


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(960, 600)
	root.content_scale_size = Vector2i(960, 600)
	_hud = HUD.new()
	root.add_child(_hud)
	await process_frame
	_hud.local_action_requested.connect(func(action: String) -> void: _actions.append(action))
	_state = _fixture()
	_hud.set_systems_state(_state)
	_hud.toggle_world_panel()
	await process_frame
	_test_services()
	await _test_native_shop_selector()
	_test_consumables()
	_test_skills()
	_test_equipment()
	await _test_network()
	_hud.set_systems_state({})
	_check(_hud._vital_labels[4].text == "—" and _hud._skill_buttons[0].disabled, "missing skill model falls back to unavailable SP and shortcuts")
	_hud.queue_free()
	await process_frame
	for failure: String in _failures: push_error(failure)
	print(JSON.stringify({"suite": "systems_ui", "status": "pass" if _failures.is_empty() else "fail", "checks": _checks, "failures": _failures.size()}))
	quit(0 if _failures.is_empty() else 1)


func _fixture() -> Dictionary:
	var shop: Array = []
	for index in range(8):
		shop.append({"item_num": 7000040 + index, "name": "Loja %d" % index, "count": 2, "buy_price": 120, "sell_price": 30, "bundle_size": 1, "available": index != 1, "reason": "Nível insuficiente." if index == 1 else ""})
	var skills: Array = []
	for index in range(557):
		skills.append({"id": 1000 + index, "name": "Habilidade %d" % index, "description": "[b]Texto original literal[/b]", "supported": index != 2, "learned": index == 0, "learnable": index == 1, "min_level": 9, "cost": 100, "sp_cost": 25, "cooldown": 10, "reason": "Efeito ainda não suportado." if index == 2 else ""})
	var hotbar: Array = []
	for index in range(8): hotbar.append({"slot": index + 1, "id": 1000 if index == 0 else 0, "name": "Habilidade 0", "sp_cost": 25, "remaining": 0, "usable": index == 0})
	return {"services": {"allowed": true, "mode": "buy", "rows": shop, "total": 16079, "offset": 0}, "skills": {"learn_allowed": true, "rows": skills, "hotbar": hotbar, "sp": 75, "max_sp": 100}, "equipment": {"credits": 1000, "bonus_stats": 3, "stat_cap": 300, "total_stats": {"attack": 20}, "allocated_stats": {"attack": 2}, "equipped": {"armor": 8000130, "cpu": 0, "radar": 0}}, "network": {"status": "offline", "mode": "offline", "connected": false, "port": 24680, "peers": {}, "chat": []}}


func _test_services() -> void:
	_hud._select_library_tab("services")
	_check(_actions.back().begins_with("systems_query:"), "services request a paginated model query on open")
	var query: Dictionary = JSON.parse_string(_actions.back().trim_prefix("systems_query:"))
	_check(query.limit == 8 and query.offset == 0 and query.mode == "buy", "model query has bounded page and explicit transaction mode")
	_check(_hud._world_missions.get_child_count() == 8, "16k shop templates create at most eight rows")
	_check(_hud._library_page_label.text.ends_with("16079"), "server page preserves total catalog count")
	var buy: Button = _hud._world_missions.get_child(0).find_child("ShopAction_7000040", true, false)
	_hud._service_quantity.value = 4
	buy.pressed.emit()
	_check(_actions.back() == "shop_buy:7000040:4", "buy action includes item identity and selected quantity")
	_check(_state.services.rows[0].count == 2, "UI action never grants stock or mutates inventory")
	var blocked: Button = _hud._world_missions.get_child(1).find_child("ShopAction_7000041", true, false)
	_check(blocked.disabled and blocked.tooltip_text == "Nível insuficiente.", "model rejection disables purchase with its Portuguese reason")
	_hud._library_next.pressed.emit()
	query = JSON.parse_string(_actions.back().trim_prefix("systems_query:"))
	_check(query.offset == 8 and query.limit == 8, "next shop page requests only the next eight model rows")
	_hud._library_search.text = "motor"
	_hud._library_search.text_changed.emit("motor")
	query = JSON.parse_string(_actions.back().trim_prefix("systems_query:"))
	_check(query.query == "motor" and query.offset == 0, "search resets the remote model page")
	_hud._library_search.text = ""
	_hud._select_service_mode("sell")
	_hud._world_missions.get_child(0).find_child("ShopAction_7000040", true, false).pressed.emit()
	_check(_actions.back() == "shop_sell:7000040:4", "sell action remains explicit and preserves quantity")
	_state.services = {"allowed": true, "rows": [{"recipe_id": "12:4", "item_num": 9, "name": "Receita", "cost": 500, "probability_10k": 2500, "available": false, "reason": "Faltam ingredientes.", "ingredients": [{"name": "Cristal", "count": 2, "owned": 1}]}], "total": 1, "offset": 0}
	_hud._select_service_mode("recipes")
	_hud.set_systems_state(_state)
	var recipe: Control = _hud._world_missions.get_child(0)
	_check(recipe.find_child("CraftRecipe_12_4", true, false) != null or recipe.get_child(recipe.get_child_count() - 1) is Button, "recipe identity is preserved in bounded rows")
	_check(str(recipe.get_child(1).text).contains("25.00%") and str(recipe.get_child(1).text).contains("1/2"), "recipe shows source success chance and actual ingredient shortage")
	_check((recipe.get_child(recipe.get_child_count() - 1) as Button).disabled, "uncraftable recipe cannot submit from UI")
	_state.services = {"allowed": true, "rows": [], "total": 0, "quotes": [{"resource": "hp", "amount": 40, "cost": 20, "ok": true}, {"resource": "primary_ammo", "amount": 0, "cost": 0, "ok": false, "error": "Munição cheia."}]}
	_hud._select_service_mode("maintenance")
	_hud.set_systems_state(_state)
	_hud._world_missions.get_child(0).get_child(1).pressed.emit()
	_check(_actions.back() == "service_repair:hp", "repair requests source model quote execution")
	_check(_hud._world_missions.get_child(1).get_child(1).disabled, "full ammo quote cannot be submitted")
	_state.services.quotes[0].affordable = false
	_hud.set_systems_state(_state)
	_check(_hud._world_missions.get_child(0).get_child(1).disabled, "valid but unaffordable repair remains blocked")
	_state.services.allowed = false
	_state.services.reason = "Contato adequado não disponível."
	_state.services.quotes[0].affordable = true
	_hud.set_systems_state(_state)
	_check(_hud._world_missions.get_child(0).get_child(1).disabled and _hud._world_missions.get_child(0).get_child(1).tooltip_text.contains("Contato adequado"), "city/contact access gate cannot be bypassed by an affordable quote")


func _test_native_shop_selector() -> void:
	_state.services = {"allowed":true,"shop":9001,"map_id":2001,"rows":[],"total":0,"offset":0,"shop_options":[{"building_index":9001,"map_id":2001,"name":"Armas","native_stock_count":14},{"building_index":9005,"map_id":2001,"name":"Peças","native_stock_count":20},{"building_index":9006,"map_id":2001,"name":"GEAR","native_stock_count":13}]}
	_hud._select_service_mode("buy")
	_hud.set_systems_state(_state)
	_check(_hud._service_shop_toolbar.visible and _hud._service_shop.item_count==4 and int(_hud._service_shop.get_selected_metadata())==9001,"native shops appear separately instead of silently merging distinct BuildingIndex stocks")
	await process_frame
	await process_frame
	_hud._layout()
	_check(Rect2(Vector2.ZERO, Vector2(root.size)).encloses(_hud._world_panel.get_global_rect()),"native shop controls and eight-row scroll view remain inside a960x600window")
	_hud._service_offset=8
	var before:=_actions.size()
	_hud._service_shop.select(2)
	_hud._service_shop.item_selected.emit(2)
	var query: Dictionary=JSON.parse_string(_actions.back().trim_prefix("systems_query:"))
	_check(query.shop==9005 and query.offset==0 and _actions.size()==before+1 and _actions.back().begins_with("systems_query:"),"selecting the native parts shop requests its catalog at offset0 without buying anything")
	_check(int(_hud._service_quantity.value)==4,"changing native shop preserves the selected transaction quantity")
	_state.services.shop=9005
	_state.services.shop_options=[_state.services.shop_options[1],_state.services.shop_options[2],_state.services.shop_options[0]]
	_hud.set_systems_state(_state)
	_check(_hud._service_shop.selected==1 and int(_hud._service_shop.get_selected_metadata())==9005 and _hud.systems_query().shop==9005,"shop selection follows BuildingIndex when native options are reordered")
	_state.services.shop_options.remove_at(0)
	_hud.set_systems_state(_state)
	_check(_hud._service_shop_id==0 and _hud._service_shop.selected==0 and _hud.systems_query().shop==0,"a removed native shop clears the selection to the default contact")
	_hud._select_service_shop(9006)
	_state.services.map_id=2002
	_state.services.shop=10001
	_state.services.shop_options=[{"building_index":10001,"map_id":2002,"name":"Outra cidade","native_stock_count":3}]
	_hud.set_systems_state(_state)
	_check(_hud._service_shop_id==0 and _hud._service_offset==0,"travel to another city clears the previous native shop and page")
	_state.services.shop_options=[]
	_hud.set_systems_state(_state)
	_check(_hud._service_shop.disabled,"a city with no recovered shop cannot offer a fake selectable stock")
	_hud._select_service_mode("maintenance")
	_check(not _hud._service_shop_toolbar.visible,"maintenance hides unrelated native stock selection")


func _test_consumables() -> void:
	var item := {"item_num":7002600,"name":"Kit HP original","kind":18,"count":3,"consumable":true,"usable":true,"use_reason":"","use_remaining":0.0,"use_effects":[{"resource":"hp","amount":42}],"use_quantity":1,"equippable_slots":[]}
	var inventory := {"entries":[item],"equipped":{}}
	_hud.set_inventory_state(inventory)
	_hud._select_inventory_cell(0)
	_check(_hud._inventory_use.visible and not _hud._inventory_use.disabled and _hud._inventory_hint.text.contains("×3") and _hud._inventory_use.tooltip_text.contains("HP +42"),"owned supported consumable exposes a native inventory use button with stack count and recovered effect")
	_hud._inventory_use.pressed.emit()
	_check(_actions.back()=="use_item:7002600" and int(_hud._inventory_state.entries[0].count)==3,"using a kit emits one item identity without client-side consumption or healing")
	var before := _actions.size()
	item.usable=false
	item.use_reason="Efeito original 23900 ainda não implementado; item preservado."
	item.use_effects=[]
	_hud.set_inventory_state(inventory)
	_hud._inventory_use.pressed.emit()
	_check(_hud._inventory_use.disabled and _hud._inventory_use.tooltip_text.contains("23900") and _actions.size()==before,"unsupported native effects remain blocked and cannot emit even a forced button signal")
	item.use_reason="Recuperação ainda em recarga."
	item.use_remaining=2.8
	_hud.set_inventory_state(inventory)
	var cell: Node=_hud._inventory_icons.get_child(0)
	_check(_hud._inventory_use.disabled and _hud._inventory_use.tooltip_text.contains("2.8 s"),"real cooldown availability is shown with the use rejection reason")
	item.use_remaining=2.7
	_hud.set_inventory_state(inventory)
	_check(_hud._inventory_icons.get_child(0)==cell and float(_hud._inventory_state.entries[0].use_remaining)==2.7,"fractional cooldown updates preserve source state without rebuilding every inventory cell each frame")
	item.usable=true
	item.use_remaining=0.0
	item.use_reason=""
	_hud.set_inventory_state(inventory)
	_check(not _hud._inventory_use.disabled,"model confirmation of cooldown expiry re-enables the selected owned kit")
	_hud.set_online_state({"status":"connecting","connected":false})
	_hud._inventory_use.pressed.emit()
	_check(_hud._inventory_use.disabled and _hud._inventory_use.tooltip_text.contains("online") and _actions.size()==before,"pending online authority blocks consumables before authentication and never invents a server item-use command")
	_hud.set_online_state({"status":"offline","connected":false})
	_hud.set_inventory_state({"entries":[],"equipped":{}})
	_check(not _hud._inventory_use.visible and _hud._inventory_use.disabled,"an absent owned stack removes the use action")


func _test_skills() -> void:
	_hud._select_library_tab("skills")
	_check(_hud._systems_toolbar.get_child(0).autowrap_mode == TextServer.AUTOWRAP_OFF and _hud._systems_toolbar.get_child(0).custom_minimum_size.x >= 230, "skill assignment label keeps a readable horizontal width without vertical letter wrapping")
	_check(_hud._systems_toolbar.get_combined_minimum_size().y < 60, "skill toolbar cannot expand the world panel beyond the viewport")
	_check(_hud._world_missions.get_child_count() == 8 and _hud._library_filtered.size() == 557, "557 skill records stay paginated to eight rows")
	_check(_hud._vital_labels[4].text == "75" and _hud._vital_labels[5].text == "100", "native HUD SP reads actual skill model resources")
	var learned: Control = _hud._world_missions.get_child(0)
	var available: Control = _hud._world_missions.get_child(1)
	var blocked: Control = _hud._world_missions.get_child(2)
	_check((learned.find_child("LearnSkill_1000", true, false) as Button).disabled, "learned skill cannot be bought again")
	_check(not available.find_child("LearnSkill_1001", true, false).disabled, "compatible affordable rank can be learned at an allowed school")
	available.find_child("LearnSkill_1001", true, false).pressed.emit()
	_check(_actions.back() == "skill_learn:1001", "learn request uses exact original skill id")
	_check((blocked.find_child("AssignSkill_1002", true, false) as Button).disabled, "unsupported effects cannot be assigned")
	_hud._skill_slot.value = 8
	learned.find_child("AssignSkill_1000", true, false).pressed.emit()
	_check(_actions.back() == "skill_assign:8:1000", "assignment selects any hotbar slot1 through8")
	_hud._skill_buttons[0].pressed.emit()
	_check(_actions.back() == "skill_use:1", "real HUD shortcut requests model activation")
	_check(_hud._skill_buttons[1].disabled, "empty shortcut has no fake activation")
	_hud._library_available.button_pressed = true
	_check(_hud._library_filtered.size() == 2, "available skill filter shows learned and learnable entries only")
	_state.skills.learn_allowed = false
	_state.skills.learn_reason = "Escola adequada não disponível."
	_hud.set_systems_state(_state)
	var learn: Button = _hud._world_missions.get_child(1).find_child("LearnSkill_1001", true, false)
	_check(learn.disabled and learn.tooltip_text.contains("Escola adequada"), "missing native school disables otherwise eligible learning")
	_state.skills.learn_allowed = true
	_state.equipment.credits = 0
	_hud.set_systems_state(_state)
	learn = _hud._world_missions.get_child(1).find_child("LearnSkill_1001", true, false)
	_check(learn.disabled and learn.tooltip_text.contains("Saldo SPI insuficiente"), "learning also requires actual SPI balance")
	_state.equipment.credits = 1000
	_hud.set_systems_state(_state)
	var compact := _state.duplicate(true)
	compact.skills.erase("rows")
	compact.skills.sp = 50
	_hud.set_systems_state(compact)
	_check(_hud._library_filtered.size() == 2 and _hud._vital_labels[4].text == "50", "compact hotbar refresh preserves the full catalog without recopying it")


func _test_equipment() -> void:
	_hud._select_library_tab("equipment")
	_check(not _hud._library_search.visible and _hud._world_missions.get_child_count() == 8, "attribute page stays compact and avoids unrelated catalog filters")
	var attack: Control = _hud._world_missions.find_child("AllocateStat_attack", true, false)
	attack.get_child(1).pressed.emit()
	_check(_actions.back() == "allocate_stat:attack:1", "attribute action requests exactly one validated point")
	_check(_state.equipment.bonus_stats == 3, "attribute UI never spends points itself")
	var slots: Control = _hud._world_missions.get_child(7)
	slots.get_child(0).pressed.emit()
	_check(_actions.back() == "unequip_item:armor", "armor removal preserves the explicit equipment slot")
	_check(slots.get_child(1).disabled, "empty CPU cannot be unequipped")
	_state.equipment.bonus_stats = 0
	_hud.set_systems_state(_state)
	attack = _hud._world_missions.find_child("AllocateStat_attack", true, false)
	_check(attack.get_child(1).disabled, "zero bonus points disables distribution")


func _test_network() -> void:
	_hud._select_library_tab("network")
	_hud._network_address.text = "fe80::1"
	_hud._network_port.value = 26000
	_hud._network_address.grab_focus()
	_check(_hud.wants_keyboard(), "LAN address field captures keyboard movement and firing")
	var address_control: LineEdit = _hud._network_address
	_state.skills.sp = 40
	_hud.set_systems_state(_state)
	_check(_hud._network_address == address_control and _hud._network_address.has_focus(), "unrelated SP refresh cannot rebuild a focused connection form")
	_hud._world_missions.find_child("NetworkJoin", true, false).pressed.emit()
	var payload: Dictionary = JSON.parse_string(_actions.back().trim_prefix("network:"))
	_check(payload.action == "join" and payload.address == "fe80::1" and payload.port == 26000, "JSON network action preserves colons in address")
	_hud._world_missions.find_child("NetworkHost", true, false).pressed.emit()
	payload = JSON.parse_string(_actions.back().trim_prefix("network:"))
	_check(payload.action == "host" and payload.port == 26000, "host action uses selected port")
	_state.network = {"status": "connected", "connected": true, "mode": "client", "peer_count": 2, "peers": {"1": {"name": "[b]Literal[/b]", "map_index": 3002, "gear_id": "12003100"}}, "chat": [{"peer_id": 1, "name": "Anfitrião", "text": "[url]Texto literal[/url]"}]}
	_hud.set_systems_state(_state)
	_check(_hud._world_missions.find_child("NetworkHost", true, false).disabled, "connected session cannot silently host a second connection")
	_check(not _hud._chat_log.bbcode_enabled and _hud._chat_log.text.contains("[url]Texto literal[/url]"), "peer chat is displayed as plain text without markup injection")
	var local_notes: int = _hud._chat_notes.size()
	_hud._chat_input.text_submitted.emit("mensagem LAN")
	payload = JSON.parse_string(_actions.back().trim_prefix("network:"))
	_check(payload.action == "chat" and payload.text == "mensagem LAN", "chat submits to live transport only while connected")
	_check(_hud._chat_notes.size() == local_notes, "LAN submission does not masquerade as a local note or successful echo")
	_hud._world_missions.find_child("NetworkLeave", true, false).pressed.emit()
	payload = JSON.parse_string(_actions.back().trim_prefix("network:"))
	_check(payload.action == "disconnect", "disconnect action reaches actual network model")
	_hud._network_address.grab_focus()
	_hud.toggle_world_panel()
	await process_frame
	_check(not _hud.wants_keyboard(), "closing M releases connection input focus")


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition: _failures.append(message)
