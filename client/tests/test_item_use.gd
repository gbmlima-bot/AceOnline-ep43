extends SceneTree
const Inventory = preload("res://scripts/inventory_model.gd")
const ItemUse = preload("res://scripts/item_use_model.gd")
var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func _check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures.append(message)

func _resources() -> Dictionary:
	return {"hp": 500.0, "max_hp": 600.0, "shield": 5.0, "max_shield": 79.0,
		"sp": 0.0, "max_sp": 24.0, "ep": 5.0, "max_ep": 30.0, "dead": false}

func _run() -> void:
	var inventory := Inventory.new()
	_check(inventory.configure(), "Original catalog failed to load")
	var model := ItemUse.new()
	for identifier in [7002600, 7003000, 7002830, 7000790, 7022580, 7021620, 7025350, 7003020, 7001060, 7004600, 7027400]:
		_check(inventory.add_item(identifier, 4), "Cannot own native fixture:%d" % identifier)
	var resources := _resources()
	_check(model.use_item(inventory, 7002600, resources).ok, "Native HP42 kit rejected")
	_check(resources.hp == 542.0 and inventory.quantities[7002600] == 3, "HP effect or count did not match native data")
	_check(model.cooldown_for("hp") == 3.0, "HP recast did not use native ReAttacktime3000")
	_reject(model, inventory, 7003000, resources, {}, "native_item_cooldown", "Another HP kit bypassed shared native recast")
	_check(model.use_item(inventory, 7002830, resources).ok and resources.shield == 79.0, "Shield kit must clamp DP84 to native maximum79")
	_check(model.use_item(inventory, 7022580, resources).ok and resources.sp == 24.0, "Native SP kit did not restore skills resource")
	var fuel_result: Dictionary = model.use_item(inventory, 7000790, resources)
	_check(fuel_result.ok and resources.ep == 30.0 and fuel_result.ep_current == 30.0 and fuel_result.ep_max == 30.0, "Native EP30 kit/fuel integration result incorrect")
	_check(model.cooldown_for("ep") == 4.0 and model.cooldown_for("sp") == 10.0, "EP/SP timers use wrong units")
	model.advance(3.0)
	_check(model.cooldown_for("hp") == 0.0 and model.cooldown_for("sp") == 7.0, "Native resource timers did not tick independently")
	_check(model.use_item(inventory, 7003000, resources).ok and resources.hp == 600.0, "D-grade HP126 must clamp correctly")
	_reject(model, inventory, 7002600, resources, {}, "native_item_cooldown", "Full resource bypassed still active recast")
	model.advance(20.0)
	_reject(model, inventory, 7002600, resources, {}, "resource_already_full", "Full HP consumed a kit")
	resources.ep = 0.0
	_reject(model, inventory, 7000790, resources, {}, "native_empty_ep", "Native EP0 restriction bypassed")
	resources = _resources()
	resources.dead = true
	_reject(model, inventory, 7002600, resources, {}, "pilot_dead", "Dead pilot recovered using inventory")
	resources.dead = false
	resources.hp = 0.0
	_reject(model, inventory, 7022580, resources, {}, "pilot_dead", "HP0 pilot recovered SP")
	resources = _resources()
	for entry in [[{"bazaar_active": true}, "bazaar_active"], [{"trading": true}, "item_is_trading"], [{"trading_items": [7002600]}, "item_is_trading"], [{"item_parameter_overlap": true}, "native_item_parameter_overlap"], [{"freeze_hp": true}, "native_recovery_frozen"], [{"arena_map": true}, "native_arena_requirement"]]:
		_reject(model, inventory, 7002600, resources, entry[0], entry[1], "Native use-state restriction bypassed")
	_reject(model, inventory, 7002830, resources, {"shield_paralyzed": true}, "resource_already_full", "Shield paralysis recovered DP")
	_reject(model, inventory, 7002830, resources, {"freeze_shield": true}, "native_recovery_frozen", "DP freeze ignored")
	_reject(model, inventory, 7022580, resources, {"freeze_sp": true}, "native_recovery_frozen", "SP freeze ignored")
	_reject(model, inventory, 7027400, resources, {}, "native_infinity_requirement", "Infinity-only kit used on field server")
	_check(model.can_use(inventory, 7027400, resources, {"infinity_server": true}).ok, "Infinity server gate rejected supported native kit")
	_check(model.can_use(inventory, 7004600, resources, {"arena_map": true}).ok, "Native arena kit rejected")
	_reject(model, inventory, 7003020, resources, {}, "native_item_effect_not_ported", "Newer unknown23900 descriptor silently ignored")
	_reject(model, inventory, 7001060, resources, {}, "native_item_effect_not_ported", "Stat-reset card invented an effect")
	_reject(model, inventory, 7000040, resources, {}, "item_not_owned", "Catalog-only item treated as ownership")
	inventory.catalog[7002600].ReqMinLevel = 20
	_reject(model, inventory, 7002600, resources, {}, "native_level_requirement", "Minimum level restriction ignored")
	inventory.catalog[7002600].ReqMinLevel = 1
	inventory.catalog[7002600].ReqMaxLevel = 2
	_reject(model, inventory, 7002600, resources, {}, "native_level_requirement", "Maximum level restriction ignored")
	inventory.catalog[7002600].ReqMaxLevel = 0
	inventory.catalog[7002600].ReqUnitKind = 1
	_reject(model, inventory, 7002600, resources, {}, "native_gear_requirement", "GEAR requirement ignored")
	inventory.catalog[7002600].ReqUnitKind = 65535
	resources.hp = NAN
	_reject(model, inventory, 7002600, resources, {}, "pilot_dead", "Invalid HP accepted")
	resources = _resources()
	resources.sp = INF
	_reject(model, inventory, 7022580, resources, {}, "invalid_resource_state", "Invalid SP accepted")
	_test_combined(inventory)
	_test_persistence(inventory)
	var supported := 0
	for row: Dictionary in inventory.catalog.values():
		if model.supported_effects(row).ok:
			supported += 1
	_check(supported == 71, "Supported current native instant-kit count changed:%d" % supported)
	if failures.is_empty():
		print("PASS: native consumables — %d checks; %d supported current OMI kits, exact HP/DP/SP/EP effects, shared recasts, atomic ownership, unsupported effects and JSON cooldown state" % [checks, supported])
		quit(0)
	else:
		for message in failures:
			push_error(message)
		quit(1)

func _reject(model: RefCounted, inventory: RefCounted, identifier: int, resources: Dictionary, context: Dictionary, error: String, message: String) -> void:
	var before_inventory: Dictionary = inventory.export_state()
	var before_state: Dictionary = model.export_state()
	var before_resources := var_to_bytes(resources)
	var result: Dictionary = model.use_item(inventory, identifier, resources, context)
	_check(not bool(result.ok) and str(result.get("error", "")) == error, message + " got:" + str(result))
	_check(inventory.export_state() == before_inventory and model.export_state() == before_state and var_to_bytes(resources) == before_resources, "Rejected kit partially changed resources/count/timer")

func _test_combined(inventory: RefCounted) -> void:
	var model := ItemUse.new()
	var resources := _resources()
	_check(model.use_item(inventory, 7021620, resources).ok and resources.hp == 600.0 and resources.shield == 79.0, "Combined HP/DP kit failed native pair")
	_check(model.cooldown_for("hp") == 3.0 and model.cooldown_for("shield") == 3.0, "Combined kit omitted resource recast")
	model.advance(10.0)
	resources = _resources()
	resources.hp = 600.0
	_check(model.use_item(inventory, 7021620, resources).ok and model.cooldown_for("hp") == 0.0 and model.cooldown_for("shield") == 3.0, "Full HP portion falsely started a recast")
	resources.hp = 500.0
	_reject(model, inventory, 7021620, resources, {}, "native_item_cooldown", "Pair partially applied while DP recast active")
	model.advance(10.0)
	_check(model.use_item(inventory, 7021620, resources, {"shield_paralyzed": true}).ok and resources.hp == 600.0 and model.cooldown_for("shield") == 0.0, "Paralysis must allow only HP part of native pair")
	model.advance(10.0)
	resources = _resources()
	_check(model.use_item(inventory, 7025350, resources).ok and resources.hp == 600.0 and resources.shield == 79.0, "Native reverse DP/HP pair failed")
	# Inventory owns removal validation; a failed debit must never apply healing.
	var broken := Inventory.new()
	broken.configure()
	broken.add_item(7002600)
	broken.credits = -1
	resources = _resources()
	_reject(ItemUse.new(), broken, 7002600, resources, {}, "credit_overflow", "Failed inventory transaction still healed")

func _test_persistence(inventory: RefCounted) -> void:
	var model := ItemUse.new()
	var resources := _resources()
	_check(model.use_item(inventory, 7000790, resources).ok, "Fuel kit persistence setup failed")
	model.advance(0.5)
	var saved: Dictionary = JSON.parse_string(JSON.stringify(model.export_state()))
	var restored := ItemUse.new()
	_check(restored.import_state(saved) and restored.cooldown_for("ep") == 3.5, "JSON cooldown round-trip changed recast")
	resources = _resources()
	_reject(restored, inventory, 7000790, resources, {}, "native_item_cooldown", "Reload reset native EP recast")
	for corrupt in [{"unknown": 1}, {"ep": -1}, {"ep": INF}, {"ep": "1"}, {"ep": true}, {"ep": 4294968.0}]:
		var invalid := {"schema_version": 1, "cooldowns": corrupt}
		_check(not restored.import_state(invalid) and restored.export_state() == model.export_state(), "Malformed cooldown load mutated/accepted state")
	_check(not restored.import_state({"schema_version": 2, "cooldowns": {}}), "Unknown cooldown schema accepted")
	_check(restored.import_state({}) and restored.export_state().cooldowns.is_empty(), "0.8 save without cooldowns failed default migration")
