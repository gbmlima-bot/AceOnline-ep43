class_name OriginalProps
extends RefCounted
## Static original scenery. Placements already contain F*inverse(LookAtLH)*F.
## The loader adds imported mesh-relative transforms without a ship heading.

const ORIGINAL_ALPHA_SHADER: String = """shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_back;
uniform sampler2D original_albedo : source_color, filter_linear_mipmap, repeat_enable;
uniform vec4 original_factor : source_color = vec4(1.0);
uniform float alpha_reference = 0.4980392156862745;
uniform float original_roughness = 1.0;
uniform vec3 original_emission : source_color = vec3(0.0);
void fragment() {
	vec4 texel = texture(original_albedo, UV) * original_factor;
	if (texel.a < alpha_reference) { discard; }
	ALBEDO = texel.rgb;
	ALPHA = texel.a;
	ROUGHNESS = original_roughness;
	METALLIC = 0.0;
	EMISSION = original_emission;
}
"""

static func instantiate(layout_path: String = "res://assets/original_props/placements.json") -> Dictionary:
	var result_root: Node3D = Node3D.new()
	result_root.name = "OriginalScenery3002"
	var errors: PackedStringArray = PackedStringArray()
	var result: Dictionary = {"node": result_root, "errors": errors, "instance_count": 0, "model_count": 0}
	if not FileAccess.file_exists(layout_path):
		errors.append("Missing original scenery placements: " + layout_path)
		result["errors"] = errors
		return result
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(layout_path))
	if not parsed is Dictionary or int(parsed.get("schema_version", -1)) != 1:
		errors.append("Unsupported original scenery placement layout")
		result["errors"] = errors
		return result
	var models: Variant = parsed.get("models", [])
	if not models is Array:
		errors.append("Original scenery models must be an array")
		result["errors"] = errors
		return result
	var alpha_pipeline: Dictionary = parsed.get("alpha_pipeline", {})
	result_root.set_meta("source_instance_count", int(parsed.get("instance_count", 0)))
	result_root.set_meta("source_model_count", int(parsed.get("model_count", 0)))
	result_root.set_meta("matrix_layout", str(parsed.get("matrix_layout", "")))
	result_root.set_meta("coordinate_profile", str(parsed.get("coordinate_profile", "")))
	for model_value: Variant in models:
		if not model_value is Dictionary:
			errors.append("Invalid original scenery model record")
			continue
		var model: Dictionary = model_value
		var model_alpha_pipeline: Dictionary = alpha_pipeline.duplicate()
		var source_object: Dictionary = model.get("source_mapobjectinfo", {})
		if source_object.has("alpha"):
			model_alpha_pipeline["enabled"] = int(source_object["alpha"]) != 0
		var scene_path: String = str(model.get("scene", ""))
		var packed: PackedScene = load(scene_path) as PackedScene if ResourceLoader.exists(scene_path) else null
		if packed == null:
			errors.append("Original scenery scene does not load: " + scene_path)
			continue
		var records: Variant = model.get("placements", [])
		if not records is Array or records.is_empty():
			errors.append("Original scenery model has no placements: " + scene_path)
			continue
		var transforms: Array[Transform3D] = []
		for record_value: Variant in records:
			var record: Dictionary = record_value if record_value is Dictionary else {}
			var values: Variant = record.get("transform_columns", [])
			if not _valid_transform_values(values):
				errors.append("Invalid scenery transform in " + scene_path)
				continue
			var basis: Basis = Basis(Vector3(float(values[0]), float(values[1]), float(values[2])), Vector3(float(values[3]), float(values[4]), float(values[5])), Vector3(float(values[6]), float(values[7]), float(values[8])))
			if absf(basis.determinant() - 1.0) > 0.001 or not basis.is_equal_approx(basis.orthonormalized()):
				errors.append("Scenery transform is not an orthonormal rotation: " + scene_path)
				continue
			transforms.append(Transform3D(basis, Vector3(float(values[9]), float(values[10]), float(values[11]))))
		if transforms.is_empty():
			continue
		var scene: Node = packed.instantiate()
		var meshes: Array[Dictionary] = []
		_collect_meshes(scene, Transform3D.IDENTITY, meshes)
		if meshes.is_empty():
			errors.append("Original scenery scene contains no meshes: " + scene_path)
			scene.free()
			continue
		for mesh_record: Dictionary in meshes:
			var source: MeshInstance3D = mesh_record["node"]
			var relative: Transform3D = mesh_record["relative"]
			var multimesh: MultiMesh = MultiMesh.new()
			multimesh.transform_format = MultiMesh.TRANSFORM_3D
			multimesh.mesh = _mesh_with_original_materials(source, model_alpha_pipeline)
			multimesh.instance_count = transforms.size()
			for index: int in range(transforms.size()):
				multimesh.set_instance_transform(index, transforms[index] * relative)
			var batch: MultiMeshInstance3D = MultiMeshInstance3D.new()
			batch.name = ("Scenery_%s_%s" % [str(model.get("code", "")), str(source.name)]).validate_node_name()
			batch.multimesh = multimesh
			batch.material_override = _original_alpha_material(source.material_override, model_alpha_pipeline)
			batch.layers = 1
			batch.set_meta("source_code", int(model.get("code", 0)))
			batch.set_meta("source_placements", transforms.size())
			result_root.add_child(batch)
		result["instance_count"] = int(result["instance_count"]) + transforms.size()
		result["model_count"] = int(result["model_count"]) + 1
		scene.free()
	result["errors"] = errors
	return result


static func _valid_transform_values(values: Variant) -> bool:
	if not values is Array or values.size() != 12:
		return false
	for value: Variant in values:
		if not (value is int or value is float) or not is_finite(float(value)):
			return false
	return true


static func _collect_meshes(node: Node, parent_transform: Transform3D, meshes: Array[Dictionary]) -> void:
	var relative: Transform3D = parent_transform
	if node is Node3D:
		relative = parent_transform * (node as Node3D).transform
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		meshes.append({"node": node, "relative": relative})
	for child: Node in node.get_children():
		_collect_meshes(child, relative, meshes)


static func _mesh_with_original_materials(source: MeshInstance3D, alpha_pipeline: Dictionary) -> Mesh:
	# glTF normally stores materials on the Mesh; preserve optional scene overrides
	# too, because MultiMesh has no per-surface override API of its own.
	var mesh: Mesh = source.mesh
	var copied: ArrayMesh = mesh.duplicate() as ArrayMesh
	if copied == null:
		return mesh
	for surface: int in range(mesh.get_surface_count()):
		var material: Material = source.get_surface_override_material(surface)
		if material == null:
			material = mesh.surface_get_material(surface)
		copied.surface_set_material(surface, _original_alpha_material(material, alpha_pipeline))
	return copied


static func _original_alpha_material(material: Material, alpha_pipeline: Dictionary) -> Material:
	if material == null or not bool(alpha_pipeline.get("enabled", false)):
		return material
	var original: StandardMaterial3D = material as StandardMaterial3D
	if original == null or original.albedo_texture == null:
		return material
	# Source ObjRender.cpp:65-74 enables both >=127 alpha test and straight-alpha
	# blending. glTF BLEND carries the source image; discard completes its test.
	var shader: Shader = Shader.new()
	shader.code = ORIGINAL_ALPHA_SHADER
	var converted: ShaderMaterial = ShaderMaterial.new()
	converted.shader = shader
	converted.set_shader_parameter("original_albedo", original.albedo_texture)
	converted.set_shader_parameter("original_factor", original.albedo_color)
	converted.set_shader_parameter("original_roughness", original.roughness)
	converted.set_shader_parameter("original_emission", Vector3(original.emission.r, original.emission.g, original.emission.b))
	converted.set_shader_parameter("alpha_reference", float(alpha_pipeline.get("cutoff", 127.0 / 255.0)))
	converted.set_meta("source_alpha_test", "GREATER_EQUAL127/255")
	converted.set_meta("source_alpha_blend", "SRCALPHA/INVSRCALPHA")
	return converted
