extends SceneTree

const Runtime = preload("res://scripts/world_runtime.gd")
var checks: int = 0
var failures: int = 0
var imported_maps: Array[int] = []

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var world: Node3D = Runtime.new()
	root.add_child(world)
	var configured: Dictionary = world.configure()
	_check(configured.map_count == 238 and configured.mission_count == 598, "all native map and quest rows remain catalogued")
	_check(configured.supported_mission_count == 541, "bounded compiler enables541 original quests and exposes56blocked scripts")
	var catalog: Dictionary = world.mission_catalog(0, 1000, true)
	_check(catalog.records.size() == 598 and catalog.blocked_count == 56, "UI can request the complete compact mission catalog")
	for row: Dictionary in catalog.records:
		_check(not row.has("dsl_ast") and not row.has("description"), "mission catalog excludes heavy original AST and prose:%s" % row.id)
	var detail: Dictionary = world.mission_details("102")
	_check(detail.get("ok", false) and not str(detail.get("description", "")).is_empty() and str(detail.get("dialogue", {}).get("pre_talk", "")).contains("320SPI") and detail.get("_source", {}).has("sha256") and not detail.has("dsl_ast"), "full original narrative and byte provenance are loaded only on demand")
	var page: Dictionary = world.mission_catalog(1, 7, true)
	_check(page.records.size() == 7 and page.page == 1 and page.total == 598, "mission catalog pagination preserves totals")
	_check(not world.accept_mission("105").ok and _mission(world, "105").runtime_supported, "native random-drop quest is compiled but still enforces real map/profile/prerequisite availability")
	_check(not world.accept_mission("110").ok and not _mission(world, "110").runtime_supported, "unsupported item-use quest cannot execute a partial script")
	var rows: Array = world.map_catalog()
	var available: int = 0
	for row: Dictionary in rows:
		if row.available:
			available += 1
	_check(available >= 3, "map availability requires real converted assets")
	var loaded: Dictionary = world.load_map(3002)
	_check(loaded.get("ok", false), "baseline source map still loads after library merge")
	_check(world.get_state().missions.size() <= 12 and world.get_state().support_diagnostics.total == 597, "frame snapshot stays compact while exposing full source totals")
	world.configure_player_profile({"influence": 1, "level": 9, "unit_kind": 4096, "start_city_map_id": 2001})
	_check(world.faction_city_map() == 2001 and world.resolve_destination_map(9998) == 3002, "normal faction uses native VCN starting city and garden")
	world.configure_player_profile({"influence": 4})
	_check(world.faction_city_map() == 2002 and world.resolve_destination_map(9998) == 3018, "ANI sentinels resolve native city2002 and garden3018")
	world.configure_player_profile({"influence": 1, "start_city_map_id": 2002})
	_check(world.faction_city_map() == 2002, "normal faction preserves chosen starting city per original AtumSJ")
	world.configure_player_profile({"influence": 1, "start_city_map_id": 2001})
	world.interact_nearest(loaded.spawn_position)
	_check(world.accept_mission("101").get("ok", false), "native initial dialogue still completes immediately")
	_check(world.accept_mission("102").get("ok", false), "native102 still accepts after101 and transfers to mission map")
	var objectives: Array = world.active_objectives()
	_check(objectives.size() == 2 and objectives[0].mission_id == "102" and objectives[0].map_id == 3302 and objectives[0].monster_code == 2028200, "combat receives native active objective codes and map restrictions")
	world.record_target_destroyed(2028200, "expansion:fighter:1")
	for index: int in range(3):
		world.record_target_destroyed(2028100, "expansion:bomber:%d" % index)
	_check(world.active_objectives().is_empty(), "completed proof objectives stop requesting encounters")
	var reward: Dictionary = world.claim_reward("102")
	_check(reward.get("ok", false) and reward.reward.credits == 320 and reward.reward.experience == 91 and reward.reward.items.is_empty(), "native102 reward retains exact money and experience")
	if _map(world, 2001).get("available", false):
		_check(world.current_map_id == 2001, "source faction-city sentinel now returns to converted city2001")
		var has_native_npc: bool = false
		for npc: Dictionary in world._npcs:
			if int(npc.get("source_npc_index", 0)) == 3:
				has_native_npc = npc.has("source_event") and int(npc.get("source_building_index", 0)) == 9007
		_check(has_native_npc, "city Diego uses original event9 placement and OMI building9007")
	var saved: Dictionary = world.export_state()
	var before_revision: int = int(world.get_state().revision)
	world.reset_session()
	_check(world.import_state(saved).get("ok", false), "validated original world progression restores after reset")
	_check(_mission(world, "101").status == "completed" and _mission(world, "102").status == "completed" and world.get_state().wallet.credits == 320, "completed missions and wallet persist without repaying rewards")
	_check(not world.claim_reward("102").get("ok", false) and not world.record_target_destroyed(2028200, "expansion:fighter:1").get("ok", false), "reward and kill deduplication survive save restore")
	_check(int(world.get_state().revision) > before_revision, "UI revision increments when progression is restored")
	var bad: Dictionary = saved.duplicate(true)
	bad.wallet.credits = -1
	_check(not world.import_state(bad).get("ok", false) and world.get_state().wallet.credits == 320, "invalid wallet is rejected atomically")
	bad = saved.duplicate(true)
	bad.progress["102"].counts[0] = 999
	_check(not world.import_state(bad).get("ok", false), "out-of-range saved objective counters are rejected")
	bad = saved.duplicate(true)
	bad.position = ["untrusted", 0, 0]
	_check(not world.import_state(bad).get("ok", false), "nonnumeric saved positions cannot silently become zero")
	bad = saved.duplicate(true)
	bad.mission_return_maps["102"] = {"invalid": "map"}
	_check(not world.import_state(bad).get("ok", false), "malformed return destinations are rejected before mutation")
	bad = saved.duplicate(true)
	bad.map_id = 999999
	_check(not world.import_state(bad).get("ok", false) and world.current_map_id == int(saved.map_id), "unavailable saved map cannot replace active original world")
	# Expanded native chain: real source NPC/map/monster resources gate103.
	var giver: Dictionary = {}
	for npc: Dictionary in world._npcs:
		if int(npc.get("source_npc_index", 0)) == 3:
			giver = npc
	if not giver.is_empty():
		world.interact_nearest(giver.position)
	var third: Dictionary = world.accept_mission("103")
	_check(third.get("ok", false) and world.current_map_id == 3303, "expanded native103 accepts at original cityNPC and loads real3303")
	if third.get("ok", false):
		var native_objectives: Array = world.active_objectives()
		_check(native_objectives.size() == 2 and native_objectives[0].target_code == 2002800 and native_objectives[0].required == 5 and native_objectives[1].target_code == 2003000 and native_objectives[1].required == 2, "expanded mission preserves original Watcher5 and Overwatcher2 objectives")
		for objective: Dictionary in native_objectives:
			for index: int in range(int(objective.required)):
				world.record_target_destroyed(int(objective.target_code), "unit103:%s:%s" % [objective.target_code, index])
		var third_reward: Dictionary = world.claim_reward("103")
		_check(third_reward.get("ok", false) and third_reward.reward.credits == 450 and third_reward.reward.experience == 141 and world.current_map_id == 2001, "expanded103 pays source450SPI141XP once and returns to native city")
		_check(world.get_state().wallet.credits == 770 and not world.claim_reward("103").get("ok", false), "expanded mission adds to preserved wallet without repeat payment")
	# Continue the real prerequisite chain into the newly recovered no-tile rooms.
	# This path never bypasses a prerequisite, map, profile or source objective.
	var campaign_inventory: Dictionary = {}
	world.set_inventory_counts([])
	world.local_event.connect(func(event: Dictionary) -> void:
		if str(event.get("type", "")) in ["mission_item_collected", "mission_accepted", "mission_reward"]:
			for item: Dictionary in event.get("removals", []):campaign_inventory[int(item.item_num)] = int(campaign_inventory.get(int(item.item_num),0)) - int(item.count)
			for item: Dictionary in event.get("items", []):campaign_inventory[int(item.item_num)] = int(campaign_inventory.get(int(item.item_num),0)) + int(item.count)
			world.set_inventory_counts(_inventory_rows(campaign_inventory))
	)
	_near_giver(world)
	var fourth: Dictionary = world.accept_mission("104")
	_check(fourth.get("ok",false) and world.current_map_id == 3351 and not world.collision_model.tile_rendering_enabled, "true native101→104 campaign now reaches object-only3351 without a fabricated tiled ground")
	if fourth.get("ok",false):
		world.record_target_destroyed(2015400,"campaign104:1")
		world.record_target_destroyed(2015400,"campaign104:2")
		_visit_original_event(world,3351,1005)
		_check(_mission(world,"104").status == "ready", "native104 requires both real guaranteed drops and recovered original terminal event1005")
		var fourth_reward: Dictionary = world.claim_reward("104")
		_check(fourth_reward.get("ok",false) and fourth_reward.reward.bonus_stats == 1 and world.current_map_id == 2001, "native104 pays bonus and returns to actual city after real prerequisite chain")
	_near_giver(world)
	var fifth: Dictionary = world.accept_mission("105")
	_check(fifth.get("ok",false) and world.current_map_id == 3002, "native105 becomes available from legitimately completed104")
	if fifth.get("ok",false):
		for index: int in range(64):
			if _mission(world,"105").status == "ready":break
			world.record_target_destroyed(2003800,"campaign105:%d" % index)
		_check(_mission(world,"105").status == "ready", "native105 probabilistic proofs complete through actual unique target deaths")
		_check(world.claim_reward("105").get("ok",false), "native105 real chain pays once after source drop requirement")
	_near_giver(world)
	var sixth: Dictionary = world.accept_mission("106")
	_check(sixth.get("ok",false) and world.current_map_id == 3301, "native106 reaches original3301 with preserved minimap area hint")
	if sixth.get("ok",false):
		world.record_target_destroyed(2017900,"campaign106:1")
		var sixth_reward: Dictionary = world.claim_reward("106")
		_check(sixth_reward.get("ok",false) and int(campaign_inventory.get(7009370,0)) == 1, "native106 source weapon reward enters real integration inventory")
	_near_giver(world)
	var seventh: Dictionary = world.accept_mission("107")
	_check(seventh.get("ok",false) and world.current_map_id == 3352 and int(campaign_inventory.get(7011340,0)) == 1, "native107 grants its source courier item and enters recovered no-tile3352")
	if seventh.get("ok",false):
		_visit_original_event(world,3352,1005)
		var seventh_reward: Dictionary = world.claim_reward("107")
		_check(seventh_reward.get("ok",false) and int(campaign_inventory.get(7011340,0)) == 0 and seventh_reward.reward.removals.size() == 1, "native107 source courier item is consumed once on actual original event visit")
		_check(not world.claim_reward("107").get("ok",false), "expanded real101→107 campaign preserves reward idempotence")
	var source: Dictionary = _read_json("res://assets/original_worlds/catalog.json")
	if not source.is_empty():
		var expected_available: int = 0
		for row: Dictionary in source.get("records", []):
			if row.get("available", false):
				expected_available += 1
		_check(available == expected_available, "all published available maps have imported real scene resources")
		_check(world._source_rules.portals.size() >= source.portals.size(), "all recovered native portal records join the session catalog")
		_check(world._source_rules.events.size() >= source.events.size(), "distinct event positions sharing an ID are preserved by source offset")
		for map_id: int in [2001, 2002, 3004, 3018, 3303, 6001]:
			if not _map(world, map_id).get("available", false):
				continue
			var result: Dictionary = world.load_map(map_id)
			_check(result.get("ok", false), "expanded original map loads its collision dataset:%d" % map_id)
			if result.get("ok", false):
				_check(is_finite(world.sample_ground_height(result.spawn_position.x, result.spawn_position.z)) and result.spawn_position.is_finite(), "expanded map has finite terrain queries:%d" % map_id)
				imported_maps.append(map_id)
			await process_frame
	world.free()
	_test_new_mission_contracts()
	print(JSON.stringify({"suite":"world-expansion", "status":"pass" if failures == 0 else "fail", "checks":checks, "failures":failures, "sampled_maps":imported_maps, "available_maps":available, "native_missions_supported":541, "native_missions_blocked":56}))
	quit(0 if failures == 0 else 1)

func _mission(world: Node, identifier: String) -> Dictionary:
	for row: Dictionary in world.mission_catalog(0, 1000, true).records:
		if str(row.id) == identifier:
			return row
	return {}

func _map(world: Node, identifier: int) -> Dictionary:
	for row: Dictionary in world.map_catalog():
		if int(row.map_id) == identifier:
			return row
	return {}

func _read_json(path: String) -> Dictionary:
	var result: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return result if result is Dictionary else {}

func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		printerr(JSON.stringify({"suite":"world-expansion", "failure":message}))

func _test_new_mission_contracts() -> void:
	var world: Node3D = Runtime.new()
	root.add_child(world)
	world.configure()
	var inventory: Dictionary = {}
	var collected: Array[Dictionary] = []
	world.local_event.connect(func(event: Dictionary) -> void:
		if str(event.get("type", "")) in ["mission_item_collected", "mission_accepted", "mission_reward"]:
			for item: Dictionary in event.get("removals", []):
				inventory[int(item.item_num)] = int(inventory.get(int(item.item_num), 0)) - int(item.count)
			for item: Dictionary in event.get("items", []):
				inventory[int(item.item_num)] = int(inventory.get(int(item.item_num), 0)) + int(item.count)
			world.set_inventory_counts(_inventory_rows(inventory))
		if str(event.get("type", "")) == "mission_item_collected":
			collected.append(event.duplicate(true))
	)
	world.set_inventory_counts([])
	world.load_map(3002)
	# Isolate the source105 rule without pretending its absent104-map prerequisite
	# can be completed. No published mission/profile/prerequisite is changed.
	world._missions["105"]["prerequisites"] = []
	world.configure_player_profile({"level":9,"influence":1,"unit_kind":4096})
	_check(world.accept_mission("105").get("ok",false), "native105 drop rule accepts in isolated prerequisite fixture with real3002 assets")
	world.record_target_destroyed(2003800,"rng:before")
	var checkpoint: Dictionary = world.export_state()
	var checkpoint_inventory: Dictionary = inventory.duplicate()
	collected.clear()
	for index: int in range(16):
		world.record_target_destroyed(2003800,"rng:future:%d" % index,Vector3(4000,300,-4000))
	var first_events: Array = collected.duplicate(true)
	var first_rng: int = int(world.export_state().rng_state)
	_check(first_events.size() > 0 and first_events.size() < 16, "native800000/1000000 probability yields actual successful and failed proof drops")
	_check(_mission(world,"105").status == "ready" and _mission(world,"105").objectives[0].current == 5, "attached monster AREA remains navigation hint while real native item quantities satisfy source objective")
	inventory.clear()
	inventory.merge(checkpoint_inventory)
	world.set_inventory_counts(_inventory_rows(inventory))
	_check(world.import_state(checkpoint).get("ok",false), "partial random-drop mission restores validated deterministic state")
	collected.clear()
	for index: int in range(16):
		world.record_target_destroyed(2003800,"rng:future:%d" % index,Vector3(4000,300,-4000))
	_check(collected == first_events and int(world.export_state().rng_state) == first_rng, "save/reload preserves both drop outcomes and unique proof reward IDs")
	var serial: int = int(world.export_state().proof_serial)
	_check(not world.record_target_destroyed(2003800,"rng:future:0").ok and int(world.export_state().proof_serial) == serial, "duplicate target cannot mint another physical mission proof")
	var result: Dictionary = world.claim_reward("105")
	_check(result.get("ok",false) and result.reward.credits == 680 and result.reward.removals.size() == 1 and int(inventory.get(7011320,0)) == 0, "native105 reward removes actual quest proofs atomically through integration contract")
	_check(not world.claim_reward("105").get("ok",false), "random-drop quest still pays its source reward once")
	_check(world.sync_inventory_wallet(500,391).get("ok",false) and world.get_state().wallet.credits_earned == 680 and world.get_state().wallet.credits == 500, "verified economic balance sync preserves separate earned mission ledger")
	_check(not world.sync_inventory_wallet(501,392).get("ok",false) and world.get_state().wallet.experience == 391, "economic sync cannot mint experience")
	var economic_save: Dictionary = world.export_state()
	_check(world.import_state(economic_save).get("ok",false) and world.get_state().wallet.credits == 500, "spent economic balance restores without corrupting earned quest totals")
	var forged: Dictionary = economic_save.duplicate(true)
	forged.wallet.credits_earned += 1
	_check(not world.import_state(forged).get("ok",false), "forged earned credit ledger is rejected")
	forged = economic_save.duplicate(true)
	forged.progress["105"].reward_experience += 1
	_check(not world.import_state(forged).get("ok",false), "forged mission reward XP is rejected against native source")
	forged = economic_save.duplicate(true)
	forged.rng_state = -1
	_check(not world.import_state(forged).get("ok",false), "negative RNG checkpoint cannot replace current world")
	var source_choices: Array = world._missions["163"].random_item_rewards[0].choices
	var original_sync: bool = world._inventory_synchronized
	world._inventory_synchronized = false
	var weighted: Dictionary = world._resolved_reward(world._missions["163"], {"proof_counts":{"7005750":2}})
	world._inventory_synchronized = original_sync
	var total_items: int = 0
	var allowed_choices: bool = true
	for item: Dictionary in weighted.items:
		total_items += int(item.count)
		allowed_choices = allowed_choices and source_choices.any(func(choice: Dictionary) -> bool: return int(choice.item_num) == int(item.item_num))
	_check(total_items == 6 and allowed_choices, "native weighted OR reward performs one source choice per proof item and preserves quantity3")
	world.reset_session()
	inventory.clear()
	world.set_inventory_counts([])
	world.load_map(3002)
	world._missions["109"]["prerequisites"] = []
	_check(world.accept_mission("109").get("ok",false) and world.current_map_id == 3306, "native timed109 loads recovered3306 terrain in isolated rule fixture")
	for index: int in range(7):
		world.record_target_destroyed(2018000,"per:%d" % index)
	world.advance(299.0,world._player_position)
	_check(_mission(world,"109").status == "ready" and is_equal_approx(_mission(world,"109").remaining_seconds,1.0), "native five-minute limit tracks only supplied active simulation delta")
	result = world.claim_reward("109")
	_check(result.get("ok",false) and result.reward.credits == 1400 and result.reward.experience == 3171 and int(inventory.get(7002690,0)) == 0, "native PER source pays200SPI times7 actual proofs and consumes proofs")
	_check(world.import_state(world.export_state()).get("ok",false), "variable native PER reward receipt survives validated save restore")
	world.reset_session()
	inventory.clear()
	world.set_inventory_counts([])
	world.load_map(3002)
	_check(world.accept_mission("109").get("ok",false), "timed source mission can be isolated again for expiry test")
	world.advance(301.0,world._player_position)
	_check(_mission(world,"109").status == "failed" and not world.claim_reward("109").get("ok",false) and world.get_state().wallet.experience == 0, "expired native timer blocks reward rather than silently ignoring time limit")
	_check(world.import_state(world.export_state()).get("ok",false), "failed timer state persists and cannot regain an unearned reward on reload")
	world.reset_session()
	inventory.clear()
	world.set_inventory_counts([])
	world.load_map(2001)
	world._missions["118"]["prerequisites"] = []
	world.configure_player_profile({"level":16,"influence":2})
	var giver: Dictionary = {}
	for npc: Dictionary in world._npcs:
		if int(npc.get("source_npc_index",0)) == 3:
			giver = npc
	if not giver.is_empty():world.interact_nearest(giver.position)
	_check(world.accept_mission("118").get("ok",false) and world.current_map_id == 3067, "native crafting quest118 retains real3067 and native class/profile requirements")
	world.record_target_destroyed(2004000,"mix:ingredient:1")
	world.record_target_destroyed(2008800,"mix:ingredient:2")
	_check(int(inventory.get(7008720,0)) == 1 and int(inventory.get(7901550,0)) == 1 and _mission(world,"118").status == "active", "native proof drops become real crafting ingredients without completing missing result objective")
	inventory.erase(7008720)
	inventory.erase(7901550)
	inventory[7901560] = 1
	world.set_inventory_counts(_inventory_rows(inventory))
	_check(_mission(world,"118").status == "ready" and world.active_objectives().is_empty(), "native TargetMixItemTarget possession overrides consumed ingredient requirements per server source")
	result = world.claim_reward("118")
	_check(result.get("ok",false) and result.reward.credits == 8840 and result.reward.bonus_stats == 1 and result.reward.removals.is_empty(), "native118 pays source reward and does not delete already consumed craft ingredients twice")
	_check(world.import_state(world.export_state()).get("ok",false), "completed mixed-item quest restores despite consumed proof ingredients")
	world.load_map(2001)
	var contacts: Array = world.service_contacts()
	var laboratory: Dictionary = {}
	for contact: Dictionary in contacts:
		if int(contact.get("source_building_index",0)) == 9003:laboratory = contact
	_check(not laboratory.is_empty() and laboratory.native_position and laboratory.service_symbol == "BUILDINGKIND_LABORATORY" and laboratory.building_kind == 10, "native DAT building9003 connects to exact OMI laboratory service")
	if not laboratory.is_empty():
		var nearby: Dictionary = world.nearby_service(laboratory.position)
		_check(not nearby.is_empty() and nearby.native_position and nearby.in_range and nearby.distance == 0.0, "service proximity uses original NPC position and explicit local interaction range")
	_check(world.nearby_service(Vector3(100000,100000,100000)).is_empty(), "distant native services never become nearby through catalog presence")
	world.load_map(3002)
	for contact: Dictionary in world.service_contacts():
		if not contact.native_position:
			_check(world.nearby_service(contact.position).is_empty(), "adapted fallback dialogue NPC cannot pretend to be a native service placement")
	_check(world.receive_local_event({"type":"skill_used","item_num":7830011,"count":1,"event_id":"skill:verified:1"}).get("ok",false), "trusted successful skill event has explicit integration contract")
	_check(not world.receive_local_event({"type":"skill_used","item_num":7830011,"count":1,"event_id":"skill:verified:1"}).get("ok",false), "successful skill event is deduplicated")
	_check(not _mission(world,"110").runtime_supported, "receiving a skill event does not silently guess unsupported modern native quest semantics")
	_check(not world.receive_local_event({"type":"skill_used","item_num":{},"event_id":"bad"}).get("ok",false), "malformed local events are rejected before state mutation")
	_check(not world.set_inventory_counts([{"item_num":1,"count":-1}]).get("ok",false), "negative inventory snapshots cannot create quest progress")
	world.free()

func _inventory_rows(values: Dictionary) -> Array:
	var rows: Array = []
	for item: int in values:
		if int(values[item]) > 0:rows.append({"item_num":item,"count":int(values[item])})
	return rows


func _near_giver(world: Node) -> void:
	for npc: Dictionary in world._npcs:
		if int(npc.get("source_npc_index",0)) == 3:
			world.interact_nearest(npc.position)
			return

func _visit_original_event(world: Node, map_id: int, event_id: int) -> void:
	for event: Dictionary in world._source_rules.events:
		if int(event.get("map_id",0)) == map_id and int(event.get("event_id",0)) == event_id:
			world.advance(0.0,world._vector(event.position))
			return
