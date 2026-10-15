extends SceneTree
## Focused native mission contract tests. Geometry/NPC eligibility is isolated
## in explicit fixtures; original objectives, rewards and item IDs are unchanged.
const Runtime = preload("res://scripts/world_runtime.gd")
var checks: int = 0
var failures: Array[String] = []
var native: Dictionary = {}


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var source: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets/local_world/mission_support.json"))
	for mission: Dictionary in source.records:
		native[str(mission.id)] = mission
	for identifier: String in ["153", "541", "914", "917"]:
		_check(native[identifier].runtime_supported, "source script is fully compiled:%s" % identifier)
		_test_optional_inventory(identifier)
	_test_preowned_proof_save()
	_test_absent_optional_inventory()
	_test_atomic_reward_rejection()
	_test_atomic_proof_rejection()
	_test_atomic_start_rejection()
	print(JSON.stringify({"suite":"world-mission-inventory", "checks":checks, "failures":failures.size(), "native_supported":source.summary.supported, "native_blocked":source.summary.blocked, "scope":"native_rules_with_isolated_map_and_eligibility_fixtures"}))
	for message: String in failures:
		printerr(JSON.stringify({"suite":"world-mission-inventory", "failure":message}))
	quit(0 if failures.is_empty() else 1)


func _fixture(identifier: String) -> Node3D:
	var world: Node3D = Runtime.new()
	root.add_child(world)
	var mission: Dictionary = native[identifier].duplicate(true)
	# This test verifies individual native transaction rules, without claiming
	# the fixture supplies original server spawns or campaign prerequisites.
	mission.prerequisites = []
	mission.required_level_min = 1
	mission.required_influence = 0
	mission.npc_id = 0
	mission.on_accept.warp_map_id = 3002
	mission.event_map_id = 3002
	mission.on_complete.warp_map_id = 3002
	var heights: PackedByteArray = PackedByteArray()
	heights.resize(9 * 9 * 4)
	world.configure({"maps":[{"map_id":3002, "metadata":{"vertex_side":9,"tile_size":40.0},"height_bytes":heights}], "mission_support":{"records":[mission]}, "local_scenario":{}})
	world.load_map(3002)
	for objective: Dictionary in mission.objectives:
		if objective.has("target_code"):
			world._actor_codes[int(objective.target_code)] = true
	return world


func _test_optional_inventory(identifier: String) -> void:
	var world: Node3D = _fixture(identifier)
	var item: int = int(native[identifier].external_inventory_items[0])
	_check(not world.accept_mission(identifier).get("ok", false), "unknown inventory cannot silently resolve optional items:%s" % identifier)
	world.set_inventory_counts([])
	_check(world.accept_mission(identifier).get("ok", false), "known empty inventory is legal for native optional rewards:%s" % identifier)
	var collected: Array = []
	world.local_event.connect(func(event: Dictionary) -> void:
		if str(event.get("type", "")) == "mission_item_collected":collected.append(event)
	)
	for objective: Dictionary in native[identifier].objectives:
		for index: int in range(int(objective.required)):
			world.record_target_destroyed(int(objective.target_code), "%s:%s:%s" % [identifier,objective.target_code,index])
	_check(not collected.any(func(event: Dictionary) -> bool: return event.items.any(func(row: Dictionary) -> bool: return int(row.item_num) == item)), "reward-only inventory item never becomes an invented monster drop:%s" % identifier)
	# A real inventory integration would apply the emitted proof atomically.
	var inventory: Array = [{"item_num":item,"count":3}]
	for objective: Dictionary in native[identifier].objectives:
		if objective.has("quest_item_num"):
			inventory.append({"item_num":int(objective.quest_item_num),"count":int(objective.required)})
	world.set_inventory_counts(inventory)
	var claimed: Dictionary = world.claim_reward(identifier)
	_check(claimed.get("ok", false), "original objectives and real optional inventory can be claimed:%s" % identifier)
	if claimed.get("ok", false):
		_check(claimed.reward.removals.any(func(row: Dictionary) -> bool: return int(row.item_num) == item and int(row.count) == 3), "native cleanup removes actual optional quantity:%s" % identifier)
		if identifier in ["153", "541"]:
			_check(int(claimed.reward.credits) == 240000, "native PER pays80000 times3 existing items:%s" % identifier)
		else:
			var random_total: int = 0
			for row: Dictionary in claimed.reward.items:
				if int(row.item_num) in [7005500,7005510,7005520]:random_total += int(row.count)
			_check(random_total == 3 and int(claimed.reward.credits) == 520000, "native weighted reward rolls once per3 optional tokens:%s" % identifier)
		_check(world.import_state(world.export_state()).get("ok", false), "native optional reward receipt survives validated restore:%s" % identifier)
		_check(not world.claim_reward(identifier).get("ok", false), "native optional reward cannot be paid twice:%s" % identifier)
	world.free()


func _test_preowned_proof_save() -> void:
	var world: Node3D = _fixture("105")
	world.set_inventory_counts([{"item_num":7011320,"count":5}])
	_check(world.accept_mission("105").get("ok", false), "original inventory possession can satisfy proofs owned before accept")
	var claimed: Dictionary = world.claim_reward("105")
	_check(claimed.get("ok", false) and world._progress["105"].counts[0] == 5, "claim persists possessed proof completion before physical removal")
	_check(world.import_state(world.export_state()).get("ok", false), "preowned proof completion restores without fictional kill events")
	world.free()


func _test_absent_optional_inventory() -> void:
	var world: Node3D = _fixture("153")
	world.set_inventory_counts([])
	world.accept_mission("153")
	for objective: Dictionary in native["153"].objectives:
		for index: int in range(int(objective.required)):
			world.record_target_destroyed(int(objective.target_code), "empty:%s:%d" % [objective.target_code,index])
	var claimed: Dictionary = world.claim_reward("153")
	_check(claimed.get("ok", false) and int(claimed.reward.credits) == 0 and int(claimed.reward.experience) == 1332759 and claimed.reward.removals.is_empty(), "absent optional source item grants no fabricated variable reward and blocks no completed native kill condition")
	world.free()


func _test_atomic_reward_rejection() -> void:
	var world: Node3D = _fixture("917")
	world.set_inventory_counts([{"item_num":7005580,"count":3},{"item_num":7005440,"count":1}])
	_check(world.accept_mission("917").get("ok", false), "atomic random reward fixture accepts original possession conditions")
	var before: Dictionary = world.export_state()
	var attempted: Array = []
	world.reward_applicator = func(event: Dictionary) -> bool:
		attempted.append(event.duplicate(true))
		return false
	var refused: Dictionary = world.claim_reward("917")
	_check(not refused.get("ok", false) and refused.get("error", "") == "inventory_reward_rejected", "inventory transaction rejection reaches caller")
	_check(world.export_state() == before, "rejected random reward preserves RNG, mission, wallet and pose atomically")
	_check(not world.drain_events().any(func(event: Dictionary) -> bool: return str(event.type) == "mission_reward"), "rejected inventory grant emits no completed reward")
	world.reward_applicator = func(event: Dictionary) -> bool:
		attempted.append(event.duplicate(true))
		return true
	var accepted: Dictionary = world.claim_reward("917")
	_check(accepted.get("ok", false) and bool(accepted.reward.get("inventory_applied", false)), "successful atomic grant marks event to prevent a second integration application")
	_check(attempted.size() == 2 and attempted[0] == attempted[1], "retry resolves identical native random rewards after rejected transaction")
	_check(not world.claim_reward("917").get("ok", false) and attempted.size() == 2, "already claimed reward never invokes inventory applicator again")
	world.free()


func _test_atomic_proof_rejection() -> void:
	var world: Node3D = _fixture("917")
	world.set_inventory_counts([])
	world.accept_mission("917")
	var before: Dictionary = world.export_state()
	world.reward_applicator = func(_event: Dictionary) -> bool:return false
	world.record_target_destroyed(2004700,"proof:rejected")
	var after: Dictionary = world.export_state()
	_check(after.progress == before.progress and int(after.proof_serial) == int(before.proof_serial), "refused proof creates no physical grant, counter, receipt or proof serial")
	_check(int(after.rng_state) != int(before.rng_state) and after.seen_targets.has("proof:rejected"), "refused proof still consumes its native random roll and unique kill")
	_check(not world.record_target_destroyed(2004700,"proof:rejected").get("ok", false) and int(world.export_state().rng_state) == int(after.rng_state), "rejected pickup cannot reroll the same defeated target")
	world.reward_applicator = func(_event: Dictionary) -> bool:return true
	world.record_target_destroyed(2004700,"proof:accepted")
	_check(int(world.export_state().proof_serial) == int(before.proof_serial) + 1 and int(world._progress["917"].counts[0]) == 1, "later successful unique pickup commits exactly one proof")
	_check(world.drain_events().filter(func(event: Dictionary) -> bool: return str(event.type) == "mission_item_collected" and bool(event.get("inventory_applied", false))).size() == 1, "successful proof event carries explicit no-double-apply flag")
	world.free()


func _test_atomic_start_rejection() -> void:
	var world: Node3D = _fixture("113")
	world._maps[3003] = world._maps[3002].duplicate(true)
	world._maps[3003].map_id = 3003
	world._missions["113"].on_accept.warp_map_id = 3003
	world._missions["113"].event_map_id = 3003
	# The baseline is a grounded pose; rollback must not apply the normal120-unit
	# arrival lift to an already valid player position.
	world._player_position = Vector3(100,4,0)
	var before: Dictionary = world.export_state()
	var transfers: Array = []
	world.map_changed.connect(func(event: Dictionary) -> void:transfers.append(int(event.map_id)))
	world.reward_validator = func(_event: Dictionary) -> bool:return false
	_check(not world.accept_mission("113").get("ok", false) and world.export_state() == before and transfers.is_empty(), "start inventory preflight refuses before accepting or changing maps")
	world.reward_validator = func(_event: Dictionary) -> bool:return true
	world.reward_applicator = func(_event: Dictionary) -> bool:return false
	var refused: Dictionary = world.accept_mission("113")
	_check(not refused.get("ok", false) and refused.get("error", "") == "inventory_start_rejected" and world.export_state() == before, "unexpected atomic start refusal restores mission, map, wallet and grounded pose")
	_check(transfers == [3003,3002] and not world.drain_events().any(func(event: Dictionary) -> bool: return str(event.type) == "mission_accepted"), "start rollback restores the previous scene and emits no accepted-item receipt")
	var applications: Array = []
	world.reward_applicator = func(event: Dictionary) -> bool:
		applications.append(event.duplicate(true))
		return true
	var accepted: Dictionary = world.accept_mission("113")
	_check(accepted.get("ok", false) and world.current_map_id == 3003 and applications.size() == 1, "successful start commits class-appropriate grant and mission map")
	_check(applications[0].items == [{"item_num":7000300,"count":1}] and world.drain_events().any(func(event: Dictionary) -> bool: return str(event.type) == "mission_accepted" and bool(event.get("inventory_applied", false))), "native class masks select one original start item and avoid integration double application")
	_check(not world.accept_mission("113").get("ok", false) and applications.size() == 1, "repeated acceptance cannot duplicate initial equipment")
	world.free()


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:failures.append(message)
