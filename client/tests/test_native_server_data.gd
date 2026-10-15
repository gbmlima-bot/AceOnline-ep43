extends SceneTree
const Data = preload("res://scripts/native_server_data.gd")
const Runtime = preload("res://scripts/combat_runtime.gd")
var checks := 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_native_boundaries()
	_test_pickup_levels()
	_test_fail_closed()
	_test_runtime_receipts()
	_test_real_death_event_loop()
	_test_real_static_tables()
	print(JSON.stringify({"suite":"native-server-data","checks":checks,"failures":failures.size(),"scope":"native_backup_rules_solo_base_rates;no_native_spawns_or_HP_override"}))
	for message: String in failures:printerr(JSON.stringify({"suite":"native-server-data","failure":message}))
	quit(0 if failures.is_empty() else 1)


func _table(name: String, columns: Array, rows: Array) -> Dictionary:
	return {"schema_version":1,"table":name,"columns":columns,"rows":rows}


func _items() -> Dictionary:
	return {7000022:{"ItemNum":7000022,"Kind":18,"Time":0,"ItemAttribute":32769},7005580:{"ItemNum":7005580,"Kind":24,"Time":0,"ItemAttribute":7}}


func _fixture(rows: Array, options: int = 1, bell: int = 1) -> RefCounted:
	var data := Data.new()
	# Actual Hornian values from ti_Monster, independently recovered from acc.bak.
	var monsters := _table("ti_Monster",Data.MONSTER_COLUMNS,[[2000000,9,82,bell,options]])
	_check(data.configure(monsters,_table("ti_MonsterItem",Data.DROP_COLUMNS,rows),_items(),{2000000:{"MonsterUnitKind":2000000}}).get("ok",false), "bounded compact native static tables configure")
	return data


func _test_native_boundaries() -> void:
	# Actual guaranteed Hornian SPI table:32..98, probability1000000/1000000.
	var data: RefCounted = _fixture([[2000000,7000022,32,98,1000000,0,0,0]])
	var reward: Dictionary = data.roll_rewards(2000000,9,func(low: int,_high: int) -> int:return low)
	_check(reward.ok and reward.experience == 82 and reward.credits == 32 and reward.items.is_empty(), "actual Hornian row gives82XP and native minimum32SPI")
	reward = data.roll_rewards(2000000,9,func(_low: int,high: int) -> int:return high)
	_check(reward.ok and reward.credits == 98, "native RANDI includes maximum98SPI")
	data = _fixture([[2000000,7005580,1,1,100,0,0,0]])
	reward = data.roll_rewards(2000000,9,func(low: int,high: int) -> int:return 100 if high == 999999 else low)
	_check(reward.items == [{"item_num":7005580,"count":1}], "native probability comparator includes equality roll100/prob100")
	reward = data.roll_rewards(2000000,9,func(low: int,high: int) -> int:return 101 if high == 999999 else low)
	_check(reward.items.is_empty() and reward.experience == 82, "roll101 fails probability100 without removing independently earned XP")
	data = _fixture([[2000000,7005580,1,1,0,0,0,0]])
	var calls: Array = []
	reward = data.roll_rewards(2000000,9,func(low: int,_high: int) -> int:calls.append(low);return low)
	_check(reward.items.is_empty() and calls.is_empty(), "disabled zero-probability rows cannot win even when random is zero")
	data = _fixture([[2000000,7005580,0,0,1000000,0,0,0]])
	reward = data.roll_rewards(2000000,9,func(low: int,_high: int) -> int:return low)
	_check(reward.items == [{"item_num":7005580,"count":1}], "native successful quantity clamps to one after the base1x monster-count ratio")


func _test_pickup_levels() -> void:
	var data: RefCounted = _fixture([[2000000,7000022,32,32,1000000,0,0,0]])
	var equal: Dictionary = data.roll_rewards(2000000,19,func(low: int,high: int) -> int:return 40 if high == 99 else low)
	var over: Dictionary = data.roll_rewards(2000000,19,func(low: int,high: int) -> int:return 41 if high == 99 else low)
	_check(equal.credits == 32 and over.credits == 0, "native ten-level SPI penalty uses inclusive40/99 pickup boundary")
	data = _fixture([[2000000,7000022,32,32,1000000,0,0,0]],8)
	_check(data.roll_rewards(2000000,19,func(_low: int,high: int) -> int:return high).credits == 32, "native boss MPOption bypasses low-level SPI pickup loss")
	var nonauto := _items()
	nonauto[7005580].ItemAttribute = 6
	data.configure(_table("ti_Monster",Data.MONSTER_COLUMNS,[[2000000,9,82,1,1]]),_table("ti_MonsterItem",Data.DROP_COLUMNS,[[2000000,7005580,1,1,1000000,0,0,0]]),nonauto,{2000000:{}})
	_check(data.roll_rewards(2000000,19,func(low: int,high: int) -> int:return 31 if high == 99 else low).items.is_empty(), "nonauto quest items retain native low-level item pickup probability")
	data = _fixture([[2000000,7005580,1,1,1000000,0,0,0]],1,12)
	_check(data.roll_rewards(2000000,9,func(low: int,_high: int) -> int:return low).items.is_empty(), "native strategy-point monsters create no regular drops")
	data = _fixture([[2000000,7005580,1,1,1000000,0,0,0]],1,31)
	_check(not data.roll_rewards(2000000,9,func(low: int,_high: int) -> int:return low).ok, "unavailable infinity context never becomes default local rewards")


func _test_fail_closed() -> void:
	var data: RefCounted = _fixture([[2000000,7005580,1,1,1000000,1,0,0],[2000000,7005580,1,1,1000000,0,0,1],[2000000,999,1,1,1000000,0,0,0],[2000000,7005580,2,1,1000000,0,0,0]])
	_check(data.diagnostics().blocked_drop_rows == 4 and data.diagnostics().supported_drop_rows == 0, "rare, staged, unknown-item and reversed-range rows stay blocked")
	_check(not data.roll_rewards(2000001,9,func(low: int,_high: int) -> int:return low).ok, "unknown current-client monster cannot mint fallback XP or loot")
	data = _fixture([[2000000,7005580,1,1,1000000,0,0,0]])
	_check(not data.roll_rewards(2000000,9,func(_low: int,high: int) -> int:return high + 1).ok, "out-of-range random callback cannot silently grant reward")
	var items := _items()
	items[7005580].Time = 60
	_check(data.configure(_table("ti_Monster",Data.MONSTER_COLUMNS,[[2000000,9,82,1,1]]),_table("ti_MonsterItem",Data.DROP_COLUMNS,[[2000000,7005580,1,1,1000000,0,0,0]]),items,{2000000:{}}).get("ok",false) and data.diagnostics().blocked_reasons.has("native_timed_item_not_implemented"), "unimplemented timed item cannot be granted as a permanent base item")
	_check(data.configure(_table("ti_Monster",Data.MONSTER_COLUMNS,[[2000000,9,82,1,1]]),_table("ti_MonsterItem",Data.DROP_COLUMNS,[[2000000,7005580,1,1,1000000,0,0,0]]),_items(),{2000000:{}},{7000022:true}).get("ok",false) and data.diagnostics().blocked_reasons.has("legacy_current_item_semantics_differ") and data.roll_rewards(2000000,9,func(low: int,_high: int) -> int:return low).items.is_empty(), "cross-version filter blocks an otherwise supported ID whose native/current item semantics differ")
	_check(not data.configure(_table("ti_Monster",["UniqueNumber"],[[2000000]]),{},items,{2000000:{}}).get("ok",false) and not data.roll_rewards(2000000,9,func(low: int,_high: int) -> int:return low).ok, "invalid replacement schema disables the complete reward helper")


func _runtime_fixture() -> Node3D:
	var runtime := Runtime.new()
	root.add_child(runtime)
	runtime.inventory.configure(_items().values())
	runtime.inventory.set_starting_level(9)
	runtime._native_monsters = {2000000:{"MonsterUnitKind":2000000}}
	runtime.native_server = _fixture([[2000000,7000022,32,98,1000000,0,0,0],[2000000,7005580,1,1,1000000,0,0,0]])
	var profile: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets/legacy_rules/combat.json"))
	profile.encounter_id = "native-fixture"
	profile.player = runtime.inventory.combat_profile()
	profile.player.level = 9
	runtime.model.configure(profile,123)
	runtime.model.add_target({"MonsterUnitKind":2000000,"HP":303,"Level":9},Vector3.ZERO,0)
	runtime.model.targets[0].hp = 0.01
	runtime.model.targets[0].dodge = -100.0
	runtime.model._attack_target(runtime.model.targets[0],runtime.model.weapons.primary,100.0)
	return runtime


func _test_runtime_receipts() -> void:
	var runtime: Node3D = _runtime_fixture()
	var event := {"type":"target_destroyed","id":0,"monster_code":2000000,"instance_id":"native-fixture/0:0"}
	var original_hp: float = runtime.model.targets[0].max_hp
	var result: Dictionary = runtime._award_native_pve(event)
	_check(result.ok and result.reward.inventory_applied and runtime.inventory.experience == 82 and runtime.inventory.credits >= 32 and runtime.inventory.credits <= 98 and int(runtime.inventory.quantities.get(7005580,0)) == 1, "real local death event applies native XP/SPI/item in one inventory transaction")
	_check(result.reward.type == "native_pve_reward" and result.reward.source_kind == "monster" and result.reward.reward_id == "native-pve:native-fixture/0:0", "successful event exposes exact combat-ledger integration contract")
	_check(runtime.model.targets[0].max_hp == original_hp, "native server reward integration never overrides current-client HP")
	var rng: int = runtime.model._rng_state
	_check(not runtime._award_native_pve(event).get("ok",false) and runtime.model._rng_state == rng and runtime.inventory.experience == 82, "duplicate real target identity cannot reroll or repay")
	runtime._remote_active = true
	var forged: Dictionary = event.duplicate()
	forged.instance_id = "different"
	_check(not runtime._award_native_pve(forged).get("ok",false), "online remote snapshots never become offline reward authority")
	runtime._remote_active = false
	_check(not runtime._award_native_pve(forged).get("ok",false), "stale or arbitrary target life ID cannot create an inventory award")
	var saved: Dictionary = runtime.export_state()
	_check(saved.pve_consumed == ["native-fixture/0:0"] and int(saved.rng_state) == rng, "existing combat save stores consumed native kill IDs and deterministic RNG")
	runtime.free()
	runtime = _runtime_fixture()
	runtime.inventory.quantities[7005580] = 1000000000
	result = runtime._award_native_pve(event)
	_check(result.ok and result.reward.loot_rejected and runtime.inventory.experience == 82 and runtime.inventory.credits == 0 and runtime.inventory.quantities[7005580] == 1000000000, "refused pickup preserves independently earned native XP atomically without partial loot")
	_check(not runtime._award_native_pve(event).get("ok",false), "inventory refusal cannot reroll the defeated monster")
	runtime.free()


func _test_real_static_tables() -> void:
	var inventory := preload("res://scripts/inventory_model.gd").new()
	inventory.configure()
	var client: Dictionary = {}
	var source: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets/legacy_rules/monsters.json"))
	for row: Dictionary in source.records:client[int(row.MonsterUnitKind)] = row
	var data := Data.new()
	var loaded: Dictionary = data.load_catalogs(inventory.catalog,client)
	_check(loaded.get("ok",false) and loaded.source_monsters == 1300 and loaded.source_drop_rows == 70406 and loaded.supported_drop_rows > 0, "both full static SQL tables pass pinned backup provenance/hash and current-client identity checks")
	if loaded.get("ok",false):
		var reward: Dictionary = data.roll_rewards(2000000,9,func(low: int,_high: int) -> int:return low)
		_check(reward.ok and reward.experience == 82 and reward.credits >= 32, "full source Hornian awards actual82XP and native SPI without placeholders")
		var hornian: Dictionary = data.npc_attack_profile(2000000)
		_check(hornian.get("ok",false) and hornian.options.size() == 1 and hornian.options[0].source_item_num == 7500020 and hornian.options[0].weight == 100 and hornian.options[0].item.Kind == 151, "native Hornian uses exactly linked compatible rocket7500020 with100percent original weight")
		var bomber: Dictionary = data.npc_attack_profile(2028100)
		_check(bomber.get("ok",false) and bomber.options.size() == 2 and bomber.options[0].weight == 70 and bomber.options[1].weight == 30 and bomber.options[1].item.MultiNum == 2, "native Bombing Exerciser preserves70/30 weapon weights and second gun's actual MultiNum2")
		var fighter: Dictionary = data.npc_attack_profile(2028200)
		_check(not fighter.get("ok",false) and fighter.get("field","") == "HitRate", "one float32ULP difference blocks whole Fighter Exerciser loadout without renormalizing its alternative")
		var unarmed: Dictionary = data.npc_attack_profile(2015400)
		_check(unarmed.get("ok",false) and unarmed.unarmed and unarmed.options.is_empty(), "source unarmed targets never gain a fabricated player primary weapon")
		var original_hit: float = inventory.catalog[7500020].HitRate
		inventory.catalog[7500020].HitRate = original_hit + 1.0
		_check(not data.npc_attack_profile(2000000).get("ok",false), "changed current weapon field cannot pass a previously compatible ID alone")
		inventory.catalog[7500020].HitRate = original_hit
		print(JSON.stringify({"native_server_coverage":loaded}))
	var minimal := Data.new()
	_check(minimal.load_experience_catalog({2000000:{}}).get("ok",false) and minimal.monster_experience(2000000) == 82 and minimal.monster_experience(2028100) == -1, "authoritative minimal XP loader validates source and caller monster allowlist without loading loot tables")


func _test_real_death_event_loop() -> void:
	var runtime: Node3D = _runtime_fixture()
	var pilot := Node3D.new()
	runtime.add_child(pilot)
	runtime.player_node = pilot
	runtime._ready_to_play = true
	# _runtime_fixture defeated its actual CombatModel target; advance consumes
	# that model's untouched target_destroyed event through the production path.
	runtime.advance(0.0,{})
	var events: Array = runtime.drain_events()
	_check(runtime.inventory.experience == 82 and events.any(func(event: Dictionary) -> bool:return event.type == "target_destroyed") and events.any(func(event: Dictionary) -> bool:return event.type == "native_pve_reward" and event.inventory_applied), "production advance consumes real target_destroyed and emits an already-applied native reward")
	var xp: int = runtime.inventory.experience
	runtime.advance(0.0,{})
	_check(runtime.inventory.experience == xp and not runtime.drain_events().any(func(event: Dictionary) -> bool:return event.type == "native_pve_reward"), "subsequent frames never replay the same model death reward")
	var rng: int = runtime.model._rng_state
	runtime._profile = runtime.model._initial_profile.duplicate(true)
	runtime._encounter = {"player":runtime._profile.player.duplicate(true)}
	runtime.reset()
	_check(runtime.model._rng_state == rng and runtime.inventory.experience == xp and runtime._pve_consumed.has("native-fixture/0:0"), "map/encounter regeneration preserves consumed native death receipts and the existing random stream")
	runtime.free()


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:failures.append(message)
