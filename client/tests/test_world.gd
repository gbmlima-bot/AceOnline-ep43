extends SceneTree
const World = preload("res://scripts/world_model.gd")
const Runtime = preload("res://scripts/world_runtime.gd")

var checks: int = 0
var failures: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	_test_height_diagonal()
	_test_swept_ridge_and_boundaries()
	_test_water_tiles()
	_test_object_sweeps_and_collision_flags()
	_test_invalid_data()
	_test_original_height_data()
	_test_ground_and_landing()
	_test_native_non_tile_model()
	_test_real_runtime_session()
	_report()

func _fixture(heights: Array, water: PackedByteArray = PackedByteArray(), colliders: Array = []) -> RefCounted:
	var model: RefCounted = World.new()
	var bytes: PackedByteArray = PackedByteArray()
	bytes.resize(heights.size() * 4)
	for index: int in range(heights.size()):
		bytes.encode_float(index * 4, float(heights[index]))
	var data: Dictionary = {"map_id": 1, "vertex_side": 3, "tile_size": 40.0, "water": {"height": 5.0}, "flight_ceiling": 100.0}
	var errors: PackedStringArray = model.configure(data, bytes, colliders, water)
	_check(errors.is_empty(), "valid deterministic fixture configures: " + str(errors))
	return model

func _test_height_diagonal() -> void:
	var world: RefCounted = _fixture([0,0,0,0,20,0,0,0,0])
	_check(is_equal_approx(world.sample_ground_height(-20, 20), 0.0), "collision uses original B-D diagonal rather than visual A-C/bilinear interpolation")
	_check(is_equal_approx(world.sample_ground_height(-10, 10), 10.0), "second collision triangle interpolates its original plane")
	_check(is_nan(world.sample_ground_height(41, 0)), "height query outside original grid is explicit")
	_check(is_equal_approx(world.sample_ground_height(40, -40), 0.0), "last grid edge stays queryable without index overflow")
	var hit: Dictionary = world.resolve_motion(Vector3(-20, 20, 20), Vector3(-20, -10, 20), 2.0)
	_check(hit.collided and hit.kind == "terrain" and is_equal_approx(hit.position.y, 2.001), "descending ship stops above original collision plane with clearance")
	_check((hit.normal as Vector3).is_equal_approx(Vector3.UP), "flat collision triangle gives upward normal")
	var unstuck: Dictionary = world.resolve_motion(Vector3(-20, -10, 20), Vector3(-20, -10, 20), 2.0)
	_check(unstuck.collided and unstuck.t == 0.0 and unstuck.position.y >= 2.0, "initial terrain penetration is resolved deterministically")

func _test_swept_ridge_and_boundaries() -> void:
	var world: RefCounted = _fixture([0,0,0,40,40,40,0,0,0])
	var hit: Dictionary = world.resolve_motion(Vector3(-35, 20, 0), Vector3(35, 20, 0), 2.0)
	_check(hit.collided and hit.kind == "terrain" and hit.position.x < -20.0, "sweep catches ridge even when both segment endpoints are above terrain")
	_check(is_equal_approx(hit.t, 13.0 / 70.0), "ridge contact time follows the exact piecewise plane")
	var flat: RefCounted = _fixture([0,0,0,0,0,0,0,0,0])
	var boundary: Dictionary = flat.resolve_motion(Vector3(0,20,0), Vector3(100,20,0), 4.0)
	_check(boundary.collided and boundary.kind == "boundary" and absf(boundary.position.x - 35.999) < 0.0001, "map boundary respects source width and ship radius")
	_check(boundary.normal == Vector3.LEFT, "boundary contact points inward")
	var ceiling: Dictionary = flat.resolve_motion(Vector3(0,90,0), Vector3(0,120,0), 2.0)
	_check(ceiling.collided and ceiling.kind == "boundary" and absf(ceiling.position.y - 97.999) < 0.0001, "configured source ceiling stops upward motion")
	var repeat: Dictionary = flat.resolve_motion(Vector3(0,90,0), Vector3(0,120,0), 2.0)
	_check(repeat == ceiling, "world queries are repeatable without a physics clock")

func _test_water_tiles() -> void:
	var flags: PackedByteArray = PackedByteArray([1,0,0,0])
	var world: RefCounted = _fixture([0,0,0,0,0,0,0,0,0], flags)
	_check(world.sample_ground_height(-20,20) == 5.0 and world.sample_ground_height(-20,20,false) == 0.0, "exact wet tile adds original water surface without altering terrain")
	_check(world.sample_ground_height(20,-20) == 0.0, "adjacent dry tile does not inherit an80unit render patch")
	var hit: Dictionary = world.resolve_motion(Vector3(-20,20,20), Vector3(-20,0,20), 2.0)
	_check(hit.collided and hit.kind == "water" and absf(hit.position.y - 7.001) < 0.0001, "water collision uses the project height and surface normal")

func _wall(collision: int) -> Dictionary:
	return {"id":"fixture_wall", "source_code":42, "collision":collision, "triangles":PackedVector3Array([Vector3(0,0,-10),Vector3(0,30,-10),Vector3(0,30,10),Vector3(0,0,-10),Vector3(0,30,10),Vector3(0,0,10)])}

func _test_object_sweeps_and_collision_flags() -> void:
	var world: RefCounted = _fixture([-100,-100,-100,-100,-100,-100,-100,-100,-100], PackedByteArray(), [_wall(1)])
	_check(world.collider_count() == 1, "OMICollision1 registers original triangle geometry")
	var hit: Dictionary = world.resolve_motion(Vector3(-20,10,0), Vector3(20,10,0), 2.0)
	_check(hit.collided and hit.kind == "object" and hit.object_id == "fixture_wall", "continuous sphere sweep hits object face without tunneling")
	_check(absf(hit.position.x + 2.001) < 0.0001 and hit.normal == Vector3.LEFT, "object face collision retains radius and opposing normal")
	var edge: Dictionary = world.trace_segment(Vector3(-20,10,11), Vector3(20,10,11), 2.0)
	_check(edge.collided and absf(edge.position.x + sqrt(3.0)) < 0.001, "sphere sweep catches triangle edge grazing outside the face")
	var corner: Dictionary = world.trace_segment(Vector3(-20,31,11), Vector3(20,31,11), 2.0)
	_check(corner.collided and absf(corner.position.x + sqrt(2.0)) < 0.001, "sphere sweep catches vertex grazing outside face and edge")
	var reverse: Dictionary = world.trace_segment(Vector3(20,10,0), Vector3(-20,10,0), 0.0)
	_check(reverse.collided and reverse.normal == Vector3.RIGHT, "object rays collide from both sides independent of render winding")
	var transparent: RefCounted = _fixture([-100,-100,-100,-100,-100,-100,-100,-100,-100], PackedByteArray(), [_wall(0), _wall(2)])
	_check(transparent.collider_count() == 0 and not transparent.resolve_motion(Vector3(-20,10,0),Vector3(20,10,0),2.0).collided, "objects withoutOMICollision1 are not promoted to collision by their visual bounds")

func _test_invalid_data() -> void:
	var world: RefCounted = World.new()
	_check(not world.configure({"vertex_side":3},PackedByteArray()).is_empty() and not world.is_configured(), "truncated height data is rejected before a world is configured")
	var bytes: PackedByteArray = PackedByteArray()
	bytes.resize(36)
	bytes.encode_float(0,NAN)
	_check(not world.configure({"vertex_side":3},bytes).is_empty(), "nonfinite source heights are rejected")
	var valid: RefCounted = _fixture([0,0,0,0,0,0,0,0,0])
	var bad: Dictionary = valid.resolve_motion(Vector3.ZERO,Vector3(INF,0,0))
	_check(bad.has("error") and (bad.position as Vector3).is_finite(), "invalid motion cannot inject nonfinite flight position")

func _test_original_height_data() -> void:
	var metadata: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets/original_world/3002_terrain.json"))
	metadata["flight_ceiling"] = 2230.0
	var bytes: PackedByteArray = FileAccess.get_file_as_bytes("res://assets/original_world/3002_heights.f32")
	var world: RefCounted = World.new()
	_check(world.configure(metadata,bytes).is_empty(), "complete original3002height data configures")
	_check(world.grid_side == 257 and world.tile_size == 40.0 and world.sample_ground_height(0,0,false) == -160.0, "original center sample and dimensions match the recovered native grid")
	var hit: Dictionary = world.resolve_motion(Vector3(0,100,0),Vector3(0,-200,0),4.0)
	_check(hit.collided and hit.kind == "terrain" and hit.position.y >= -156.0, "original terrain stops descent through its real center surface")
	var bounds: Dictionary = world.get_bounds()
	_check(bounds.min.x == -5120.0 and bounds.max.x == 5120.0 and bounds.max.y == 2230.0, "source map bounds and recovered source altitude limit are exposed")


func _test_ground_and_landing() -> void:
	var world: RefCounted = _fixture([0,0,0,0,10,0,0,0,0])
	var airport: PackedByteArray = PackedByteArray([1,0,0,0])
	var data: Dictionary = {"vertex_side":3,"tile_size":40.0}
	var bytes: PackedByteArray = PackedByteArray()
	bytes.resize(36)
	_check(world.configure(data,bytes,[],PackedByteArray(),airport).is_empty(), "landing fixture loads exact original tile flags")
	_check(world.probe_landing(Vector3(-20,179.9,20),4,180,"12003100").ok, "B-Gear can land on an enabled airport tile below source180threshold")
	_check(not world.probe_landing(Vector3(-20,180,20),4,180,"12003100").ok, "landing threshold is strict source center-to-ground distance<180")
	_check(not world.probe_landing(Vector3(20,10,-20),4,180,"12003100").ok, "B-Gear cannot land outside enabled original airport tiles")
	_check(world.probe_landing(Vector3(20,10,-20),4,180,"12002100").ok, "A-Gear can land on dry terrain outside an airport per source exception")
	var contact: Dictionary = world.resolve_ground_motion(Vector3(-20,4,20),Vector3(20,4,20),4)
	_check(not contact.collided and contact.position.y == 4.0 and contact.get("supported",false), "ground support does not emit a collision or collision damage")
	var wall: RefCounted = _fixture([0,0,0,0,0,0,0,0,0],PackedByteArray(),[_wall(1)])
	var blocked: Dictionary = wall.resolve_ground_motion(Vector3(-20,4,0),Vector3(20,4,0),2)
	_check(blocked.collided and blocked.kind == "object" and blocked.position.x < -2.0, "ground mode still sweeps original object meshes")
	var bounds: Dictionary = world.resolve_ground_motion(Vector3(20,4,0),Vector3(100,4,0),4)
	_check(bounds.collided and bounds.kind == "boundary", "ground mode retains map border collisions")
	var invalid: RefCounted = World.new()
	_check(not invalid.configure(data,bytes,[{"collision":1,"triangles":[]}]).is_empty(), "malformed collider geometry propagates a configure error")
	_check(not invalid.configure(data,bytes,[{"collision":1,"triangles":["bad",[0,1,0],[1,0,0]]}]).is_empty(), "malformed collider vertices cannot silently become zero vectors")
	var bad_bounds: Dictionary = data.duplicate()
	bad_bounds["boundary_margin"] = NAN
	_check(not invalid.configure(bad_bounds,bytes).is_empty(), "nonfinite world bounds are rejected")

func _test_real_runtime_session() -> void:
	var runtime: Node3D = Runtime.new()
	root.add_child(runtime)
	var configured: Dictionary = runtime.configure()
	_check(configured.ok and configured.map_count == 238 and configured.mission_count == 598 and configured.supported_mission_count == 537, "all238maps and597quests catalogued;537native missions compiled with explicit unsupported diagnostics")
	_check(int(configured.source_mission_count) == 597, "all597native quest records remain source data without claiming script support")
	var loaded: Dictionary = runtime.load_map(3002)
	_check(loaded.get("ok",false), "original3002terrain and collision geometry load atomically")
	if not loaded.get("ok",false):
		runtime.free()
		return
	var state: Dictionary = runtime.get_state()
	_check(runtime.get_bounds().min.x == -5080.0 and runtime.get_bounds().max.y == 2230.0, "runtime uses native40unit border margin and water-relative map ceiling")
	_check(state.collision_object_count > 0 and state.collision_gaps.is_empty(), "sourceCollision1 objects use available source triangle meshes")
	_check(state.npc_count >= 1 and state.portal_count == 2, "original3002portals and explicitly adapted sourceNPC3 interaction load")
	_check((state.missions as Array).size() <= 12 and not state.missions[0].has("dsl_ast"), "frame snapshots are paginated and omit597raw source ASTs")
	var available: Array[int] = []
	for map: Dictionary in state.map_catalog:
		if map.available:
			available.append(int(map.map_id))
	_check(available.has(3002) and available.has(3003) and available.has(3302), "three converted datasets are available through the extensible238map catalog")
	_check(not runtime.load_map(9999).ok and runtime.current_map_id == 3002, "missing faction-city destination never replaces the current world")
	_check(not runtime.accept_mission("102").ok, "native102is locked before prerequisite101")
	runtime.configure_player_profile({"influence":2})
	_check(not runtime.accept_mission("101").ok, "native quest faction requirement is enforced")
	runtime.configure_player_profile({"influence":1,"level":0})
	_check(not runtime.accept_mission("101").ok, "native quest minimum level is enforced")
	runtime.configure_player_profile({"level":9,"unit_kind":0})
	_check(not runtime.accept_mission("101").ok, "native quest class mask requirement is enforced")
	runtime.configure_player_profile({"unit_kind":1})
	runtime.interact_nearest(loaded.spawn_position)
	var first: Dictionary = runtime.accept_mission("101")
	_check(first.ok and first.mission.status == "completed", "native101dialogue completes immediately from source end_type0")
	_check(not runtime.claim_reward("101").ok, "immediate mission cannot claim a second time")
	var second: Dictionary = runtime.accept_mission("102")
	_check(second.ok and runtime.current_map_id == 3302 and second.mission.status == "active", "native102acceptance transfers to distinct original3302terrain")
	_check(str(runtime.current_map.visual_profile.props.layout_path).contains("/3302/props/"), "mission map uses its908source placements rather than3002poses")
	_check(not runtime.claim_reward("102").ok, "native102reward is unavailable before its actual multi-target objective")
	runtime.load_map(3002)
	runtime.record_target_destroyed(2028200,"offmap:life1")
	_check(_mission(runtime.get_state(),"102").objectives[0].current == 0, "native102kills in a different map do not satisfy mission-map requirements")
	runtime.load_map(3302)
	runtime.record_target_destroyed(2028200,"fighter:life1")
	_check(not runtime.record_target_destroyed(2028200,"fighter:life1").ok, "duplicate kill notification cannot advance quest twice")
	runtime.record_target_destroyed(2000000,"wrong:life1")
	for index: int in range(3):
		runtime.record_target_destroyed(2028100,"bomber%d:life1" % index)
	var mission: Dictionary = _mission(runtime.get_state(),"102")
	_check(mission.status == "ready" and mission.objectives[0].current == 1 and mission.objectives[1].current == 3, "native102requires exactly fighter2028200x1 and bomber2028100x3")
	var reward: Dictionary = runtime.claim_reward("102")
	_check(reward.ok and reward.reward.type == "mission_reward" and reward.reward.credits == 320 and reward.reward.experience == 91, "native102grants exact recovered320SPI and91XP")
	_check(runtime.current_map_id == 2001 and not runtime.claim_reward("102").ok, "native faction-city sentinel resolves converted city2001 and reward remains idempotent")
	var native_return: bool = false
	var reward_count: int = 0
	for event: Dictionary in runtime.drain_events():
		if event.type == "faction_city_return":
			native_return = not event.get("adaptation",true) and event.source_destination == 9999 and event.target_map == 2001
		if event.type == "mission_reward" and event.mission_id == "102":
			reward_count += 1
	_check(native_return and reward_count == 1, "event stream identifies native9999city mapping and one mission102reward")
	runtime.load_map(3002)
	var portal_id: String = "portal:3002:203"
	_check(not runtime.use_portal(portal_id).ok, "source portal refuses interaction outside range or while transfer is settling")
	runtime.advance(1,Vector3(-3920,800,4310))
	runtime.advance(1,Vector3(-3920,800,4310))
	var transferred: Dictionary = runtime.use_portal(portal_id)
	_check(transferred.get("ok",false) and runtime.current_map_id == 3003, "original3002event203transfers to real3003dataset")
	if transferred.get("ok",false):
		_check(runtime.get_bounds().max.y == 2450.0 and str(transferred.visual_profile.props.layout_path).contains("/3003/props/"), "destination uses source3003ceiling and distinct312object placement data")
		_check(runtime.current_map.collision_gaps.is_empty(), "destination collider meshes are complete rather than bounding-box proxies")
		_check(runtime.get_state().portal_count == 3, "source3003publishes all three portals, including unavailable catalogued destinations")
		runtime.advance(1,Vector3(4710,650,-600))
		runtime.advance(1,Vector3(4710,650,-600))
		var returned: Dictionary = runtime.use_portal("portal:3003:300")
		_check(returned.get("ok",false) and runtime.current_map_id == 3002, "original3003event300returns to3002event203without synthetic portal data")
	runtime.reset_session()
	_check(runtime.get_state().wallet.credits == 0 and _mission(runtime.get_state(),"101").status == "available", "reset clears local session progress and reward wallet")
	runtime.free()

func _mission(state: Dictionary, identifier: String) -> Dictionary:
	for mission: Dictionary in state.missions:
		if str(mission.id) == identifier:
			return mission
	return {}

func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)

func _report() -> void:
	for failure: String in failures:
		printerr(JSON.stringify({"suite":"world","failure":failure}))
	print(JSON.stringify({"suite":"world","checks":checks,"failures":failures.size(),"status":"pass" if failures.is_empty() else "fail"}))
	quit(0 if failures.is_empty() else 1)


func _test_native_non_tile_model() -> void:
	var model: RefCounted = World.new()
	var bytes: PackedByteArray = PackedByteArray()
	bytes.resize(36)
	for index: int in range(9):bytes.encode_float(index*4,100.0)
	var metadata: Dictionary = {"vertex_side":3,"tile_size":40.0,"flight_ceiling":300.0,"source_map_info":{"TileRenderingFlag":0},"water":{"height":200.0}}
	_check(model.configure(metadata,bytes,[],PackedByteArray([1,1,1,1])).is_empty(), "native TileRenderingFlag0 configures original DAT grid without visible tiled terrain")
	_check(not model.tile_rendering_enabled and model.sample_ground_height(0,0) == 0.0, "disabled tiled ground ignores DAT heights100 and source wet flags in favor of native craft centerY0 navigation bound")
	_check(model.get_bounds().min.y == 0.0 and model.get_bounds().max.y == 300.0, "non-tile world preserves native centerY0 minimum and actual map ceiling")
	_check(not model.trace_segment(Vector3(0,150,0),Vector3(0,-50,0)).collided, "projectile and camera traces do not collide with absent terrain or a fabricated navigation-floor mesh")
	var motion: Dictionary = model.resolve_motion(Vector3(0,20,0),Vector3(0,-20,0),4)
	_check(not motion.collided and motion.position.y == 0.0 and motion.native_floor_clamped, "craft center clamps at nativeY0 without inventing a damage-producing terrain collision")
	_check(model.sample_surface(0,0).kind == "native_navigation_floor", "navigation reference is labeled separately from native terrain/water")
	_check(model.configure(metadata,bytes,[_wall(1)],PackedByteArray([1,1,1,1])).is_empty(), "non-tile world still configures real original Collision1 object geometry")
	var object_hit: Dictionary = model.trace_segment(Vector3(-20,10,0),Vector3(20,10,0))
	_check(object_hit.collided and object_hit.kind == "object", "original room/tunnel prop meshes remain real projectile and motion colliders")
	_check(model.probe_landing(Vector3(-20,10,0),4,180,"12002100").ok, "local A-GEAR ground support uses native navigation bound and actual source object queries")
