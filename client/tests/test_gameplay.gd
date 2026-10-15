extends SceneTree
## E2E production scene. Only poses, simulation scheduling and NPC AI are fixtures.
## Positive quest kills use unmodified native weapons, HP, damage and hit chances.

var scene: Node
var checks := 0
var failures: Array[String] = []
var kill_evidence: Array[Dictionary] = []
var transfers: Array[int] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	scene = (load("res://main.tscn") as PackedScene).instantiate()
	root.add_child(scene)
	scene.set_physics_process(false)
	scene.set_process(false)
	await process_frame
	_check(is_instance_valid(scene.world_runtime) and is_instance_valid(scene.combat_runtime), "main creates production world and combat runtimes")
	if not is_instance_valid(scene.world_runtime) or not is_instance_valid(scene.combat_runtime):
		await _finish()
		return
	_check(scene.current_map_id == 3002 and scene.world_runtime.current_map_id == 3002, "initial map is original3002 in both scene and world")
	_check(scene._combat_ready and scene.combat_runtime.snapshot().targets.size() == 3, "initial native Hornian encounter is ready")
	_check(scene.model.profile_ready and scene.model.engine_item_num == 7002570, "initial I-GEAR uses recovered engine ITEM")
	_check(scene.world_runtime.get_state().collision_gaps.is_empty(), "initial map has complete declared collision meshes")
	_quiet_ai()
	_render_hud()
	await _test_gear_and_input_masks()
	_test_collision_chain()
	await _test_native_quest_combat_reward()
	await _test_portal_transfers_preserve_state()
	_test_death_and_respawn()
	await _finish()


func _test_gear_and_input_masks() -> void:
	var expected := {"12000100": 1, "12001100": 16, "12002100": 256, "12003100": 4096}
	var seen: Dictionary = {}
	for index in range(4):
		await _tap("cycle_gear")
		var gear: String = scene.model.gear_id
		var combat: Dictionary = scene.combat_runtime.snapshot()
		seen[gear] = true
		var armor: Dictionary = scene.combat_runtime.inventory.armor_appearance()
		var visual_source := str(armor.get("model_id", gear)) if bool(armor.get("available", false)) else gear
		_check(expected.has(gear) and str(scene.ship.get_meta("original_source_id")) == visual_source and combat.gear_id == gear, "F2 binds owned native armor geometry, flight and combat GEAR together")
		for slot: String in ["armor", "radar"]:
			var native_item: Dictionary = scene.combat_runtime.inventory.catalog.get(int(scene.combat_runtime.inventory.equipped.get(slot, 0)), {})
			_check(not native_item.is_empty() and (int(native_item.get("ReqUnitKind", 0)) & int(expected.get(gear, 0))) != 0, "F2 keeps " + slot + " compatible with selected native GEAR class")
		_check((int(combat.weapons.primary.req_unit_kind) & int(expected.get(gear, 0))) != 0 and (int(combat.weapons.secondary.req_unit_kind) & int(expected.get(gear, 0))) != 0, "F2 equips native class-compatible primary and secondary")
		_render_hud()
	_check(seen.size() == 4, "real input traverses all four original GEAR profiles")
	# A failed essential loadout must leave flight, visuals and combat together.
	var inventory: Variant = scene.combat_runtime.inventory
	var quantities: Dictionary = inventory.quantities.duplicate()
	var previous_gear: String = scene.model.gear_id
	var previous_engine: int = scene.model.engine_item_num
	var previous_visual: Node = scene.ship_visual
	inventory.quantities.erase(7000040) # Next B-GEAR requires this owned primary.
	var invalid_before: Dictionary = scene.combat_runtime.export_state()
	await _tap("cycle_gear")
	_check(scene.model.gear_id == previous_gear and scene.original_scene_profile.active_gear_id == previous_gear and scene.model.engine_item_num == previous_engine, "failed F2 equipment transaction preserves selected flight class and engine")
	_check(scene.ship_visual == previous_visual and scene.combat_runtime.export_state() == invalid_before, "failed F2 equipment transaction preserves visible source model and entire combat state")
	inventory.quantities = quantities
	_quiet_ai()
	scene.model.position = Vector3(0, 1500, 1000)
	scene.ship.position = scene.model.position
	scene.model.movement_enabled = true
	Input.action_press("boost")
	_main_for(2.0)
	Input.action_release("boost")
	_check(scene.model.boosting and scene.model.speed > 190, "held boost reaches the production flight model")
	Input.action_press("brake")
	_main_for(1.0)
	Input.action_release("brake")
	_check(not scene.model.boosting and scene.model.speed < 140, "brake reaches the production flight model")
	scene.model.movement_enabled = false
	await _mouse_primary(true)
	var ammo: int = scene.combat_runtime.snapshot().primary_ammo
	scene._physics_process(1.0 / 60.0)
	await _mouse_primary(false)
	_check(int(scene.combat_runtime.snapshot().primary_ammo) == ammo - 1, "unhandled mouse input fires a real native weapon through main")
	await _tap("toggle_inventory")
	_check(scene.legacy_hud.inventory_items.visible and scene.legacy_hud.blocks_weapons(), "inventory input opens a weapon-blocking window")
	ammo = int(scene.combat_runtime.snapshot().primary_ammo)
	scene._primary_held = true
	_main_for(0.4)
	_check(int(scene.combat_runtime.snapshot().primary_ammo) == ammo, "inventory masks even a previously held fire button")
	scene._primary_held = false
	await _tap("toggle_inventory")
	scene.legacy_hud._chat_input.grab_focus()
	await process_frame
	var gear: String = scene.model.gear_id
	await _tap("cycle_gear")
	_check(scene.legacy_hud.wants_keyboard() and scene.model.gear_id == gear, "chat focus masks GEAR-switch input")
	ammo = int(scene.combat_runtime.snapshot().primary_ammo)
	scene._primary_held = true
	Input.action_press("boost")
	scene._physics_process(0.2)
	Input.action_release("boost")
	_check(int(scene.combat_runtime.snapshot().primary_ammo) == ammo and not scene.model.boosting, "chat masks fire and boost controls")
	scene._primary_held = false
	scene.legacy_hud._chat_input.release_focus()
	await _tap("toggle_world")
	var position: Vector3 = scene.model.position
	var elapsed: float = scene.combat_runtime.model.elapsed
	scene._primary_held = true
	scene._physics_process(0.5)
	_check(scene.legacy_hud.is_world_panel_open() and scene.model.position == position and scene.combat_runtime.model.elapsed == elapsed and not scene._primary_held, "world modal freezes simulation and clears held fire")
	await _tap("toggle_world")
	await _tap("pause_flight")
	elapsed = scene.combat_runtime.model.elapsed
	scene._physics_process(0.5)
	_check(scene.is_paused and scene.combat_runtime.model.elapsed == elapsed, "pause input freezes combat as well as flight")
	await _tap("pause_flight")
	scene._reset_flight()
	scene.model.movement_enabled = false
	_quiet_ai()


func _test_collision_chain() -> void:
	var before: Dictionary = scene.combat_runtime.snapshot()
	_collision_step(190.0)
	var after: Dictionary = scene.combat_runtime.snapshot()
	_check(scene.model.boundary_hit and scene.model.position.y >= scene.world_runtime.sample_ground_height(0, 0, true) + 4, "main resolves actual world terrain contact into corrected flight pose")
	var damage := (float(before.max_hp) + float(before.max_shield)) * 0.15
	var expected_shield := maxf(0.0, float(before.shield) - damage)
	var expected_hp := maxf(0.0, float(before.hp) - maxf(0.0, damage - float(before.shield)))
	_check(is_equal_approx(float(after.shield), expected_shield) and is_equal_approx(float(after.hp), expected_hp), "world→flight impact190 applies native15percent of current maxHP+maxDP to DP before HP")
	_check(scene.ship.position.is_equal_approx(scene.model.position), "world collision correction reaches the visible GEAR")
	scene._reset_flight()
	scene.model.movement_enabled = false
	_quiet_ai()


func _test_native_quest_combat_reward() -> void:
	var world: Node = scene.world_runtime
	_check(_mission("101").status == "available" and _mission("102").status == "locked", "native101 prerequisite gates102 at scene startup")
	await _tap("interact_world")
	_check(scene.legacy_hud.is_world_panel_open() and not world.get_state().nearby_interaction.is_empty(), "NPC interaction input opens mission dialogue")
	scene.legacy_hud.local_action_requested.emit("accept_mission:101")
	_check(_mission("101").status == "completed" and _mission("102").status == "available", "actual HUD signal completes dialogue101 and unlocks102")
	scene.legacy_hud.local_action_requested.emit("accept_mission:102")
	await process_frame
	_check(scene.current_map_id == 3302 and world.current_map_id == 3302 and scene.combat_runtime.snapshot().map_index == 3302, "accept102 warps world, rendered scene and combat encounter to3302")
	_check(_mission("102").status == "active", "native102 stays active until its actual kill objectives")
	_check(str(scene.original_scene_profile.terrain.resource_path).contains("/3302/"), "mission renders distinct original3302 terrain")
	transfers.append(3302)
	_render_hud()
	if scene.legacy_hud.is_world_panel_open():
		await _tap("toggle_world")
	var runtime: Node3D = scene.combat_runtime
	var counts: Dictionary = {}
	for target: Dictionary in runtime.model.targets:
		counts[int(target.monster_code)] = int(counts.get(int(target.monster_code), 0)) + 1
	_check(int(counts.get(2028200, 0)) == 1 and int(counts.get(2028100, 0)) == 3 and runtime.model.targets.size() == 4, "3302 encounter contains native fighter×1 and bomber×3")
	_check(not world.claim_reward("102").ok, "quest reward is rejected before any weapon kills")
	scene._drain_simulation_events()
	# Controlled poses/AI isolate combat geometry. HP, defenses, weapons, RNG,
	# ammunition, heat, hit probability and native damage equations stay unchanged.
	scene.model.position = Vector3(0, 1800, 0)
	scene.ship.position = scene.model.position
	scene.model.movement_enabled = false
	_quiet_ai()
	var start_ammo: int = runtime.snapshot().primary_ammo
	var start_secondary: int = runtime.snapshot().secondary_ammo
	_check(int(runtime.snapshot().weapons.primary.item_num) == 7000040 and int(runtime.snapshot().weapons.secondary.item_num) == 7901000, "positive kill path uses unchanged native B/M/I weapon ITEMs")
	for target: Dictionary in runtime.model.targets:
		target.position = Vector3(1000 + int(target.id) * 100, 1800, -1000)
		target.spawn_position = target.position
	for target: Dictionary in runtime.model.targets:
		var expected_hp := 112.0 if int(target.monster_code) == 2028200 else 96.0
		_check(float(target.hp) == expected_hp and float(target.max_hp) == expected_hp, "quest target starts with unchanged native HP")
		target.position = Vector3(0, 1800, -120)
		runtime.model.select_target(int(target.id))
		var iterations := 0
		while not bool(target.dead) and iterations < 900:
			runtime.advance(1.0 / 30.0, {"primary": true, "secondary": true, "aim_origin": scene.model.position, "aim_direction": Vector3.FORWARD}, {"position": scene.model.position, "forward": Vector3.FORWARD})
			for event: Dictionary in runtime._events:
				if str(event.get("type", "")) == "target_destroyed":
					kill_evidence.append(event.duplicate(true))
			scene._drain_simulation_events()
			iterations += 1
		_check(bool(target.dead), "native weapons kill quest species" + str(target.monster_code))
		# Disable only AI respawning; no kill, hit or objective event is injected.
		if target.dead:
			target.respawn_remaining = 10000.0
			target.spawn_position = Vector3(2000, 1800, -2000)
	var before_reward: Dictionary = runtime.snapshot()
	_check(int(before_reward.primary_ammo) < start_ammo and int(before_reward.secondary_ammo) < start_secondary, "positive combat path consumes real primary and missile ammunition")
	_check(kill_evidence.size() == 4, "four production target_destroyed events emerge from actual weapon resolution")
	for event: Dictionary in kill_evidence:
		_check(int(event.get("source_id", 0)) in [7000040, 7901000] and not str(event.get("instance_id", "")).is_empty(), "quest kill evidence identifies native weapon and unique target life")
	var mission: Dictionary = _mission("102")
	_check(mission.status == "ready" and mission.objectives[0].current == 1 and mission.objectives[1].current == 3, "main event drain advances native102 to exact1fighter/3bomber objective")
	scene.legacy_hud.local_action_requested.emit("claim_reward:102")
	await process_frame
	var after: Dictionary = runtime.snapshot()
	var wallet: Dictionary = world.get_state().wallet
	_check(_mission("102").status == "completed" and wallet.credits == 320 and wallet.experience == 91, "native102 grants exactly320SPI/91XP to world wallet")
	_check(int(after.credits) == 320 and int(after.experience) == 91, "main forwards original mission reward once to combat/session ledger")
	_check(scene.current_map_id == 2001 and world.current_map_id == 2001 and after.map_index == 2001, "original9999faction-city sentinel returns to real converted city2001 across all runtimes")
	_check(int(after.primary_ammo) == int(before_reward.primary_ammo) and int(after.secondary_ammo) == int(before_reward.secondary_ammo), "mission return does not refill spent ammunition")
	transfers.append(2001)
	_check(str(scene.original_scene_profile.terrain.resource_path).contains("/2001/"), "native city return renders city2001 terrain rather than reuse mission world")
	var native_npc: bool = false
	for npc: Dictionary in world._npcs:
		if int(npc.get("source_npc_index", 0)) == 3 and npc.has("source_event"):
			native_npc = true
	_check(native_npc, "returned city exposes original Diego position from DAT event9")
	_render_hud()
	scene.legacy_hud.local_action_requested.emit("claim_reward:102")
	scene._drain_simulation_events()
	_check(world.get_state().wallet.credits == 320 and runtime.snapshot().credits == 320 and runtime.snapshot().experience == 91, "repeating claim and event drain cannot pay native reward again")
	_check(not runtime.apply_reward({"reward_id": "mission:102", "credits": 320, "experience": 91}), "duplicate reward identity is rejected independently by session ledger")


func _test_portal_transfers_preserve_state() -> void:
	var world: Node = scene.world_runtime
	var city_resources: Dictionary = scene.combat_runtime.snapshot()
	# Explicit fixture uses the same available-map action exposed by the library.
	# This is local exploration, not a fabricated native portal or quest return.
	scene.legacy_hud.local_action_requested.emit("travel_map:3002")
	await process_frame
	_check(scene.current_map_id == 3002 and _same_resources(city_resources, scene.combat_runtime.snapshot()), "local library travel returns to3002 while preserving city resources")
	transfers.append(3002)
	_quiet_ai()
	scene.model.movement_enabled = false
	_collision_step(190.0)
	var before: Dictionary = scene.combat_runtime.snapshot()
	_check(float(before.shield) < float(before.max_shield) and int(before.primary_ammo) < 1000, "portal preservation fixture carries actual collision damage and spent weapon ammo")
	await _use_portal("portal:3002:203", 3003)
	var after: Dictionary = scene.combat_runtime.snapshot()
	_check(_same_resources(before, after), "portal3002→3003 preserves HP/DP/ammo/heat/cooldowns instead of healing/rearming")
	_check(scene.model.bounds_max.y == 2450.0 and str(scene.original_scene_profile.terrain.resource_path).contains("/3003/"), "portal destination installs source3003 bounds and distinct terrain")
	before = after.duplicate(true)
	await _use_portal("portal:3003:300", 3002)
	after = scene.combat_runtime.snapshot()
	_check(_same_resources(before, after), "return portal preserves session resources too")
	_check(world.get_state().wallet.credits == 320 and int(after.experience) == 91, "portals preserve quest rewards and completed progress")
	_check(_mission("102").status == "completed", "native quest completion survives portal round trip")


func _test_death_and_respawn() -> void:
	_quiet_ai()
	scene.model.movement_enabled = false
	var contacts := 0
	while not bool(scene.combat_runtime.snapshot().dead) and contacts < 10:
		_collision_step(190.0)
		contacts += 1
		if not scene.combat_runtime.snapshot().dead:
			_main_for(0.8)
	_check(scene.combat_runtime.snapshot().dead and not scene.model.movement_enabled and scene.model.speed == 0, "repeated real world impacts kill player and disable flight through event drain")
	_main_for(4.2)
	var after: Dictionary = scene.combat_runtime.snapshot()
	_check(not after.dead and after.hp == after.max_hp and after.shield == after.max_shield, "native local respawn timer restores player vitals")
	_check(scene.model.movement_enabled and scene.model.position.distance_to(scene.map_spawn) < 50.0, "respawn event re-enables flight at active map entry")
	_check(scene.ship.position.is_equal_approx(scene.model.position), "respawn synchronizes model and rendered GEAR")
	_check(int(after.credits) == 320 and int(after.experience) == 91, "death/respawn preserves awarded session progress")
	_render_hud()


func _collision_step(speed: float) -> void:
	var ground: float = scene.world_runtime.sample_ground_height(0, 0, true)
	scene.model.position = Vector3(0, ground + 1.0, 0)
	scene.model.orientation = Quaternion.IDENTITY
	scene.model.speed = speed
	scene.model.travel_speed = speed
	scene.model.movement_enabled = false
	scene.ship.position = scene.model.position
	scene._physics_process(1.0 / 120.0)


func _use_portal(identifier: String, destination: int) -> void:
	var portal: Dictionary = {}
	for candidate: Dictionary in scene.world_runtime._portals:
		if str(candidate.id) == identifier:
			portal = candidate
	_check(not portal.is_empty(), "native source portal is present:" + identifier)
	if portal.is_empty():
		return
	scene.model.position = portal.position
	scene.ship.position = scene.model.position
	scene.world_runtime.advance(1.0, scene.model.position)
	scene.world_runtime.advance(1.0, scene.model.position)
	await _tap("interact_world")
	_check(scene.current_map_id == destination and scene.world_runtime.current_map_id == destination and scene.combat_runtime.snapshot().map_index == destination, "E input transfers source portal into consistent destination runtimes")
	transfers.append(scene.current_map_id)
	_quiet_ai()
	scene.model.movement_enabled = false
	_render_hud()
	await process_frame


func _same_resources(a: Dictionary, b: Dictionary) -> bool:
	for key: String in ["hp", "shield", "primary_ammo", "secondary_ammo", "primary_heat_remaining", "secondary_heat_remaining", "primary_cooldown", "secondary_cooldown", "primary_overheated", "secondary_overheated", "dead", "credits", "experience"]:
		if a.get(key) != b.get(key):
			printerr("Transfer changed resource " + key + ":" + str(a.get(key)) + "→" + str(b.get(key)))
			return false
	return true


func _quiet_ai() -> void:
	for target: Dictionary in scene.combat_runtime.model.targets:
		target.hostile = false
		target.speed = 0.0


func _mission(identifier: String) -> Dictionary:
	for row: Dictionary in scene.world_runtime.get_state().missions:
		if str(row.id) == identifier:
			return row
	return {}


func _main_for(seconds: float) -> void:
	for index in range(roundi(seconds * 10.0)):
		scene._physics_process(0.1)


func _render_hud() -> void:
	# Exercise production _process/update_simulation on every visited map too.
	scene._process(1.0 / 60.0)
	_check(scene.legacy_hud._world_state.map_id == scene.current_map_id, "HUD processes production state for map" + str(scene.current_map_id))


func _tap(action: String) -> void:
	var event := InputEventAction.new()
	event.action = action
	event.pressed = true
	Input.parse_input_event(event)
	await process_frame
	event = InputEventAction.new()
	event.action = action
	event.pressed = false
	Input.parse_input_event(event)
	Input.action_release(action)
	await process_frame


func _mouse_primary(pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	event.position = root.get_visible_rect().size / 2.0
	Input.parse_input_event(event)
	await process_frame


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		printerr("GAMEPLAY CHECK FAILED: " + message)


func _finish() -> void:
	for action: StringName in InputMap.get_actions():
		Input.action_release(action)
	print(JSON.stringify({"suite": "gameplay_e2e", "checks": checks, "failures": failures.size(), "display": DisplayServer.get_name(), "visited_maps": transfers, "real_weapon_kills": kill_evidence, "fixture_scope": "main callbacks scheduled manually; poses/AI controlled, native weapons and target HP unchanged; no positive kill/objective event injected"}))
	if is_instance_valid(scene):
		scene.queue_free()
	await process_frame
	quit(0 if failures.is_empty() else 1)
