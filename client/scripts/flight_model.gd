class_name FlightModel
extends RefCounted
## Airborne normal-flight branches ported from EP35 CShuttleChild/AtumSJ.
## Engine values come from the pinned original ITEM data, never from mesh size.
## Keyboard axes and a fixed 120 Hz clock adapt the original cursor/frame input.

const START_POSITION := Vector3(0.0, 105.0, 170.0)
const CRUISE_SPEED := 160.0 # Compatibility alias: selected level-one ITEM AbilityMax.
const BOOST_SPEED := 220.0 # Selected level-one ITEM Range; profiles remain authoritative.
const BRAKE_SPEED := 130.0 # Selected level-one ITEM AbilityMin.
const MAX_STEP := 1.0 / 120.0
const MAX_DELTA := 0.5
const ENGINE_RULES := "res://assets/legacy_rules/engines.json"
const AIR_PITCH_MAX := 0.5 # ShuttleChild.cpp:115,7216.
const AIR_YAW_MAX := 0.7 # ShuttleChild.cpp:114,7248.
const GRAVITY := 98.0 # Game speed correction, not a rigid-body gravity acceleration.
const OVERHEAT_REPAIR_SECONDS := 10.0 # AtumDefine.h:178.
const EP_CONSUMPTION_VALUE := 5.0 # FieldTimerManager.h:24-26.
const EP_CONSUMPTION_DISTANCE := 30000.0
const EP_CONSUMPTION_SECONDS := 60.0
const EP_HEAVY_WEIGHT := 0.7 # AtumParam.h:497, strict > in FieldIOCPSocket.
const LOCAL_FALL_GRAVITY := 98.0 # New ballistic bridge; source uses a cinema pattern.

var position: Vector3 = START_POSITION
var orientation := Quaternion.IDENTITY
var angular_velocity := Vector3.ZERO
var speed := BRAKE_SPEED
var boost_energy := 1.0
var boosting := false
var boundary_hit := false
var bounds_min := Vector3(-5080.0, -1000000.0, -5080.0)
var bounds_max := Vector3(5080.0, 2230.0, 5080.0) # MAP_INFO3002:2400 + water -170.
var gear_id := "12003100"
var engine_item_num := 0
var profile_ready := false
var profile_error := "Engine ITEM profile has not been loaded"
var movement_enabled := true
var fuel_fraction := 1.0 # Supplied session resource; no invented fuel regeneration.
var weight_ratio := 0.0
var min_speed := BRAKE_SPEED
var cruise_speed := CRUISE_SPEED
var booster_speed := BOOST_SPEED
var burn_duration := 0.0
var range_angle := 0.0
var booster_angle := 0.0
var circular_angle := 0.0
var ground_speed := 0.0
var airborne := true
var siege := false
var ground_normal := Vector3.UP
var fuel_capacity := 0.0 # Must be supplied from native character stats.
var fuel_falling := false
var fuel_stranded := false
var hyper_booster := false # Only an active, validated DES_HYPER_BOOSTER skill.
var _fuel_distance := 0.0
var _fuel_seconds := 0.0
var _fuel_exempt := false
var _fuel_map := -1
var _fuel_influence := -1
var _fuel_character_mode := false
var _fall_velocity := Vector3.ZERO
var _fuel_total_used := 0.0
var _engine_base: Dictionary = {}
var _skill_modifiers: Dictionary = {}
var travel_speed := 0.0
var bank_angle := 0.0
var gravity_speed := 0.0
var overheated := false
var _accumulator := 0.0
var _current_pitch := 0.0
var _current_yaw := 0.0
var _lateral_rate := 0.0


func _init() -> void:
	# Missing source data stops movement instead of selecting an arcade fallback.
	load_gear_profile(gear_id)


func load_gear_profile(source_gear_id: String, path: String = ENGINE_RULES) -> bool:
	if not FileAccess.file_exists(path):
		profile_error = "Original engine rules missing: " + path
		return false
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary:
		profile_error = "Original engine rules are not a dictionary"
		return false
	var by_gear: Variant = parsed.get("by_gear", {})
	if not by_gear is Dictionary or not by_gear.has(source_gear_id):
		profile_error = "No explicit engine selection for GEAR " + source_gear_id
		return false
	var row: Variant = by_gear[source_gear_id]
	if not row is Dictionary:
		profile_error = "Engine selection is not an ITEM record"
		return false
	var item: Dictionary = row.get("item", row)
	if not configure(item):
		return false
	gear_id = source_gear_id
	return true


func configure(item: Dictionary) -> bool:
	var fields := ["AbilityMin", "AbilityMax", "Range", "Time", "SpeedPenalty", "RangeAngle", "BoosterAngle"]
	for field: String in fields:
		if not item.has(field) or not (item[field] is float or item[field] is int) or not is_finite(float(item[field])):
			profile_error = "Invalid or absent original engine ITEM field: " + field
			return false
	var low := float(item.AbilityMin)
	var cruise := float(item.AbilityMax)
	var high := float(item.Range)
	if low < 0.0 or cruise < low or high < cruise or float(item.Time) <= 0.0 or float(item.RangeAngle) < 0.0 or float(item.BoosterAngle) < 0.0 or float(item.SpeedPenalty) < 0.0:
		profile_error = "Original engine ITEM values are outside supported airborne bounds"
		return false
	var was_ready := profile_ready
	min_speed = low
	cruise_speed = cruise
	booster_speed = high
	burn_duration = float(item.Time) / 1000.0
	circular_angle = float(item.SpeedPenalty)
	range_angle = float(item.RangeAngle)
	booster_angle = float(item.BoosterAngle)
	ground_speed = maxf(0.0, float(item.get("Charging", 0.0)))
	_engine_base = {"booster_speed": booster_speed, "circular_angle": circular_angle,
		"range_angle": range_angle, "booster_angle": booster_angle}
	_apply_skill_modifiers()
	engine_item_num = int(item.get("ItemNum", item.get("item_num", 0)))
	profile_ready = true
	profile_error = ""
	# An engine switch preserves the current pose and thermal fraction.
	if not was_ready:
		speed = min_speed
	else:
		speed = clampf(speed, -booster_speed, booster_speed)
	return true


func configure_world(minimum: Vector3, maximum: Vector3) -> bool:
	if not minimum.is_finite() or not maximum.is_finite() or minimum.x >= maximum.x or minimum.y >= maximum.y or minimum.z >= maximum.z:
		return false
	bounds_min = minimum
	bounds_max = maximum
	return true


func set_fuel_state(current: float, capacity: float) -> void:
	if is_finite(current) and is_finite(capacity) and capacity > 0.0:
		fuel_capacity = capacity
		fuel_fraction = clampf(current / capacity, 0.0, 1.0)
		if fuel_fraction > 0.0:
			fuel_falling = false
			fuel_stranded = false
			_fall_velocity = Vector3.ZERO


func configure_resources(resources: Dictionary) -> bool:
	var capacity: Variant = resources.get("max_ep")
	if not _resource_number(capacity) or float(capacity) <= 0.0 or float(capacity) > 1000000.0:
		return false
	var current := fuel_fraction * fuel_capacity if fuel_capacity > 0.0 else fuel_fraction * float(capacity)
	if resources.has("current_ep"):
		if not _resource_number(resources.current_ep):
			return false
		current = float(resources.current_ep)
	set_fuel_state(current, float(capacity))
	return true


func set_skill_modifiers(modifiers: Dictionary) -> bool:
	var clean: Dictionary = {}
	for key: String in ["reaction_speed_factor", "turn_angle_factor", "boost_turn_angle_factor", "booster_speed_add"]:
		var value: Variant = modifiers.get(key, 0.0)
		if not _resource_number(value) or absf(float(value)) > 10000.0:
			return false
		clean[key] = float(value)
	_skill_modifiers = clean
	_apply_skill_modifiers()
	return true


func _apply_skill_modifiers() -> void:
	if _engine_base.is_empty():
		return
	# AtumSJ.cpp:994,1010,1027; ShuttleChild.cpp:14373. Active skill timers,
	# SP, ownership, class and level are checked by SkillModel, not a free key.
	booster_speed = maxf(50.0, float(_engine_base.booster_speed) + float(_skill_modifiers.get("booster_speed_add", 0.0)))
	circular_angle = maxf(0.0, float(_engine_base.circular_angle) * (1.0 + float(_skill_modifiers.get("reaction_speed_factor", 0.0))))
	range_angle = maxf(0.0, float(_engine_base.range_angle) * (1.0 + float(_skill_modifiers.get("turn_angle_factor", 0.0))))
	booster_angle = maxf(0.0, float(_engine_base.booster_angle) * (1.0 + float(_skill_modifiers.get("boost_turn_angle_factor", 0.0))))


func configure_fuel_context(map_index: int, map_influence: int, character_mode: bool = false) -> bool:
	if map_index < 1 or map_influence < 0 or map_influence > 65535:
		return false
	if map_index != _fuel_map or map_influence != _fuel_influence or character_mode != _fuel_character_mode:
		_fuel_distance = 0.0
		_fuel_seconds = 0.0
	_fuel_map = map_index
	_fuel_influence = map_influence
	_fuel_character_mode = character_mode
	_fuel_exempt = character_mode or map_index == 8001 or (map_influence >= 5000 and map_influence <= 5999)
	return true


static func validate_fuel_progress(progress: Variant, is_airborne: bool) -> bool:
	if not progress is Dictionary:
		return false
	for key: String in ["current", "max", "distance_pending", "seconds_pending", "used"]:
		if not _resource_number(progress.get(key)):
			return false
	for key: String in ["configured", "falling", "stranded"]:
		if not progress.get(key) is bool:
			return false
	var capacity := float(progress.max)
	var current := float(progress.current)
	if capacity < 0.0 or capacity > 1000000.0 or current < 0.0 or current > capacity or bool(progress.configured) != (capacity > 0.0):
		return false
	if float(progress.distance_pending) < 0.0 or float(progress.distance_pending) > EP_CONSUMPTION_DISTANCE + 0.01 or float(progress.seconds_pending) < 0.0 or float(progress.seconds_pending) > EP_CONSUMPTION_SECONDS + 0.01:
		return false
	if float(progress.used) < 0.0 or float(progress.used) > 1000000000000.0:
		return false
	if (progress.falling and (progress.stranded or not is_airborne or current > 0.0)) or (progress.stranded and (is_airborne or current > 0.0)):
		return false
	var velocity: Variant = progress.get("fall_velocity")
	if not velocity is Array or velocity.size() != 3:
		return false
	for component: Variant in velocity:
		if not _resource_number(component) or absf(float(component)) > 1000000.0:
			return false
	return true


func restore_fuel_progress(progress: Dictionary) -> bool:
	if not validate_fuel_progress(progress, airborne):
		return false
	# Map exemptions remain derived from current native map/character context;
	# a save file cannot select its own no-consumption rule.
	fuel_capacity = float(progress.max)
	if fuel_capacity > 0.0:
		fuel_fraction = float(progress.current) / fuel_capacity
	_fuel_distance = float(progress.distance_pending)
	_fuel_seconds = float(progress.seconds_pending)
	_fuel_total_used = float(progress.used)
	fuel_falling = progress.falling
	fuel_stranded = progress.stranded
	var velocity: Array = progress.fall_velocity
	_fall_velocity = Vector3(float(velocity[0]), float(velocity[1]), float(velocity[2]))
	return true


static func _resource_number(value: Variant) -> bool:
	return (value is float or value is int) and is_finite(float(value))


func reset() -> void:
	position = START_POSITION
	orientation = Quaternion.IDENTITY
	angular_velocity = Vector3.ZERO
	speed = min_speed
	boost_energy = 1.0
	boosting = false
	boundary_hit = false
	overheated = false
	gravity_speed = 0.0
	travel_speed = min_speed
	bank_angle = 0.0
	_current_pitch = 0.0
	_current_yaw = 0.0
	_lateral_rate = 0.0
	_accumulator = 0.0
	movement_enabled = true
	airborne = true
	siege = false
	ground_normal = Vector3.UP
	fuel_falling = false
	fuel_stranded = false
	_fall_velocity = Vector3.ZERO
	_fuel_distance = 0.0
	_fuel_seconds = 0.0
	hyper_booster = false
	_skill_modifiers.clear()
	_apply_skill_modifiers()


func forward() -> Vector3:
	return -Basis(orientation).z


func snapshot() -> Dictionary:
	return {"speed": speed, "travel_speed": travel_speed, "boost_energy": boost_energy,
		"boosting": boosting, "overheated": overheated, "engine_item_num": engine_item_num,
		"gear_id": gear_id, "fuel_fraction": fuel_fraction, "weight_ratio": weight_ratio,
		"bank_angle": bank_angle, "boundary_hit": boundary_hit, "profile_ready": profile_ready,
		"min_speed": min_speed, "cruise_speed": cruise_speed, "booster_speed": booster_speed,
		"airborne": airborne, "ground_speed": ground_speed,
		"hyper_booster": hyper_booster,
		"flight_skill_modifiers": _skill_modifiers.duplicate(),
		"fuel": {"current": fuel_fraction * fuel_capacity, "max": fuel_capacity,
			"configured": fuel_capacity > 0.0, "exempt": _fuel_exempt,
			"distance_pending": _fuel_distance, "seconds_pending": _fuel_seconds,
			"falling": fuel_falling, "stranded": fuel_stranded, "used": _fuel_total_used,
			"fall_velocity": [_fall_velocity.x, _fall_velocity.y, _fall_velocity.z],
			"fall_motion": "local_ballistic_bridge", "consumption": "EP35 distance/time formula"},
		"mode": "fuel_falling" if fuel_falling else ("fuel_stranded" if fuel_stranded else ("airborne" if airborne else ("siege" if siege else ("ground" if gear_id == "12002100" else "landed"))))}


func advance(controls: Dictionary, delta: float) -> void:
	if not profile_ready or not movement_enabled or not is_finite(delta) or delta <= 0.0:
		return
	boundary_hit = false
	_accumulator += minf(delta, MAX_DELTA)
	# Run source explicit frame equations on a stable clock; retain the remainder.
	while _accumulator + 0.000000001 >= MAX_STEP:
		var previous := position
		_integrate(controls, MAX_STEP)
		_advance_fuel(previous.distance_to(position), MAX_STEP)
		_accumulator = maxf(0.0, _accumulator - MAX_STEP)


func _axis(controls: Dictionary, key: String) -> float:
	var value: Variant = controls.get(key, 0.0)
	if not (value is float or value is int) or not is_finite(float(value)):
		return 0.0
	return clampf(float(value), -1.0, 1.0)


func _integrate(controls: Dictionary, step: float) -> void:
	if not airborne:
		_integrate_ground(controls, step)
		return
	if fuel_fraction <= 0.0:
		_integrate_fuel_fall(step)
		return
	var brake := bool(controls.get("brake", false))
	var stopped := bool(controls.get("unit_stop", false))
	# TickBURN + Move_Air: burn decreases in seconds; overheat recovers to 90%.
	if overheated and boost_energy >= 0.9:
		overheated = false
	boosting = bool(controls.get("boost", false)) and not brake and not stopped and not overheated and fuel_fraction > 0.0 and weight_ratio < 0.8
	if boosting and not hyper_booster:
		boost_energy = maxf(0.0, boost_energy - step / burn_duration)
		if boost_energy <= 0.0:
			overheated = true
			boosting = false
	else:
		boost_energy = minf(1.0, boost_energy + step / OVERHEAT_REPAIR_SECONDS)
	_update_direction(controls, step)
	# ShuttleChild.cpp:10016-10055: inclination changes effective travel speed.
	var inclination := acos(clampf(forward().dot(Vector3.UP), -1.0, 1.0)) / PI
	var target_gravity := 0.0
	if inclination > 0.0 and inclination < 1.0:
		target_gravity = GRAVITY * (1.0 - 2.0 * inclination)
	gravity_speed += (target_gravity - gravity_speed) * step
	gravity_speed = clampf(gravity_speed, -GRAVITY, GRAVITY)
	if speed - gravity_speed < min_speed:
		gravity_speed = speed - min_speed
	# Normal/boost convergence gain 1; S-brake gain 4 plus the original tiny-step rule.
	if stopped:
		speed = 0.0
		gravity_speed = 0.0
		_lateral_rate = 0.0
	elif brake:
		var reduction := (speed - min_speed) * step * 4.0
		speed = speed * 0.5 if absf(reduction) < 0.005 else speed - reduction
		speed = maxf(min_speed, speed)
	else:
		var target := booster_speed if boosting else cruise_speed
		if not boosting or speed < target:
			speed += (target - speed) * step
	# Source heavily-loaded flight clamps the minimum-speed branch.
	if weight_ratio > 0.9:
		speed = minf(speed, min_speed if min_speed >= 0.0 else 10.0)
	travel_speed = speed - gravity_speed
	var direction := forward()
	var up := Basis(orientation).y.rotated(direction, -bank_angle).normalized()
	var right := direction.cross(up).normalized()
	var fuel_factor := 1.0 if fuel_fraction > 0.0 else 0.5
	position += (direction * travel_speed + right * 0.5 * _lateral_rate * cruise_speed) * step * fuel_factor
	var bounded := position.clamp(bounds_min, bounds_max)
	boundary_hit = boundary_hit or not bounded.is_equal_approx(position)
	position = bounded


func _advance_fuel(distance: float, step: float) -> void:
	if fuel_capacity <= 0.0 or _fuel_exempt:
		_fuel_distance = 0.0
		_fuel_seconds = 0.0
		return
	_fuel_distance += distance
	_fuel_seconds += step
	# FieldIOCPSocket.cpp:16625-16645. The weight and boost multipliers are
	# evaluated when the debit happens, not averaged over the preceding interval.
	if _fuel_distance > EP_CONSUMPTION_DISTANCE or _fuel_seconds > EP_CONSUMPTION_SECONDS:
		var multiplier := (2.0 if weight_ratio > EP_HEAVY_WEIGHT else 1.0) * (2.0 if boosting else 1.0)
		var used := multiplier * EP_CONSUMPTION_VALUE * (_fuel_distance / EP_CONSUMPTION_DISTANCE)
		var current := fuel_fraction * fuel_capacity
		_fuel_total_used += minf(current, used)
		fuel_fraction = maxf(0.0, current - used) / fuel_capacity
		_fuel_distance = 0.0
		_fuel_seconds = 0.0


func _integrate_fuel_fall(step: float) -> void:
	if not fuel_falling:
		fuel_falling = true
		fuel_stranded = false
		_fall_velocity = forward() * maxf(0.0, travel_speed) * 0.5
	boosting = false
	# Source Move_Air:7575 enters FALLING, driven by a cinema-unit pattern.
	# This explicit ballistic replacement needs no unavailable cinematic decoder.
	_fall_velocity.y -= LOCAL_FALL_GRAVITY * step
	position += _fall_velocity * step
	position = position.clamp(bounds_min, bounds_max)
	travel_speed = _fall_velocity.length()
	speed = 0.0
	angular_velocity = Vector3.ZERO


func _update_direction(controls: Dictionary, step: float) -> void:
	var pitch := _axis(controls, "pitch") * AIR_PITCH_MAX
	var yaw := _axis(controls, "yaw") * AIR_YAW_MAX
	var lateral := -_axis(controls, "roll") # Existing A/D now drives original side thrust.
	_lateral_rate = move_toward(_lateral_rate, lateral, (10.0 if lateral != 0.0 else 1.0) * step)
	var turn_scale := booster_angle if boosting else range_angle
	var direction := forward().normalized()
	var up := Basis(orientation).y.rotated(direction, -bank_angle).normalized()
	var right := direction.cross(up).normalized()
	var pitch_rate := 0.0
	var yaw_rate := 0.0
	if pitch != 0.0 and not bool(controls.get("unit_stop", false)):
		_current_pitch += circular_angle * step * pitch * 0.1
		_current_pitch = minf(_current_pitch, pitch) if pitch > 0.0 else maxf(_current_pitch, pitch)
		pitch_rate = turn_scale * _current_pitch
		direction = direction.rotated(right, pitch_rate * step)
		up = up.rotated(right, pitch_rate * step)
	if yaw != 0.0:
		_current_yaw += circular_angle * step * yaw * 0.1
		_current_yaw = minf(_current_yaw, yaw) if yaw > 0.0 else maxf(_current_yaw, yaw)
		yaw_rate = turn_scale * _current_yaw
		direction = direction.rotated(up, yaw_rate * step)
	right = direction.cross(up).normalized()
	up = right.cross(direction).normalized()
	# SetMatrix_Move_Air: virtual bank follows steering/side thrust, capped to 72deg.
	var bank_control := -yaw
	if not ((_lateral_rate <= 0.0 and bank_control <= _lateral_rate * 0.5) or (_lateral_rate >= 0.0 and bank_control >= _lateral_rate * 0.5)):
		bank_control = _lateral_rate * 0.5
	var bank_target := 4.0 * bank_control
	bank_angle += (bank_target - bank_angle) * step
	bank_angle = clampf(bank_angle, -PI * 0.4, PI * 0.4)
	var visual_up := up.rotated(direction, bank_angle)
	orientation = Basis.looking_at(direction, visual_up).get_rotation_quaternion().normalized()
	angular_velocity = Vector3(pitch_rate, yaw_rate, bank_angle)


func resolve_collision(safe_position: Vector3, normal: Vector3, kind: String = "terrain") -> Dictionary:
	var impact := absf(travel_speed)
	if safe_position.is_finite():
		position = safe_position
	boundary_hit = true
	boosting = false
	if fuel_falling:
		# Source falling-by-fuel reaches FUELALLIN rather than reporting a combat
		# kill. The local world contact strands the craft until a service refuels it.
		fuel_falling = false
		fuel_stranded = true
		airborne = false
		siege = false
		speed = 0.0
		travel_speed = 0.0
		gravity_speed = 0.0
		_fall_velocity = Vector3.ZERO
		if normal.is_finite() and normal.length_squared() > 0.000001:
			ground_normal = normal.normalized()
		return {"impact_speed": impact, "damage_scale": 0.0, "kind": kind, "fuel_stranded": true}
	if kind == "blocked_tile":
		# Exact source no-move tile response, ShuttleChild.cpp:8306-8309.
		speed *= -0.5
		_lateral_rate *= 0.8
	elif normal.is_finite() and normal.length_squared() > 0.000001:
		# The contact query is a local sweep, not the source multi-ray aircraft body.
		# Its normal feeds GetCollReflect (AtumGlobal.cpp:2390-2400), then the source
		# common collision-speed branch (ShuttleChild.cpp:10808,10926).
		var direction := forward()
		var unit_normal := normal.normalized()
		if direction.dot(unit_normal) < 0.0:
			direction = direction.bounce(unit_normal).normalized()
			var up := Vector3.UP if absf(direction.y) < 0.999 else Vector3.RIGHT
			orientation = Basis.looking_at(direction, up).get_rotation_quaternion()
			bank_angle = 0.0
		speed = maxf(min_speed, 60.0)
	gravity_speed = 0.0
	travel_speed = speed
	return {"impact_speed": impact, "damage_scale": 1.0, "kind": kind}


func land(contact_position: Vector3, normal: Vector3 = Vector3.UP) -> bool:
	if not contact_position.is_finite() or not normal.is_finite() or normal.length_squared() < 0.000001:
		return false
	airborne = false
	siege = false
	fuel_falling = false
	fuel_stranded = fuel_fraction <= 0.0
	_fall_velocity = Vector3.ZERO
	speed = 0.0
	travel_speed = 0.0
	gravity_speed = 0.0
	bank_angle = 0.0
	_lateral_rate = 0.0
	boosting = false
	set_ground_contact(contact_position, normal)
	return true


func take_off() -> bool:
	if airborne or not profile_ready or fuel_fraction <= 0.0:
		return false
	# Local state bridge; the original cinematic/server-authorized pattern is absent.
	airborne = true
	siege = false
	position += ground_normal * 5.0
	speed = min_speed
	gravity_speed = 0.0
	return true


func set_ground_contact(contact_position: Vector3, normal: Vector3 = Vector3.UP) -> void:
	if airborne or not contact_position.is_finite() or not normal.is_finite() or normal.length_squared() < 0.000001:
		return
	position = contact_position
	ground_normal = normal.normalized()
	var direction := forward().slide(ground_normal)
	if direction.length_squared() < 0.000001:
		direction = Vector3.FORWARD.slide(ground_normal)
	if direction.length_squared() < 0.000001:
		direction = Vector3.RIGHT.slide(ground_normal)
	orientation = Basis.looking_at(direction.normalized(), ground_normal).get_rotation_quaternion()


func set_siege(enabled: bool) -> bool:
	if gear_id != "12002100" or airborne:
		return false
	siege = enabled
	if siege:
		speed = 0.0
		travel_speed = 0.0
	return true


func _integrate_ground(controls: Dictionary, step: float) -> void:
	boosting = false
	boost_energy = minf(1.0, boost_energy + step / OVERHEAT_REPAIR_SECONDS)
	if boost_energy >= 0.9:
		overheated = false
	if gear_id != "12002100" or siege or bool(controls.get("brake", false)) or fuel_fraction <= 0.0:
		speed = 0.0
		travel_speed = 0.0
		return
	# A-GEAR Move_Ground/CheckMoveRate: Charging, reverse limit -Charging/2.
	var throttle := _axis(controls, "ground_throttle") if controls.has("ground_throttle") else _axis(controls, "pitch")
	if throttle > 0.0:
		speed += (ground_speed - speed) * step
	elif throttle < 0.0:
		if speed > 0.0:
			speed -= (speed + ground_speed * 0.5) * step
		else:
			speed -= (ground_speed * 0.5 - speed) * step
		speed = maxf(-ground_speed * 0.5, speed)
	else:
		var reduction := speed * step
		speed = speed * 0.5 if absf(reduction) < 0.005 else speed - reduction
		if int(speed * 100.0) == 0:
			speed = 0.0
	var steering := clampf(_axis(controls, "roll") + _axis(controls, "yaw"), -1.0, 1.0)
	var direction := forward().rotated(ground_normal, steering * step).normalized()
	orientation = Basis.looking_at(direction, ground_normal).get_rotation_quaternion()
	travel_speed = speed
	position += direction * speed * step
	var bounded := position.clamp(bounds_min, bounds_max)
	boundary_hit = boundary_hit or not bounded.is_equal_approx(position)
	position = bounded
