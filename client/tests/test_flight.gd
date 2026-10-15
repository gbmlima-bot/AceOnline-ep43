extends SceneTree
## Fixtures derived independently from EP35 equations and pinned original ITEM rows.
const Model = preload("res://scripts/flight_model.gd")
var checks := 0
var failures: Array[String] = []


func _initialize() -> void:
	_test_source_engine_profiles()
	_test_source_speed_fixtures()
	_test_source_turn_and_bank()
	_test_gravity()
	_test_thermal_and_limits()
	_test_ground_and_landing()
	_test_source_takeoff()
	_test_source_landing_transition()
	_test_source_landing_leveling()
	_test_surface_transition_persistence()
	_test_delta_and_invalid_inputs()
	_test_collision_contract()
	_test_native_fuel()
	_test_fuel_fall_bridge()
	_test_native_flight_skill_modifiers()
	_test_fuel_persistence()
	print(JSON.stringify({"suite": "source_flight", "checks": checks, "failures": failures.size()}))
	for failure: String in failures:
		printerr(failure)
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)


func _run_seconds(state: RefCounted, controls: Dictionary, duration: float, rate: int = 120) -> void:
	for frame in range(roundi(duration * rate)):
		state.advance(controls, 1.0 / float(rate))


func _new_gear(id: String = "12003100") -> RefCounted:
	var state = Model.new()
	_check(state.load_gear_profile(id), "original selected engine profile loads for " + id)
	state.reset()
	return state


func _test_source_engine_profiles() -> void:
	var expected := {"12000100": 7001230, "12001100": 7002580, "12002100": 7002590, "12003100": 7002570}
	for gear: String in expected:
		var state = _new_gear(gear)
		_check(state.engine_item_num == expected[gear], "profile keeps exact original ITEM number")
		_check(state.min_speed == 130.0 and state.cruise_speed == 160.0 and state.booster_speed == 220.0 and state.burn_duration == 20.0, "selected level-one ITEM speed/burn fields are applied")
		_check(state.speed == 130.0, "UpdateEngine starts at AbilityMin, not invented cruise")
	var state = _new_gear()
	var engine: int = state.engine_item_num
	_check(not state.configure({"AbilityMin": 50}), "incomplete engine metadata is rejected")
	_check(state.engine_item_num == engine and state.profile_ready, "a rejected reconfiguration preserves the valid profile")
	_check(not state.load_gear_profile("not-a-gear"), "an unknown GEAR has no silent profile fallback")


func _test_source_speed_fixtures() -> void:
	var state = _new_gear()
	state.advance({}, 1.0 / 120.0)
	_check(absf(state.speed - 130.25) < 0.000001, "source Euler normal-speed first tick:130+(160-130)/120")
	state.reset()
	_run_seconds(state, {}, 1.0)
	# Geometric sum of the source recurrence, computed independently in Python.
	_check(absf(state.speed - 149.00976203332053) < 0.00001, "normal speed after120 ticks matches closed-form discrete fixture")
	_check(absf(state.position.z - 28.8513473497096) < 0.002, "position uses the source updated-speed sum, not invented exponential integration")
	state.reset()
	_run_seconds(state, {"boost": true}, 1.0)
	_check(absf(state.speed - 187.0292860999616) < 0.00001, "boost target Range220 uses original gain1")
	_check(absf(state.boost_energy - 0.95) < 0.000001, "ITEM Time20000 consumes exactly one second of20-second burn")
	state.speed = 220.0
	_run_seconds(state, {"brake": true, "boost": true}, 0.5)
	_check(absf(state.speed - 141.77191452874084) < 0.00001, "source air-brake gain4 fixture")
	_check(not state.boosting, "brake overrides the adapted boost input")
	state.speed = 130.1
	state.advance({"brake": true}, Model.MAX_STEP)
	_check(state.speed == 130.0, "source tiny-brake half-speed branch clamps to AbilityMin")
	_run_seconds(state, {}, 2.0)
	_check(state.speed > 130.0 and state.speed < 160.0, "releasing brake returns toward normal engine speed")
	state.advance({"unit_stop": true}, Model.MAX_STEP)
	_check(state.speed == 0.0 and state.travel_speed == 0.0, "source explicit unit-stop state stops translation")


func _test_source_turn_and_bank() -> void:
	var pitch = _new_gear()
	_run_seconds(pitch, {"pitch": 1.0}, 1.0)
	var pitch_angle := 0.7617083261410396 # Sum currentAngle ramp*RangeAngle*dt.
	var expected_pitch := Vector3(0, sin(pitch_angle), -cos(pitch_angle))
	_check(pitch.forward().distance_to(expected_pitch) < 0.0001, "source pitch envelope0.5 and SpeedPenalty ramp fixture")
	var yaw = _new_gear()
	_run_seconds(yaw, {"yaw": 1.0}, 1.0)
	var yaw_angle := 1.0663916565974554
	_check(yaw.forward().distance_to(Vector3(-sin(yaw_angle), 0, -cos(yaw_angle))) < 0.0001, "source yaw envelope0.7 and engine angle fixture")
	_check(absf(yaw.bank_angle + PI * 0.4) < 0.00001, "source virtual bank damps the unclamped target then reaches the72-degree cap")
	var side = _new_gear()
	_run_seconds(side, {"roll": 1.0}, 0.5)
	_check(side.position.x < -25.0 and side.forward().distance_to(Vector3.FORWARD) < 0.0001, "A/D side thrust moves laterally without inventing yaw dynamics")
	var i_gear = _new_gear("12003100")
	var m_gear = _new_gear("12001100")
	_run_seconds(i_gear, {"boost": true, "yaw": 1.0}, 1.0)
	_run_seconds(m_gear, {"boost": true, "yaw": 1.0}, 1.0)
	_check(i_gear.forward().angle_to(Vector3.FORWARD) > m_gear.forward().angle_to(Vector3.FORWARD) + 0.04, "original I booster-angle1.6 turns faster than selected M1.5")
	_check(absf(i_gear.orientation.length() - 1.0) < 0.00001, "rotation remains normalized")


func _test_gravity() -> void:
	var climb = _new_gear()
	climb.speed = 160.0
	climb.orientation = Quaternion(Vector3.RIGHT, PI / 6.0)
	climb.advance({}, Model.MAX_STEP)
	_check(absf(climb.gravity_speed - 0.2722222222222222) < 0.0001, "30-degree climb uses original gravity98 inclination correction")
	var dive = _new_gear()
	dive.speed = 160.0
	dive.orientation = Quaternion(Vector3.RIGHT, -PI / 6.0)
	dive.advance({}, Model.MAX_STEP)
	_check(absf(dive.gravity_speed + 0.2722222222222222) < 0.0001 and dive.travel_speed > climb.travel_speed, "dive gains effective speed while climb loses it")
	var floor_state = _new_gear()
	floor_state.orientation = Quaternion(Vector3.RIGHT, 1.0)
	_run_seconds(floor_state, {}, 1.0)
	_check(floor_state.travel_speed >= floor_state.min_speed - 0.001, "gravity cannot force effective normal speed below engine minimum")


func _test_thermal_and_limits() -> void:
	var state = _new_gear()
	_run_seconds(state, {"boost": true}, 20.1)
	_check(state.overheated and not state.boosting, "full20-second burn enters overheat")
	state.boost_energy = 0.899
	state.overheated = true
	state.advance({"boost": true}, Model.MAX_STEP)
	_check(not state.boosting and state.overheated, "overheat cannot restart below90%")
	state.advance({"boost": true}, Model.MAX_STEP * 2.0)
	_check(state.boosting and not state.overheated, "recharge to90% unlocks boost")
	state.boost_energy = 0.25
	state.overheated = false
	_run_seconds(state, {}, 1.0)
	_check(absf(state.boost_energy - 0.35) < 0.00001, "original10-second repair adds10% capacity each second")
	state.weight_ratio = 0.8
	state.advance({"boost": true}, Model.MAX_STEP)
	_check(not state.boosting, "original weight ratio0.8 blocks boost")
	state.weight_ratio = 0.95
	state.speed = 200.0
	state.advance({}, Model.MAX_STEP)
	_check(state.speed == state.min_speed, "over90% load restricts movement to engine minimum")
	state.weight_ratio = 0.0
	state.set_fuel_state(0, 100)
	state.advance({"boost": true}, Model.MAX_STEP)
	_check(not state.boosting and state.fuel_fraction == 0.0, "empty externally supplied fuel blocks boost")
	state.set_fuel_state(100, 100)
	_check(state.configure_world(Vector3(-10, -20, -30), Vector3(10, 2230, 30)), "world bounds can be supplied from original map metadata")
	state.position = Vector3(50, 3000, -50)
	state.advance({}, Model.MAX_STEP)
	_check(state.boundary_hit and state.position.x <= 10 and state.position.y == 2230 and state.position.z >= -30, "source altitude ceiling and map bounds are enforced")
	_check(not state.configure_world(Vector3.ZERO, Vector3.ZERO), "invalid world bounds are rejected")


func _test_ground_and_landing() -> void:
	var a_gear = _new_gear("12002100")
	_check(a_gear.ground_speed == 50.0, "A-GEAR Charging50 becomes original ground speed")
	_check(a_gear.land(Vector3(0, 5, 0), Vector3.UP), "A-GEAR can enter grounded mode using a world contact")
	_run_seconds(a_gear, {"ground_throttle": 1.0}, 1.0)
	_check(absf(a_gear.speed - 31.68293672220088) < 0.00001 and a_gear.position.y == 5, "original A ground acceleration fixture keeps contact height")
	_check(a_gear.set_siege(true), "A-GEAR can enter ground siege state")
	var stopped: Vector3 = a_gear.position
	_run_seconds(a_gear, {"ground_throttle": 1.0}, 1.0)
	_check(a_gear.speed == 0 and a_gear.position == stopped, "ground siege disables translation without inventing combat buffs")
	a_gear.set_siege(false)
	_run_seconds(a_gear, {"ground_throttle": -1.0}, 1.0)
	_check(a_gear.speed == -25.0, "original reverse branch clamps to minus half Charging")
	a_gear.land(Vector3.ZERO, Vector3.UP)
	_run_seconds(a_gear, {"roll": 1.0}, 1.0)
	_check(a_gear.forward().distance_to(Vector3(-sin(1.0), 0, -cos(1.0))) < 0.0001, "A ground keyboard rotation uses original one radian per second")
	_check(a_gear.take_off() and a_gear.airborne and a_gear.taking_off and a_gear.speed == 0.0, "takeoff enters original timed state without instant normal-flight speed")
	var i_gear = _new_gear()
	i_gear.land(Vector3(0, 5, 0), Vector3.UP)
	stopped = i_gear.position
	_run_seconds(i_gear, {"ground_throttle": 1.0, "boost": true}, 1.0)
	_check(i_gear.position == stopped and i_gear.speed == 0 and not i_gear.set_siege(true), "landed I-GEAR neither drives like an A-GEAR nor enables siege")
	_check(not i_gear.land(Vector3(NAN, 0, 0)), "invalid landing contact is rejected")
	a_gear.land(Vector3.ZERO, Vector3.UP)
	_run_seconds(a_gear, {"ground_throttle": 1.0, "unit_stop": true}, 1.0)
	_check(a_gear.position == Vector3.ZERO and a_gear.speed == 0.0, "source ground unit-stop prevents throttle translation")


func _test_source_takeoff() -> void:
	for gear: String in ["12000100", "12001100", "12002100", "12003100"]:
		var state = _new_gear(gear)
		state.land(Vector3(0, 5, 0), Vector3.UP)
		var before: Vector3 = state.position
		_check(state.take_off() and state.position == before, "takeoff begins without teleport for " + gear)
		_check(state.snapshot().mode == "taking_off" and not state.take_off(), "takeoff state blocks duplicate starts")
		var duration := 0.4 if gear == "12002100" else 1.0
		var displacement := 24.0 if gear == "12002100" else 30.0
		_run_seconds(state, {"pitch": 1.0, "roll": 1.0, "boost": true}, duration)
		_check(state.position.distance_to(before + Vector3(0, displacement, -displacement)) < 0.0001, "original fixed takeoff trajectory and duration for " + gear)
		_check(not state.taking_off and state.snapshot().mode == "airborne" and state.speed == state.min_speed, "source takeoff completion restores normal state")
		_check(state.orientation == Quaternion.IDENTITY and not state.boosting, "takeoff motion ignores normal-flight steering and boost")
	var stopped = _new_gear()
	stopped.land(Vector3.ZERO)
	stopped.set_fuel_state(0.0, 100.0)
	_check(not stopped.take_off(), "empty fuel prevents native takeoff state")
	stopped.set_fuel_state(100.0, 100.0)
	stopped.take_off()
	stopped.advance({}, Model.MAX_STEP)
	stopped.reset()
	_check(not stopped.taking_off and not stopped.landing and stopped.snapshot().takeoff_remaining == 0.0, "reset clears in-progress surface transitions")


func _test_source_landing_transition() -> void:
	for gear: String in ["12002100", "12003100"]:
		var state = _new_gear(gear)
		state.position = Vector3(0, 105, 0)
		state.speed = 130.0
		_check(state.begin_landing(Vector3(0, 5, 0)) and state.airborne and state.landing, "original landing enters airborne descent for " + gear)
		_check(state.position == Vector3(0, 105, 0) and state.snapshot().mode == "landing", "landing begins without position snap")
		_run_seconds(state, {"pitch": 1.0, "roll": 1.0}, 1.0)
		var descent := 45.0 if gear == "12002100" else 15.0
		# Independent arithmetic series of130-n*30/120, n=1..120.
		_check(absf(state.position.y - (105.0 - descent)) < 0.0002 and absf(state.speed - 100.0) < 0.00001, "native descent and30-unit deceleration fixture for " + gear)
		_check(absf(state.position.z + 114.875) < 0.0002 and state.position.x == 0.0, "landing keeps forward translation without lateral teleport")
		state.update_landing_contact(Vector3(0, 5, state.position.z))
		_run_seconds(state, {}, 7.0)
		_check(not state.landing and not state.airborne and absf(state.position.y - 5.0) < 0.0001 and state.position.z < -114.0, "descent commits ground at current horizontal position")
	var state = _new_gear()
	state.position = Vector3(0, 100, 0)
	_check(not state.begin_landing(Vector3(0, -80, 0)) and not state.begin_landing(Vector3(0, 101, 0)), "TryLandingState enforces strict180-height cap and rejects support above aircraft")
	_check(not state.begin_landing(Vector3.ZERO, Vector3.ZERO) and not state.begin_landing(Vector3.ZERO, Vector3.RIGHT), "invalid or wall landing support is rejected")
	state.begin_landing(Vector3.ZERO)
	var before: Vector3 = state.position
	state.advance({"boost": true}, Model.MAX_STEP)
	_check(state.taking_off and not state.landing and state.position.y > before.y, "boost cancels landing through native takeoff state")
	state.land(Vector3.ZERO)
	state.take_off()
	state.resolve_collision(Vector3(1, 2, 3), Vector3.BACK, "object")
	_check(not state.taking_off, "blocked takeoff exits scripted motion so collision cannot be overwritten")
	state.reset()
	state.begin_landing(Vector3.ZERO)
	var hit: Dictionary = state.resolve_collision(Vector3(0, 5, -10), Vector3.UP, "terrain")
	_check(hit.get("landed", false) and hit.damage_scale == 0.0 and not state.airborne and not state.landing, "landing contact commits without combat collision damage")
	state.reset()
	state.begin_landing(Vector3.ZERO)
	state.set_fuel_state(0.0, 100.0)
	state.advance({}, Model.MAX_STEP)
	_check(state.fuel_falling and not state.landing and not state.taking_off, "fuel exhaustion cancels landing and enters source falling state")


func _test_source_landing_leveling() -> void:
	# Independent closed-form pitch fixture: the native upright branch rotates
	# twice, so theta(n)=theta(0)*(1-2/120)^n before horizon epsilon clamping.
	for sign_value: float in [1.0, -1.0]:
		var state = _new_gear()
		state.position = Vector3(0, 105, 0)
		state.orientation = Quaternion(Vector3.RIGHT, sign_value * PI / 4.0)
		_check(state.begin_landing(Vector3(0, 5, 0)), "tilted upright landing begins")
		_run_seconds(state, {"pitch": sign_value, "roll": 1.0}, 1.0)
		var expected_pitch := sign_value * 0.10451562750703258
		_check(absf(asin(state.forward().y) - expected_pitch) < 0.00001, "native landing double pitch relaxation matches closed-form fixture")
		var expected_height := 128.44713608459907 if sign_value > 0.0 else 51.55286391540092
		_check(absf(state.position.y - expected_height) < 0.0003 and absf(state.position.z + 106.02915648388205) < 0.0003, "landing levels pitch before source forward translation")
		_check(absf(state.bank_angle) < 0.0001 and absf(state.orientation.length() - 1.0) < 0.00001, "pitch leveling preserves a normalized unbanked frame")
		_run_seconds(state, {}, 12.0)
		_check(not state.airborne and not state.landing and absf(state.position.y - 5.0) < 0.0001, "tilted up/down landing reaches the ground instead of holding initial pitch")
	var inverted = _new_gear()
	inverted.position = Vector3(0, 105, 0)
	inverted.orientation = Quaternion(Vector3.FORWARD, PI)
	inverted.begin_landing(Vector3(0, 5, 0))
	_run_seconds(inverted, {}, 1.0)
	# Pure bank has one transform: abs(bank)=PI*(1-1/120)^120.
	var expected_bank := PI * pow(119.0 / 120.0, 120.0)
	_check(absf(absf(inverted.bank_angle) - expected_bank) < 0.0001, "native inverted landing rolls toward world up at original gain one")
	_check(inverted.forward().distance_to(Vector3.FORWARD) < 0.0001 and absf(inverted.position.y - 90.0) < 0.0002, "inverted roll recovery preserves heading and descent")
	for pitch_sign: float in [1.0, -1.0]:
		var state = _new_gear()
		state.position = Vector3(0, 105, 0)
		state.orientation = Quaternion(Vector3.FORWARD, PI) * Quaternion(Vector3.RIGHT, pitch_sign * PI / 4.0)
		var initial_tilt := absf(state.forward().y)
		state.begin_landing(Vector3(0, 5, 0))
		state.advance({}, Model.MAX_STEP)
		var expected_first_pitch := PI / 4.0 * (1.0 - Model.MAX_STEP)
		_check(absf(absf(asin(state.forward().y)) - expected_first_pitch) < 0.00001, "inverted pitch receives the source single relaxation transform")
		_run_seconds(state, {}, 1.0)
		_check(absf(state.forward().y) < initial_tilt and state.orientation.is_finite() and absf(state.orientation.length() - 1.0) < 0.00001, "tilted inverted landing recovers without NaN or heading reversal")
		_run_seconds(state, {}, 12.0)
		_check(not state.airborne and state.position.y == 5.0 and Basis(state.orientation).y.dot(Vector3.UP) > 0.999, "tilted inverted landing completes with upright ground contact")


func _test_surface_transition_persistence() -> void:
	var state = _new_gear("12002100")
	state.land(Vector3.ZERO)
	state.take_off()
	_run_seconds(state, {}, 0.2)
	var saved: Dictionary = state.transition_progress()
	var loaded = _new_gear("12002100")
	loaded.position = state.position
	loaded.speed = state.speed
	_check(loaded.restore_transition_progress(saved) and loaded.taking_off, "mid-takeoff timer round-trips")
	_run_seconds(loaded, {}, 0.2)
	_check(not loaded.taking_off and loaded.position.distance_to(Vector3(0, 24, -24)) < 0.0001, "restored takeoff flies only the remaining native duration")
	state.reset()
	state.begin_landing(Vector3(0, 5, 0))
	_run_seconds(state, {}, 0.5)
	saved = state.transition_progress()
	loaded.position = state.position
	loaded.speed = state.speed
	_check(loaded.restore_transition_progress(saved) and loaded.landing, "landing support plane round-trips")
	_run_seconds(state, {}, 3.0)
	_run_seconds(loaded, {}, 3.0)
	_check(state.position.distance_to(loaded.position) < 0.0001 and state.airborne == loaded.airborne, "restored landing keeps the same descent and contact")
	var invalid := saved.duplicate(true)
	invalid.taking_off = true
	var before: Dictionary = loaded.transition_progress()
	_check(not loaded.restore_transition_progress(invalid) and loaded.transition_progress() == before, "mutually exclusive transitions are rejected atomically")
	invalid = saved.duplicate(true)
	invalid.normal = [0, NAN, 0]
	_check(not Model.validate_transition_progress(invalid, true, "12002100"), "nonfinite restored support rejected")
	invalid = saved.duplicate(true)
	invalid.normal = [0, 0, 0]
	_check(not Model.validate_transition_progress(invalid, true, "12002100"), "zero restored support normal rejected")
	_check(not Model.validate_transition_progress(saved, false, "12002100"), "grounded save cannot claim active airborne transition")
	state.land(Vector3.ZERO)
	state.take_off()
	saved = state.transition_progress()
	saved.remaining = 0.5
	_check(not Model.validate_transition_progress(saved, true, "12002100"), "A-GEAR takeoff restore cannot exceed recovered0.4-second duration")
	loaded.clear_surface_transition()
	_check(not loaded.landing and not loaded.taking_off, "legacy save can explicitly discard previous transition")


func _simulate(rate: int) -> RefCounted:
	var state = _new_gear()
	_run_seconds(state, {"pitch": 0.2, "roll": 0.12, "yaw": -0.3, "boost": true}, 3.0, rate)
	return state


func _test_delta_and_invalid_inputs() -> void:
	var low = _simulate(30)
	for rate in [60, 144]:
		var high = _simulate(rate)
		_check(low.position.distance_to(high.position) < 0.001 and absf(low.speed - high.speed) < 0.000001, "fixed source ticks are independent of render rate " + str(rate))
		_check(absf(low.boost_energy - high.boost_energy) < 0.000001 and low.orientation.angle_to(high.orientation) < 0.001, "thermal and angular state are render-rate independent")
	var invalid = _new_gear()
	for delta in [0.0, -1.0, NAN, INF]:
		invalid.advance({"boost": true}, delta)
	_check(invalid.position == Model.START_POSITION and invalid.speed == 130, "invalid delta does not mutate state")
	invalid.advance({"pitch": NAN, "yaw": INF, "roll": "invalid"}, Model.MAX_STEP)
	_check(invalid.orientation == Quaternion.IDENTITY, "non-numeric/non-finite input cannot corrupt orientation")
	var clamped = _new_gear()
	var normalized = _new_gear()
	_run_seconds(clamped, {"pitch": 99.0, "roll": -99.0, "yaw": 99.0}, 1.0)
	_run_seconds(normalized, {"pitch": 1.0, "roll": -1.0, "yaw": 1.0}, 1.0)
	_check(clamped.orientation.is_equal_approx(normalized.orientation) and clamped.position.is_equal_approx(normalized.position), "analog input is clamped")
	invalid.reset()
	invalid.advance({}, 1000)
	_check(invalid.position.distance_to(Model.START_POSITION) < 160.0 * Model.MAX_DELTA, "frame spikes are bounded")
	invalid.reset()
	_check(invalid.position == Model.START_POSITION and invalid.orientation == Quaternion.IDENTITY and invalid.boost_energy == 1.0 and not invalid.overheated, "reset clears pose, thermal state and fixed-clock remainder")


func _test_collision_contract() -> void:
	var state = _new_gear()
	state.speed = 200.0
	state.travel_speed = 190.0
	var hit: Dictionary = state.resolve_collision(Vector3(1, 2, 3), Vector3.UP, "blocked_tile")
	_check(state.position == Vector3(1, 2, 3) and state.speed == -100.0 and hit.impact_speed == 190, "original no-move-tile speed reversal and integration contact contract")
	state.reset()
	state.speed = 200.0
	state.travel_speed = 200.0
	hit = state.resolve_collision(Vector3(0, 20, 0), Vector3.BACK, "terrain")
	_check(state.forward().z > 0.99 and state.speed == 130.0 and hit.damage_scale == 1.0, "source reflection and post-collision max(engineMin,60) apply to the local sweep contact")


func _test_native_fuel() -> void:
	var state = _new_gear()
	_check(not state.snapshot().fuel.configured, "fuel consumption requires actual native stat capacity")
	_check(not state.configure_resources({"max_ep": NAN}) and not state.configure_resources({"max_ep": "100"}), "invalid resource capacity is rejected")
	state.fuel_fraction = 0.5
	_check(state.configure_resources({"max_ep": 100.0}) and state.snapshot().fuel.current == 50.0, "legacy fuel_fraction initializes absolute native EP")
	_check(state.configure_resources({"max_ep": 200.0}) and state.snapshot().fuel.current == 50.0, "capacity changes preserve EP rather than granting fuel")
	_check(state.configure_resources({"max_ep": 100.0, "current_ep": 100.0}), "native EP can be restored or refueled explicitly")
	state._advance_fuel(30000.0, 60.0)
	_check(state.snapshot().fuel.current == 100.0, "source consumption thresholds are strict distance/time greater-than")
	state._advance_fuel(0.0, 0.01)
	_check(absf(state.snapshot().fuel.current - 95.0) < 0.00001, "source debit is exactly5 EP per30000 distance after timeout")
	_check(state.snapshot().fuel.distance_pending == 0.0 and state.snapshot().fuel.seconds_pending == 0.0, "debit resets both source accumulators")
	state._advance_fuel(15000.0, 60.01)
	_check(absf(state.snapshot().fuel.current - 92.5) < 0.00001, "timeout debits a proportional half-distance2.5 EP")
	state._advance_fuel(0.0, 60.01)
	_check(absf(state.snapshot().fuel.current - 92.5) < 0.00001, "stationary ship consumes zero in distance-based formula")
	state.weight_ratio = 0.7
	state._advance_fuel(30000.0, 60.01)
	_check(absf(state.snapshot().fuel.current - 87.5) < 0.00001, "exact70percent weight has no strict-heavy penalty")
	state.weight_ratio = 0.701
	state._advance_fuel(30000.0, 60.01)
	_check(absf(state.snapshot().fuel.current - 77.5) < 0.00001, "over70percent native heavy load doubles debit")
	state.boosting = true
	state._advance_fuel(30000.0, 60.01)
	_check(absf(state.snapshot().fuel.current - 57.5) < 0.00001, "boost and heavy weight multiply to quadruple debit")
	state.weight_ratio = 0.0
	state.boosting = false
	state.configure_fuel_context(8001, 0)
	state._advance_fuel(50000.0, 61.0)
	_check(absf(state.snapshot().fuel.current - 57.5) < 0.00001 and state.snapshot().fuel.exempt, "source tutorial map8001 is exempt")
	state.configure_fuel_context(3002, 5000)
	state._advance_fuel(50000.0, 61.0)
	_check(absf(state.snapshot().fuel.current - 57.5) < 0.00001, "source infinity influence5000 is exempt")
	state.configure_fuel_context(3002, 5999)
	_check(state.snapshot().fuel.exempt, "source infinity last influence5999 is inclusive")
	state.configure_fuel_context(3002, 6000)
	_check(not state.snapshot().fuel.exempt, "outpost influence6000 is not infinity")
	state.configure_fuel_context(2001, 1000, true)
	_check(state.snapshot().fuel.exempt, "source on-foot character mode is exempt")
	state.configure_fuel_context(3002, 0)
	state._advance_fuel(30000.01, 1.0)
	_check(absf(state.snapshot().fuel.current - 52.4999983333333) < 0.0001, "distance threshold debits before60 seconds")
	state.set_fuel_state(0.1, 100.0)
	state._advance_fuel(30000.01, 1.0)
	_check(state.fuel_fraction == 0.0, "exhaustion clamps actual current EP to zero")
	state.reset()
	state.set_fuel_state(100.0, 100.0)
	state.configure_world(Vector3(-100000, -100000, -100000), Vector3(100000, 100000, 100000))
	_run_seconds(state, {}, 60.1)
	_check(state.fuel_fraction < 1.0 and state.fuel_fraction > 0.98, "actual flight integration debits the original distance formula")
	var before: float = state.fuel_fraction
	state.movement_enabled = false
	_run_seconds(state, {}, 61.0)
	_check(state.fuel_fraction == before, "disabled/dead local simulation does not consume fuel")


func _test_fuel_fall_bridge() -> void:
	var state = _new_gear()
	state.set_fuel_state(0.0, 100.0)
	var initial: Vector3 = state.position
	state.advance({"boost": true, "pitch": 1.0}, Model.MAX_STEP)
	_check(state.fuel_falling and not state.boosting and state.position.y < initial.y, "native zero-EP trigger enters explicit local falling bridge")
	_check(state.snapshot().mode == "fuel_falling" and state.snapshot().fuel.fall_motion == "local_ballistic_bridge", "falling bridge is labelled in state")
	_run_seconds(state, {"boost": true, "pitch": 1.0}, 0.5)
	_check(state.position.y < initial.y - 10.0 and state.orientation == Quaternion.IDENTITY, "fuel fall follows gravity rather than pilot steering")
	var impact: Dictionary = state.resolve_collision(Vector3(1, 2, 3), Vector3.UP, "terrain")
	_check(impact.damage_scale == 0.0 and state.fuel_stranded and not state.airborne, "source fuel-exhausted contact strands instead of awarding a combat death")
	_check(not state.take_off(), "stranded craft cannot take off without EP")
	var stopped: Vector3 = state.position
	_run_seconds(state, {"boost": true, "ground_throttle": 1.0}, 1.0)
	_check(state.position == stopped, "empty stranded craft remains still")
	state.set_fuel_state(100.0, 100.0)
	_check(not state.fuel_falling and not state.fuel_stranded and state.take_off(), "explicit refuel service restores normal takeoff")
	_run_seconds(state, {}, 0.2)
	_check(state.snapshot().mode == "taking_off" and state.position.y >= 7.0, "refueled craft leaves grounded contact through timed native takeoff")


func _test_native_flight_skill_modifiers() -> void:
	var state = _new_gear()
	var turn: float = state.range_angle
	var boost_turn: float = state.booster_angle
	var reaction: float = state.circular_angle
	state.speed = 150.0
	state.boost_energy = 0.4
	var before: Vector3 = state.position
	_check(state.set_skill_modifiers({"reaction_speed_factor": 0.1, "turn_angle_factor": 0.1, "boost_turn_angle_factor": 0.1, "booster_speed_add": 20.0}), "native HyperMoving descriptor combination is supported")
	_check(absf(state.circular_angle - reaction * 1.1) < 0.00001 and absf(state.range_angle - turn * 1.1) < 0.00001 and absf(state.booster_angle - boost_turn * 1.1) < 0.00001, "AtumSJ reaction/normal/boost angle factors follow native equations")
	_check(state.booster_speed == 240.0 and state.speed == 150.0 and state.position == before and state.boost_energy == 0.4, "DES181 adds20 speed without teleport, resource refill or instant acceleration")
	_check(not state.set_skill_modifiers({"turn_angle_factor": NAN}) and state.booster_speed == 240.0, "invalid skill modifier is rejected atomically")
	state.set_skill_modifiers({})
	_check(state.booster_speed == 220.0 and state.range_angle == turn and state.circular_angle == reaction, "skill expiration restores native engine baseline")
	state.set_skill_modifiers({"booster_speed_add": 20.0})
	state.load_gear_profile("12001100")
	_check(state.booster_speed == 240.0, "native engine reconfiguration recomputes active modifiers without compounding")
	state.load_gear_profile("12001100")
	_check(state.booster_speed == 240.0, "repeated engine load cannot stack the same skill")
	state.reset()
	_check(state.booster_speed == 220.0 and not state.hyper_booster, "reset removes skill effects and does not invent a free hyperbooster")
	state.boost_energy = 0.4
	_check(state.set_skill_modifiers({"hyper_booster": 1.0}), "validated DES166 activation is accepted")
	_run_seconds(state, {"boost": true}, 1.0)
	_check(state.boosting and absf(state.boost_energy - 0.5) < 0.00001 and state.booster_speed == 220.0, "native hyperbooster recovers thermal charge without granting speed")
	_check(not state.set_skill_modifiers({"hyper_booster": 2.0}) and state.hyper_booster, "invalid hyperbooster flag is rejected atomically")
	state.set_skill_modifiers({})
	var energy: float = state.boost_energy
	_run_seconds(state, {"boost": true}, 1.0)
	_check(not state.hyper_booster and absf(state.boost_energy - (energy - 0.05)) < 0.00001, "DES166 expiration resumes original thermal consumption")


func _test_fuel_persistence() -> void:
	var state = _new_gear()
	state.configure_resources({"max_ep": 100.0, "current_ep": 80.0})
	state.configure_fuel_context(3002, 0)
	state._advance_fuel(12000.0, 30.0)
	var saved: Dictionary = state.snapshot().fuel
	var loaded = _new_gear()
	loaded.configure_fuel_context(3002, 0)
	_check(loaded.restore_fuel_progress(saved), "fuel state imports current/capacity and pending debit")
	_check(loaded.snapshot().fuel.current == 80.0 and loaded.snapshot().fuel.distance_pending == 12000.0 and loaded.snapshot().fuel.seconds_pending == 30.0, "pending source distance and timer round-trip")
	loaded._advance_fuel(0.0, 31.0)
	_check(absf(loaded.snapshot().fuel.current - 78.0) < 0.00001, "reload does not erase the next scheduled fuel debit")
	var before: Dictionary = loaded.snapshot().fuel
	var invalid := saved.duplicate(true)
	invalid.current = NAN
	_check(not loaded.restore_fuel_progress(invalid) and loaded.snapshot().fuel == before, "invalid resource restore is atomic")
	invalid = saved.duplicate(true)
	invalid.distance_pending = 30001.0
	_check(not loaded.restore_fuel_progress(invalid), "out-of-range pending consumption is rejected")
	invalid = saved.duplicate(true)
	invalid.falling = true
	_check(not Model.validate_fuel_progress(invalid, true), "falling with positive EP is rejected before scene mutation")
	state.set_fuel_state(0.0, 100.0)
	state.advance({}, Model.MAX_STEP)
	saved = state.snapshot().fuel
	_check(loaded.restore_fuel_progress(saved) and loaded.fuel_falling, "fall trajectory velocity and empty fuel round-trip")
	_check(not Model.validate_fuel_progress(saved, false), "airborne falling state cannot be loaded as grounded")
	loaded.resolve_collision(Vector3.ZERO, Vector3.UP)
	saved = loaded.snapshot().fuel
	state.airborne = false
	_check(state.restore_fuel_progress(saved) and state.fuel_stranded, "stranded state round-trips without accidental takeoff")
	invalid = saved.duplicate(true)
	invalid.fall_velocity = [0.0, INF, 0.0]
	_check(not state.restore_fuel_progress(invalid), "invalid restored fall velocity rejected")
	invalid = saved.duplicate(true)
	invalid.exempt = true
	_check(state.restore_fuel_progress(invalid) and not state.snapshot().fuel.exempt, "save metadata cannot bypass native map fuel rules")
