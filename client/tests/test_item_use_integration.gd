extends SceneTree
## Production action/resource/save integration. Owned kits are explicit test
## fixtures; these grants are not evidence of earned campaign progression.
const ProgressStore = preload("res://scripts/local_save.gd")
var scene: Node3D
var checks := 0
var failures: Array[String] = []
var save_path := "user://item-use-integration-v09.json"

func _initialize() -> void:
	_run.call_deferred()

func _check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures.append(message)

func _run() -> void:
	scene = (load("res://main.tscn") as PackedScene).instantiate()
	root.add_child(scene)
	scene.set_physics_process(false)
	scene.set_process(false)
	await process_frame
	_check(scene._combat_ready and is_instance_valid(scene.systems), "Production systems failed to initialize")
	if not scene._combat_ready or not is_instance_valid(scene.systems):
		await _finish()
		return
	scene.systems.set_process(false)
	var systems: Node = scene.systems
	var inventory = scene.combat_runtime.inventory
	for identifier: int in [7002600, 7002830, 7022580, 7000790, 7003020]:
		_check(inventory.add_item(identifier, 3), "Cannot create explicit owned test kit fixture")
	# Actual combat damage produces both HP and shield deficits.
	var combat = scene.combat_runtime.model
	combat.damage_player(float(combat.player.max_shield) + 100.0, "integration_fixture")
	var damaged_hp := float(combat.player.hp)
	_check(damaged_hp > 0.0 and damaged_hp < float(combat.player.max_hp), "Production damage did not prepare a living damaged ship")
	scene._update_hud()
	var hp_entry := _entry(7002600, scene.legacy_hud._inventory_state)
	_check(hp_entry.get("consumable", false) and hp_entry.get("usable", false) and hp_entry.get("use_quantity", 0) == 1, "Actual main HUD snapshot lacks owned-use availability")
	_check(hp_entry.get("use_effects", []) == [{"resource": "hp", "amount": 42.0}], "HUD native kit effect differs from recovered descriptor")
	var before: Dictionary = inventory.export_state()
	_action("use_item:7002600")
	_check(float(combat.player.hp) == damaged_hp + 42.0 and inventory.quantities[7002600] == 2, "Production HUD action failed to debit exactly one kit and apply native HP42")
	_check(inventory.credits == before.credits and inventory.experience == before.experience, "Using an owned kit altered money/experience")
	_check(systems.item_use.cooldown_for("hp") == 3.0, "Production HP recast did not start")
	var checkpoint: Dictionary = scene._capture_local_progress()
	_action("use_item:7002600")
	_check(scene.combat_runtime.inventory.export_state() == checkpoint.combat.inventory and float(combat.player.hp) == float(checkpoint.combat.player.hp), "Repeated HUD click consumed another kit during native recast")
	scene._update_hud()
	hp_entry = _entry(7002600, scene.legacy_hud._inventory_state)
	_check(not bool(hp_entry.get("usable", true)) and float(hp_entry.get("use_remaining", 0.0)) == 3.0 and not str(hp_entry.get("use_reason", "")).is_empty(), "HUD snapshot lost recast blocking/reason")
	_action("use_item:7002830")
	_check(float(combat.player.shield) == float(combat.player.max_shield) and inventory.quantities[7002830] == 2, "Production DP kit did not affect live combat shield")
	systems.skills.sp = 0.0 # Controlled SP deficit, not a learned-skill grant.
	systems.sync_resources()
	_action("use_item:7022580")
	_check(systems.skills.sp == systems.skills.max_sp and float(combat.player.sp) == systems.skills.sp and inventory.quantities[7022580] == 2, "SP kit was overwritten by skills authority during profile sync")
	var capacity := float(scene.model.fuel_capacity)
	scene.model.set_fuel_state(5.0, capacity)
	combat.player.ep = 1.0 # Deliberately stale mirror; flight remains authoritative.
	_action("use_item:7000790")
	_check(is_equal_approx(scene.model.fuel_fraction, 1.0) and float(combat.player.ep) == capacity and inventory.quantities[7000790] == 2, "EP kit failed to sync live flight fuel before/after item usage")
	var rejected_before: Dictionary = scene._capture_local_progress()
	_action("use_item:7003020")
	_check(scene.combat_runtime.inventory.export_state() == rejected_before.combat.inventory and systems.item_use.export_state() == rejected_before.systems.item_use, "Unknown newer descriptor mutated live inventory/timers")
	_action("use_item:invalid")
	_check(scene.combat_runtime.inventory.export_state() == rejected_before.combat.inventory, "Malformed use action changed owned items")
	# Actual game tick advances kit recasts, independently from view refresh.
	systems.advance(0.5)
	_check(systems.item_use.cooldown_for("hp") == 2.5 and systems.item_use.cooldown_for("ep") == 3.5 and systems.item_use.cooldown_for("sp") == 9.5, "GameSystems tick omitted per-resource native recasts")
	await _test_save_load()
	await _finish()

func _action(action: String) -> void:
	scene.legacy_hud.local_action_requested.emit(action)
	scene._drain_simulation_events()

func _entry(identifier: int, state: Dictionary) -> Dictionary:
	for entry: Dictionary in state.get("entries", []):
		if int(entry.get("item_num", 0)) == identifier:
			return entry
	return {}

func _test_save_load() -> void:
	var systems: Node = scene.systems
	scene._save_path = save_path
	var saved: Dictionary = scene._capture_local_progress()
	_check(saved.systems.item_use.cooldowns == {"hp": 2.5, "shield": 2.5, "sp": 9.5, "ep": 3.5}, "Full checkpoint omitted exact native kit recasts")
	_check(bool(scene._save_local_game(false).get("ok", false)), "Production save failed to persist consumables")
	var read: Dictionary = ProgressStore.read_game(save_path)
	_check(bool(read.get("ok", false)) and int(read.snapshot.systems.item_use.schema_version) == 1 and read.snapshot.systems.item_use.cooldowns == saved.systems.item_use.cooldowns, "Checksummed saved file omitted kit state")
	systems.advance(0.5)
	scene.combat_runtime.model.damage_player(5.0, "integration_fixture")
	scene.model.set_fuel_state(3.0, scene.model.fuel_capacity)
	_check(bool(scene._load_local_game().get("ok", false)), "Production load rejected consumable checkpoint")
	_check(systems.item_use.export_state() == saved.systems.item_use and scene.combat_runtime.inventory.export_state() == saved.combat.inventory, "Reload changed spent quantities/recasts")
	_check(float(scene.combat_runtime.model.player.hp) == float(saved.combat.player.hp) and float(scene.combat_runtime.model.player.shield) == float(saved.combat.player.shield), "Reload did not restore actual combat resources")
	_check(systems.skills.sp == float(saved.systems.skills.sp) and float(scene.combat_runtime.model.player.sp) == systems.skills.sp and is_equal_approx(scene.model.fuel_fraction, float(saved.flight.fuel_fraction)), "Reload failed SP/EP authority consistency")
	var denied: Dictionary = systems.use_item(7002600)
	_check(not bool(denied.get("ok", true)) and denied.get("error", "") == "native_item_cooldown", "Reload bypassed native kit recast")
	var corrupt: Dictionary = scene._capture_local_progress()
	corrupt.systems.item_use.cooldowns.ep = "3"
	var preserved: Dictionary = scene._capture_local_progress()
	_check(not bool(scene._restore_local_progress(corrupt).get("ok", true)), "Corrupt kit recast accepted by production restore")
	var after: Dictionary = scene._capture_local_progress()
	_check(after.systems == preserved.systems and after.combat.inventory == preserved.combat.inventory and after.flight.fuel == preserved.flight.fuel, "Corrupt recast rollback changed owned items, skills, service ledger, timers or fuel")
	# An older 0.8 systems save has skills/services but no item_use subsystem.
	var legacy: Dictionary = scene._capture_local_progress()
	legacy.release = "0.8.0"
	legacy.systems.erase("item_use")
	_check(bool(scene._restore_local_progress(legacy).get("ok", false)) and systems.item_use.export_state().cooldowns.is_empty(), "0.8 migration did not default absent kit timers")
	_check(scene.combat_runtime.inventory.export_state() == legacy.combat.inventory, "0.8 migration restored consumed kits or changed wallet")
	# Online suspension must preserve the offline inventory/timers and never
	# apply local consumption to a server-owned pilot snapshot.
	systems.suspend_for_online(true)
	var offline_items: Dictionary = scene.combat_runtime.inventory.export_state()
	var offline_timers: Dictionary = systems.item_use.export_state()
	_check(not systems.handle_action("use_item:7002600"), "Suspended local subsystem handled an online use action")
	_check(not bool(systems.use_item(7002600).get("ok", true)) and scene.combat_runtime.inventory.export_state() == offline_items and systems.item_use.export_state() == offline_timers, "Online direct call mutated offline kit state")
	systems.advance(1.0)
	_check(systems.item_use.export_state() == offline_timers, "Suspended online session advanced offline recasts")
	systems.suspend_for_online(false)

func _finish() -> void:
	if is_instance_valid(scene):
		scene.queue_free()
		await process_frame
	for suffix: String in ["", ".bak", ".tmp"]:
		var local := ProjectSettings.globalize_path(save_path + suffix)
		if FileAccess.file_exists(local):
			DirAccess.remove_absolute(local)
	for message: String in failures:
		push_error(message)
	print("%s: native consumable production integration — %d checks; actual HUD action, combat/SP/fuel authority, recasts, checksummed save/load, corrupt rollback, 0.8 migration and online isolation" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)
