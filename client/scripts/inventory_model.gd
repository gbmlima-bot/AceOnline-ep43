class_name InventoryModel
extends RefCounted
## Native ITEM identities with an explicit local character inventory, never an account.
## Native positions, requirements and scalar effects; unsupported effects stay blocked.

const NativeEquipment = preload("res://scripts/native_equipment.gd")
const CATALOG_PATH := "res://assets/original_library/catalogs/items.json"
const SLOT_POSITIONS := {"primary": 2, "secondary": 4, "engine": 6, "armor": 5, "cpu": 1, "radar": 0, "accessory": 7}
const SLOT_KINDS := {"engine": [17], "armor": [16], "cpu": [26], "radar": [25], "accessory": [31]}
const GEAR_KINDS := {"12000100": 1, "12001100": 16, "12002100": 256, "12003100": 4096}
const MAX_COUNT := 1000000000
const MAX_EXPERIENCE := 9007199254740991
const EXPERIENCE_PATH := "res://assets/original_library/catalogs/level_experience.json"

var catalog: Dictionary = {}
var quantities: Dictionary = {}
var equipped: Dictionary = {}
var reward_ids: Dictionary = {}
var credits := 0
var experience := 0
var bonus_stats := 0
var level := 9
var starting_level := 9
var experience_origin := 0
var effective_experience := 0.0
var experience_discarded := 0.0
var _experience_rows: Dictionary = {}
var _max_level := 125
var gear_id := "12003100"
var _icons: Dictionary = {}
var allocated_stats: Dictionary = {}
var grandfathered_equipment: Dictionary = {}
var _stat_rows: Dictionary = {}
var _armor_models: Dictionary = {}
var _native_equipment_ready := false

func configure(items: Array = []) -> bool:
	catalog.clear()
	var rows: Array = items
	if rows.is_empty():
		for path: String in [CATALOG_PATH, "res://assets/legacy_rules/weapons.json", "res://assets/legacy_rules/engines.json"]:
			if not FileAccess.file_exists(path):
				continue
			var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
			if data is Dictionary and data.get("records", []) is Array:
				rows.append_array(data.records)
	for value: Variant in rows:
		if value is Dictionary and int(value.get("ItemNum", 0)) > 0:
			catalog[int(value.ItemNum)] = value.duplicate(true)
	_native_equipment_ready = NativeEquipment.enrich_catalog(catalog)
	if FileAccess.file_exists("res://assets/original_library/icons/items.json"):
		var icons: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://assets/original_library/icons/items.json"))
		if icons is Dictionary:
			for key: Variant in icons.get("by_item", {}):
				var binding: Variant = icons.by_item[key]
				if binding is Dictionary:
					_icons[int(key)] = str(binding.get("small", ""))
	_load_experience_table()
	_load_equipment_tables()
	set_starting_level(starting_level)
	return not catalog.is_empty()

func add_item(item_num: int, count: int = 1) -> bool:
	if not catalog.has(item_num) or count <= 0 or count > MAX_COUNT:
		return false
	var previous := int(quantities.get(item_num, 0))
	if previous > MAX_COUNT - count:
		return false
	quantities[item_num] = previous + count
	return true

func can_equip(item_num: int, slot: String, require_owned: bool = true) -> Dictionary:
	if not SLOT_POSITIONS.has(slot):
		return {"ok": false, "error": "unsupported_slot"}
	var item: Dictionary = catalog.get(item_num, {})
	if item.is_empty():
		return {"ok": false, "error": "unknown_native_item"}
	if require_owned and int(quantities.get(item_num, 0)) <= 0:
		return {"ok": false, "error": "item_not_owned"}
	if int(item.get("Position", -1)) != int(SLOT_POSITIONS[slot]):
		return {"ok": false, "error": "native_position_mismatch"}
	if SLOT_KINDS.has(slot) and not int(item.get("Kind", -1)) in SLOT_KINDS[slot]:
		return {"ok": false, "error": "unsupported_native_kind"}
	if (int(item.get("ReqUnitKind", 0)) & int(GEAR_KINDS.get(gear_id, 0))) == 0:
		return {"ok": false, "error": "native_gear_requirement"}
	if int(item.get("ReqMinLevel", 0)) > level or (int(item.get("ReqMaxLevel", 0)) > 0 and level > int(item.ReqMaxLevel)):
		return {"ok": false, "error": "native_level_requirement"}
	if slot in ["armor", "cpu", "radar", "accessory"]:
		var effects := NativeEquipment.supported_parameters(item, slot == "cpu")
		if not bool(effects.ok):
			return effects
		# Timed, invoked and special-authority items need server lifecycle rules.
		if int(item.get("Time", 0)) != 0 or (int(item.get("ItemAttribute", 0)) & 0x00880848) != 0:
			return {"ok": false, "error": "native_equipment_lifecycle_not_ported"}
	var stats := _total_stats_without_slot(slot)
	for stat: String in item.get("ReqGearStat", {}):
		if int(grandfathered_equipment.get(slot, 0)) == item_num:
			break
		if int(stats.get(stat, 0)) < int(item.ReqGearStat[stat]):
			return {"ok": false, "error": "native_stat_requirement", "stat": stat, "required": int(item.ReqGearStat[stat])}
	return {"ok": true, "item": item}

func equip_item(item_num: int, slot: String) -> Dictionary:
	var result := can_equip(item_num, slot)
	if bool(result.ok):
		var candidate := equipped.duplicate()
		candidate[slot] = item_num
		if not _equipment_requirements_hold(candidate):
			return {"ok": false, "error": "other_equipment_stat_requirement"}
		equipped[slot] = item_num
		if int(grandfathered_equipment.get(slot, 0)) != item_num:
			grandfathered_equipment.erase(slot)
	return result


func unequip_item(slot: String) -> Dictionary:
	if not SLOT_POSITIONS.has(slot):
		return {"ok": false, "error": "unsupported_slot"}
	var candidate := equipped.duplicate()
	candidate.erase(slot)
	if not _equipment_requirements_hold(candidate):
		return {"ok": false, "error": "other_equipment_stat_requirement"}
	equipped = candidate
	grandfathered_equipment.erase(slot)
	return {"ok": true}


func remove_item(item_num: int, count: int = 1) -> Dictionary:
	return exchange([{"item_num": item_num, "count": count}], [], 0)


func apply_transaction(credit_delta: int, additions: Array, removals: Array, options: Dictionary = {}) -> Dictionary:
	if not options.is_empty():
		return {"ok": false, "error": "unsupported_transaction_option"}
	return exchange(removals, additions, credit_delta)


func exchange(remove_items: Array, add_items: Array, credit_delta: int = 0) -> Dictionary:
	if credit_delta < -MAX_COUNT or credit_delta > MAX_COUNT or credits + credit_delta < 0 or credits + credit_delta > MAX_COUNT:
		return {"ok": false, "error": "insufficient_credits" if credit_delta < 0 else "credit_overflow"}
	var removals := _transaction_items(remove_items)
	var additions := _transaction_items(add_items)
	if not bool(removals.ok):
		return removals
	if not bool(additions.ok):
		return additions
	var candidate := quantities.duplicate()
	for identifier: int in removals.items:
		var remaining := int(candidate.get(identifier, 0)) - int(removals.items[identifier])
		if remaining < 0:
			return {"ok": false, "error": "insufficient_items", "item_num": identifier}
		if remaining == 0 and equipped.values().has(identifier):
			return {"ok": false, "error": "item_is_equipped", "item_num": identifier}
		if remaining == 0:
			candidate.erase(identifier)
		else:
			candidate[identifier] = remaining
	for identifier: int in additions.items:
		var count := int(additions.items[identifier])
		if int(candidate.get(identifier, 0)) > MAX_COUNT - count:
			return {"ok": false, "error": "item_count_overflow", "item_num": identifier}
		candidate[identifier] = int(candidate.get(identifier, 0)) + count
	quantities = candidate
	credits += credit_delta
	return {"ok": true, "credit_delta": credit_delta, "removed": removals.items, "added": additions.items}


func _transaction_items(rows: Array) -> Dictionary:
	var result: Dictionary = {}
	if rows.size() > 20000:
		return {"ok": false, "error": "too_many_transaction_rows"}
	for value: Variant in rows:
		if not value is Dictionary:
			return {"ok": false, "error": "invalid_transaction_item"}
		var identifier := _bounded_integer(value.get("item_num", -1))
		var count := _bounded_integer(value.get("count", -1))
		if identifier <= 0 or not catalog.has(identifier) or count <= 0:
			return {"ok": false, "error": "invalid_transaction_item"}
		if int(result.get(identifier, 0)) > MAX_COUNT - count:
			return {"ok": false, "error": "item_count_overflow", "item_num": identifier}
		result[identifier] = int(result.get(identifier, 0)) + count
	return {"ok": true, "items": result}


func allocate_stat(stat: String, count: int = 1) -> Dictionary:
	if not NativeEquipment.STATS.has(stat):
		return {"ok": false, "error": "unknown_native_stat"}
	if count <= 0 or count > bonus_stats:
		return {"ok": false, "error": "insufficient_bonus_stats"}
	if _stat_rows.is_empty():
		return {"ok": false, "error": "native_stat_table_unavailable"}
	var increment := int(NativeEquipment.increments(gear_id)[stat])
	var current := int(NativeEquipment.base_stats(gear_id, allocated_stats)[stat])
	# ChangeStat tests the value before each allocation; the last native increment
	# may cross the cap, while all derived formulas clamp to GET_MAX_STAT_POINT.
	if current + (count - 1) * increment >= _stat_cap():
		return {"ok": false, "error": "native_stat_cap"}
	allocated_stats[stat] = int(allocated_stats.get(stat, 0)) + count
	bonus_stats -= count
	return {"ok": true, "stat": stat, "spent": count, "increase": count * increment, "remaining": bonus_stats}


func can_change_gear(next_gear_id: String) -> Dictionary:
	if not GEAR_KINDS.has(next_gear_id):
		return {"ok": false, "error": "unknown_native_gear"}
	var next_stats := NativeEquipment.base_stats(next_gear_id, allocated_stats)
	for stat: String in NativeEquipment.STATS:
		if int(next_stats[stat]) > _stat_cap():
			return {"ok": false, "error": "native_stat_cap_for_gear", "stat": stat, "actual": int(next_stats[stat]), "maximum": _stat_cap()}
	return {"ok": true, "gear_id": next_gear_id, "base_stats": next_stats}


func _stat_cap() -> int:
	return 300 if level <= 100 else 340


func _total_stats_without_slot(slot: String) -> Dictionary:
	var cpu: Dictionary = {}
	if slot != "cpu":
		cpu = catalog.get(int(equipped.get("cpu", 0)), {})
	return NativeEquipment.total_stats(gear_id, allocated_stats, cpu)


func _equipment_requirements_hold(candidate: Dictionary) -> bool:
	var cpu: Dictionary = catalog.get(int(candidate.get("cpu", 0)), {})
	var total := NativeEquipment.total_stats(gear_id, allocated_stats, cpu)
	for slot: String in candidate:
		var row: Dictionary = catalog.get(int(candidate[slot]), {})
		if int(grandfathered_equipment.get(slot, 0)) == int(candidate[slot]):
			continue
		var applicable := NativeEquipment.base_stats(gear_id, allocated_stats) if slot == "cpu" else total
		for stat: String in row.get("ReqGearStat", {}):
			if int(applicable.get(stat, 0)) < int(row.ReqGearStat[stat]):
				return false
	return true


func armor_appearance() -> Dictionary:
	var identifier := int(equipped.get("armor", 0))
	if identifier <= 0:
		return {"available": false, "item_num": 0, "reason": "no_armor_equipped"}
	var row: Dictionary = catalog.get(identifier, {})
	var binding: Dictionary = _armor_models.get(str(identifier), {})
	if not bool(binding.get("available", false)):
		return {"available": false, "item_num": identifier, "source_index": int(row.get("SourceIndex", 0)), "reason": "native_armor_model_unavailable"}
	var result := binding.duplicate(true)
	result["item_num"] = identifier
	result["source_index"] = int(row.get("SourceIndex", 0))
	result["scope"] = "owned_equipped_native_armor"
	return result


func equipment_modifiers() -> Dictionary:
	return combat_profile()


func weight_profile() -> Dictionary:
	var total_weight := 0.0
	for slot: String in SLOT_POSITIONS:
		var identifier := int(equipped.get(slot, 0))
		if identifier <= 0 or int(quantities.get(identifier, 0)) <= 0:
			continue
		var item: Dictionary = catalog.get(identifier, {})
		# DesWeight is an instance affix/enchantment field, currently unsupported.
		# Spare owned copies of a non-countable item do not add equipped weight.
		total_weight += NativeEquipment.item_weight(item, int(quantities[identifier]), 0.0)
	var total := _total_stats_without_slot("")
	var capacity := float(mini(_stat_cap(), int(total.fuel)) * 60 + 300)
	return {"weight": total_weight, "transport": capacity, "ratio": total_weight / capacity,
		"scope": "native_equipped_items_only_base_weight_no_affix_or_enchantment",
		"source": "AtumSJ.cpp:331-350; AtumParam.h:1338; FieldItemManager.cpp:1711-1734"}


func combat_profile() -> Dictionary:
	var base := NativeEquipment.base_stats(gear_id, allocated_stats)
	var total := _total_stats_without_slot("")
	var cap := _stat_cap()
	var attack: Dictionary = _stat_rows.get(mini(cap, int(total.attack)), {})
	var defense: Dictionary = _stat_rows.get(mini(cap, int(total.defense)), {})
	var dodge: Dictionary = _stat_rows.get(mini(cap, int(total.dodge)), {})
	var shield: Dictionary = _stat_rows.get(mini(cap, int(total.shield)), {})
	var result := {
		"max_hp": 600.0, "max_shield": float(int(shield.get("ShieldPart_DP", 0.0))),
		"max_sp": float(mini(cap, int(total.soul)) * 8), "max_ep": float(mini(cap, int(total.fuel)) * 10),
		"transport": float(mini(cap, int(total.fuel)) * 60 + 300),
		"level": level, "attack_bonus": float(attack.get("AttackPart_AttackIncreaseRate", 0.0)),
		"attack_probability_bonus": float(attack.get("AttackPart_AttackIncreaseProbability", 0.0)),
		"pierce": float(attack.get("AttackPart_PierceAttackProbability", 0.0)),
		"defense": float(defense.get("DefensePart_DefenseDecreaseRate", 0.0)) * 100.0,
		"dodge": float(dodge.get("DodgePart_DefenseProbabilityRate", 0.0)) * 100.0,
		"base_stats": base, "total_stats": total, "stat_cap": cap,
		"source": "EP35 AtumSJ.cpp:1935-2066 + LocalizationDefineCommon.h:106-132; pinned current OMI parameters",
		"scope": "native_scalar_equipment_and_freestyle_stats_local_character",
		"unavailable": ["rare_affixes", "enchantments", "invoking_effects", "timed_equipment", "pet_effects"]}
	for key: String in NativeEquipment.MODIFIER_PARAMETERS.values():
		result[key] = 0.0
	for slot: String in equipped:
		if slot == "cpu":
			continue
		var item: Dictionary = catalog.get(int(equipped[slot]), {})
		for parameter: Dictionary in item.get("native_parameters", []):
			var dest := int(parameter.parameter)
			var key := str(NativeEquipment.MODIFIER_PARAMETERS.get(dest, NativeEquipment.RESOURCE_PARAMETERS.get(dest, "")))
			if not key.is_empty():
				result[key] = float(result.get(key, 0.0)) + float(parameter.value)
	var radar: Dictionary = catalog.get(int(equipped.get("radar", 0)), {})
	result["radar_range"] = float(radar.get("Range", 0.0))
	result["radar_primary_range"] = float(radar.get("AbilityMin", 0.0))
	result["radar_secondary_range"] = float(radar.get("AbilityMax", 0.0))
	return result


func _load_equipment_tables() -> void:
	_stat_rows.clear()
	_armor_models.clear()
	var path := "res://assets/original_library/catalogs/level_stat_values.json"
	if FileAccess.file_exists(path):
		var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if data is Dictionary:
			for row: Dictionary in data.get("records", []):
				_stat_rows[int(row.get("LevelOrStat", -1))] = row
	path = "res://assets/original_library/gears/gears.json"
	if FileAccess.file_exists(path):
		var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if data is Dictionary:
			_armor_models = data.get("by_item_num", {})

func apply_reward(event: Dictionary) -> bool:
	var identifier := str(event.get("reward_id", ""))
	if identifier.is_empty() or reward_ids.has(identifier):
		return false
	var new_credits := _bounded_integer(event.get("credits", 0))
	var new_experience := _bounded_experience(event.get("experience", 0))
	var new_bonus := _bounded_integer(event.get("bonus_stats", 0))
	var native_bonus := 0
	if not _experience_rows.is_empty() and level < _max_level and effective_experience + float(maxi(0, new_experience)) >= float(_experience_rows[level]):
		var next_level := level + 1
		if next_level <= 110 or next_level in [115, 120, 125]:
			native_bonus = 1
	if new_credits < 0 or new_experience < 0 or new_bonus < 0 or credits > MAX_COUNT - new_credits or experience > MAX_EXPERIENCE - new_experience or bonus_stats > MAX_COUNT - new_bonus - native_bonus:
		return false
	var additions: Dictionary = {}
	var items: Variant = event.get("items", [])
	if not items is Array:
		return false
	for value: Variant in items:
		if not value is Dictionary:
			return false
		var item_num := _bounded_integer(value.get("item_num", value.get("ItemNum", 0)))
		var count := _bounded_integer(value.get("count", 1))
		var mask := int(value.get("gear_mask", 0))
		if mask != 0 and (mask & int(GEAR_KINDS.get(gear_id, 0))) == 0:
			continue
		if item_num <= 0 or count <= 0 or not catalog.has(item_num):
			return false
		additions[item_num] = int(additions.get(item_num, 0)) + count
		if int(additions[item_num]) > MAX_COUNT:
			return false
	var removals: Variant = event.get("removals", [])
	if not removals is Array:
		return false
	var rows: Array[Dictionary] = []
	for item_num: int in additions:
		rows.append({"item_num": item_num, "count": additions[item_num]})
	if not bool(exchange(removals, rows, new_credits).ok):
		return false
	experience += new_experience
	_apply_native_experience(new_experience)
	bonus_stats += new_bonus
	reward_ids[identifier] = true
	return true

func snapshot() -> Dictionary:
	var entries: Array[Dictionary] = []
	var identifiers: Array = quantities.keys()
	identifiers.sort()
	for identifier: int in identifiers:
		var item: Dictionary = catalog.get(identifier, {})
		var slots: Array[String] = []
		var equip_errors: Dictionary = {}
		for slot: String in SLOT_POSITIONS:
			var eligibility := can_equip(identifier, slot)
			if bool(eligibility.ok):
				slots.append(slot)
			elif int(item.get("Position", -1)) == int(SLOT_POSITIONS[slot]):
				equip_errors[slot] = eligibility
		entries.append({"item_num": identifier, "count": int(quantities[identifier]), "name": str(item.get("ItemName", "")),
			"kind": int(item.get("Kind", 0)), "position": int(item.get("Position", -1)), "min_level": int(item.get("ReqMinLevel", 0)),
			"max_level": int(item.get("ReqMaxLevel", 0)), "source": item.get("_source", {}), "equippable_slots": slots, "equip_errors": equip_errors,
			"native_parameters": item.get("native_parameters", []), "required_stats": item.get("ReqGearStat", {}),
			"icon_path": str(_icons.get(identifier, "")), "stats": {"minimum": item.get("AbilityMin", 0), "maximum": item.get("AbilityMax", 0),
				"range": item.get("Range", 0), "price": item.get("Price", 0)}})
	return {"entries": entries, "equipped": equipped.duplicate(), "credits": credits, "experience": experience, "level": level,
		"weight_profile": weight_profile(),
		"allocated_stats": allocated_stats.duplicate(), "base_stats": NativeEquipment.base_stats(gear_id, allocated_stats),
		"grandfathered_equipment": grandfathered_equipment.duplicate(),
		"total_stats": _total_stats_without_slot(""), "stat_increments": NativeEquipment.increments(gear_id), "stat_cap": _stat_cap(),
		"combat_profile": combat_profile(), "armor_appearance": armor_appearance(),
		"gear_id": gear_id, "bonus_stats": bonus_stats, "experience_origin": experience_origin, "effective_experience": effective_experience, "experience_discarded": experience_discarded, "level_progress": _level_progress(), "catalog_count": catalog.size(), "scope": "explicit_local_inventory_native_ITEMs", "level_progression": "native_arrLevelExperienceNew" if not _experience_rows.is_empty() else "native_experience_table_unavailable"}

func export_state() -> Dictionary:
	var rows: Array[Dictionary] = []
	for identifier: Variant in quantities:
		rows.append({"item_num": int(identifier), "count": int(quantities[identifier])})
	return {"schema_version": 1, "items": rows, "equipped": equipped.duplicate(), "credits": credits, "experience": experience,
		"level": level, "starting_level": starting_level, "experience_origin": experience_origin, "effective_experience": effective_experience, "experience_discarded": experience_discarded, "gear_id": gear_id, "bonus_stats": bonus_stats, "reward_ids": reward_ids.keys(), "allocated_stats": allocated_stats.duplicate(), "grandfathered_equipment": grandfathered_equipment.duplicate()}

func import_state(state: Dictionary) -> Dictionary:
	if int(state.get("schema_version", -1)) != 1 or not state.get("items") is Array or not state.get("equipped") is Dictionary or not state.get("reward_ids") is Array:
		return {"ok": false, "error": "inventory_schema"}
	var next_credits := _bounded_integer(state.get("credits", -1))
	var next_xp := _bounded_experience(state.get("experience", -1))
	var next_origin := _bounded_experience(state.get("experience_origin", -1))
	var next_effective: Variant = state.get("effective_experience", -1)
	var next_discarded: Variant = state.get("experience_discarded", -1)
	for value: Variant in [next_effective, next_discarded]:
		if not (value is int or value is float) or not is_finite(float(value)) or float(value) < 0.0 or float(value) > MAX_EXPERIENCE:
			return {"ok": false, "error": "inventory_effective_experience"}
	if absf(float(next_origin + next_xp) - float(next_effective) - float(next_discarded)) > maxf(0.01, absf(float(next_origin + next_xp)) * 0.0000000000000008881784197001252):
		return {"ok": false, "error": "inventory_experience_ledger"}
	var next_starting := _bounded_integer(state.get("starting_level", -1))
	var next_level := _bounded_integer(state.get("level", -1))
	var next_bonus := _bounded_integer(state.get("bonus_stats", 0))
	var next_gear := str(state.get("gear_id", ""))
	if next_credits < 0 or next_xp < 0 or next_origin < 0 or next_starting != starting_level or next_bonus < 0 or next_level < 1 or next_level > _max_level or not GEAR_KINDS.has(next_gear):
		return {"ok": false, "error": "inventory_character"}
	var candidate: RefCounted = get_script().new()
	candidate.catalog = catalog
	candidate._experience_rows = _experience_rows
	candidate._stat_rows = _stat_rows
	candidate._armor_models = _armor_models
	candidate._max_level = _max_level
	candidate.starting_level = next_starting
	candidate.set_starting_level(next_starting)
	if candidate.experience_origin != next_origin:
		return {"ok": false, "error": "inventory_experience_origin"}
	candidate.level = next_level
	candidate.gear_id = next_gear
	var next_allocated: Variant = state.get("allocated_stats", {})
	if not next_allocated is Dictionary or next_allocated.size() > NativeEquipment.STATS.size():
		return {"ok": false, "error": "inventory_allocated_stats"}
	for stat: Variant in next_allocated:
		var count := _bounded_integer(next_allocated[stat])
		if not NativeEquipment.STATS.has(stat) or count <= 0:
			return {"ok": false, "error": "inventory_allocated_stats"}
		var increment := int(NativeEquipment.increments(next_gear)[stat])
		if count * increment >= candidate._stat_cap():
			return {"ok": false, "error": "inventory_allocated_stat_cap"}
		candidate.allocated_stats[stat] = count
	candidate.credits = next_credits
	candidate.experience = next_xp
	candidate.effective_experience = float(next_effective)
	candidate.experience_discarded = float(next_discarded)
	candidate._recompute_level()
	if candidate.level != next_level:
		return {"ok": false, "error": "inventory_level_threshold"}
	for value: Variant in state.items:
		if not value is Dictionary:
			return {"ok": false, "error": "inventory_item"}
		var item_num := _bounded_integer(value.get("item_num", -1))
		var count := _bounded_integer(value.get("count", -1))
		if candidate.quantities.has(item_num) or not candidate.add_item(item_num, count):
			return {"ok": false, "error": "inventory_item"}
	var legacy_equipment: Variant = state.get("grandfathered_equipment", {})
	if not legacy_equipment is Dictionary or legacy_equipment.size() > 3:
		return {"ok": false, "error": "inventory_legacy_equipment"}
	for slot: Variant in legacy_equipment:
		var item_num := _bounded_integer(legacy_equipment[slot])
		if not slot in ["primary", "secondary", "engine"] or item_num <= 0 or _bounded_integer(state.equipped.get(slot, -1)) != item_num:
			return {"ok": false, "error": "inventory_legacy_equipment"}
		candidate.grandfathered_equipment[slot] = item_num
	# CPU first: other equipment may legitimately depend on its native stats.
	var slots: Array = state.equipped.keys()
	if slots.has("cpu"):
		slots.erase("cpu")
		slots.push_front("cpu")
	for slot: String in slots:
		var item_num := _bounded_integer(state.equipped[slot])
		# v0.6 did not enforce ReqGearStat. Keep only its previously equipped
		# primary/secondary/engine until removed; never grant phantom stat points.
		if not state.has("allocated_stats") and slot in ["primary", "secondary", "engine"]:
			var eligibility: Dictionary = candidate.can_equip(item_num, slot)
			if not bool(eligibility.ok) and str(eligibility.get("error", "")) == "native_stat_requirement":
				candidate.grandfathered_equipment[slot] = item_num
		if not bool(candidate.equip_item(item_num, slot).ok):
			return {"ok": false, "error": "inventory_equipment"}
	for value: Variant in state.reward_ids:
		if not value is String or value.is_empty() or value.length() > 200 or candidate.reward_ids.has(value):
			return {"ok": false, "error": "inventory_reward_ledger"}
		candidate.reward_ids[value] = true
	quantities = candidate.quantities
	allocated_stats = candidate.allocated_stats
	grandfathered_equipment = candidate.grandfathered_equipment
	equipped = candidate.equipped
	reward_ids = candidate.reward_ids
	credits = next_credits
	experience = next_xp
	bonus_stats = next_bonus
	level = next_level
	starting_level = next_starting
	experience_origin = next_origin
	effective_experience = float(next_effective)
	experience_discarded = float(next_discarded)
	gear_id = next_gear
	return {"ok": true}

static func _bounded_integer(value: Variant) -> int:
	if not (value is int or value is float) or not is_finite(float(value)) or float(value) != floorf(float(value)) or float(value) < 0.0 or float(value) > MAX_COUNT:
		return -1
	return int(value)


func _load_experience_table() -> void:
	_experience_rows.clear()
	if not FileAccess.file_exists(EXPERIENCE_PATH):
		return
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(EXPERIENCE_PATH))
	if not data is Dictionary:
		return
	var previous := -1
	for value: Variant in data.get("records", []):
		if not value is Dictionary:
			_experience_rows.clear()
			return
		var row_level := int(value.get("Level", -1))
		var threshold := _bounded_experience(value.get("Experience", -1))
		if row_level < 0 or threshold < previous or threshold < 0 or _experience_rows.has(row_level):
			_experience_rows.clear()
			return
		_experience_rows[row_level] = threshold
		previous = threshold
	_max_level = int(data.get("max_level", data.get("runtime_max_level", 125)))
	for row_level in range(_max_level + 1):
		if not _experience_rows.has(row_level):
			_experience_rows.clear()
			return


func set_starting_level(value: int) -> bool:
	if value < 1 or value > _max_level:
		return false
	starting_level = value
	level = value
	experience_origin = int(_experience_rows.get(value - 1, 0))
	effective_experience = float(experience_origin + experience)
	experience_discarded = 0.0
	_recompute_level()
	return true


func _apply_native_experience(amount: int) -> void:
	if _experience_rows.is_empty():
		effective_experience = float(experience_origin + experience)
		return
	# FieldIOCPSocket::ChangeExperience887-947: max one level per award,
	# then cap to99% of the following level. Earned ledger remains auditable.
	if level >= _max_level:
		effective_experience = float(_experience_rows[_max_level - 1])
	else:
		effective_experience += float(amount)
		if effective_experience >= float(_experience_rows[level]):
			level += 1
			var low := float(_experience_rows[level - 1])
			var high := float(_experience_rows[mini(level, _max_level - 1)])
			effective_experience = minf(effective_experience, low + 0.99 * (high - low))
			# BONUS_STAT_PER_A_LEVEL=1 (FieldIOCPSocket.cpp:79), source level gate933.
			if level <= 110 or level in [115, 120, 125]:
				bonus_stats += 1
	experience_discarded = maxf(0.0, float(experience_origin + experience) - effective_experience)


func _recompute_level() -> void:
	if _experience_rows.is_empty():
		return
	var effective := effective_experience
	var computed := starting_level
	while computed < _max_level and effective >= int(_experience_rows[computed]):
		computed += 1
	level = computed


func _level_progress() -> float:
	if _experience_rows.is_empty() or level >= _max_level:
		return 0.0
	var low := int(_experience_rows[level - 1])
	var high := int(_experience_rows[level])
	return clampf((effective_experience - float(low)) / float(maxi(1, high - low)), 0.0, 1.0)


static func _bounded_experience(value: Variant) -> int:
	if not (value is int or value is float) or not is_finite(float(value)) or float(value) != floorf(float(value)) or float(value) < 0.0 or float(value) > MAX_EXPERIENCE:
		return -1
	return int(value)
