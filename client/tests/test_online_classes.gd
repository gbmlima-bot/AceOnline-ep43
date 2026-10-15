extends SceneTree
## Authoritative class creation and source-surface transition regression tests.
const Arena = preload("res://scripts/online/arena_model.gd")
const World = preload("res://scripts/online/headless_world.gd")
const Wire = preload("res://scripts/online/json_wire.gd")
const OLD_ABSENT_FIELDS := ["landing", "taking_off", "_takeoff_remaining", "_landing_contact", "_landing_normal"]
var checks := 0
var failures: Array[String] = []
var world: RefCounted

func _initialize() -> void:
	world = World.new()
	_check(world.configure(3002), "Native headless map failed configuration")
	_test_classes_and_migration()
	_test_authoritative_ground_transitions()
	_test_fuel_skill_flight_owner()
	print("ONLINE_CLASSES_TEST=" + JSON.stringify({"checks": checks, "failures": failures, "native_classes": 4, "legacy_v08_migration": true, "authoritative_surface_commands": true}))
	for failure: String in failures:
		push_error(failure)
	quit(0 if failures.is_empty() else 1)

func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)

func _arena() -> RefCounted:
	var arena = Arena.new()
	_check(arena.configure({"room_id": "classes", "max_players": 8}, world), "Arena failed native configuration")
	return arena

func _test_classes_and_migration() -> void:
	var arena = _arena()
	_check(not bool(arena.add_player("invalid", {}, "10000000").ok) and arena.pilots.is_empty(), "Unknown class created a pilot")
	for index in range(Arena.GEAR_IDS.size()):
		var gear: String = Arena.GEAR_IDS[index]
		var id := "pilot%d" % index
		_check(bool(arena.add_player(id, {}, gear).ok), "Native class starter failed: " + gear)
		if not arena.pilots.has(id):
			continue
		var pilot: Dictionary = arena.pilots[id]
		_check(str(pilot.inventory.gear_id) == gear and str(pilot.flight.gear_id) == gear and str(pilot.skills.gear_id) == gear, "Server class differs across inventory/flight/skills")
		for slot: String in ["primary", "secondary", "engine", "armor", "radar"]:
			_check(bool(pilot.inventory.can_equip(int(pilot.inventory.equipped[slot]), slot).ok), "Starter violates native class/level/stats: " + gear + "/" + slot)
		var snapshot: Dictionary = arena.snapshot(id)
		_check(str(snapshot.self.inventory.gear_id) == gear and str(snapshot.self.skills.gear_id) == gear, "Private snapshot reports wrong class")
		_check(snapshot.self.skills.assignment_available and not snapshot.self.skills.learning_available and snapshot.self.skills.rows.is_empty() and not snapshot.self.skills.learned_rows.is_empty(), "Owned skill ranks or honest school capability missing")
		_check(not Wire.encode({"op": "snapshot", "state": snapshot}).is_empty(), "Four-class snapshot exceeds wire or leaks Godot types")
	_check(bool(arena.add_player("old-client").ok) and arena.pilots["old-client"].inventory.gear_id == Arena.GEAR_ID, "Optional auth class broke old I-GEAR clients")
	_check(bool(arena.submit_input("pilot0", 0, {"ground_throttle": 0.5, "unit_stop": true}).ok), "Native validated ground throttle/unit stop controls were rejected")
	_check(not bool(arena.submit_input("pilot0", 1, {"ground_throttle": 1.1}).ok) and not bool(arena.submit_input("pilot0", 1, {"unit_stop": 1}).ok), "Malformed throttle or unit-stop controls were accepted")
	var inventory_before: Dictionary = arena.pilots.pilot0.inventory.export_state()
	var learned_before: Dictionary = arena.pilots.pilot0.skills.export_state()
	var denied: Dictionary = arena.command("pilot0", "no-school", "skill_learn", {"item_num": 7830011})
	_check(not bool(denied.ok) and denied.error == "native_school_contact_unavailable" and arena.pilots.pilot0.inventory.export_state() == inventory_before and arena.pilots.pilot0.skills.export_state() == learned_before, "Remote field learning granted unavailable training or changed resources")
	arena.combat.activate_pilot("pilot0")
	arena.combat.player.hp -= 10.0
	arena.combat.store_pilot()
	arena.remove_player("pilot0")
	_check(not bool(arena.add_player("pilot0", {}, "12003100").ok) and not arena.pilots.pilot0.connected, "Reconnection changed persistent character class")
	_check(bool(arena.add_player("pilot0", {}, "12000100").ok) and arena.combat.pilot_states.pilot0.player.hp == arena.combat.pilot_states.pilot0.player.max_hp - 10.0, "Matching-class reconnect refreshed character resources")
	var saved: Dictionary = JSON.parse_string(JSON.stringify(arena.export_state()))
	var restored = _arena()
	_check(restored.import_state(saved), "Four-class server state failed JSON restore")
	for id: String in arena.pilots:
		_check(restored.pilots.has(id) and restored.pilots[id].inventory.gear_id == arena.pilots[id].inventory.gear_id and restored.pilots[id].flight.engine_item_num == arena.pilots[id].flight.engine_item_num, "Restart changed native class/engine")
	var current: Dictionary = restored.export_state()
	var bad := saved.duplicate(true)
	bad.pilots.pilot0.flight.gear_id = "12003100"
	_check(not restored.import_state(bad) and restored.export_state() == current, "Mismatched flight class mutated live persistence")
	bad = saved.duplicate(true)
	bad.pilots.pilot0.inventory = []
	_check(not restored.import_state(bad) and restored.export_state() == current, "Malformed saved inventory crashed or mutated the live room")
	bad = saved.duplicate(true)
	bad.pilots.pilot0.inventory.gear_id = "invalid"
	_check(not restored.import_state(bad) and restored.export_state() == current, "Unknown saved class mutated live persistence")
	# Existing v0.8 saves captured every Flight variable and omit all five new
	# transitions. This is an explicit, narrow migration rather than lenient load.
	for id: String in saved.pilots:
		for field: String in OLD_ABSENT_FIELDS:
			saved.pilots[id].flight.erase(field)
	_check(restored.import_state(saved) and not restored.pilots.pilot0.flight.landing and not restored.pilots.pilot0.flight.taking_off, "Legacy v0.8 server records failed transition-default migration")
	bad = saved.duplicate(true)
	bad.pilots.pilot0.flight.erase("speed")
	current = restored.export_state()
	_check(not restored.import_state(bad) and restored.export_state() == current, "Legacy migration accepted missing mandatory flight state")

func _dry_contact() -> Dictionary:
	var bounds: Dictionary = world.get_bounds()
	for x in range(-8, 9):
		for z in range(-8, 9):
			var position := Vector3(lerpf(bounds.min.x, bounds.max.x, float(x + 9) / 18.0), 0, lerpf(bounds.min.z, bounds.max.z, float(z + 9) / 18.0))
			position.y = world.sample_ground_height(position.x, position.z, true) + 60.0
			var contact: Dictionary = world.probe_landing(position, 4.0, 180.0, "12002100")
			if bool(contact.get("ok", false)):
				return {"position": position, "contact": contact}
	return {}

func _test_authoritative_ground_transitions() -> void:
	var arena = _arena()
	_check(bool(arena.add_player("tank", {}, "12002100").ok), "A-GEAR creation failed")
	_check(not bool(arena.command("tank", "air-siege", "toggle_siege", {}).ok), "Airborne A-GEAR entered siege")
	var fixture := _dry_contact()
	_check(not fixture.is_empty(), "Original map has no recoverable dry A-GEAR landing fixture")
	if fixture.is_empty():
		return
	var flight: RefCounted = arena.pilots.tank.flight
	flight.position = fixture.position
	arena.combat.activate_pilot("tank")
	arena.combat.set_player_pose(flight.position, flight.forward())
	arena.combat.store_pilot()
	var start: Vector3 = flight.position
	var hp: float = arena.combat.player.hp
	var landing: Dictionary = arena.command("tank", "land", "toggle_landing", {})
	_check(bool(landing.ok) and flight.landing and flight.airborne and flight.position == start, "Server landing command teleported or skipped descent")
	var transition_saved: Dictionary = JSON.parse_string(JSON.stringify(arena.export_state()))
	var restored = _arena()
	_check(restored.import_state(transition_saved) and restored.pilots.tank.flight.landing, "Mid-landing state did not persist")
	for frame in range(10):
		arena.advance(0.25)
	_check(not flight.airborne and not flight.landing and flight.position.y < start.y and arena.combat.pilot_states.tank.player.hp == hp, "Native descent failed to land or caused collision damage")
	_check(bool(arena.command("tank", "siege", "toggle_siege", {}).ok) and flight.siege, "Grounded A-GEAR could not enter siege")
	var grounded_start: Vector3 = flight.position
	_check(bool(arena.submit_input("tank", 1, {"yaw": 0.3, "roll": 1.0}).ok), "Validated grounded controls were rejected")
	arena.advance(0.1)
	_check(flight.position.is_equal_approx(grounded_start), "Sieged A-GEAR moved across native terrain")
	_check(bool(arena.command("tank", "unsiege", "toggle_siege", {}).ok) and not flight.siege, "A-GEAR siege toggle failed")
	var prior: Vector3 = flight.position
	_check(bool(arena.command("tank", "takeoff", "toggle_landing", {}).ok) and flight.taking_off and flight.position == prior, "Server takeoff teleported instead of starting native ascent")
	arena.advance(0.1)
	_check(flight.airborne and flight.position.y > prior.y and flight.position.y < prior.y + 20.0, "A-GEAR source takeoff speed was not advanced by server ticks")
	var saved: Dictionary = JSON.parse_string(JSON.stringify(arena.export_state()))
	_check(restored.import_state(saved) and restored.pilots.tank.flight.taking_off, "Mid-takeoff timer did not persist")
	var malformed := saved.duplicate(true)
	malformed.pilots.tank.flight.landing = true
	_check(not restored.import_state(malformed), "Impossible simultaneous landing/takeoff passed persistence validation")


func _test_fuel_skill_flight_owner() -> void:
	var arena = _arena()
	_check(bool(arena.add_player("medic", {}, "12001100").ok), "M-GEAR recovery fixture failed to join")
	var pilot: Dictionary = arena.pilots.medic
	# Trusted server-earned-rank fixture isolates the transaction bridge. No
	# network command grants these ranks or changes the level in live gameplay.
	pilot.skills.set_profile({"gear_id": "12001100", "player": {"level": 125, "max_sp": 1000.0}})
	pilot.skills.sp = 1000.0
	_check(bool(pilot.skills.learn(7813011).ok) and bool(pilot.skills.learn(7813071).ok), "Native M-GEAR recovery ranks could not be prepared")
	pilot.skills.assign_slot(1, 7813011)
	pilot.skills.assign_slot(2, 7813071)
	var capacity: float = pilot.flight.fuel_capacity
	pilot.flight.set_fuel_state(10.0, capacity)
	var refuel: Dictionary = arena.command("medic", "refuel", "skill_use", {"slot": 1})
	_check(bool(refuel.ok) and is_equal_approx(float(pilot.flight.fuel_fraction) * capacity, minf(capacity, 40.0)), "Authoritative Refuel did not update the Flight EP owner")
	var fuel_before: float = pilot.flight.fuel_fraction
	var sp_before: float = pilot.skills.sp
	_check(bool(arena.command("medic", "refuel", "skill_use", {"slot": 1}).get("replayed", false)) and pilot.flight.fuel_fraction == fuel_before and pilot.skills.sp == sp_before, "Recovery replay consumed SP or duplicated fuel")
	_check(not bool(arena.command("medic", "forged-fuel", "skill_use", {"slot": 2, "ep_current": 99999}).ok) and pilot.flight.fuel_fraction == fuel_before and pilot.skills.sp == sp_before, "Client supplied EP bypassed server-owned recovery")
	var complete: Dictionary = arena.command("medic", "recover", "skill_use", {"slot": 2})
	_check(bool(complete.ok) and is_equal_approx(pilot.flight.fuel_fraction, 1.0) and is_equal_approx(float(complete.ep_current), capacity), "Full Recovery did not refill flight fuel and combat resources together")
	var tank = _arena()
	tank.add_player("barrier", {}, "12002100")
	var armor: Dictionary = tank.pilots.barrier
	armor.skills.set_profile({"gear_id": "12002100", "player": {"level": 125, "max_sp": 1000.0}})
	armor.skills.sp = 1000.0
	_check(bool(armor.skills.learn(7821061).ok) and bool(armor.skills.assign_slot(1, 7821061).ok), "Native A-GEAR Barrier rank could not be prepared")
	sp_before = armor.skills.sp
	_check(not bool(tank.command("barrier", "air-barrier", "skill_use", {"slot": 1}).ok) and armor.skills.sp == sp_before, "Server failed to pass airborne context to native ground-only Barrier")
	var fixture := _dry_contact()
	if fixture.is_empty():
		_check(false, "Native Barrier ground fixture unavailable")
		return
	armor.flight.land(fixture.contact.position, fixture.contact.normal)
	_check(bool(tank.command("barrier", "ground-barrier", "skill_use", {"slot": 1}).ok) and float(armor.skills.modifiers().get("missile_barrier", 0.0)) == 1.0, "Authoritative grounded context did not permit native Barrier")
