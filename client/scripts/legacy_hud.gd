class_name LegacyHUD
extends CanvasLayer
## Blue UI artwork and Group.tex layout from the official 2025 client.
## EP43 caller positions supply screen anchors; flight and all messages are local.

signal local_action_requested(action: String)

const GroupRenderer = preload("res://scripts/legacy_group.gd")
const OriginalAssetRenderer = preload("res://scripts/original_asset.gd")
const ASSET_DIR := "res://assets/legacy_ui/"
const TEXT := Color("e4eeee")
const CYAN := Color("8ad5f0")
const GOLD := Color("edcd80")
const EQUIP_SLOTS := [
	["Radar", Vector2(19, 111)], ["Computador", Vector2(329, 111)],
	["Arma primária", Vector2(19, 76)], ["Marca", Vector2(329, 41)],
	["Arma secundária", Vector2(329, 76)], ["Armadura", Vector2(19, 181)],
	["Motor", Vector2(329, 146)], ["Acessório", Vector2(19, 146)],
	["Acessório temporário", Vector2(329, 181)], ["Pet", Vector2(19, 41)],
]
const CHAT_CHANNELS := ["Todos", "Local", "Nação", "Troca", "Mapa", "Brigada", "Grupo", "Arena", "Sala"]
const ITEM_INDEX := "res://assets/original_library/catalogs/items_index.json"
const GEAR_INDEX := "res://assets/original_library/gears/gears.json"
const GEAR_UNIT_KINDS := {"12000100": 1, "12001100": 16, "12002100": 256, "12003100": 4096}
const LIBRARY_PAGE_SIZE := 8
const EQUIPPED_ROLES := {"Arma primária": "primary", "Arma secundária": "secondary", "Motor": "engine", "Armadura": "armor", "Computador": "cpu", "Radar": "radar", "Acessório": "accessory"}
const STAT_LABELS := {"attack": "Ataque", "defense": "Defesa", "fuel": "Combustível", "soul": "Espírito", "shield": "Escudo", "dodge": "Esquiva"}

var root: Control
var inventory_items: Control
var inventory_equipment: Control
var radar_frame: TextureRect
var quick_bar: TextureRect
var experience_background: TextureRect
var chat_filter := 0
var _paths: Dictionary = {}
var _textures: Dictionary = {}
var _groups: Dictionary = {}
var _gauge_root: Control
var _gauge_anchors: GroupRenderer
var _gauge_artwork: GroupRenderer
var _inventory_group: GroupRenderer
var _minimap_group: GroupRenderer
var _boost_gauge: TextureRect
var _speed_digits: Array[TextureRect] = []
var _speed_fallback: Label
var _altitude: Label
var _boost_value: Label
var _mode: Label
var _mission: Label
var _message: Label
var _pause: Label
var _altimeter: TextureRect
var _altimeter_pin: TextureRect
var _minimap_back: TextureRect
var _map_viewport_container: SubViewportContainer
var _map_viewport: SubViewport
var _map_camera: Camera3D
var _radar: RadarDisplay
var _radar_site: TextureRect
var _radar_player: TextureRect
var _quick_numbers: TextureRect
var _quick_page_up: TextureRect
var _quick_page_down: TextureRect
var _xp_fill: TextureRect
var _bottom_strip: TextureRect
var _chat_root: Control
var _chat_log: RichTextLabel
var _chat_input: LineEdit
var _chat_input_art: TextureRect
var _chat_filter_root: Control
var _chat_controls: Control
var _chat_filters: Array[Button] = []
var _chat_notes: Array[String] = []
var _system_root: Control
var _system_log: RichTextLabel
var _system_notes: Array[String] = []
var _reticle: TextureRect
var _preview_viewport: SubViewport
var _preview_model: Node3D
var _inventory_hint: Label
var _inventory_button: Button
var _pause_button: Button
var _local_notice: Label
var _menu_root: Control
var _xp_notice: Label
var _help_panel: Control
var _inventory_opened := false
var _last_size := Vector2.ZERO
var _last_speed := -1
var _last_boost_frame := -1
var _last_ring := -1
var _boundary_was_hit := false
var _vital_arcs: Dictionary = {}
var _vital_labels: Array[Label] = []
var _ammo_labels: Array[Label] = []
var _target_root: Control
var _target_marker: TextureRect
var _target_status: Label
var _interaction_prompt: Label
var _death_notice: Label
var _world_panel: PanelContainer
var _world_summary: Label
var _world_missions: VBoxContainer
var _world_maps: Label
var _world_signature := ""
var _world_state: Dictionary = {}
var _inventory_credits: Label
var _equipment_buttons: Dictionary = {}
var _equipment_descriptions: Dictionary = {}
var _library_tab := "missions"
var _library_tabs: Dictionary = {}
var _library_search: LineEdit
var _library_available: CheckBox
var _library_page := 0
var _library_page_label: Label
var _library_previous: Button
var _library_next: Button
var _library_reset_appearance: Button
var _library_map_records: Array = []
var _library_mission_records: Array = []
var _library_item_records: Array = []
var _library_gear_records: Array = []
var _library_filtered: Array = []
var _library_version := 0
var _item_index_loaded := false
var _gear_index_loaded := false
var _items_by_id: Dictionary = {}
var _inventory_state: Dictionary = {}
var _inventory_signature := ""
var _inventory_grid: EmptyGrid
var _inventory_icons: Control
var _inventory_page := 0
var _inventory_page_label: Label
var _inventory_equip: Button
var _inventory_previous: Button
var _inventory_next: Button
var _inventory_selected: Dictionary = {}
var _equipment_icons: Dictionary = {}
var _mission_details_panel: PanelContainer
var _mission_details_title: Label
var _mission_details_text: RichTextLabel
var _systems_state: Dictionary = {}
var _systems_signature := ""
var _systems_version := 0
var _systems_toolbar: HBoxContainer
var _systems_notice: Label
var _service_mode := "buy"
var _service_modes: Dictionary = {}
var _service_quantity: SpinBox
var _skill_slot: SpinBox
var _skill_buttons: Array[Button] = []
var _network_address: LineEdit
var _network_port: SpinBox
var _network_name: LineEdit
var _network_notes: Array[String] = []
var _service_offset := 0
var _network_form: Control
var _online_state: Dictionary = {}
var _online_signature := ""
var _online_url_draft := ""
var _online_url: LineEdit
var _online_token: LineEdit
var _online_connect: Button
var _online_disconnect: Button
var _online_status_label: Label
var _online_notes: Array[String] = []
var _world_heading: Label
const ONLINE_OFFLINE_ONLY := ["save_game", "load_game", "travel_map", "preview_gear", "reset_appearance", "equip_item", "unequip_item", "allocate_stat", "skill_use", "skill_learn", "skill_assign", "shop_buy", "shop_sell", "craft_recipe", "service_repair", "service_ammo", "accept_mission", "claim_reward", "pause", "reset"]
const ONLINE_LOCK_REASON := "A sessão online é controlada pelo servidor. Esta ação pertence ao perfil offline."


class RadarDisplay extends Control:
	var ship_position := Vector3.ZERO
	var heading := 0.0
	var points: Array[Vector3] = []
	var active := 0

	func _draw() -> void:
		var center := Vector2(59, 59)
		draw_circle(center, 57, Color(0.015, 0.045, 0.055, 0.88))
		draw_arc(center, 28, 0, TAU, 48, Color(0.2, 0.55, 0.61, 0.22), 1, true)
		draw_line(center + Vector2(-52, 0), center + Vector2(52, 0), Color(0.2, 0.55, 0.61, 0.2))
		draw_line(center + Vector2(0, -52), center + Vector2(0, 52), Color(0.2, 0.55, 0.61, 0.2))
		for index in range(active, points.size()):
			var delta_world: Vector3 = points[index] - ship_position
			var offset := Vector2(delta_world.x, delta_world.z).rotated(-heading) * (53.0 / 1000.0)
			if offset.length() <= 52.0:
				var color := Color("ffcf73") if index == active else Color("66c7cf")
				draw_circle(center + offset, 2.8 if index == active else 1.5, color)
		draw_colored_polygon(PackedVector2Array([center + Vector2(0, -4), center + Vector2(-3, 3), center + Vector2(3, 3)]), Color("e2f9ed"))


class DragPanel extends Control:
	var dragging := false

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed and event.position.y < 20:
				dragging = true
				get_parent().move_child(self, -1)
				accept_event()
			elif not event.pressed:
				dragging = false
		elif event is InputEventMouseMotion and dragging:
			position += event.relative
			var limit := get_viewport_rect().size - size
			position = position.clamp(Vector2.ZERO, limit.max(Vector2.ZERO))
			accept_event()


class EmptyGrid extends Control:
	signal cell_selected(index: int)
	var selected := -1

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			var column := int(event.position.x / 32.0)
			var row := int(event.position.y / 32.0)
			if column >= 0 and column < 10 and row >= 0 and row < 6:
				selected = row * 10 + column
				queue_redraw()
				cell_selected.emit(selected)
				accept_event()

	func _draw() -> void:
		if selected >= 0:
			var cell := Vector2(selected % 10, selected / 10) * 32.0
			draw_rect(Rect2(cell, Vector2(30, 30)), Color("cbe7ed"), false, 1)


func _ready() -> void:
	_read_asset_paths()
	var layout: Variant = JSON.parse_string(FileAccess.get_file_as_string(ASSET_DIR + "group_layout.json"))
	if layout is Dictionary:
		for group: Dictionary in layout.get("groups", []):
			_groups[str(group.get("name", ""))] = group
	root = Control.new()
	root.name = "OriginalInterface"
	if ResourceLoader.exists("res://assets/fonts/ACE-Korean.otf"):
		var latin := ThemeDB.fallback_font.duplicate() as Font
		var korean: Font = load("res://assets/fonts/ACE-Korean.otf")
		latin.fallbacks = [korean]
		var ui_theme := Theme.new()
		ui_theme.default_font = latin
		root.theme = ui_theme
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	_create_gauges()
	_create_radar()
	_create_quick_slots()
	_create_chat()
	_create_inventory()
	_create_annotations()
	_create_simulation_ui()
	_layout()
	root.resized.connect(_layout)
	append_local_note("Registro pessoal: mensagens permanecem apenas nesta sessão.")
	append_system_note("Prévia local · sem conexão com servidor.")
	append_system_note("F1: controles · Tab: alvo · M: mundo / missões.")


func _read_asset_paths() -> void:
	for manifest_name in ["manifest.json", ".manifest.json"]:
		var file_name: String = ASSET_DIR + manifest_name
		if FileAccess.file_exists(file_name):
			_register_manifest(JSON.parse_string(FileAccess.get_file_as_string(file_name)))
	var directory := DirAccess.open(ASSET_DIR)
	if directory:
		for file_name: String in directory.get_files():
			if file_name.get_extension().to_lower() in ["png", "tga", "dds", "webp", "jpg", "svg"]:
				_paths[file_name.get_basename().to_lower()] = ASSET_DIR + file_name


func _register_manifest(value: Variant, inherited_key: String = "") -> void:
	if value is Array:
		for item: Variant in value:
			_register_manifest(item)
	elif value is Dictionary:
		var key := str(value.get("key", value.get("name", value.get("id", inherited_key))))
		var path := str(value.get("path", value.get("file", value.get("output", ""))))
		if not key.is_empty() and not path.is_empty() and path.get_extension().to_lower() in ["png", "tga", "dds", "webp", "jpg", "svg"]:
			if not path.begins_with("res://"):
				path = ASSET_DIR + path.get_file()
			_paths[key.get_basename().to_lower()] = path
		for child_key: Variant in value:
			if value[child_key] is Array or value[child_key] is Dictionary:
				_register_manifest(value[child_key], str(child_key))
			elif value[child_key] is String and str(value[child_key]).get_extension().to_lower() in ["png", "tga", "dds", "webp", "jpg", "svg"]:
				var candidate: String = value[child_key]
				_paths[str(child_key).get_basename().to_lower()] = candidate if candidate.begins_with("res://") else ASSET_DIR + candidate.get_file()


func _texture(key: String) -> Texture2D:
	var normalized := key.to_lower()
	if _textures.has(normalized):
		return _textures[normalized]
	var texture: Texture2D = null
	if _paths.has(normalized) and ResourceLoader.exists(_paths[normalized]):
		texture = load(_paths[normalized]) as Texture2D
	_textures[normalized] = texture
	return texture


func _sprite(parent: Control, key: String, where: Vector2 = Vector2.ZERO) -> TextureRect:
	var sprite := TextureRect.new()
	sprite.name = key.validate_node_name()
	sprite.texture = _texture(key)
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	sprite.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sprite.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	sprite.position = where
	if sprite.texture:
		sprite.size = sprite.texture.get_size()
	parent.add_child(sprite)
	return sprite


func _text(parent: Control, value: String, where: Vector2, font_size: int = 11, color: Color = TEXT) -> Label:
	var label := Label.new()
	label.text = value
	label.position = where
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.95))
	label.add_theme_constant_override("shadow_offset_x", 1)
	label.add_theme_constant_override("shadow_offset_y", 1)
	parent.add_child(label)
	return label


func _transparent_button(parent: Control, title: String, where: Vector2, dimensions: Vector2, callback: Callable) -> Button:
	var button := Button.new()
	button.text = title
	button.position = where
	button.size = dimensions
	button.focus_mode = Control.FOCUS_NONE
	button.add_theme_font_size_override("font_size", 11)
	button.add_theme_color_override("font_color", TEXT)
	button.add_theme_color_override("font_hover_color", GOLD)
	button.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
	var hover := StyleBoxFlat.new()
	hover.bg_color = Color(0.1, 0.24, 0.32, 0.5)
	hover.border_color = Color(0.4, 0.7, 0.8, 0.6)
	hover.set_border_width_all(1)
	button.add_theme_stylebox_override("hover", hover)
	button.add_theme_stylebox_override("pressed", hover)
	button.pressed.connect(callback)
	parent.add_child(button)
	return button


func _build_group(parent: Control, key: String, node_name: String = "") -> GroupRenderer:
	var group := GroupRenderer.new()
	group.name = node_name if not node_name.is_empty() else key.validate_node_name()
	group.build(_groups.get(key, {}), _texture)
	parent.add_child(group)
	for error: String in group.build_errors:
		push_error("Legacy group %s: %s" % [key, error])
	return group


func _crop_sprite(parent: Control, key: String, region: Rect2, where: Vector2, dimensions: Vector2) -> TextureRect:
	var sprite := _sprite(parent, key, where)
	var source := _texture(key)
	if source:
		var atlas := AtlasTexture.new()
		atlas.atlas = source
		atlas.region = region
		atlas.filter_clip = true
		sprite.texture = atlas
	sprite.size = dimensions
	return sprite


func _art_button(parent: Control, key: String, where: Vector2, dimensions: Vector2, tooltip: String, callback: Callable, idle_scale: float = 1.0) -> Button:
	var art := _sprite(parent, key + "3", where)
	if art.texture == null:
		art.texture = _texture(key + "0")
	art.scale = Vector2.ONE * idle_scale
	var button := _transparent_button(parent, "", where, dimensions, callback)
	button.tooltip_text = tooltip
	button.add_theme_stylebox_override("hover", StyleBoxEmpty.new())
	button.add_theme_stylebox_override("pressed", StyleBoxEmpty.new())
	# EP43 ImageBtn idle=.8 for all six menus; origins keep their55px stride.
	# Hover grows to1 in1s; CENTER_BOTTOM uses image width for its Y offset.
	button.mouse_entered.connect(func() -> void:
		var texture := _texture(key + "0")
		if texture: art.texture = texture
		if idle_scale < 1.0:
			var tween := create_tween().set_parallel(true)
			button.set_meta("hover_tween", tween)
			tween.tween_property(art, "scale", Vector2.ONE, 1.0)
			var growth := art.size.x * (1.0 - idle_scale)
			tween.tween_property(art, "position", where - Vector2(growth / 2, growth), 1.0)
	)
	button.mouse_exited.connect(func() -> void:
		if button.has_meta("hover_tween"):
			var tween: Tween = button.get_meta("hover_tween")
			if tween and tween.is_valid(): tween.kill()
		var texture := _texture(key + "3")
		if texture: art.texture = texture
		art.scale = Vector2.ONE * idle_scale
		art.position = where
	)
	return button


func _create_gauges() -> void:
	_gauge_root = Control.new()
	_gauge_root.name = "FlightGauges"
	_gauge_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_gauge_root)
	_gauge_anchors = _build_group(_gauge_root, "Gage", "GaugeAnchors")
	_gauge_artwork = _build_group(_gauge_root, "MainGB", "MainGaugeArtwork")
	for layer: Array in [["ene19", "ene00"], ["she19", "she00"], ["skil19", "skil00"], ["fue16", "fue00"], ["fuelG00", "fuelG00"]]:
		var rectangle := _gauge_anchors.control_rect(layer[1])
		var arc := _sprite(_gauge_root, layer[0], rectangle.position)
		arc.size = rectangle.size
		_vital_arcs[str(layer[1])] = arc
	_boost_gauge = _sprite(_gauge_root, "Bost17", _gauge_anchors.control_rect("Bost00").position)
	_boost_gauge.size = _gauge_anchors.control_rect("Bost00").size
	# Numeric values follow the original text anchors; SP comes from SkillModel when present.
	for where: Vector2 in [Vector2(24, 87), Vector2(24, 97), Vector2(129, 87), Vector2(129, 97), Vector2(77, 67), Vector2(77, 77), Vector2(159, 69)]:
		_vital_labels.append(_text(_gauge_root, "—", where, 9))
	for anchor_name: String in ["firstweapon", "secondweapon"]:
		var anchor := _gauge_anchors.control_rect(anchor_name)
		_ammo_labels.append(_text(_gauge_root, "—", anchor.position + Vector2(17 if anchor_name == "firstweapon" else 11, 5), 13, CYAN))
	var atlas := _texture("speedm")
	for index in range(3):
		var digit := _sprite(_gauge_root, "speedm", Vector2(56 + 16 * index, 105))
		digit.size = Vector2(19, 17)
		digit.visible = atlas != null and atlas.get_width() >= 190
		_speed_digits.append(digit)
	_speed_fallback = _text(_gauge_root, "000", Vector2(56, 103), 17)
	_speed_fallback.visible = atlas == null or atlas.get_width() < 190
	# EP4 experience strip is one source pixel stretched across the window.
	experience_background = _sprite(root, "expbac")
	experience_background.size.y = 12
	_xp_fill = _sprite(root, "expbar")
	_xp_fill.visible = false
	_xp_notice = _text(root, "EXP —", Vector2.ZERO, 8)
	_bottom_strip = _sprite(root, "mnbtnBG")


func _create_radar() -> void:
	_minimap_back = _sprite(root, "mnMinibk")
	_minimap_back.visible = false # EP4 no longer draws this old upper backing.
	_radar = RadarDisplay.new()
	_radar.name = "LocalRadar"
	_radar.size = Vector2(118, 118)
	_radar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_radar)
	radar_frame = _sprite(root, "mmback")
	_radar_site = _sprite(root, "mmsite")
	_radar_player = _sprite(root, "mmaxis")
	_minimap_group = _build_group(root, "minimap", "MiniMapGroup")
	_map_viewport_container = SubViewportContainer.new()
	_map_viewport_container.name = "LocalTerrainMap"
	_map_viewport_container.size = Vector2(126, 126)
	_map_viewport_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_map_viewport_container)
	_map_viewport = SubViewport.new()
	_map_viewport.name = "TerrainMapViewport"
	_map_viewport.size = Vector2i(126, 126)
	_map_viewport.world_3d = get_viewport().world_3d
	_map_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_map_viewport_container.add_child(_map_viewport)
	_map_camera = Camera3D.new()
	_map_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_map_camera.cull_mask = 1 # Terrain/GEAR only; original sky uses render layer2.
	_map_camera.size = 1600
	_map_camera.far = 5000
	_map_viewport.add_child(_map_camera)
	_map_camera.current = true
	var marker := _sprite(_map_viewport_container, "mmaxis", Vector2(58, 58))
	marker.modulate = GOLD
	_altimeter = _sprite(root, "altig")
	_altimeter_pin = _sprite(root, "altip")
	_altitude = _text(root, "0 m", Vector2.ZERO, 9, CYAN)
	_altitude.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_altitude.size.x = 90
	_boost_value = _text(root, "", Vector2.ZERO, 9)
	_boost_value.visible = false # The original boost arc is driven by flight energy.


func _create_quick_slots() -> void:
	quick_bar = _sprite(root, "mnQSlot")
	quick_bar.tooltip_text = "Barra original · atalhos 1–8 usam as habilidades atribuídas no painel M."
	_quick_numbers = _sprite(root, "mnQSlotN")
	_quick_page_up = _sprite(root, "mnQup03")
	_quick_page_down = _sprite(root, "mnQdn03")
	_text(quick_bar, "1", Vector2(323, 7), 9)
	for index in range(8):
		var slot_number := index + 1
		var slot := Button.new()
		slot.name = "SkillHotbar%d" % slot_number
		slot.position = Vector2(32 * index, 0)
		slot.size = Vector2(30, 30)
		slot.flat = true
		slot.focus_mode = Control.FOCUS_NONE
		slot.disabled = true
		slot.text = str(slot_number)
		slot.add_theme_font_size_override("font_size", 9)
		slot.tooltip_text = "Atalho %d · vazio. Atribua uma habilidade em M." % slot_number
		slot.pressed.connect(func() -> void: _emit_local_action("skill_use:%d" % slot_number))
		quick_bar.add_child(slot)
		_skill_buttons.append(slot)


func _chat_frame(parent: Control, width: float, height: float, system: bool = false) -> void:
	# EP43 DrawChatWindow: 21px caps, cropped central artwork, 1px stretches.
	# width is the distance to the right cap, not total width.
	var left_cap := _sprite(parent, "c_c02" if system else "c_c00")
	left_cap.flip_h = system
	var source := _texture("c_c01")
	if source:
		var half := 119.0 # (default minimum280 - two21px caps)/2
		_crop_sprite(parent, "c_c01", Rect2(0, 0, half, 21), Vector2(21, 0), Vector2(half, 21))
		var right_edge := width - 21 if system else width
		_crop_sprite(parent, "c_c01", Rect2(half, 0, 1, 21), Vector2(21 + half, 0), Vector2(right_edge - 21 - 2 * half, 21))
		_crop_sprite(parent, "c_c01", Rect2(source.get_width() - half, 0, half, 21), Vector2(right_edge - half, 0), Vector2(half, 21))
	var right_cap := _sprite(parent, "c_c00" if system else "c_c02", Vector2(width - 21 if system else width, 0))
	right_cap.flip_h = system
	var left := _sprite(parent, "c_c10", Vector2(0, 21))
	left.size = Vector2(1, height - 21)
	var interior_width := width - 1 if system else width + 20
	_crop_sprite(parent, "c_c11", Rect2(0, 0, interior_width, height - 21), Vector2(1, 21), Vector2(interior_width, height - 21))
	var right := _sprite(parent, "c_c12", Vector2(width - 2 if system else width + 19, 21))
	right.size = Vector2(2, height - 21)
	_sprite(parent, "c_c20", Vector2(0, height))
	var bottom := _texture("c_c21")
	if bottom:
		_crop_sprite(parent, "c_c21", Rect2(0, 0, 119, 10), Vector2(21, height), Vector2(119, 10))
		var bottom_right := width - 21 if system else width
		_crop_sprite(parent, "c_c21", Rect2(119, 0, 1, 10), Vector2(140, height), Vector2(bottom_right - 259, 10))
		_crop_sprite(parent, "c_c21", Rect2(bottom.get_width() - 119, 0, 119, 10), Vector2(bottom_right - 119, height), Vector2(119, 10))
	_sprite(parent, "c_c22", Vector2(width - 21 if system else width, height))


func _new_log(parent: Control, where: Vector2, dimensions: Vector2, font_color: Color = TEXT) -> RichTextLabel:
	var log_label := RichTextLabel.new()
	log_label.position = where
	log_label.size = dimensions
	log_label.bbcode_enabled = false
	log_label.add_theme_font_size_override("normal_font_size", 11)
	log_label.add_theme_color_override("default_color", font_color)
	log_label.add_theme_constant_override("line_separation", 1)
	log_label.scroll_following = true
	log_label.selection_enabled = true
	parent.add_child(log_label)
	return log_label


func _create_chat() -> void:
	_chat_root = Control.new()
	_chat_root.name = "LocalChat"
	_chat_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_chat_root)
	_chat_frame(_chat_root, 318, 120)
	_sprite(_chat_root, "Chatmage", Vector2(1, -4))
	_chat_log = _new_log(_chat_root, Vector2(8, 24), Vector2(319, 91))
	_chat_filter_root = Control.new()
	_chat_filter_root.name = "ChatFilters"
	_chat_filter_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_chat_filter_root)
	for index in range(CHAT_CHANNELS.size()):
		var icon := _sprite(_chat_filter_root, "cicon_li%d3" % (index + 1), Vector2(index * 37, 0))
		var filter_button := _transparent_button(_chat_filter_root, "", Vector2(index * 37, 0), Vector2(27, 21), set_chat_filter.bind(index))
		filter_button.name = "ChatFilter%d" % index
		filter_button.tooltip_text = "%s · %s" % [CHAT_CHANNELS[index], "notas locais" if index <= 1 else "canal sem conexão"]
		filter_button.set_meta("art", icon)
		filter_button.disabled = index >= 7
		_chat_filters.append(filter_button)
	_chat_input_art = _sprite(root, "c_nbar")
	_chat_input = LineEdit.new()
	_chat_input.name = "LocalChatInput"
	_chat_input.size = Vector2(240, 20)
	_chat_input.placeholder_text = "Nota local… Enter para registrar"
	_chat_input.max_length = 120
	_chat_input.add_theme_font_size_override("font_size", 11)
	_chat_input.add_theme_color_override("font_color", TEXT)
	_chat_input.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
	_chat_input.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	_chat_input.text_submitted.connect(func(value: String) -> void:
		if not value.strip_edges().is_empty():
			if is_online_connected():
				_request_online({"action": "chat", "text": value.strip_edges()})
			elif bool((_systems_state.get("network", {}) as Dictionary).get("connected", false)):
				_request_network({"action": "chat", "text": value.strip_edges()})
			else:
				append_local_note(value.strip_edges())
			set_chat_filter(1)
		_chat_input.clear()
		_chat_input.release_focus()
	)
	_chat_input.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
			_chat_input.release_focus()
	)
	root.add_child(_chat_input)
	_chat_input.reset_size()
	_chat_input.size = Vector2(240, 20)
	_chat_controls = Control.new()
	_chat_controls.name = "ChatInputControls"
	_chat_controls.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_chat_controls)
	var local_mode := _sprite(_chat_controls, "c_nme0", Vector2(1, 0))
	local_mode.mouse_filter = Control.MOUSE_FILTER_PASS
	local_mode.tooltip_text = "Modo local · nenhuma mensagem é enviada a outros jogadores."
	_art_button(_chat_controls, "copticon", Vector2(309, 0), Vector2(21, 21), "Ajuda da prévia local [F1]", toggle_help)
	_sprite(_chat_controls, "c_hsbtn10", Vector2(331, 0))
	_transparent_button(_chat_controls, "", Vector2(331, 0), Vector2(13, 23), func() -> void: _chat_root.visible = not _chat_root.visible).tooltip_text = "Mostrar / ocultar registro local"
	_system_root = Control.new()
	_system_root.name = "LocalSystemMessages"
	_system_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_system_root)
	_chat_frame(_system_root, 335, 120, true)
	var system_title := _sprite(_system_root, "sysbar", Vector2(5, -4))
	if system_title.texture == null:
		_text(_system_root, "SISTEMA", Vector2(8, 2), 10)
	_system_log = _new_log(_system_root, Vector2(8, 24), Vector2(319, 91), GOLD)
	var minimize := _sprite(_system_root, "w_wMin", Vector2(304, 3))
	minimize.mouse_filter = Control.MOUSE_FILTER_PASS
	minimize.tooltip_text = "Registro de eventos da sessão local"
	_sprite(_system_root, "close", Vector2(317, 3))
	_transparent_button(_system_root, "", Vector2(317, 3), Vector2(17, 17), func() -> void: _system_root.hide()).tooltip_text = "Ocultar registro · a próxima mensagem local reabre a janela"
	set_chat_filter(0)


func set_chat_filter(index: int) -> void:
	chat_filter = clampi(index, 0, CHAT_CHANNELS.size() - 1)
	for i in range(_chat_filters.size()):
		var art: TextureRect = _chat_filters[i].get_meta("art")
		art.texture = _texture("cicon_li%d%d" % [i + 1, 0 if i == chat_filter else 3])
	if is_instance_valid(_chat_log):
		var connected := bool((_systems_state.get("network", {}) as Dictionary).get("connected", false))
		_chat_log.text = "\n".join(_online_notes if is_online_connected() else (_network_notes if connected else _chat_notes)) if chat_filter <= 1 else "Canal sem conexão. Use Local para notas ou chat da sessão conectada."


func _create_inventory() -> void:
	inventory_items = DragPanel.new()
	inventory_items.name = "InventoryItems"
	inventory_items.z_index = 10
	inventory_items.position = Vector2.ZERO
	root.add_child(inventory_items)
	_inventory_group = _build_group(inventory_items, "inven", "InventoryGroup")
	inventory_items.size = _inventory_group.image_bounds.size
	# The frame is the shipped 'inven' group; tc_inven belongs to Trade Center.
	inventory_equipment = Control.new()
	inventory_equipment.name = "InventoryEquipment"
	inventory_equipment.size = inventory_items.size
	inventory_equipment.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inventory_items.add_child(inventory_equipment)
	var preview_container := SubViewportContainer.new()
	preview_container.name = "LocalGearPreview"
	preview_container.position = Vector2(56, 36)
	preview_container.size = Vector2(266, 177)
	preview_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inventory_equipment.add_child(preview_container)
	_preview_viewport = SubViewport.new()
	_preview_viewport.size = Vector2i(266, 177)
	_preview_viewport.own_world_3d = true
	_preview_viewport.transparent_bg = true
	_preview_viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	preview_container.add_child(_preview_viewport)
	for slot: Array in EQUIP_SLOTS:
		var role: String = slot[0]
		var button := _transparent_button(inventory_equipment, "", slot[1], Vector2(30, 30), func() -> void:
			append_system_note(str(_equipment_descriptions.get(role, "%s: nenhum item de conta; equipamento não recuperado para esta sessão." % role)))
		)
		button.tooltip_text = "%s · sem item de conta" % role
		_equipment_buttons[role] = button
		var icon := TextureRect.new()
		icon.position = Vector2.ONE
		icon.size = Vector2(28, 28)
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		button.add_child(icon)
		_equipment_icons[role] = icon
	_inventory_grid = EmptyGrid.new()
	_inventory_grid.name = "InventoryGrid"
	_inventory_grid.position = Vector2(25, 254)
	_inventory_grid.size = Vector2(320, 192)
	_inventory_grid.tooltip_text = "Itens possuídos na sessão local; selecione para consultar ou equipar."
	inventory_items.add_child(_inventory_grid)
	_inventory_icons = Control.new()
	_inventory_icons.name = "OwnedItemIcons"
	_inventory_icons.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_inventory_grid.add_child(_inventory_icons)
	_inventory_hint = _text(inventory_items, "SESSÃO LOCAL · SEM ITENS CARREGADOS", Vector2(64, 216), 9, CYAN)
	_inventory_hint.size.x = 280
	_inventory_hint.clip_text = true
	_inventory_grid.cell_selected.connect(_select_inventory_cell)
	_inventory_equip = _transparent_button(inventory_items, "Equipar seleção", Vector2(25, 232), Vector2(154, 18), _equip_inventory_selection)
	_inventory_equip.disabled = true
	_inventory_equip.add_theme_font_size_override("font_size", 10)
	_inventory_previous = _transparent_button(inventory_items, "‹", Vector2(241, 232), Vector2(21, 18), func() -> void: _change_inventory_page(-1))
	_inventory_page_label = _text(inventory_items, "1 / 1", Vector2(264, 234), 9, CYAN)
	_inventory_next = _transparent_button(inventory_items, "›", Vector2(322, 232), Vector2(21, 18), func() -> void: _change_inventory_page(1))
	_inventory_credits = _text(inventory_items, "—", Vector2(132, 458), 10)
	_inventory_credits.tooltip_text = "Créditos do perfil local. F5 salva e F9 carrega o progresso neste computador."
	_text(inventory_items, "—", Vector2(276, 458), 10)
	_sprite(inventory_items, "close", Vector2(361, 6))
	var close_button := _transparent_button(inventory_items, "", Vector2(361, 6), Vector2(17, 17), func() -> void: inventory_items.hide())
	close_button.name = "InventoryClose"
	close_button.tooltip_text = "Fechar inventário [I]"
	inventory_items.hide()


func set_gear_preview(visual: Node3D) -> void:
	if not is_instance_valid(_preview_viewport):
		return
	for previous: Node in _preview_viewport.get_children():
		_preview_viewport.remove_child(previous)
		previous.queue_free()
	_preview_model = visual.duplicate() as Node3D
	_preview_model.position = Vector3.ZERO
	_preview_model.rotation = Vector3(0, 0.35, 0)
	_preview_viewport.add_child(_preview_model)
	if visual.has_meta("preview_label"):
		_inventory_hint.text = str(visual.get_meta("preview_label"))
	if visual.has_meta("scene_provenance"):
		_mode.tooltip_text = str(visual.get_meta("scene_provenance"))
	var camera := Camera3D.new()
	var bounds: AABB = visual.get_meta("visual_bounds", AABB(Vector3(-7, -1, -5), Vector3(14, 3, 10)))
	var framing: Dictionary = OriginalAssetRenderer.preview_camera(bounds, Vector2(_preview_viewport.size), _preview_model.quaternion)
	camera.position = framing.position
	camera.fov = framing.fov
	camera.far = framing.far
	_preview_viewport.add_child(camera)
	camera.look_at(framing.target)
	camera.current = true
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-40, -25, 0)
	light.light_energy = 2.0
	_preview_viewport.add_child(light)
	var environment := WorldEnvironment.new()
	var settings := Environment.new()
	settings.background_mode = Environment.BG_COLOR
	settings.background_color = Color(0.02, 0.06, 0.08, 0)
	settings.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	settings.ambient_light_color = Color("93b0ba")
	settings.ambient_light_energy = 0.8
	environment.environment = settings
	_preview_viewport.add_child(environment)


func set_inventory_state(data: Dictionary) -> void:
	_inventory_state = data
	var signature := JSON.stringify([data.get("entries", []), data.get("equipped", {})])
	if signature != _inventory_signature:
		_inventory_signature = signature
		_refresh_inventory()


func _refresh_inventory() -> void:
	if not is_instance_valid(_inventory_icons):
		return
	for child: Node in _inventory_icons.get_children():
		_inventory_icons.remove_child(child)
		child.queue_free()
	var entries: Array = _inventory_state.get("entries", [])
	var page_count := maxi(1, ceili(entries.size() / 60.0))
	_inventory_page = clampi(_inventory_page, 0, page_count - 1)
	_inventory_page_label.text = "%d / %d" % [_inventory_page + 1, page_count]
	_inventory_previous.disabled = _inventory_page == 0
	_inventory_next.disabled = _inventory_page >= page_count - 1
	for index: int in range(_inventory_page * 60, mini(entries.size(), (_inventory_page + 1) * 60)):
		var item: Dictionary = entries[index]
		var cell := index % 60
		var button := Button.new()
		button.name = "OwnedItem_%s" % _item_id(item)
		button.position = Vector2(cell % 10, cell / 10) * 32
		button.size = Vector2(30, 30)
		button.flat = true
		button.focus_mode = Control.FOCUS_NONE
		button.tooltip_text = _item_tooltip(item, true)
		button.icon = _item_texture(item)
		button.expand_icon = true
		if button.icon == null:
			button.text = str(item.get("kind", "?" )).left(2)
			button.add_theme_font_size_override("font_size", 9)
		button.pressed.connect(func() -> void: _select_inventory_cell(cell))
		_inventory_icons.add_child(button)
		var count := int(item.get("count", 1))
		if count > 1:
			var quantity := _text(button, str(count), Vector2(0, 16), 9, Color.WHITE)
			quantity.size = Vector2(29, 13)
			quantity.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	var equipped: Dictionary = _inventory_state.get("equipped", {})
	for role: String in EQUIPPED_ROLES:
		var selected := int(equipped.get(EQUIPPED_ROLES[role], 0))
		var owned: Dictionary = {}
		for value: Dictionary in entries:
			if int(_item_id(value)) == selected:
				owned = value
				break
		(_equipment_icons[role] as TextureRect).texture = _item_texture(owned)
		if not owned.is_empty():
			_equipment_descriptions[role] = "%s · equipado\n%s" % [role, _item_tooltip(owned, true)]
			(_equipment_buttons[role] as Button).tooltip_text = _equipment_descriptions[role]
	if _inventory_selected.is_empty():
		_inventory_equip.disabled = true


func _select_inventory_cell(cell: int) -> void:
	_inventory_grid.selected = cell
	_inventory_grid.queue_redraw()
	var entries: Array = _inventory_state.get("entries", [])
	var index := _inventory_page * 60 + cell
	_inventory_selected = entries[index] if index >= 0 and index < entries.size() else {}
	if _inventory_selected.is_empty():
		_inventory_hint.text = "ESPAÇO %02d VAZIO · PERFIL LOCAL" % (cell + 1)
		_inventory_equip.disabled = true
		return
	_inventory_hint.text = _item_name(_inventory_selected)
	_inventory_hint.tooltip_text = _item_tooltip(_inventory_selected, true)
	var slots: Array = _inventory_selected.get("equippable_slots", [])
	_inventory_equip.disabled = slots.is_empty() or is_online_connected()
	_inventory_equip.text = "Equipar seleção" if not slots.is_empty() else "Item sem encaixe"
	_inventory_equip.tooltip_text = "Equipa apenas itens possuídos; classe, nível, atributos e encaixe são conferidos pelo perfil local."
	if slots.is_empty():
		var errors: Dictionary = _inventory_selected.get("equip_errors", {})
		var reasons := PackedStringArray()
		for value: Dictionary in errors.values():
			var code := str(value.get("error", ""))
			var descriptions := {"wrong_gear_class": "Item de outra classe de GEAR.", "insufficient_level": "Nível insuficiente.", "level_too_high": "Nível acima do limite do item.", "native_stat_requirement": "Atributos insuficientes para este equipamento.", "native_equipment_parameter_not_ported": "Um bônus deste equipamento ainda não é suportado.", "native_equipment_parameters_unavailable": "Parâmetros originais deste equipamento indisponíveis.", "other_equipment_stat_requirement": "A mudança invalidaria os requisitos de outro equipamento."}
			reasons.append(str(value.get("reason", descriptions.get(code, "Os requisitos deste equipamento ainda não foram atendidos."))))
		if not reasons.is_empty(): _inventory_equip.tooltip_text = "\n".join(reasons)


func _equip_inventory_selection() -> void:
	if is_online_connected(): return
	var slots: Array = _inventory_selected.get("equippable_slots", [])
	if not slots.is_empty() and int(_inventory_selected.get("count", 0)) > 0:
		_emit_local_action("equip_item:%s:%s" % [str(slots[0]), _item_id(_inventory_selected)])


func _change_inventory_page(direction: int) -> void:
	var entries: Array = _inventory_state.get("entries", [])
	_inventory_page = clampi(_inventory_page + direction, 0, maxi(0, ceili(entries.size() / 60.0) - 1))
	_inventory_selected = {}
	_inventory_grid.selected = -1
	_refresh_inventory()


func _item_id(item: Dictionary) -> String:
	return str(int(item.get("item_num", item.get("ItemNum", 0))))


func _item_name(item: Dictionary) -> String:
	return str(item.get("name", item.get("ItemName", "Item original")))


func _item_texture(item: Dictionary) -> Texture2D:
	var path := str(item.get("icon_path", ""))
	if path.is_empty() and _items_by_id.has(_item_id(item)):
		path = str((_items_by_id[_item_id(item)] as Dictionary).get("icon_path", ""))
	if not path.is_empty() and ResourceLoader.exists(path):
		if not _textures.has(path):
			_textures[path] = load(path) as Texture2D
		return _textures[path] as Texture2D
	return null


func _item_tooltip(item: Dictionary, owned: bool = false) -> String:
	var lines := PackedStringArray(["%s · ITEM %s" % [_item_name(item), _item_id(item)]])
	lines.append("%s · nível %s–%s · posição %s" % [str(item.get("kind", item.get("Kind", "—"))), str(int(item.get("min_level", item.get("ReqMinLevel", 0)))), str(int(item.get("max_level", item.get("ReqMaxLevel", 0)))), str(item.get("position", item.get("Position", "—")))])
	var required: Dictionary = item.get("required_stats", item.get("ReqGearStat", {}))
	for stat: String in STAT_LABELS:
		var value := int(required.get(stat, 0))
		if value > 0: lines.append("Requer %s: %d" % [STAT_LABELS[stat], value])
	var stats: Dictionary = item.get("stats", {})
	for definition: Array in [["minimum", "Dano mínimo"], ["maximum", "Dano máximo"], ["range", "Alcance"], ["price", "Preço dos dados"]]:
		if stats.has(definition[0]):
			lines.append("%s: %s" % [definition[1], str(stats[definition[0]])])
	if item.has("Price"):
		lines.append("Preço dos dados: %s · máscara GEAR: %s" % [str(item.Price), str(item.get("ReqUnitKind", "—"))])
	var source: Variant = item.get("source", "perfil local")
	var source_label := "registro ITEM original · perfil local" if source is Dictionary else str(source)
	lines.append("Possuído ×%d · %s" % [int(item.get("count", 0)), source_label] if owned else "Catálogo do cliente original · não representa posse ou loja.")
	return "\n".join(lines)


func _create_annotations() -> void:
	_mode = _text(root, "PRÉVIA LOCAL · F1 AJUDA", Vector2.ZERO, 10, GOLD)
	_mode.mouse_filter = Control.MOUSE_FILTER_PASS
	_mode.tooltip_text = "Recursos e regras originais convertidos; simulação, serviços e progressão locais. Rede LAN opcional compartilha presença e chat; combate e recompensas individuais."
	_mission = _text(root, "", Vector2.ZERO, 10, CYAN)
	_mission.visible = false
	_message = _text(root, "", Vector2.ZERO, 12, GOLD)
	_message.visible = false
	_pause = _text(root, "VOO PAUSADO\nP para continuar", Vector2.ZERO, 24)
	_pause.z_index = 20
	_pause.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_pause.visible = false
	_local_notice = _text(root, "", Vector2.ZERO, 10)
	_local_notice.visible = false
	_menu_root = Control.new()
	_menu_root.name = "MainMenuIcons"
	_menu_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_menu_root)
	_art_button(_menu_root, "op_faq", Vector2.ZERO, Vector2(44, 40.8), "Controles locais [F1]", toggle_help, 0.8)
	for index in range(5):
		var position := Vector2(55 + index * 55, 0)
		if index == 0:
			_inventory_button = _art_button(_menu_root, "mnbtn%d" % index, position, Vector2(44, 40.8), "Inventário local [I]", toggle_inventory, 0.8)
		elif index == 4:
			_pause_button = _art_button(_menu_root, "mnbtn%d" % index, position, Vector2(44, 40.8), "Pausar / continuar voo local [P]", func() -> void: _emit_local_action("pause"), 0.8)
		elif index == 1:
			_art_button(_menu_root, "mnbtn%d" % index, position, Vector2(44, 40.8), "Mapa e missões locais [M]", toggle_world_panel, 0.8)
		else:
			var label: String = ["", "Informações", "Comunidade", "Comércio"][index]
			_art_button(_menu_root, "mnbtn%d" % index, position, Vector2(44, 40.8), "%s · indisponível na prévia local" % label, func() -> void: append_system_note("%s: recurso online indisponível na prévia local." % label), 0.8)
	_reticle = _sprite(root, "t_center0")
	if _reticle.texture == null:
		_reticle.texture = _texture("t_n_blue")
		if _reticle.texture: _reticle.size = _reticle.texture.get_size()
	_reticle.modulate.a = 0.85
	_help_panel = PanelContainer.new()
	_help_panel.name = "LocalControlsHelp"
	_help_panel.z_index = 20
	_help_panel.size = Vector2(510, 400)
	var background := StyleBoxFlat.new()
	background.bg_color = Color(0.02, 0.07, 0.12, 0.95)
	background.border_color = Color("458cc1")
	background.set_border_width_all(1)
	background.content_margin_left = 20
	background.content_margin_top = 16
	background.content_margin_right = 20
	background.content_margin_bottom = 16
	_help_panel.add_theme_stylebox_override("panel", background)
	root.add_child(_help_panel)
	_text(_help_panel, "CONTROLES · SESSÃO LOCAL\n\nW / S       Inclinar; A-GEAR no solo: frente / ré\nA / D        Deslocamento lateral / inclinação visual\nQ / E        Virar; E próximo de contato: interagir\nShift         Boost      ·      Espaço   Frear\nMouse         Mirar · botões 1 / 2: armas\nTab           Selecionar alvo / travar míssil\nG               Pousar próximo do solo / decolar\nT                Cerco A-GEAR no solo\nM              Mundo e missões locais\nI                 Inventário     ·     F2   Alternar GEAR\nP               Pausar     ·     R   Reiniciar encontro\n\nF1 fecha a ajuda. Chat registra notas pessoais.\nSem servidor ou conta; cenário de combate adaptado.", Vector2.ZERO, 13)
	_help_panel.hide()


func _layout() -> void:
	if not is_instance_valid(root) or not is_instance_valid(_mode):
		return
	var viewport_size := root.get_viewport_rect().size
	_last_size = viewport_size
	experience_background.position = Vector2(0, viewport_size.y - 12)
	experience_background.size.x = viewport_size.x
	_xp_notice.position = Vector2(floorf(viewport_size.x / 2 - 15), viewport_size.y - 14)
	_bottom_strip.position = Vector2(viewport_size.x - 335, viewport_size.y - 53)
	_bottom_strip.size = Vector2(335, 40)
	# Modern radar placement from EP43 BACK_START_X/Y and actual native sizes.
	radar_frame.position = Vector2(viewport_size.x - 189, 24)
	_radar.position = radar_frame.position + Vector2(24, 24)
	_radar_site.position = Vector2(radar_frame.position.x + (radar_frame.size.x - _radar_site.size.x) / 2, 49)
	_radar_player.position = radar_frame.position + (radar_frame.size - _radar_player.size) / 2
	_minimap_group.position = Vector2(viewport_size.x - 177, 186)
	_map_viewport_container.position = _minimap_group.position + Vector2(7, 7)
	_altimeter.position = Vector2(viewport_size.x - 32, 188)
	_altimeter_pin.position.x = _altimeter.position.x - (_altimeter_pin.size.x - _altimeter.size.x) / 2
	_altitude.position = Vector2(viewport_size.x - 127, 326)
	# EP43 QSlot caller:336+(W−1001)/2,H−57 (C++ truncates integer division).
	var bar_position := Vector2(336 + int((viewport_size.x - 1001) / 2), viewport_size.y - 57)
	quick_bar.position = bar_position
	_quick_numbers.position = bar_position
	_quick_page_up.position = bar_position + Vector2(325, 12)
	_quick_page_down.position = bar_position + Vector2(322, 23)
	_chat_root.position = Vector2(0, viewport_size.y - 180)
	_chat_filter_root.position = Vector2(2, viewport_size.y - 54)
	_chat_input_art.position = Vector2(2, viewport_size.y - 34)
	_chat_controls.position = Vector2(0, viewport_size.y - 34)
	_chat_input.size = Vector2(240, 20)
	_chat_input.position = Vector2(52, minf(viewport_size.y - 34, viewport_size.y - _chat_input.size.y - 12))
	_system_root.position = Vector2(viewport_size.x - 335, viewport_size.y - 183)
	_mode.position = Vector2(258, 4)
	_pause.position = Vector2(viewport_size.x / 2 - 190, viewport_size.y / 2 - 40)
	_pause.size.x = 380
	_menu_root.position = Vector2(viewport_size.x - 330, viewport_size.y - 53)
	_reticle.position = (viewport_size - _reticle.size) / 2
	_help_panel.position = (viewport_size - _help_panel.size) / 2
	if is_instance_valid(_world_panel):
		_world_panel.size = Vector2(minf(760, viewport_size.x - 32), minf(540, viewport_size.y - 32))
		_world_panel.position = (viewport_size - _world_panel.size) / 2
	if is_instance_valid(_mission_details_panel):
		_mission_details_panel.size = Vector2(minf(710, viewport_size.x - 48), minf(510, viewport_size.y - 48))
		_mission_details_panel.position = (viewport_size - _mission_details_panel.size) / 2
	if is_instance_valid(_interaction_prompt):
		_interaction_prompt.position = Vector2(260, 29)
		_death_notice.position = Vector2(viewport_size.x / 2 - 220, viewport_size.y / 2 - 60)
		_death_notice.size.x = 440
	inventory_items.position = inventory_items.position.clamp(Vector2.ZERO, (viewport_size - inventory_items.size).max(Vector2.ZERO))


func toggle_inventory() -> void:
	inventory_items.visible = not inventory_items.visible
	if inventory_items.visible:
		if not _inventory_opened:
			# Active EP4 caller centers the unified window, then retains dragging.
			var dimensions := root.get_viewport_rect().size
			inventory_items.position = Vector2(floorf(dimensions.x / 2) - floorf(inventory_items.size.x / 2), floorf(dimensions.y / 2) - floorf(inventory_items.size.y / 2))
			_inventory_opened = true
		_layout()
		_refresh_inventory()


func toggle_equipment() -> void:
	# The modern inventory is one window; its equipment section stays integrated.
	inventory_equipment.visible = inventory_items.visible


func toggle_help() -> void:
	_help_panel.visible = not _help_panel.visible


func _unhandled_key_input(event: InputEvent) -> void:
	if wants_keyboard():
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F1:
		toggle_help()
		get_viewport().set_input_as_handled()


func wants_keyboard() -> bool:
	var owner := root.get_viewport().gui_get_focus_owner() if is_instance_valid(root) else null
	return is_instance_valid(owner) and (owner is LineEdit or owner is TextEdit or owner is SpinBox)


func append_local_note(note: String) -> void:
	_chat_notes.append("Local › " + note)
	if _chat_notes.size() > 30:
		_chat_notes.pop_front()
	if is_instance_valid(_chat_log):
		set_chat_filter(chat_filter)


func append_system_note(note: String) -> void:
	_system_notes.append(note)
	if _system_notes.size() > 30:
		_system_notes.pop_front()
	if is_instance_valid(_system_log):
		_system_root.show()
		_system_log.text = "\n".join(_system_notes)


func update_flight(state: RefCounted, ring_points: Array[Vector3], current_ring: int, paused: bool, _flash: float) -> void:
	var speed := clampi(roundi(absf(state.speed)), 0, 999)
	if speed != _last_speed:
		_last_speed = speed
		var digits := "%03d" % speed
		_speed_fallback.text = digits
		var atlas := _texture("speedm")
		if atlas and atlas.get_width() >= 190:
			for index in range(3):
				var digit := AtlasTexture.new()
				digit.atlas = atlas
				digit.region = Rect2(int(digits[index]) * 19, 0, 19, 17)
				_speed_digits[index].texture = digit
	var boost_frame := clampi(int(state.boost_energy * 18.0), 0, 17)
	if boost_frame != _last_boost_frame:
		_last_boost_frame = boost_frame
		_boost_gauge.texture = _texture("Bost%02d" % boost_frame)
	_altitude.text = "%d u" % roundi(state.position.y)
	# Only this local model's altitude is represented, normalized to its ceiling.
	var travel := maxf(0, _altimeter.size.y - 14)
	_altimeter_pin.position.y = _altimeter.position.y + travel * (1.0 - clampf((state.position.y - state.bounds_min.y) / (state.bounds_max.y - state.bounds_min.y), 0, 1))
	_pause.visible = paused
	if current_ring != _last_ring:
		_last_ring = current_ring
		append_system_note("Treino: anéis %02d / %02d%s" % [current_ring, ring_points.size(), " · concluído" if current_ring >= ring_points.size() else ""])
	if state.boundary_hit and not _boundary_was_hit:
		append_system_note("Limite do campo. Vire ou pressione R para reiniciar.")
	_boundary_was_hit = state.boundary_hit
	_radar.ship_position = state.position
	var direction: Vector3 = state.forward()
	_radar.heading = atan2(direction.x, -direction.z)
	_radar.points = ring_points
	_radar.active = current_ring
	_radar.queue_redraw()
	_map_camera.position = state.position + Vector3(0, 1800, 0)
	_map_camera.look_at(state.position, Vector3(0, 0, -1))
	if root.get_viewport_rect().size != _last_size:
		_layout()


func _create_simulation_ui() -> void:
	_target_root = Control.new()
	_target_root.name = "CombatTarget"
	_target_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_target_root)
	_target_marker = _sprite(_target_root, "qtarget")
	_target_status = _text(_target_root, "", Vector2(0, 62), 11, GOLD)
	_target_root.hide()
	_interaction_prompt = _text(root, "", Vector2.ZERO, 11, GOLD)
	_death_notice = _text(root, "", Vector2.ZERO, 24, GOLD)
	_death_notice.z_index = 25
	_death_notice.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_death_notice.hide()
	_world_panel = PanelContainer.new()
	_world_panel.name = "LocalWorldPanel"
	_world_panel.z_index = 15
	_world_panel.size = Vector2(760, 540)
	var skin := StyleBoxFlat.new()
	skin.bg_color = Color(0.015, 0.055, 0.09, 0.97)
	skin.border_color = Color("458cc1")
	skin.set_border_width_all(1)
	_world_panel.add_theme_stylebox_override("panel", skin)
	root.add_child(_world_panel)
	# A separate local panel preserves the source inventory and HUD geometry.
	var content := VBoxContainer.new()
	content.name = "WorldContent"
	content.add_theme_constant_override("separation", 6)
	var margins := MarginContainer.new()
	margins.add_theme_constant_override("margin_left", 12)
	margins.add_theme_constant_override("margin_right", 12)
	margins.add_theme_constant_override("margin_top", 12)
	margins.add_theme_constant_override("margin_bottom", 12)
	_world_panel.add_child(margins)
	margins.add_child(content)
	var heading := HBoxContainer.new()
	content.add_child(heading)
	var title := Label.new()
	title.text = "MUNDO E BIBLIOTECA · SESSÃO LOCAL"
	_world_heading = title
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_font_size_override("font_size", 15)
	heading.add_child(title)
	var close := Button.new()
	close.name = "WorldClose"
	close.text = "Fechar [M]"
	close.focus_mode = Control.FOCUS_NONE
	close.pressed.connect(toggle_world_panel)
	heading.add_child(close)
	_world_summary = Label.new()
	_world_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_world_summary.max_lines_visible = 2
	_world_summary.clip_text = true
	_world_summary.custom_minimum_size.y = 34
	_world_summary.add_theme_font_size_override("font_size", 12)
	content.add_child(_world_summary)
	var tabs := HBoxContainer.new()
	content.add_child(tabs)
	for definition: Array in [["missions", "Missões"], ["maps", "Mapas"], ["items", "Itens originais"], ["gears", "Aparências"], ["online", "Online PvE"]]:
		var tab := Button.new()
		var key: String = definition[0]
		tab.text = definition[1]
		tab.focus_mode = Control.FOCUS_NONE
		tab.toggle_mode = true
		tab.pressed.connect(func() -> void: _select_library_tab(key))
		tabs.add_child(tab)
		_library_tabs[key] = tab
	var system_tabs := HBoxContainer.new()
	content.add_child(system_tabs)
	for definition: Array in [["services", "Serviços"], ["skills", "Habilidades"], ["equipment", "Atributos"], ["network", "Rede LAN"]]:
		var key := str(definition[0])
		var tab := Button.new()
		tab.text = str(definition[1])
		tab.focus_mode = Control.FOCUS_NONE
		tab.toggle_mode = true
		tab.pressed.connect(func() -> void: _select_library_tab(key))
		system_tabs.add_child(tab)
		_library_tabs[key] = tab
	var save_button := Button.new()
	save_button.name = "SaveLocalGame"
	save_button.text = "Salvar [F5]"
	save_button.focus_mode = Control.FOCUS_NONE
	save_button.pressed.connect(func() -> void: _emit_local_action("save_game"))
	system_tabs.add_child(save_button)
	var load_button := Button.new()
	load_button.name = "LoadLocalGame"
	load_button.text = "Carregar [F9]"
	load_button.focus_mode = Control.FOCUS_NONE
	load_button.pressed.connect(func() -> void: _emit_local_action("load_game"))
	system_tabs.add_child(load_button)
	var audio_button := Button.new()
	audio_button.name = "ToggleOriginalMusic"
	audio_button.text = "Música"
	audio_button.focus_mode = Control.FOCUS_NONE
	audio_button.tooltip_text = "Ativar / silenciar a música original vinculada ao mapa."
	audio_button.pressed.connect(func() -> void: _emit_local_action("toggle_audio"))
	system_tabs.add_child(audio_button)
	var filters := HBoxContainer.new()
	content.add_child(filters)
	_library_search = LineEdit.new()
	_library_search.name = "LibrarySearch"
	_library_search.placeholder_text = "Buscar nome ou código original…"
	_library_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_library_search.text_changed.connect(func(_query: String) -> void: _library_page = 0; _service_offset = 0; _invalidate_library(); _request_systems_query())
	_library_search.text_submitted.connect(func(_query: String) -> void: _library_search.release_focus())
	_library_search.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
			_library_search.release_focus()
			_library_search.accept_event()
	)
	filters.add_child(_library_search)
	_library_available = CheckBox.new()
	_library_available.name = "OnlyAvailableContent"
	_library_available.text = "Disponíveis"
	_library_available.focus_mode = Control.FOCUS_NONE
	_library_available.toggled.connect(func(_enabled: bool) -> void: _library_page = 0; _service_offset = 0; _invalidate_library(); _request_systems_query())
	filters.add_child(_library_available)
	_systems_toolbar = HBoxContainer.new()
	_systems_toolbar.name = "SystemsToolbar"
	content.add_child(_systems_toolbar)
	_systems_notice = Label.new()
	_systems_notice.name = "SystemsResult"
	_systems_notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_systems_notice.max_lines_visible = 2
	_systems_notice.add_theme_font_size_override("font_size", 11)
	_systems_notice.add_theme_color_override("font_color", GOLD)
	_systems_notice.hide()
	content.add_child(_systems_notice)
	var scroll := ScrollContainer.new()
	scroll.name = "LibraryScroll"
	scroll.custom_minimum_size = Vector2(0, 180)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	content.add_child(scroll)
	_world_missions = VBoxContainer.new()
	_world_missions.name = "LocalMissionList"
	_world_missions.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_world_missions.add_theme_constant_override("separation", 10)
	scroll.add_child(_world_missions)
	var navigation := HBoxContainer.new()
	content.add_child(navigation)
	_library_previous = Button.new()
	_library_previous.name = "LibraryPrevious"
	_library_previous.text = "‹ Anterior"
	_library_previous.focus_mode = Control.FOCUS_NONE
	_library_previous.pressed.connect(func() -> void: _change_library_page(-1))
	navigation.add_child(_library_previous)
	_library_reset_appearance = Button.new()
	_library_reset_appearance.name = "ResetLocalAppearance"
	_library_reset_appearance.text = "Visual padrão"
	_library_reset_appearance.focus_mode = Control.FOCUS_NONE
	_library_reset_appearance.tooltip_text = "Restaurar o modelo original selecionado para esta classe."
	_library_reset_appearance.pressed.connect(func() -> void: _emit_local_action("reset_appearance"))
	_library_reset_appearance.hide()
	navigation.add_child(_library_reset_appearance)
	_library_page_label = Label.new()
	_library_page_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_library_page_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_library_page_label.add_theme_font_size_override("font_size", 11)
	navigation.add_child(_library_page_label)
	_library_next = Button.new()
	_library_next.name = "LibraryNext"
	_library_next.text = "Próxima ›"
	_library_next.focus_mode = Control.FOCUS_NONE
	_library_next.pressed.connect(func() -> void: _change_library_page(1))
	navigation.add_child(_library_next)
	_world_maps = Label.new()
	_world_maps.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_world_maps.max_lines_visible = 2
	_world_maps.add_theme_font_size_override("font_size", 11)
	content.add_child(_world_maps)
	(_library_tabs["missions"] as Button).button_pressed = true
	_world_panel.hide()
	_create_mission_details()


func _create_mission_details() -> void:
	_mission_details_panel = PanelContainer.new()
	_mission_details_panel.name = "OriginalMissionDetails"
	_mission_details_panel.z_index = 18
	var skin := StyleBoxFlat.new()
	skin.bg_color = Color(0.015, 0.045, 0.07, 0.99)
	skin.border_color = Color("458cc1")
	skin.set_border_width_all(1)
	skin.content_margin_left = 16
	skin.content_margin_right = 16
	skin.content_margin_top = 14
	skin.content_margin_bottom = 14
	_mission_details_panel.add_theme_stylebox_override("panel", skin)
	root.add_child(_mission_details_panel)
	var content := VBoxContainer.new()
	_mission_details_panel.add_child(content)
	var heading := HBoxContainer.new()
	content.add_child(heading)
	_mission_details_title = Label.new()
	_mission_details_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_mission_details_title.add_theme_font_size_override("font_size", 13)
	_mission_details_title.clip_text = true
	heading.add_child(_mission_details_title)
	var close := Button.new()
	close.name = "CloseMissionDetails"
	close.text = "Voltar"
	close.focus_mode = Control.FOCUS_NONE
	close.pressed.connect(func() -> void: _mission_details_panel.hide())
	heading.add_child(close)
	_mission_details_text = RichTextLabel.new()
	_mission_details_text.name = "RecoveredMissionProse"
	_mission_details_text.bbcode_enabled = false
	_mission_details_text.selection_enabled = true
	_mission_details_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_mission_details_text.custom_minimum_size = Vector2(0, 200)
	_mission_details_text.add_theme_font_size_override("normal_font_size", 14)
	content.add_child(_mission_details_text)
	_mission_details_panel.hide()


func show_mission_details(details: Dictionary) -> void:
	_mission_details_title.text = "%s · %s" % [str(details.get("id", "")), str(details.get("title", "Missão"))]
	var sections := PackedStringArray([str(details.get("provenance_label", "Texto recuperado do cliente original"))])
	if not str(details.get("description", "")).is_empty():
		sections.append("DESCRIÇÃO\n" + _native_prose(str(details.description)))
	var dialogue: Dictionary = details.get("dialogue", {})
	for definition: Array in [["pre_talk", "APRESENTAÇÃO"], ["mid_talk", "EM ANDAMENTO"], ["success_talk", "CONCLUSÃO"], ["fail_talk", "FALHA"]]:
		var text := str(dialogue.get(definition[0], ""))
		if not text.is_empty(): sections.append(str(definition[1]) + "\n" + _native_prose(text))
	var source: Dictionary = details.get("_source", {})
	if not str(source.get("sha256", "")).is_empty():
		sections.append("ORIGEM · SHA-256\n" + str(source.sha256))
	if sections.size() == 1: sections.append(str(details.get("message", "Esta missão não contém texto adicional recuperado.")))
	_mission_details_text.text = "\n\n".join(sections)
	_mission_details_panel.show()
	_mission_details_text.scroll_to_line(0)
	_layout()


func _native_prose(value: String) -> String:
	# Source strings retain escaped line separators. Display them as text only;
	# unknown escapes/byte markers stay visible and BBCode is never evaluated.
	return value.replace("\\\\n", "\n").replace("\\n", "\n")


func toggle_world_panel() -> void:
	_world_panel.visible = not _world_panel.visible
	if _world_panel.visible:
		_chat_input.release_focus()
		_emit_local_action("refresh_library")
		_refresh_world_panel()
	else:
		_release_systems_focus()
		if is_instance_valid(_online_token): _online_token.clear()
		_mission_details_panel.hide()


func is_world_panel_open() -> bool:
	return is_instance_valid(_world_panel) and _world_panel.visible


func blocks_weapons() -> bool:
	return wants_keyboard() or inventory_items.visible or is_world_panel_open() or _help_panel.visible


func _arc_fraction(key: String, prefix: String, fraction: float, frames: int) -> void:
	if _vital_arcs.has(key):
		(_vital_arcs[key] as TextureRect).texture = _texture(prefix + "%02d" % clampi(int(clampf(fraction, 0, 1) * frames), 0, frames - 1))


func update_simulation(flight: Dictionary, combat: Dictionary, world: Dictionary, view_camera: Camera3D) -> void:
	_world_state = world
	set_inventory_state(combat.get("inventory", {}))
	var ready := bool(combat.get("available", false))
	for pair: Array in [["hp", "max_hp", "ene00", "ene"], ["shield", "max_shield", "she00", "she"]]:
		var value := float(combat.get(pair[0], 0))
		var maximum := float(combat.get(pair[1], 0))
		_arc_fraction(pair[2], pair[3], value / maximum if maximum > 0 and ready else 0, 20)
	_vital_labels[0].text = str(roundi(float(combat.get("hp", 0)))) if ready else "—"
	_vital_labels[1].text = str(roundi(float(combat.get("max_hp", 0)))) if ready else "—"
	_vital_labels[2].text = str(roundi(float(combat.get("shield", 0)))) if ready else "—"
	_vital_labels[3].text = str(roundi(float(combat.get("max_shield", 0)))) if ready else "—"
	_update_skill_hud()
	var fuel: Dictionary = flight.get("fuel", {})
	_vital_labels[6].text = str(roundi(float(fuel.get("current", 0)))) if bool(fuel.get("configured", false)) else "%d" % roundi(float(flight.get("fuel_fraction", 1)) * 100)
	_arc_fraction("fue00", "fue", float(flight.get("fuel_fraction", 1)), 17)
	for index in range(2):
		_ammo_labels[index].text = str(combat.get("primary_ammo" if index == 0 else "secondary_ammo", "—")) if ready else "—"
	_equipment_descriptions["Motor"] = "Motor ITEM %s · perfil desta sessão local." % flight.get("engine_item_num", "—")
	var weapons: Dictionary = combat.get("weapons", {})
	for pair: Array in [["Arma primária", "primary"], ["Arma secundária", "secondary"]]:
		var weapon: Dictionary = weapons.get(pair[1], {})
		_equipment_descriptions[pair[0]] = "%s: %s · ITEM %s · equipamento da sessão local." % [pair[0], weapon.get("name", "indisponível"), weapon.get("item_num", "—")]
	var equipped: Dictionary = _inventory_state.get("equipped", {})
	for role: String in EQUIPPED_ROLES:
		var equipped_id := int(equipped.get(EQUIPPED_ROLES[role], 0))
		for item: Dictionary in _inventory_state.get("entries", []):
			if int(_item_id(item)) == equipped_id:
				_equipment_descriptions[role] = "%s · equipado\n%s" % [role, _item_tooltip(item, true)]
				break
	for role: String in _equipment_descriptions:
		if _equipment_buttons.has(role): (_equipment_buttons[role] as Button).tooltip_text = _equipment_descriptions[role]
	var experience := int(combat.get("experience", 0))
	_xp_notice.text = "EXP %d · NV %d · %s" % [experience, int(_inventory_state.get("level", 9)), "ONLINE" if is_online_connected() else "LOCAL"]
	var wallet: Variant = world.get("wallet", {})
	_inventory_credits.text = str(wallet.get("credits", 0)) if wallet is Dictionary else str(wallet)
	var nearby: Dictionary = world.get("nearby_interaction", {})
	var mode := str(flight.get("mode", "airborne"))
	var mode_label: String = {"airborne": "VOO", "ground": "SOLO", "landed": "POUSADO", "siege": "CERCO", "fuel_falling": "SEM COMBUSTÍVEL · QUEDA", "fuel_stranded": "SEM COMBUSTÍVEL · PARADO"}.get(mode, mode)
	_interaction_prompt.text = "[E] %s · %s" % [nearby.get("title", "Interagir"), mode_label] if not nearby.is_empty() else "M: mundo / missões · %s" % mode_label
	var dead := bool(combat.get("dead", false))
	_death_notice.visible = dead
	_death_notice.text = "GEAR DESTRUÍDO\nReaparecendo em %.1f s" % float(combat.get("respawn_remaining", 0))
	var target: Dictionary = combat.get("target", {})
	_target_root.hide()
	if not target.is_empty() and not bool(target.get("dead", false)) and is_instance_valid(view_camera):
		var point: Vector3 = target.get("position", Vector3.ZERO)
		if not view_camera.is_position_behind(point):
			var screen := view_camera.unproject_position(point)
			if root.get_viewport_rect().has_point(screen):
				_target_root.position = screen - _target_marker.size / 2
				_target_root.show()
				_target_marker.modulate = Color("ffb35e") if bool(combat.get("locked", false)) else Color("8ad5f0")
				_target_status.text = "%s · %du\nHP %d/%d · ESC %d · LOCK %d%%" % [target.get("name", "Alvo local"), roundi(float(target.get("distance", 0))), roundi(float(target.get("hp", 0))), roundi(float(target.get("max_hp", 0))), roundi(float(target.get("shield", 0))), roundi(float(combat.get("lock_progress", 0)) * 100)]
	if is_world_panel_open():
		_refresh_world_panel()


func set_library_data(maps: Array, missions: Array) -> void:
	# The main session supplies compact records only on open or revision changes.
	# Full source ASTs and descriptions never enter this per-frame HUD state.
	_library_map_records = maps
	_library_mission_records = missions
	_library_version += 1
	_invalidate_library()


func _invalidate_library() -> void:
	_world_signature = ""
	if is_world_panel_open():
		_refresh_world_panel()


func _select_library_tab(tab: String) -> void:
	_library_tab = tab
	_library_page = 0
	for key: String in _library_tabs:
		(_library_tabs[key] as Button).button_pressed = key == tab
	_library_available.visible = tab not in ["items", "equipment", "network", "online"]
	_library_search.visible = tab not in ["equipment", "network", "online"]
	_library_available.text = "Minha classe" if tab == "gears" else "Disponíveis"
	_library_available.set_pressed_no_signal(tab in ["maps", "gears"])
	_library_reset_appearance.visible = tab == "gears"
	_library_search.placeholder_text = "Buscar nome ou código original…"
	if tab == "items":
		_load_item_index()
	elif tab == "gears":
		_load_item_index()
		_load_gear_index()
	elif tab == "skills":
		_load_item_index()
	_build_systems_toolbar()
	_systems_signature = ""
	set_systems_state(_systems_state)
	_request_systems_query()


func _load_item_index() -> void:
	if _item_index_loaded or not FileAccess.file_exists(ITEM_INDEX):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(ITEM_INDEX))
	if not parsed is Dictionary:
		return
	_library_item_records = parsed.get("records", [])
	for item: Dictionary in _library_item_records:
		_items_by_id[_item_id(item)] = item
	_item_index_loaded = true


func _load_gear_index() -> void:
	if _gear_index_loaded or not FileAccess.file_exists(GEAR_INDEX):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(GEAR_INDEX))
	if not parsed is Dictionary:
		return
	var by_source: Dictionary = parsed.get("by_source_index", {})
	var source_items: Dictionary = {}
	for item: Dictionary in _library_item_records:
		if int(item.get("Kind", -1)) != 16: continue
		var source_key := str(int(item.get("SourceIndex", 0)))
		if not source_items.has(source_key): source_items[source_key] = []
		(source_items[source_key] as Array).append(item)
	for source_key: String in by_source:
		var model: Dictionary = by_source[source_key]
		var items: Array = source_items.get(source_key, [])
		var mask := int(model.get("unit_kind_mask", 0))
		for item: Dictionary in items: mask |= int(item.get("ReqUnitKind", 0))
		var path := str(model.get("resource_path", model.get("scene_path", "")))
		_library_gear_records.append({"source_index": int(source_key), "model_index": int(model.get("model_id", 0)), "item": items[0] if not items.is_empty() else {}, "unit_kind_mask": mask, "resource_path": path, "available": bool(model.get("available", true)) and FileAccess.file_exists(path)})
	_library_gear_records.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.source_index) < int(b.source_index))
	_gear_index_loaded = true


func _change_library_page(direction: int) -> void:
	if _library_tab == "services":
		var total := int((_systems_state.get("services", {}) as Dictionary).get("total", 0))
		_service_offset = clampi(_service_offset + direction * LIBRARY_PAGE_SIZE, 0, maxi(0, (ceili(total / float(LIBRARY_PAGE_SIZE)) - 1) * LIBRARY_PAGE_SIZE))
		_request_systems_query()
		return
	var page_count := maxi(1, ceili(_library_filtered.size() / float(LIBRARY_PAGE_SIZE)))
	_library_page = clampi(_library_page + direction, 0, page_count - 1)
	_invalidate_library()


func _library_records() -> Array:
	if _library_tab == "skills":
		return (_systems_state.get("skills", {}) as Dictionary).get("rows", [])
	if _library_tab == "services":
		return (_systems_state.get("services", {}) as Dictionary).get("rows", [])
	if _library_tab == "items":
		return _library_item_records
	if _library_tab == "gears":
		return _library_gear_records
	if _library_tab == "maps":
		if not _library_map_records.is_empty():
			return _library_map_records
		var maps: Variant = _world_state.get("map_catalog", [])
		return maps.values() if maps is Dictionary else maps
	var records: Array = _library_mission_records.duplicate()
	var updates: Dictionary = {}
	for mission: Dictionary in _world_state.get("missions", []):
		updates[str(mission.get("id", ""))] = mission
	for mission: Dictionary in _world_state.get("active_missions", []):
		updates[str(mission.get("id", ""))] = mission
	for index: int in range(records.size()):
		var identifier := str((records[index] as Dictionary).get("id", ""))
		if updates.has(identifier):
			records[index] = updates[identifier]
			updates.erase(identifier)
	records.append_array(updates.values())
	return records


func _refresh_world_panel() -> void:
	if not is_instance_valid(_world_summary):
		return
	var signature := JSON.stringify([_world_state.get("revision", 0), _world_state.get("map_id"), _world_state.get("missions", []), _world_state.get("nearby_interaction", {}).get("id", ""), _world_state.get("wallet", {}), _inventory_state.get("gear_id", ""), _library_tab, _library_search.text, _library_available.button_pressed, _library_page, _library_version, _systems_version])
	if signature == _world_signature:
		return
	_world_signature = signature
	var nearby: Dictionary = _world_state.get("nearby_interaction", {})
	_world_summary.text = "%s · mapa %s · %s\n%s" % [_world_state.get("map_title", "Mundo local"), _world_state.get("map_id", "—"), "online: simulação no servidor" if is_online_connected() else "simulação local pausada", "Perfil online separado; sem importar ou salvar progresso offline." if is_online_connected() else nearby.get("title", "E: interagir próximo de contatos e portais. F5/F9: perfil local.")]
	for child: Node in _world_missions.get_children():
		_world_missions.remove_child(child)
		child.queue_free()
	if _library_tab in ["equipment", "network", "online"]:
		if _library_tab == "equipment": _build_equipment_page()
		elif _library_tab == "online": _build_online_page()
		else: _build_network_page()
		_library_previous.disabled = true
		_library_next.disabled = true
		_library_page_label.text = "Online PvE · arena no servidor" if _library_tab == "online" else ("Perfil local" if _library_tab == "equipment" else "Sessão LAN · progresso individual")
		return
	var records := _library_records()
	_library_filtered = []
	var query := _library_search.text.strip_edges().to_lower()
	for record: Dictionary in records:
		var searchable := ""
		if _library_tab in ["services", "skills"]:
			searchable = str(record.get("id", record.get("item_num", record.get("recipe_id", "")))) + " " + str(record.get("name", ""))
		elif _library_tab == "items":
			searchable = _item_id(record) + " " + _item_name(record)
		elif _library_tab == "gears":
			searchable = str(record.get("source_index", "")) + " " + str(record.get("model_index", "")) + " " + _item_name(record.get("item", {}))
		elif _library_tab == "maps":
			searchable = _map_id(record) + " " + str(record.get("map_title", record.get("title", "")))
		else:
			searchable = str(record.get("id", "")) + " " + str(record.get("title", ""))
		if _library_tab != "services" and not query.is_empty() and not searchable.to_lower().contains(query):
			continue
		if _library_available.button_pressed and _library_tab != "items":
			if _library_tab == "skills" and not bool(record.get("learned", false)) and not bool(record.get("learnable", false)):
				continue
			if _library_tab == "gears" and (int(record.get("unit_kind_mask", 0)) & int(GEAR_UNIT_KINDS.get(str(_inventory_state.get("gear_id", "12003100")), 0))) == 0:
				continue
			if _library_tab == "maps" and not bool(record.get("available", false)):
				continue
			if _library_tab == "missions" and str(record.get("status", "")) not in ["available", "active", "ready", "ready_to_claim"]:
				continue
		_library_filtered.append(record)
	if _library_tab == "services":
		_render_service_page()
		return
	var page_count := maxi(1, ceili(_library_filtered.size() / float(LIBRARY_PAGE_SIZE)))
	_library_page = clampi(_library_page, 0, page_count - 1)
	_library_page_label.text = "%d–%d de %d · página %d / %d" % [mini(_library_page * LIBRARY_PAGE_SIZE + 1, _library_filtered.size()), mini((_library_page + 1) * LIBRARY_PAGE_SIZE, _library_filtered.size()), _library_filtered.size(), _library_page + 1, page_count]
	_library_previous.disabled = _library_page == 0
	_library_next.disabled = _library_page >= page_count - 1
	for index: int in range(_library_page * LIBRARY_PAGE_SIZE, mini((_library_page + 1) * LIBRARY_PAGE_SIZE, _library_filtered.size())):
		var record: Dictionary = _library_filtered[index]
		if _library_tab == "skills":
			_build_skill_row(record)
		elif _library_tab == "maps":
			_build_map_row(record)
		elif _library_tab == "items":
			_build_item_row(record)
		elif _library_tab == "gears":
			_build_gear_row(record)
		else:
			_build_mission_row(record)
	if _library_filtered.is_empty():
		var empty := Label.new()
		empty.text = "Nenhum registro para este filtro." if _library_tab != "items" or _item_index_loaded else "Catálogo de itens ainda indisponível neste pacote."
		empty.add_theme_font_size_override("font_size", 12)
		_world_missions.add_child(empty)
	if _library_tab == "skills":
		_world_maps.text = "Aprender debita SPI; usar exige SP, alvo e recarga válidos. Apenas efeitos suportados são executados. Atribua nos slots 1–8."
	elif _library_tab == "maps":
		var available := 0
		for record: Dictionary in records:
			if bool(record.get("available", false)): available += 1
		_world_maps.text = "%d mapas convertidos · %d registros originais. Viagem rápida é uma ferramenta local; portais mantêm os destinos originais." % [available, records.size()]
	elif _library_tab == "items":
		_world_maps.text = "%d modelos de item do cliente. Esta biblioteca não concede itens. I abre o inventário do perfil local." % records.size()
	elif _library_tab == "gears":
		_world_maps.text = "%d aparências recuperadas · teste visual local da classe atual, sem conceder armadura ou alterar atributos." % records.size()
	else:
		_world_maps.text = "Missões preservam requisitos e recompensas recuperados. Cada bloqueio indica o dado ou comportamento que ainda falta."


func _map_id(record: Dictionary) -> String:
	return str(int(record.get("map_id", record.get("map_index", record.get("id", 0)))))


func _new_library_label(parent: Node, text: String, color: Color = TEXT) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", color)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(label)
	return label


func _build_map_row(record: Dictionary) -> void:
	var row := HBoxContainer.new()
	row.name = "MapRow_" + _map_id(record)
	_world_missions.add_child(row)
	var available := bool(record.get("available", false))
	var reason := str(record.get("unavailable_reason", record.get("disabled_reason", "Recursos não convertidos para esta versão.")))
	var missing: Array = record.get("unavailable_reasons", [])
	if not missing.is_empty(): reason = ", ".join(missing).replace("_", " ")
	if reason.is_empty(): reason = "Recursos não convertidos para esta versão."
	var coverage := "Recursos originais convertidos"
	if int(record.get("props_total", 0)) > 0:
		coverage += " · objetos %d / %d" % [int(record.get("props_imported", 0)), int(record.get("props_total", 0))]
	var gaps: Array = record.get("coverage_gaps", [])
	if not gaps.is_empty(): coverage += " · composição parcial"
	var title := "%s · %s\n%s" % [_map_id(record), str(record.get("map_title", record.get("title", "Mapa original"))), coverage if available else "Recursos deste mapa indisponíveis nesta versão."]
	_new_library_label(row, title, TEXT if available else Color("889da9"))
	row.tooltip_text = "Origem MAP_INFO %s\n%s" % [str(record.get("source_id", _map_id(record))), ", ".join(gaps).replace("_", " ")]
	var travel := Button.new()
	travel.name = "TravelMap_" + _map_id(record)
	travel.text = "Visitar" if available else "Indisponível"
	travel.focus_mode = Control.FOCUS_NONE
	travel.disabled = not available or is_online_connected()
	travel.tooltip_text = ONLINE_LOCK_REASON if is_online_connected() else ("Viagem rápida local para explorar os recursos convertidos; não é uma rota original do jogo." if available else reason)
	var action := "travel_map:" + _map_id(record)
	travel.pressed.connect(func() -> void: _emit_local_action(action))
	row.add_child(travel)


func _build_item_row(record: Dictionary) -> void:
	var row := HBoxContainer.new()
	row.name = "CatalogItem_" + _item_id(record)
	row.tooltip_text = _item_tooltip(record)
	_world_missions.add_child(row)
	var icon := TextureRect.new()
	icon.custom_minimum_size = Vector2(32, 32)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.texture = _item_texture(record)
	icon.tooltip_text = row.tooltip_text
	row.add_child(icon)
	_new_library_label(row, "%s · %s\nTipo %s · nível %s–%s · catálogo original" % [_item_id(record), _item_name(record), str(int(record.get("Kind", 0))), str(int(record.get("ReqMinLevel", 0))), str(int(record.get("ReqMaxLevel", 0)))])


func _build_gear_row(record: Dictionary) -> void:
	var row := HBoxContainer.new()
	row.name = "Appearance_" + str(int(record.get("source_index", 0)))
	_world_missions.add_child(row)
	var item: Dictionary = record.get("item", {})
	var icon := TextureRect.new()
	icon.custom_minimum_size = Vector2(32, 32)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.texture = _item_texture(item)
	row.add_child(icon)
	var gear_id := str(_inventory_state.get("gear_id", "12003100"))
	var compatible := (int(record.get("unit_kind_mask", 0)) & int(GEAR_UNIT_KINDS.get(gear_id, 0))) != 0
	_new_library_label(row, "%s · %s\nSourceIndex %s · modelo %s" % [_item_name(item), "classe compatível" if compatible else "outra classe de GEAR", str(int(record.get("source_index", 0))), str(int(record.get("model_index", 0)))], TEXT if compatible else Color("889da9"))
	var preview := Button.new()
	preview.name = "PreviewGear_" + str(int(record.get("source_index", 0)))
	preview.text = "Testar aparência"
	preview.focus_mode = Control.FOCUS_NONE
	preview.disabled = is_online_connected() or not compatible or not bool(record.get("available", false))
	preview.tooltip_text = "Teste visual local da classe atual. Mantém equipamento, motor e atributos; não concede ou equipa a armadura. Use F2 para alternar a classe." if compatible else "Esta aparência pertence a outra classe de GEAR. Use F2 para alternar a classe."
	var action := "preview_gear:" + str(int(record.get("source_index", 0)))
	preview.pressed.connect(func() -> void: _emit_local_action(action))
	row.add_child(preview)


func _build_mission_row(mission: Dictionary) -> void:
	var row := VBoxContainer.new()
	row.name = "MissionRow_" + str(mission.get("id", "")).validate_node_name()
	_world_missions.add_child(row)
	var status := str(mission.get("status", "available"))
	var state_label: String = {"available":"disponível", "active":"em andamento", "ready":"pronta para entregar", "ready_to_claim":"pronta para entregar", "completed":"concluída", "failed":"falhou", "locked":"pré-requisito pendente", "unavailable":"indisponível", "unsupported":"comportamento ainda não implementado"}.get(status, status)
	var goals: Array = mission.get("objectives", [])
	if goals.is_empty() and not (mission.get("objective", {}) as Dictionary).is_empty(): goals = [mission.get("objective", {})]
	var progress := PackedStringArray()
	for goal: Dictionary in goals:
		var kind := str(goal.get("kind", ""))
		var description: String = {"destroy_target":"Eliminar alvo", "kill_monster":"Eliminar alvo", "kill":"Eliminar alvo", "dialogue":"Conversar", "talk_npc":"Conversar", "visit_map":"Visitar mapa", "visit_event":"Visitar local", "inventory":"Possuir item"}.get(kind, "Objetivo")
		var raw_target: Variant = goal.get("target_code", goal.get("target", goal.get("npc_id", goal.get("map_id", goal.get("item_num", "")))))
		var target := str(int(raw_target)) if raw_target is float or raw_target is int else str(raw_target)
		progress.append("%s %s · %d / %d" % [description, target, int(goal.get("current", 0)), int(goal.get("required", 1))])
	var text := "%s · %s · %s\n%s" % [str(mission.get("id", "")), mission.get("title", "Missão local"), state_label, mission.get("provenance_label", "Cenário local adaptado")]
	if not progress.is_empty(): text += "\n" + "\n".join(progress)
	if float(mission.get("time_limit_seconds", 0)) > 0:
		text += "\nTempo restante: %d s / %d s" % [maxi(0, ceili(float(mission.get("remaining_seconds", 0)))), ceili(float(mission.get("time_limit_seconds", 0)))]
	var reward: Dictionary = mission.get("reward", {})
	text += "\nRecompensa base: %d créditos · %d EXP" % [int(reward.get("credits", 0)), int(reward.get("experience", 0))] if not (mission.get("per_item_rewards", []) as Array).is_empty() or not (mission.get("random_item_rewards", []) as Array).is_empty() else "\nRecompensa: %d créditos · %d EXP" % [int(reward.get("credits", 0)), int(reward.get("experience", 0))]
	for variable: Dictionary in mission.get("per_item_rewards", []):
		text += "\nVariável: %d SPI por item %s entregue" % [int(variable.get("credits", 0)), str(int(variable.get("source_item_num", 0)))]
		if int(variable.get("item_num", 0)) > 0: text += " · ITEM %s ×%d" % [str(int(variable.item_num)), int(variable.get("count", 1))]
	if not (mission.get("random_item_rewards", []) as Array).is_empty(): text += "\nInclui item aleatório conforme os pesos originais; resultado definido na entrega."
	for item: Dictionary in reward.get("items", []):
		text += " · ITEM %s ×%d" % [str(int(item.get("item_num", item.get("ItemNum", 0)))), int(item.get("count", 1))]
	var reason := str(mission.get("disabled_reason", mission.get("unavailable_reason", "")))
	if reason.is_empty(): reason = str(mission.get("unavailable_reason", ""))
	if not reason.is_empty(): text += "\n" + reason
	var label := _new_library_label(row, text, TEXT if status in ["available", "active", "ready", "ready_to_claim", "completed"] else Color("889da9"))
	label.tooltip_text = "Requisitos originais: nível %s–%s · facção %s · máscara GEAR %s\n%s" % [str(mission.get("required_level_min", "—")), str(mission.get("required_level_max", "—")), str(mission.get("required_influence", "—")), str(mission.get("required_gear_mask", "—")), reason]
	if status in ["available", "ready", "ready_to_claim"]:
		var button := Button.new()
		button.name = "MissionAction_" + str(mission.get("id", "")).validate_node_name()
		button.focus_mode = Control.FOCUS_NONE
		var claim := status != "available"
		button.text = "Entregar / receber recompensa" if claim else "Aceitar missão"
		button.disabled = is_online_connected()
		if button.disabled: button.tooltip_text = ONLINE_LOCK_REASON
		var action := ("claim_reward:" if claim else "accept_mission:") + str(mission.get("id", ""))
		button.pressed.connect(func() -> void: _emit_local_action(action))
		row.add_child(button)
	var details := Button.new()
	details.name = "MissionDetails_" + str(mission.get("id", "")).validate_node_name()
	details.text = "Texto original / detalhes" if bool(mission.get("native", true)) else "Detalhes do treino local"
	details.focus_mode = Control.FOCUS_NONE
	var details_action := "mission_details:" + str(mission.get("id", ""))
	details.pressed.connect(func() -> void: _emit_local_action(details_action))
	row.add_child(details)


func set_aim_position(where: Vector2) -> void:
	_reticle.position = where - _reticle.size / 2


func set_systems_state(data: Dictionary) -> void:
	# Main supplies model snapshots and at most one page of shop/recipe results.
	# The UI never mutates a model, grants items or computes an affordable quote.
	if not data.is_empty() and data.has("skills") and not (data.skills as Dictionary).has("rows"):
		data = data.duplicate()
		data.skills = (data.skills as Dictionary).duplicate()
		data.skills["rows"] = (_systems_state.get("skills", {}) as Dictionary).get("rows", [])
	_systems_state = data
	var network: Dictionary = data.get("network", {})
	_network_notes.clear()
	for entry: Dictionary in network.get("chat", []):
		_network_notes.append("LAN · %s › %s" % [str(entry.get("name", entry.get("peer_id", "Jogador"))), str(entry.get("text", ""))])
	_update_chat_placeholder()
	set_chat_filter(chat_filter)
	_update_skill_hud()
	var skills: Dictionary = data.get("skills", {})
	var compact_skills: Array = []
	for row: Dictionary in skills.get("rows", []):
		compact_skills.append([row.get("id"), row.get("learned"), row.get("learnable"), row.get("reason"), ceili(float(row.get("remaining", 0)))])
	var peers: Array = []
	for key: Variant in (network.get("peers", {}) as Dictionary):
		var peer: Dictionary = network.peers[key]
		peers.append([key, peer.get("name"), peer.get("map_index"), peer.get("gear_id")])
	var active_data: Variant = []
	match _library_tab:
		"services": active_data = data.get("services", {})
		"equipment": active_data = data.get("equipment", {})
		"skills": active_data = [compact_skills, skills.get("status"), skills.get("learn_allowed", false), skills.get("learn_reason", ""), (data.get("equipment", {}) as Dictionary).get("credits", 0)]
		"network": active_data = [network.get("status"), network.get("message"), peers]
	var signature := JSON.stringify([_library_tab, active_data, data.get("message", "")])
	if signature != _systems_signature:
		_systems_signature = signature
		_systems_version += 1
		_systems_notice.text = str(data.get("message", ""))
		_systems_notice.visible = not _systems_notice.text.is_empty()
		_invalidate_library()


func systems_query() -> Dictionary:
	return {"tab": _library_tab, "mode": _service_mode, "query": _library_search.text.strip_edges(), "offset": _service_offset, "limit": LIBRARY_PAGE_SIZE, "available": _library_available.button_pressed}


func _request_systems_query() -> void:
	if _library_tab == "services" and is_world_panel_open():
		_emit_local_action("systems_query:" + JSON.stringify(systems_query()))


func _request_network(payload: Dictionary) -> void:
	_emit_local_action("network:" + JSON.stringify(payload))


func _release_systems_focus() -> void:
	var owner := root.get_viewport().gui_get_focus_owner()
	if is_instance_valid(owner): owner.release_focus()


func _system_button(parent: Node, title: String, action: String, enabled: bool = true, reason: String = "") -> Button:
	var button := Button.new()
	button.text = title
	button.focus_mode = Control.FOCUS_NONE
	button.disabled = not enabled or _online_blocks_action(action)
	button.tooltip_text = ONLINE_LOCK_REASON if _online_blocks_action(action) else reason
	button.add_theme_font_size_override("font_size", 11)
	button.pressed.connect(func() -> void: _emit_local_action(action))
	parent.add_child(button)
	return button


func _build_systems_toolbar() -> void:
	for child: Node in _systems_toolbar.get_children():
		_systems_toolbar.remove_child(child)
		child.queue_free()
	_service_modes.clear()
	_systems_toolbar.visible = _library_tab in ["services", "skills"]
	if _library_tab == "services":
		for definition: Array in [["buy", "Comprar"], ["sell", "Vender"], ["recipes", "Receitas"], ["maintenance", "Manutenção"]]:
			var mode := str(definition[0])
			var button := Button.new()
			button.name = "ServiceMode_" + mode
			button.text = str(definition[1])
			button.toggle_mode = true
			button.button_pressed = _service_mode == mode
			button.focus_mode = Control.FOCUS_NONE
			button.add_theme_font_size_override("font_size", 11)
			button.pressed.connect(func() -> void: _select_service_mode(mode))
			_systems_toolbar.add_child(button)
			_service_modes[mode] = button
		var label := Label.new()
		label.text = "Qtd."
		label.add_theme_font_size_override("font_size", 11)
		_systems_toolbar.add_child(label)
		_service_quantity = SpinBox.new()
		_service_quantity.name = "ServiceQuantity"
		_service_quantity.min_value = 1
		_service_quantity.max_value = 999
		_service_quantity.value = 1
		_service_quantity.custom_minimum_size.x = 90
		_service_quantity.tooltip_text = "Quantidade de compras/vendas. O modelo valida saldo, posse e limites antes de concluir."
		_systems_toolbar.add_child(_service_quantity)
	elif _library_tab == "skills":
		var label := _new_library_label(_systems_toolbar, "Atribuir habilidade no atalho:")
		label.autowrap_mode = TextServer.AUTOWRAP_OFF
		label.custom_minimum_size.x = 230
		label.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		_skill_slot = SpinBox.new()
		_skill_slot.name = "SkillSlotNumber"
		_skill_slot.min_value = 1
		_skill_slot.max_value = 8
		_skill_slot.value = 1
		_skill_slot.custom_minimum_size.x = 80
		_systems_toolbar.add_child(_skill_slot)
		var clear_button := Button.new()
		clear_button.text = "Limpar atalho"
		clear_button.focus_mode = Control.FOCUS_NONE
		clear_button.disabled = is_online_connected()
		if clear_button.disabled: clear_button.tooltip_text = ONLINE_LOCK_REASON
		_systems_toolbar.add_child(clear_button)
		clear_button.pressed.connect(func() -> void: _emit_local_action("skill_assign:%d:0" % int(_skill_slot.value)))


func _select_service_mode(mode: String) -> void:
	_service_mode = mode
	_service_offset = 0
	for key: String in _service_modes:
		(_service_modes[key] as Button).button_pressed = mode == key
	_library_search.visible = mode != "maintenance"
	_library_available.visible = mode != "maintenance"
	_invalidate_library()
	_request_systems_query()


func _render_service_page() -> void:
	var service: Dictionary = _systems_state.get("services", {})
	var total := int(service.get("total", 0))
	var offset := int(service.get("offset", _service_offset))
	var count := mini(LIBRARY_PAGE_SIZE, _library_filtered.size())
	_library_previous.disabled = offset <= 0
	_library_next.disabled = offset + LIBRARY_PAGE_SIZE >= total
	_library_page_label.text = "%d–%d de %d" % [mini(offset + 1, total), mini(offset + count, total), total]
	if _service_mode == "maintenance":
		for quote: Dictionary in service.get("quotes", []):
			_build_service_quote(quote)
		if _world_missions.get_child_count() == 0:
			_new_library_label(_world_missions, str(service.get("reason", "Aproxime-se de um contato ou entre em uma cidade para consultar serviços.")), GOLD)
		_library_previous.disabled = true
		_library_next.disabled = true
		_library_page_label.text = "Serviços calculados pelo perfil"
	else:
		for index: int in range(count):
			var record: Dictionary = _library_filtered[index]
			if _service_mode == "recipes": _build_recipe_row(record)
			else: _build_shop_row(record)
		if count == 0:
			_new_library_label(_world_missions, str(service.get("reason", "Nenhum registro atende aos filtros e requisitos atuais.")), GOLD)
	_world_maps.text = str(service.get("scope", "Economia local: preços/ingredientes recuperados; catálogo de loja e acesso usam política local explícita. Toda transação é revalidada antes de debitar SPI ou itens."))


func _add_system_icon(parent: Node, record: Dictionary) -> void:
	var icon := TextureRect.new()
	icon.custom_minimum_size = Vector2(32, 32)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.texture = _item_texture(record)
	parent.add_child(icon)


func _build_shop_row(record: Dictionary) -> void:
	var row := HBoxContainer.new()
	row.name = "ShopItem_" + _item_id(record)
	_world_missions.add_child(row)
	_add_system_icon(row, record)
	var selling := _service_mode == "sell"
	var price := int(record.get("sell_price" if selling else "buy_price", 0))
	var service: Dictionary = _systems_state.get("services", {})
	var allowed := bool(service.get("allowed", false))
	var reason := str(record.get("reason", "")) if allowed else str(service.get("reason", "Este serviço exige um contato apropriado ou uma cidade."))
	_new_library_label(row, "%s · %s\n%d SPI / lote ×%d · possuído ×%d%s" % [_item_id(record), _item_name(record), price, int(record.get("bundle_size", 1)), int(record.get("count", 0)), "\n" + reason if not reason.is_empty() else ""])
	var button := Button.new()
	button.name = "ShopAction_" + _item_id(record)
	button.text = "Vender" if selling else "Comprar"
	button.focus_mode = Control.FOCUS_NONE
	button.disabled = is_online_connected() or not allowed or not bool(record.get("available", false))
	button.tooltip_text = ONLINE_LOCK_REASON if is_online_connected() else (reason if button.disabled else "Solicita a transação. Saldo, quantidade e requisitos serão conferidos novamente.")
	var prefix := "shop_sell" if selling else "shop_buy"
	button.pressed.connect(func() -> void: _emit_local_action("%s:%s:%d" % [prefix, _item_id(record), int(_service_quantity.value)]))
	row.add_child(button)


func _build_recipe_row(record: Dictionary) -> void:
	var row := HBoxContainer.new()
	row.name = "Recipe_" + str(record.get("recipe_id", "")).validate_node_name()
	_world_missions.add_child(row)
	_add_system_icon(row, record)
	var ingredients := PackedStringArray()
	for ingredient: Dictionary in record.get("ingredients", []):
		ingredients.append("%s %d/%d" % [str(ingredient.get("name", ingredient.get("item_num", "Ingrediente"))), int(ingredient.get("owned", 0)), int(ingredient.get("count", 0))])
	var service: Dictionary = _systems_state.get("services", {})
	var allowed := bool(service.get("allowed", false))
	var reason := str(record.get("reason", "")) if allowed else str(service.get("reason", "Este serviço exige um contato apropriado ou uma cidade."))
	_new_library_label(row, "%s · %s · %d SPI · %.2f%%\n%s%s" % [str(record.get("recipe_id", "")), _item_name(record), int(record.get("cost", 0)), float(record.get("probability_10k", 0)) / 100.0, ", ".join(ingredients), "\n" + reason if not reason.is_empty() else ""])
	var button := _system_button(row, "Fabricar", "craft_recipe:" + str(record.get("recipe_id", "")), allowed and bool(record.get("available", false)), reason)
	button.name = "CraftRecipe_" + str(record.get("recipe_id", "")).validate_node_name()


func _build_service_quote(quote: Dictionary) -> void:
	var kind := str(quote.get("resource", quote.get("kind", "")))
	var labels := {"hp": "Reparar HP", "dp": "Recuperar escudo", "ep": "Reabastecer combustível", "sp": "Recuperar SP", "primary_ammo": "Munição primária", "secondary_ammo": "Munição secundária"}
	var action := "service_ammo:" + kind.trim_suffix("_ammo") if kind.ends_with("_ammo") else "service_repair:" + kind
	var row := HBoxContainer.new()
	row.name = "ServiceQuote_" + kind
	_world_missions.add_child(row)
	var service: Dictionary = _systems_state.get("services", {})
	var allowed := bool(service.get("allowed", false))
	var reason := str(quote.get("reason", quote.get("error", "")))
	if not bool(quote.get("affordable", true)): reason = "Saldo SPI insuficiente."
	if not allowed: reason = str(service.get("reason", "Este serviço exige um contato apropriado ou uma cidade."))
	_new_library_label(row, "%s · +%s · %d SPI%s" % [labels.get(kind, kind), str(quote.get("amount", 0)), int(quote.get("cost", 0)), "\n" + reason if not reason.is_empty() else ""])
	_system_button(row, "Solicitar", action, allowed and bool(quote.get("ok", quote.get("available", false))) and bool(quote.get("affordable", true)) and float(quote.get("amount", 0)) > 0, reason)


func _build_skill_row(record: Dictionary) -> void:
	var identifier := str(int(record.get("id", 0)))
	var row := HBoxContainer.new()
	row.name = "SkillRow_" + identifier
	_world_missions.add_child(row)
	_add_system_icon(row, _items_by_id.get(str(int(record.get("iconitem", record.get("id", 0)))), {}))
	var learned := bool(record.get("learned", false))
	var skills: Dictionary = _systems_state.get("skills", {})
	var allowed := bool(skills.get("learn_allowed", false))
	var affordable := int((_systems_state.get("equipment", {}) as Dictionary).get("credits", 0)) >= int(record.get("cost", 0))
	var can_learn := not learned and bool(record.get("learnable", false)) and allowed and affordable
	var reason := str(record.get("reason", ""))
	if not learned and bool(record.get("learnable", false)):
		if not allowed: reason = str(skills.get("learn_reason", "Visite uma escola de habilidades para aprender."))
		elif not affordable: reason = "Saldo SPI insuficiente para aprender esta habilidade."
	row.tooltip_text = str(record.get("description", ""))
	_new_library_label(row, "%s · %s · %s\nNv.%d · %d SPI · %s SP · recarga %.1fs%s" % [identifier, str(record.get("name", "Habilidade")), "aprendida" if learned else "não aprendida", int(record.get("min_level", 0)), int(record.get("cost", 0)), str(record.get("sp_cost", 0)), float(record.get("cooldown", 0)), "\n" + reason if not reason.is_empty() else ""], TEXT if bool(record.get("supported", false)) else Color("889da9"))
	var learn := _system_button(row, "Aprendida" if learned else "Aprender", "skill_learn:" + identifier, can_learn, reason)
	learn.name = "LearnSkill_" + identifier
	var assign := Button.new()
	assign.name = "AssignSkill_" + identifier
	assign.text = "Atribuir"
	assign.focus_mode = Control.FOCUS_NONE
	assign.disabled = is_online_connected() or not learned or not bool(record.get("supported", false))
	assign.tooltip_text = "Vincula ao slot escolhido; não aprende nem ativa gratuitamente." if not assign.disabled else reason
	assign.pressed.connect(func() -> void: _emit_local_action("skill_assign:%d:%s" % [int(_skill_slot.value), identifier]))
	row.add_child(assign)


func _update_skill_hud() -> void:
	if not is_instance_valid(_chat_input): return
	var skills: Dictionary = _systems_state.get("skills", {})
	var max_sp := float(skills.get("max_sp", 0))
	var sp := float(skills.get("sp", 0))
	_arc_fraction("skil00", "skil", sp / max_sp if max_sp > 0 else 0.0, 20)
	_vital_labels[4].text = str(roundi(sp)) if max_sp > 0 else "—"
	_vital_labels[5].text = str(roundi(max_sp)) if max_sp > 0 else "—"
	var hotbar: Array = skills.get("hotbar", [])
	if not _item_index_loaded:
		for slot: Dictionary in hotbar:
			if int(slot.get("id", 0)) > 0:
				# Resolve native icons once, including before the library is opened.
				_load_item_index()
				break
	for index: int in range(_skill_buttons.size()):
		var slot: Dictionary = hotbar[index] if index < hotbar.size() and hotbar[index] is Dictionary else {}
		var button := _skill_buttons[index]
		var identifier := int(slot.get("id", 0))
		var remaining := float(slot.get("cooldown", 0))
		button.disabled = (is_online_active() and not bool(_systems_state.get("authoritative_online",false))) or identifier <= 0 or not bool(slot.get("usable", false))
		button.text = "%d\n%d" % [index + 1, ceili(remaining)] if remaining > 0 else str(index + 1)
		button.modulate = CYAN if identifier > 0 else Color.WHITE
		var icon_item: Dictionary = _items_by_id.get(str(int(slot.get("iconitem", identifier))), {})
		button.icon = _item_texture(icon_item)
		button.expand_icon = true
		button.tooltip_text = "%d · %s\n%s SP · recarga %.1fs\n%s" % [index + 1, str(slot.get("name", "Atalho vazio")), str(slot.get("sp_cost", 0)), remaining, str(slot.get("reason", ""))]


func _build_equipment_page() -> void:
	var equipment: Dictionary = _systems_state.get("equipment", _inventory_state)
	var totals: Dictionary = equipment.get("total_stats", {})
	var allocated: Dictionary = equipment.get("allocated_stats", {})
	var points := int(equipment.get("bonus_stats", 0))
	_new_library_label(_world_missions, "Pontos disponíveis: %d · limite por atributo: %d" % [points, int(equipment.get("stat_cap", 0))], GOLD)
	for stat: String in STAT_LABELS:
		var row := HBoxContainer.new()
		row.name = "AllocateStat_" + stat
		_world_missions.add_child(row)
		_new_library_label(row, "%s · total %s · distribuídos %d" % [STAT_LABELS[stat], str(totals.get(stat, 0)), int(allocated.get(stat, 0))])
		var cap := int(equipment.get("stat_cap", 0))
		_system_button(row, "+1", "allocate_stat:%s:1" % stat, points > 0 and (cap <= 0 or float(totals.get(stat, 0)) < cap), "Distribui um ponto com a regra da classe. A operação é revalidada pelo inventário.")
	var equipped: Dictionary = equipment.get("equipped", {})
	var slots := HBoxContainer.new()
	_world_missions.add_child(slots)
	for definition: Array in [["armor", "Armadura"], ["cpu", "CPU"], ["radar", "Radar"], ["accessory", "Acessório"]]:
		var slot := str(definition[0])
		var identifier := int(equipped.get(slot, 0))
		_system_button(slots, "%s %s · retirar" % [definition[1], str(identifier) if identifier > 0 else "—"], "unequip_item:" + slot, identifier > 0, "Equipamentos possuídos são selecionados e equipados pelo inventário [I].")
	_world_maps.text = "Equipar armadura, CPU, radar e acessórios usa apenas itens possuídos em I. Atributos e modificadores aplicam as regras suportadas; bônus desconhecidos continuam bloqueados."


func _build_network_page() -> void:
	var network: Dictionary = _systems_state.get("network", {})
	var labels := {"offline": "desconectado", "hosting": "hospedando", "connecting": "conectando", "connected": "conectado", "error": "erro"}
	_new_library_label(_world_missions, "Estado: %s · %d participantes\n%s" % [labels.get(str(network.get("status", "offline")), str(network.get("status", "offline"))), int(network.get("peer_count", 0)), str(network.get("message", ""))], GOLD)
	var form := HBoxContainer.new()
	form.name = "NetworkConnectionForm"
	_world_missions.add_child(form)
	var old_address := _network_address.text if is_instance_valid(_network_address) else str(network.get("address", "127.0.0.1"))
	var old_port := int(_network_port.value) if is_instance_valid(_network_port) else int(network.get("port", 24680))
	_network_address = LineEdit.new()
	_network_address.name = "NetworkAddress"
	_network_address.placeholder_text = "IP do computador anfitrião"
	_network_address.text = old_address
	_network_address.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_network_address.max_length = 255
	form.add_child(_network_address)
	_network_port = SpinBox.new()
	_network_port.name = "NetworkPort"
	_network_port.min_value = 1024
	_network_port.max_value = 65535
	_network_port.value = old_port
	_network_port.custom_minimum_size.x = 110
	form.add_child(_network_port)
	var controls := HBoxContainer.new()
	_world_missions.add_child(controls)
	var offline := str(network.get("status", "offline")) in ["offline", "error"] and not is_online_connected()
	var host := _system_button(controls, "Hospedar", "", offline)
	for connection: Dictionary in host.pressed.get_connections(): host.pressed.disconnect(connection.callable)
	host.name = "NetworkHost"
	host.pressed.connect(func() -> void: _request_network({"action": "host", "port": int(_network_port.value)}))
	var join := _system_button(controls, "Entrar pelo IP", "", offline)
	for connection: Dictionary in join.pressed.get_connections(): join.pressed.disconnect(connection.callable)
	join.name = "NetworkJoin"
	join.pressed.connect(func() -> void: _request_network({"action": "join", "address": _network_address.text.strip_edges(), "port": int(_network_port.value)}))
	var leave := _system_button(controls, "Desconectar", "", not offline)
	for connection: Dictionary in leave.pressed.get_connections(): leave.pressed.disconnect(connection.callable)
	leave.name = "NetworkLeave"
	leave.pressed.connect(func() -> void: _request_network({"action": "disconnect"}))
	for key: Variant in (network.get("peers", {}) as Dictionary):
		var peer: Dictionary = network.peers[key]
		_new_library_label(_world_missions, "%s · GEAR %s · mapa %s" % [str(peer.get("name", "Jogador")) + " (#" + str(key) + ")", str(peer.get("gear_id", "—")), str(peer.get("map_index", "—"))])
	_world_maps.text = "LAN compartilha presença, nave e chat entre cópias desta versão. Combate, economia, missões e recompensas continuam individuais. Informe o IP local do anfitrião; o serviço original não é utilizado."


func is_online_connected() -> bool:
	return bool(_online_state.get("connected", false))


func is_online_active() -> bool:
	return is_online_connected() or str(_online_state.get("status","")) in ["connecting","authenticating","authorizing"]


func _online_blocks_action(action: String) -> bool:
	if action.begins_with("skill_use:") and bool(_systems_state.get("authoritative_online",false)): return false
	return is_online_active() and (action.get_slice(":", 0) in ONLINE_OFFLINE_ONLY or action.begins_with("network:"))


func _emit_local_action(action: String) -> void:
	if _online_blocks_action(action):
		append_system_note(ONLINE_LOCK_REASON)
		return
	local_action_requested.emit(action)


func _request_online(payload: Dictionary) -> void:
	_emit_local_action("online:" + JSON.stringify(payload))


func _safe_online_url(value: String) -> String:
	var clean := value.strip_edges().get_slice("?", 0).get_slice("#", 0)
	if clean.contains("@"): return ""
	return clean


func _valid_online_url(value: String) -> bool:
	if value.is_empty() or value != _safe_online_url(value): return false
	if value.begins_with("wss://") and value.trim_prefix("wss://").get_slice("/", 0).length() > 0:
		return true
	# Plain WebSocket is useful only for a loopback development server.
	for host: String in ["127.0.0.1", "localhost", "[::1]"]:
		if value.begins_with("ws://" + host + ":") or value.begins_with("ws://" + host + "/"):
			return true
	return false


func set_online_state(data: Dictionary) -> void:
	# A strict public-state whitelist prevents credentials from entering HUD state,
	# logs, capture metadata or a locally persisted profile.
	var state: Dictionary = {}
	for key: String in ["status", "message", "server_url", "pilot_id"]:
		var value: Variant = data.get(key, "")
		state[key] = str(value) if value is String or value is StringName else ""
	if str(state.status).is_empty(): state.status = "offline"
	state["server_url"] = _safe_online_url(str(state.server_url))
	state["connected"] = data.get("connected", false) is bool and data.get("connected", false)
	state["shared_combat"] = data.get("shared_combat", true) is bool and data.get("shared_combat", true)
	for key: String in ["player_count", "revision"]:
		var value: Variant = data.get(key, 0)
		state[key] = maxi(0, int(value)) if value is int or value is float else 0
	_online_state = state
	if is_instance_valid(_mode):
		_mode.text = "PVE ONLINE · F1 AJUDA" if is_online_active() else "PRÉVIA LOCAL · F1 AJUDA"
	if not str(state.server_url).is_empty(): _online_url_draft = str(state.server_url)
	_update_chat_placeholder()
	set_chat_filter(chat_filter)
	_update_skill_hud()
	_update_online_locks()
	_update_online_status_label()
	var signature := JSON.stringify([state.status, state.message, state.connected, state.server_url, state.pilot_id, state.player_count, state.shared_combat])
	if signature != _online_signature:
		_online_signature = signature
		_systems_version += 1
		_invalidate_library()


func append_online_chat(pilot_id: String, text: String) -> void:
	# Chat is deliberately plain text; no remote BBCode, images or links execute.
	_online_notes.append("Online · %s › %s" % [pilot_id.left(80), text.left(512)])
	if _online_notes.size() > 30: _online_notes.pop_front()
	set_chat_filter(chat_filter)


func _update_chat_placeholder() -> void:
	if not is_instance_valid(_chat_input): return
	if is_online_connected(): _chat_input.placeholder_text = "Online… Enter para enviar"
	elif bool((_systems_state.get("network", {}) as Dictionary).get("connected", false)): _chat_input.placeholder_text = "LAN… Enter para enviar"
	else: _chat_input.placeholder_text = "Nota local… Enter para registrar"


func _update_online_locks() -> void:
	if not is_instance_valid(_world_panel): return
	for name: String in ["SaveLocalGame", "LoadLocalGame", "ResetLocalAppearance"]:
		var button := _world_panel.find_child(name, true, false) as Button
		if is_instance_valid(button):
			button.disabled = is_online_active()
			button.tooltip_text = ONLINE_LOCK_REASON if is_online_connected() else "Perfil local deste computador."
	if is_instance_valid(_pause_button):
		_pause_button.disabled = is_online_active()
		_pause_button.tooltip_text = "A simulação online continua no servidor." if is_online_connected() else "Pausar / continuar voo local [P]"
	if is_instance_valid(_inventory_equip):
		_inventory_equip.disabled = is_online_connected() or (_inventory_selected.get("equippable_slots", []) as Array).is_empty()
		if is_online_connected(): _inventory_equip.tooltip_text = ONLINE_LOCK_REASON
	if is_instance_valid(_world_heading):
		_world_heading.text = "MUNDO E BIBLIOTECA · ONLINE PvE" if is_online_connected() else "MUNDO E BIBLIOTECA · SESSÃO LOCAL"


func _online_busy() -> bool:
	return str(_online_state.get("status", "offline")) in ["connecting", "authenticating", "authorizing"]


func _update_online_connect_controls() -> void:
	if not is_instance_valid(_online_connect): return
	var connected := is_online_connected()
	var busy := _online_busy()
	var url := _online_url.text.strip_edges()
	_online_connect.disabled = connected or busy or not _valid_online_url(url) or _online_token.text.strip_edges().is_empty()
	_online_connect.tooltip_text = "Informe WSS e a credencial do piloto. O perfil offline não é enviado." if not connected else "Já conectado ao servidor da arena."
	_online_disconnect.disabled = not connected and not busy
	_online_url.editable = not connected and not busy
	_online_token.editable = not connected and not busy


func _update_online_status_label() -> void:
	if not is_instance_valid(_online_status_label): return
	var labels := {"offline": "desconectado", "disconnected": "desconectado", "connecting": "conectando", "authenticating": "autenticando", "authorizing": "autenticando", "connected": "conectado", "error": "erro"}
	var status := str(_online_state.get("status", "offline"))
	_online_status_label.text = "Estado: %s · %d jogadores · atualização %d\n%s" % [labels.get(status, status), int(_online_state.get("player_count", 0)), int(_online_state.get("revision", 0)), str(_online_state.get("message", "Informe o endereço WSS e a credencial do piloto para entrar."))]
	if not str(_online_state.get("pilot_id", "")).is_empty(): _online_status_label.text += "\nPiloto: " + str(_online_state.pilot_id)


func _submit_online_connection() -> void:
	if not is_instance_valid(_online_token) or not _valid_online_url(_online_url.text.strip_edges()) or _online_busy() or is_online_connected(): return
	var credential := _online_token.text.strip_edges()
	if credential.is_empty(): return
	var url := _online_url.text.strip_edges()
	_online_url_draft = url
	# Clear before the synchronous action callback can update/capture the UI.
	_online_token.clear()
	_online_token.release_focus()
	_update_online_connect_controls()
	_request_online({"action": "connect", "url": url, "token": credential})


func _build_online_page() -> void:
	_online_status_label = _new_library_label(_world_missions, "", GOLD)
	_online_status_label.name = "OnlineStatus"
	_update_online_status_label()
	_new_library_label(_world_missions, "Arena online PvE: mapa 3002 e I-GEAR. Os jogadores compartilham o combate; a simulação e o progresso deste piloto ficam no servidor.")
	var address := HBoxContainer.new()
	_world_missions.add_child(address)
	var url_label := _new_library_label(address, "Servidor")
	url_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	url_label.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_online_url = LineEdit.new()
	_online_url.name = "OnlineServerURL"
	_online_url.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_online_url.placeholder_text = "wss://seu-dominio/play"
	_online_url.max_length = 512
	_online_url.text = _online_url_draft
	address.add_child(_online_url)
	_online_url.text_changed.connect(func(value: String) -> void:
		_online_url_draft = _safe_online_url(value)
		_update_online_connect_controls()
	)
	var credentials := HBoxContainer.new()
	_world_missions.add_child(credentials)
	var token_label := _new_library_label(credentials, "Credencial")
	token_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	token_label.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_online_token = LineEdit.new()
	_online_token.name = "OnlinePilotCredential"
	_online_token.secret = true
	_online_token.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_online_token.max_length = 512
	_online_token.placeholder_text = "Credencial do piloto · não será salva neste computador"
	credentials.add_child(_online_token)
	_online_token.text_changed.connect(func(_value: String) -> void: _update_online_connect_controls())
	_online_token.text_submitted.connect(func(_value: String) -> void: _submit_online_connection())
	var controls := HBoxContainer.new()
	_world_missions.add_child(controls)
	_online_connect = Button.new()
	_online_connect.name = "OnlineConnect"
	_online_connect.text = "Conectar ao servidor"
	_online_connect.focus_mode = Control.FOCUS_NONE
	_online_connect.pressed.connect(_submit_online_connection)
	controls.add_child(_online_connect)
	_online_disconnect = Button.new()
	_online_disconnect.name = "OnlineDisconnect"
	_online_disconnect.text = "Desconectar"
	_online_disconnect.focus_mode = Control.FOCUS_NONE
	_online_disconnect.pressed.connect(func() -> void: _request_online({"action": "disconnect"}))
	controls.add_child(_online_disconnect)
	_new_library_label(_world_missions, "A credencial é apagada do campo ao conectar. Salvamentos, itens e progresso offline não são enviados para a arena.", CYAN)
	_world_maps.text = "Online PvE usa um servidor dedicado e progresso separado. Nesta arena, viagens, classe e alterações do perfil offline ficam bloqueadas. O MMO completo e o protocolo do serviço original não são reproduzidos."
	_update_online_connect_controls()
