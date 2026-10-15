extends SceneTree
## Runs unchanged in a minimal server staging project, without an editor import.
const World = preload("res://scripts/online/headless_world.gd")
var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run()


func _run() -> void:
	var world: RefCounted = World.new()
	_check(world.is_class("RefCounted") and not world.is_class("Node"), "authoritative world is a nonvisual RefCounted")
	_check(not world.is_configured() and is_nan(world.sample_ground_height(0.0, 0.0)), "unconfigured world cannot supply fabricated ground")
	_check(world.sweep_projectile(Vector3.ZERO, Vector3.ONE).collided and not world.line_of_sight(Vector3.ZERO, Vector3.ONE), "missing authoritative world fails closed for firing and visibility")
	_check(not world.configure(3302) and not world.is_configured(), "online deployment allowlists map3002 only")
	if OS.get_cmdline_user_args().has("--expect-missing-data"):
		_check(not world.configure() and not world.is_configured(), "missing or modified native data refuses authoritative startup")
		_check(world.resolve_motion(Vector3.ZERO, Vector3.ONE).has("error"), "movement remains blocked after data validation failure")
		_finish(world)
		return
	_check(world.configure(), "all native numeric geometry configures without any GLB, texture, audio or scene")
	if not world.is_configured():
		_finish(world)
		return
	_check(world.map_id == 3002 and world.source_map_info.MapIndex == 3002 and world.source_map_info.TileRenderingFlag == 1, "server map identity is read from fixed native metadata")
	var diagnostics: Dictionary = world.diagnostics()
	_check(diagnostics.collision_instances == 31 and diagnostics.data_files.size() == 15 and not diagnostics.native_server_spawns_available, "server requires all31 original Collision1 placements and15 data files without pretending to recover server spawns")
	var bounds: Dictionary = world.get_bounds()
	_check(bounds.min.x == -5080.0 and bounds.max.x == 5080.0 and bounds.max.y == 2230.0, "native margin40 and water-relative flight ceiling2230 are authoritative")
	_check(world.sample_ground_height(0.0, 0.0, false) == -160.0, "map3002 center retains exact native height")
	_check(is_nan(world.sample_ground_height(99999.0, 0.0)), "outside-map height is unavailable rather than extrapolated")
	var ground: Dictionary = world.sweep_projectile(Vector3(0,100,0), Vector3(0,-200,0), 2.0)
	_check(ground.collided and ground.kind == "terrain" and absf(ground.position.y + 158.0) < 0.001, "authoritative projectile sphere hits original B-D collision ground at correct clearance")
	_check(is_equal_approx(float(ground.distance), 300.0 * float(ground.t)), "obstacle distance matches CombatModel callback contract")
	var wet_height: float = world.sample_ground_height(-4020.0, -4380.0)
	_check(wet_height == -170.0 and world.sample_ground_height(-4020.0, -4380.0, false) < -175.0, "exact original water tile raises collision surface without altering terrain")
	var water: Dictionary = world.sweep_projectile(Vector3(-4020,-100,-4380), Vector3(-4020,-210,-4380))
	_check(water.collided and water.kind == "water" and is_equal_approx(water.position.y, -170.0), "water is a real authoritative projectile obstacle")
	var start: Vector3 = Vector3(-2395.5838381560275,318.76453793121004,-2113.2562869512453)
	var finish: Vector3 = Vector3(-2392.1830859590605,317.4083227344173,-2111.64521127493)
	var prop: Dictionary = world.sweep_projectile(start, finish)
	_check(prop.collided and prop.kind == "object" and int(prop.get("source_code",0)) == 3001700, "native prop3001700 placement252 blocks actual projectiles through transformed original triangle geometry")
	_check(not world.line_of_sight(start, finish), "the same native wall blocks enemy line of sight")
	var motion: Dictionary = world.resolve_motion(start, finish, {"radius":0.25})
	_check(motion.collided and motion.kind == "object" and motion.position.distance_to(start) < start.distance_to(finish), "pilot motion is stopped by the same original mesh with authoritative hull radius")
	var npc_position: Vector3 = world.resolve_npc_motion(start, finish, 0.25)
	_check(npc_position.is_finite() and npc_position.distance_to(motion.position) < 0.001, "NPC movement adapter returns Vector3 using the same server geometry")
	_check(world.line_of_sight(Vector3(-20,2000,0),Vector3(20,2000,0)), "unobstructed high-altitude sight remains clear")
	var edge: Dictionary = world.resolve_motion(Vector3(0,2000,0),Vector3(10000,2000,0))
	_check(edge.collided and edge.kind == "boundary" and absf(edge.position.x - 5079.999) < 0.01, "authoritative movement enforces the original map edge")
	var contact: Dictionary = world.ground_contact(Vector3(0,-150,0))
	_check(contact.ok and is_equal_approx(contact.position.y,-156.0) and contact.normal.y > 0.99, "ground contact exposes real source support for A-GEAR and pilot landing integration")
	_check(world.probe_landing(Vector3(0,-150,0),4.0,180.0,"12002100").ok and not world.probe_landing(Vector3(0,-150,0),4.0,180.0,"12003100").ok, "native landing requires an enabled airport tile or A-GEAR class exception")
	var grounded: Dictionary = world.resolve_motion(Vector3(0,-156,0),Vector3(10,-156,0),{"radius":4.0,"grounded":true})
	_check(grounded.position.is_finite() and grounded.get("supported",false), "grounded authoritative motion follows source support without fabricated collision damage")
	_check(world.resolve_motion(Vector3.ZERO, Vector3.ONE, {"radius":-1.0}).has("error") and world.resolve_motion(Vector3.ZERO,Vector3.ONE,{"grounded":"fake"}).has("error"), "invalid authoritative hull/ground options do not reach geometry code")
	_check(world.sweep_projectile(Vector3(NAN,0,0),Vector3.ZERO).collided and not world.line_of_sight(Vector3(NAN,0,0),Vector3.ZERO), "nonfinite firing requests fail closed")
	_check(world.resolve_motion(Vector3.ZERO,Vector3.ONE,{"radius":4.0,"noclip":true}).has("error"), "unrecognized movement options cannot enable noclip")
	_check(not world.configure(3302) and world.is_configured() and world.map_id == 3002, "rejected map change preserves the already validated room atomically")
	_finish(world)


func _finish(world: RefCounted) -> void:
	print(JSON.stringify({"suite":"headless-world","checks":checks,"failures":failures.size(),"map_id":world.map_id,"collision_instances":world.diagnostics().collision_instances,"native_numeric_data_only":true}))
	for failure: String in failures:
		printerr(JSON.stringify({"suite":"headless-world","failure":failure}))
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures.append(description)
