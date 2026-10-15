extends SceneTree
## Ledger integration with actual SQL Hornian rewards and native mission105.
## Map geometry and NPC eligibility are isolated, not original spawn claims.
const World = preload("res://scripts/world_runtime.gd")
const Inventory = preload("res://scripts/inventory_model.gd")
const Services = preload("res://scripts/service_model.gd")
const NativeServer = preload("res://scripts/native_server_data.gd")
var checks: int = 0
var failures: Array[String] = []
var native_mission: Dictionary = {}
var native_rewards: RefCounted


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var source: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets/local_world/mission_support.json"))
	for row: Dictionary in source.records:
		if str(row.id) == "105":native_mission = row
	var catalog := Inventory.new()
	_check(catalog.configure(), "native inventory catalog loads")
	var client_monster: Dictionary = {}
	var monsters: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets/original_library/catalogs/monsters.json"))
	for row: Dictionary in monsters.records:
		if int(row.MonsterUnitKind) == 2000000:client_monster = row
	# Exact static rows recovered from pinned SQL backup e5ae92ac...b4a4674.
	# ti_Monster SHA55199710...443c15 and ti_MonsterItem SHA06fa411e...64ecf.
	native_rewards = NativeServer.new()
	var loaded: Dictionary = native_rewards.configure(
		{"schema_version":1,"columns":["UniqueNumber","Level","Experience","Belligerence","MPOption"],"rows":[[2000000,9,82,1,1]]},
		{"schema_version":1,"columns":["MonsterUniqueNumber","ItemNum","MinCount","MaxCount","Probability","PrefixProbability","SuffixProbability","DropType"],"rows":[[2000000,7000022,32,98,1000000,0,0,0]]},
		catalog.catalog, {2000000:client_monster})
	_check(loaded.get("ok", false), "verified Hornian SQL drop rule configures against current client items")
	_test_inventory_mission_combat_and_shop()
	_test_old_save_migration()
	_test_rejected_events()
	_test_rejected_saves()
	_test_bounds_and_reset()
	print(JSON.stringify({"suite":"combat-ledger","checks":checks,"failures":failures.size(),"scope":"native_SQL_rewards;native_mission105;isolated_map_and_NPC_eligibility"}))
	for message: String in failures:printerr(JSON.stringify({"suite":"combat-ledger","failure":message}))
	quit(0 if failures.is_empty() else 1)


func _fixture() -> Node3D:
	var world := World.new()
	root.add_child(world)
	var mission: Dictionary = native_mission.duplicate(true)
	mission.prerequisites = []
	mission.required_level_min = 1
	mission.required_influence = 0
	mission.npc_id = 0
	mission.on_complete.warp_map_id = 3002
	var heights := PackedByteArray()
	heights.resize(9 * 9 * 4)
	world.configure({"maps":[{"map_id":3002,"metadata":{"vertex_side":9,"tile_size":40.0},"height_bytes":heights}],"mission_support":{"records":[mission]},"local_scenario":{}})
	world.load_map(3002)
	world._actor_codes[2003800] = true
	return world


func _native_event(identifier: String) -> Dictionary:
	var result: Dictionary = native_rewards.roll_rewards(2000000, 9, func(minimum: int, _maximum: int) -> int:return minimum)
	result["type"] = "native_pve_reward"
	result["reward_id"] = "native-pve:" + identifier
	result["inventory_applied"] = true
	return result


func _claim_native_mission(world: Node3D, inventory: RefCounted) -> void:
	inventory.add_item(7011320, 5)
	world.set_inventory_counts([{"item_num":7011320,"count":5}])
	world.reward_applicator = func(event: Dictionary) -> bool:return inventory.apply_reward(event)
	_check(world.accept_mission("105").get("ok", false), "mission105 accepts native preowned proof items")
	_check(world.claim_reward("105").get("ok", false), "mission105 commits original680SPI/391XP atomically")


func _test_inventory_mission_combat_and_shop() -> void:
	var world: Node3D = _fixture()
	var inventory := Inventory.new()
	inventory.configure()
	_claim_native_mission(world, inventory)
	var event: Dictionary = _native_event("hornian:life:1")
	_check(event.get("ok", false) and int(event.credits) == 32 and int(event.experience) == 82, "real Hornian row resolves minimum32SPI and82rawXP through native reward logic")
	_check(inventory.apply_reward(event) and world.record_combat_reward(event), "successful inventory grant is recorded once in independent combat ledger")
	var wallet: Dictionary = world.get_state().wallet
	_check(int(wallet.credits) == inventory.credits and int(wallet.experience) == inventory.experience and inventory.credits == 712 and inventory.experience == 473, "combined mission and combat balances match real inventory")
	_check(int(wallet.mission_credits_earned) == 680 and int(wallet.mission_experience) == 391 and int(wallet.combat_credits_earned) == 32 and int(wallet.combat_experience) == 82 and int(wallet.combat_kills) == 1, "separate mission and combat earnings retain original amounts")
	_check(world.sync_inventory_wallet(inventory.credits, inventory.experience).get("ok", false), "raw XP synchronization accepts combined ledgers")
	var before: Dictionary = world.export_state()
	_check(not world.record_combat_reward(event) and world.export_state() == before, "event replay cannot duplicate combat XP or money")
	var services := Services.new()
	_check(services.configure(inventory, {"schema_version":1,"stock_item_nums":[7004000],"recipes":[]}), "isolated merchant uses actual native item catalog")
	var bought: Dictionary = services.buy(7004000, 100)
	_check(bought.get("ok", false) and int(bought.get("cost", -1)) == 7, "merchant spends actual native7SPI bullet bundle from earned income")
	_check(world.sync_inventory_wallet(inventory.credits, inventory.experience).get("ok", false), "merchant spending synchronizes balance after combat income")
	wallet = world.get_state().wallet
	_check(int(wallet.credits) == 705 and int(wallet.credits_earned) == 712 and int(wallet.experience) == 473 and int(wallet.combat_credits_earned) == 32 and int(wallet.mission_credits_earned) == 680, "spending changes current balance and preserves independent earned ledgers")
	var saved: Dictionary = JSON.parse_string(JSON.stringify(world.export_state()))
	var restored: Node3D = _fixture()
	var restored_inventory := Inventory.new()
	restored_inventory.configure()
	var inventory_saved: Dictionary = JSON.parse_string(JSON.stringify(inventory.export_state()))
	_check(restored_inventory.import_state(inventory_saved).get("ok", false), "real inventory reward receipts survive JSON roundtrip")
	_check(restored.import_state(saved).get("ok", false), "mixed mission/combat ledger survives validated JSON roundtrip after merchant spending")
	var restored_world: Dictionary = restored.export_state()
	var original_world: Dictionary = world.export_state()
	_check(restored_world.wallet == original_world.wallet and restored_world.combat_rewards == original_world.combat_rewards and restored_world.combat_totals == original_world.combat_totals and int(restored_world.progress["105"].reward_credits) == 680 and int(restored_world.progress["105"].reward_experience) == 391, "JSON world restore preserves exact receipts and separate earnings")
	_check(restored.sync_inventory_wallet(restored_inventory.credits, restored_inventory.experience).get("ok", false), "restored inventory agrees with both reward ledgers")
	_check(not restored.record_combat_reward(event) and not restored_inventory.apply_reward(event), "both independent ledgers reject reward replay after restore")
	before = restored.export_state()
	_check(not restored.sync_inventory_wallet(restored_inventory.credits, restored_inventory.experience + 1).get("ok", false) and restored.export_state() == before, "economic synchronization cannot mint XP")
	world.free()
	restored.free()


func _test_old_save_migration() -> void:
	var world: Node3D = _fixture()
	var inventory := Inventory.new()
	inventory.configure()
	_claim_native_mission(world, inventory)
	var old: Dictionary = JSON.parse_string(JSON.stringify(world.export_state()))
	old.erase("combat_rewards")
	old.erase("combat_totals")
	var restored: Node3D = _fixture()
	_check(restored.import_state(old).get("ok", false), "native0.8 mission-only save without combat fields remains valid")
	var exported: Dictionary = restored.export_state()
	_check(exported.combat_rewards.is_empty() and exported.combat_totals == {"credits_earned":0,"experience":0,"kills":0} and int(exported.wallet.credits) == int(old.wallet.credits) and int(exported.wallet.credits_earned) == int(old.wallet.credits_earned) and int(exported.wallet.experience) == int(old.wallet.experience), "old saves migrate to empty combat ledger without changing earned mission XP")
	var event: Dictionary = _native_event("after0.8migration")
	_check(inventory.apply_reward(event) and restored.record_combat_reward(event) and restored.import_state(restored.export_state()).get("ok", false), "migrated mission save can earn and restore actual native combat reward")
	old.wallet.experience = int(old.wallet.experience) + 1
	var before: Dictionary = restored.export_state()
	_check(not restored.import_state(old).get("ok", false) and restored.export_state() == before, "missing old combat fields cannot explain forged mission XP")
	world.free()
	restored.free()


func _test_rejected_events() -> void:
	var world: Node3D = _fixture()
	var valid: Dictionary = _native_event("reject-fixture")
	var cases: Array[Dictionary] = []
	for update: Dictionary in [{"type":"mission_reward"},{"inventory_applied":false},{"inventory_applied":"true"},{"reward_id":""},{"reward_id":"mission:105"},{"reward_id":52},{"reward_id":"native-pve:"},{"source_kind":"player"},{"monster_code":0},{"monster_code":1.5},{"monster_code":2147483648},{"credits":-1},{"credits":1.5},{"credits":1000000001},{"experience":-1},{"experience":1.5},{"experience":INF},{"experience":NAN},{"experience":"82"},{"experience":9000000000000001}]:
		var bad: Dictionary = valid.duplicate(true)
		bad.merge(update, true)
		cases.append(bad)
	for key: String in ["reward_id","source_kind","monster_code","credits","experience","inventory_applied"]:
		var bad: Dictionary = valid.duplicate(true)
		bad.erase(key)
		cases.append(bad)
	var before: Dictionary = world.export_state()
	var revision: int = world._revision
	for index: int in range(cases.size()):
		_check(not world.record_combat_reward(cases[index]) and world.export_state() == before and int(world._revision) == revision, "malformed/uncommitted event rejects without mutation:%d" % index)
	_check(world.record_combat_reward(valid), "valid event remains usable after rejected events")
	before = world.export_state()
	valid.credits = 33
	_check(not world.record_combat_reward(valid) and world.export_state() == before, "same defeated life cannot be credited again with altered amount")
	world.free()


func _test_rejected_saves() -> void:
	var world: Node3D = _fixture()
	world.record_combat_reward(_native_event("save-corruption"))
	var before: Dictionary = world.export_state()
	var cases: Array[Dictionary] = []
	for update: Dictionary in [{"combat_rewards":{}},{"combat_totals":[]},{"combat_rewards":[42]}]:
		var bad: Dictionary = before.duplicate(true)
		bad.merge(update, true)
		cases.append(bad)
	var duplicate: Dictionary = before.duplicate(true)
	duplicate.combat_rewards.append(duplicate.combat_rewards[0].duplicate(true))
	cases.append(duplicate)
	for key: String in ["credits_earned","experience","kills"]:
		var mismatch: Dictionary = before.duplicate(true)
		mismatch.combat_totals[key] = int(mismatch.combat_totals[key]) + 1
		cases.append(mismatch)
		var fractional: Dictionary = before.duplicate(true)
		fractional.combat_totals[key] = 0.5
		cases.append(fractional)
	for update: Dictionary in [{"credits":-1},{"experience":0.5},{"monster_code":0},{"source_kind":"player"},{"reward_id":"mission:105"},{"experience":9000000000000001}]:
		var bad: Dictionary = before.duplicate(true)
		bad.combat_rewards[0].merge(update, true)
		cases.append(bad)
	for key: String in ["credits_earned","experience"]:
		var bad: Dictionary = before.duplicate(true)
		bad.wallet[key] = int(bad.wallet[key]) + 1
		cases.append(bad)
	var missing_totals: Dictionary = before.duplicate(true)
	missing_totals.erase("combat_totals")
	cases.append(missing_totals)
	var erased_receipts: Dictionary = before.duplicate(true)
	erased_receipts.erase("combat_rewards")
	erased_receipts.erase("combat_totals")
	cases.append(erased_receipts)
	var too_many: Dictionary = before.duplicate(true)
	var rows: Array = []
	rows.resize(100001)
	too_many.combat_rewards = rows
	cases.append(too_many)
	var revision: int = world._revision
	for index: int in range(cases.size()):
		_check(not world.import_state(cases[index]).get("ok", false) and world.export_state() == before and int(world._revision) == revision, "malformed/mismatched saved ledger rejects atomically:%d" % index)
	world.free()


func _test_bounds_and_reset() -> void:
	var world: Node3D = _fixture()
	var event: Dictionary = _native_event("upper-bound")
	event.credits = 1000000000
	event.experience = 9000000000000000
	_check(world.record_combat_reward(event), "documented local balance/rawXP bounds are inclusive")
	var before: Dictionary = world.export_state()
	_check(not world.record_combat_reward(_native_event("over-bound")) and world.export_state() == before, "additional successful-event input cannot overflow wallet ledgers")
	_check(world.import_state(JSON.parse_string(JSON.stringify(before))).get("ok", false), "maximum permitted ledger values restore exactly through JSON")
	world.reset_session()
	var cleared: Dictionary = world.export_state()
	_check(cleared.combat_rewards.is_empty() and cleared.combat_totals == {"credits_earned":0,"experience":0,"kills":0} and cleared.wallet == {"credits":0,"credits_earned":0,"experience":0}, "new local session clears both ledgers and receipt history")
	var zero: Dictionary = _native_event("zero-award-contract")
	zero.credits = 0
	zero.experience = 0
	_check(world.record_combat_reward(zero) and not world.record_combat_reward(zero), "zero-award contract still records one unique defeated life")
	world.free()


func _check(value: bool, message: String) -> void:
	checks += 1
	if not value:failures.append(message)
