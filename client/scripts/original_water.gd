class_name OriginalWater
extends RefCounted
## Native two-tile water patches. Original pixels, alpha, selection, height and
## UV corners; static modern material, without original DirectX distortion.

static func instantiate(metadata: Dictionary, source_map: Dictionary) -> Node3D:
	var result := Node3D.new()
	result.name = "OriginalWaterPatches"
	if int(source_map.get("TileRenderingFlag", 1)) == 0:
		return result
	var data: Dictionary = metadata.get("water", {})
	var patches: Array = data.get("active_patch_indices_source_xz", [])
	var water_type := int(source_map.get("WaterType", 0))
	if water_type == 0 or patches.is_empty(): return result
	var registry_path := "res://assets/original_library/water/manifest.json"
	if not FileAccess.file_exists(registry_path): return result
	var registry: Variant = JSON.parse_string(FileAccess.get_file_as_string(registry_path))
	if not registry is Dictionary: return result
	var path := str(registry.get("by_water_type", {}).get(str(water_type), ""))
	if not ResourceLoader.exists(path): return result
	var texture := load(path) as Texture2D
	if texture == null: return result
	var grid: Dictionary = metadata.get("grid", {})
	var half_span := float(grid.get("tile_side", 256)) * float(grid.get("tile_size", 40)) / 2.0
	var size := float(data.get("patch_world_size", 80))
	var height := float(data.get("height", 0))
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uv := PackedVector2Array()
	var indices := PackedInt32Array()
	for pair: Array in patches:
		if pair.size() != 2: continue
		var x := float(pair[0]) * size - half_span
		var z := half_span - float(pair[1]) * size
		var start := vertices.size()
		vertices.append_array(PackedVector3Array([Vector3(x,height,z),Vector3(x+size,height,z),Vector3(x+size,height,z-size),Vector3(x,height,z-size)]))
		normals.append_array(PackedVector3Array([Vector3.UP,Vector3.UP,Vector3.UP,Vector3.UP]))
		uv.append_array(PackedVector2Array([Vector2(0,1),Vector2(1,1),Vector2(1,0),Vector2(0,0)]))
		indices.append_array(PackedInt32Array([start,start+2,start+1,start,start+3,start+2]))
	if vertices.is_empty(): return result
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var material := StandardMaterial3D.new()
	material.albedo_texture = texture
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.roughness = 1.0
	material.metallic = 0.0
	mesh.surface_set_material(0, material)
	var visual := MeshInstance3D.new()
	visual.mesh = mesh
	visual.layers = 1
	visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	result.add_child(visual)
	result.set_meta("source_patch_count", vertices.size() / 4)
	result.set_meta("source_texture", path)
	result.set_meta("source_water_type", water_type)
	result.set_meta("scope", "Original texture alpha and tile patches; static modern material, no native water animation shader")
	return result
