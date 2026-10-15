extends SceneTree
## GUI integration: large catalogs, live inventory, requests and source bindings.
## Fixtures exercise pagination; actual ITEM and UI art verify native bindings.

const HUD = preload("res://scripts/legacy_hud.gd")
const Inventory = preload("res://scripts/inventory_model.gd")

var _hud: CanvasLayer
var _checks := 0
var _failures: Array[String] = []
var _actions: Array[String] = []
var _maps: Array = []
var _missions: Array = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(960, 600)
	root.content_scale_size = Vector2i(960, 600)
	_hud = HUD.new()
	root.add_child(_hud)
	await process_frame
	_hud.local_action_requested.connect(func(action: String) -> void: _actions.append(action))
	_check(_hud.inventory_items.size == Vector2(379, 506), "native 2025 inventory frame retains its dimensions")
	_build_catalog_fixtures()
	_hud.set_library_data(_maps, _missions)
	_hud.update_simulation({}, {}, {"map_id": 3002, "map_title": "Original region", "missions": [], "wallet": {}}, null)
	_hud.toggle_world_panel()
	await process_frame
	await process_frame
	_hud._layout()
	_check(_actions.has("refresh_library"), "opening M requests compact catalog refresh once")
	_check(_hud.blocks_weapons(), "library masks combat inputs")
	_check(Rect2(Vector2.ZERO, Vector2(root.size)).encloses(_hud._world_panel.get_global_rect()), "expanded library fits 960×600")
	_check(_hud._world_missions.get_child_count() <= HUD.LIBRARY_PAGE_SIZE, "597 mission records create only one visible page")
	_check(_hud._library_filtered.size() == 597, "all mission records remain searchable")
	_hud._library_next.pressed.emit()
	_check(_hud._library_page == 1 and _hud._world_missions.get_child_count() <= HUD.LIBRARY_PAGE_SIZE, "page navigation replaces rows without growing the tree")
	_test_maps()
	await process_frame
	_test_missions()
	_test_native_mission_details()
	await process_frame
	await _test_live_inventory()
	_test_source_item_index()
	_test_appearance_browser()
	_test_variable_mission_display()
	_hud._library_search.grab_focus()
	_check(_hud.wants_keyboard(), "catalog search owns keyboard focus")
	_hud.toggle_world_panel()
	_check(not _hud.wants_keyboard(), "closing library releases keyboard focus")
	_hud.queue_free()
	await process_frame
	if _failures.is_empty():
		print("library-ui: %d checks passed" % _checks)
		print(JSON.stringify({"suite": "library_ui", "status": "pass", "checks": _checks, "failures": 0}))
		quit(0)
	else:
		for failure: String in _failures: push_error(failure)
		print("library-ui: %d/%d checks failed" % [_failures.size(), _checks])
		print(JSON.stringify({"suite": "library_ui", "status": "fail", "checks": _checks, "failures": _failures.size()}))
		quit(1)


func _build_catalog_fixtures() -> void:
	for index: int in range(238):
		_maps.append({"map_id": 1000 + index, "title": "UI fixture map %03d" % index, "available": index % 3 == 0, "unavailable_reason": "Fixture: terrain texture missing"})
	for index: int in range(597):
		_missions.append({"id": str(index + 1), "title": "UI fixture mission %03d" % index, "status": "available" if index % 4 == 0 else "unsupported", "provenance_label": "Original script · local execution", "disabled_reason": "Fixture: cinematic handler missing" if index % 4 else "", "reward": {"credits": 320, "experience": 91}, "objectives": []})


func _test_maps() -> void:
	_hud._select_library_tab("maps")
	_check(_hud._library_available.button_pressed and _hud._library_filtered.size() == 80, "map browser initially shows only converted maps")
	_hud._library_available.button_pressed = false
	_check(_hud._library_filtered.size() == 238, "map browser retains every original metadata record")
	_check(_hud._world_missions.get_child_count() == HUD.LIBRARY_PAGE_SIZE, "238 maps create only eight rows")
	var unavailable: Button = _hud._world_missions.get_child(1).get_child(1)
	_check(unavailable.disabled and unavailable.tooltip_text.contains("missing"), "unconverted map has disabled travel and a concrete reason")
	_check(str(_hud._world_missions.get_child(1).get_child(0).text).contains("Recursos deste mapa indisponíveis nesta versão.") and not str(_hud._world_missions.get_child(1).get_child(0).text).contains("missing"), "unavailable map explains its status in Portuguese and keeps the source reason in the tooltip")
	var available: Button = _hud._world_missions.get_child(0).get_child(1)
	_check(not available.disabled and available.tooltip_text.contains("local"), "converted map exposes clearly local travel")
	available.pressed.emit()
	_check(_actions.back() == "travel_map:1000", "travel request keeps the native map identifier")
	_hud._library_search.text = "map 237"
	_hud._library_search.text_changed.emit(_hud._library_search.text)
	_check(_hud._library_filtered.size() == 1 and _hud._world_missions.get_child_count() == 1, "name search finds a record beyond the first page")
	_hud._library_search.text = "1237"
	_hud._library_search.text_changed.emit(_hud._library_search.text)
	_check(_hud._library_filtered.size() == 1, "native map codes can be searched directly")
	_hud._library_search.text = ""
	_hud._library_search.text_changed.emit("")
	_hud._library_available.button_pressed = true
	_check(_hud._library_filtered.size() == 80, "available filter excludes maps lacking converted resources")
	_hud._library_available.button_pressed = false
	_hud._library_search.text = "does not exist"
	_hud._library_search.text_changed.emit(_hud._library_search.text)
	_check(_hud._library_filtered.is_empty() and _hud._world_missions.get_child_count() == 1, "empty search produces one explanation and no travel controls")
	_hud._library_search.text = ""
	_hud._library_search.text_changed.emit("")


func _test_missions() -> void:
	_hud._select_library_tab("missions")
	_check(_hud._library_filtered.size() == 597, "mission tab restores the complete compact catalog")
	var unavailable: Control = _hud._world_missions.get_child(1)
	_check(unavailable.find_children("MissionAction_*", "Button", true, false).is_empty() and str(unavailable.get_child(0).text).contains("cinematic"), "unsupported script shows its missing handler without an accept action")
	var available: Button = _hud._world_missions.get_child(0).get_child(1)
	available.pressed.emit()
	_check(_actions.back() == "accept_mission:1", "accept action uses the selected original mission id")
	var update := {"id": "1", "title": "Live quest", "status": "ready", "provenance_label": "Original script", "objectives": [{"kind": "kill_monster", "target_code": 2028100, "current": 3, "required": 3}], "reward": {"credits": 320, "experience": 91}}
	_hud.update_simulation({}, {}, {"map_id": 3002, "map_title": "Original region", "missions": [update], "wallet": {}}, null)
	var current: Control = _hud._world_missions.get_child(0)
	_check(str(current.get_child(0).text).contains("3 / 3") and str(current.get_child(0).text).contains("320 créditos"), "live objective progress and native reward override the cached mission")
	(current.get_child(1) as Button).pressed.emit()
	_check(_actions.back() == "claim_reward:1", "ready mission requests reward rather than accepting again")
	var save: Button = _hud._world_panel.find_child("SaveLocalGame", true, false)
	var load_button: Button = _hud._world_panel.find_child("LoadLocalGame", true, false)
	save.pressed.emit()
	_check(_actions.back() == "save_game", "save control requests local persistence")
	load_button.pressed.emit()
	_check(_actions.back() == "load_game", "load control requests local persistence")
	var audio: Button = _hud._world_panel.find_child("ToggleOriginalMusic", true, false)
	audio.pressed.emit()
	_check(_actions.back() == "toggle_audio", "music control requests original-map audio toggle")


func _test_native_mission_details() -> void:
	var source: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets/legacy_rules/missions.json"))
	var details: Dictionary = {}
	for row: Dictionary in source.get("records", []):
		if int(row.get("id", 0)) == 102:
			details = row
			break
	_hud.show_mission_details(details)
	_check(_hud._mission_details_panel.visible and _hud._mission_details_title.text.contains("102"), "selected native mission opens its recovered prose")
	_check(_hud._mission_details_text.text.contains("320SPI") and _hud._mission_details_text.text.contains("훈련폭격기"), "original Korean briefing and source reward text are preserved")
	_check(not _hud._mission_details_text.bbcode_enabled and not _hud._mission_details_text.text.contains("\\\\n"), "source prose renders line separators without interpreting markup")
	_check(_hud._mission_details_text.selection_enabled, "recovered mission prose can be selected and copied")
	_hud._mission_details_panel.hide()
	var details_button: Button = _hud._world_missions.get_child(0).find_child("MissionDetails_1", true, false)
	details_button.pressed.emit()
	_check(_actions.back() == "mission_details:1", "details are requested only for the selected mission")


func _test_live_inventory() -> void:
	_hud.toggle_world_panel()
	_hud.toggle_inventory()
	await process_frame
	var inventory := Inventory.new()
	_check(inventory.configure(), "inventory reads actual source ITEM records")
	_check(inventory.add_item(7000040, 3), "actual starter weapon is owned by the test profile")
	_check(bool(inventory.equip_item(7000040, "primary").ok), "native weapon slot accepts the compatible source item")
	var before: Dictionary = inventory.export_state()
	_hud.set_inventory_state(inventory.snapshot())
	_check(_hud._inventory_icons.get_child_count() == 1, "inventory draws only owned records rather than all templates")
	var item: Button = _hud._inventory_icons.get_child(0)
	_check(item.tooltip_text.contains("7000040") and item.tooltip_text.contains("×3"), "owned item tooltip binds original identity and actual quantity")
	await process_frame
	_click(item.get_global_rect().get_center())
	_check(not _hud._inventory_equip.disabled and _hud._inventory_selected.item_num == 7000040, "selection enables equip only for eligible owned items")
	_click(_hud._inventory_equip.get_global_rect().get_center())
	_check(_actions.back() == "equip_item:primary:7000040", "equip request preserves native slot and ITEM id")
	_check(inventory.export_state() == before, "browsing and requesting equip do not grant or mutate inventory")
	_click(_hud._inventory_grid.get_global_rect().position + Vector2(5 * 32 + 15, 15))
	_check(_hud._inventory_equip.disabled and _hud._inventory_hint.text.contains("VAZIO"), "empty cells cannot equip a fabricated item")
	var data := inventory.snapshot()
	data.entries = []
	for index: int in range(65):
		data.entries.append({"item_num": 7000040 + index, "name": "UI pagination fixture", "kind": 0, "count": 1, "equippable_slots": []})
	_hud.set_inventory_state(data)
	_check(_hud._inventory_icons.get_child_count() == 60, "native inventory grid draws exactly sixty slots per page")
	_hud._inventory_next.pressed.emit()
	_check(_hud._inventory_icons.get_child_count() == 5 and _hud._inventory_page == 1, "remaining owned items are reachable on the second page")
	_hud._inventory_icons.get_child(0).pressed.emit()
	_check(_hud._inventory_equip.disabled, "item without a supported native slot remains inspectable and unequippable")
	await process_frame
	_hud.toggle_inventory()
	_hud.toggle_world_panel()


func _test_source_item_index() -> void:
	_check(FileAccess.file_exists(HUD.ITEM_INDEX), "release includes the compact original ITEM library")
	if not FileAccess.file_exists(HUD.ITEM_INDEX):
		return
	_hud._select_library_tab("items")
	_check(_hud._library_item_records.size() >= 16000, "full source ITEM index is available without loading the heavy catalog")
	_check(_hud._world_missions.get_child_count() <= HUD.LIBRARY_PAGE_SIZE, "sixteen thousand templates create only one page")
	_hud._library_search.text = "7000040"
	_hud._library_search.text_changed.emit("7000040")
	_check(_hud._library_filtered.size() >= 1, "original starter ITEM can be found in the source catalog")
	var item: Dictionary = _hud._items_by_id.get("7000040", {})
	_check(not item.is_empty() and not str(item.get("icon_path", "")).is_empty(), "item icon is resolved from the source binding index")
	_check(ResourceLoader.exists(str(item.get("icon_path", ""))), "source icon has a usable imported resource")
	if ResourceLoader.exists(str(item.get("icon_path", ""))):
		_check(_hud._item_texture(item) != null, "source icon resolves as an imported native texture")
	var bindings: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets/original_library/icons/index.json"))
	var binding: Dictionary = bindings.get("by_item", {}).get("7000040", {})
	_check(str(binding.get("small", "")) == str(item.get("icon_path", "")) and str(binding.get("source_key", "")) == "07001950", "inventory library uses the proven native SourceIndex icon binding")
	_check(_hud._world_maps.text.contains("não concede"), "catalog explicitly distinguishes templates from owned inventory")
	_check(_hud._world_missions.find_children("*", "Button", true, false).is_empty(), "item catalog has no grant, purchase or equip action")
	_hud._library_search.text = ""
	_hud._library_search.text_changed.emit("")


func _test_appearance_browser() -> void:
	_check(FileAccess.file_exists(HUD.GEAR_INDEX), "release includes the native GEAR appearance registry")
	if not FileAccess.file_exists(HUD.GEAR_INDEX): return
	_hud._select_library_tab("gears")
	_check(_hud._library_gear_records.size() >= 300, "appearance browser exposes converted original armor models")
	_check(_hud._library_filtered.size() > 0 and _hud._world_missions.get_child_count() <= HUD.LIBRARY_PAGE_SIZE, "current class appearances fit a paginated list")
	var first: Control = _hud._world_missions.get_child(0)
	var preview: Button = first.get_child(2)
	_check(not preview.disabled and preview.tooltip_text.contains("não concede"), "compatible model offers an explicit visual preview without granting armor")
	preview.pressed.emit()
	_check(_actions.back().begins_with("preview_gear:"), "appearance request identifies the native ITEM SourceIndex")
	_hud._library_available.button_pressed = false
	var incompatible: Dictionary = {}
	for record: Dictionary in _hud._library_gear_records:
		if (int(record.get("unit_kind_mask", 0)) & 4096) == 0:
			incompatible = record
			break
	_check(not incompatible.is_empty(), "source registry distinguishes class-specific appearances")
	_hud._library_search.text = str(int(incompatible.get("source_index", 0)))
	_hud._library_search.text_changed.emit(_hud._library_search.text)
	var blocked: Button = _hud._world_missions.get_child(0).get_child(2)
	_check(blocked.disabled and blocked.tooltip_text.contains("outra classe"), "appearance from another class cannot be applied through the UI")
	_hud._library_reset_appearance.pressed.emit()
	_check(_actions.back() == "reset_appearance", "reset control restores the class default model through the session")
	_check(_hud._world_maps.text.contains("sem conceder"), "appearance catalog explicitly separates visual testing from equipment")
	_hud._library_search.text = ""
	_hud._library_search.text_changed.emit("")


func _test_variable_mission_display() -> void:
	var mission := {"id": "99999", "title": "Fixture PER e tempo", "status": "active", "native": true, "reward": {"credits": 0, "experience": 10}, "objectives": [{"kind": "inventory", "item_num": 7011290, "current": 1, "required": 2}], "time_limit_seconds": 60, "remaining_seconds": 42, "per_item_rewards": [{"source_item_num": 7011290, "credits": 200}], "random_item_rewards": [{"choices": [{"item_num": 7000040, "weight": 100, "count": 1}]}]}
	_hud.set_library_data(_maps, [mission])
	_hud._select_library_tab("missions")
	_hud._library_search.text = "99999"
	_hud._library_search.text_changed.emit("99999")
	var row: Control = _hud._world_missions.get_child(0)
	var text := str(row.get_child(0).text)
	_check(text.contains("Possuir item 7011290") and text.contains("1 / 2"), "inventory mission objective displays the native item and actual progress")
	_check(text.contains("Tempo restante: 42 s / 60 s"), "timed mission displays remaining active-play seconds")
	_check(text.contains("200 SPI por item 7011290 entregue") and text.contains("Recompensa base: 0"), "PER reward is explained as a variable payout rather than only zero credits")
	_check(text.contains("item aleatório") and text.contains("resultado definido na entrega"), "random rewards are identified without inventing a guaranteed result")
	mission.status = "failed"
	mission.disabled_reason = "Limite de tempo original excedido; nenhuma recompensa foi concedida."
	_hud.set_library_data(_maps, [mission])
	row = _hud._world_missions.get_child(0)
	_check(str(row.get_child(0).text).contains("falhou") and row.find_children("MissionAction_*", "Button", true, false).is_empty(), "expired mission shows failure and cannot claim a reward")
	_hud._library_search.text = ""
	_hud._library_search.text_changed.emit("")
	_hud.set_library_data(_maps, _missions)


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition: _failures.append(message)


func _click(point: Vector2) -> void:
	for pressed: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.global_position = point
		event.button_index = MOUSE_BUTTON_LEFT
		event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
		event.pressed = pressed
		root.push_input(event, true)
