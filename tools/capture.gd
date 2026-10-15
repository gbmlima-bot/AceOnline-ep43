extends SceneTree
## Use the editor executable and a display; release templates do not support --script.
## Godot --path client --script tools/capture.gd -- --output=/path.png [--inventory] [--size=1440x900]

var scene: Node
var frames := 0
var output := ""
var show_inventory := false
var capture_size := Vector2i.ZERO
var freeze_flight := false
var capture_gear := ""
var capture_map := 3002
var show_world := false
var training_mission := false
var expected_position := Vector3.ZERO
var combat_shot := false
var library_tab := ""
var library_query := ""
var appearance_id := 0
var service_mode := ""


func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--output="):
			output = argument.trim_prefix("--output=")
		elif argument == "--inventory":
			show_inventory = true
		elif argument == "--freeze":
			freeze_flight = true
		elif argument == "--world-panel":
			show_world = true
		elif argument == "--training-mission":
			training_mission = true
		elif argument == "--combat-shot":
			combat_shot = true
		elif argument.begins_with("--map="):
			capture_map = int(argument.trim_prefix("--map="))
		elif argument.begins_with("--library-tab="):
			library_tab = argument.trim_prefix("--library-tab=")
			show_world = true
		elif argument.begins_with("--service-mode="):
			service_mode = argument.trim_prefix("--service-mode=")
			library_tab = "services"
			show_world = true
		elif argument.begins_with("--query="):
			library_query = argument.trim_prefix("--query=")
		elif argument.begins_with("--appearance="):
			appearance_id = int(argument.trim_prefix("--appearance="))
		elif argument.begins_with("--gear="):
			capture_gear = argument.trim_prefix("--gear=")
		elif argument.begins_with("--size="):
			var dimensions := argument.trim_prefix("--size=").split("x")
			if dimensions.size() == 2:
				capture_size = Vector2i(int(dimensions[0]), int(dimensions[1]))
	library_tab = {"attrs": "equipment", "attributes": "equipment", "appearances": "gears"}.get(library_tab, library_tab)
	if not service_mode.is_empty(): library_tab = "services"
	if not service_mode.is_empty() and service_mode not in ["buy", "sell", "recipes", "maintenance"]:
		push_error("Invalid --service-mode; use buy, sell, recipes or maintenance")
		quit(1)
		return
	if output.is_empty():
		push_error("Missing --output=/path.png")
		quit(1)
		return
	if capture_size.x > 0 and capture_size.y > 0:
		root.content_scale_size = capture_size
		root.size = capture_size
	scene = (load("res://main.tscn") as PackedScene).instantiate()
	root.add_child(scene)
	if freeze_flight:
		scene.set_physics_process(false)
	print("CAPTURE_UI_MANIFEST=", FileAccess.file_exists("res://assets/legacy_ui/manifest.json"))


func _process(_delta: float) -> bool:
	frames += 1
	if frames == 1 and capture_size.x > 0 and capture_size.y > 0:
		# Project window overrides are applied after SceneTree initialization.
		root.size = capture_size
		root.content_scale_size = capture_size
	if frames == 1 and freeze_flight:
		# Script processing is registered after _initialize; freeze after _ready.
		scene._reset_flight()
		scene.set_physics_process(false)
	if frames == 1:
		if capture_map != 3002:
			var loaded: Dictionary = {}
			# Prefer the actual DAT portal entry instead of inventing a camera spawn.
			for portal: Dictionary in scene.world_runtime._portals:
				if int(portal.get("destination_map_id", 0)) == capture_map:
					for _tick in range(3):
						scene.world_runtime.advance(1.0, portal.position)
					loaded = scene.world_runtime.use_portal(str(portal.id))
					break
			if loaded.is_empty():
				loaded = scene.world_runtime.load_map(capture_map)
			if not loaded.get("ok", false):
				push_error("Capture map unavailable: " + str(capture_map) + " " + str(loaded))
				quit(1)
				return false
		if training_mission:
			var first: Dictionary = scene.world_runtime.accept_mission("101")
			var second: Dictionary = scene.world_runtime.accept_mission("102")
			if not first.get("ok", false) or not second.get("ok", false):
				push_error("Capture could not accept native mission101/102")
				quit(1)
				return false
			scene._drain_simulation_events()
		expected_position = scene.map_spawn
		if combat_shot:
			# Hold only the flight pose for a repeatable demonstration. Targets,
			# native weapons, damage, AI and projectiles use production simulation.
			scene.model.movement_enabled = false
			scene.combat_runtime.model.select_target(0)
	if frames == 1 and not capture_gear.is_empty():
		var profiles: Array = scene.original_scene_profile.get("gear_profiles", [])
		for _index in profiles.size():
			if str(scene.original_scene_profile.get("active_gear_id", "")) == capture_gear:
				break
			scene._cycle_gear()
		if str(scene.original_scene_profile.get("active_gear_id", "")) != capture_gear:
			push_error("Unknown capture gear: " + capture_gear)
			quit(1)
			return false
	if frames == 20 and show_inventory:
		scene.legacy_hud.toggle_inventory()
	if frames == 20 and show_world:
		scene.legacy_hud.toggle_world_panel()
		if not library_tab.is_empty():
			scene.legacy_hud._select_library_tab(library_tab)
			scene.legacy_hud._library_search.text = library_query
			scene.legacy_hud._library_search.text_changed.emit(library_query)
		if not service_mode.is_empty():
			scene.legacy_hud._select_service_mode(service_mode)
			# Keep the visible mode and main's production query in sync.
			scene._on_local_action("systems_query:" + JSON.stringify(scene.legacy_hud.systems_query()))
		if is_instance_valid(scene.get("systems")):
			scene.systems.refresh_ui()
	if frames == 20 and appearance_id > 0:
		scene._on_local_action("preview_gear:" + str(appearance_id))
	if combat_shot and frames > 1 and frames <= 100:
		var targets: Array = scene.combat_runtime.model.targets
		if not targets.is_empty():
			scene._aim_screen = scene.camera.unproject_position(targets[0].position)
		scene._primary_held = true
		scene._secondary_held = true
		scene._physics_process(1.0 / 60.0)
	if frames == 100:
		if freeze_flight and (scene.is_physics_processing() or not scene.model.position.is_equal_approx(expected_position)):
			push_error("Comparison capture did not keep the initial flight state")
			quit(1)
			return false
		var captured := root.get_texture().get_image()
		var result := captured.save_png(output)
		var controls: Array = []
		_collect_controls(scene.legacy_hud, controls)
		var captured_profile: Variant = scene.get("original_scene_profile")
		var metadata := {
			"origin": "Godot reconstruction; not an original-client capture",
			"inventory_open": show_inventory,
			"world_panel_open": show_world,
			"library_tab": library_tab,
			"service_mode": service_mode,
			"systems": _compact_systems(),
			"appearance_source_index": appearance_id,
			"training_mission_accepted": training_mission,
			"combat_advanced_with_frozen_flight_pose": combat_shot,
			"map_index": scene.current_map_id,
			"combat": scene.combat_runtime.snapshot(),
			"world": scene.world_runtime.get_state(),
			"freeze_flight_for_comparison": freeze_flight,
			"physics_process_enabled": scene.is_physics_processing(),
			"model_position": [scene.model.position.x, scene.model.position.y, scene.model.position.z],
			"active_gear_id": str(captured_profile.get("active_gear_id", "")) if captured_profile is Dictionary else "",
			"logical_size": [root.get_visible_rect().size.x, root.get_visible_rect().size.y],
			"render_size": [captured.get_width(), captured.get_height()],
			"controls": controls,
		}
		var file := FileAccess.open(output.get_basename() + "-layout.json", FileAccess.WRITE)
		if file:
			file.store_string(JSON.stringify(metadata, "  "))
		print("CAPTURE_RESULT=", result, " path=", output)
		quit(0 if result == OK else 1)
	return false


func _collect_controls(node: Node, rows: Array) -> void:
	if node is Control and node.is_visible_in_tree():
		var bounds: Rect2 = node.get_global_rect()
		var row := {"name": str(node.name), "class": node.get_class(), "rect": [bounds.position.x, bounds.position.y, bounds.size.x, bounds.size.y]}
		if node is TextureRect and node.texture:
			row["texture"] = node.texture.resource_path
		if node is Label:
			row["text"] = node.text
		rows.append(row)
	for child in node.get_children():
		_collect_controls(child, rows)


func _compact_systems() -> Dictionary:
	var state: Dictionary = scene.legacy_hud.get("_systems_state")
	var skills: Dictionary = state.get("skills", {})
	var services: Dictionary = state.get("services", {})
	var equipment: Dictionary = state.get("equipment", {})
	var network: Dictionary = state.get("network", {})
	var quotes: Array = []
	for quote: Dictionary in services.get("quotes", []):
		quotes.append({"resource": quote.get("resource", quote.get("kind", "")), "ok": quote.get("ok", false), "affordable": quote.get("affordable", false), "amount": quote.get("amount", 0), "cost": quote.get("cost", 0)})
	var contact: Dictionary = services.get("contact", {})
	return {
		"skills": {"catalog_count": (skills.get("rows", []) as Array).size(), "supported": skills.get("supported_count", 0), "blocked": skills.get("blocked_count", 0), "sp": skills.get("sp", 0), "max_sp": skills.get("max_sp", 0), "hotbar": skills.get("hotbar", [])},
		"services": {"mode": services.get("mode", ""), "allowed": services.get("allowed", false), "reason": services.get("reason", ""), "page_rows": (services.get("rows", []) as Array).size(), "total": services.get("total", 0), "offset": services.get("offset", 0), "native_contact_id": contact.get("id", contact.get("npc_id", 0)), "quotes": quotes},
		"equipment": {"native_catalog_count": equipment.get("catalog_count", 0), "owned_entry_count": (equipment.get("entries", []) as Array).size(), "equipped": equipment.get("equipped", {}), "credits": equipment.get("credits", 0), "bonus_stats": equipment.get("bonus_stats", 0), "allocated_stats": equipment.get("allocated_stats", {}), "total_stats": equipment.get("total_stats", {})},
		"network": {"status": network.get("status", "offline"), "mode": network.get("mode", "offline"), "connected": network.get("connected", false), "peer_count": network.get("peer_count", 0), "chat_entries": (network.get("chat", []) as Array).size(), "scope": "LAN presence and chat; local independent combat and rewards"},
	}
