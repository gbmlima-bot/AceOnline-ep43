class_name OriginalAsset
extends RefCounted
## Loads converted client artwork as data. No procedural replacement or pose guess.
## All coordinate changes are explicit in the caller's documented asset profile.


static func instantiate(profile: Dictionary) -> Dictionary:
	var issues := PackedStringArray()
	var path := str(profile.get("resource_path", ""))
	if not path.begins_with("res://assets/") or not ResourceLoader.exists(path):
		issues.append("original_resource_missing:" + path)
		return {"node": null, "bounds": AABB(), "mesh_count": 0, "errors": issues}
	var resource := load(path)
	var visual: Node3D
	if resource is PackedScene:
		var instance: Node = resource.instantiate()
		if not instance is Node3D:
			instance.free()
			issues.append("original_scene_has_no_3d_root:" + path)
			return {"node": null, "bounds": AABB(), "mesh_count": 0, "errors": issues}
		visual = instance as Node3D
	elif resource is Mesh:
		var mesh_node := MeshInstance3D.new()
		mesh_node.mesh = resource
		visual = mesh_node
	else:
		issues.append("original_resource_is_not_scene_or_mesh:" + path)
		return {"node": null, "bounds": AABB(), "mesh_count": 0, "errors": issues}
	var container := Node3D.new()
	container.name = str(profile.get("name", "OriginalClientAsset")).validate_node_name()
	container.set_meta("original_resource_path", path)
	container.set_meta("original_source_id", str(profile.get("source_id", "")))
	container.set_meta("original_asset_profile", profile.duplicate(true))
	var alignment := Node3D.new()
	alignment.name = "SourceAlignment"
	container.add_child(alignment)
	alignment.add_child(visual)
	# Conversion may already bake handedness/axes. Identity is then stated in the
	# profile; this loader never infers facing from the silhouette or filename.
	alignment.position = _vector3(profile.get("position", [0, 0, 0]))
	alignment.rotation_degrees = _vector3(profile.get("rotation_degrees", [0, 0, 0]))
	alignment.scale = _vector3(profile.get("scale", [1, 1, 1]))
	var measurement := measure(container)
	var bounds: AABB = measurement.bounds
	if int(measurement.mesh_count) == 0 or not bounds.position.is_finite() or not bounds.size.is_finite() or bounds.size.length_squared() <= 0.000001:
		issues.append("original_asset_has_no_nonempty_mesh:" + path)
		container.free()
		return {"node": null, "bounds": AABB(), "mesh_count": 0, "errors": issues}
	container.set_meta("visual_bounds", bounds)
	container.set_meta("original_mesh_count", measurement.mesh_count)
	return {"node": container, "bounds": bounds, "mesh_count": measurement.mesh_count, "errors": issues}


static func preview_camera(bounds: AABB, viewport_size: Vector2, visual_rotation: Quaternion, vertical_fov: float = 36.0) -> Dictionary:
	# Fit every transformed AABB corner in the preview frustum. This changes the
	# viewer's camera only; original model vertices, scale and origin stay intact.
	# Adapted front three-quarter viewer angle; canonical source facing is -Z.
	var back := Vector3(0.55, 0.45, -1.0).normalized()
	var right := Vector3.UP.cross(back).normalized()
	var up := back.cross(right).normalized()
	var tangent_y := tan(deg_to_rad(vertical_fov) / 2.0)
	var tangent_x := tangent_y * viewport_size.x / maxf(1.0, viewport_size.y)
	var rotation := Basis(visual_rotation)
	var center := rotation * bounds.get_center()
	var distance := 0.1
	for index in range(8):
		var corner := rotation * bounds.get_endpoint(index) - center
		var required := maxf(absf(corner.dot(right)) / tangent_x, absf(corner.dot(up)) / tangent_y)
		distance = maxf(distance, corner.dot(back) + required)
	distance = distance * 1.12 + 0.2
	return {"position": center + back * distance, "target": center, "fov": vertical_fov, "far": maxf(100.0, distance * 4.0)}


static func measure(node: Node) -> Dictionary:
	var state := {"bounds": AABB(), "mesh_count": 0}
	_measure_children(node, Transform3D.IDENTITY, state)
	return state


static func _measure_children(node: Node, inherited: Transform3D, state: Dictionary) -> void:
	var transform := inherited
	if node is Node3D:
		transform = inherited * node.transform
	if node is MeshInstance3D and node.mesh != null:
		var local_bounds: AABB = transform * node.get_aabb()
		state.bounds = local_bounds if int(state.mesh_count) == 0 else (state.bounds as AABB).merge(local_bounds)
		state.mesh_count = int(state.mesh_count) + 1
	for child: Node in node.get_children():
		_measure_children(child, transform, state)


static func _vector3(value: Variant) -> Vector3:
	if value is Vector3:
		return value
	if value is Array and value.size() >= 3:
		return Vector3(float(value[0]), float(value[1]), float(value[2]))
	return Vector3.ZERO
