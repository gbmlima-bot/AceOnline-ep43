class_name LegacyGroup
extends Control
## Draws original Group.tex child records at a caller-supplied local origin.
## EP43 INFGroupManager.cpp:59-105 supplies crop, translation, scale and angle.
## Group metadata translation (often the editor position 100,100) is not applied.
## Type3 records are anchors; they never create artwork or interactive controls.
## Shipped 2025 groups audited here use angle=0, scale_percent=1 and image min=0.
## Nonzero-angle/percent behavior is a modern transform profile, not a verified
## D3DX runtime comparison: upstream bounds use percent while its draw path does
## not, and upstream GroupImage adds its minimum position during rendering.

const IMAGE_TYPE: int = 1
const CONTROL_TYPE: int = 3

var group_name: String = ""
var image_nodes: Dictionary = {}
var layout_bounds: Rect2 = Rect2()
var image_bounds: Rect2 = Rect2()
var build_errors: PackedStringArray = PackedStringArray()

var _control_rects: Dictionary = {}
var _owned_nodes: Array[Node] = []
var _has_layout_bounds: bool = false
var _has_image_bounds: bool = false


func build(group: Dictionary, texture_lookup: Callable) -> void:
	for child: Node in _owned_nodes:
		if is_instance_valid(child):
			remove_child(child)
			child.queue_free()
	_owned_nodes.clear()
	image_nodes.clear()
	_control_rects.clear()
	build_errors.clear()
	layout_bounds = Rect2()
	image_bounds = Rect2()
	_has_layout_bounds = false
	_has_image_bounds = false
	group_name = str(group.get("name", ""))
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_contents = false
	if not texture_lookup.is_valid():
		build_errors.append("invalid_texture_lookup")
		size = Vector2.ZERO
		return
	# Preserve the array order: GroupManager/GroupImage render records in sequence.
	var records: Array = group.get("nodes", [])
	for record: Dictionary in records:
		var record_type: int = int(record.get("type", -1))
		if record_type == CONTROL_TYPE:
			_add_control(record)
		elif record_type == IMAGE_TYPE:
			_add_image(record, texture_lookup)
		else:
			build_errors.append("unsupported_record_type:%d" % record_type)
	size = layout_bounds.size if _has_layout_bounds else Vector2.ZERO


func control_rect(target: String) -> Rect2:
	var rectangle: Rect2 = _control_rects.get(target, Rect2())
	return rectangle


func has_control(target: String) -> bool:
	return _control_rects.has(target)


func _add_control(record: Dictionary) -> void:
	var target: String = str(record.get("target_name", ""))
	var minimum: Vector2 = _vector2(record.get("control_min", []))
	var maximum: Vector2 = _vector2(record.get("control_max", []))
	var rectangle: Rect2 = Rect2(minimum, maximum - minimum).abs()
	# Empty target names occur in shipped groups and remain unnamed anchors.
	if not target.is_empty():
		_control_rects[target] = rectangle
	_merge_layout(rectangle)


func _add_image(record: Dictionary, texture_lookup: Callable) -> void:
	var texture_name: String = str(record.get("name", ""))
	var texture: Texture2D = texture_lookup.call(texture_name) as Texture2D
	if texture == null:
		build_errors.append("missing_texture:" + texture_name)
		return
	var crop: Rect2 = _source_rectangle(record.get("source_rect", []))
	if crop.size.x <= 0.0 or crop.size.y <= 0.0:
		build_errors.append("empty_source_rectangle:" + texture_name)
		return
	if not Rect2(Vector2.ZERO, texture.get_size()).encloses(crop):
		build_errors.append("source_rectangle_outside_texture:" + texture_name)
		return
	var atlas: AtlasTexture = AtlasTexture.new()
	atlas.atlas = texture
	atlas.region = crop
	atlas.filter_clip = true
	var sprite: TextureRect = TextureRect.new()
	sprite.name = texture_name.validate_node_name() if not texture_name.is_empty() else "GroupImage"
	sprite.texture = atlas
	sprite.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	sprite.stretch_mode = TextureRect.STRETCH_SCALE
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	sprite.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var translation: Vector2 = _vector2(record.get("translation", []))
	var center: Vector2 = _vector2(record.get("center", []))
	var scaling: Vector2 = _vector2(record.get("scaling", [1.0, 1.0]))
	var scale_percent: float = float(record.get("scale_percent", 1.0))
	var drawn_size: Vector2 = crop.size * scaling * scale_percent
	var reflected_origin: Vector2 = Vector2(minf(drawn_size.x, 0.0), minf(drawn_size.y, 0.0))
	sprite.position = translation + reflected_origin
	sprite.size = drawn_size.abs()
	sprite.flip_h = drawn_size.x < 0.0
	sprite.flip_v = drawn_size.y < 0.0
	# Center affects rotation, not scale. Scaling the pivot would shift zero-angle
	# frame tiles whose stored center happens to equal their translation.
	sprite.pivot_offset = center - reflected_origin
	sprite.rotation = float(record.get("angle", 0.0))
	sprite.set_meta("legacy_source_name", texture_name)
	sprite.set_meta("legacy_source_rect", crop)
	add_child(sprite)
	_owned_nodes.append(sprite)
	image_nodes[str(sprite.name)] = sprite
	var bounds: Rect2 = _transformed_bounds(sprite)
	_merge_layout(bounds)
	image_bounds = image_bounds.merge(bounds) if _has_image_bounds else bounds
	_has_image_bounds = true


func _merge_layout(rectangle: Rect2) -> void:
	layout_bounds = layout_bounds.merge(rectangle) if _has_layout_bounds else rectangle
	_has_layout_bounds = true


static func _vector2(value: Variant) -> Vector2:
	if value is Array and value.size() >= 2:
		return Vector2(float(value[0]), float(value[1]))
	return Vector2.ZERO


static func _source_rectangle(value: Variant) -> Rect2:
	if value is Array and value.size() >= 4:
		return Rect2(float(value[0]), float(value[1]), float(value[2]) - float(value[0]), float(value[3]) - float(value[1]))
	return Rect2()


static func _transformed_bounds(sprite: TextureRect) -> Rect2:
	var transform: Transform2D = sprite.get_transform()
	var first: Vector2 = transform * Vector2.ZERO
	var bounds: Rect2 = Rect2(first, Vector2.ZERO)
	for corner: Vector2 in [Vector2(sprite.size.x, 0.0), sprite.size, Vector2(0.0, sprite.size.y)]:
		bounds = bounds.expand(transform * corner)
	return bounds
