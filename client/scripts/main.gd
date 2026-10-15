extends Node3D
## Offline orchestration; native data and equations live in the flight/world/combat modules.

const Model = preload("res://scripts/flight_model.gd")
const OriginalHUD = preload("res://scripts/legacy_hud.gd")
const OriginalAssetRenderer = preload("res://scripts/original_asset.gd")
const OriginalPropsRenderer = preload("res://scripts/original_props.gd")
const CombatScene = preload("res://scripts/combat_runtime.gd")
const ProgressStore = preload("res://scripts/local_save.gd")
const AudioRuntime = preload("res://scripts/original_audio.gd")
const WaterRenderer = preload("res://scripts/original_water.gd")
const SystemsRuntime = preload("res://scripts/game_systems.gd")
const OnlineView = preload("res://scripts/online/online_view.gd")
const ORIGINAL_PROFILE := "res://assets/original_3d/runtime_scene.json"
const INK := Color("122631")
const WHITE := Color("eff9f8")
const MUTED := Color("a6c4cb")
const MINT := Color("76e1d3")
const AMBER := Color("ffc179")
const RING_RADIUS := 22.0
const RING_POINTS: Array[Vector3] = [
	Vector3(0, 105, -40), Vector3(15, 118, -290),
	Vector3(-35, 145, -535), Vector3(-115, 170, -780),
	Vector3(-30, 205, -1030), Vector3(120, 230, -1280),
	Vector3(210, 245, -1540), Vector3(110, 270, -1810),
]

var model = Model.new()
var ship: Node3D
var camera: Camera3D
var exhausts: Array[MeshInstance3D] = []
var rings: Array[Node3D] = []
var ring_materials: Array[StandardMaterial3D] = []
var active_ring := 0
var is_paused := false
var flight_time := 0.0
var flash_time := 0.0
var legacy_hud: OriginalHUD
var original_scene_profile: Dictionary = {}
var original_world: Node3D
var original_sky: Node3D
var original_clouds: Node3D
var original_props: Node3D
var original_water: Node3D
var ship_bounds := AABB()
var chase_offset := Vector3(0.0, 5.5, 19.0)
var camera_focus_distance := 36.0
var world_runtime: Node
var combat_runtime: Node3D
var ship_visual: Node3D
var map_spawn := Model.START_POSITION
var current_map_id := 3002
var _primary_held := false
var _secondary_held := false
var _target_next := false
var _combat_ready := false
var _aim_screen := Vector2.INF
var original_audio: AudioRuntime
var _save_path := ProgressStore.DEFAULT_PATH
var _progress_enabled := not OS.get_cmdline_args().has("--script")
var _loading_progress := false
var _autosave_time := 0.0
var _last_boosting := false
var _last_target_lock := false
var _library_revision := -1
var _appearance_overrides: Dictionary = {}
var _gear_library: Dictionary = {}
var systems: Node
var online_view: Node


func _ready() -> void:
	_configure_input()
	if not _load_original_profile():
		return
	_create_environment()
	if not _create_ship():
		return
	camera = Camera3D.new()
	camera.fov = 74.0
	camera.far = 6500.0
	camera.near = 0.2
	add_child(camera)
	camera.current = true
	original_audio = AudioRuntime.new()
	original_audio.name = "OriginalAudioRuntime"
	add_child(original_audio)
	_create_hud()
	_create_course()
	var world_script: Script = load("res://scripts/world_runtime.gd")
	if world_script == null:
		_asset_failure(PackedStringArray(["world_runtime_missing"]))
		return
	world_runtime = world_script.new()
	world_runtime.name = "LocalWorldRuntime"
	add_child(world_runtime)
	world_runtime.connect("map_changed", _on_world_map_changed)
	var loaded: Dictionary = world_runtime.call("load_map", 3002)
	if not bool(loaded.get("ok", false)):
		_asset_failure(PackedStringArray([str(loaded.get("error", "initial_map_load_failed"))]))
		return
	combat_runtime = CombatScene.new()
	combat_runtime.name = "LocalCombatRuntime"
	add_child(combat_runtime)
	_combat_ready = bool(combat_runtime.call("setup", world_runtime, ship))
	combat_runtime.call("configure_gear", str(original_scene_profile.active_gear_id))
	world_runtime.set("reward_applicator", Callable(self, "_apply_world_inventory_event"))
	world_runtime.set("reward_validator", Callable(self, "_validate_world_inventory_event"))
	if not _combat_ready:
		legacy_hud.append_system_note("Encontro indisponível: faltam regras ou recursos originais.")
	elif _create_ship(false):
		legacy_hud.set_gear_preview(ship)
	_sync_player_profile()
	systems = SystemsRuntime.new()
	systems.name = "GameSystems"
	add_child(systems)
	if not systems.setup(self):
		_asset_failure(PackedStringArray(["new_game_systems_unavailable"]))
		return
	if _progress_enabled and (ProgressStore.exists(_save_path) or (_save_path == ProgressStore.DEFAULT_PATH and ProgressStore.exists(ProgressStore.LEGACY_PATH))):
		_load_local_game()
	online_view = OnlineView.new()
	online_view.name = "OnlineArenaView"
	add_child(online_view)
	online_view.setup(self)
	_update_hud()


func _load_original_profile() -> bool:
	if not FileAccess.file_exists(ORIGINAL_PROFILE):
		_asset_failure(PackedStringArray(["original_scene_profile_missing"]))
		return false
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(ORIGINAL_PROFILE))
	if not parsed is Dictionary or int(parsed.get("schema_version", 0)) != 1:
		_asset_failure(PackedStringArray(["original_scene_profile_invalid"]))
		return false
	original_scene_profile = parsed
	# The portable manifest is authoritative for the available original models.
	var manifest: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://assets/original_3d/manifest.json"))
	if manifest is Dictionary:
		var profiles: Array = []
		for entry: Dictionary in manifest.get("entries", []):
			profiles.append({"source_id": str(entry.id), "name": str(entry.reference_class) + "Original", "display_name": str(entry.reference_class), "resource_path": str(entry.scene_path), "resource_sha256": str(entry.sha256), "position": [0,0,0], "rotation_degrees": [0,0,0], "scale": [1,1,1], "expected_aabb_min": entry.aabb.min, "expected_aabb_max": entry.aabb.max, "expected_triangles": entry.triangles, "orientation": {"forward": "-Z", "up": "+Y", "heading_baked": true}})
		original_scene_profile.gear_profiles = profiles
	return true


func _asset_failure(issues: PackedStringArray) -> void:
	set_process(false)
	set_physics_process(false)
	for issue: String in issues:
		push_error(issue)
	get_tree().quit(1)


func _configure_input() -> void:
	var mappings := {
		"pitch_up": KEY_W, "pitch_down": KEY_S, "roll_left": KEY_A,
		"roll_right": KEY_D, "yaw_left": KEY_Q, "yaw_right": KEY_E,
		"boost": KEY_SHIFT, "brake": KEY_SPACE, "reset_flight": KEY_R, "pause_flight": KEY_P,
		"toggle_inventory": KEY_I,
		"cycle_gear": KEY_F2, "toggle_world": KEY_M, "target_next": KEY_TAB,
		"interact_world": KEY_E, "toggle_landing": KEY_G, "toggle_siege": KEY_T,
		"save_local_game": KEY_F5, "load_local_game": KEY_F9,
	}
	for action: String in mappings:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
			var key := InputEventKey.new()
			key.physical_keycode = mappings[action]
			InputMap.action_add_event(action, key)
	for slot in range(1, 9):
		var action := "skill_slot_" + str(slot)
		if not InputMap.has_action(action):
			InputMap.add_action(action)
			var key := InputEventKey.new()
			key.physical_keycode = KEY_0 + slot
			InputMap.action_add_event(action, key)


func _input(event: InputEvent) -> void:
	# Releases reach us even when a GUI control consumed the original press.
	if event is InputEventMouseButton and not event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT: _primary_held = false
		if event.button_index == MOUSE_BUTTON_RIGHT: _secondary_held = false
	if not is_instance_valid(legacy_hud) or legacy_hud.wants_keyboard():
		return
	if event is InputEventMouseMotion and not legacy_hud.blocks_weapons():
		_aim_screen = event.position
	if event.is_action_pressed("target_next") and not event.is_echo() and not legacy_hud.blocks_weapons():
		_target_next = true
		get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if not is_instance_valid(legacy_hud) or legacy_hud.wants_keyboard():
		return
	if is_online_active():
		_handle_online_input(event)
		return
	if is_instance_valid(systems) and not event.is_echo():
		for slot in range(1, 9):
			if event.is_action_pressed("skill_slot_" + str(slot)):
				systems.cast_slot(slot)
				get_viewport().set_input_as_handled()
				return
	if event.is_action_pressed("reset_flight"):
		_reset_flight()
	elif event.is_action_pressed("pause_flight"):
		is_paused = not is_paused
	elif event.is_action_pressed("toggle_inventory"):
		legacy_hud.toggle_inventory()
	elif event.is_action_pressed("cycle_gear"):
		_cycle_gear()
	elif event.is_action_pressed("toggle_world"):
		legacy_hud.toggle_world_panel()
		original_audio.play_effect("open_menu" if legacy_hud.is_world_panel_open() else "close_menu")
	elif event.is_action_pressed("save_local_game"):
		_save_local_game()
	elif event.is_action_pressed("load_local_game"):
		_load_local_game()
	elif event.is_action_pressed("interact_world") and is_instance_valid(world_runtime):
		var state: Dictionary = world_runtime.call("get_state")
		var nearby: Dictionary = state.get("nearby_interaction", {})
		if not nearby.is_empty():
			_show_world_error(world_runtime.call("interact_nearest", model.position))
			if str(nearby.get("kind", "")) in ["npc", "contact", "mission_npc"] and not legacy_hud.is_world_panel_open():
				legacy_hud.toggle_world_panel()
	elif event.is_action_pressed("toggle_landing"):
		_toggle_landing()
	elif event.is_action_pressed("toggle_siege"):
		if model.set_siege(not model.siege):
			legacy_hud.append_system_note("Cerco A-GEAR ativado." if model.siege else "Cerco A-GEAR desativado.")
	elif event is InputEventMouseButton and not legacy_hud.blocks_weapons():
		_aim_screen = event.position
		if event.button_index == MOUSE_BUTTON_LEFT: _primary_held = event.pressed
		if event.button_index == MOUSE_BUTTON_RIGHT: _secondary_held = event.pressed


func _physics_process(delta: float) -> void:
	if not is_instance_valid(world_runtime) or not is_instance_valid(combat_runtime):
		return
	if is_online_active():
		online_view.physics_tick(delta)
		return
	var modal := legacy_hud.is_world_panel_open()
	if is_paused or modal:
		_primary_held = false
		_secondary_held = false
		_target_next = false
		return
	flight_time += delta
	if is_instance_valid(systems): systems.advance(delta)
	world_runtime.call("advance", delta, model.position)
	var previous: Vector3 = model.position
	var typing: bool = legacy_hud.wants_keyboard()
	var combat_state: Dictionary = combat_runtime.call("snapshot")
	if not bool(combat_state.get("dead", false)):
		var yaw: float = 0.0 if typing else Input.get_axis("yaw_right", "yaw_left")
		var world_state: Dictionary = world_runtime.call("get_state")
		if not (world_state.get("nearby_interaction", {}) as Dictionary).is_empty() and Input.is_action_pressed("interact_world"):
			yaw = 1.0 if Input.is_action_pressed("yaw_left") else 0.0
		if model.landing:
			var support: Dictionary = world_runtime.call("probe_landing", model.position, 4.0, 180.0, model.gear_id)
			if not bool(support.get("ok", false)) or not model.update_landing_contact(support.get("position", Vector3.INF), support.get("normal", Vector3.UP)):
				model.clear_surface_transition()
				legacy_hud.append_system_note("Pouso cancelado: a superfície deixou de permitir contato.")
		model.advance({
			"pitch": 0.0 if typing else Input.get_axis("pitch_down", "pitch_up"),
			"roll": 0.0 if typing else Input.get_axis("roll_right", "roll_left"),
			"yaw": yaw,
			"boost": not typing and Input.is_action_pressed("boost"),
			"brake": not typing and Input.is_action_pressed("brake"),
			"ground_throttle": 0.0 if typing else Input.get_axis("pitch_down", "pitch_up"),
		}, delta)
		var collision: Dictionary = world_runtime.call("resolve_motion" if model.airborne else "resolve_ground_motion", previous, model.position, 4.0)
		if bool(collision.get("collided", false)):
			var impact: Dictionary = model.resolve_collision(collision.position, collision.get("normal", Vector3.UP), str(collision.get("kind", "terrain")))
			impact.collided = true
			impact.kind = str(collision.get("kind", "terrain"))
			combat_runtime.call("receive_collision", impact)
		if not model.airborne and world_runtime.has_method("ground_contact"):
			var contact: Dictionary = world_runtime.call("ground_contact", model.position, 4.0)
			if bool(contact.get("ok", false)):
				model.set_ground_contact(contact.position, contact.get("normal", Vector3.UP))
		ship.position = model.position
		ship.quaternion = model.orientation
		_check_course(previous)
	var masked := legacy_hud.blocks_weapons()
	var flight: Dictionary = model.snapshot()
	flight.position = model.position
	flight.forward = model.forward()
	combat_runtime.call("advance", delta, {"primary": _primary_held and not masked, "secondary": _secondary_held and not masked, "target_next": _target_next and not masked, "aim_origin": camera.project_ray_origin(_aim_position()), "aim_direction": camera.project_ray_normal(_aim_position())}, flight)
	if model.boosting != _last_boosting:
		original_audio.play_effect("boost_start" if model.boosting else "boost_end")
		_last_boosting = model.boosting
	var locked: bool = float(combat_runtime.call("snapshot").get("lock_progress", 0.0)) >= 1.0
	if locked and not _last_target_lock:
		original_audio.play_effect("lock_on")
	_last_target_lock = locked
	_target_next = false
	if is_instance_valid(systems): systems.sync_resources()
	_drain_simulation_events()


func _drain_simulation_events() -> void:
	if is_online_active(): return
	for event: Dictionary in combat_runtime.call("drain_events"):
		match str(event.get("type", "")):
			"native_pve_reward":
				if bool(world_runtime.call("record_combat_reward", event)):
					legacy_hud.append_system_note("PvE · %d XP · %d SPI · dados originais do servidor." % [int(event.get("experience", 0)), int(event.get("credits", 0))])
					if int(event.get("credits", 0)) > 0 or not event.get("items", []).is_empty(): original_audio.play_effect("get_item")
				_sync_player_profile()
			"fired":
				original_audio.play_weapon(int(event.get("item_num", 0)), model.gear_id)
			"hit":
				original_audio.play_binding("weapon_effects", int(event.get("source_id", 0)), "hit")
			"target_destroyed":
				original_audio.play_binding("monster_effects", int(event.get("monster_code", 0)), "destroyed")
				world_runtime.call("record_target_destroyed", event.get("monster_code", 0), str(event.get("instance_id", "")), event.get("position", model.position))
				legacy_hud.append_system_note("Alvo destruído · encontro local.")
			"player_died":
				original_audio.play_binding("gear_effects", int(model.gear_id), "destroyed")
				model.movement_enabled = false
				model.speed = 0.0
				model.travel_speed = 0.0
				model.boosting = false
				legacy_hud.append_system_note("GEAR destruído · reaparecimento local em andamento.")
				_primary_held = false
				_secondary_held = false
			"player_respawned":
				_reset_player_pose()
				legacy_hud.append_system_note("GEAR recuperado no ponto de entrada do mapa.")
	for event: Dictionary in world_runtime.call("drain_events"):
		var kind := str(event.get("type", ""))
		if kind in ["reward", "mission_reward", "reward_claimed", "mission_item_collected"] or (kind == "mission_accepted" and event.has("reward_id")):
			if bool(event.get("inventory_applied", false)) or bool(combat_runtime.call("apply_reward", event)):
				original_audio.play_effect("get_item")
			else:
				legacy_hud.append_system_note("O inventário recusou a transação da missão; a recompensa não foi entregue.")
			_sync_player_profile()
		var message := str(event.get("message", event.get("text", "")))
		if not message.is_empty():
			legacy_hud.append_system_note(message)
	if legacy_hud.is_world_panel_open():
		_refresh_library()


func _apply_world_inventory_event(event: Dictionary) -> bool:
	return is_instance_valid(combat_runtime) and bool(combat_runtime.call("apply_reward", event))


func _validate_world_inventory_event(event: Dictionary) -> bool:
	return is_instance_valid(combat_runtime) and bool(combat_runtime.inventory.can_apply_reward(event))


func _toggle_landing() -> void:
	if is_online_active(): return
	if not is_instance_valid(world_runtime):
		return
	if not model.airborne or model.landing:
		if model.take_off(): legacy_hud.append_system_note("Decolagem local.")
		original_audio.play_effect("takeoff")
	elif world_runtime.has_method("probe_landing"):
		var contact: Dictionary = world_runtime.call("probe_landing", model.position, 4.0, 180.0, model.gear_id)
		if bool(contact.get("ok", false)) and model.begin_landing(contact.position, contact.get("normal", Vector3.UP)):
			legacy_hud.append_system_note("Aproximação de pouso iniciada · G cancela e decola; T ativa cerco do A-GEAR no solo.")
			original_audio.play_effect("landing")
		else:
			legacy_hud.append_system_note(str(contact.get("reason", "Aproxime-se de uma superfície permitida para pousar.")))


func _process(delta: float) -> void:
	if is_online_active(): online_view.frame(delta)
	if not is_instance_valid(camera):
		return
	var desired: Vector3 = model.position + Basis(model.orientation) * chase_offset
	# Camera avoidance is a modern adaptation using the same world obstacles.
	if is_instance_valid(world_runtime) and world_runtime.collision_model != null:
		var anchor: Vector3 = model.position + Vector3.UP * 2.0
		var obstruction: Dictionary = world_runtime.call("trace_segment", anchor, desired, 1.0)
		if bool(obstruction.get("collided", false)):
			desired = obstruction.get("position", desired) + obstruction.get("normal", Vector3.ZERO) * 0.5
	camera.position = camera.position.lerp(desired, 1.0 - exp(-5.5 * delta))
	var focal_point: Vector3 = model.position + model.forward() * camera_focus_distance + Vector3.UP * 1.3
	camera.look_at(focal_point, Vector3.UP)
	_update_sky_position()
	camera.fov = lerpf(camera.fov, 84.0 if model.boosting else 74.0, 1.0 - exp(-3.0 * delta))
	for exhaust: MeshInstance3D in exhausts:
		exhaust.scale.y = (1.65 if model.boosting else 0.8) + sin(flight_time * 36.0) * 0.05
	flash_time = maxf(0.0, flash_time - delta)
	_update_hud()
	legacy_hud.set_aim_position(_aim_position())
	if _progress_enabled and not _loading_progress and not is_online_active():
		_autosave_time += delta
		if _autosave_time >= 30.0:
			_autosave_time = 0.0
			_save_local_game(false)


func _aim_position() -> Vector2:
	var screen := get_viewport().get_visible_rect()
	return _aim_screen if _aim_screen.is_finite() and screen.has_point(_aim_screen) else screen.size / 2


func _reset_player_pose() -> void:
	var fuel: Dictionary = model.snapshot().get("fuel", {})
	model.reset()
	if bool(fuel.get("configured", false)):
		# Resetting the local flight pose does not erase distance/time already flown.
		fuel["falling"] = float(fuel.get("current", 0.0)) <= 0.0
		fuel["stranded"] = false
		fuel["fall_velocity"] = [0.0, 0.0, 0.0]
		model.restore_fuel_progress(fuel)
	_aim_screen = Vector2.INF
	model.position = map_spawn
	if is_instance_valid(world_runtime): world_runtime.call("advance", 0.0, model.position)
	ship.position = model.position
	ship.quaternion = model.orientation
	camera.position = model.position + Basis(model.orientation) * chase_offset
	camera.look_at(model.position + model.forward() * camera_focus_distance, Vector3.UP)
	_update_sky_position()


func _reset_flight(reset_combat: bool = true) -> void:
	if is_online_active() and not online_view._restoring: return
	_reset_player_pose()
	active_ring = 0
	flight_time = 0.0
	flash_time = 0.0
	is_paused = false
	_primary_held = false
	_secondary_held = false
	_target_next = false
	_refresh_rings()
	if reset_combat and is_instance_valid(combat_runtime):
		combat_runtime.call("respawn_at", map_spawn)


func _on_world_map_changed(data: Dictionary) -> void:
	current_map_id = int(data.get("map_id", 3002))
	var profile: Dictionary = data.get("visual_profile", {})
	for key: String in ["terrain", "props", "sky", "clouds", "environment"]:
		if profile.has(key): original_scene_profile[key] = profile[key]
	_create_environment()
	for visual: Node3D in [original_world, original_sky, original_clouds]:
		if is_instance_valid(visual):
			remove_child(visual)
			visual.queue_free()
	original_world = null
	original_props = null
	original_sky = null
	original_clouds = null
	if not _create_terrain() or not _create_original_props() or not _create_original_sky():
		return
	original_water = WaterRenderer.instantiate(world_runtime.current_map.get("metadata", {}), world_runtime.current_map.get("source_map_info", {}))
	original_world.add_child(original_water)
	map_spawn = data.get("spawn_position", Model.START_POSITION)
	if data.get("bounds_min") is Vector3 and data.get("bounds_max") is Vector3:
		model.configure_world(data.bounds_min, data.bounds_max)
	if is_online_active() and not online_view._restoring:
		for ring: Node3D in rings: ring.visible = false
		if is_instance_valid(original_audio): original_audio.select_map(world_runtime.current_map.get("source_map_info", {}))
		return
	# A portal changes the encounter, not the character's resources or death timer.
	var boost_fraction: float = model.boost_energy
	var was_overheated: bool = model.overheated
	_reset_flight(false)
	model.boost_energy = boost_fraction
	model.overheated = was_overheated
	if is_instance_valid(combat_runtime):
		combat_runtime.call("transfer_to_map", map_spawn, current_map_id)
		if bool(combat_runtime.call("snapshot").get("dead", false)):
			model.movement_enabled = false
			model.speed = 0.0
			model.travel_speed = 0.0
	for ring: Node3D in rings: ring.visible = current_map_id == 3002
	_library_revision = -1
	if is_instance_valid(original_audio):
		original_audio.select_map(world_runtime.current_map.get("source_map_info", {}))
		if _combat_ready and not _loading_progress:
			original_audio.play_effect("warp")
	legacy_hud.append_system_note("Entrada em %s · sessão local." % data.get("map_title", str(current_map_id)))


func _material(color: Color, metallic: float = 0.0, emission: float = 0.0) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.72
	material.metallic = metallic
	if emission > 0.0:
		material.emission_enabled = true
		material.emission = color
		material.emission_energy_multiplier = emission
	return material


func _mesh(parent: Node3D, mesh: Mesh, location: Vector3, material: Material) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.position = location
	instance.material_override = material
	parent.add_child(instance)
	return instance


func _box(parent: Node3D, location: Vector3, dimensions: Vector3, material: Material) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = dimensions
	return _mesh(parent, mesh, location, material)


func _create_environment() -> void:
	for node_name: String in ["OriginalAssetViewerEnvironment", "OriginalAssetViewerLight"]:
		var previous := get_node_or_null(node_name)
		if previous:
			remove_child(previous)
			previous.queue_free()
	# Viewer lighting is explicit; an unextracted sky is not replaced with clouds,
	# islands or a generated sky texture presented as original-client artwork.
	var settings: Dictionary = original_scene_profile.get("environment", {})
	var world := WorldEnvironment.new()
	world.name = "OriginalAssetViewerEnvironment"
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = _profile_color(settings.get("background_color", [0.20, 0.26, 0.31]))
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = _profile_color(settings.get("ambient_light_color", [0.78, 0.82, 0.87]))
	environment.ambient_light_energy = float(settings.get("ambient_light_energy", 0.8))
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	world.environment = environment
	add_child(world)
	var sun := DirectionalLight3D.new()
	sun.name = "OriginalAssetViewerLight"
	var rotation: Array = settings.get("sun_rotation_degrees", [-34, -35, 0])
	sun.rotation_degrees = Vector3(float(rotation[0]), float(rotation[1]), float(rotation[2]))
	sun.light_color = _profile_color(settings.get("sun_color", [1.0, 0.96, 0.9]))
	sun.light_energy = float(settings.get("sun_energy", 1.4))
	sun.shadow_enabled = false
	add_child(sun)


func _profile_color(values: Array) -> Color:
	return Color(float(values[0]), float(values[1]), float(values[2]))


func _create_terrain() -> bool:
	if is_instance_valid(world_runtime) and int(world_runtime.current_map.get("source_map_info", {}).get("TileRenderingFlag", 1)) == 0:
		# Native space/object maps intentionally have no QuadGround or MAP texture.
		original_world = Node3D.new()
		original_world.name = "OriginalNonTileWorld"
		original_world.set_meta("native_tile_rendering_disabled", true)
		add_child(original_world)
		return true
	var result: Dictionary = OriginalAssetRenderer.instantiate(original_scene_profile.get("terrain", {}))
	if result.node == null:
		_asset_failure(result.errors)
		return false
	original_world = result.node as Node3D
	add_child(original_world)
	return true


func _create_original_sky() -> bool:
	for key: String in ["sky", "clouds"]:
		var settings: Dictionary = original_scene_profile.get(key, {})
		if settings.is_empty():
			continue
		var result: Dictionary = OriginalAssetRenderer.instantiate(settings)
		if result.node == null:
			_asset_failure(result.errors)
			return false
		var layer: Node3D = result.node as Node3D
		_configure_sky_layer(layer, key == "sky")
		add_child(layer)
		if key == "sky":
			original_sky = layer
		else:
			original_clouds = layer
	return true


func _create_original_props() -> bool:
	var settings: Dictionary = original_scene_profile.get("props", {})
	if settings.is_empty() or str(settings.get("layout_path", "")).is_empty():
		return true
	var result: Dictionary = OriginalPropsRenderer.instantiate(str(settings.layout_path))
	if result.node == null or not result.errors.is_empty():
		if result.node != null:
			result.node.free()
		_asset_failure(result.errors)
		return false
	original_props = result.node as Node3D
	# Native placements already include the terrain's handedness and center.
	# The terrain root remains identity; no additional model heading is applied.
	original_world.add_child(original_props)
	return true


func _configure_sky_layer(node: Node, background: bool) -> void:
	if node is MeshInstance3D:
		# The local top-down map uses layer1; only the main camera sees layer2.
		node.layers = 2
		for surface in range(node.mesh.get_surface_count()):
			var material: Material = node.get_active_material(surface)
			if material is BaseMaterial3D:
				var viewer_material: BaseMaterial3D = material.duplicate()
				# Keep texture/color/shading/alpha from the conversion. Sky cannot
				# write foreground depth or bypass depth testing over the GEAR.
				viewer_material.no_depth_test = false
				if background:
					viewer_material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
				node.set_surface_override_material(surface, viewer_material)
	for child: Node in node.get_children():
		_configure_sky_layer(child, background)


func _update_sky_position() -> void:
	if is_instance_valid(original_sky):
		original_sky.position = camera.position
	if is_instance_valid(original_clouds):
		original_clouds.position = camera.position


func _create_course() -> void:
	for point: Vector3 in RING_POINTS:
		var ring := Node3D.new()
		ring.position = point
		add_child(ring)
		var torus := TorusMesh.new()
		torus.inner_radius = RING_RADIUS - 0.55
		torus.outer_radius = RING_RADIUS + 0.55
		torus.rings = 48
		torus.ring_segments = 8
		var material := _material(MINT, 0.25, 0.65)
		var hoop := _mesh(ring, torus, Vector3.ZERO, material)
		hoop.rotation.x = PI * 0.5
		for side in [-1.0, 1.0]:
			_box(ring, Vector3(side * (RING_RADIUS + 2.0), 0, 0), Vector3(3.4, 7.0, 2.0), _material(Color("253f47"), 0.55))
			_box(ring, Vector3(side * (RING_RADIUS + 2.0), 0, 1.1), Vector3(1.0, 4.5, 0.3), material)
		rings.append(ring)
		ring_materials.append(material)


func _refresh_rings() -> void:
	for index in range(rings.size()):
		var color := AMBER if index == active_ring else MINT
		if index < active_ring:
			color = Color("426f73")
		ring_materials[index].albedo_color = color
		ring_materials[index].emission = color
		ring_materials[index].emission_energy_multiplier = 1.0 if index == active_ring else 0.25


func _check_course(previous: Vector3) -> void:
	if current_map_id != 3002 or active_ring >= RING_POINTS.size():
		return
	var point: Vector3 = RING_POINTS[active_ring]
	var segment: Vector3 = model.position - previous
	if absf(segment.z) < 0.000001:
		return
	var factor := (point.z - previous.z) / segment.z
	if factor < 0.0 or factor > 1.0:
		return
	var intersection := previous + segment * factor
	if Vector2(intersection.x - point.x, intersection.y - point.y).length() <= RING_RADIUS - 1.0:
		active_ring += 1
		flash_time = 2.1
		_refresh_rings()


func _create_ship(load_engine: bool = true) -> bool:
	var selected: Dictionary = {}
	for profile: Dictionary in original_scene_profile.get("gear_profiles", []):
		if str(profile.get("source_id", "")) == str(original_scene_profile.get("active_gear_id", "")):
			selected = profile
			break
	var base_gear := str(original_scene_profile.get("active_gear_id", ""))
	var remote_visual: bool = is_online_active() and not online_view._restoring
	if remote_visual:
		var server_armor: Dictionary = online_view.ship_profile()
		if not server_armor.is_empty(): selected = server_armor
	else:
		if is_instance_valid(combat_runtime) and combat_runtime.inventory.has_method("armor_appearance"):
			var armor: Dictionary = combat_runtime.inventory.armor_appearance()
			if bool(armor.get("available", false)):
				var equipped_visual := _appearance_profile(int(armor.get("source_index", 0)), base_gear)
				if not equipped_visual.is_empty(): selected = equipped_visual
		if _appearance_overrides.has(base_gear):
			var appearance: Dictionary = _appearance_profile(int(_appearance_overrides[base_gear]), base_gear)
			if not appearance.is_empty(): selected = appearance
	var result: Dictionary = OriginalAssetRenderer.instantiate(selected)
	if result.node == null:
		_asset_failure(result.errors)
		return false
	if not is_instance_valid(ship):
		ship = Node3D.new()
		ship.name = "PlayerGEAR"
		add_child(ship)
	if is_instance_valid(ship_visual):
		ship.remove_child(ship_visual)
		ship_visual.queue_free()
	ship_visual = result.node as Node3D
	ship.add_child(ship_visual)
	ship_bounds = result.bounds
	ship.set_meta("visual_bounds", ship_bounds)
	for key: StringName in ship_visual.get_meta_list():
		ship.set_meta(key, ship_visual.get_meta(key))
	ship.set_meta("original_resource", selected.get("resource_path", ""))
	if load_engine: model.load_gear_profile(base_gear)
	ship.set_meta("preview_label", str(selected.get("display_name", "GEAR")) + (" ORIGINAL · EQUIPAMENTO ONLINE" if remote_visual else " ORIGINAL · EQUIPAMENTO LOCAL"))
	ship.set_meta("scene_provenance", "Modelo original convertido. Arena PvE dedicada: combate, SP, habilidades e progresso sob autoridade do servidor; perfil offline separado." if remote_visual else "Modelos e regras originais convertidos. Progresso local, equipamentos, SP e habilidades interpretadas; LAN para voo e chat, com combate individual. Sem conta do servidor original.")
	# Camera framing follows the measured original dimensions, without scaling
	# the source model or changing its source origin. Flight pose remains outside.
	var center := ship_bounds.get_center()
	chase_offset = center + Vector3(0, maxf(5.5, ship_bounds.size.y * 0.9), maxf(19.0, ship_bounds.size.z * 1.6))
	camera_focus_distance = maxf(36.0, ship_bounds.size.z * 2.0)
	exhausts.clear() # Original exhaust effects have not been converted.
	return true


func _cycle_gear() -> void:
	if is_online_active(): return
	var profiles: Array = original_scene_profile.get("gear_profiles", [])
	if profiles.size() < 2:
		return
	var current := 0
	for index in range(profiles.size()):
		if str(profiles[index].get("source_id", "")) == str(original_scene_profile.get("active_gear_id", "")):
			current = index
			break
	var next_gear := str(profiles[(current + 1) % profiles.size()].source_id)
	if is_instance_valid(combat_runtime) and combat_runtime.inventory.has_method("can_change_gear"):
		var check: Dictionary = combat_runtime.inventory.can_change_gear(next_gear)
		if not bool(check.get("ok", false)):
			legacy_hud.append_system_note("A distribuição de atributos atual impede a troca local para esta classe.")
			return
	if is_instance_valid(combat_runtime):
		var changed: Dictionary = combat_runtime.call("configure_gear", next_gear)
		if not bool(changed.get("ok", false)):
			legacy_hud.append_system_note("Não foi possível equipar esta classe; o GEAR atual foi preservado.")
			return
	original_scene_profile.active_gear_id = next_gear
	if not _create_ship():
		return
	ship.position = model.position
	ship.quaternion = model.orientation
	if is_instance_valid(combat_runtime):
		model.configure(combat_runtime.inventory.catalog[int(combat_runtime.inventory.equipped.engine)])
	_sync_player_profile()
	legacy_hud.set_gear_preview(ship)
	legacy_hud.append_system_note("Prévia da nave original: %s. F2 alterna os modelos locais." % profiles[(current + 1) % profiles.size()].display_name)


func _create_hud() -> void:
	legacy_hud = OriginalHUD.new()
	add_child(legacy_hud)
	legacy_hud.set_gear_preview(ship)
	legacy_hud.local_action_requested.connect(_on_local_action)


func _on_local_action(action: String) -> void:
	if is_instance_valid(online_view) and online_view.handle_action(action): return
	if is_instance_valid(systems) and systems.handle_action(action):
		if action.begins_with("equip_item:") or action.begins_with("unequip_item:"):
			if _create_ship(false): legacy_hud.set_gear_preview(ship)
		_drain_simulation_events()
		_update_hud()
		return
	if action == "pause":
		is_paused = not is_paused
	elif action == "reset":
		_reset_flight()
	elif action == "interact" and is_instance_valid(world_runtime):
		_show_world_error(world_runtime.call("interact_nearest", model.position))
	elif action.begins_with("accept_mission:") and is_instance_valid(world_runtime):
		_show_world_error(world_runtime.call("accept_mission", action.trim_prefix("accept_mission:")))
	elif action.begins_with("claim_reward:") and is_instance_valid(world_runtime):
		_show_world_error(world_runtime.call("claim_reward", action.trim_prefix("claim_reward:")))
	elif action.begins_with("mission_details:"):
		var details: Dictionary = world_runtime.call("mission_details", action.trim_prefix("mission_details:"))
		if bool(details.get("ok", false)):
			legacy_hud.call("show_mission_details", details)
		else:
			_show_world_error(details)
	elif action.begins_with("travel_map:"):
		var identifier := action.trim_prefix("travel_map:")
		if identifier.is_valid_int():
			_show_world_error(world_runtime.call("load_map", int(identifier)))
	elif action.begins_with("equip_item:"):
		var parts := action.split(":")
		if parts.size() == 3 and parts[2].is_valid_int():
			var equipped: Dictionary = combat_runtime.call("equip_item", int(parts[2]), parts[1])
			if bool(equipped.get("ok", false)):
				if parts[1] == "engine": model.configure(equipped.get("item", {}))
				legacy_hud.append_system_note("Equipamento local atualizado.")
			else:
				_show_world_error(equipped)
	elif action == "refresh_library":
		_refresh_library(true)
	elif action == "save_game":
		_save_local_game()
	elif action == "load_game":
		_load_local_game()
	elif action == "toggle_audio":
		var muted: bool = original_audio.toggle_muted()
		legacy_hud.append_system_note("Áudio desativado." if muted else "Áudio original ativado.")
	elif action.begins_with("preview_gear:"):
		var identifier := action.trim_prefix("preview_gear:")
		var base_gear := str(original_scene_profile.active_gear_id)
		if identifier.is_valid_int() and not _appearance_profile(int(identifier), base_gear).is_empty():
			_appearance_overrides[base_gear] = int(identifier)
			if _create_ship(false):
				legacy_hud.set_gear_preview(ship)
				legacy_hud.append_system_note("Teste de aparência original aplicado; os atributos do equipamento foram preservados.")
	elif action == "reset_appearance":
		_appearance_overrides.erase(str(original_scene_profile.active_gear_id))
		if _create_ship(false): legacy_hud.set_gear_preview(ship)
	if is_instance_valid(combat_runtime): _drain_simulation_events()
	_update_hud()


func _show_world_error(result: Dictionary) -> void:
	if not bool(result.get("ok", false)):
		legacy_hud.append_system_note(str(result.get("message", "A interação não pôde ser concluída.")))


func _refresh_library(force: bool = false) -> void:
	if not is_instance_valid(world_runtime) or not legacy_hud.has_method("set_library_data"):
		return
	var state: Dictionary = world_runtime.call("get_state")
	var revision := int(state.get("revision", 0))
	if not force and revision == _library_revision:
		return
	var missions: Dictionary = world_runtime.call("mission_catalog", 0, 1000, true)
	legacy_hud.call("set_library_data", world_runtime.call("map_catalog"), missions.get("records", []))
	_library_revision = revision


func _sync_player_profile() -> void:
	if is_online_active() and not online_view._restoring: return
	if not is_instance_valid(world_runtime) or not is_instance_valid(combat_runtime):
		return
	var inventory: Dictionary = combat_runtime.call("snapshot").get("inventory", {})
	var kinds := {"12000100": 1, "12001100": 16, "12002100": 256, "12003100": 4096}
	world_runtime.call("configure_player_profile", {"level": int(inventory.get("level", 9)), "unit_kind": int(kinds.get(model.gear_id, 4096))})
	if is_instance_valid(systems): systems.sync_profile()
	_library_revision = -1


func _appearance_profile(identifier: int, base_gear: String) -> Dictionary:
	if _gear_library.is_empty():
		var path := "res://assets/original_library/gears/gears.json"
		if not FileAccess.file_exists(path): return {}
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if not parsed is Dictionary: return {}
		_gear_library = parsed
	var entry: Dictionary = _gear_library.get("by_source_index", {}).get(str(identifier), {})
	var masks := {"12000100": 1, "12001100": 16, "12002100": 256, "12003100": 4096}
	if not bool(entry.get("available", false)) or (int(entry.get("unit_kind_mask", 0)) & int(masks.get(base_gear, 0))) == 0 or not ResourceLoader.exists(str(entry.get("resource_path", ""))):
		return {}
	var result := entry.duplicate(true)
	result["source_id"] = str(entry.get("model_id", ""))
	result["name"] = "OriginalAppearance" + str(identifier)
	result["display_name"] = "APARÊNCIA " + str(identifier)
	return result


func _capture_local_progress() -> Dictionary:
	if is_online_active(): return online_view._checkpoint.duplicate(true)
	if is_instance_valid(systems): systems.sync_resources()
	world_runtime.call("advance", 0.0, model.position)
	return {"schema_version": 1, "release": "0.9.0", "world": world_runtime.call("export_state"), "combat": combat_runtime.call("export_state"),
		"flight": {"gear_id": model.gear_id, "position": [model.position.x, model.position.y, model.position.z],
			"orientation": [model.orientation.x, model.orientation.y, model.orientation.z, model.orientation.w],
			"speed": model.speed, "boost_energy": model.boost_energy, "overheated": model.overheated,
			"fuel_fraction": model.fuel_fraction, "weight_ratio": model.weight_ratio,
		"airborne": model.airborne, "siege": model.siege, "fuel": model.snapshot().get("fuel", {}), "transition": model.transition_progress()}, "audio_muted": original_audio.muted, "appearances": _appearance_overrides.duplicate(), "systems": systems.export_state() if is_instance_valid(systems) else {}}


func _save_local_game(show_message: bool = true) -> Dictionary:
	if is_online_active(): return {"ok": false, "error": "online_profile_separate", "message": "O progresso online é salvo pelo servidor; o perfil offline foi preservado."}
	if not _combat_ready or _loading_progress:
		return {"ok": false, "error": "session_not_ready"}
	var result: Dictionary = ProgressStore.save_game(_capture_local_progress(), _save_path)
	if show_message:
		legacy_hud.append_system_note(str(result.get("message", "Falha ao salvar o progresso.")))
	return result


func _load_local_game() -> Dictionary:
	if is_online_active(): return {"ok": false, "error": "online_profile_separate", "message": "Desconecte da arena para carregar o perfil offline."}
	if not _combat_ready or _loading_progress:
		return {"ok": false, "error": "session_not_ready"}
	var loaded: Dictionary = ProgressStore.read_current_game() if _save_path == ProgressStore.DEFAULT_PATH else ProgressStore.read_game(_save_path)
	if not bool(loaded.get("ok", false)):
		_show_world_error(loaded)
		return loaded
	var result: Dictionary = _restore_local_progress(loaded.snapshot)
	if bool(result.get("ok", false)):
		legacy_hud.append_system_note(str(loaded.get("message", "Progresso local carregado.")))
		if loaded.has("migrated_from"):
			var migrated: Dictionary = _save_local_game(false)
			if not bool(migrated.get("ok", false)): _show_world_error(migrated)
	else:
		_show_world_error(result)
	return result


func _restore_local_progress(snapshot: Dictionary) -> Dictionary:
	var flight: Variant = snapshot.get("flight")
	if not flight is Dictionary or not snapshot.get("world") is Dictionary or not snapshot.get("combat") is Dictionary:
		return {"ok": false, "message": "Progresso local incompleto."}
	if not snapshot.get("systems", {}) is Dictionary:
		return {"ok": false, "message": "Habilidades, serviços ou consumíveis salvos inválidos."}
	if not snapshot.combat.get("inventory") is Dictionary or not snapshot.world.get("wallet") is Dictionary:
		return {"ok": false, "message": "Inventário ou saldo salvo inválido."}
	var gear_id := str(flight.get("gear_id", ""))
	var known := false
	for profile: Dictionary in original_scene_profile.get("gear_profiles", []):
		if str(profile.get("source_id", "")) == gear_id: known = true
	if not known or str(snapshot.combat.get("inventory", {}).get("gear_id", "")) != gear_id:
		return {"ok": false, "message": "A classe salva não é compatível com o equipamento."}
	var appearances: Variant = snapshot.get("appearances", {})
	if not appearances is Dictionary:
		return {"ok": false, "message": "Aparências salvas inválidas."}
	for key: Variant in appearances:
		var value: Variant = appearances[key]
		if not (value is int or value is float) or not is_finite(float(value)) or float(value) != float(int(value)) or _appearance_profile(int(value), str(key)).is_empty():
			return {"ok": false, "message": "Uma aparência salva ainda não está disponível."}
	for key: String in ["position", "orientation"]:
		var values: Variant = flight.get(key)
		if not values is Array or values.size() != (3 if key == "position" else 4):
			return {"ok": false, "message": "Posição salva inválida."}
		for value: Variant in values:
			if not (value is float or value is int) or not is_finite(float(value)):
				return {"ok": false, "message": "Posição salva inválida."}
	for key: String in ["speed", "boost_energy", "fuel_fraction", "weight_ratio"]:
		var value: Variant = flight.get(key)
		if not (value is float or value is int) or not is_finite(float(value)):
			return {"ok": false, "message": "Recursos salvos inválidos."}
	for key: String in ["airborne", "siege", "overheated"]:
		if not flight.get(key) is bool:
			return {"ok": false, "message": "Estado de voo salvo inválido."}
	var fuel_progress: Variant = flight.get("fuel", {})
	if not fuel_progress is Dictionary or (not fuel_progress.is_empty() and not Model.validate_fuel_progress(fuel_progress, bool(flight.airborne))):
		return {"ok": false, "message": "O estado de combustível salvo é inválido."}
	if flight.has("transition") and not Model.validate_transition_progress(flight.transition, bool(flight.airborne), gear_id):
		return {"ok": false, "message": "A transição de pouso ou decolagem salva é inválida."}
	var rotation := Quaternion(float(flight.orientation[0]), float(flight.orientation[1]), float(flight.orientation[2]), float(flight.orientation[3]))
	if rotation.length_squared() < 0.5 or rotation.length_squared() > 1.5:
		return {"ok": false, "message": "Orientação salva inválida."}
	if snapshot.world.get("wallet", {}).get("credits", -1) != snapshot.combat.get("inventory", {}).get("credits", -2) or snapshot.world.get("wallet", {}).get("experience", -1) != snapshot.combat.get("inventory", {}).get("experience", -2):
		return {"ok": false, "message": "Os saldos salvos não conferem entre os sistemas."}
	var inventory_receipts: Variant = snapshot.combat.inventory.get("reward_ids", [])
	if not inventory_receipts is Array or not snapshot.world.get("combat_rewards", []) is Array:
		return {"ok": false, "message": "O histórico de recompensas salvo é inválido."}
	for entry: Variant in snapshot.world.get("combat_rewards", []):
		if not entry is Dictionary or not inventory_receipts.has(entry.get("reward_id", "")):
			return {"ok": false, "message": "Uma recompensa PvE salva não consta no inventário."}
	var previous: Dictionary = _capture_local_progress()
	_loading_progress = true
	var world_result: Dictionary = world_runtime.call("import_state", snapshot.world)
	if not bool(world_result.get("ok", false)):
		_loading_progress = false
		return world_result
	var combat_result: Dictionary = combat_runtime.call("import_state", snapshot.combat)
	if bool(combat_result.get("ok", false)) and not fuel_progress.is_empty():
		var expected_capacity := float(combat_runtime.inventory.combat_profile().get("max_ep", 30.0))
		if not is_equal_approx(float(fuel_progress.get("max", -1.0)), expected_capacity) or not is_equal_approx(float(fuel_progress.get("current", -1.0)) / expected_capacity, float(flight.fuel_fraction)):
			combat_result = {"ok": false, "error": "fuel_equipment_mismatch"}
		elif snapshot.combat.player.has("ep") and not is_equal_approx(float(snapshot.combat.player.ep), float(fuel_progress.current)):
			combat_result = {"ok": false, "error": "fuel_combat_mismatch"}
	if not bool(combat_result.get("ok", false)):
		world_runtime.call("import_state", previous.world)
		combat_runtime.call("import_state", previous.combat)
		_apply_flight_progress(previous.flight)
		if is_instance_valid(systems): systems.sync_profile()
		_loading_progress = false
		return {"ok": false, "message": "O equipamento salvo é incompatível; a sessão atual foi preservada.", "error": combat_result.get("error", "")}
	original_scene_profile.active_gear_id = gear_id
	_appearance_overrides = appearances.duplicate()
	model.load_gear_profile(gear_id)
	_create_ship(false)
	model.configure(combat_result.get("engine", {}))
	_apply_flight_progress(flight)
	var systems_result: Dictionary = systems.import_state(snapshot.get("systems", {})) if is_instance_valid(systems) else {"ok": true}
	if not bool(systems_result.get("ok", false)):
		world_runtime.call("import_state", previous.world)
		combat_runtime.call("import_state", previous.combat)
		original_scene_profile.active_gear_id = str(previous.flight.gear_id)
		_appearance_overrides = previous.appearances.duplicate()
		model.load_gear_profile(str(previous.flight.gear_id))
		model.configure(combat_runtime.inventory.catalog[int(combat_runtime.inventory.equipped.engine)])
		_apply_flight_progress(previous.flight)
		systems.import_state(previous.get("systems", {}))
		_create_ship(false)
		_loading_progress = false
		return {"ok": false, "message": "O progresso de habilidades, serviços ou consumíveis é inválido; a sessão foi preservada."}
	if bool(snapshot.get("audio_muted", false)) != original_audio.muted:
		original_audio.toggle_muted()
	_sync_player_profile()
	legacy_hud.set_gear_preview(ship)
	_loading_progress = false
	_drain_simulation_events()
	_update_hud()
	return {"ok": true}


func _apply_flight_progress(flight: Dictionary) -> void:
	model.clear_surface_transition()
	var values: Array = flight.position
	var position := Vector3(float(values[0]), float(values[1]), float(values[2]))
	position = position.clamp(model.bounds_min + Vector3(4, 0, 4), model.bounds_max - Vector3(4, 0, 4))
	var ground: float = world_runtime.call("sample_ground_height", position.x, position.z, true)
	if is_finite(ground): position.y = maxf(position.y, ground + 4.0)
	model.position = position
	var q: Array = flight.orientation
	model.orientation = Quaternion(float(q[0]), float(q[1]), float(q[2]), float(q[3])).normalized()
	model.speed = clampf(float(flight.speed), -model.booster_speed, model.booster_speed)
	model.travel_speed = model.speed
	model.boost_energy = clampf(float(flight.boost_energy), 0, 1)
	model.overheated = bool(flight.overheated)
	var capacity := float(combat_runtime.inventory.combat_profile().get("max_ep", 30.0))
	model.set_fuel_state(clampf(float(flight.fuel_fraction), 0, 1) * capacity, capacity)
	model.weight_ratio = clampf(float(flight.weight_ratio), 0, 10)
	model.airborne = bool(flight.airborne)
	model.siege = bool(flight.siege) and not model.airborne and model.gear_id == "12002100"
	if flight.has("transition"):
		model.restore_transition_progress(flight.transition)
	if flight.get("fuel", {}) is Dictionary and not flight.get("fuel", {}).is_empty() and model.has_method("restore_fuel_progress"):
		model.restore_fuel_progress(flight.fuel)
	model.movement_enabled = not bool(combat_runtime.call("snapshot").get("dead", false))
	if not model.movement_enabled:
		model.speed = 0.0
		model.travel_speed = 0.0
	ship.position = model.position
	ship.quaternion = model.orientation
	camera.position = model.position + Basis(model.orientation) * chase_offset
	camera.look_at(model.position + model.forward() * camera_focus_distance, Vector3.UP)
	combat_runtime.model.set_player_pose(model.position, model.forward())
	world_runtime.call("advance", 0.0, model.position)
	_update_sky_position()
	_primary_held = false
	_secondary_held = false
	_target_next = false
	_aim_screen = Vector2.INF


func _exit_tree() -> void:
	if is_online_active():
		online_view.shutdown()
		return
	if _progress_enabled and _combat_ready and not _loading_progress and is_instance_valid(world_runtime) and is_instance_valid(combat_runtime):
		_save_local_game(false)


func _update_hud() -> void:
	if is_online_active():
		legacy_hud.update_flight(model, [], 0, false, 0.0)
		legacy_hud.update_simulation(online_view.hud_flight(), combat_runtime.snapshot(), online_view.hud_world(), camera)
		return
	var course_points: Array[Vector3] = []
	if current_map_id == 3002:
		course_points = RING_POINTS
	legacy_hud.update_flight(model, course_points, active_ring, is_paused, flash_time)
	var combat: Dictionary = combat_runtime.call("snapshot") if is_instance_valid(combat_runtime) else {}
	if is_instance_valid(systems): combat["inventory"] = systems.inventory_snapshot(combat.get("inventory", {}))
	var world: Dictionary = world_runtime.call("get_state") if is_instance_valid(world_runtime) else {}
	legacy_hud.update_simulation(model.snapshot(), combat, world, camera)


func is_online_active() -> bool:
	return is_instance_valid(online_view) and bool(online_view.active)


func _handle_online_input(event: InputEvent) -> void:
	if not event.is_echo():
		for slot in range(1,9):
			if event.is_action_pressed("skill_slot_"+str(slot)):
				online_view.cast_skill(slot)
				get_viewport().set_input_as_handled()
				return
	if event.is_action_pressed("toggle_inventory"): legacy_hud.toggle_inventory()
	elif event.is_action_pressed("toggle_world"): legacy_hud.toggle_world_panel()
	elif event.is_action_pressed("toggle_landing"):
		online_view.toggle_landing()
	elif event.is_action_pressed("toggle_siege"):
		online_view.toggle_siege()
	elif event is InputEventMouseButton and not legacy_hud.blocks_weapons():
		_aim_screen = event.position
		if event.button_index == MOUSE_BUTTON_LEFT: _primary_held = event.pressed
		if event.button_index == MOUSE_BUTTON_RIGHT: _secondary_held = event.pressed
	else:
		for action: String in ["reset_flight","pause_flight","cycle_gear","save_local_game","load_local_game","interact_world"]:
			if event.is_action_pressed(action):
				legacy_hud.append_system_note("A arena online é controlada pelo servidor; o perfil offline permanece separado.")
				get_viewport().set_input_as_handled()
				return
