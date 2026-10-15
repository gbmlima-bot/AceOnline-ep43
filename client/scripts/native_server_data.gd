class_name NativeServerData
extends RefCounted
## Read-only static server tables recovered from the pinned original backup.
## No database connection, account table, executable script or guessed drop rate.
const Equipment = preload("res://scripts/native_equipment.gd")
const ROOT := "res://assets/native_server/"
const SOURCE_SHA := "e5ae92ac1b2e89ee2ef480d85785aa95d3c2588d386092b988efac558b4a4674"
const SOURCE_COMMIT := "7c3e47ac47844e5c415d356a94d6201a0b9a38c4"
const ITEM_COMPATIBILITY := "res://assets/legacy_rules/server_item_compatibility.json"
const COMPATIBILITY_SHA := "774c85fae7a3a8503111a2bd49a4a6fa177913363ce18541023909254fc5e652"
const CURRENT_ITEM_SHA := "7b983721f9da9d19747aa9709f9d9ed8138f97f28159de616595e85ae8c33446"
const NATIVE_ITEM_SHA := "ed70cbe01ef3cdce6cb88479baf3d059f9ea033239d8c68a4adedfa820455a46"
const MONEY_ITEM := 7000022
const MAX_COUNT := 1000000000
const MAX_EXPERIENCE := 9007199254740991
const DROP_COLUMNS := ["MonsterUniqueNumber","ItemNum","MinCount","MaxCount","Probability","PrefixProbability","SuffixProbability","DropType"]
const MONSTER_COLUMNS := ["UniqueNumber","Level","Experience","Belligerence","MPOption"]
const SUPPORTED_ITEM_KINDS := [0,1,2,3,8,9,10,16,17,18,19,23,24,25,26,29,30,31]
const NPC_FLOAT_FIELDS := ["AbilityMin","AbilityMax","HitRate","FractionResistance","RangeAngle"]
const NPC_INTEGER_FIELDS := ["Kind","ReqUnitKind","ReqRace","ReqMinLevel","ReqMaxLevel","Range","ReAttacktime","Charging","Time","RepeatTime","ShotNum","MultiNum","AttackTime","OrbitType","ExplosionRange","ReactionRange","MultiTarget","SkillType","SummonMonster","ItemAttribute"]
const SAFE_ITEM_ATTRIBUTES := 0x00008007 # auto pickup, transfer/quest flags, forbid arena copy
static var _verified_file_cache: Dictionary = {}
static var _native_weapon_index: Dictionary = {}
static var _native_weapon_columns: Dictionary = {}
var _monsters: Dictionary = {}
var _source_monsters: Dictionary = {}
var _current_items: Dictionary = {}
var _drops: Dictionary = {}
var _blocked: Dictionary = {}
var _compatible_items: Dictionary = {}
var _summary: Dictionary = {}
var _ready := false


func load_catalogs(items: Dictionary, client_monsters: Dictionary) -> Dictionary:
	_ready = false
	var loaded := _load_verified_tables(["ti_Monster","ti_MonsterItem"])
	if not bool(loaded.get("ok", false)):return loaded
	var compatibility := _load_item_compatibility()
	if not bool(compatibility.get("ok", false)):return compatibility
	return configure(loaded.tables.ti_Monster, loaded.tables.ti_MonsterItem, items, client_monsters, compatibility.identities)


func load_experience_catalog(client_monsters: Dictionary) -> Dictionary:
	_ready = false
	var loaded := _load_verified_tables(["ti_Monster"])
	if not bool(loaded.get("ok", false)):return loaded
	# Only the XP accessor is needed by authoritative server deployments. No
	# loot table or client artwork is required to validate native Experience.
	var empty_drops := {"schema_version":1,"columns":DROP_COLUMNS,"rows":[]}
	var result := configure(loaded.tables.ti_Monster, empty_drops, {MONEY_ITEM:{}}, client_monsters)
	result["experience_only"] = true
	return result


func load_npc_catalog(items: Dictionary, client_monsters: Dictionary) -> Dictionary:
	_ready = false
	var loaded := _load_verified_tables(["ti_Monster"])
	if not bool(loaded.get("ok",false)):return loaded
	var compatibility := _load_item_compatibility()
	if not bool(compatibility.get("ok",false)):return compatibility
	var empty_drops := {"schema_version":1,"columns":DROP_COLUMNS,"rows":[]}
	return configure(loaded.tables.ti_Monster,empty_drops,items,client_monsters,compatibility.identities)


func monster_experience(monster_code: int) -> int:
	return int(_monsters[monster_code].experience) if _ready and _monsters.has(monster_code) else -1


func npc_attack_profile(monster_code: int) -> Dictionary:
	if not _ready or not _source_monsters.has(monster_code):return {"ok":false,"error":"native_npc_loadout_unavailable"}
	var source: Dictionary = _source_monsters[monster_code]
	for key: String in ["HPActionIdx","ControlSkill"]:
		if not source.has(key) or _integer(source[key],2147483647) != 0:
			return {"ok":false,"error":"native_npc_conditional_skills_not_implemented"}
	# Ordinary attacks occupy01..05.06..15 require native HP-action execution;
	# ControlSkill is the separate16th slot. Never reinterpret a skill as a gun.
	for index: int in range(6,16):
		var field := "MonsterItem%02d" % index
		if not source.has(field) or _integer(source[field],2147483647) != 0:
			return {"ok":false,"error":"native_npc_conditional_skills_not_implemented"}
	var indexed := _load_native_weapon_index()
	if not bool(indexed.get("ok",false)):return indexed
	var options: Array[Dictionary] = []
	for slot: int in range(1,6):
		var field := "MonsterItem%02d" % slot
		var item_num := _integer(source.get(field,-1),2147483647)
		if item_num < 0:return {"ok":false,"error":"invalid_native_npc_weapon_slot"}
		if item_num == 0:continue
		if not _current_items.has(item_num) or not _compatible_items.has(item_num) or not _native_weapon_index.has(item_num):
			return {"ok":false,"error":"native_npc_weapon_identity_incompatible","item_num":item_num}
		var item: Dictionary = _current_items[item_num]
		var row: Array = _native_weapon_index[item_num]
		for key: String in NPC_INTEGER_FIELDS:
			var previous := _integer(row[_native_weapon_columns[key]],2147483647)
			if previous < 0 or previous != _integer(item.get(key,-1),2147483647):
				return {"ok":false,"error":"native_npc_weapon_field_mismatch","item_num":item_num,"field":key}
		for key: String in NPC_FLOAT_FIELDS:
			if not _equal_float32(row[_native_weapon_columns[key]],item.get(key)):
				return {"ok":false,"error":"native_npc_weapon_field_mismatch","item_num":item_num,"field":key}
		var weight := int(item.Charging)
		if weight == 0:continue # Native normal AI never chooses scripted-only guns.
		if int(item.OrbitType) == 101:return {"ok":false,"error":"native_npc_object_beam_not_implemented"}
		if int(item.Kind) not in [100,101,102,150,151,152]:return {"ok":false,"error":"native_npc_weapon_kind_not_implemented","item_num":item_num}
		if weight < 1 or weight > 100:return {"ok":false,"error":"invalid_native_npc_weapon_weight"}
		options.append({"item":item.duplicate(true),"weight":weight,"source_item_num":item_num,"source_slot":slot})
	if not options.is_empty():
		var total := 0
		for option: Dictionary in options:total += int(option.weight)
		if total != 100:return {"ok":false,"error":"native_npc_weapon_weights_not_100"}
		options.sort_custom(func(a: Dictionary,b: Dictionary) -> bool:return int(a.weight) > int(b.weight))
	return {"ok":true,"options":options,"unarmed":options.is_empty(),"source_sha256":SOURCE_SHA,"source_item_sha256":NATIVE_ITEM_SHA,"source_kind":"ti_Monster.MonsterItem01..05;ti_Item;current_OMI_exact_float32_fields"}


static func _load_native_weapon_index() -> Dictionary:
	if not _native_weapon_index.is_empty():return {"ok":true}
	var loaded := _load_verified_tables(["ti_Item"])
	if not bool(loaded.get("ok",false)):return loaded
	var table: Dictionary = loaded.tables.ti_Item
	var required: Array = ["ItemNum"] + NPC_INTEGER_FIELDS + NPC_FLOAT_FIELDS
	var columns := _columns(table,required,100000)
	if columns.is_empty():return {"ok":false,"error":"native_npc_item_schema_unavailable"}
	var index: Dictionary = {}
	for value: Variant in table.rows:
		if not value is Array or value.size() != table.columns.size():return {"ok":false,"error":"native_npc_item_row_invalid"}
		var code := _integer(value[columns.ItemNum],2147483647)
		if code <= 0:continue
		if index.has(code):return {"ok":false,"error":"native_npc_item_identity_duplicate"}
		index[code] = value
	_native_weapon_columns = columns
	_native_weapon_index = index
	return {"ok":true}


static func _equal_float32(left: Variant, right: Variant) -> bool:
	if not (left is int or left is float) or not (right is int or right is float) or not is_finite(float(left)) or not is_finite(float(right)):return false
	var bytes := PackedByteArray()
	bytes.resize(8)
	bytes.encode_float(0,float(left))
	bytes.encode_float(4,float(right))
	return bytes.decode_float(0) == bytes.decode_float(4)


static func _load_verified_tables(names: Array) -> Dictionary:
	var manifest: Dictionary = _read_dictionary(ROOT + "manifest.json")
	var source: Dictionary = manifest.get("source", {})
	if source.get("sha256", "") != SOURCE_SHA or source.get("commit", "") != SOURCE_COMMIT:
		return {"ok":false,"error":"native_database_provenance_unavailable"}
	var tables: Dictionary = {}
	for name: String in names:
		var description: Dictionary = {}
		for value: Variant in manifest.get("exported", []):
			if value is Dictionary and value.get("table", "") == name:description = value
		if description.get("file", "") != name + ".json" or not description.get("sha256", "") is String or str(description.get("sha256", "")).length() != 64:
			return {"ok":false,"error":"native_database_table_not_verified","table":name}
		var path: String = ROOT + name + ".json"
		var digest: String = str(description.sha256)
		if not _verified_file_cache.has(digest):
			if not FileAccess.file_exists(path) or FileAccess.get_sha256(path) != digest:
				return {"ok":false,"error":"native_database_table_hash_mismatch","table":name}
			var data: Dictionary = _read_dictionary(path)
			if data.get("source_sha256", "") != SOURCE_SHA or data.get("table", "") != name:
				return {"ok":false,"error":"native_database_table_provenance_mismatch","table":name}
			_verified_file_cache[digest] = data
		tables[name] = _verified_file_cache[digest]
	return {"ok":true,"tables":tables}


func configure(monster_table: Dictionary, drop_table: Dictionary, items: Dictionary, client_monsters: Dictionary, compatible_items: Dictionary = {}) -> Dictionary:
	# Direct configure is for isolated caller-supplied data/fixtures. Production
	# load_catalogs always supplies the verified cross-version identity filter.
	_ready = false
	_monsters.clear()
	_source_monsters.clear()
	_current_items = items
	_drops.clear()
	_blocked.clear()
	_compatible_items = compatible_items
	_summary = {"source_monsters":0,"matched_monsters":0,"source_drop_rows":0,"supported_drop_rows":0,"blocked_drop_rows":0,"disabled_drop_rows":0,"blocked_reasons":{},"item_identity_filter_enforced":not compatible_items.is_empty()}
	var monster_columns: Dictionary = _columns(monster_table, MONSTER_COLUMNS, 10000)
	var drop_columns: Dictionary = _columns(drop_table, DROP_COLUMNS, 200000)
	if monster_columns.is_empty() or drop_columns.is_empty() or items.is_empty() or client_monsters.is_empty():
		return {"ok":false,"error":"native_database_invalid_static_schema"}
	_summary.source_monsters = monster_table.rows.size()
	for value: Variant in monster_table.rows:
		if not value is Array or value.size() != monster_table.columns.size():
			return {"ok":false,"error":"native_database_invalid_monster_row"}
		var code := _integer(value[monster_columns.UniqueNumber], 2147483647)
		var level := _integer(value[monster_columns.Level], 255)
		var xp := _integer(value[monster_columns.Experience], MAX_EXPERIENCE)
		var bell := _integer(value[monster_columns.Belligerence], 255)
		var options := _integer(value[monster_columns.MPOption], MAX_EXPERIENCE)
		if code <= 0 or level <= 0 or xp < 0 or bell < 0 or options < 0 or _monsters.has(code):
			return {"ok":false,"error":"native_database_invalid_monster_value"}
		if client_monsters.has(code):
			_monsters[code] = {"monster_code":code,"level":level,"experience":xp,"belligerence":bell,"mp_option":options}
			var full: Dictionary = {}
			for name: String in monster_columns:full[name] = value[monster_columns[name]]
			_source_monsters[code] = full
	_summary.matched_monsters = _monsters.size()
	_summary.source_drop_rows = drop_table.rows.size()
	for index: int in range(drop_table.rows.size()):
		var value: Variant = drop_table.rows[index]
		if not value is Array or value.size() != drop_table.columns.size():
			return {"ok":false,"error":"native_database_invalid_drop_row"}
		var row: Dictionary = {}
		for name: String in DROP_COLUMNS:row[name] = _integer(value[drop_columns[name]], 2147483647)
		var code: int = row.MonsterUniqueNumber
		var reason := _drop_block(row, items)
		if not _monsters.has(code):reason = "client_monster_identity_unavailable"
		if not reason.is_empty():
			_block(code, reason)
			continue
		if int(row.Probability) == 0:
			_summary.disabled_drop_rows += 1
			continue
		var item: Dictionary = items[int(row.ItemNum)]
		row["auto_pickup"] = (int(item.ItemAttribute) & 1) != 0
		row["quest_item"] = (int(item.ItemAttribute) & 4) != 0 or int(item.Kind) == 24
		row["source_row"] = index
		if not _drops.has(code):_drops[code] = []
		_drops[code].append(row)
		_summary.supported_drop_rows += 1
	_ready = true
	return diagnostics()


func diagnostics() -> Dictionary:
	var result: Dictionary = _summary.duplicate(true)
	result["ok"] = _ready
	result["source_sha256"] = SOURCE_SHA
	result["source_commit"] = SOURCE_COMMIT
	result["scope"] = "native_database_drop_rules;solo_base_rates;local_automatic_collection;current_client_items;unchanged_client_HP"
	return result


func roll_rewards(monster_code: int, player_level: int, random_integer: Callable) -> Dictionary:
	if not _ready or not _monsters.has(monster_code) or player_level < 1 or player_level > 255 or not random_integer.is_valid():
		return {"ok":false,"error":"native_monster_rewards_unavailable","monster_code":monster_code}
	var monster: Dictionary = _monsters[monster_code]
	if int(monster.belligerence) >= 30:
		return {"ok":false,"error":"native_infinity_context_required","monster_code":monster_code}
	var result: Dictionary = {"ok":true,"monster_code":monster_code,"credits":0,"experience":int(monster.experience),"items":[],"blocked_rows":_blocked.get(monster_code, {}).duplicate(true),"source_sha256":SOURCE_SHA,"source_kind":"monster"}
	# FieldIOCP::CreateDropItems rejects strategy-point and teleport drops.
	if int(monster.belligerence) in [12,13,18,19]:return result
	var additions: Dictionary = {}
	for row: Dictionary in _drops.get(monster_code, []):
		var probability_roll := _roll(random_integer, 0, 999999)
		if probability_roll < 0:return {"ok":false,"error":"invalid_native_drop_random_source"}
		# Original comparator is inclusive, even though RAND1000K ends at999999.
		if int(row.Probability) < probability_roll:continue
		var count := _roll(random_integer, int(row.MinCount), int(row.MaxCount))
		if count < 0:return {"ok":false,"error":"invalid_native_drop_random_source"}
		# Native base monster count ratio is1.0 and clamps successful amounts
		# to at least1 (FieldIOCP.cpp3257; CMonster bonus defaults).
		count = maxi(1,count)
		var money: bool = int(row.ItemNum) == MONEY_ITEM
		var pickup_required: bool = not bool(row.auto_pickup) or (money and not bool(row.quest_item))
		if pickup_required and (int(monster.mp_option) & 0x28) == 0:
			var pickup_roll := _roll(random_integer, 0, 99)
			if pickup_roll < 0:return {"ok":false,"error":"invalid_native_drop_random_source"}
			if pickup_roll > _pickup_threshold(int(monster.level) - player_level, money and bool(row.auto_pickup)):continue
		if money:
			result.credits += count
			if int(result.credits) > MAX_COUNT:return {"ok":false,"error":"native_reward_transaction_limit"}
		else:
			var item: int = row.ItemNum
			additions[item] = int(additions.get(item, 0)) + count
			if int(additions[item]) > MAX_COUNT:return {"ok":false,"error":"native_reward_transaction_limit"}
	for item: int in additions:result.items.append({"item_num":item,"count":int(additions[item])})
	return result


func _drop_block(row: Dictionary, items: Dictionary) -> String:
	for key: String in DROP_COLUMNS:
		if int(row[key]) < 0:return "invalid_native_drop_integer"
	if int(row.MonsterUniqueNumber) <= 0 or int(row.ItemNum) <= 0:return "invalid_native_drop_identity"
	if int(row.DropType) != 0:return "native_infinity_drop_type_not_implemented"
	if int(row.MinCount) > int(row.MaxCount) or int(row.MaxCount) > MAX_COUNT:return "invalid_native_drop_quantity"
	if int(row.PrefixProbability) != 0 or int(row.SuffixProbability) != 0:return "native_rare_instances_not_implemented"
	if not items.has(int(row.ItemNum)):return "current_client_item_unavailable"
	if not _compatible_items.is_empty() and not _compatible_items.has(int(row.ItemNum)):return "legacy_current_item_semantics_differ"
	var item: Dictionary = items[int(row.ItemNum)]
	if _integer(item.get("Kind", -1), 255) not in SUPPORTED_ITEM_KINDS:return "native_item_kind_not_implemented"
	var attributes := _integer(item.get("ItemAttribute", -1), MAX_EXPERIENCE)
	if attributes < 0 or (attributes & ~SAFE_ITEM_ATTRIBUTES) != 0:return "native_item_lifecycle_or_authority_not_implemented"
	if _integer(item.get("Time", -1), 2147483647) != 0:return "native_timed_item_not_implemented"
	if int(item.Kind) in [16,25,26,31] and not bool(Equipment.supported_parameters(item, int(item.Kind) == 26).get("ok", false)):
		return "native_equipment_parameters_not_implemented"
	return ""


func _block(code: int, reason: String) -> void:
	_summary.blocked_drop_rows += 1
	_summary.blocked_reasons[reason] = int(_summary.blocked_reasons.get(reason, 0)) + 1
	if not _blocked.has(code):_blocked[code] = {}
	_blocked[code][reason] = int(_blocked[code].get(reason, 0)) + 1


static func _load_item_compatibility() -> Dictionary:
	if not FileAccess.file_exists(ITEM_COMPATIBILITY) or FileAccess.get_sha256(ITEM_COMPATIBILITY) != COMPATIBILITY_SHA:
		return {"ok":false,"error":"native_item_identity_filter_unavailable"}
	if FileAccess.get_sha256("res://assets/original_library/catalogs/items.json") != CURRENT_ITEM_SHA:
		return {"ok":false,"error":"current_item_catalog_changed_requires_revalidation"}
	var data := _read_dictionary(ITEM_COMPATIBILITY)
	if data.get("native_item_sha256", "") != NATIVE_ITEM_SHA or data.get("current_item_sha256", "") != CURRENT_ITEM_SHA or not data.get("compatible_ids") is Array:
		return {"ok":false,"error":"native_item_identity_provenance_mismatch"}
	var manifest := _read_dictionary(ROOT + "manifest.json")
	var native_verified := false
	for row: Variant in manifest.get("exported", []):
		if row is Dictionary and row.get("table", "") == "ti_Item" and row.get("sha256", "") == NATIVE_ITEM_SHA:native_verified = true
	if not native_verified:return {"ok":false,"error":"native_item_catalog_provenance_unavailable"}
	var identities: Dictionary = {}
	for value: Variant in data.compatible_ids:
		var code := _integer(value, 2147483647)
		if code <= 0 or identities.has(code):return {"ok":false,"error":"invalid_native_item_identity_filter"}
		identities[code] = true
	if identities.is_empty() or identities.size() != int(data.get("compatible_count", -1)):
		return {"ok":false,"error":"invalid_native_item_identity_filter"}
	return {"ok":true,"identities":identities}


static func _pickup_threshold(level_difference: int, money: bool) -> int:
	if level_difference <= -10:return 40 if money else 30
	if level_difference == -9:return 50
	if level_difference == -8:return 60 if money else 70
	if level_difference == -7:return 70 if money else 90
	return 100


static func _columns(table: Dictionary, required: Array, maximum_rows: int) -> Dictionary:
	if int(table.get("schema_version", 0)) != 1 or not table.get("columns") is Array or not table.get("rows") is Array or table.rows.size() > maximum_rows:
		return {}
	var result: Dictionary = {}
	for index: int in range(table.columns.size()):
		var name: Variant = table.columns[index]
		if not name is String or result.has(name):return {}
		result[name] = index
	for name: String in required:
		if not result.has(name):return {}
	return result


static func _roll(source: Callable, minimum: int, maximum: int) -> int:
	var value: Variant = source.call(minimum, maximum)
	var number := _integer(value, maximum)
	return number if number >= minimum else -1


static func _integer(value: Variant, maximum: int) -> int:
	if not (value is int or value is float) or not is_finite(float(value)) or float(value) != floorf(float(value)) or float(value) < 0.0 or float(value) > float(maximum):return -1
	return int(value)


static func _read_dictionary(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:return {}
	if file.get_length() > 16 * 1024 * 1024:return {}
	var value: Variant = JSON.parse_string(file.get_as_text())
	return value if value is Dictionary else {}
