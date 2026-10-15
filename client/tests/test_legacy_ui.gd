extends SceneTree
## Integration tests use real GUI key/click dispatch and deterministic flight steps.
## Run: godot --headless --path client --script res://tests/test_legacy_ui.gd

const Model = preload("res://scripts/flight_model.gd")
const GroupRenderer = preload("res://scripts/legacy_group.gd")
const FLIGHT_ACTIONS: Array[String] = ["pitch_up", "pitch_down", "roll_left", "roll_right", "yaw_left", "yaw_right", "boost", "brake"]

var _scene: Node
var _hud: CanvasLayer
var _checks: int = 0
var _failures: Array[String] = []
var _radar_anchor: Vector2 = Vector2.INF
var _quick_anchor: Vector2 = Vector2.INF


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	if OS.get_cmdline_user_args().has("--group-only"):
		_test_group_transforms()
		_report()
		return
	_test_group_transforms()
	var packed: PackedScene = load("res://main.tscn") as PackedScene
	_check(packed != null, "main scene loads")
	if packed == null:
		_report()
		return
	_scene = packed.instantiate()
	root.add_child(_scene)
	await process_frame
	# Decouple the test clock from the headless renderer's frame rate.
	_scene.set_physics_process(false)
	_scene.set_process(false)
	_hud = _scene.legacy_hud
	_check(is_instance_valid(_hud), "main installs LegacyHUD")
	if not is_instance_valid(_hud):
		_report()
		return
	_release_actions()
	_test_original_resources()
	_test_shipped_group_layout()
	await _test_layout(Vector2i(1024, 768))
	await _test_layout(Vector2i(1440, 900))
	await _test_layout(Vector2i(960, 600))
	await _test_layout(Vector2i(1920, 1080))
	_test_chat_filters_and_separate_logs()
	_test_local_menu_boundaries()
	_test_runtime_hud_bindings()
	_test_inventory_keeps_flight_active()
	_test_chat_masks_controls_without_pausing()
	_test_typing_shortcuts_and_submission()
	_test_pause_button_freezes_model()
	await _test_inventory_drag_and_resize()
	_release_actions()
	_scene.queue_free()
	await process_frame
	_report()


func _test_group_transforms() -> void:
	var bitmap: Image = Image.create(32, 32, false, Image.FORMAT_RGBA8)
	bitmap.fill(Color.WHITE)
	var texture: Texture2D = ImageTexture.create_from_image(bitmap)
	var lookup: Callable = func(_key: String) -> Texture2D: return texture
	var group: Dictionary = {
		"name": "synthetic_transform_contract",
		"metadata": {"translation": [100.0, 100.0, 0.0]},
		"nodes": [
			{"type": 1, "name": "scaled", "source_rect": [2, 3, 10, 9], "translation": [10, 20], "center": [500, 800], "scaling": [2, 0.5], "scale_percent": 0.5, "angle": 0.0},
			{"type": 3, "target_name": "anchor", "control_min": [50, 60], "control_max": [70, 80]},
			{"type": 1, "name": "rotated", "source_rect": [0, 0, 4, 2], "translation": [30, 40], "center": [0, 0], "scaling": [1, 1], "scale_percent": 1.0, "angle": PI / 2.0},
		],
	}
	var renderer: Control = GroupRenderer.new()
	root.add_child(renderer)
	renderer.build(group, lookup)
	_check(renderer.build_errors.is_empty(), "group renderer builds valid crops and transforms")
	_check(renderer.image_nodes.size() == 2 and renderer.get_child_count() == 2, "control anchors do not become drawable nodes")
	_check(renderer.has_control("anchor") and renderer.control_rect("anchor") == Rect2(50, 60, 20, 20), "control rectangle preserves its original coordinates")
	_check(not renderer.has_control("missing") and renderer.control_rect("missing") == Rect2(), "missing control targets are explicit")
	var scaled: TextureRect = renderer.image_nodes["scaled"]
	_check(scaled.position == Vector2(10, 20), "group editor metadata and rotation center do not shift zero-angle tiles")
	_check(scaled.size.is_equal_approx(Vector2(8, 1.5)), "crop dimensions receive scaling and scale_percent exactly once")
	_check(scaled.scale == Vector2.ONE, "scaled display size is not scaled a second time")
	_check(scaled.texture is AtlasTexture and scaled.texture.region == Rect2(2, 3, 8, 6), "LTRB crop becomes the exact atlas region")
	_check(renderer.get_child(0).name == "scaled" and renderer.get_child(1).name == "rotated", "image records retain their draw order around controls")
	_check(renderer.image_bounds.is_equal_approx(Rect2(10, 20, 20, 24)), "image bounds include the rotated quad")
	_check(renderer.layout_bounds.is_equal_approx(Rect2(10, 20, 60, 60)), "layout bounds include non-drawn control anchors")
	renderer.build(group, lookup)
	_check(renderer.get_child_count() == 2, "rebuilding a group replaces its nodes without duplication")
	var broken: Dictionary = {"name": "invalid_crop", "nodes": [{"type": 1, "name": "outside", "source_rect": [0, 0, 33, 1]}]}
	renderer.build(broken, lookup)
	_check(renderer.build_errors.has("source_rectangle_outside_texture:outside"), "invalid source bounds are reported rather than stretched")
	_check(renderer.image_nodes.is_empty() and renderer.get_child_count() == 0, "invalid rebuild leaves no stale images")
	renderer.queue_free()


func _test_original_resources() -> void:
	var path: String = "res://assets/legacy_ui/manifest.json"
	_check(FileAccess.file_exists(path), "original UI manifest is present")
	if not FileAccess.file_exists(path):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	_check(parsed is Dictionary, "UI manifest is an object")
	if not parsed is Dictionary:
		return
	var entries: Array = parsed.get("entries", [])
	_check(entries.size() >= 400, "full original UI collection is registered")
	for entry: Dictionary in entries:
		var name: String = str(entry["name"])
		var asset_path: String = str(entry["path"])
		_check(FileAccess.file_exists(asset_path), "source asset exists: " + name)
		_check(FileAccess.get_sha256(asset_path) == str(entry["sha256"]), "source bytes match manifest: " + name)
		_check(str(entry["sha256"]) == str(entry["source_sha256"]), "source bytes are untransformed: " + name)
		var texture: Texture2D = _hud._texture(name)
		_check(texture != null, "original UI name resolves: " + name)
		if texture != null:
			_check(texture.get_width() == int(entry["width"]) and texture.get_height() == int(entry["height"]), "original dimensions match: " + name)
	_scene._update_hud()
	for digit: TextureRect in _hud._speed_digits:
		_check(digit.texture != null and digit.texture.get_width() > 0, "speed digit has a real texture")
		if digit.texture is AtlasTexture:
			var atlas: AtlasTexture = digit.texture as AtlasTexture
			_check(Rect2(Vector2.ZERO, atlas.atlas.get_size()).encloses(atlas.region), "speed atlas crop stays in source bounds")


func _test_shipped_group_layout() -> void:
	var path: String = "res://assets/legacy_ui/group_layout.json"
	var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets/legacy_ui/manifest.json"))
	var provenance: Dictionary = manifest.get("provenance", {})
	_check(FileAccess.get_sha256(path) == str(provenance.get("group_layout_sha256", "")), "shipped group geometry matches its provenance hash")
	var layout: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	_check(str(layout.get("source_sha256", "")) == str(provenance.get("group_resource_sha256", "")), "group geometry and texture manifest identify the same source resource")
	_check(str(layout.get("texture_resource_sha256", "")) == str(provenance.get("source_resource_sha256", "")), "group geometry refers to the packaged source texture resource")
	# Check the production groups against the shipped data, including anchors that
	# must not draw an extra copy of a gauge or inherit the editor's 100,100 offset.
	var active_groups: Array = [_hud._gauge_anchors, _hud._gauge_artwork, _hud._inventory_group, _hud._minimap_group]
	for renderer: Control in active_groups:
		var group: Dictionary = _hud._groups.get(renderer.group_name, {})
		_check(not group.is_empty() and renderer.build_errors.is_empty(), "active original group resolves without crop/texture errors: " + renderer.group_name)
		var image_index: int = 0
		for record: Dictionary in group.get("nodes", []):
			if int(record.get("type", -1)) == 3:
				var target: String = str(record.get("target_name", ""))
				if not target.is_empty():
					var minimum: Array = record["control_min"]
					var maximum: Array = record["control_max"]
					var expected: Rect2 = Rect2(float(minimum[0]), float(minimum[1]), float(maximum[0]) - float(minimum[0]), float(maximum[1]) - float(minimum[1]))
					_check(renderer.has_control(target) and renderer.control_rect(target).is_equal_approx(expected), "original control anchor is preserved: %s/%s" % [renderer.group_name, target])
				continue
			if int(record.get("type", -1)) != 1:
				continue
			var sprite: TextureRect = renderer.get_child(image_index) as TextureRect if image_index < renderer.get_child_count() else null
			var crop: Array = record["source_rect"]
			var translation: Array = record["translation"]
			var scaling: Array = record["scaling"]
			var region: Rect2 = Rect2(float(crop[0]), float(crop[1]), float(crop[2]) - float(crop[0]), float(crop[3]) - float(crop[1]))
			var expected_size: Vector2 = region.size * Vector2(float(scaling[0]), float(scaling[1])) * float(record.get("scale_percent", 1.0))
			var exact: bool = sprite != null and sprite.texture is AtlasTexture
			if exact:
				exact = str(sprite.get_meta("legacy_source_name", "")) == str(record["name"]) and sprite.texture.region.is_equal_approx(region) and sprite.position.is_equal_approx(Vector2(float(translation[0]), float(translation[1]))) and sprite.size.is_equal_approx(expected_size)
			_check(exact, "original image order/crop/placement is preserved: %s/%d/%s" % [renderer.group_name, image_index, record["name"]])
			image_index += 1
		_check(renderer.get_child_count() == image_index, "group only draws its image records: " + renderer.group_name)
		var bounds: Variant = group.get("image_bounds_unrotated_local")
		if bounds is Array:
			var expected_bounds: Rect2 = Rect2(float(bounds[0]), float(bounds[1]), float(bounds[2]) - float(bounds[0]), float(bounds[3]) - float(bounds[1]))
			_check(renderer.image_bounds.is_equal_approx(expected_bounds), "production image bounds match source layout: " + renderer.group_name)
	_check(_hud._inventory_group.group_name == "inven" and _hud.inventory_items.size == Vector2(379, 506), "standalone inventory uses the 2025 inven group rather than the Trade Center panel")
	_check(_hud._gauge_anchors.get_child_count() == 0, "Gage control anchors do not draw a duplicate HUD")


func _test_layout(dimensions: Vector2i) -> void:
	root.content_scale_size = dimensions
	root.size = dimensions
	await process_frame
	await process_frame
	_scene._update_hud()
	var viewport_size: Vector2 = _hud.root.get_viewport_rect().size
	_check(viewport_size.is_equal_approx(Vector2(dimensions)), "logical viewport is " + str(dimensions))
	# The extracted artwork has different transparent borders from the EP3.5 atlas.
	# Check the displayed bounds and relative anchors, not the old atlas offsets.
	var radar_rect: Rect2 = _hud.radar_frame.get_global_rect()
	_check(_inside_viewport(_hud.radar_frame), "radar artwork is not clipped at " + str(dimensions))
	var radar_anchor: Vector2 = Vector2(viewport_size.x - radar_rect.end.x, radar_rect.position.y)
	if _radar_anchor == Vector2.INF:
		_radar_anchor = radar_anchor
	_check(radar_anchor.is_equal_approx(_radar_anchor), "radar keeps top and right margins across resize at " + str(dimensions))
	_check(radar_rect.get_center().x > viewport_size.x * 0.75 and radar_rect.get_center().y < viewport_size.y * 0.4, "radar remains in the top-right region at " + str(dimensions))
	var quick_rect: Rect2 = _hud.quick_bar.get_global_rect()
	_check(_inside_viewport(_hud.quick_bar), "quick slot artwork is not clipped at " + str(dimensions))
	var quick_anchor: Vector2 = Vector2(quick_rect.get_center().x - viewport_size.x / 2.0, viewport_size.y - quick_rect.end.y)
	if _quick_anchor == Vector2.INF:
		_quick_anchor = quick_anchor
	# The legacy integer expression rounds toward zero below its 1001px baseline.
	_check(quick_anchor.distance_to(_quick_anchor) <= 1.0 and absf(quick_anchor.x) <= 20.0 and quick_anchor.y <= 49.0, "quick slots track bottom center across resize at " + str(dimensions))
	var xp_rect: Rect2 = _hud.experience_background.get_global_rect()
	_check(_inside_viewport(_hud.experience_background), "experience frame stays visible at " + str(dimensions))
	_check(is_zero_approx(xp_rect.position.x) and is_equal_approx(xp_rect.end.x, viewport_size.x) and is_equal_approx(xp_rect.end.y, viewport_size.y), "modern experience strip spans the bottom edge at " + str(dimensions))
	for control: Control in [_hud._minimap_group, _hud._map_viewport_container, _hud._altimeter, _hud._altimeter_pin, _hud._system_log]:
		_check(_inside_viewport(control), "modern map/altimeter/system content stays inside %s: %s" % [dimensions, control.name])
	var system_art: Rect2 = _artwork_rect(_hud._system_root)
	var chat_art: Rect2 = _artwork_rect(_hud._chat_root)
	var viewport: Rect2 = Rect2(Vector2.ZERO, viewport_size).grow(0.1)
	_check(viewport.encloses(system_art) and is_equal_approx(system_art.end.x, viewport_size.x), "system frame including reversed caps fits the right edge at " + str(dimensions))
	_check(viewport.encloses(chat_art) and is_zero_approx(chat_art.position.x), "chat frame including native caps fits the left edge at " + str(dimensions))
	for filter_button: Button in _hud._chat_filters:
		_check(_inside_viewport(filter_button), "chat channel remains reachable at %s: %s" % [dimensions, filter_button.name])
	_check(_hud._reticle.get_global_rect().get_center().is_equal_approx(viewport_size / 2.0), "reticle remains centered at " + str(dimensions))
	for control: Control in [_hud._chat_input, _hud._inventory_button, _hud._pause_button]:
		_check(_inside_viewport(control), "interactive control is reachable at %s: rect=%s viewport=%s" % [dimensions, control.get_global_rect(), viewport_size])
	for node: Node in _hud.root.find_children("*", "Label", true, false):
		var label: Label = node as Label
		if label.is_visible_in_tree():
			_check(_inside_viewport(label), "visible annotation stays inside %s: %s" % [dimensions, label.text])
	# The panels must fit after layout even if their previous location is offscreen.
	_hud.inventory_items.position = Vector2(10000, 10000)
	_hud._layout()
	_check(_inside_viewport(_hud.inventory_items), "inventory frame is clamped after layout at " + str(dimensions))
	_check(_hud.inventory_equipment.get_global_rect().is_equal_approx(_hud.inventory_items.get_global_rect()), "equipment remains integrated with the dragged inventory at " + str(dimensions))


func _test_chat_filters_and_separate_logs() -> void:
	_reset_scene()
	_check(_hud._chat_filters.size() == 9, "chat exposes the nine source channel tabs")
	var system_before: Array = _hud._system_notes.duplicate()
	_hud.append_local_note("UI_TEST_LOCAL_ONLY")
	_check(_hud._system_notes == system_before and not _hud._system_log.text.contains("UI_TEST_LOCAL_ONLY"), "a local note never enters the system log")
	var chat_before: Array = _hud._chat_notes.duplicate()
	_hud.append_system_note("UI_TEST_SYSTEM_ONLY")
	_check(_hud._chat_notes == chat_before and not _hud._chat_log.text.contains("UI_TEST_SYSTEM_ONLY"), "a system note never enters chat")
	var position_before: Vector3 = _scene.model.position
	for index: int in range(7):
		_click(_hud._chat_filters[index].get_global_rect().get_center())
		_check(_hud.chat_filter == index, "physical click selects available channel%d" % index)
		if index <= 1:
			_check(_hud._chat_log.text.contains("UI_TEST_LOCAL_ONLY"), "All/Local retains local notes in channel%d" % index)
		else:
			_check(not _hud._chat_log.text.contains("UI_TEST_LOCAL_ONLY") and _hud._chat_log.text.contains("sem conexão"), "remote channel%d explicitly shows its unavailable state" % index)
		_check(_hud._system_log.text.contains("UI_TEST_SYSTEM_ONLY") and _hud._chat_notes == chat_before, "filter%d changes display without modifying either log" % index)
	for index: int in [7, 8]:
		_check(_hud._chat_filters[index].disabled, "source-disabled Arena/Room tab remains disabled: %d" % index)
		_click(_hud._chat_filters[index].get_global_rect().get_center())
		_check(_hud.chat_filter == 6, "disabled channel%d cannot be activated by clicking" % index)
	# Submitting from an unavailable channel creates an explicitly local note and
	# selects Local so the result is visible without implying a remote delivery.
	var notes_before: int = _hud._chat_notes.size()
	var system_count: int = _hud._system_notes.size()
	_click(_hud._chat_input.get_global_rect().get_center())
	_hud._chat_input.text = "UI_TEST_FILTERED_NOTE"
	_key(KEY_ENTER, 13)
	_check(_hud._chat_notes.size() == notes_before + 1 and str(_hud._chat_notes.back()) == "Local › UI_TEST_FILTERED_NOTE", "submission in a remote view stays a local note")
	_check(_hud.chat_filter == 1 and _hud._chat_log.text.contains("UI_TEST_FILTERED_NOTE"), "local submission switches to Local and reveals the retained note")
	_check(_hud._system_notes.size() == system_count, "local submission leaves the system log untouched")
	_click(_hud._chat_filters[0].get_global_rect().get_center())
	_check(_hud._chat_log.text.contains("UI_TEST_FILTERED_NOTE"), "All also retains the submitted local note")
	_click(_hud._chat_input.get_global_rect().get_center())
	_hud._chat_input.text = "   "
	_key(KEY_ENTER, 13)
	_check(_hud._chat_notes.size() == notes_before + 1 and not _hud.wants_keyboard(), "blank submission adds no note and releases keyboard focus")
	_check(_scene.model.position == position_before and not _scene.is_paused and not _hud.inventory_items.is_visible_in_tree(), "chat filter clicks and submissions do not trigger flight shortcuts")


func _test_local_menu_boundaries() -> void:
	_reset_scene()
	var buttons: Array[Button] = []
	for child: Node in _hud._menu_root.get_children():
		if child is Button:
			buttons.append(child as Button)
		elif child is TextureRect:
			var artwork: TextureRect = child as TextureRect
			var expected_size: Vector2 = artwork.texture.get_size() * 0.8
			_check(artwork.get_global_rect().size.is_equal_approx(expected_size) and artwork.get_global_rect().end.y <= _hud.experience_background.position.y + 0.1, "source idle menu scale leaves the experience strip visible: " + str(artwork.name))
	_check(buttons.size() == 6, "bottom menu has the source FAQ and five main buttons")
	if buttons.size() != 6:
		return
	for button: Button in buttons:
		_check(button.size.is_equal_approx(Vector2(44, 40.8)), "menu hitbox follows the source idle scale: " + button.tooltip_text)
	_click(buttons[0].get_global_rect().get_center())
	_check(_hud._help_panel.is_visible_in_tree() and _inside_viewport(_hud._help_panel), "FAQ opens reachable local control help")
	_key(KEY_F1, 0)
	_check(not _hud._help_panel.is_visible_in_tree(), "F1 closes local control help")
	_click(_hud._chat_input.get_global_rect().get_center())
	_key(KEY_F1, 0)
	_check(not _hud._help_panel.is_visible_in_tree(), "F1 while typing does not open help")
	_key(KEY_ESCAPE, 0)
	_click(buttons[2].get_global_rect().get_center())
	_check(_hud.is_world_panel_open() and _inside_viewport(_hud._world_panel), "information menu opens the local world and mission panel")
	_check(_hud.blocks_weapons(), "world panel blocks weapons without inventing account data")
	_hud.toggle_world_panel()
	for index: int in [3, 4]:
		var position_before: Vector3 = _scene.model.position
		var chat_before: Array = _hud._chat_notes.duplicate()
		var system_count: int = _hud._system_notes.size()
		_click(buttons[index].get_global_rect().get_center())
		_check(_hud._system_notes.size() == system_count + 1 and str(_hud._system_notes.back()).contains("indisponível"), "online menu%d adds only an unavailable notice" % index)
		_check(_hud._chat_notes == chat_before and _scene.model.position == position_before and _scene.active_ring == 0 and not _scene.is_paused and not _hud.inventory_items.is_visible_in_tree(), "online menu%d has no simulated account or flight effect" % index)


func _test_inventory_keeps_flight_active() -> void:
	_reset_scene()
	var panel: Control = _hud.inventory_items
	if panel.is_visible_in_tree():
		_hud.toggle_inventory()
	var node_count: int = _hud.root.get_child_count()
	_click(_hud._inventory_button.get_global_rect().get_center())
	_check(panel.is_visible_in_tree(), "clicking inventory opens the original frame")
	_check(panel.get_global_rect().get_center().distance_to(_hud.root.get_viewport_rect().size / 2.0) <= 1.0, "first inventory opening follows the modern centered caller")
	_check(not _scene.is_paused, "inventory does not pause flight")
	Input.action_press("boost")
	Input.action_press("pitch_up")
	var old_position: Vector3 = _scene.model.position
	var old_speed: float = _scene.model.speed
	_scene._physics_process(0.25)
	_check(_scene.model.position.distance_to(old_position) > 1.0, "flight advances with inventory open")
	_check(_scene.model.boosting and _scene.model.speed > old_speed, "boost accelerates from the original engine minimum with inventory open")
	_check(not _scene.model.orientation.is_equal_approx(Quaternion.IDENTITY), "steering still works with inventory open")
	_release_actions()
	_click(_hud._inventory_button.get_global_rect().get_center())
	_check(not panel.is_visible_in_tree(), "clicking inventory closes the frame")
	for iteration: int in range(3):
		_action_event("toggle_inventory")
		_check(panel.is_visible_in_tree(), "inventory shortcut reopens the same frame")
		_action_event("toggle_inventory")
		_check(not panel.is_visible_in_tree(), "inventory shortcut closes the same frame")
	_check(_hud.root.get_child_count() == node_count, "repeated inventory toggles do not duplicate UI nodes")
	_check(not _scene.is_paused, "inventory clicks never toggle pause")


func _test_chat_masks_controls_without_pausing() -> void:
	_reset_scene()
	var chat: LineEdit = _hud._chat_input
	# Non-opposing axes avoid a false pass caused by opposite keys cancelling.
	for action: String in ["pitch_up", "roll_left", "yaw_left", "boost"]:
		Input.action_press(action)
	_click(chat.get_global_rect().get_center())
	_check(chat.has_focus() and _hud.wants_keyboard(), "clicking chat captures keyboard focus")
	# Commands already held when focus arrives are masked while chat is focused.
	var reference: RefCounted = Model.new()
	var previous: Vector3 = _scene.model.position
	reference.advance({}, 0.25)
	_scene._physics_process(0.25)
	_check(_scene.model.position.is_equal_approx(reference.position), "chat applies neutral controls to movement")
	_check(_scene.model.orientation.is_equal_approx(reference.orientation), "chat blocks new angular controls")
	_check(is_equal_approx(_scene.model.speed, reference.speed), "chat blocks boost and braking")
	_check(is_equal_approx(_scene.model.boost_energy, reference.boost_energy), "chat preserves neutral boost recovery")
	_check(_scene.model.position.distance_to(previous) > 1.0 and _scene.flight_time > 0.0, "chat continues cruise and simulation time")
	_check(not _scene.is_paused, "chat focus does not pause flight")
	_release_actions()
	Input.action_press("brake")
	reference.advance({}, 0.1)
	_scene._physics_process(0.1)
	_check(is_equal_approx(_scene.model.speed, reference.speed), "chat separately blocks held braking")
	_check(_scene.model.position.is_equal_approx(reference.position), "chat neutral movement also holds while brake is pressed")
	_release_actions()
	# Residual angular momentum must decay normally; typing does not freeze pose.
	_scene.model.angular_velocity = Vector3(0.2, 0.3, -0.1)
	reference.angular_velocity = _scene.model.angular_velocity
	reference.advance({}, 0.1)
	_scene._physics_process(0.1)
	_check(_scene.model.orientation.is_equal_approx(reference.orientation), "chat preserves the model's normal angular damping")
	_key(KEY_ESCAPE, 0)
	_check(not chat.has_focus() and not _hud.wants_keyboard(), "Escape releases chat focus")
	Input.action_press("boost")
	_scene._physics_process(0.1)
	_check(_scene.model.boosting, "flight controls work again after leaving chat")
	_release_actions()


func _test_typing_shortcuts_and_submission() -> void:
	_reset_scene()
	var chat: LineEdit = _hud._chat_input
	chat.clear()
	_click(chat.get_global_rect().get_center())
	_scene.model.position = Vector3(40, 150, 50)
	var position_before: Vector3 = _scene.model.position
	var inventory_before: bool = _hud.inventory_items.is_visible_in_tree()
	for code: int in [KEY_R, KEY_P, KEY_I, KEY_W, KEY_A, KEY_S, KEY_D, KEY_Q, KEY_E]:
		_key(code, code + 32)
	_check(chat.text == "rpiwasdqe", "physical letter keys enter text in chat")
	_check(_scene.model.position == position_before, "typing R does not reset flight")
	_check(not _scene.is_paused, "typing P does not pause flight")
	_check(_hud.inventory_items.is_visible_in_tree() == inventory_before, "typing I does not toggle inventory")
	var notes_before: int = _hud._chat_notes.size()
	_key(KEY_ENTER, 13)
	_check(chat.text.is_empty() and not chat.has_focus(), "Enter submits and releases chat")
	_check(_hud._chat_notes.size() == notes_before + 1, "chat submission adds exactly one local note")
	_check(str(_hud._chat_notes.back()).ends_with("rpiwasdqe"), "local note preserves the typed text")
	_check(not _scene.is_paused and _scene.model.position == position_before, "chat submission does not alter flight state")


func _test_pause_button_freezes_model() -> void:
	_reset_scene()
	_scene.model.angular_velocity = Vector3(0.2, 0.1, 0.3)
	Input.action_press("boost")
	_scene._physics_process(0.1)
	var position_before: Vector3 = _scene.model.position
	var orientation_before: Quaternion = _scene.model.orientation
	var speed_before: float = _scene.model.speed
	var energy_before: float = _scene.model.boost_energy
	var time_before: float = _scene.flight_time
	_click(_hud._pause_button.get_global_rect().get_center())
	_check(_scene.is_paused, "pause button dispatches to the scene")
	_scene._physics_process(0.25)
	_check(_scene.model.position == position_before and _scene.model.orientation == orientation_before, "pause freezes flight pose")
	_check(_scene.model.speed == speed_before and _scene.model.boost_energy == energy_before, "pause freezes speed and energy")
	_check(_scene.flight_time == time_before, "pause freezes simulation time")
	_click(_hud._inventory_button.get_global_rect().get_center())
	_check(_scene.is_paused, "opening inventory preserves an explicit pause")
	_click(_hud._pause_button.get_global_rect().get_center())
	_check(not _scene.is_paused, "pause button resumes flight")
	_scene._physics_process(0.1)
	_check(_scene.model.position.distance_to(position_before) > 1.0, "resumed simulation advances")
	_release_actions()


func _test_inventory_drag_and_resize() -> void:
	_reset_scene()
	if not _hud.inventory_items.is_visible_in_tree():
		_hud.toggle_inventory()
	var panel: Control = _hud.inventory_items
	panel.position = Vector2(20, 40)
	var point: Vector2 = panel.get_global_rect().position + Vector2(70, 10)
	_mouse_button(point, true)
	var motion: InputEventMouseMotion = InputEventMouseMotion.new()
	motion.position = point + Vector2(2000, 1500)
	motion.global_position = motion.position
	motion.relative = Vector2(2000, 1500)
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	root.push_input(motion, true)
	_mouse_button(motion.position, false)
	_check(panel.position != Vector2(20, 40), "dragging the title moves the frame")
	_check(_inside_viewport(panel), "dragging clamps the frame within the viewport")
	_check(not _scene.is_paused, "dragging a panel does not pause flight")
	await _test_layout(Vector2i(1024, 768))
	_check(panel.is_visible_in_tree() and _inside_viewport(panel), "open frame remains reachable after shrinking viewport")
	var grid: Control = panel.get_node_or_null("InventoryGrid") as Control
	var close_button: Button = panel.get_node_or_null("InventoryClose") as Button
	_check(grid != null and close_button != null, "inventory exposes its displayed grid and close button")
	if grid == null or close_button == null:
		return
	var last_cell: Vector2 = grid.get_global_rect().position + Vector2(9 * 32 + 15, 5 * 32 + 15)
	_click(last_cell)
	_check(grid.selected == 59, "clicking last displayed slot after drag and resize selects slot60")
	_check(_hud._inventory_hint.text.begins_with("ESPAÇO 60 VAZIO"), "slot click updates the local empty-space hint")
	_click(close_button.get_global_rect().get_center())
	_check(not panel.is_visible_in_tree() and not _hud.inventory_equipment.is_visible_in_tree(), "original close button hides the complete inventory")
	var dragged_position: Vector2 = panel.position
	_action_event("toggle_inventory")
	_check(panel.is_visible_in_tree() and panel.position == dragged_position, "reopening inventory preserves its last dragged and clamped origin")
	_click(close_button.get_global_rect().get_center())
	grid.selected = -1
	_click(last_cell)
	_check(grid.selected == -1, "a hidden inventory no longer intercepts clicks on its former slots")
	_check(not _scene.is_paused, "inventory close and empty-space clicks leave flight active")


func _inside_viewport(control: Control) -> bool:
	return Rect2(Vector2.ZERO, _hud.root.get_viewport_rect().size).grow(0.1).encloses(control.get_global_rect())


func _artwork_rect(parent: Control) -> Rect2:
	var bounds: Rect2 = Rect2()
	var found: bool = false
	for child: Node in parent.get_children():
		if child is TextureRect and child.is_visible_in_tree():
			bounds = bounds.merge(child.get_global_rect()) if found else child.get_global_rect()
			found = true
	return bounds


func _reset_scene() -> void:
	_release_actions()
	_hud._chat_input.release_focus()
	_scene._reset_flight()
	_scene._update_hud()


func _release_actions() -> void:
	for action: String in FLIGHT_ACTIONS:
		Input.action_release(action)


func _key(code: int, unicode_value: int) -> void:
	for pressed: bool in [true, false]:
		var event: InputEventKey = InputEventKey.new()
		event.keycode = code
		event.physical_keycode = code
		event.unicode = unicode_value
		event.pressed = pressed
		root.push_input(event, true)


func _action_event(action: String) -> void:
	var event: InputEventAction = InputEventAction.new()
	event.action = action
	event.pressed = true
	root.push_input(event, true)


func _click(point: Vector2) -> void:
	_mouse_button(point, true)
	_mouse_button(point, false)


func _mouse_button(point: Vector2, pressed: bool) -> void:
	var event: InputEventMouseButton = InputEventMouseButton.new()
	event.position = point
	event.global_position = point
	event.button_index = MOUSE_BUTTON_LEFT
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	event.pressed = pressed
	root.push_input(event, true)


func _check(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(label)


func _report() -> void:
	for failure: String in _failures:
		printerr(JSON.stringify({"suite": "legacy_ui", "failure": failure}))
	print(JSON.stringify({"suite": "legacy_ui", "status": "pass" if _failures.is_empty() else "fail", "checks": _checks, "failures": _failures.size()}))
	quit(0 if _failures.is_empty() else 1)


func _test_runtime_hud_bindings() -> void:
	_reset_scene()
	var combat: Dictionary = _scene.combat_runtime.snapshot()
	_check(bool(combat.get("available", false)), "original combat resources and rules support the live HUD")
	_scene._update_hud()
	_check(_hud._vital_labels[0].text == str(roundi(float(combat.get("hp", 0)))), "energy number reflects actual player HP")
	_check(_hud._vital_labels[2].text == str(roundi(float(combat.get("shield", 0)))), "shield number reflects actual combat shield")
	_check(_hud._ammo_labels[0].text == str(combat.get("primary_ammo", -1)) and _hud._ammo_labels[1].text == str(combat.get("secondary_ammo", -1)), "both ammunition counters reflect actual local loadout")
	_check(_hud._equipment_buttons["Motor"].tooltip_text.contains(str(_scene.model.engine_item_num)), "inventory engine tooltip identifies the selected original ITEM")
	_check(_hud._equipment_buttons["Arma primária"].tooltip_text.contains(str(combat.weapons.primary.item_num)), "inventory weapon tooltip follows the local native loadout")
	var skills: Dictionary = _hud._systems_state.get("skills", {})
	_check(_hud._vital_labels[4].text == str(roundi(float(skills.get("sp", 0)))) and _hud._vital_labels[5].text == str(roundi(float(skills.get("max_sp", 0)))) if float(skills.get("max_sp", 0)) > 0 else _hud._vital_labels[4].text == "—" and _hud._vital_labels[5].text == "—", "SP gauge follows real SkillModel state or stays unavailable without one")
	_scene.combat_runtime.model.damage_player(41.0, "ui_fixture")
	_scene._update_hud()
	var damaged: Dictionary = _scene.combat_runtime.snapshot()
	_check(float(damaged.shield) < float(combat.shield) and _hud._vital_labels[2].text == str(roundi(float(damaged.shield))), "combat damage updates shield instead of static preview art")
	_scene.combat_runtime.model.damage_player(float(damaged.hp) + float(damaged.shield) + 1.0, "ui_fixture")
	_scene._update_hud()
	_check(_hud._death_notice.is_visible_in_tree() and _hud._death_notice.text.contains("Reaparecendo"), "player death displays the local respawn timer")
	_reset_scene()
	_check(not _hud._death_notice.is_visible_in_tree(), "reset clears the actual death state and overlay")
