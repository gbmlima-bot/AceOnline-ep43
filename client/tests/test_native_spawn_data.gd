extends SceneTree
const Data = preload("res://scripts/native_spawn_data.gd")
var checks := 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_coordinates_and_identity()
	_test_native_gates()
	_test_invalid_records()
	_test_regions()
	_test_real_catalog()
	print(JSON.stringify({"suite":"native-spawn-data","checks":checks,"failures":failures.size(),"scope":"verified_DAT_type6_positions;SMA_regions_blocked;explicit_local_channel_adapter_required"}))
	for message: String in failures:printerr(JSON.stringify({"suite":"native-spawn-data","failure":message}))
	quit(0 if failures.is_empty() else 1)


func _row() -> Dictionary:
	return {"map_id":3004,"event_id":7,"monster_uid":2000000,"object_code":3018500,"position_native":[100.0,20.0,200.0],"direction_native":[0.0,0.0,1.0],"up_native":[0.0,1.0,0.0],"event_type":6,"event_enabled":true,"event_enabled_raw":1,"body_condition_raw":2,"is_city_war_raw":0,"parameters":[7,0,10],"next_event_index":3018500,"source":{"id":"dat:3004","offset":44,"size":112,"record_index":0,"sha256":"a".repeat(64)}}


func _catalog(rows: Array = []) -> Dictionary:
	return {"schema_version":1,"source_files":[{"id":"dat:3004","archive_path":"Res-map/3004.dat","sha256":"b".repeat(64),"size":1000,"entry_offset":44,"object_count":8,"tile_count_x":8,"tile_count_z":16,"tile_size_native":40.0}],"object_spawns":rows,"region_spawns":[]}


func _maps(influence: int = 1001) -> Dictionary:
	return {3004:{"MapIndex":3004,"Dat":3004,"MapInfluenceType":influence,"project":{"tile_count_x":8,"tile_count_z":16,"tile_size":40}}}


func _monsters(bell: int = 1) -> Dictionary:
	return {2000000:{"MonsterUnitKind":2000000,"Belligerence":bell}}


func _fixture(row: Dictionary, maps: Dictionary = {}, monsters: Dictionary = {}) -> RefCounted:
	var data := Data.new()
	_check(data.configure(_catalog([row]),_maps() if maps.is_empty() else maps,_monsters() if monsters.is_empty() else monsters).get("ok",false), "isolated source fixture configures")
	return data


func _test_coordinates_and_identity() -> void:
	var row := _row()
	var data: RefCounted = _fixture(row)
	var result: Dictionary = data.object_spawn_profiles(3004)
	_check(result.ok and result.records.size() == 1, "ordinary original object yields one read-only profile")
	var profile: Dictionary = result.records[0]
	_check(profile.position == Vector3(-60,20,120) and profile.direction == Vector3(0,0,-1) and profile.up == Vector3(0,1,0), "native source grid centers X and reverses centered Z exactly once")
	_check(profile.position_native == row.position_native and profile.source_data == row and profile.source == row.source, "exact source position and raw source bytes identity remain available")
	_check(profile.source_placement_id == "dat:3004:0" and profile.source_uid == 2000000 and profile.monster_code == 2000000, "placement identity uses source record and actual MonsterUID, never decorative object code")
	_check(profile.respawn_seconds == 10 and profile.tick_seconds == 1.0 and profile.initial_last_timestamp_seconds == 0.0 and profile.one_alive_per_placement, "native seconds, one-second tick and ordinary zero initial timestamp are preserved")
	_check(result.requires_local_channel_adapter and profile.requires_local_channel_adapter and result.unverified_runtime_gates.has("channel_monster_capacity"), "unverified live channel gates require an explicit adapter")
	_check(not result.catalog_verified and result.source_catalog_sha256.is_empty(), "fixture data cannot claim the pinned production checksum")
	profile.source_data.position_native[0] = 999.0
	result.records.clear()
	row.position_native[0] = 888.0
	_check(data.object_spawn_profiles(3004).records[0].position_native[0] == 100.0 and data.object_spawn_profiles(3004).records[0].source_data.position_native[0] == 100.0, "caller edits cannot mutate cached validated profiles")
	row = _row()
	row.event_enabled = false
	row.event_enabled_raw = 0
	row.body_condition_raw = 99
	data = _fixture(row)
	profile = data.object_spawn_profiles(3004).records[0]
	_check(profile.respawn_seconds == 10 and profile.tick_seconds == 1.0 and not profile.source_data.event_enabled and profile.source_data.body_condition_raw == 99, "type6 ignores event-enabled/body flags instead of inventing new spawn gates")
	row.parameters[2] = 0
	data = _fixture(row)
	_check(data.object_spawn_profiles(3004).blocked_records[0].source_data.parameters[2] == 0 and data.object_spawn_profiles(3004).blocked_reasons.has("native_zero_interval_local_adapter_not_enabled"), "source zero interval remains zero metadata while conservative local scheduler opt-in is blocked")
	var maps := _maps()
	maps[3004] = {"map_id":3004,"source_map_info":maps[3004]}
	_check(_fixture(_row(),maps).object_spawn_profiles(3004).records.size() == 1, "existing world definition source_map_info is supported")


func _test_native_gates() -> void:
	for influence: int in [0,1001,1999,2001,2999]:
		_check(_fixture(_row(),_maps(influence)).object_spawn_profiles(3004).records.size() == 1, "ordinary verified map influence allowed:%d" % influence)
	for influence: int in [999,1000,2000,3000,4999,5000,5999,6000,6001,6999,7000,7999,8000,9001]:
		var result: Dictionary = _fixture(_row(),_maps(influence)).object_spawn_profiles(3004)
		_check(result.records.is_empty() and result.blocked_records.size() == 1, "special/unverified map influence fails closed:%d" % influence)
	for bell: int in [10,12,13,18,19,29]:
		_check(_fixture(_row(),_maps(),_monsters(bell)).object_spawn_profiles(3004).blocked_reasons.has("native_war_spawn_state_not_implemented"), "war/strategy/teleport state cannot become an ordinary local spawn:%d" % bell)
	for bell: int in [30,31,255]:
		_check(_fixture(_row(),_maps(),_monsters(bell)).object_spawn_profiles(3004).blocked_reasons.has("native_special_monster_spawn_state_not_implemented"), "Infinity/unknown special monster state cannot become ordinary spawn:%d" % bell)
	for boss: int in [1,10,105]:
		var row := _row()
		row.is_city_war_raw = boss
		_check(_fixture(row).object_spawn_profiles(3004).blocked_reasons.has("native_object_boss_initial_timer_not_implemented"), "boss/raw nonboolean flags preserve unsupported native initial timer:%d" % boss)
	var data := Data.new()
	data.configure(_catalog([_row()]),{},_monsters())
	_check(data.object_spawn_profiles(3004).blocked_reasons.has("current_map_unavailable"), "missing current map cannot acquire an invented layout")
	data.configure(_catalog([_row()]),_maps(),{})
	_check(data.object_spawn_profiles(3004).blocked_reasons.has("current_monster_unavailable"), "missing current MonsterUID cannot acquire substitute NPC data")
	var row := _row()
	row.map_id = 8001
	var catalog := _catalog([row])
	var map: Dictionary = _maps()[3004]
	map.MapIndex = 8001
	map.Dat = 8001
	data.configure(catalog,{8001:map},_monsters())
	_check(data.object_spawn_profiles(8001).blocked_reasons.has("native_tutorial_spawn_requires_script"), "native tutorial map skips automatic creation")


func _test_invalid_records() -> void:
	for patch: Dictionary in [{"position_native":[-1,0,0]},{"position_native":[321,0,0]},{"position_native":[0,0,641]},{"position_native":[NAN,0,0]},{"position_native":[0,0]},{"direction_native":[0,0,0]},{"parameters":[7,0,-1]},{"parameters":[7,0,1.5]},{"event_type":5},{"event_id":8},{"source":{"id":"dat:3004","offset":999,"size":112,"record_index":0,"sha256":"a".repeat(64)}}]:
		var row := _row()
		row.merge(patch,true)
		_check(_fixture(row).object_spawn_profiles(3004).records.is_empty(), "malformed coordinates, timing, event or provenance fails closed:%s" % str(patch.keys()))
	var maps := _maps()
	maps[3004].project.tile_count_x = 16
	_check(_fixture(_row(),maps).object_spawn_profiles(3004).blocked_reasons.has("native_map_grid_mismatch"), "mismatched native grid cannot silently shift all positions")
	maps = _maps()
	maps[3004].Dat = 3005
	_check(_fixture(_row(),maps).object_spawn_profiles(3004).blocked_reasons.has("native_map_source_binding_mismatch"), "different DAT binding cannot silently load another layout")
	var data := Data.new()
	_check(not data.configure(_catalog([_row(),_row()]),_maps(),_monsters()).ok and not data.object_spawn_profiles(3004).ok, "duplicate placement identity invalidates the catalog instead of duplicating live NPCs")
	_check(not data.configure({},_maps(),_monsters()).ok and not data.object_spawn_profiles(3004).ok, "failed reconfiguration cannot expose previously valid records")


func _test_regions() -> void:
	var source := {"map_id":4001,"region_name":"native rectangle","monster_uid":2008200,"start_x_tile":23,"start_z_tile":55,"end_x_tile":34,"end_z_tile":74,"max_monsters":1,"respawn_count":1,"respawn_time":15,"spawn_type":1,"tile_size_native":40.0,"source":{"id":"sma:4001","record_index":0}}
	var catalog := _catalog()
	catalog.region_spawns = [source]
	var data := Data.new()
	data.configure(catalog,_maps(),_monsters())
	var result: Dictionary = data.region_spawn_profiles(4001)
	_check(result.records.is_empty() and result.blocked_records.size() == 1 and result.blocked_records[0].source_data == source and not result.blocked_records[0].has("position"), "SMA rectangle preserves native data and never becomes a fake center spawn")
	_check(data.diagnostics().supported_region_records == 0 and data.diagnostics().blocked_region_records == 1, "unported native regional positioning is explicit coverage, not guessed population")
	_check(data.object_spawn_profiles(4001).source_region_count == 1 and data.object_spawn_profiles(4001).blocked_reasons.has("native_region_position_algorithm_not_implemented"), "native-only region presence prevents generic fallback populations")


func _test_real_catalog() -> void:
	var maps: Dictionary = {}
	var monsters: Dictionary = {}
	for row: Dictionary in JSON.parse_string(FileAccess.get_file_as_string("res://assets/legacy_rules/maps.json")).records:maps[int(row.MapIndex)] = row
	for row: Dictionary in JSON.parse_string(FileAccess.get_file_as_string(Data.MONSTER_PATH)).records:monsters[int(row.MonsterUnitKind)] = row
	var data := Data.new()
	var summary: Dictionary = data.load_catalog(maps,monsters)
	_check(summary.ok and summary.catalog_verified and summary.source_catalog_sha256 == Data.CATALOG_SHA, "real native archive data and current monster catalog pass pinned SHA/provenance checks")
	if not summary.ok:return
	_check(summary.source_object_records == 3498 and summary.source_region_records == 5 and summary.blocked_region_records == 5 and summary.supported_region_records == 0, "real source coverage remains3498objects and5blockedSMA regions")
	_check(summary.supported_object_records == 2255 and summary.blocked_object_records == 1243 and summary.supported_object_maps == 95, "real pinned coverage accounts for2255ordinary placements and1243blocked objects")
	var source: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(Data.CATALOG_PATH))
	var files: Dictionary = {}
	for row: Dictionary in source.source_files:files[row.id] = row
	var covered := 0
	var placements: Dictionary = {}
	for map_id: int in maps:
		for profile: Dictionary in data.object_spawn_profiles(map_id).records:
			var row: Dictionary = profile.source_data
			var grid: Dictionary = files[row.source.id]
			var expected := Vector3(float(row.position_native[0])-float(grid.tile_count_x)*40.0/2.0,float(row.position_native[1]),-(float(row.position_native[2])-float(grid.tile_count_z)*40.0/2.0))
			_check(profile.position.is_equal_approx(expected) and profile.monster_uid == int(row.monster_uid) and profile.respawn_seconds == int(row.parameters[2]) and not placements.has(profile.source_placement_id), "real profile retains exact unique source placement:%s" % profile.source_placement_id)
			placements[profile.source_placement_id] = true
			covered += 1
	_check(covered == summary.supported_object_records and data.region_spawn_profiles(4001).blocked_records.size() == 5, "real per-map queries cover every supported object and preserve all native region rectangles")
	print(JSON.stringify({"suite":"native-spawn-data-coverage","source_object_records":summary.source_object_records,"supported_object_records":covered,"supported_object_maps":summary.supported_object_maps,"blocked_object_records":summary.blocked_object_records,"blocked_region_records":summary.blocked_region_records,"blocked_reasons":summary.blocked_reasons,"sha256":Data.CATALOG_SHA}))


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:failures.append(message)
