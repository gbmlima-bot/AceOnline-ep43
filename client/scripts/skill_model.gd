class_name SkillModel
extends RefCounted
## Recovered native skills, with explicitly limited self-target execution.
## No account ownership or party is inferred from a catalog definition.

const CATALOG_PATH := "res://assets/original_library/catalogs/skills.json"
const BINARY_PATH := "res://assets/original_library/catalogs/omi-native.bin"
const GEAR_MASKS := {"12000100": 1, "12001100": 16, "12002100": 256, "12003100": 4096}
const PARAM_KEYS := {18: "primary_min_attack", 71: "primary_max_attack", 19: "secondary_min_attack", 72: "secondary_max_attack", 20: "primary_hit", 21: "secondary_hit", 22: "primary_defense", 23: "secondary_defense", 24: "primary_dodge", 25: "secondary_dodge", 31: "primary_reattack", 32: "secondary_reattack", 38: "secondary_range_angle", 69: "secondary_shot_num", 70: "secondary_multi_num", 148: "sp_reduction", 154: "reaction_speed_factor", 155: "turn_angle_factor", 156: "boost_turn_angle_factor", 181: "booster_speed_add"}
const HEALS := {59: "hp", 83: "shield", 60: "sp"}
const SOURCE_NOOP_IDS := [23910, 23911, 23912, 23913]
const MAX_TIMER := 90000.0
static var _catalog_cache: Dictionary = {}

var definitions: Dictionary = {}
var learned: Dictionary = {}
var hotbar: Array[int] = [0, 0, 0, 0, 0, 0, 0, 0]
var sp := 200.0
var max_sp := 200.0
var level := 9
var gear_id := "12003100"
var gear_unit_mask := 4096
var status := "Aprenda habilidades na escola ou use a formação inicial local."
var _active: Dictionary = {}
var _cooldowns: Dictionary = {}
var _regen_elapsed := 0.0
var _serial := 0
var _configured := false
var _events: Array[Dictionary] = []


func configure(profile: Dictionary = {}) -> bool:
	if not _load_catalog():
		return false
	learned.clear()
	hotbar = [0, 0, 0, 0, 0, 0, 0, 0]
	_active.clear()
	_cooldowns.clear()
	_events.clear()
	_serial = 0
	_regen_elapsed = 0.0
	_configured = false
	set_profile(profile)
	sp = max_sp
	_configured = true
	return true


func _load_catalog() -> bool:
	# Definitions are immutable source data; server pilots share them while
	# learned ranks/resources/timers remain private per SkillModel instance.
	if not _catalog_cache.is_empty():
		definitions = _catalog_cache
		return true
	definitions = {}
	var source: Variant = JSON.parse_string(FileAccess.get_file_as_string(CATALOG_PATH))
	if not source is Dictionary or not source.get("records", null) is Array:
		return false
	var binary := FileAccess.get_file_as_bytes(BINARY_PATH)
	var hashing := HashingContext.new()
	hashing.start(HashingContext.HASH_SHA256)
	hashing.update(binary)
	if hashing.finish().hex_encode() != str(source.get("source", {}).get("sha256", "")):
		return false
	for value: Variant in source.records:
		if not value is Dictionary:
			return false
		var record: Dictionary = value.duplicate(true)
		var offset := int(record.get("_source", {}).get("offset", -1))
		if offset < 0 or offset + 576 > binary.size():
			return false
		var parameters: Array[Dictionary] = []
		for index in range(8):
			var destination := binary.decode_u16(offset + 120 + index * 2)
			var amount := binary.decode_float(offset + 136 + index * 4)
			if not is_finite(amount):
				return false
			if destination == 0 or (destination in SOURCE_NOOP_IDS and amount == 0.0):
				continue
			parameters.append({"destination": destination, "value": amount})
		record["parameters"] = parameters
		record["family"] = int(record.get("NextSkill", record.ItemNum))
		if int(record.family) <= 0:
			record.family = int(record.ItemNum)
		record["blocked_reason"] = _unsupported_reason(record)
		definitions[int(record.ItemNum)] = record
	if not definitions.is_empty():
		_catalog_cache = definitions
	return not definitions.is_empty()


func _unsupported_reason(record: Dictionary) -> String:
	if int(record.ItemNum) == int(record.family):
		return "Definição base; aprenda um nível efetivo desta habilidade."
	if int(record.get("ReqUnitKind", 0)) in [0, 65535]:
		return "Efeito de sistema, evento ou formação; concessão original não recuperada."
	var skill_type := int(record.get("SkillType", -1))
	if skill_type not in [1, 2]:
		return "Modo alternável ou carregado ainda não portado."
	var target_type := int(record.get("SkillTargetType", -1))
	if target_type not in [0, 1]:
		return "Exige formação ou múltiplos alvos; execução local não presume um grupo."
	if record.parameters.is_empty():
		return "Ação especial sem parâmetros de atributo; movimento próprio ainda não portado."
	for parameter: Dictionary in record.parameters:
		var destination := int(parameter.destination)
		if skill_type == 2 and target_type == 0 and PARAM_KEYS.has(destination):
			continue
		if skill_type == 1 and HEALS.has(destination):
			continue
		return "Efeito nativo %d ainda não portado; habilidade bloqueada por inteiro." % destination
	if skill_type == 2 and int(record.get("Time", 0)) <= 0:
		return "Duração original inválida para um efeito temporário."
	return ""


func set_profile(profile: Dictionary) -> void:
	var stats: Dictionary = profile.get("player", profile)
	level = maxi(1, int(stats.get("level", profile.get("level", level))))
	gear_id = str(profile.get("gear_id", stats.get("gear_id", gear_id)))
	var replacement_mask := int(profile.get("gear_unit_mask", stats.get("gear_unit_mask", GEAR_MASKS.get(gear_id, gear_unit_mask))))
	if _configured and replacement_mask != gear_unit_mask:
		# A local F2 class switch is not a new session and cannot reset recasts/SP.
		_active.clear()
	gear_unit_mask = replacement_mask
	var capacity := float(stats.get("max_sp", profile.get("max_sp", max_sp)))
	if is_finite(capacity):
		max_sp = maxf(1.0, capacity)
	sp = minf(sp, max_sp)
	for family: Variant in _active.keys():
		if not _requirements(definitions[int(_active[family].item_num)]).is_empty():
			_active.erase(family)


func _requirements(record: Dictionary) -> String:
	if (int(record.get("ReqUnitKind", 0)) & gear_unit_mask) == 0:
		return "Habilidade de outra classe GEAR."
	if int(record.get("ReqMinLevel", 0)) > level or (int(record.get("ReqMaxLevel", 0)) > 0 and level > int(record.ReqMaxLevel)):
		return "Exige nível %d." % int(record.get("ReqMinLevel", 0))
	return ""


func can_learn(item_num: int) -> Dictionary:
	var record: Dictionary = definitions.get(item_num, {})
	if record.is_empty():
		return _failure("Habilidade original desconhecida.")
	if not str(record.blocked_reason).is_empty():
		return _failure(str(record.blocked_reason))
	if learned.has(item_num):
		return _failure("Habilidade já aprendida.")
	var reason := _requirements(record)
	if not reason.is_empty():
		return _failure(reason)
	var needed_rank := int(record.get("SkillLevel", 1)) - 1
	var highest := 0
	for known_id: Variant in learned:
		var known: Dictionary = definitions[int(known_id)]
		if int(known.family) == int(record.family):
			highest = maxi(highest, int(known.get("SkillLevel", 1)))
	if highest < needed_rank:
		return _failure("Aprenda primeiro o nível anterior desta habilidade.")
	return {"ok": true, "item_num": item_num, "cost": maxi(0, int(record.get("Price", 0)))}


func learn(item_num: int) -> Dictionary:
	# Economic debit/proximity is the caller's transaction; this model grants no ITEM.
	var result := can_learn(item_num)
	if not bool(result.ok):
		return result
	learned[item_num] = true
	var record: Dictionary = definitions[item_num]
	for index in range(8):
		if hotbar[index] > 0 and int(definitions[hotbar[index]].family) == int(record.family):
			hotbar[index] = item_num
	status = "%s · nível %d aprendido." % [record.ItemName, int(record.SkillLevel)]
	return result


func learn_base_skills() -> Dictionary:
	# Explicit offline training policy: only native, compatible effective rank1.
	# Callers may offer this at a school; it is never invoked by configure/import.
	var added: Array[int] = []
	for item_num: Variant in definitions:
		var record: Dictionary = definitions[item_num]
		if int(record.get("SkillLevel", 1)) != 1 or not bool(can_learn(int(item_num)).ok):
			continue
		learn(int(item_num))
		added.append(int(item_num))
		var empty_slot := hotbar.find(0)
		if empty_slot >= 0:
			hotbar[empty_slot] = int(item_num)
	status = "%d habilidades iniciais aprendidas por treinamento local." % added.size()
	return {"ok": true, "learned": added, "local_training_policy": true}


func assign_slot(slot: int, item_num: int) -> Dictionary:
	if slot < 1 or slot > 8:
		return _failure("Atalho deve estar entre 1 e 8.")
	if item_num != 0 and not learned.has(item_num):
		return _failure("Aprenda a habilidade antes de atribuir um atalho.")
	if item_num != 0 and not _requirements(definitions[item_num]).is_empty():
		return _failure(_requirements(definitions[item_num]))
	hotbar[slot - 1] = item_num
	return {"ok": true, "slot": slot, "item_num": item_num}


func cast_slot(slot: int, combat: RefCounted, context: Dictionary = {}) -> Dictionary:
	if slot < 1 or slot > 8:
		return _failure("Atalho deve estar entre 1 e 8.")
	return cast(hotbar[slot - 1], combat, context)


func cast(item_num: int, combat: RefCounted, context: Dictionary = {}) -> Dictionary:
	if combat == null or combat.get("player") == null or combat.player.is_empty():
		return _failure("Combate não está configurado.")
	if bool(combat.player.get("dead", false)):
		return _failure("Não é possível usar habilidades enquanto destruído.")
	var reason := _cast_reason(item_num)
	if not reason.is_empty():
		return _failure(reason)
	if str(context.get("target", "self")) != "self":
		return _failure("Esta implementação executa somente no próprio GEAR.")
	var record: Dictionary = definitions[item_num]
	if not _weapon_requirement(record, combat):
		return _failure("O equipamento atual não atende ReqItemKind desta habilidade.")
	var cost := _sp_cost(record)
	sp -= cost
	var family := int(record.family)
	_cooldowns[family] = maxf(0.0, float(record.get("ReAttacktime", 0)) / 1000.0)
	if int(record.SkillType) == 2:
		_active[family] = {"item_num": item_num, "remaining": float(record.Time) / 1000.0}
	else:
		for parameter: Dictionary in record.parameters:
			var destination := int(parameter.destination)
			var value := maxf(0.0, float(parameter.value))
			if destination == 60:
				sp = minf(max_sp, sp + value)
			elif destination == 59:
				combat.player.hp = minf(float(combat.player.max_hp), float(combat.player.hp) + value)
			elif destination == 83:
				combat.player.shield = minf(float(combat.player.max_shield), float(combat.player.shield) + value)
	_serial += 1
	var result := {"ok": true, "type": "skill_used", "item_num": item_num, "base_item_num": family, "skill_type": int(record.SkillType), "count": 1, "event_id": "skill:%d" % _serial, "sp_used": cost}
	_events.append(result.duplicate(true))
	status = "%s · %d SP" % [record.ItemName, int(cost)]
	_sync_combat(combat)
	return result


static func _weapon_requirement(record: Dictionary, combat: RefCounted) -> bool:
	# Native CheckSkillReqItemKind/COMPARE_ITEMKIND, using equipped real weapons.
	var requirement := int(record.get("ReqItemKind", 40))
	if requirement == 40:
		return true
	for weapon: Dictionary in combat.weapons.values():
		var kind := int(weapon.get("kind", -1))
		if requirement == kind or (requirement == 43 and kind >= 0 and kind <= 15) or (requirement in [44, 45] and kind >= 0 and kind <= 7) or (requirement == 47 and kind >= 8 and kind <= 15) or (requirement == 48 and kind >= 8 and kind <= 11) or (requirement == 49 and kind >= 12 and kind <= 15):
			return true
	return false


func _cast_reason(item_num: int) -> String:
	if item_num <= 0 or not learned.has(item_num):
		return "Atalho vazio ou habilidade não aprendida."
	var record: Dictionary = definitions[item_num]
	var requirement := _requirements(record)
	if not requirement.is_empty():
		return requirement
	if float(_cooldowns.get(int(record.family), 0.0)) > 0.000001:
		return "Habilidade em recarga."
	if sp + 0.000001 < _sp_cost(record):
		return "SP insuficiente."
	return ""


func _sp_cost(record: Dictionary) -> float:
	# DecreaseCurrentSP subtracts int(cost * SmartSP) from the requested cost.
	# Truncation applies to the discount, not the final positive cost.
	var cost := maxi(0, int(record.get("ReqSP", 0)))
	var reduction := 0.0 if int(record.get("family", 0)) == 7813020 else clampf(float(modifiers().get("sp_reduction", 0.0)), 0.0, 1.0)
	return float(cost - int(float(cost) * reduction))


func advance(delta: float, combat: RefCounted = null) -> void:
	if not is_finite(delta) or delta <= 0.0:
		return
	var step := minf(delta, 0.5)
	for family: Variant in _cooldowns.keys():
		_cooldowns[family] = maxf(0.0, float(_cooldowns[family]) - step)
		if float(_cooldowns[family]) <= 0.000001:
			_cooldowns.erase(family)
	var dead := combat != null and bool(combat.player.get("dead", false))
	if dead:
		_active.clear()
		_regen_elapsed = 0.0
	else:
		for family: Variant in _active.keys():
			_active[family].remaining = float(_active[family].remaining) - step
			if float(_active[family].remaining) <= 0.000001:
				_active.erase(family)
		if sp < max_sp:
			_regen_elapsed += step
			while _regen_elapsed + 0.000001 >= 3.0:
				sp = minf(max_sp, sp + 3.0 + floorf(max_sp / 500.0))
				_regen_elapsed -= 3.0
		else:
			_regen_elapsed = 0.0
	if combat != null:
		_sync_combat(combat)


func modifiers() -> Dictionary:
	var result: Dictionary = {}
	for active: Dictionary in _active.values():
		for parameter: Dictionary in definitions[int(active.item_num)].parameters:
			var key := str(PARAM_KEYS.get(int(parameter.destination), ""))
			if not key.is_empty():
				result[key] = float(result.get(key, 0.0)) + float(parameter.value)
	return result


func _sync_combat(combat: RefCounted) -> void:
	combat.set_skill_modifiers(modifiers())
	combat.player.sp = sp
	combat.player.max_sp = max_sp


func sync_combat(combat: RefCounted) -> void:
	# Synchronization is not a simulation tick; save/load must preserve timers.
	_sync_combat(combat)


func catalog(query: String = "") -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var normalized := query.strip_edges().to_lower()
	for item_num: Variant in definitions:
		var record: Dictionary = definitions[item_num]
		if not normalized.is_empty() and normalized not in (str(item_num) + " " + str(record.ItemName) + " " + str(record.get("Description", ""))).to_lower():
			continue
		var learn_result := can_learn(int(item_num))
		var reason := str(record.blocked_reason)
		if reason.is_empty() and not bool(learn_result.ok):
			reason = str(learn_result.get("reason", ""))
		var family := int(record.family)
		result.append({"id": int(item_num), "item_num": int(item_num), "name": str(record.ItemName), "description": str(record.get("Description", "")), "supported": str(record.blocked_reason).is_empty(), "learned": learned.has(int(item_num)), "learnable": bool(learn_result.ok), "reason": reason, "min_level": int(record.get("ReqMinLevel", 0)), "level": int(record.get("SkillLevel", 1)), "cost": int(record.get("Price", 0)), "sp_cost": _sp_cost(record), "iconitem": int(item_num), "cooldown": float(_cooldowns.get(family, 0.0)), "duration": float(record.get("Time", 0)) / 1000.0, "remaining": float(_active.get(family, {}).get("remaining", 0.0)), "family": family})
	return result


func snapshot(include_catalog: bool = true) -> Dictionary:
	var slots: Array[Dictionary] = []
	for index in range(8):
		var item_num := hotbar[index]
		var record: Dictionary = definitions.get(item_num, {})
		var family := int(record.get("family", 0))
		var reason := _cast_reason(item_num)
		slots.append({"slot": index + 1, "id": item_num, "item_num": item_num, "name": str(record.get("ItemName", "Vazio")), "sp_cost": _sp_cost(record), "cooldown": float(_cooldowns.get(family, 0.0)), "remaining": float(_active.get(family, {}).get("remaining", 0.0)), "usable": reason.is_empty(), "reason": reason, "iconitem": item_num})
	var supported := 0
	for record: Dictionary in definitions.values():
		if str(record.blocked_reason).is_empty():
			supported += 1
	return {"sp": sp, "max_sp": max_sp, "level": level, "gear_id": gear_id, "hotbar": slots, "rows": catalog() if include_catalog else [], "status": status, "supported_count": supported, "blocked_count": definitions.size() - supported, "modifiers": modifiers(), "active_count": _active.size(), "local_policy": "Treinamento inicial opcional local; alvos suportados executados somente no próprio GEAR."}


func export_state() -> Dictionary:
	return {"schema_version": 1, "learned": learned.keys(), "hotbar": hotbar.duplicate(), "sp": sp, "cooldowns": _cooldowns.duplicate(true), "active": _active.duplicate(true), "regen_elapsed": _regen_elapsed, "serial": _serial}


func import_state(state: Dictionary) -> bool:
	# Old checkpoints omit skills entirely; leave the configured defaults unchanged.
	if state.is_empty():
		return true
	if int(state.get("schema_version", -1)) != 1 or not state.get("learned", null) is Array or not state.get("hotbar", null) is Array or state.hotbar.size() != 8 or not state.get("cooldowns", null) is Dictionary or not state.get("active", null) is Dictionary:
		return false
	var new_sp: Variant = state.get("sp", -1)
	var regen: Variant = state.get("regen_elapsed", -1)
	var serial: Variant = state.get("serial", -1)
	if not _number(new_sp) or float(new_sp) < 0.0 or float(new_sp) > max_sp or not _number(regen) or float(regen) < 0.0 or float(regen) > 3.0 or not _integer(serial) or int(serial) < 0:
		return false
	var new_learned: Dictionary = {}
	if state.learned.size() > definitions.size() or state.cooldowns.size() > definitions.size() or state.active.size() > definitions.size():
		return false
	for item_num: Variant in state.learned:
		if not _integer(item_num) or not definitions.has(int(item_num)) or not str(definitions[int(item_num)].blocked_reason).is_empty() or new_learned.has(int(item_num)):
			return false
		new_learned[int(item_num)] = true
	# This model keeps every purchased rank; reject a checkpoint that invents
	# an advanced rank while omitting the required learning chain.
	for item_num: Variant in new_learned:
		var record: Dictionary = definitions[int(item_num)]
		for rank in range(1, int(record.get("SkillLevel", 1))):
			var has_predecessor := false
			for known_id: Variant in new_learned:
				var known: Dictionary = definitions[int(known_id)]
				if int(known.family) == int(record.family) and int(known.SkillLevel) == rank:
					has_predecessor = true
					break
			if not has_predecessor:
				return false
	var new_hotbar: Array[int] = []
	for item_num: Variant in state.hotbar:
		if not _integer(item_num) or (int(item_num) != 0 and not new_learned.has(int(item_num))):
			return false
		new_hotbar.append(int(item_num))
	var new_cooldowns: Dictionary = {}
	for family: Variant in state.cooldowns:
		if not str(family).is_valid_int():
			return false
		var family_id := str(family).to_int()
		var remaining: Variant = state.cooldowns[family]
		if not definitions.has(family_id) or not _number(remaining) or float(remaining) < 0.0 or float(remaining) > MAX_TIMER:
			return false
		var maximum_recast := 0.0
		for known_id: Variant in new_learned:
			var known: Dictionary = definitions[int(known_id)]
			if int(known.family) == family_id:
				maximum_recast = maxf(maximum_recast, float(known.ReAttacktime) / 1000.0)
		if float(remaining) > maximum_recast:
			return false
		new_cooldowns[family_id] = float(remaining)
	var new_active: Dictionary = {}
	for family: Variant in state.active:
		if not str(family).is_valid_int():
			return false
		var value: Variant = state.active[family]
		if not value is Dictionary or not _integer(value.get("item_num")) or not new_learned.has(int(value.item_num)) or not _number(value.get("remaining")):
			return false
		var record: Dictionary = definitions[int(value.item_num)]
		if int(record.SkillType) != 2 or str(family).to_int() != int(record.family) or float(value.remaining) <= 0.0 or float(value.remaining) > float(record.Time) / 1000.0 or not _requirements(record).is_empty():
			return false
		new_active[int(record.family)] = {"item_num": int(value.item_num), "remaining": float(value.remaining)}
	learned = new_learned
	hotbar = new_hotbar
	sp = float(new_sp)
	_cooldowns = new_cooldowns
	_active = new_active
	_regen_elapsed = float(regen)
	_serial = int(serial)
	_events.clear()
	return true


func drain_events() -> Array[Dictionary]:
	var result: Array[Dictionary] = _events.duplicate(true)
	_events.clear()
	return result


static func _failure(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason, "error": reason}


static func _number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))


static func _integer(value: Variant) -> bool:
	return _number(value) and float(value) == floorf(float(value)) and absf(float(value)) < 9007199254740991.0
