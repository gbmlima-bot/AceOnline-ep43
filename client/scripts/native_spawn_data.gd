class_name NativeSpawnData
extends RefCounted
## Read-only native DAT object placements. This helper never creates actors.
## Channel capacity/enablement needs an explicit local adapter; regional SMA
## rectangles remain blocked until NPCGetCreatablePosition is fully ported.

const CATALOG_PATH := "res://assets/legacy_rules/native_spawns.json"
const CATALOG_SHA := "2ebbc60416a1ebcdc3f20824f967dd3d917fccd6a7e506b9dd42df8e54039aa4"
const ARCHIVE_SHA := "8395f1f33dda8165f70f30d2a6ad094c5f64e144403fce98337e5012be795841"
const INVENTORY_SHA := "a4430929aacaf158bc717b4f588f7e3d6ed5aaa6b409ebc36a7caf7ce62bbafa"
const MONSTER_PATH := "res://assets/original_library/catalogs/monsters.json"
const MONSTER_SHA := "57988a17a7c84bcf71815c60ba10f01f19ba18b532a1ce020737575565614cf6"
const RULES_COMMIT := "7c3e47ac47844e5c415d356a94d6201a0b9a38c4"
const RUNTIME_GATES := ["auto_create_monster_channel", "disabled_spawn_state", "channel_monster_capacity"]
static var _verified_catalog: Dictionary = {}
static var _monster_catalog_verified := false

var _objects: Dictionary = {}
var _blocked_objects: Dictionary = {}
var _regions: Dictionary = {}
var _summary: Dictionary = {}
var _ready := false
var _verified := false


func load_catalog(current_maps: Dictionary, current_monsters: Dictionary) -> Dictionary:
	_ready = false
	if _verified_catalog.is_empty():
		if not FileAccess.file_exists(CATALOG_PATH) or FileAccess.get_sha256(CATALOG_PATH) != CATALOG_SHA:
			return {"ok":false,"error":"native_spawn_catalog_hash_mismatch"}
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(CATALOG_PATH))
		if not parsed is Dictionary:
			return {"ok":false,"error":"native_spawn_catalog_invalid_json"}
		if parsed.get("source_archive", {}).get("sha256", "") != ARCHIVE_SHA or parsed.get("source_inventory_sha256", "") != INVENTORY_SHA or parsed.get("current_monster_catalog_sha256", "") != MONSTER_SHA or parsed.get("native_rules", {}).get("ep35_commit", "") != RULES_COMMIT:
			return {"ok":false,"error":"native_spawn_catalog_provenance_mismatch"}
		_verified_catalog = parsed
	if not _monster_catalog_verified:
		if not FileAccess.file_exists(MONSTER_PATH) or FileAccess.get_sha256(MONSTER_PATH) != MONSTER_SHA:
			return {"ok":false,"error":"native_spawn_monster_catalog_hash_mismatch"}
		_monster_catalog_verified = true
	var result := configure(_verified_catalog, current_maps, current_monsters)
	if not bool(result.get("ok", false)):return result
	_verified = bool(result.get("ok", false))
	return diagnostics()


func configure(catalog: Dictionary, current_maps: Dictionary, current_monsters: Dictionary) -> Dictionary:
	# Fixture entry point. Only load_catalog supplies the pinned production data.
	_ready = false
	_verified = false
	_objects.clear()
	_blocked_objects.clear()
	_regions.clear()
	_summary = {"source_object_records":0,"supported_object_records":0,"blocked_object_records":0,"source_region_records":0,"supported_region_records":0,"blocked_region_records":0,"blocked_reasons":{},"requires_local_channel_adapter":true,"unverified_runtime_gates":RUNTIME_GATES.duplicate()}
	if catalog.get("schema_version", 0) != 1 or not catalog.get("source_files") is Array or not catalog.get("object_spawns") is Array or not catalog.get("region_spawns") is Array or catalog.source_files.size() > 10000 or catalog.object_spawns.size() > 100000 or catalog.region_spawns.size() > 100000:
		return {"ok":false,"error":"native_spawn_catalog_schema_invalid"}
	var files: Dictionary = {}
	for value: Variant in catalog.source_files:
		if not value is Dictionary or not value.get("id") is String or files.has(value.id) or not _digest(value.get("sha256")) or _integer(value.get("size"), 2147483647) <= 0:
			return {"ok":false,"error":"native_spawn_source_file_invalid"}
		files[value.id] = value
	var seen: Dictionary = {}
	_summary.source_object_records = catalog.object_spawns.size()
	for value: Variant in catalog.object_spawns:
		if not value is Dictionary:
			return {"ok":false,"error":"native_spawn_object_row_invalid"}
		var row: Dictionary = value
		var map_id := _integer(row.get("map_id"), 65535)
		var reason := _object_block(row, files, current_maps, current_monsters)
		if reason.is_empty():
			var placement := _placement_id(row)
			if seen.has(placement):
				# Ambiguous placement identity must never produce two live actors.
				return {"ok":false,"error":"native_spawn_placement_duplicate"}
			seen[placement] = true
			var file: Dictionary = files[row.source.id]
			var position: Vector3 = _vector(row.position_native)
			var half_x: float = float(file.tile_count_x) * float(file.tile_size_native) / 2.0
			var half_z: float = float(file.tile_count_z) * float(file.tile_size_native) / 2.0
			var profile := {
				"map_id":map_id,"source_dat_map_id":map_id,"monster_uid":int(row.monster_uid),"monster_code":int(row.monster_uid),"source_uid":int(row.monster_uid),
				"source_placement_id":placement,"source_kind":"DAT_type6_object","source":row.source.duplicate(true),"source_data":row.duplicate(true),
				"position":Vector3(position.x-half_x,position.y,-(position.z-half_z)),"position_native":row.position_native.duplicate(),
				"direction":_flip_z(_vector(row.direction_native)),"up":_flip_z(_vector(row.up_native)),
				"respawn_seconds":int(row.parameters[2]),"tick_seconds":1.0,"initial_last_timestamp_seconds":0.0,"initial_timestamp_policy":"native_monotonic_uptime_zero_for_non_boss_objects",
				"one_alive_per_placement":true,"last_timestamp_on_delete":"current_monotonic_tick","requires_local_channel_adapter":true,"unverified_runtime_gates":RUNTIME_GATES.duplicate()
			}
			if not _objects.has(map_id):_objects[map_id] = []
			_objects[map_id].append(profile)
			_summary.supported_object_records += 1
		else:
			if not _blocked_objects.has(map_id):_blocked_objects[map_id] = []
			_blocked_objects[map_id].append({"reason":reason,"source_data":row.duplicate(true)})
			_summary.blocked_object_records += 1
			_count_reason(reason)
	_summary.source_region_records = catalog.region_spawns.size()
	for value: Variant in catalog.region_spawns:
		if not value is Dictionary:
			return {"ok":false,"error":"native_spawn_region_row_invalid"}
		var map_id := _integer(value.get("map_id"), 65535)
		if not _regions.has(map_id):_regions[map_id] = []
		# A rectangle has no exact spawn point. Do not synthesize its center or
		# randomize altitude without the original native clearance/water rules.
		_regions[map_id].append({"reason":"native_region_position_algorithm_not_implemented","source_data":value.duplicate(true)})
		_summary.blocked_region_records += 1
		_count_reason("native_region_position_algorithm_not_implemented")
	_ready = true
	return diagnostics()


func object_spawn_profiles(map_id: int) -> Dictionary:
	if not _ready:return {"ok":false,"error":"native_spawn_catalog_unavailable","records":[],"blocked_records":[],"blocked_reasons":{},"source_object_count":0,"source_region_count":0}
	var reasons: Dictionary = {}
	var blocked: Array = _blocked_objects.get(map_id, [])
	for row: Dictionary in blocked:reasons[row.reason] = int(reasons.get(row.reason, 0)) + 1
	var regions: Array = _regions.get(map_id, [])
	for row: Dictionary in regions:reasons[row.reason] = int(reasons.get(row.reason, 0)) + 1
	return {"ok":true,"map_id":map_id,"records":_objects.get(map_id, []).duplicate(true),"source_object_count":_objects.get(map_id, []).size()+blocked.size(),"source_region_count":regions.size(),"blocked_records":blocked.duplicate(true),"blocked_reasons":reasons,"source_catalog_sha256":CATALOG_SHA if _verified else "","catalog_verified":_verified,"requires_local_channel_adapter":true,"unverified_runtime_gates":RUNTIME_GATES.duplicate()}


func region_spawn_profiles(map_id: int) -> Dictionary:
	if not _ready:return {"ok":false,"error":"native_spawn_catalog_unavailable","records":[],"blocked_records":[]}
	return {"ok":true,"map_id":map_id,"records":[],"blocked_records":_regions.get(map_id, []).duplicate(true),"source_catalog_sha256":CATALOG_SHA if _verified else "","catalog_verified":_verified}


func diagnostics() -> Dictionary:
	var result: Dictionary = _summary.duplicate(true)
	result["ok"] = _ready
	result["catalog_verified"] = _verified
	result["source_catalog_sha256"] = CATALOG_SHA if _verified else ""
	result["supported_object_maps"] = _objects.size()
	return result


func _object_block(row: Dictionary, files: Dictionary, maps: Dictionary, monsters: Dictionary) -> String:
	var map_id := _integer(row.get("map_id"), 65535)
	var code := _integer(row.get("monster_uid"), 2147483647)
	if map_id <= 0 or not maps.has(map_id) or not maps[map_id] is Dictionary:return "current_map_unavailable"
	if code <= 0 or not monsters.has(code) or not monsters[code] is Dictionary:return "current_monster_unavailable"
	var monster: Dictionary = monsters[code]
	if _integer(monster.get("MonsterUnitKind"), 2147483647) != code:return "current_monster_identity_mismatch"
	var bell := _integer(monster.get("Belligerence"), 255)
	if bell < 0:return "native_monster_belligerence_unavailable"
	if bell >= 10 and bell <= 29:return "native_war_spawn_state_not_implemented"
	if bell >= 30:return "native_special_monster_spawn_state_not_implemented"
	var definition: Dictionary = maps[map_id]
	var map: Variant = definition.get("source_map_info", definition)
	if not map is Dictionary:return "native_map_definition_invalid"
	if _integer(map.get("MapIndex"), 65535) != map_id:return "current_map_identity_mismatch"
	var dat_id := _integer(map.get("Dat", map_id), 65535)
	if dat_id != 0 and dat_id != map_id:return "native_map_source_binding_mismatch"
	if map_id == 8001:return "native_tutorial_spawn_requires_script"
	var influence := _integer(map.get("MapInfluenceType"), 65535)
	if influence >= 5000 and influence <= 5999:return "native_infinity_spawn_state_not_implemented"
	if influence >= 6001 and influence <= 6999:return "native_outpost_automatic_spawn_disabled"
	if influence >= 7000 and influence <= 7999:return "native_arena_spawn_state_not_implemented"
	if influence != 0 and not (influence >= 1001 and influence <= 1999) and not (influence >= 2001 and influence <= 2999):return "native_map_influence_state_not_implemented"
	if _integer(row.get("event_type"), 255) != 6:return "native_object_event_type_invalid"
	var raw_boss := _integer(row.get("is_city_war_raw"), 255)
	if raw_boss < 0:return "native_object_boss_flag_invalid"
	if raw_boss != 0:return "native_object_boss_initial_timer_not_implemented"
	if not row.get("parameters") is Array or row.parameters.size() != 3:return "native_object_parameters_invalid"
	for value: Variant in row.parameters:
		if _integer(value, 32767) < 0:return "native_object_parameters_invalid"
	# Native zero means no elapsed-interval restriction, still evaluated on its
	# one-second channel tick. Keep its exact source value in blocked_records;
	# the local scheduler only opts in to strictly positive intervals.
	if int(row.parameters[2]) == 0:return "native_zero_interval_local_adapter_not_enabled"
	if _integer(row.get("event_id"),32767) != int(row.parameters[0]):return "native_object_event_identity_mismatch"
	var source: Variant = row.get("source")
	if not source is Dictionary or source.get("id", "") != "dat:%d" % map_id or not files.has(source.id):return "native_object_source_unavailable"
	var file: Dictionary = files[source.id]
	if _integer(source.get("size"),112) != 112 or _integer(source.get("offset"),2147483647) < 0 or _integer(source.get("record_index"),2147483647) < 0 or not _digest(source.get("sha256")) or int(source.offset)+112 > int(file.size) or int(source.record_index) >= _integer(file.get("object_count"),1000000):return "native_object_source_record_invalid"
	var tiles_x := _integer(file.get("tile_count_x"), 65535)
	var tiles_z := _integer(file.get("tile_count_z"), 65535)
	if tiles_x <= 0 or tiles_z <= 0 or not _number(file.get("tile_size_native")) or float(file.tile_size_native) != 40.0:return "native_object_source_grid_invalid"
	var project: Variant = map.get("project", {})
	if not project is Dictionary:return "native_map_grid_invalid"
	if not project.is_empty() and (_integer(project.get("tile_count_x"),65535) != tiles_x or _integer(project.get("tile_count_z"),65535) != tiles_z or not _number(project.get("tile_size")) or float(project.tile_size) != 40.0):return "native_map_grid_mismatch"
	if not _vector_valid(row.get("position_native")) or not _vector_valid(row.get("direction_native")) or not _vector_valid(row.get("up_native")):return "native_object_coordinates_invalid"
	var position := _vector(row.position_native)
	if position.x < 0.0 or position.z < 0.0 or position.x > tiles_x * 40.0 or position.z > tiles_z * 40.0:return "native_object_coordinates_outside_grid"
	if _vector(row.direction_native).is_zero_approx() or _vector(row.up_native).is_zero_approx():return "native_object_orientation_invalid"
	return ""


func _count_reason(reason: String) -> void:
	_summary.blocked_reasons[reason] = int(_summary.blocked_reasons.get(reason,0)) + 1


static func _placement_id(row: Dictionary) -> String:
	return "%s:%d" % [row.source.id,int(row.source.record_index)]


static func _integer(value: Variant, maximum: int) -> int:
	if not _number(value) or float(value) < 0.0 or float(value) > float(maximum) or float(value) != floor(float(value)):return -1
	return int(value)


static func _number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))


static func _digest(value: Variant) -> bool:
	if not value is String or value.length() != 64:return false
	for character: String in value:
		if not character in "0123456789abcdef":return false
	return true


static func _vector_valid(value: Variant) -> bool:
	if not value is Array or value.size() != 3:return false
	for component: Variant in value:
		if not _number(component):return false
	return _vector(value).is_finite()


static func _vector(value: Array) -> Vector3:
	return Vector3(float(value[0]),float(value[1]),float(value[2]))


static func _flip_z(value: Vector3) -> Vector3:
	return Vector3(value.x,value.y,-value.z)
