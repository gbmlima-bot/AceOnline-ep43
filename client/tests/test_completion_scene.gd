extends SceneTree
## Production orchestration checks. High-level school profiles in the fuel test
## are explicit fixtures; they are not evidence of earned campaign progression.

var scene: Node3D
var checks := 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)


func _run() -> void:
	scene = (load("res://main.tscn") as PackedScene).instantiate()
	root.add_child(scene)
	scene.set_physics_process(false)
	scene.set_process(false)
	await process_frame
	_check(scene._combat_ready and is_instance_valid(scene.systems), "production models initialized")
	if not scene._combat_ready or not is_instance_valid(scene.systems):
		await _finish()
		return
	scene.systems.set_process(false)
	_check(scene.world_runtime.reward_validator.is_valid() and scene.world_runtime.reward_applicator.is_valid(), "production mission transactions have inventory preflight and commit hooks")
	_test_inventory_preview()
	await _test_landing_and_save()
	_test_rejected_save_rebinds_inventory()
	_test_fuel_skill_bridge()
	await _finish()


func _test_inventory_preview() -> void:
	var inventory = scene.combat_runtime.inventory
	var before: Dictionary = inventory.export_state()
	var event := {"reward_id":"completion-preview-fixture", "items":[{"item_num":7000040,"count":1}]}
	_check(scene._validate_world_inventory_event(event), "production mission preflight accepts a known native item")
	_check(inventory.export_state() == before, "production preflight does not grant items or consume reward receipts")
	_check(not scene._validate_world_inventory_event({"reward_id":"unknown-preview", "items":[{"item_num":1,"count":1}]}), "production preflight refuses unknown items")
	_check(inventory.export_state() == before, "refused production preflight preserves inventory and wallet")


func _contact() -> Dictionary:
	var bounds: Dictionary = scene.world_runtime.get_bounds()
	for x in range(int(bounds.min.x + 100), int(bounds.max.x - 100), 300):
		for z in range(int(bounds.min.z + 100), int(bounds.max.z - 100), 300):
			var ground: float = scene.world_runtime.sample_ground_height(x, z, true)
			if not is_finite(ground): continue
			var contact: Dictionary = scene.world_runtime.probe_landing(Vector3(x,ground + 60,z),4.0,180.0,scene.model.gear_id)
			if bool(contact.get("ok", false)): return contact
	return {}


func _test_landing_and_save() -> void:
	# The source map permits A-GEAR surface contact; other classes require pads.
	for _gear in range(4):
		if scene.model.gear_id == "12002100": break
		scene._cycle_gear()
	var contact := _contact()
	_check(not contact.is_empty(), "native world provides an eligible landing surface")
	if contact.is_empty(): return
	scene.model.clear_surface_transition()
	scene.model.position = contact.position + Vector3.UP * 15.0
	scene.model.orientation = Quaternion.IDENTITY
	scene.model.speed = 0.0
	scene.model.airborne = true
	scene.ship.position = scene.model.position
	var initial_position: Vector3 = scene.model.position
	scene._toggle_landing()
	_check(scene.model.landing and scene.model.position == initial_position, "G begins a descent without teleporting")
	scene._physics_process(1.0 / 120.0)
	_check(scene.model.position.y < initial_position.y and scene.model.airborne, "production physics advances gradual landing")
	var saved: Dictionary = scene._capture_local_progress()
	_check(saved.flight.transition.landing, "production save includes active landing state")
	var restored: Dictionary = scene._restore_local_progress(JSON.parse_string(JSON.stringify(saved)))
	_check(bool(restored.get("ok", false)) and scene.model.landing, "active landing survives production JSON restore")
	var hp: float = scene.combat_runtime.model.player.hp
	for _step in range(150):
		if not scene.model.airborne: break
		scene._physics_process(1.0 / 120.0)
	_check(not scene.model.airborne and not scene.model.landing, "production contact commits a completed landing")
	_check(scene.combat_runtime.model.player.hp == hp, "landing contact causes no collision damage")
	var grounded: Vector3 = scene.model.position
	scene._toggle_landing()
	_check(scene.model.taking_off and scene.model.position == grounded, "G starts timed takeoff without a height snap")
	scene._physics_process(1.0 / 120.0)
	_check(scene.model.position.y > grounded.y, "production physics advances takeoff ascent")
	saved = scene._capture_local_progress()
	_check(saved.flight.transition.taking_off and bool(scene._restore_local_progress(JSON.parse_string(JSON.stringify(saved))).get("ok", false)), "mid-takeoff save restores its remaining timer")
	var invalid: Dictionary = saved.duplicate(true)
	invalid.flight.transition.remaining = 100.0
	var before: Vector3 = scene.model.position
	_check(not bool(scene._restore_local_progress(invalid).get("ok", false)) and scene.model.position == before, "invalid transition is rejected before mutating the running session")
	for _step in range(130): scene._physics_process(1.0 / 120.0)
	_check(scene.model.airborne and not scene.model.taking_off, "timed takeoff returns to regular flight")


func _test_rejected_save_rebinds_inventory() -> void:
	var before: Dictionary = scene._capture_local_progress()
	var invalid: Dictionary = before.duplicate(true)
	invalid.combat.player.max_hp = float(invalid.combat.player.max_hp) + 1.0
	var result: Dictionary = scene._restore_local_progress(invalid)
	_check(not bool(result.get("ok", false)) and str(result.get("error", "")) == "combat_derived_vitals", "invalid combat vitals cause a production rollback")
	_check(scene.combat_runtime.inventory.export_state() == before.combat.inventory, "rejected combat restore preserves owned inventory and credits")
	_check(scene.systems.services.inventory == scene.combat_runtime.inventory, "rollback rebinds shop services to the current live inventory")
	_check(scene.systems.export_state().item_use == before.systems.item_use, "rollback preserves consumable cooldowns")


func _test_fuel_skill_bridge() -> void:
	for _gear in range(4):
		if scene.model.gear_id == "12001100": break
		scene._cycle_gear()
	_check(scene.model.gear_id == "12001100", "M-GEAR fixture uses its actual native flight profile")
	var skills = scene.systems.skills
	# Isolate a high-level learned skill; do not grant progression to the profile.
	skills.set_profile({"gear_id":"12001100", "player":{"level":125,"max_sp":1000.0}})
	skills.sp = skills.max_sp
	var identifier := 0
	for key: Variant in skills.definitions:
		var row: Dictionary = skills.definitions[key]
		if int(row.get("SkillLevel",0)) != 1 or not str(row.get("blocked_reason", "")).is_empty(): continue
		if not bool(skills.can_learn(int(key)).get("ok",false)): continue
		for parameter: Dictionary in row.parameters:
			if int(parameter.destination) == 61: identifier = int(key)
		if identifier > 0: break
	_check(identifier > 0, "recovered M-GEAR refuel rank exists for this fixture")
	if identifier == 0: return
	_check(bool(skills.learn(identifier).get("ok",false)) and bool(skills.assign_slot(1,identifier).get("ok",false)), "native skill learning and assignment are used by the integration fixture")
	scene.model.set_fuel_state(scene.model.fuel_capacity * 0.2, scene.model.fuel_capacity)
	var previous: float = scene.model.fuel_fraction
	scene.combat_runtime.model.player.ep = -1.0 # Stale presentation must be refreshed from FlightModel.
	var result: Dictionary = scene.systems.cast_slot(1)
	_check(bool(result.get("ok", false)) and result.has("ep_current"), "production skill bridge obtains authoritative fuel context before casting")
	_check(scene.model.fuel_fraction > previous, "native refuel changes actual FlightModel fuel")
	_check(is_equal_approx(float(scene.combat_runtime.model.player.ep), scene.model.fuel_fraction * scene.model.fuel_capacity), "combat and flight fuel remain synchronized after the cast")


func _finish() -> void:
	if is_instance_valid(scene):
		scene.queue_free()
		await process_frame
	print(JSON.stringify({"suite":"completion-scene", "checks":checks,"failures":failures.size(),"native_mac_windows_execution":false}))
	for failure: String in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
