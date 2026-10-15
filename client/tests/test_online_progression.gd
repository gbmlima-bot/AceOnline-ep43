extends SceneTree
## Recovered SQL base XP and authoritative non-party damage division.
const Arena = preload("res://scripts/online/arena_model.gd")
const World = preload("res://scripts/online/headless_world.gd")
const Combat = preload("res://scripts/combat_model.gd")
const NativeData = preload("res://scripts/native_server_data.gd")
const Wire = preload("res://scripts/online/json_wire.gd")
var world: RefCounted
var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	world = World.new()
	_check(world.configure(3002), "Native map3002 failed to configure")
	_test_native_damage_division_and_restart()
	_test_legacy_live_encounter_migration()
	_test_progression_import_validation()
	_test_exact_damage_and_fraction_roundtrip()
	print("ONLINE_PROGRESSION_TEST=" + JSON.stringify({"checks": checks, "failures": failures, "native_hornian_base_xp": 82, "native_hornian_hp": 303, "source_sha256": NativeData.SOURCE_SHA, "fractional_share_accounting": true, "legacy_live_encounter_migration": true}))
	for failure: String in failures:
		push_error(failure)
	quit(0 if failures.is_empty() else 1)

func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)

func _arena() -> RefCounted:
	var arena = Arena.new()
	_check(arena.configure({"room_id": "xp", "max_players": 3}, world), "Native XP arena failed configuration")
	for id: String in ["alice", "bob", "bystander"]:
		_check(bool(arena.add_player(id).ok), "XP fixture pilot failed to join")
	return arena

func _hit(arena: RefCounted, pilot_id: String, nominal_damage: float) -> void:
	# Trusted server-owned damage fixture uses the real Combat damage splitter
	# on the unchanged303HP source monster. No network operation accepts this.
	var target: Dictionary = arena.combat.targets[0]
	var split: Dictionary = Combat.apply_damage(target, nominal_damage)
	arena._process_event({"type": "hit", "id": 0, "monster_code": int(target.monster_code), "target_life": int(target.life), "pilot_id": pilot_id, "damage": nominal_damage, "hp_damage": split.hp, "shield_damage": split.shield})
	if float(target.hp) <= 0.0 and not bool(target.dead):
		target.dead = true
		target.respawn_remaining = 12.0
		arena._process_event({"type": "target_destroyed", "id": 0, "monster_code": int(target.monster_code), "pilot_id": pilot_id})

func _respawn_fixture(arena: RefCounted) -> void:
	var target: Dictionary = arena.combat.targets[0]
	target.life += 1
	target.hp = target.max_hp
	target.shield = target.max_shield
	target.dead = false
	target.respawn_remaining = 0.0

func _roundtrip(arena: RefCounted) -> RefCounted:
	var restored = _arena()
	_check(restored.import_state(JSON.parse_string(JSON.stringify(arena.export_state()))), "Native XP/fractions/contributions failed JSON roundtrip")
	for id: String in ["alice", "bob", "bystander"]:
		_check(bool(restored.add_player(id).ok), "Persistent XP pilot failed reconnect")
	return restored

func _test_native_damage_division_and_restart() -> void:
	var arena = _arena()
	_check(int(arena._native_rewards.monster_experience(2000000)) == 82 and int(arena.combat.targets[0].max_hp) == 303, "Recovered SQL XP changed current client monster HP or identity")
	arena.combat.activate_pilot("alice")
	arena.combat.player.hp -= 17.0
	arena.combat.player.primary_ammo -= 11
	arena.combat.player.primary_cooldown = 0.125
	arena.combat.selected_id = 1
	arena.combat.lock_progress = 0.4
	arena.combat.store_pilot()
	var pilot: Dictionary = arena.pilots.alice
	pilot.flight.set_fuel_state(0.4 * float(pilot.flight.fuel_capacity), float(pilot.flight.fuel_capacity))
	var position: Vector3 = pilot.flight.position
	var orientation: Quaternion = pilot.flight.orientation
	var fuel := float(pilot.flight.fuel_fraction) * float(pilot.flight.fuel_capacity)
	var hp := float(arena.combat.pilot_states.alice.player.hp)
	var sp := float(pilot.skills.sp)
	_hit(arena, "alice", 75.75) # Exactly25%of303HP.
	_check(is_equal_approx(float(arena._contributions["xp/0:0"].alice), 75.75), "Effective positive hit damage was not recorded")
	var resumed = _roundtrip(arena)
	_hit(arena, "bob", 1000000.0) # Actual remaining damage227.25, not nominaloverkill.
	_hit(resumed, "bob", 1000000.0)
	_check(arena.pilots.alice.inventory.experience == 20 and arena.pilots.bob.inventory.experience == 61 and arena.pilots.bystander.inventory.experience == 0, "25/75damage split gave full XP for a hit or rewarded a bystander")
	_check(is_equal_approx(float(arena.pilots.alice.xp_fraction), 0.5) and is_equal_approx(float(arena.pilots.bob.xp_fraction), 0.5), "Native fractional shares were discarded or transferred to another pilot")
	_check(resumed.pilots.alice.inventory.experience == 20 and resumed.pilots.bob.inventory.experience == 61 and resumed.pilots.alice.xp_fraction == arena.pilots.alice.xp_fraction, "Restart during shared encounter changed XP division")
	_check(arena.pilots.alice.inventory.credits == 10 and arena.pilots.bob.inventory.credits == 10 and arena.pilots.bystander.inventory.credits == 0, "Explicit SPI policy changed contributor eligibility")
	_check(pilot.flight.position == position and pilot.flight.orientation == orientation and is_equal_approx(float(pilot.flight.fuel_fraction) * float(pilot.flight.fuel_capacity), fuel) and arena.combat.pilot_states.alice.player.hp == hp and pilot.skills.sp == sp and arena.combat.pilot_states.alice.player.primary_ammo == 989 and arena.combat.pilot_states.alice.player.primary_cooldown == 0.125 and arena.combat.pilot_states.alice.selected_id == 1 and arena.combat.pilot_states.alice.lock_progress == 0.4, "XP refresh reset pose, fuel, HP, SP, ammo, weapon recast or another target lock")
	var rewards: Dictionary = {}
	for event: Dictionary in arena.drain_events():
		if event.type == "pilot_reward":
			rewards[event.pilot_id] = event
	_check(is_equal_approx(float(rewards.alice.experience_share), 20.5) and is_equal_approx(float(rewards.bob.experience_share), 61.5) and is_equal_approx(float(rewards.alice.damage_share), 0.25), "XP event concealed effective damage ratio or fractional ledger adaptation")
	_check(rewards.alice.source_sha256 == NativeData.SOURCE_SHA and str(rewards.alice.credits_policy).contains("not_native_drops"), "Reward provenance or explicit room SPI policy is missing")
	arena._process_event({"type": "target_destroyed", "id": 0, "monster_code": 2000000, "pilot_id": "bob"})
	_check(arena.pilots.alice.inventory.experience == 20 and arena.pilots.bob.inventory.experience == 61 and arena.pilots.alice.xp_fraction == 0.5, "Repeated destruction replay duplicated XP or fractional share")
	resumed = _roundtrip(arena)
	resumed._process_event({"type": "target_destroyed", "id": 0, "monster_code": 2000000, "pilot_id": "alice"})
	_check(resumed.pilots.alice.inventory.experience == 20 and resumed.pilots.alice.xp_fraction == 0.5, "Restart erased XP replay protection")
	_respawn_fixture(resumed)
	_hit(resumed, "alice", 75.75)
	_hit(resumed, "bob", 1000000.0)
	_check(resumed.pilots.alice.inventory.experience == 41 and resumed.pilots.bob.inventory.experience == 123 and is_zero_approx(float(resumed.pilots.alice.xp_fraction)) and is_zero_approx(float(resumed.pilots.bob.xp_fraction)), "Same-pilot fractional shares did not accumulate across lives/restart")
	var inventory: RefCounted = resumed.pilots.alice.inventory
	var until_next := int(inventory._experience_rows[9]) - int(inventory.effective_experience) - 10
	_check(until_next > 0 and inventory.apply_reward({"reward_id": "trusted-level-boundary-fixture", "experience": until_next}), "Server-earned level-boundary fixture failed")
	_check(inventory.level == 9 and inventory.bonus_stats == 0, "Boundary fixture granted unearned level/stat point")
	position = resumed.pilots.alice.flight.position
	fuel = float(resumed.pilots.alice.flight.fuel_fraction) * float(resumed.pilots.alice.flight.fuel_capacity)
	_respawn_fixture(resumed)
	_hit(resumed, "alice", 1000000.0)
	_check(inventory.level == 10 and inventory.bonus_stats == 1 and resumed.combat.pilot_states.alice.player.level == 10 and resumed.pilots.alice.skills.level == 10, "Real native XP award failed to synchronize levelup and source bonus-stat gate")
	_check(resumed.pilots.alice.flight.position == position and is_equal_approx(float(resumed.pilots.alice.flight.fuel_fraction) * float(resumed.pilots.alice.flight.fuel_capacity), fuel), "Levelup reset flight pose/fuel")
	_check(bool(resumed.command("alice", "earned-point", "allocate_stat", {"stat": "attack", "count": 1}).ok) and inventory.bonus_stats == 0, "Native XP-earned stat point could not be allocated authoritatively")
	var state: Dictionary = resumed.snapshot("alice")
	_check(state.self.inventory.level == 10 and state.self.inventory.allocate_stats_available and not Wire.encode({"op": "snapshot", "state": state}).is_empty(), "Progressed inventory is absent/invalid at client wire boundary")

func _test_legacy_live_encounter_migration() -> void:
	var arena = _arena()
	_hit(arena, "alice", 75.75)
	var old: Dictionary = JSON.parse_string(JSON.stringify(arena.export_state()))
	old.erase("contributions_version")
	old.erase("legacy_contribution_lives")
	old.erase("contribution_bits")
	old.erase("target_resource_bits")
	old.contributions["xp/0:0"].alice = true
	for id: String in old.pilots:
		old.pilots[id].erase("xp_fraction")
		old.pilots[id].erase("xp_fraction_bits")
	var restored = _arena()
	_check(restored.import_state(old) and restored._contributions["xp/0:0"].alice == 1.0 and restored._legacy_contribution_lives.has("xp/0:0"), "Legacy boolean hits were interpreted as recovered damage weights")
	for id: String in ["alice", "bob", "bystander"]:
		restored.add_player(id)
	_hit(restored, "bob", 1000000.0)
	_check(restored.pilots.alice.inventory.experience == 0 and restored.pilots.bob.inventory.experience == 0 and restored.pilots.alice.inventory.credits == 10 and restored.pilots.bob.inventory.credits == 10, "Legacy active life fabricated historical XP damage or lost previous SPI policy")
	_respawn_fixture(restored)
	_hit(restored, "alice", 1000000.0)
	_check(restored.pilots.alice.inventory.experience == 82 and restored._legacy_contribution_lives.is_empty(), "First fully observed post-migration life did not resume native XP")

func _test_progression_import_validation() -> void:
	var arena = _arena()
	_hit(arena, "alice", 75.75)
	var original: Dictionary = arena.export_state()
	for invalid: Variant in [0.0, -1.0, NAN, INF, true, "75.75"]:
		var bad := original.duplicate(true)
		bad.contributions["xp/0:0"].alice = invalid
		_check(not arena.import_state(bad) and arena.export_state() == original, "Invalid contribution mutated live state: " + str(invalid))
	var too_much := original.duplicate(true)
	too_much.contributions["xp/0:0"].alice = 304.0
	_check(not arena.import_state(too_much) and arena.export_state() == original, "Contribution greater than native monster HP+DP was accepted")
	for fraction: Variant in [-0.1, 1.0, INF, true, "0.5"]:
		var bad := original.duplicate(true)
		bad.pilots.alice.xp_fraction = fraction
		_check(not arena.import_state(bad) and arena.export_state() == original, "Invalid pending XP fraction mutated live state")
	var unknown := original.duplicate(true)
	unknown.contributions["xp/0:0"]["unknown-pilot"] = 1.0
	_check(not arena.import_state(unknown) and arena.export_state() == original, "Unknown pilot gained a saved damage contribution")
	var corrupted_bits := original.duplicate(true)
	corrupted_bits.contribution_bits["xp/0:0"].alice = "000000000000f87f" # quietNaNdouble
	_check(not arena.import_state(corrupted_bits) and arena.export_state() == original, "Invalid binary damage weight bypassed persistence validation")
	corrupted_bits = original.duplicate(true)
	corrupted_bits.pilots.alice.xp_fraction_bits = "000000000000f87f"
	_check(not arena.import_state(corrupted_bits) and arena.export_state() == original, "Invalid binary XP fraction bypassed persistence validation")
	corrupted_bits = original.duplicate(true)
	corrupted_bits.target_resource_bits[0].hp = "000000000000f87f"
	_check(not arena.import_state(corrupted_bits) and arena.export_state() == original, "Invalid binary target HP bypassed persistence validation")
	var wrong_life := original.duplicate(true)
	wrong_life.contributions = {"xp/0:99": {"alice": 75.75}}
	_check(not arena.import_state(wrong_life) and arena.export_state() == original, "Unobserved monster life accepted saved contributions")


func _test_exact_damage_and_fraction_roundtrip() -> void:
	var arena = _arena()
	_hit(arena, "alice", 75.12345678901234)
	var resumed = _roundtrip(arena)
	_check(resumed._contributions == arena._contributions and resumed.combat.targets[0].hp == arena.combat.targets[0].hp, "JSON rounding changed exact observed damage weights or target HP")
	_hit(arena, "bob", 1000000.0)
	_hit(resumed, "bob", 1000000.0)
	_check(arena.pilots.alice.xp_fraction == resumed.pilots.alice.xp_fraction and arena.pilots.bob.xp_fraction == resumed.pilots.bob.xp_fraction, "Mid-life restart changed exact fractional XP division")
	var awarded = _roundtrip(arena)
	_check(awarded.pilots.alice.xp_fraction == arena.pilots.alice.xp_fraction and awarded.pilots.bob.xp_fraction == arena.pilots.bob.xp_fraction, "Restart rounded an already-awarded XP fraction")
