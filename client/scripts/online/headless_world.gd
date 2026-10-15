extends RefCounted
## Authoritative map3002 queries with original numeric data only. No scene,
## renderer, audio, imported resource or original executable is loaded.

const CollisionModel = preload("res://scripts/world_model.gd")
const MAP_ID: int = 3002
const METADATA: String = "res://assets/original_world/3002_terrain.json"
const HEIGHTS: String = "res://assets/original_world/3002_heights.f32"
const WATER_FLAGS: String = "res://assets/original_world/3002_water_flags.u8"
const LANDING_FLAGS: String = "res://assets/original_world/3002_landing_flags.u8"
const PROP_LAYOUT: String = "res://assets/original_props/placements.json"
const SOURCE_ARCHIVE_SHA256: String = "8395f1f33dda8165f70f30d2a6ad094c5f64e144403fce98337e5012be795841"
const SOURCE_DAT_SHA256: String = "ddc85816f376c044dbd239ed3888eeb1e8e28dfc62db4d93cf6ff1d3cd6e2d92"
const COLLISION_CODES: Array[int] = [3001700, 3001800, 3002000, 3002600, 3002700, 3002800, 3002900, 3003000, 3003500, 3003800]
# Filled from the source files by the same audited release that produced the
# geometry. This pins presentation-free server data, not client-supplied paths.
const METADATA_SHA256: String = "715204dee6ff9aed2d51c55708964621651de21ad1d83d14567b64f3f3b3c8b3"
const PROP_LAYOUT_SHA256: String = "483ef21478f0f1f4c2a164d8e6f186b27d3b27fb1c807d8d6064b6916680cb29"

var map_id: int = 0
var last_error: String = "not_configured"
var source_map_info: Dictionary = {}
var _model: RefCounted
var _source_files: Array[String] = []


func configure(requested_map_id: int = MAP_ID) -> bool:
	if requested_map_id != MAP_ID:
		return _failure("unsupported_map")
	if not _matches(METADATA, METADATA_SHA256) or not _matches(PROP_LAYOUT, PROP_LAYOUT_SHA256):
		return _failure("native_metadata_missing_or_hash_mismatch")
	var metadata: Dictionary = _read_dictionary(METADATA)
	var layout: Dictionary = _read_dictionary(PROP_LAYOUT)
	var native: Dictionary = metadata.get("source_map_info", {})
	if int(metadata.get("resource_id", 0)) != MAP_ID or int(native.get("MapIndex", 0)) != MAP_ID or int(native.get("Dat", 0)) != MAP_ID or int(native.get("TileRenderingFlag", 0)) != 1:
		return _failure("native_map_identity_mismatch")
	if str(metadata.get("source_package", {}).get("sha256", "")) != SOURCE_ARCHIVE_SHA256 or str(metadata.get("source_resources", {}).get("dat", {}).get("sha256", "")) != SOURCE_DAT_SHA256 or str(layout.get("source", {}).get("sha256", "")) != SOURCE_DAT_SHA256:
		return _failure("native_source_identity_mismatch")
	if not _matches(HEIGHTS, str(metadata.get("grid", {}).get("heightmap_sha256", ""))) or not _matches(WATER_FLAGS, str(metadata.get("water", {}).get("active_tile_flags_sha256", ""))) or not _matches(LANDING_FLAGS, str(metadata.get("landing", {}).get("tile_flags_sha256", ""))):
		return _failure("native_grid_missing_or_hash_mismatch")
	var collision: Dictionary = _read_colliders(layout)
	if not bool(collision.get("ok", false)):
		return _failure(str(collision.get("error", "native_colliders_invalid")))
	metadata = metadata.duplicate(true)
	metadata["map_id"] = MAP_ID
	metadata["boundary_margin"] = 40.0
	metadata["flight_ceiling"] = float(native["ClientMaxAltitudeHeight"]) + float(native["WaterHeight"])
	metadata["ceiling_is_center_limit"] = true
	var candidate: RefCounted = CollisionModel.new()
	var errors: PackedStringArray = candidate.configure(metadata, FileAccess.get_file_as_bytes(HEIGHTS), collision.colliders, FileAccess.get_file_as_bytes(WATER_FLAGS), FileAccess.get_file_as_bytes(LANDING_FLAGS))
	if not errors.is_empty():
		return _failure("native_collision_configuration:" + ";".join(errors))
	_model = candidate
	map_id = MAP_ID
	source_map_info = native.duplicate(true)
	_source_files = [METADATA, HEIGHTS, WATER_FLAGS, LANDING_FLAGS, PROP_LAYOUT]
	_source_files.append_array(collision.files)
	last_error = ""
	return true


func is_configured() -> bool:
	return _model != null and map_id == MAP_ID and _model.is_configured()


func get_bounds() -> Dictionary:
	return _model.get_bounds() if is_configured() else {}


func sample_ground_height(x: float, z: float, include_water: bool = true) -> float:
	return _model.sample_ground_height(x, z, include_water) if is_configured() else NAN


func resolve_motion(from: Vector3, to: Vector3, options: Dictionary = {}) -> Dictionary:
	var radius: Variant = options.get("radius", 4.0)
	if not _valid_radius(radius) or not options.get("grounded", false) is bool:
		return _blocked_query(from, "invalid_motion_options")
	for key: Variant in options:
		if str(key) not in ["radius", "grounded"]:
			return _blocked_query(from, "invalid_motion_options")
	if not _valid_segment(from, to):
		return _blocked_query(from, "invalid_motion_segment")
	var result: Dictionary = _model.resolve_ground_motion(from, to, float(radius)) if bool(options.get("grounded", false)) else _model.resolve_motion(from, to, float(radius))
	return _with_distance(result, from, to)


func resolve_npc_motion(from: Vector3, to: Vector3, radius: float = 4.0) -> Vector3:
	# CombatModel.npc_motion_query has a Vector3 contract; all other public
	# movement APIs retain hit metadata for authoritative impact handling.
	return resolve_motion(from, to, {"radius": radius}).get("position", from)


func sweep_projectile(from: Vector3, to: Vector3, radius: float = 0.0, _context: Dictionary = {}) -> Dictionary:
	if not _valid_segment(from, to) or not _valid_radius(radius):
		return _blocked_query(from, "invalid_projectile_segment")
	return _with_distance(_model.trace_segment(from, to, radius), from, to)


func trace_segment(from: Vector3, to: Vector3, radius: float = 0.0) -> Dictionary:
	return sweep_projectile(from, to, radius)


func line_of_sight(from: Vector3, to: Vector3) -> bool:
	var hit: Dictionary = sweep_projectile(from, to)
	return not bool(hit.get("collided", true)) and not hit.has("error")


func probe_landing(position: Vector3, radius: float = 4.0, max_distance: float = 180.0, gear_id: String = "12003100") -> Dictionary:
	if not is_configured() or not position.is_finite() or not _valid_radius(radius) or is_nan(max_distance) or max_distance < 0.0:
		return {"ok": false, "reason": "world_not_ready_or_invalid_landing_query"}
	return _model.probe_landing(position, radius, max_distance, gear_id)


func ground_contact(position: Vector3, radius: float = 4.0) -> Dictionary:
	return probe_landing(position, radius, INF, "12002100")


func diagnostics() -> Dictionary:
	return {"configured": is_configured(), "map_id": map_id, "error": last_error, "collision_instances": _model.collider_count() if is_configured() else 0, "data_files": _source_files.duplicate(), "source_archive_sha256": SOURCE_ARCHIVE_SHA256, "source_dat_sha256": SOURCE_DAT_SHA256, "scope": "native_numeric_terrain_water_landing_Collision1;new_authoritative_room", "native_server_spawns_available": false, "room_encounters": "explicit_local_server_policy;actor_allowlist_is_owned_by_room"}


func _valid_segment(from: Vector3, to: Vector3) -> bool:
	return is_configured() and from.is_finite() and to.is_finite()


static func _valid_radius(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) >= 0.0 and float(value) <= 256.0


static func _with_distance(result: Dictionary, from: Vector3, to: Vector3) -> Dictionary:
	result["hit"] = bool(result.get("collided", false))
	result["distance"] = from.distance_to(to) * clampf(float(result.get("t", 1.0)), 0.0, 1.0)
	return result


static func _blocked_query(from: Vector3, reason: String) -> Dictionary:
	return {"collided": true, "hit": true, "position": from if from.is_finite() else Vector3.ZERO, "normal": Vector3.ZERO, "t": 0.0, "distance": 0.0, "kind": "unavailable", "error": reason}


func _failure(reason: String) -> bool:
	last_error = reason
	return false


static func _matches(path: String, expected: String) -> bool:
	return expected.length() == 64 and FileAccess.file_exists(path) and FileAccess.get_sha256(path) == expected


static func _read_dictionary(path: String) -> Dictionary:
	var value: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return value if value is Dictionary else {}


static func _read_colliders(layout: Dictionary) -> Dictionary:
	if int(layout.get("resource_id", 0)) != MAP_ID or int(layout.get("instance_count", 0)) != 911:
		return {"ok": false, "error": "native_prop_layout_identity"}
	var colliders: Array[Dictionary] = []
	var files: Array[String] = []
	var codes: Array[int] = []
	for row: Dictionary in layout.get("models", []):
		if int(row.get("source_mapobjectinfo", {}).get("collision", 0)) != 1:
			continue
		var code: int = int(row.get("code", 0))
		var collision: Dictionary = row.get("collision_mesh", {})
		var path: String = "res://assets/original_props/%08d_collision.json" % code
		if not code in COLLISION_CODES or str(collision.get("path", "")) != path or not _matches(path, str(collision.get("sha256", ""))):
			return {"ok": false, "error": "native_prop_collision_missing_or_hash_mismatch"}
		var geometry: Dictionary = _read_dictionary(path)
		if str(geometry.get("source_glb_sha256", "")) != str(row.get("sha256", "")) or not geometry.get("triangles") is Array or int(geometry.get("triangle_count", 0)) <= 0:
			return {"ok": false, "error": "native_prop_collision_identity"}
		files.append(path)
		codes.append(code)
		for placement: Dictionary in row.get("placements", []):
			var columns: Array = placement.get("transform_columns", [])
			if columns.size() != 12:
				return {"ok": false, "error": "native_prop_transform"}
			for component: Variant in columns:
				if not (component is int or component is float) or not is_finite(float(component)):
					return {"ok": false, "error": "native_prop_transform"}
			var basis: Basis = Basis(_vector(columns.slice(0, 3)), _vector(columns.slice(3, 6)), _vector(columns.slice(6, 9)))
			if absf(basis.determinant() - 1.0) > 0.0001:
				return {"ok": false, "error": "native_prop_transform"}
			colliders.append({"id": "%d:%s" % [code, placement.get("source_record_index", "")], "source_code": code, "collision": 1, "transform": Transform3D(basis, _vector(columns.slice(9, 12))), "triangles": geometry.triangles})
	codes.sort()
	if codes != COLLISION_CODES or colliders.size() != 31:
		return {"ok": false, "error": "native_prop_collision_incomplete"}
	return {"ok": true, "colliders": colliders, "files": files}


static func _vector(value: Array) -> Vector3:
	return Vector3(float(value[0]), float(value[1]), float(value[2]))
