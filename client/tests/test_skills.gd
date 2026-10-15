extends SceneTree

const Skills = preload("res://scripts/skill_model.gd")
const Combat = preload("res://scripts/combat_model.gd")
var failures: Array[String] = []
var checks := 0


func _initialize() -> void:
	_test_source_and_gates()
	_test_native_buff_real_combat()
	_test_native_heals_and_resources()
	_test_native_berserker_and_movement_modifiers()
	_test_lifecycle_save_and_atomic_rejection()
	_test_stats_preserve_encounter()
	if failures.is_empty():
		print("PASS: skills — %d checks; native parameters, class/level/rank gates, real damage/defense/cadence, SP/cooldowns/heals, persistence and explicit blocked catalog" % checks)
		quit(0)
	else:
		for message: String in failures:
			push_error(message)
		quit(1)


func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)


func _skills(gear: String = "12000100", character_level: int = 125) -> RefCounted:
	var skills = Skills.new()
	_check(skills.configure({"gear_id": gear, "level": character_level, "max_sp": 1000}), "Native skill catalog did not configure")
	return skills


func _combat() -> RefCounted:
	var weapon := {"ItemNum": 1, "Kind": 0, "AbilityMin": 100, "AbilityMax": 100, "HitRate": 100, "ReAttacktime": 1000, "Range": 400, "ShotNum": 1, "MultiNum": 1}
	var secondary := weapon.duplicate()
	secondary.Kind = 9
	var combat = Combat.new()
	_check(combat.configure({"primary": weapon, "secondary": secondary, "player": {"max_hp": 1000, "max_shield": 1000, "level": 125}, "primary_ammo": 100, "secondary_ammo": 100}, 12345), "Skill combat fixture did not configure")
	return combat


func _test_source_and_gates() -> void:
	var skills = _skills()
	_check(skills.definitions.size() == 557, "The original 557 skill records are not all represented")
	_check(skills.learned.is_empty() and skills.hotbar == [0, 0, 0, 0, 0, 0, 0, 0], "Catalog loading silently granted ownership or hotbar")
	var fire: Dictionary = skills.definitions[7800011]
	_check(fire.parameters.size() == 2 and int(fire.parameters[0].destination) == 18 and int(fire.parameters[1].destination) == 71, "Native uint16 parameter array offsets were not recovered")
	_check(is_equal_approx(float(fire.parameters[0].value), 0.05), "Native FireShot magnitude was replaced")
	_check(not bool(skills.learn(7800010).ok), "Base prototype became a player-owned skill")
	_check(not bool(skills.learn(7810011).ok), "M-GEAR skill bypassed native class mask")
	_check(not bool(skills.learn(7800012).ok), "Rank2 bypassed missing previous rank")
	_check(bool(skills.learn(7800011).ok) and bool(skills.learn(7800012).ok), "Native sequential rank learning failed")
	_check(not bool(skills.learn(7800012).ok), "Duplicate learning succeeded")
	_check(bool(skills.assign_slot(1, 7800012).ok) and not bool(skills.assign_slot(0, 7800012).ok) and not bool(skills.assign_slot(9, 7800012).ok), "Hotbar bounds are not exactly1..8")
	_check(not bool(skills.assign_slot(2, 7800021).ok), "Unlearned skill assigned")
	_check(not bool(skills.learn(7800041).ok), "Unsupported toggle was silently activated")
	var snapshot: Dictionary = skills.snapshot()
	_check(snapshot.rows.size() == 557 and int(snapshot.supported_count) > 150 and int(snapshot.blocked_count) > 0, "Supported/blocked catalog scope not exposed")
	for row: Dictionary in snapshot.rows:
		if not bool(row.supported):
			_check(not str(row.reason).is_empty(), "Blocked skill has no explicit reason")
	var low_level = _skills("12000100", 1)
	_check(not bool(low_level.learn(7800011).ok), "Native minimum level requirement bypassed")
	var training = _skills("12000100", 9)
	var trained: Dictionary = training.learn_base_skills()
	_check(bool(trained.ok) and bool(trained.local_training_policy) and not trained.learned.is_empty(), "Explicit local initial training failed")
	for item_num: int in trained.learned:
		_check(int(training.definitions[item_num].SkillLevel) == 1 and (int(training.definitions[item_num].ReqUnitKind) & 1) != 0 and int(training.definitions[item_num].ReqMinLevel) <= 9, "Training granted unavailable/non-base skill")


func _test_native_buff_real_combat() -> void:
	var skills = _skills()
	var combat = _combat()
	combat.add_target({"HP": 10000, "Level": 125, "MoveSpeed": 0, "hostile": false}, Vector3(0, 0, -100))
	combat.advance(0.1, {"primary": true})
	_check(is_equal_approx(float(combat.targets[0].hp), 9900), "Unbuffed attack baseline failed")
	var ammo := int(combat.player.primary_ammo)
	var cooldown := float(combat.player.primary_cooldown)
	_check(bool(skills.learn(7800011).ok) and bool(skills.assign_slot(1, 7800011).ok), "FireShot setup failed")
	var cast_result: Dictionary = skills.cast_slot(1, combat)
	_check(bool(cast_result.ok) and int(cast_result.item_num) == 7800011 and int(cast_result.base_item_num) == 7800010 and str(cast_result.type) == "skill_used", "Successful cast lost native/family quest identity")
	_check(skills.sp == 990 and is_equal_approx(float(combat.skill_modifiers.primary_min_attack), 0.05), "Cast did not consume native10SP/apply5percent")
	_check(int(combat.player.primary_ammo) == ammo and is_equal_approx(float(combat.player.primary_cooldown), cooldown) and combat.targets.size() == 1 and combat.targets[0].hp == 9900, "Casting reset combat ammunition/recast/encounters")
	combat.advance(0.5)
	combat.advance(0.5, {"primary": true})
	_check(is_equal_approx(float(combat.targets[0].hp), 9795), "Native5percent FireShot did not increase actual weapon damage to105")
	var before: Dictionary = skills.export_state()
	_check(not bool(skills.cast_slot(1, combat).ok) and skills.export_state() == before, "Cooldown denial consumed SP/changed buff")
	var native_weapon: Dictionary = combat.weapons.primary
	combat.set_skill_modifiers({"primary_defense": 50})
	var incoming: Dictionary = combat.resolve_attack(native_weapon, {"level": 125}, combat.player, 100, true, "M2C")
	_check(incoming.hit and is_equal_approx(float(incoming.damage), 50), "Per-weapon native skill defense does not affect incoming damage")
	combat.set_skill_modifiers({"primary_dodge": 200})
	_check(not bool(combat.resolve_attack(native_weapon, {"level": 125}, combat.player, 100, true, "M2C").hit), "Native dodge skill does not affect incoming hit chance")
	combat.set_skill_modifiers({"primary_reattack": -0.5})
	combat.player.primary_cooldown = 0
	combat.advance(0.5, {"primary": true})
	_check(int(combat.player.primary_ammo) == ammo - 2, "Native ReAttacktime multiplier did not affect real shot scheduling")
	_check(skills.drain_events().size() == 1 and skills.drain_events().is_empty(), "Skill-use events were duplicated across drain")


func _test_native_heals_and_resources() -> void:
	var skills = _skills("12001100")
	var combat = _combat()
	combat.player.hp = 100
	combat.player.shield = 200
	_check(bool(skills.learn(7811041).ok), "Native target-heal rank1 did not learn")
	var record: Dictionary = skills.definitions[7811041]
	var heal := float(record.parameters[0].value)
	var result: Dictionary = skills.cast(7811041, combat)
	_check(bool(result.ok) and is_equal_approx(float(combat.player.hp), minf(1000, 100 + heal)) and combat.player.shield == 200, "Native immediateHP cure changed wrong resources/magnitude")
	_check(not bool(skills.cast(7811041, combat, {"target": "remote"}).ok), "Unsupported remote skill target was accepted")
	_check(not bool(skills.learn(7811031).ok), "Party heal became available without a real formation")
	_check(bool(skills.learn(7813021).ok) and bool(skills.cast(7813021, combat).ok), "Native SmartSP did not apply")
	_check(skills.snapshot().hotbar.size() == 8 and is_equal_approx(float(skills.catalog("7811041")[0].sp_cost), 26), "NativeSmartSP must truncate the4SPdiscount from30, leaving26")
	_check(is_equal_approx(float(skills.catalog("7813021")[0].sp_cost), 10), "NativeSmartSP must never discount its own cast")
	_check(bool(skills.learn(7811061).ok) and bool(skills.cast(7811061, combat).ok) and float(combat.player.shield) > 200, "Native immediateDP repair failed")
	skills.sp = 0
	for step in range(6):
		skills.advance(0.5, combat)
	_check(skills.sp == 5 and combat.player.sp == 5 and combat.player.max_sp == 1000, "NativeSPregen3+floor(SP/500) per3s or HUD synchronization failed")
	_check(not bool(skills.cast(7811041, combat).ok) and skills.sp == 5, "InsufficientSP cast changed resource")
	combat.player.dead = true
	for step in range(6):
		skills.advance(0.5, combat)
	_check(skills.sp == 5 and not bool(skills.cast(7811041, combat).ok), "Destroyed GEAR regeneratedSP/cast skills")


func _test_native_berserker_and_movement_modifiers() -> void:
	var skills = _skills("12003100")
	var combat = _combat()
	combat.add_target({"HP": 100000, "Level": 125, "MoveSpeed": 0, "hostile": false}, Vector3(0, 0, -100))
	_check(bool(skills.learn(7833051).ok) and bool(skills.cast(7833051, combat).ok), "Native Berserker rank1 did not cast")
	combat.advance(0.5, {"secondary": true})
	var volleys := 0
	for event: Dictionary in combat.drain_events():
		if str(event.type) == "fired" and str(event.slot) == "secondary":
			volleys += 1
	_check(volleys == 3 and int(combat.player.secondary_ammo) == 91, "Berserker nativeShotNum+2,MultiNum+2,ReAttack−30percent did not produce3volleys/9rounds")
	_check(is_equal_approx(float(combat.weapons.secondary.interval), 1.0), "Timed Berserker destructively changed base weapon definition")
	_check(bool(skills.learn(7833011).ok) and bool(skills.cast(7833011, combat).ok), "Native HyperMoving rank1 did not cast")
	var modifiers: Dictionary = skills.modifiers()
	_check(is_equal_approx(float(modifiers.reaction_speed_factor), 0.1) and is_equal_approx(float(modifiers.turn_angle_factor), 0.1) and is_equal_approx(float(modifiers.boost_turn_angle_factor), 0.1) and is_equal_approx(float(modifiers.booster_speed_add), 20), "HyperMoving source engine parameters not exposed to flight")
	_check(not modifiers.has("hyper_booster"), "Unrelated movement skill invented DES166HyperBooster")
	for step in range(30):
		skills.advance(0.5, combat)
	_check(not skills.modifiers().has("secondary_reattack") and skills.modifiers().has("booster_speed_add"), "Independent15sBerserker and60sHyperMoving durations were merged")
	_check(not bool(skills.cast(7833051, combat).ok), "Native30minuteBerserker recast disappeared at buff expiry")
	var frenzy = _skills("12003100")
	var angled = _combat()
	angled.weapons.secondary.lock_angle = 0.2
	angled.add_target({"HP": 100000, "Level": 125, "MoveSpeed": 0, "hostile": false}, Vector3(sin(0.25) * 100, 0, -cos(0.25) * 100))
	angled.select_target(0)
	angled.advance(0.1)
	_check(angled.lock_progress == 0, "Frenzy angle fixture was inside unmodified lockcone")
	_check(bool(frenzy.learn(7830031).ok) and bool(frenzy.cast(7830031, angled).ok), "Native Frenzy rank1 did not cast")
	angled.advance(0.1)
	_check(angled.lock_progress == 1, "NativeFrenzy RangeAngle must add0.09radians, allowing0.25rad beyond0.2base")


func _test_lifecycle_save_and_atomic_rejection() -> void:
	var skills = _skills()
	var combat = _combat()
	skills.learn(7800011)
	skills.assign_slot(1, 7800011)
	skills.cast_slot(1, combat)
	for step in range(10):
		skills.advance(0.5, combat)
	var state: Dictionary = skills.export_state()
	var restored = _skills()
	_check(restored.import_state(JSON.parse_string(JSON.stringify(state))) and restored.export_state() == state, "Learned/hotbar/SP/buff/recast state did not roundtrip throughJSON")
	var invalid := state.duplicate(true)
	invalid.sp = 1001
	_check(not restored.import_state(invalid) and restored.export_state() == state, "Invalid savedSP mutated skill model before rejection")
	invalid = state.duplicate(true)
	invalid.hotbar[1] = 7811041
	_check(not restored.import_state(invalid) and restored.export_state() == state, "Unlearned saved hotbar ability bypassed validation")
	invalid = state.duplicate(true)
	invalid.active[7800010].remaining = 99999
	_check(not restored.import_state(invalid) and restored.export_state() == state, "Forged effect duration bypassed validation")
	invalid = state.duplicate(true)
	invalid.learned = [7800012]
	invalid.hotbar = [7800012, 0, 0, 0, 0, 0, 0, 0]
	_check(not restored.import_state(invalid) and restored.export_state() == state, "Saved advanced skill bypassed rank learning chain")
	invalid = state.duplicate(true)
	invalid.cooldowns[7800010] = 9999
	_check(not restored.import_state(invalid) and restored.export_state() == state, "Saved recast exceeded any learned source skill")
	_check(restored.import_state({}) and restored.export_state() == state, "Backward-compatible missing skill checkpoint changed current state")
	var before_sp: float = restored.sp
	restored.set_profile({"gear_id": "12001100", "level": 125, "max_sp": 1200})
	_check(restored.sp == before_sp and restored.modifiers().is_empty() and not restored.export_state().cooldowns.is_empty(), "Class switch refreshedSP/recast or preserved foreign-class buff")
	restored.set_profile({"gear_id": "12000100", "level": 125, "max_sp": 1000})
	_check(not bool(restored.cast_slot(1, combat).ok), "Switching away/back bypassed family recast")
	var expiry = _skills()
	expiry.learn(7800011)
	expiry.cast(7800011, combat)
	for step in range(360):
		expiry.advance(0.5, combat)
	_check(expiry.modifiers().is_empty() and combat.skill_modifiers.is_empty(), "Timed buff remained active after native180seconds")


func _test_stats_preserve_encounter() -> void:
	var combat = _combat()
	combat.player.hp = 600
	combat.player.shield = 500
	combat.player.primary_cooldown = 0.75
	combat.player.primary_heat_remaining = 0.1
	combat.add_target({"HP": 500, "Level": 125, "hostile": false}, Vector3(0, 0, -100))
	combat.targets[0].hp = 123
	combat.select_target(0)
	combat.lock_progress = 0.5
	combat.apply_player_stats({"max_hp": 2000, "max_shield": 2000, "primary_min_attack": 0.1, "primary_max_attack": 0.1, "defense": 5, "dodge": 6, "level": 125})
	_check(combat.player.hp == 600 and combat.player.shield == 500 and combat.player.primary_cooldown == 0.75 and combat.player.primary_ammo == 100 and combat.targets[0].hp == 123 and combat.lock_progress == 0.5, "Equipment attribute update reset vitals/ammo/recast/encounter/lock")
	var outcome: Dictionary = combat.resolve_attack(combat.weapons.primary, combat.player, {"level": 125}, 100)
	_check(outcome.hit and is_equal_approx(float(outcome.damage), 110), "Equipment native damage modifiers do not reach combat formula")
	combat.set_skill_modifiers({"primary_min_attack": 0.05, "primary_max_attack": 0.05})
	outcome = combat.resolve_attack(combat.weapons.primary, combat.player, {"level": 125}, 100)
	_check(is_equal_approx(float(outcome.damage), 115), "Skill+equipment parameter factors must add before native damage multiplication")
	var incoming = _combat()
	incoming.set_skill_modifiers({"secondary_defense": 50})
	var weapon := {"ItemNum": 9, "Kind": 9, "AbilityMin": 100, "AbilityMax": 100, "HitRate": 100, "Range": 400, "ReAttacktime": 1000}
	incoming.add_target({"HP": 500, "Level": 125, "MoveSpeed": 0, "hostile": true, "weapon": weapon}, Vector3(0, 0, -100))
	incoming.targets[0].attack_cooldown = 0
	incoming.advance(0.1)
	_check(is_equal_approx(float(incoming.player.shield), 950), "Secondary NPC weapon used primary defense instead of native secondary defense modifiers")
