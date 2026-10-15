extends RefCounted
## Reviewed current OMI scalar layout; no pointers or unknown parameters executed.
const BINARY_PATH := "res://assets/original_library/catalogs/omi-native.bin"
const BINARY_SHA := "4831431a42bd37ac3ecffc067989330f6304ce214c0a77e8062d28f1fffb5f48"
const STATS := ["attack", "defense", "fuel", "soul", "shield", "dodge"]
const COUNTABLE_KINDS := [18, 19, 20, 21, 23, 24, 27, 28, 33, 34]
const INCREMENTS := {
	"12000100": [3, 3, 3, 3, 3, 3], "12001100": [2, 4, 3, 4, 3, 2],
	"12002100": [4, 3, 3, 3, 4, 1], "12003100": [4, 2, 3, 3, 2, 4]}
const MODIFIER_PARAMETERS := {
	18: "primary_min_attack", 71: "primary_max_attack", 19: "secondary_min_attack", 72: "secondary_max_attack",
	20: "primary_hit", 21: "secondary_hit", 22: "primary_defense", 23: "secondary_defense",
	24: "primary_dodge", 25: "secondary_dodge", 31: "primary_reattack", 32: "secondary_reattack"}
const RESOURCE_PARAMETERS := {13: "max_hp", 89: "max_shield", 14: "max_sp", 15: "max_ep"}

static func enrich_catalog(catalog: Dictionary) -> bool:
	if not FileAccess.file_exists(BINARY_PATH):
		return false
	var data := FileAccess.get_file_as_bytes(BINARY_PATH)
	var hasher := HashingContext.new()
	hasher.start(HashingContext.HASH_SHA256)
	hasher.update(data)
	if hasher.finish().hex_encode() != BINARY_SHA:
		return false
	for identifier: Variant in catalog:
		var row: Dictionary = catalog[identifier]
		var source: Dictionary = row.get("_source", {})
		var offset := int(source.get("offset", -1))
		if source.get("id", "") != "omi" or int(source.get("size", 0)) != 576 or offset < 8 or offset + 576 > data.size() or data.decode_s32(offset) != int(identifier):
			continue
		var required: Dictionary = {}
		var parameters: Array[Dictionary] = []
		for index in range(6):
			required[STATS[index]] = data.decode_u16(offset + 58 + index * 2)
		for index in range(8):
			var dest := data.decode_u16(offset + 120 + index * 2)
			var value := data.decode_float(offset + 136 + index * 4)
			if not is_finite(value):
				return false
			parameters.append({"parameter": dest, "value": value, "index": index})
		row["ReqGearStat"] = required
		row["native_parameters"] = parameters
		row["equipment_layout"] = "pinned_omi_u16x8_120_f32x8_136"
	return true

static func increments(gear_id: String) -> Dictionary:
	var result: Dictionary = {}
	var values: Array = INCREMENTS.get(gear_id, [0, 0, 0, 0, 0, 0])
	for index in range(6):
		result[STATS[index]] = int(values[index])
	return result

static func base_stats(gear_id: String, allocated: Dictionary) -> Dictionary:
	var result := increments(gear_id)
	for stat: String in STATS:
		result[stat] = int(result[stat]) * (1 + int(allocated.get(stat, 0)))
	return result

static func supported_parameters(item: Dictionary, cpu: bool = false) -> Dictionary:
	if not item.get("native_parameters") is Array:
		return {"ok": false, "error": "native_equipment_parameters_unavailable"}
	for row: Dictionary in item.native_parameters:
		var dest := int(row.parameter)
		if dest == 0 or float(row.value) == 0.0:
			continue
		if cpu and dest in [1, 2, 3, 4, 5, 6] and float(row.value) >= 0.0 and float(row.value) == floorf(float(row.value)):
			continue
		if not cpu and (MODIFIER_PARAMETERS.has(dest) or RESOURCE_PARAMETERS.has(dest)):
			continue
		return {"ok": false, "error": "native_equipment_parameter_not_ported", "parameter": dest}
	return {"ok": true}

static func total_stats(gear_id: String, allocated: Dictionary, cpu: Dictionary = {}) -> Dictionary:
	var result := base_stats(gear_id, allocated)
	for row: Dictionary in cpu.get("native_parameters", []):
		var dest := int(row.parameter)
		if dest >= 1 and dest <= 6:
			result[STATS[dest - 1]] += maxi(0, int(row.value))
	return result

static func item_weight(item: Dictionary, current_count: int = 1, des_weight: float = 0.0) -> float:
	# AtumSJ::GetItemWeight331-350, IS_COUNTABLE_ITEM is Kind, not an attribute bit.
	if current_count <= 0 or not is_finite(des_weight) or des_weight < -1.0:
		return 0.0
	var native_weight := maxf(0.0, float(item.get("Weight", 0.0))) * (1.0 + des_weight)
	if COUNTABLE_KINDS.has(int(item.get("Kind", -1))):
		var bundle := int(item.get("MinTradeQuantity", 0))
		return float(current_count) / float(bundle) * native_weight if bundle > 0 else 0.0
	return native_weight
