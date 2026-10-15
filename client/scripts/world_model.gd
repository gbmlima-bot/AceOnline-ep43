class_name WorldModel
extends RefCounted
## Deterministic local world queries, without SceneTree/PhysicsServer state.
## Terrain uses the original collision B-D diagonal (Background.cpp:1415-1439),
## which differs from the A-C diagonal of the original terrain renderer.

const EPS: float = 0.00001
const CONTACT_BIAS: float = 0.001
const MAX_GRID_SIDE: int = 1025

var map_id: int = 0
var grid_side: int = 0
var tile_size: float = 40.0
var water_height: float = 0.0
var ceiling_height: float = INF
var boundary_margin: float = 0.0
var ceiling_is_center_limit: bool = false
var tile_rendering_enabled: bool = true
var warnings: PackedStringArray = PackedStringArray()
var _heights: PackedFloat32Array = PackedFloat32Array()
var _water: PackedByteArray = PackedByteArray()
var _landing: PackedByteArray = PackedByteArray()
var _colliders: Array[Dictionary] = []
var _half_span: float = 0.0
var _minimum_y: float = 0.0
var _maximum_y: float = 0.0


func configure(map_data: Dictionary, height_bytes: PackedByteArray, collider_records: Array = [], water_bytes: PackedByteArray = PackedByteArray(), landing_bytes: PackedByteArray = PackedByteArray()) -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
	warnings.clear()
	_heights.clear()
	_water.clear()
	_landing.clear()
	_colliders.clear()
	grid_side = 0
	var grid: Dictionary = map_data.get("grid", {})
	var side: int = int(grid.get("vertex_side", map_data.get("vertex_side", 0)))
	var spacing: float = float(grid.get("tile_size", map_data.get("tile_size", 40.0)))
	if side < 2 or side > MAX_GRID_SIDE or not is_finite(spacing) or spacing <= 0.0:
		errors.append("invalid_world_grid")
		return errors
	if height_bytes.size() != side * side * 4:
		errors.append("invalid_world_height_byte_count")
		return errors
	var heights: PackedFloat32Array = PackedFloat32Array()
	heights.resize(side * side)
	var minimum: float = INF
	var maximum: float = -INF
	for index: int in range(heights.size()):
		var height: float = height_bytes.decode_float(index * 4)
		if not is_finite(height):
			errors.append("nonfinite_world_height")
			return errors
		heights[index] = height
		minimum = minf(minimum, height)
		maximum = maxf(maximum, height)
	var cell_count: int = (side - 1) * (side - 1)
	if not water_bytes.is_empty() and water_bytes.size() != cell_count:
		errors.append("invalid_world_water_byte_count")
		return errors
	if not landing_bytes.is_empty() and landing_bytes.size() != cell_count:
		errors.append("invalid_world_landing_byte_count")
		return errors
	_heights = heights
	grid_side = side
	tile_size = spacing
	_half_span = float(side - 1) * spacing / 2.0
	_minimum_y = minimum
	_maximum_y = maximum
	map_id = int(map_data.get("map_id", map_data.get("resource_id", 0)))
	var water_data: Dictionary = map_data.get("water", {})
	var project: Dictionary = map_data.get("project_environment", {})
	water_height = float(water_data.get("height", project.get("water_height", 0.0)))
	if not is_finite(water_height):
		errors.append("nonfinite_world_water_height")
		grid_side = 0
		return errors
	ceiling_height = float(map_data.get("flight_ceiling", INF))
	var margin_value: float = float(map_data.get("boundary_margin", 0.0))
	if is_nan(ceiling_height) or ceiling_height == -INF or not is_finite(margin_value) or margin_value < 0.0:
		errors.append("invalid_world_bounds")
		grid_side = 0
		return errors
	boundary_margin = clampf(margin_value, 0.0, _half_span * 0.49)
	ceiling_is_center_limit = bool(map_data.get("ceiling_is_center_limit", false))
	tile_rendering_enabled = bool(map_data.get("tile_rendering_enabled", int(map_data.get("source_map_info", {}).get("TileRenderingFlag", 1)) != 0))
	_landing = landing_bytes.duplicate()
	_water.resize(cell_count)
	_water.fill(0)
	if not water_bytes.is_empty():
		_water = water_bytes.duplicate()
	else:
		var wet_tiles: Array = water_data.get("active_tile_indices_source_xz", [])
		for tile: Variant in wet_tiles:
			if tile is Array and tile.size() >= 2:
				var x: int = int(tile[0])
				var z: int = int(tile[1])
				if x >= 0 and z >= 0 and x < side - 1 and z < side - 1:
					_water[x * (side - 1) + z] = 1
		if wet_tiles.is_empty() and int(water_data.get("active_patch_count", 0)) > 0:
			warnings.append("water_collision_requires_exact_tile_flags;80unit_render_patches_are_not_used_as_collision_tiles")
	for value: Variant in collider_records:
		if value is Dictionary:
			var collider_error: String = _add_collider(value)
			if not collider_error.is_empty():
				errors.append(collider_error)
	return errors


func is_configured() -> bool:
	return grid_side > 1 and not _heights.is_empty()


func get_bounds() -> Dictionary:
	# Finite fallback vertical envelope is a local guard, not a claimed legacy
	# altitude rule. A recovered flight_ceiling overrides the upper limit.
	var top: float = ceiling_height if is_finite(ceiling_height) else maxf(2048.0, _maximum_y + 1024.0)
	var edge: float = _half_span - boundary_margin
	return {"min": Vector3(-edge, _minimum_y - 1024.0 if tile_rendering_enabled else 0.0, -edge), "max": Vector3(edge, top, edge), "terrain_min": Vector3(-_half_span, _minimum_y, -_half_span), "terrain_max": Vector3(_half_span, _maximum_y, _half_span), "source_boundary_margin": boundary_margin, "tile_rendering_enabled": tile_rendering_enabled}


func sample_ground_height(x: float, z: float, include_water: bool = true) -> float:
	if not is_configured() or not is_finite(x) or not is_finite(z) or absf(x) > _half_span + EPS or absf(z) > _half_span + EPS:
		return NAN
	if not tile_rendering_enabled:
		# ShuttleChild.cpp:2165 clamps the craft center at Y0 on non-tile maps.
		# This is a navigation bound, not hidden terrain or a projectile collider.
		return 0.0
	var plane: Dictionary = _terrain_plane(Vector3(x, 0.0, z))
	var height: float = _plane_height(plane, Vector3(x, 0.0, z))
	if include_water and bool(plane["wet"]):
		height = maxf(height, water_height)
	return height


func sample_surface(x: float, z: float) -> Dictionary:
	var height: float = sample_ground_height(x, z, false)
	if not is_finite(height):
		return {"valid": false, "height": NAN, "normal": Vector3.UP, "kind": "outside"}
	var plane: Dictionary = _terrain_plane(Vector3(x, 0, z))
	var wet: bool = bool(plane["wet"]) and water_height > height
	return {"valid": true, "height": water_height if wet else height, "normal": Vector3.UP if wet else plane["normal"], "kind": "water" if wet else ("terrain" if tile_rendering_enabled else "native_navigation_floor")}


func probe_landing(position: Vector3, radius: float = 4.0, max_distance: float = 180.0, gear_id: String = "12003100") -> Dictionary:
	var surface: Dictionary = sample_surface(position.x, position.z)
	if not bool(surface["valid"]):
		return {"ok": false, "position": position, "normal": Vector3.UP, "distance": INF, "landable": false, "reason": "outside_world"}
	var down: Dictionary = trace_segment(position + Vector3.UP * 0.1, Vector3(position.x, float(surface["height"]) - 1.0, position.z))
	var ground: Vector3 = Vector3(position.x, float(surface["height"]), position.z)
	var normal: Vector3 = surface["normal"]
	var kind: String = str(surface["kind"])
	if bool(down["collided"]):
		ground = down["position"]
		normal = down["normal"]
		kind = str(down["kind"])
	var target: Vector3 = ground + Vector3.UP * radius
	var distance: float = position.y - ground.y
	var plane: Dictionary = _terrain_plane(position)
	var tile_index: int = int(plane["ix"]) * (grid_side - 1) + int(plane["iz"])
	var airport_tile: bool = not _landing.is_empty() and _landing[tile_index] != 0
	var is_a_gear: bool = gear_id == "12002100" or gear_id == "A-GEAR"
	var landable: bool = kind != "water" and normal.y >= 0.6 and (airport_tile or is_a_gear)
	return {"ok": landable and distance >= -0.5 and distance < max_distance, "position": target, "normal": normal, "distance": distance, "kind": kind, "landable": landable, "airport_tile": airport_tile, "source_tile_flag_known": not _landing.is_empty(), "reason": "water_steep_or_no_airport" if not landable else ("too_far" if distance >= max_distance else ""), "policy": "source_TryLandingState:airport_OR_Agear;distance<180;local_safety:dry_surface,normal_y>=0.6,clearance_radius"}


func ground_contact(position: Vector3, radius: float = 4.0) -> Dictionary:
	return probe_landing(position, radius, INF, "12002100")


func resolve_motion(previous: Vector3, desired: Vector3, radius: float = 4.0) -> Dictionary:
	var destination: Vector3 = desired
	if not tile_rendering_enabled and destination.is_finite():
		destination.y = maxf(0.0, destination.y)
	var hit: Dictionary = trace_segment(previous, destination, radius)
	if not tile_rendering_enabled and desired.is_finite() and desired.y < 0.0:
		hit["native_floor_clamped"] = true
	if bool(hit["collided"]):
		hit["position"] = (hit["position"] as Vector3) + (hit["normal"] as Vector3) * CONTACT_BIAS
	return hit


func resolve_ground_motion(previous: Vector3, desired: Vector3, radius: float = 4.0) -> Dictionary:
	if not is_configured() or not previous.is_finite() or not desired.is_finite() or radius < 0.0 or not is_finite(radius):
		return _trace_motion(previous, desired, radius, false)
	# Ground support is not an impact. Follow each original collision triangle,
	# then sweep original object triangles and source bounds along that path.
	var breaks: Array[float] = _terrain_breaks(previous, desired, 1.0)
	var start: Vector3 = previous
	var final_normal: Vector3 = Vector3.UP
	for index: int in range(1, breaks.size()):
		var endpoint: Vector3 = previous.lerp(desired, breaks[index])
		var surface: Dictionary = sample_surface(endpoint.x, endpoint.z)
		if not bool(surface["valid"]):
			return _trace_motion(start, endpoint, radius, false)
		endpoint.y = maxf(start.y, float(surface["height"]) + radius)
		var support: Dictionary = ground_contact(endpoint, radius)
		if not bool(support["ok"]):
			return _hit(breaks[index - 1], start, surface["normal"], str(surface["kind"]))
		endpoint = support["position"]
		var hit: Dictionary = _trace_motion(start, endpoint, radius, false)
		if bool(hit["collided"]):
			hit["t"] = lerpf(breaks[index - 1], breaks[index], float(hit["t"]))
			hit["position"] = (hit["position"] as Vector3) + (hit["normal"] as Vector3) * CONTACT_BIAS
			return hit
		start = endpoint
		final_normal = support["normal"]
	var result: Dictionary = _miss(start)
	result["normal"] = final_normal
	result["supported"] = true
	return result


func trace_segment(previous: Vector3, desired: Vector3, radius: float = 0.0) -> Dictionary:
	return _trace_motion(previous, desired, radius, true)


func _trace_motion(previous: Vector3, desired: Vector3, radius: float, include_ground: bool) -> Dictionary:
	var best: Dictionary = _miss(desired)
	if not is_configured() or not previous.is_finite() or not desired.is_finite() or not is_finite(radius) or radius < 0.0:
		best["error"] = "invalid_world_motion"
		best["position"] = previous if previous.is_finite() else Vector3.ZERO
		return best
	var safe_radius: float = minf(radius, _half_span * 0.49)
	var edge: float = _half_span - maxf(safe_radius, boundary_margin)
	var bounded_previous: Vector3 = previous
	bounded_previous.x = clampf(previous.x, -edge, edge)
	bounded_previous.z = clampf(previous.z, -edge, edge)
	if is_finite(ceiling_height):
		bounded_previous.y = minf(previous.y, ceiling_height - (0.0 if ceiling_is_center_limit else safe_radius))
	if not bounded_previous.is_equal_approx(previous):
		var inward: Vector3 = (bounded_previous - previous).normalized()
		var surface: float = sample_ground_height(bounded_previous.x, bounded_previous.z)
		bounded_previous.y = maxf(bounded_previous.y, surface + safe_radius)
		return _hit(0.0, bounded_previous, inward, "boundary")
	best = _boundary_hit(previous, desired, safe_radius)
	var stop_t: float = float(best["t"])
	if include_ground and tile_rendering_enabled:
		best = _choose(best, _ground_hit(previous, desired, safe_radius, stop_t))
	var direction: Vector3 = desired - previous
	for collider: Dictionary in _colliders:
		var box: AABB = collider["bounds"]
		box = box.grow(safe_radius)
		if not box.has_point(previous) and box.intersects_segment(previous, previous + direction * float(best["t"])) == null:
			continue
		var triangles: PackedVector3Array = collider["triangles"]
		for index: int in range(0, triangles.size(), 3):
			var candidate: Dictionary = _sweep_triangle(previous, direction, safe_radius, triangles[index], triangles[index + 1], triangles[index + 2])
			if bool(candidate["collided"]):
				candidate["kind"] = "object"
				candidate["object_id"] = str(collider["id"])
				candidate["source_code"] = int(collider["source_code"])
				best = _choose(best, candidate)
	return best


func collider_count() -> int:
	return _colliders.size()


func _terrain_plane(point: Vector3) -> Dictionary:
	var gx: float = clampf((point.x + _half_span) / tile_size, 0.0, float(grid_side - 1))
	var gz: float = clampf((_half_span - point.z) / tile_size, 0.0, float(grid_side - 1))
	var ix: int = mini(int(floor(gx)), grid_side - 2)
	var iz: int = mini(int(floor(gz)), grid_side - 2)
	if not tile_rendering_enabled:
		return {"base": 0.0, "dx": 0.0, "dz": 0.0, "ix": ix, "iz": iz, "normal": Vector3.UP, "wet": false}
	var fx: float = gx - float(ix)
	var fz: float = gz - float(iz)
	var a: float = _heights[ix * grid_side + iz]
	var b: float = _heights[ix * grid_side + iz + 1]
	var d: float = _heights[(ix + 1) * grid_side + iz]
	var c: float = _heights[(ix + 1) * grid_side + iz + 1]
	var dx: float
	var dz: float
	var base: float
	if fx + fz <= 1.0:
		dx = d - a
		dz = b - a
		base = a
	else:
		dx = c - b
		dz = c - d
		base = b + d - c
	return {"base": base, "dx": dx, "dz": dz, "ix": ix, "iz": iz, "normal": Vector3(-dx / tile_size, 1.0, dz / tile_size).normalized(), "wet": _water[ix * (grid_side - 1) + iz] == 1}


func _plane_height(plane: Dictionary, point: Vector3) -> float:
	var fx: float = (point.x + _half_span) / tile_size - float(plane["ix"])
	var fz: float = (_half_span - point.z) / tile_size - float(plane["iz"])
	return float(plane["base"]) + float(plane["dx"]) * fx + float(plane["dz"]) * fz


func _terrain_breaks(start: Vector3, end: Vector3, stop_t: float) -> Array[float]:
	var direction: Vector3 = end - start
	var breaks: Array[float] = [0.0, stop_t]
	var gx: float = (start.x + _half_span) / tile_size
	var gz: float = (_half_span - start.z) / tile_size
	var dx: float = direction.x / tile_size
	var dz: float = -direction.z / tile_size
	for axis: int in range(2):
		var origin: float = gx if axis == 0 else gz
		var delta: float = dx if axis == 0 else dz
		if absf(delta) < EPS:
			continue
		var last: float = origin + delta * stop_t
		var low: int = maxi(0, int(floor(minf(origin, last))))
		var high: int = mini(grid_side - 1, int(ceil(maxf(origin, last))))
		for line: int in range(low, high + 1):
			var t: float = (float(line) - origin) / delta
			if t > EPS and t < stop_t - EPS:
				breaks.append(t)
	breaks.sort()
	var cell_breaks: Array[float] = breaks.duplicate()
	if absf(dx + dz) > EPS:
		for index: int in range(cell_breaks.size() - 1):
			var middle: float = (cell_breaks[index] + cell_breaks[index + 1]) / 2.0
			var ix: int = mini(int(floor(gx + dx * middle)), grid_side - 2)
			var iz: int = mini(int(floor(gz + dz * middle)), grid_side - 2)
			var t: float = (float(ix + iz + 1) - gx - gz) / (dx + dz)
			if t > cell_breaks[index] + EPS and t < cell_breaks[index + 1] - EPS:
				breaks.append(t)
	breaks.sort()
	return breaks


func _ground_hit(start: Vector3, end: Vector3, radius: float, stop_t: float) -> Dictionary:
	var best: Dictionary = _miss(end)
	var direction: Vector3 = end - start
	var breaks: Array[float] = _terrain_breaks(start, end, stop_t)
	for index: int in range(breaks.size() - 1):
		var t0: float = breaks[index]
		var t1: float = breaks[index + 1]
		if t1 - t0 < EPS or t0 > float(best["t"]):
			continue
		var plane: Dictionary = _terrain_plane(start + direction * ((t0 + t1) / 2.0))
		var h0: float = _plane_height(plane, start + direction * t0)
		var h1: float = _plane_height(plane, start + direction * t1)
		best = _choose(best, _height_plane_hit(start, direction, radius, t0, t1, h0, h1, plane["normal"], "terrain"))
		if bool(plane["wet"]):
			best = _choose(best, _height_plane_hit(start, direction, radius, t0, t1, water_height, water_height, Vector3.UP, "water"))
	return best


static func _height_plane_hit(start: Vector3, direction: Vector3, radius: float, t0: float, t1: float, h0: float, h1: float, normal: Vector3, kind: String) -> Dictionary:
	var f0: float = start.y + direction.y * t0 - radius - h0
	var f1: float = start.y + direction.y * t1 - radius - h1
	if f0 >= -EPS and f1 >= -EPS:
		return _miss(start + direction)
	var t: float = t0 if f0 < 0.0 else lerpf(t0, t1, clampf(f0 / (f0 - f1), 0.0, 1.0))
	var position: Vector3 = start + direction * t
	if f0 < 0.0:
		position.y = h0 + radius
	return _hit(t, position, normal, kind)


func _boundary_hit(start: Vector3, end: Vector3, radius: float) -> Dictionary:
	var best: Dictionary = _miss(end)
	var direction: Vector3 = end - start
	var edge: float = _half_span - maxf(radius, boundary_margin)
	for axis: int in [0, 2]:
		if end[axis] > edge or end[axis] < -edge:
			var boundary: float = edge if end[axis] > edge else -edge
			var t: float = (boundary - start[axis]) / direction[axis]
			var normal: Vector3 = Vector3.ZERO
			normal[axis] = -1.0 if end[axis] > edge else 1.0
			best = _choose(best, _hit(t, start + direction * t, normal, "boundary"))
	var top: float = ceiling_height - (0.0 if ceiling_is_center_limit else radius)
	if is_finite(ceiling_height) and end.y > top:
		var t: float = (top - start.y) / direction.y
		best = _choose(best, _hit(t, start + direction * t, Vector3.DOWN, "boundary"))
	return best


func _add_collider(record: Dictionary) -> String:
	if int(record.get("collision", 0)) != 1:
		return ""
	var raw: Variant = record.get("triangles", PackedVector3Array())
	if not (raw is Array or raw is PackedVector3Array) or raw.is_empty() or raw.size() % 3 != 0:
		return "invalid_object_collision_triangles"
	var transform: Transform3D = record.get("transform", Transform3D.IDENTITY)
	var triangles: PackedVector3Array = PackedVector3Array()
	var bounds: AABB = AABB()
	var first: bool = true
	for index: int in range(0, raw.size(), 3):
		for point_index: int in range(index,index+3):
			if not _valid_vector(raw[point_index]):
				return "invalid_object_collision_vertex"
		var a: Vector3 = transform * _vector(raw[index])
		var b: Vector3 = transform * _vector(raw[index + 1])
		var c: Vector3 = transform * _vector(raw[index + 2])
		if not a.is_finite() or not b.is_finite() or not c.is_finite():
			return "nonfinite_object_collision_triangle"
		if (b - a).cross(c - a).length_squared() < EPS * EPS:
			continue
		for point: Vector3 in [a, b, c]:
			triangles.append(point)
			bounds = AABB(point, Vector3.ZERO) if first else bounds.expand(point)
			first = false
	if not triangles.is_empty():
		_colliders.append({"id": str(record.get("id", "")), "source_code": int(record.get("source_code", 0)), "bounds": bounds, "triangles": triangles})
	return ""


static func _sweep_triangle(start: Vector3, motion: Vector3, radius: float, a: Vector3, b: Vector3, c: Vector3) -> Dictionary:
	var best: Dictionary = _miss(start + motion)
	var normal: Vector3 = (b - a).cross(c - a).normalized()
	var closest: Vector3 = _closest_triangle(start, a, b, c)
	if start.distance_squared_to(closest) < radius * radius - EPS:
		var out: Vector3 = (start - closest).normalized()
		if out.length_squared() < EPS:
			out = normal if normal.dot(motion) <= 0.0 else -normal
		return _hit(0.0, closest + out * radius, out, "object")
	var distance: float = (start - a).dot(normal)
	var speed: float = motion.dot(normal)
	if absf(speed) > EPS:
		for sign_value: float in [-1.0, 1.0]:
			var t: float = (sign_value * radius - distance) / speed
			if t < -EPS or t > 1.0 + EPS or speed * sign_value >= 0.0:
				continue
			var center: Vector3 = start + motion * t
			var contact: Vector3 = center - normal * sign_value * radius
			if _inside_triangle(contact, a, b, c):
				best = _choose(best, _hit(t, center, normal * sign_value, "object"))
	if radius <= EPS:
		return best
	for vertex: Vector3 in [a, b, c]:
		var t: float = _quadratic_hit(motion.length_squared(), 2.0 * (start - vertex).dot(motion), start.distance_squared_to(vertex) - radius * radius)
		if t >= 0.0:
			var center: Vector3 = start + motion * t
			best = _choose(best, _hit(t, center, (center - vertex).normalized(), "object"))
	for edge: Array in [[a, b], [b, c], [c, a]]:
		var edge_start: Vector3 = edge[0]
		var direction: Vector3 = (edge[1] as Vector3) - edge_start
		var length2: float = direction.length_squared()
		if length2 < EPS:
			continue
		var relative: Vector3 = start - edge_start
		var perpendicular_start: Vector3 = relative - direction * (relative.dot(direction) / length2)
		var perpendicular_motion: Vector3 = motion - direction * (motion.dot(direction) / length2)
		var t: float = _quadratic_hit(perpendicular_motion.length_squared(), 2.0 * perpendicular_start.dot(perpendicular_motion), perpendicular_start.length_squared() - radius * radius)
		if t >= 0.0:
			var center: Vector3 = start + motion * t
			var u: float = (center - edge_start).dot(direction) / length2
			if u >= 0.0 and u <= 1.0:
				best = _choose(best, _hit(t, center, (center - (edge_start + direction * u)).normalized(), "object"))
	return best


static func _quadratic_hit(a: float, b: float, c: float) -> float:
	if a < EPS:
		return -1.0
	var discriminant: float = b * b - 4.0 * a * c
	if discriminant < 0.0:
		return -1.0
	var t: float = (-b - sqrt(maxf(discriminant, 0.0))) / (2.0 * a)
	return clampf(t, 0.0, 1.0) if t >= -EPS and t <= 1.0 + EPS else -1.0


static func _inside_triangle(point: Vector3, a: Vector3, b: Vector3, c: Vector3) -> bool:
	var u: Vector3 = b - a
	var v: Vector3 = c - a
	var w: Vector3 = point - a
	var uu: float = u.dot(u)
	var uv: float = u.dot(v)
	var vv: float = v.dot(v)
	var wu: float = w.dot(u)
	var wv: float = w.dot(v)
	var denominator: float = uu * vv - uv * uv
	if absf(denominator) < EPS:
		return false
	var s: float = (vv * wu - uv * wv) / denominator
	var t: float = (uu * wv - uv * wu) / denominator
	return s >= -EPS and t >= -EPS and s + t <= 1.0 + EPS


static func _closest_triangle(point: Vector3, a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	var ab: Vector3 = b - a
	var ac: Vector3 = c - a
	var ap: Vector3 = point - a
	var d1: float = ab.dot(ap)
	var d2: float = ac.dot(ap)
	if d1 <= 0.0 and d2 <= 0.0:
		return a
	var bp: Vector3 = point - b
	var d3: float = ab.dot(bp)
	var d4: float = ac.dot(bp)
	if d3 >= 0.0 and d4 <= d3:
		return b
	var vc: float = d1 * d4 - d3 * d2
	if vc <= 0.0 and d1 >= 0.0 and d3 <= 0.0:
		return a + ab * (d1 / (d1 - d3))
	var cp: Vector3 = point - c
	var d5: float = ab.dot(cp)
	var d6: float = ac.dot(cp)
	if d6 >= 0.0 and d5 <= d6:
		return c
	var vb: float = d5 * d2 - d1 * d6
	if vb <= 0.0 and d2 >= 0.0 and d6 <= 0.0:
		return a + ac * (d2 / (d2 - d6))
	var va: float = d3 * d6 - d5 * d4
	if va <= 0.0 and d4 - d3 >= 0.0 and d5 - d6 >= 0.0:
		return b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6)))
	var denominator: float = 1.0 / (va + vb + vc)
	return a + ab * (vb * denominator) + ac * (vc * denominator)


static func _choose(best: Dictionary, candidate: Dictionary) -> Dictionary:
	if not bool(candidate["collided"]):
		return best
	if not bool(best["collided"]) or float(candidate["t"]) < float(best["t"]) - EPS:
		return candidate
	if absf(float(candidate["t"]) - float(best["t"])) <= EPS and str(candidate["kind"]) in ["terrain", "water"] and (candidate["position"] as Vector3).y > (best["position"] as Vector3).y:
		return candidate
	return best


static func _hit(t: float, position: Vector3, normal: Vector3, kind: String) -> Dictionary:
	return {"collided": true, "position": position, "normal": normal, "kind": kind, "object_id": "", "t": clampf(t, 0.0, 1.0)}


static func _miss(position: Vector3) -> Dictionary:
	return {"collided": false, "position": position, "normal": Vector3.ZERO, "kind": "", "object_id": "", "t": 1.0}


static func _valid_vector(value: Variant) -> bool:
	if value is Vector3:
		return value.is_finite()
	if value is Array and value.size() == 3:
		for coordinate: Variant in value:
			if not (coordinate is int or coordinate is float) or not is_finite(float(coordinate)):
				return false
		return true
	return false


static func _vector(value: Variant) -> Vector3:
	if value is Vector3:
		return value
	if value is Array and value.size() >= 3:
		return Vector3(float(value[0]), float(value[1]), float(value[2]))
	return Vector3(NAN, NAN, NAN)
