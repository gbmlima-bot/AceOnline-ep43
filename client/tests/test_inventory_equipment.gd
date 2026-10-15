extends SceneTree
const Inventory = preload("res://scripts/inventory_model.gd")
var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func _check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures.append(message)

func _run() -> void:
	var inventory := Inventory.new()
	_check(inventory.configure(), "Full native catalog failed")
	_check(inventory._native_equipment_ready, "Pinned OMI equipment bytes rejected")
	_check(inventory.catalog[7009350].native_parameters[0] == {"parameter": 1, "value": 4.0, "index": 0}, "Current uint16 descriptors / float136 boundary changed")
	_check(inventory.catalog[7009350].native_parameters[1].parameter == 6 and inventory.catalog[7009350].native_parameters[1].value == 3.0, "Native CPU dodge4/3 fixture corrupted")
	_check(inventory.catalog[7002610].ReqGearStat.attack == 8 and inventory.catalog[7002610].ReqGearStat.dodge == 8, "Native requirement offsets58..69 changed")
	var native := inventory.combat_profile()
	_check(native.base_stats == {"attack": 4, "defense": 2, "fuel": 3, "soul": 3, "shield": 2, "dodge": 4}, "Native I-GEAR freestyle baseline changed")
	_check(native.max_hp == 600.0 and native.max_shield == 79.0 and native.max_sp == 24.0 and native.max_ep == 30.0 and native.transport == 480.0, "Native resource derivation / SHORT truncation changed")
	_check(is_equal_approx(native.attack_bonus, 0.029575) and is_equal_approx(native.defense, 1.3), "Native attack/defense table units changed")
	for identifier in [8013500, 8013600, 7009350, 7009360, 7000970, 7001190, 8037200, 7002610, 7000020]:
		_check(inventory.add_item(identifier), "Native equipment could not be owned:%d" % identifier)
	_check(bool(inventory.equip_item(8013500, "armor").ok), "Native permanent armor rejected")
	_check(inventory.combat_profile().max_hp == 625.0 and inventory.combat_profile().max_shield == 112.0, "Armor native HP25/DP33 not applied")
	_check(inventory.armor_appearance().available and inventory.armor_appearance().source_index == 8013100 and inventory.armor_appearance().item_num == 8013500, "Equipped ownership did not bind native appearance")
	_check(bool(inventory.equip_item(8013600, "armor").ok), "Native evasion armor rejected")
	_check(is_equal_approx(inventory.combat_profile().primary_dodge, 3.53), "Armor DES_DEFENSEPROBABILITY native percent changed")
	_check(not bool(inventory.equip_item(8037200, "armor").ok), "Unknown active native armor effects were silently granted")
	_check(not bool(inventory.equip_item(7000020, "primary").ok), "High-level original equipment requirement bypassed")
	_check(not bool(inventory.equip_item(7002610, "engine").ok), "Original gear stat requirement bypassed")
	_check(bool(inventory.equip_item(7009350, "cpu").ok), "Native CPU rejected")
	_check(inventory.combat_profile().total_stats.attack == 8 and inventory.combat_profile().total_stats.dodge == 7, "CPU did not add native attack4/dodge3")
	_check(bool(inventory.equip_item(7000970, "radar").ok), "Original radar rejected")
	_check(inventory.combat_profile().radar_range == 800.0 and inventory.combat_profile().radar_primary_range == 650.0 and inventory.combat_profile().radar_secondary_range == 1100.0, "Radar native ranges altered")
	_check(bool(inventory.equip_item(7001190, "accessory").ok), "Native permanent fuel accessory rejected")
	_check(inventory.combat_profile().max_ep == 80.0, "Native fuel accessory DES_EP50 not applied")
	_check(not bool(inventory.allocate_stat("attack").ok), "Free bonus point allocated")
	_check(inventory.apply_reward({"reward_id": "test:stats", "bonus_stats": 5}), "Stat reward rejected")
	_check(bool(inventory.allocate_stat("dodge").ok) and inventory.bonus_stats == 4 and inventory.combat_profile().base_stats.dodge == 8, "Class-scaled stat point not debited")
	_check(bool(inventory.equip_item(7002610, "engine").ok), "Valid engine after CPU/stat allocation rejected")
	var before := inventory.export_state()
	_check(not bool(inventory.unequip_item("cpu").ok), "CPU removed while engine requirements depend on it")
	_check(inventory.export_state() == before, "Rejected CPU removal partially mutated inventory")
	_check(not bool(inventory.allocate_stat("invented", 1).ok), "Invented stat allocated")
	_check(not bool(inventory.allocate_stat("attack", 100).ok), "Overspending bonus stats accepted")
	_check(inventory.export_state() == before, "Rejected allocation mutated inventory")
	_check(bool(inventory.allocate_stat("attack", 2).ok) and inventory.combat_profile().base_stats.attack == 12, "Batch allocation did not use I-GEAR increment4")
	var saved: Dictionary = JSON.parse_string(JSON.stringify(inventory.export_state()))
	var restored := Inventory.new()
	restored.configure()
	_check(bool(restored.import_state(saved).ok), "Equipped CPU dependency/allocations JSON state rejected")
	_check(restored.export_state() == inventory.export_state(), "Equipment stats save round-trip changed state")
	_check(restored.combat_profile() == inventory.combat_profile(), "Equipment-derived gameplay changed after load")
	for corrupt in [{"attack": -1}, {"attack": 1.5}, {"attack": 75}, {"invented": 1}, {"attack": "1"}]:
		var invalid: Dictionary = saved.duplicate(true)
		invalid.allocated_stats = corrupt
		_check(not bool(restored.import_state(invalid).ok), "Malformed stat allocation save accepted")
		_check(restored.export_state() == inventory.export_state(), "Malformed allocation load partially mutated state")
	_test_transactions()
	_test_caps_and_legacy()
	_test_v06_equipment_migration()
	_test_gear_changes()
	_test_equipped_weight()
	if failures.is_empty():
		print("PASS: native equipment — %d checks; source-bound scalar effects/requirements, CPU dependencies, allocated stats, atomic trading/reward removals and v0.6 saves" % checks)
		quit(0)
	else:
		for message in failures:
			push_error(message)
		quit(1)

func _test_transactions() -> void:
	var inventory := Inventory.new()
	inventory.configure()
	inventory.apply_reward({"reward_id": "wallet", "credits": 100, "items": [{"item_num": 7000040, "count": 3}]})
	inventory.equip_item(7000040, "primary")
	_check(bool(inventory.exchange([{"item_num": 7000040, "count": 2}], [{"item_num": 7000970, "count": 1}], -20).ok), "Valid atomic exchange rejected")
	_check(inventory.quantities[7000040] == 1 and inventory.quantities[7000970] == 1 and inventory.credits == 80, "Valid exchange produced wrong balances")
	var before := inventory.export_state()
	for removals in [[{"item_num": 7000040, "count": 1}], [{"item_num": 7000970, "count": 2}], [{"item_num": 7000970, "count": 1.5}], [{"item_num": 7000970, "count": 0}]]:
		_check(not bool(inventory.exchange(removals, [{"item_num": 7009350, "count": 1}], 25).ok), "Invalid removal granted transaction")
		_check(inventory.export_state() == before, "Rejected removal partially credited wallet or items")
	_check(not bool(inventory.exchange([], [{"item_num": 1234, "count": 1}], -10).ok), "Unknown transaction item accepted")
	_check(not bool(inventory.exchange([], [{"item_num": 7000970, "count": 1}], -81).ok), "Debt transaction accepted")
	_check(not bool(inventory.exchange([], [{"item_num": 7000970, "count": 1000000000}], 0).ok), "Count overflow accepted")
	_check(not bool(inventory.apply_transaction(0, [], [], {"force": true}).ok), "Unsupported forced transaction accepted")
	_check(inventory.export_state() == before, "Invalid additions/debt/overflow partially mutated wallet")
	_check(bool(inventory.remove_item(7000970).ok) and not inventory.quantities.has(7000970), "Single-item removal failed / zero stack retained")
	inventory.add_item(7000970, 3)
	var reward := {"reward_id": "quest:turn-in", "credits": 50, "experience": 91, "items": [{"item_num": 7009350, "count": 1}], "removals": [{"item_num": 7000970, "count": 2}]}
	_check(inventory.apply_reward(reward), "Native mission item turn-in rejected")
	_check(inventory.quantities[7000970] == 1 and inventory.quantities[7009350] == 1 and inventory.experience == 91 and inventory.credits == 130, "Quest removal/reward not atomic")
	before = inventory.export_state()
	_check(not inventory.apply_reward(reward), "Quest turn-in reward replay accepted")
	_check(not inventory.apply_reward({"reward_id": "bad:turn-in", "credits": 10, "experience": 91, "removals": [{"item_num": 7000970, "count": 2}]}), "Unowned quest turn-in yielded XP/SPI")
	_check(inventory.export_state() == before, "Invalid quest turn-in partially mutated reward ledger")

func _test_caps_and_legacy() -> void:
	var inventory := Inventory.new()
	inventory.configure()
	var legacy := inventory.export_state()
	legacy.erase("allocated_stats")
	_check(bool(inventory.import_state(legacy).ok) and inventory.allocated_stats.is_empty(), "v0.6 schema1 state without allocated_stats rejected")
	inventory.bonus_stats = 100
	_check(bool(inventory.allocate_stat("attack", 74).ok), "Native allocation up to cap rejected")
	_check(inventory.combat_profile().base_stats.attack == 300 and not bool(inventory.allocate_stat("attack").ok), "Native pre-increment stat cap ignored")
	_check(not bool(inventory.equip_item(8013500, "armor").ok), "Unowned armor equipped")
	for gear in ["12000100", "12001100", "12002100", "12003100"]:
		inventory.gear_id = gear
		_check(inventory.combat_profile().stat_cap == 300, "Class stat cap changed")
	# Mark a fixture's unknown effect inactive: zero data must not create a stat.
	var untouched := inventory.combat_profile()
	_check(untouched.unavailable.has("invoking_effects"), "Unported source effects not exposed")

func _test_v06_equipment_migration() -> void:
	var inventory := Inventory.new()
	inventory.configure()
	inventory.add_item(7002610)
	var old := inventory.export_state()
	old.erase("allocated_stats")
	old.erase("grandfathered_equipment")
	old.equipped = {"engine": 7002610}
	_check(bool(inventory.import_state(old).ok), "Valid v0.6 equipped higher-stat engine save lost compatibility")
	_check(inventory.grandfathered_equipment == {"engine": 7002610}, "v0.6 exception not explicitly recorded")
	_check(inventory.combat_profile().base_stats.attack == 4 and inventory.combat_profile().base_stats.dodge == 4 and inventory.bonus_stats == 0, "v0.6 migration granted fictitious native stats")
	var upgraded: Dictionary = JSON.parse_string(JSON.stringify(inventory.export_state()))
	var restored := Inventory.new()
	restored.configure()
	_check(bool(restored.import_state(upgraded).ok) and restored.equipped.engine == 7002610, "Migrated v0.6 engine did not survive a v0.7 save")
	var before := restored.export_state()
	for fixture in [
		{"grandfathered_equipment": {"engine": 7002570}},
		{"grandfathered_equipment": {"armor": 8013500}},
		{"gear_id": "12002100"},
		{"items": []},
		{"grandfathered_equipment": {"engine": 7002610.5}}]:
		var corrupt: Dictionary = upgraded.duplicate(true)
		for key: String in fixture:
			corrupt[key] = fixture[key]
		_check(not bool(restored.import_state(corrupt).ok), "Invalid legacy exception bypassed slot/id/class/ownership validation")
		_check(restored.export_state() == before, "Invalid legacy exception partially mutated state")
	_check(bool(restored.unequip_item("engine").ok) and restored.grandfathered_equipment.is_empty(), "Removing migrated item did not clear stat exception")
	_check(not bool(restored.equip_item(7002610, "engine").ok), "Removed v0.6 equipment retained a permanent stat bypass")

func _test_gear_changes() -> void:
	var inventory := Inventory.new()
	inventory.configure()
	for gear in Inventory.GEAR_KINDS:
		_check(bool(inventory.can_change_gear(gear).ok), "Native class with no allocated points rejected")
	_check(not bool(inventory.can_change_gear("invented").ok), "Unknown class accepted")
	inventory.gear_id = "12002100"
	inventory.apply_reward({"reward_id": "gear:points", "bonus_stats": 100})
	_check(bool(inventory.allocate_stat("dodge", 99).ok), "Native A-GEAR allocation99 rejected")
	var before := inventory.export_state()
	var change := inventory.can_change_gear("12000100")
	_check(bool(change.ok) and change.base_stats.dodge == 300, "Exact target B-GEAR native stat cap incorrectly rejected")
	_check(not bool(inventory.can_change_gear("12003100").ok), "Changing to I-GEAR exceeded native stat cap")
	_check(inventory.export_state() == before, "Checking gear compatibility redistributed points or mutated inventory")
	_check(inventory.gear_id == "12002100" and inventory.allocated_stats.dodge == 99 and inventory.bonus_stats == 1, "Failed class check reset allocated/unspent points")
	inventory.gear_id = "12000100"
	_check(bool(inventory.can_change_gear("12001100").ok), "Existing allocation should fit M-GEAR increment2")
	_check(inventory.can_change_gear("12001100").base_stats.dodge == 200, "Target class matrix was not used")
	var second := Inventory.new()
	second.configure()
	second.apply_reward({"reward_id": "gear:attack", "bonus_stats": 80})
	second.allocate_stat("attack", 74)
	before = second.export_state()
	_check(second.can_change_gear("12003100").base_stats.attack == 300, "Current I-GEAR cap changed during class check")
	_check(second.can_change_gear("12001100").base_stats.attack == 150, "Target M-GEAR attack increment2 not applied")
	_check(second.can_change_gear("12000100").base_stats.attack == 225, "Target B-GEAR attack increment3 not applied")
	_check(second.export_state() == before, "Successful class check mutated live character")

func _test_equipped_weight() -> void:
	var inventory := Inventory.new()
	inventory.configure()
	_check(inventory.weight_profile().weight == 0.0 and inventory.weight_profile().ratio == 0.0, "Empty local equipment already weighed something")
	for identifier in [7000040, 7901000]:
		inventory.add_item(identifier)
	_check(bool(inventory.equip_item(7000040, "primary").ok) and bool(inventory.equip_item(7901000, "secondary").ok), "Weight fixture native weapon pair could not equip")
	var profile := inventory.weight_profile()
	_check(profile.weight == 180.0 and profile.transport == 480.0 and is_equal_approx(profile.ratio, 0.375), "Source equipped weight60+120 / native transport480 changed")
	inventory.add_item(7000040, 9)
	for identifier in [7000050, 7002570, 8010100, 8011100, 8012100, 8013100]:
		inventory.add_item(identifier)
	var bullet: Dictionary = {}
	for item: Dictionary in inventory.catalog.values():
		if int(item.get("Kind", -1)) == 23:
			bullet = item
			break
	_check(not bullet.is_empty(), "Real source ammunition item missing")
	if not bullet.is_empty():
		inventory.add_item(int(bullet.ItemNum), 10000)
	_check(inventory.weight_profile() == profile, "Spare copies, four-class reserves or unequipped bullets altered flight weight")
	inventory.apply_reward({"reward_id": "weight:fuel", "bonus_stats": 1})
	inventory.allocate_stat("fuel")
	_check(inventory.weight_profile().weight == 180.0 and inventory.weight_profile().transport == 660.0 and is_equal_approx(inventory.weight_profile().ratio, 180.0 / 660.0), "Native FuelPart allocation did not change transport/ratio")
	_check(inventory.combat_profile().max_ep == 60.0 and inventory.combat_profile().transport == inventory.weight_profile().transport, "Fuel EP and transport derivations disagree")
	_check(inventory.snapshot().weight_profile == inventory.weight_profile(), "HUD snapshot omitted authoritative equipment weight")
	_check(inventory.NativeEquipment.item_weight({"Kind": 23, "Weight": 12, "MinTradeQuantity": 10}, 25) == 30.0, "Native countable fractional bundle formula changed")
	_check(inventory.NativeEquipment.item_weight({"Kind": 0, "Weight": 60, "MinTradeQuantity": 1}, 10) == 60.0, "Non-countable spare copies multiplied equipped weight")
	_check(inventory.NativeEquipment.item_weight({"Kind": 23, "Weight": 12, "MinTradeQuantity": 10}, 25, 0.25) == 37.5, "Native DesWeight multiplier algebra changed")
	_check(inventory.NativeEquipment.item_weight({"Kind": 23, "Weight": 12, "MinTradeQuantity": 0}, 25) == 0.0, "Malformed countable divisor produced invalid weight")
	_check(inventory.NativeEquipment.item_weight({"Kind": 0, "Weight": 60}, 1, -2.0) == 0.0, "Invalid DesWeight produced negative flight weight")
