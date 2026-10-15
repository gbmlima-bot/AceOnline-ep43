extends SceneTree
## Original meshes/textures, source coordinate profiles, viewer bindings and F2.

const Assets = preload("res://scripts/original_asset.gd")
const Props = preload("res://scripts/original_props.gd")
const PROFILE := "res://assets/original_3d/runtime_scene.json"

var checks := 0
var failures: Array[String] = []
var scene: Node
var skipped_gpu_getters := 0
var verified_gpu_getters := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(PROFILE))
	_check(parsed is Dictionary, "runtime profile is readable in the exported resource path")
	if not parsed is Dictionary:
		_report()
		return
	var profile: Dictionary = parsed
	_check(profile.get("gear_profiles", []).size() == 4, "four original GEAR models are available")
	for gear: Dictionary in profile.get("gear_profiles", []):
		_test_resource(gear, true)
	for key: String in ["terrain", "sky", "clouds"]:
		_test_resource(profile.get(key, {}), false)
	_test_invalid_resource()
	_test_original_props()
	scene = (load("res://main.tscn") as PackedScene).instantiate()
	root.add_child(scene)
	await process_frame
	scene.set_process(false)
	scene.set_physics_process(false)
	_check(scene.model.gear_id == "12003100" and scene.ship.get_meta("original_source_id", "") == _equipped_visual_id(scene), "flight starts with the owned original I-GEAR armor")
	_check(scene.original_world.get_meta("original_source_id", "") == "3002", "original terrain is mounted in the live scene")
	_check(is_instance_valid(scene.original_props) and scene.original_props.get_parent() == scene.original_world, "original props are mounted under the identity terrain root")
	_check(int(scene.original_props.get_meta("source_instance_count", 0)) == 911 and int(scene.original_props.get_meta("source_model_count", 0)) == 31, "live scenery retains911 original placements across31 source models")
	_check(scene.original_props.find_children("*", "CollisionObject3D", true, false).is_empty(), "render meshes stay separate from deterministic world collision")
	_check(is_instance_valid(scene.original_sky) and is_instance_valid(scene.original_clouds), "original sky and clouds are mounted in the live scene")
	_check(scene.exhausts.is_empty(), "unextracted exhaust effects do not use replacement geometry")
	_check(not scene.find_child("OriginalPlaceholderGear", true, false), "the procedural placeholder GEAR is absent")
	var environment: WorldEnvironment = scene.get_node("OriginalAssetViewerEnvironment")
	_check(environment.environment.sky == null, "no generated sky substitutes the original sky mesh")
	_test_sky(scene.original_sky, false)
	_test_sky(scene.original_clouds, true)
	_check(scene.legacy_hud._map_camera.cull_mask == 1, "top-down terrain map excludes the sky render layer")
	scene._process(1.0 / 60.0)
	_check(scene.original_sky.position.is_equal_approx(scene.camera.position), "original sky follows the main camera")
	_check(scene.original_clouds.position.is_equal_approx(scene.camera.position), "original clouds follow the main camera")
	var position: Vector3 = scene.model.position
	var orientation: Quaternion = scene.model.orientation
	var energy: float = scene.model.boost_energy
	var expected_order := ["12000100", "12001100", "12002100", "12003100"]
	for source_id: String in expected_order:
		_action("cycle_gear")
		await process_frame
		var visual_source := _equipped_visual_id(scene)
		_check(scene.ship.get_meta("original_source_id", "") == visual_source, "F2 loads owned native GEAR armor for " + source_id)
		_check(scene.ship.position.is_equal_approx(position) and scene.ship.quaternion.is_equal_approx(orientation), "GEAR switching preserves the live flight pose")
		_check(absf(scene.model.speed) <= scene.model.booster_speed and is_equal_approx(scene.model.boost_energy, energy) and scene.model.gear_id == source_id, "GEAR switching applies the selected original engine limits and preserves thermal state")
		_check(scene.legacy_hud._preview_model.get_meta("original_source_id", "") == visual_source, "inventory previews the same owned native GEAR armor")
		_check(scene.legacy_hud._preview_viewport.get_child_count() == 4, "replacing the preview does not accumulate models, cameras or lights")
		_check(scene.legacy_hud._inventory_hint.text.contains("ORIGINAL"), "inventory identifies the original artwork")
		_check(scene.ship.scale == Vector3.ONE, "the live source model is not normalized to a replacement size")
	var selected_visual := str(scene.ship.get_meta("original_source_id", ""))
	scene.legacy_hud._chat_input.grab_focus()
	_action("cycle_gear")
	await process_frame
	_check(scene.ship.get_meta("original_source_id", "") == selected_visual, "chat focus masks F2 and keeps the selected model")
	scene.legacy_hud._chat_input.release_focus()
	scene._reset_flight()
	_check(scene.model.position.is_equal_approx(scene.map_spawn), "original geometry preserves the current-map reset contract")
	_check(scene.ship.position.is_equal_approx(scene.model.position), "the source mesh root follows the model reset position")
	scene.queue_free()
	await process_frame
	_report()


func _equipped_visual_id(active_scene: Node) -> String:
	var armor: Dictionary = active_scene.combat_runtime.inventory.armor_appearance()
	return str(armor.get("model_id", active_scene.model.gear_id)) if bool(armor.get("available", false)) else str(active_scene.model.gear_id)


func _test_resource(profile: Dictionary, gear: bool) -> void:
	var source_id := str(profile.get("source_id", ""))
	var result: Dictionary = Assets.instantiate(profile)
	_check(result.errors.is_empty(), "original resource loads without fallback: " + source_id)
	if result.node == null:
		return
	var bounds: AABB = result.bounds
	var minimum := _vector(profile.get("expected_aabb_min", []))
	var maximum := _vector(profile.get("expected_aabb_max", []))
	_check(bounds.position.distance_to(minimum) < 0.02 and bounds.end.distance_to(maximum) < 0.02, "imported AABB matches the documented source transform: " + source_id)
	_check(int(result.mesh_count) == int(profile.get("expected_mesh_count", result.mesh_count)), "original mesh count: " + source_id)
	var mesh_nodes: Array[MeshInstance3D] = []
	_collect_meshes(result.node, mesh_nodes)
	var triangles := 0
	var texture_count := 0
	for mesh_node: MeshInstance3D in mesh_nodes:
		for surface in range(mesh_node.mesh.get_surface_count()):
			var arrays: Array = mesh_node.mesh.surface_get_arrays(surface)
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			triangles += int((indices.size() if not indices.is_empty() else vertices.size()) / 3)
			var material: Material = mesh_node.get_active_material(surface)
			_check(material is BaseMaterial3D, "converted surface has its source material: " + source_id)
			if material is BaseMaterial3D:
				_check(material.albedo_texture != null, "converted surface retains an original texture: " + source_id)
				if material.albedo_texture:
					texture_count += 1
					_check(material.albedo_texture.get_width() > 0 and material.albedo_texture.get_height() > 0, "source texture dimensions are nonzero: " + source_id)
	_check(triangles == int(profile.get("expected_triangles", 0)), "original triangle count: " + source_id)
	_check(texture_count > 0, "at least one original texture is bound: " + source_id)
	if gear:
		var alignment: Node3D = result.node.get_node("SourceAlignment")
		_check(alignment.transform.is_equal_approx(Transform3D.IDENTITY), "no second handedness, heading or unit transform is applied: " + source_id)
		var axes: Dictionary = profile.get("orientation", {})
		_check(axes.get("forward") == "-Z" and axes.get("up") == "+Y" and axes.get("heading_baked") == true, "source heading contract is explicit, not inferred from silhouette: " + source_id)
		_test_preview_framing(bounds, source_id)
	result.node.free()


func _test_preview_framing(bounds: AABB, source_id: String) -> void:
	var rotation := Quaternion.from_euler(Vector3(0, 0.35, 0))
	var viewport_size := Vector2(266, 177)
	var framing: Dictionary = Assets.preview_camera(bounds, viewport_size, rotation)
	var back: Vector3 = (framing.position - framing.target).normalized()
	var right := Vector3.UP.cross(back).normalized()
	var up := back.cross(right).normalized()
	var tangent_y := tan(deg_to_rad(float(framing.fov)) / 2)
	var tangent_x := tangent_y * viewport_size.x / viewport_size.y
	for index in range(8):
		var point := Basis(rotation) * bounds.get_endpoint(index)
		var to_camera: Vector3 = framing.position - point
		var depth := to_camera.dot(back)
		var centered: Vector3 = point - framing.target
		_check(depth > 0 and absf(centered.dot(right)) < depth * tangent_x and absf(centered.dot(up)) < depth * tangent_y, "preview frustum includes original AABB corner %d: %s" % [index, source_id])


func _test_sky(node: Node, cloud: bool) -> void:
	var meshes: Array[MeshInstance3D] = []
	_collect_meshes(node, meshes)
	for mesh_node: MeshInstance3D in meshes:
		_check(mesh_node.layers == 2, "sky/cloud geometry is isolated from the terrain minimap")
		for surface in range(mesh_node.mesh.get_surface_count()):
			var material: BaseMaterial3D = mesh_node.get_active_material(surface) as BaseMaterial3D
			_check(material != null and not material.no_depth_test, "original sky/cloud cannot overdraw foreground with depth testing disabled")
			if material:
				if cloud:
					_check(material.transparency in [BaseMaterial3D.TRANSPARENCY_ALPHA, BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS] and material.shading_mode != BaseMaterial3D.SHADING_MODE_UNSHADED, "original clouds retain alpha blending and lighting")
				else:
					_check(material.depth_draw_mode == BaseMaterial3D.DEPTH_DRAW_DISABLED and material.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED, "original sky remains unlit and does not write foreground depth")


func _test_invalid_resource() -> void:
	var missing: Dictionary = Assets.instantiate({"resource_path": "res://assets/not_present.glb"})
	_check(missing.node == null and not missing.errors.is_empty(), "missing original resources produce an error, not generated artwork")
	var ui: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets/legacy_ui/manifest.json"))
	var wrong: Dictionary = Assets.instantiate({"resource_path": ui.entries[0].path})
	_check(wrong.node == null and not wrong.errors.is_empty(), "texture resources are rejected as source mesh scenes")


func _test_original_props() -> void:
	var result: Dictionary = Props.instantiate()
	_check(result.errors.is_empty(), "original scenery loads without replacement meshes")
	_check(int(result.instance_count) == 911 and int(result.model_count) == 31, "scenery loads all911 placements and31 original models")
	var placements: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets/original_props/placements.json"))
	var fixture_values: Array = []
	var fixture_index := -1
	for model: Dictionary in placements.models:
		if int(model.code) != 3002300:
			continue
		for index in range(model.placements.size()):
			if int(model.placements[index].source_record_index) == 2:
				fixture_values = model.placements[index].transform_columns
				fixture_index = index
	# Independent direct read of3002.dat record2, offset3158344, not the converter.
	var expected := Transform3D(Basis(Vector3(-0.7845001372706893, 0, 0.6201286436073322), Vector3.UP, Vector3(-0.6201286436073322, 0, -0.7845001372706893)), Vector3(-5008.332061767578, 84.16123962402344, -706.85302734375))
	_check(fixture_index >= 0 and fixture_values.size() == 12, "independent nonaxial source placement fixture is present")
	if fixture_values.size() == 12:
		_check(Vector3(float(fixture_values[9]), float(fixture_values[10]), float(fixture_values[11])).distance_to(expected.origin) < 0.001, "source fixture origin matches the independently decoded centered map")
		_check(Vector3(float(fixture_values[0]), float(fixture_values[1]), float(fixture_values[2])).distance_to(expected.basis.x) < 0.00001 and Vector3(float(fixture_values[6]), float(fixture_values[7]), float(fixture_values[8])).distance_to(expected.basis.z) < 0.00001, "source fixture preserves the nonaxial RH rotation without a ship heading")
	var batches := 0
	var rendered_instances := 0
	var model_codes: Dictionary = {}
	var alpha_by_code: Dictionary = {}
	for source_model: Dictionary in placements.models:
		alpha_by_code[int(source_model.code)] = int(source_model.get("source_mapobjectinfo", {}).get("alpha", 0)) != 0
	if result.node != null:
		for batch: Node in result.node.get_children():
			if not batch is MultiMeshInstance3D:
				continue
			batches += 1
			var code := int(batch.get_meta("source_code", 0))
			if not model_codes.has(code):
				rendered_instances += batch.multimesh.instance_count
				model_codes[code] = true
			_check(batch.layers == 1, "original props are included in the local terrain minimap")
			for surface in range(batch.multimesh.mesh.get_surface_count()):
				var material: Material = batch.multimesh.mesh.surface_get_material(surface)
				_check(material != null, "original material is retained for each source surface")
				if bool(alpha_by_code.get(code, false)):
					_check(material is ShaderMaterial, "OMI alpha1 uses original alpha test plus blending")
					if material is ShaderMaterial:
						_check(is_equal_approx(float(material.get_shader_parameter("alpha_reference")), 127.0 / 255.0), "original alpha reference remains127/255")
						var texture: Texture2D = material.get_shader_parameter("original_albedo")
						_check(texture != null, "alpha-tested original scenery retains its texture")
				else:
					_check(material is BaseMaterial3D, "OMI alpha0 retains an opaque source material")
			if int(batch.get_meta("source_code", 0)) == 3002300 and fixture_index >= 0:
				if DisplayServer.get_name() == "headless" and batch.multimesh.buffer.is_empty():
					# DummyRenderingServer returns identity/empty for GPU buffers.
					# Source fixtures still run; a real renderer checks this getter.
					skipped_gpu_getters += 1
				else:
					var actual: Transform3D = batch.multimesh.get_instance_transform(fixture_index)
					verified_gpu_getters += 1
					_check(actual.origin.distance_to(expected.origin) < 0.001 and actual.basis.x.distance_to(expected.basis.x) < 0.00001 and actual.basis.z.distance_to(expected.basis.z) < 0.00001, "MultiMesh receives the independently verified original placement")
		_check(batches >= 31 and model_codes.size() == 31 and rendered_instances == 911, "all31 source model codes represent exactly911 objects without counting submeshes twice")
		result.node.free()


func _collect_meshes(node: Node, meshes: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D:
		meshes.append(node)
	for child: Node in node.get_children():
		_collect_meshes(child, meshes)


func _vector(value: Array) -> Vector3:
	return Vector3(float(value[0]), float(value[1]), float(value[2])) if value.size() >= 3 else Vector3.ZERO


func _action(action: String) -> void:
	var event := InputEventAction.new()
	event.action = action
	event.pressed = true
	Input.parse_input_event(event)


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)


func _report() -> void:
	for failure: String in failures:
		printerr(JSON.stringify({"suite": "original_assets", "failure": failure}))
	print(JSON.stringify({"suite": "original_assets", "checks": checks, "failures": failures.size(), "gpu_placement_getters_verified": verified_gpu_getters, "gpu_placement_getters_skipped_dummy": skipped_gpu_getters, "status": "pass" if failures.is_empty() else "fail"}))
	quit(0 if failures.is_empty() else 1)
