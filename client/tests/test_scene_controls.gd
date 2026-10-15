extends SceneTree

var scene: Node
var ticks := 0
var boosted_speed := 0.0
var paused_position := Vector3.ZERO
var failures: Array[String] = []


func _initialize() -> void:
	var packed := load("res://main.tscn") as PackedScene
	scene = packed.instantiate()
	root.add_child(scene)


func _event(action: String) -> void:
	var event := InputEventAction.new()
	event.action = action
	event.pressed = true
	Input.parse_input_event(event)


func _process(_delta: float) -> bool:
	ticks += 1
	if ticks == 10:
		Input.action_press("boost")
	elif ticks == 150:
		boosted_speed = scene.model.speed
		if boosted_speed <= scene.model.CRUISE_SPEED + 30.0:
			failures.append("Boost input did not reach the scene flight model")
		Input.action_release("boost")
		Input.action_press("brake")
	elif ticks == 280:
		if scene.model.speed >= boosted_speed - 30.0:
			failures.append("Brake input did not slow the scene")
		Input.action_release("brake")
		_event("pause_flight")
	elif ticks == 282:
		paused_position = scene.model.position
	elif ticks == 310:
		if not scene.is_paused or scene.model.position != paused_position:
			failures.append("Pause event did not freeze flight")
		_event("pause_flight")
	elif ticks == 315:
		_event("reset_flight")
	elif ticks == 317:
		if scene.is_paused or scene.model.position.distance_to(scene.model.START_POSITION) > 10.0:
			failures.append("Reset event did not restore the scene")
		if not failures.is_empty():
			for failure in failures:
				push_error(failure)
			quit(1)
		else:
			print("PASS: scene input dispatch — boost, brake, pause, resume, reset")
			quit(0)
	return false
