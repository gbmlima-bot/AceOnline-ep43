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
	_check(inventory.configure(), "Original native ITEM catalog did not load")
	_check(inventory.catalog.size() >= 1913, "Missing native weapon/engine records")
	_check(inventory.add_item(7000040), "Native starter weapon not accepted")
	_check(inventory.add_item(7000050), "Native A-Gear weapon not accepted")
	_check(not inventory.add_item(1234), "Invented item accepted")
	_check(not inventory.add_item(7000040, -2), "Negative count accepted")
	_check(bool(inventory.equip_item(7000040, "primary").ok), "Native I-Gear weapon rejected")
	_check(not bool(inventory.equip_item(7000050, "primary").ok), "A-only weapon equipped by I-Gear")
	_check(not bool(inventory.equip_item(7000040, "secondary").ok), "Native weapon position ignored")
	inventory.gear_id = "12002100"
	inventory.equipped.clear()
	_check(bool(inventory.equip_item(7000050, "primary").ok), "Native A-only weapon rejected for A-Gear")
	var high: Dictionary = {}
	for item: Dictionary in inventory.catalog.values():
		if int(item.get("Position", -1)) == 2 and int(item.get("ReqMinLevel", 0)) > inventory.level and (int(item.get("ReqUnitKind", 0)) & 256) != 0:
			high = item
			break
	_check(not high.is_empty(), "No real high-level native weapon found for test")
	if not high.is_empty():
		inventory.add_item(int(high.ItemNum))
		_check(not bool(inventory.equip_item(int(high.ItemNum), "primary").ok), "Native level requirement ignored")
	var reward := {"reward_id": "native:fixture:1", "credits": 320, "experience": 91, "bonus_stats": 3, "items": [{"item_num": 7000050, "count": 2}]}
	var unclaimed := inventory.export_state()
	_check(inventory.can_apply_reward(reward), "Valid mission admission preview rejected")
	_check(inventory.can_apply_reward(reward) and inventory.export_state() == unclaimed, "Preview consumed a receipt, item, XP or SPI")
	_check(not inventory.can_apply_reward({"reward_id": "preview:bad", "credits": 1, "items": [{"item_num": 1234, "count": 1}]}), "Preview accepted an unknown reward item")
	_check(inventory.export_state() == unclaimed, "Rejected preview mutated live inventory")
	_check(inventory.apply_reward(reward), "Valid native reward rejected")
	_check(inventory.credits == 320 and inventory.experience == 91 and inventory.quantities[7000050] == 3 and inventory.bonus_stats == 3, "Native reward data altered")
	_check(not inventory.apply_reward(reward), "Mission reward replay accepted")
	_check(not inventory.can_apply_reward(reward), "Preview accepted an already committed receipt")
	var previous: Dictionary = inventory.export_state()
	_check(not inventory.apply_reward({"reward_id": "bad", "credits": 1, "items": [{"item_num": 1234, "count": 1}]}), "Unknown native reward item accepted")
	_check(inventory.export_state() == previous, "Invalid reward partially credited wallet")
	var copy := Inventory.new()
	copy.configure()
	var roundtrip: Variant = JSON.parse_string(JSON.stringify(previous))
	_check(bool(copy.import_state(roundtrip).ok), "Valid inventory JSON save rejected")
	_check(copy.export_state() == previous, "Inventory save round-trip changed state")
	_check(not copy.apply_reward(reward), "Saved reward ledger lost idempotence")
	for bad: Dictionary in [{"item_num": 1234, "count": 1}, {"item_num": 7000040, "count": -2}, {"item_num": 7000040, "count": 1.5}]:
		var corrupt: Dictionary = previous.duplicate(true)
		corrupt.items.append(bad)
		_check(not bool(copy.import_state(corrupt).ok), "Invalid inventory save item accepted")
		_check(copy.export_state() == previous, "Invalid save partially mutated inventory")
	_test_native_progression()
	if failures.is_empty():
		print("PASS: inventory — %s checks; native ITEMs, class/level/slot requirements, item rewards, atomic JSON save and replay ledger" % checks)
		quit(0)
	else:
		for message: String in failures:
			push_error(message)
		quit(1)


func _test_native_progression() -> void:
	var inventory := Inventory.new()
	inventory.configure()
	_check(not inventory._experience_rows.is_empty(), "Native level table missing")
	_check(inventory.starting_level == 9 and inventory.experience_origin == 8008, "Local level9 baseline does not match source initialXP8008")
	_check(inventory.apply_reward({"reward_id": "xp:boundary:below", "experience": 4690}), "Valid native XP reward rejected")
	_check(inventory.level == 9 and is_equal_approx(inventory.effective_experience, 12698.0), "Native level9 lower boundary changed")
	_check(inventory.apply_reward({"reward_id": "xp:boundary:at", "experience": 1}), "Exact native threshold reward rejected")
	_check(inventory.level == 10 and inventory.bonus_stats == 1 and is_equal_approx(inventory.effective_experience, 12699.0), "Native level10/bonus stat boundary changed")
	inventory.apply_reward({"reward_id": "xp:huge", "experience": 1000000})
	var expected := 19360.0 + 0.99 * (28501.0 - 19360.0)
	_check(inventory.level == 11 and is_equal_approx(inventory.effective_experience, expected), "One-level award and99percent native XP cap not applied")
	_check(inventory.experience == 1004691 and is_equal_approx(inventory.experience_discarded, 8008.0 + 1004691.0 - expected), "Raw mission XP ledger lost native-cap discarded XP")
	var saved: Dictionary = JSON.parse_string(JSON.stringify(inventory.export_state()))
	var restored := Inventory.new()
	restored.configure()
	_check(bool(restored.import_state(saved).ok), "Native progression state rejected after JSON round-trip")
	var corrupt: Dictionary = saved.duplicate(true)
	corrupt.level = 12
	_check(not bool(restored.import_state(corrupt).ok), "Forged native level accepted")
	corrupt = saved.duplicate(true)
	corrupt.experience_origin = 0
	_check(not bool(restored.import_state(corrupt).ok), "Forged native XP origin accepted")
	_check(restored.export_state() == inventory.export_state(), "Rejected native XP state mutated live ledger")
	var first := Inventory.new()
	first.configure()
	first.set_starting_level(1)
	first.apply_reward({"reward_id": "native:level2", "experience": 91})
	_check(first.level == 2 and first.experience_origin == 0, "Original first level threshold91 is wrong")
	var cap := Inventory.new()
	cap.configure()
	cap.set_starting_level(124)
	cap.apply_reward({"reward_id": "native:cap125", "experience": 900000000000})
	_check(cap.level == 125 and is_equal_approx(cap.effective_experience, 122136606741.0), "Native cap125 incorrect")
