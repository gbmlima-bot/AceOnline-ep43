class_name ServiceModel
extends RefCounted
## Explicit local stock; original prices, bundles, mixing costs and refinery formulas.
## The caller must authorize an appropriate nearby NPC before a mutating action.
const ECONOMY_PATH := "res://assets/local_services/economy.json"
const MAX_COUNT := 1000000000
const PAGE_LIMIT := 8
const GEAR_KINDS := {"12000100":1, "12001100":16, "12002100":256, "12003100":4096}
const REASONS := {
	"not_configured":"Serviços indisponíveis", "unknown_item":"Item original indisponível",
	"not_in_local_stock":"Item fora do estoque local", "native_gear_requirement":"Incompatível com este GEAR",
	"native_level_requirement":"Nível incompatível", "invalid_count":"Quantidade inválida",
	"native_bundle_quantity":"Use um múltiplo do lote original", "native_no_transfer":"Item sem transferência",
	"native_sale_single_unit":"Venda uma unidade deste equipamento por vez", "invalid_price":"Preço indisponível",
	"unknown_recipe":"Receita indisponível", "ingredients_missing":"Faltam ingredientes",
	"insufficient_credits":"SPI insuficiente", "item_not_owned":"Item não possuído",
	"equipped_item":"O último exemplar está equipado", "source_instance_attributes_not_supported":"Transformação de atributos de uma instância ainda indisponível",
	"stateful_target_not_supported":"Resultado com efeitos especiais ainda indisponível", "target_item_unavailable":"Resultado ausente do catálogo",
	"invalid_source_item":"Ingrediente ausente do catálogo", "source_count_mismatch":"Receita inconsistente",
	"source_kind_not_supported":"Tipo de ingrediente ainda indisponível", "timed_target_not_supported":"Item temporário ainda indisponível",
	"unknown_current_recipe_extension":"Extensão da receita desconhecida", "invalid_native_bounds":"Dados da receita inválidos",
	"already_full":"Recurso já completo", "invalid_resource":"Recurso inválido", "native_ammunition_unavailable":"Munição original por calibre indisponível",
	"invalid_service_state":"Estado do recurso inválido", "native_equipped_weapon_required":"Selecione a arma equipada neste slot",
	"insufficient_items":"Faltam ingredientes", "item_is_equipped":"O último exemplar está equipado", "item_count_overflow":"Limite do inventário", "inventory_overflow":"Limite do inventário", "credit_overflow":"Limite de SPI"
}
var inventory: RefCounted
var _data: Dictionary = {}
var _stock: Dictionary = {}
var _recipes: Dictionary = {}
var _recipe_ids: Array[String] = []
var _countable: Array = []
var _ammo: Dictionary = {}
var _cache: Dictionary = {}
var _revision := 0
var _operation_serial := 0
var _rng := RandomNumberGenerator.new()

func configure(character_inventory: RefCounted, economy: Dictionary = {}) -> bool:
	inventory = character_inventory
	_data = economy
	if _data.is_empty() and FileAccess.file_exists(ECONOMY_PATH):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(ECONOMY_PATH))
		if parsed is Dictionary:
			_data = parsed
	_stock.clear(); _recipes.clear(); _recipe_ids.clear(); _ammo.clear(); _cache.clear()
	if inventory == null or not inventory.has_method("exchange") or int(_data.get("schema_version", 0)) != 1:
		return false
	for number: Variant in _data.get("stock_item_nums", []):
		if inventory.catalog.has(int(number)):
			_stock[int(number)] = true
	for value: Variant in _data.get("recipes", []):
		if value is Dictionary and not str(value.get("recipe_id", "")).is_empty():
			var identifier := str(value.recipe_id)
			_recipes[identifier] = value
			_recipe_ids.append(identifier)
	_countable = _data.get("native_countable_kinds", [])
	for item: Dictionary in inventory.catalog.values():
		if int(item.get("Kind", -1)) == 23 and int(item.get("Caliber", 0)) > 0 and int(item.get("Caliber", 0)) != 255 and int(item.get("Price", 0)) > 0 and int(item.get("MinTradeQuantity", 0)) > 0:
			_ammo[int(item.Caliber)] = item
	_rng.randomize()
	return true

func shop_catalog(query: String = "", offset: int = 0, limit: int = PAGE_LIMIT, compatible_only: bool = true, mode: String = "buy") -> Dictionary:
	if inventory == null:
		return {"rows":[], "total":0, "offset":0, "limit":PAGE_LIMIT}
	var cache_key := "shop|%s|%s|%s|%s" % [query.to_lower(), compatible_only, mode, _inventory_key()]
	if not _cache.has(cache_key):
		var ids: Array[int] = []
		var candidates: Array = inventory.quantities.keys() if mode == "sell" else _stock.keys()
		candidates.sort()
		for number: int in candidates:
			var item: Dictionary = inventory.catalog.get(number, {})
			if item.is_empty() or not _matches(item, query) or (compatible_only and not _compatible(item).is_empty()):
				continue
			if mode == "sell" and (int(item.get("Price", 0)) <= 0 or (int(item.get("ItemAttribute", 0)) & 2) != 0):
				continue
			ids.append(number)
		_store_cache(cache_key, ids)
	var filtered: Array = _cache[cache_key]
	var start := clampi(offset, 0, filtered.size())
	var size := clampi(limit, 1, PAGE_LIMIT)
	var rows: Array[Dictionary] = []
	for index in range(start, mini(start + size, filtered.size())):
		var number := int(filtered[index])
		var row := _shop_row(number)
		var reason := _trade_error(number, int(row.bundle_size) if mode != "sell" or _countable.has(int(row.kind)) else 1, mode)
		row.available = reason.is_empty()
		row.reason = _reason(reason)
		row.reason_code = reason
		rows.append(row)
	return {"rows":rows, "total":filtered.size(), "offset":start, "limit":size, "mode":mode,
		"scope":"Estoque local ilimitado; preços e lotes ITEM originais; imposto local zero"}

func recipe_catalog(query: String = "", offset: int = 0, limit: int = PAGE_LIMIT, craftable_only: bool = false, compatible_only: bool = true) -> Dictionary:
	if inventory == null:
		return {"rows":[], "total":0, "offset":0, "limit":PAGE_LIMIT}
	var cache_key := "recipes|%s|%s|%s|%s" % [query.to_lower(), craftable_only, compatible_only, _inventory_key()]
	if not _cache.has(cache_key):
		var ids: Array[String] = []
		for identifier: String in _recipe_ids:
			var recipe: Dictionary = _recipes[identifier]
			var item: Dictionary = inventory.catalog.get(int(recipe.item_num), {})
			if not _matches(item, query, identifier) or (compatible_only and not _compatible(item).is_empty()):
				continue
			if craftable_only and not _craft_error(recipe).is_empty():
				continue
			ids.append(identifier)
		_store_cache(cache_key, ids)
	var filtered: Array = _cache[cache_key]
	var start := clampi(offset, 0, filtered.size())
	var size := clampi(limit, 1, PAGE_LIMIT)
	var rows: Array[Dictionary] = []
	for index in range(start, mini(start + size, filtered.size())):
		rows.append(_recipe_row(_recipes[filtered[index]]))
	return {"rows":rows, "total":filtered.size(), "offset":start, "limit":size,
		"scope":"Receitas originais; transformações de instância e dados ausentes ficam bloqueados"}

func buy(item_num: int, count: int = 1) -> Dictionary:
	var error := _trade_error(item_num, count, "buy")
	if not error.is_empty():
		return _fail(error)
	var item: Dictionary = inventory.catalog[item_num]
	var price := int(item.Price) * (count / int(item.MinTradeQuantity))
	var result: Dictionary = inventory.exchange([], [{"item_num":item_num, "count":count}], -price)
	if bool(result.get("ok", false)):
		_changed()
		return {"ok":true, "cost":price, "item_num":item_num, "count":count, "scope":"local_stock_native_ITEM_price"}
	return _transaction_result(result)

func sell(item_num: int, count: int = 1) -> Dictionary:
	var error := _trade_error(item_num, count, "sell")
	if not error.is_empty():
		return _fail(error)
	var item: Dictionary = inventory.catalog[item_num]
	var bundles := count / int(item.MinTradeQuantity) if _countable.has(int(item.Kind)) else 1
	var price := _native_sell_price(int(item.Price)) * bundles
	var result: Dictionary = inventory.exchange([{"item_num":item_num, "count":count}], [], price)
	if bool(result.get("ok", false)):
		_changed()
		return {"ok":true, "income":price, "item_num":item_num, "count":count, "scope":"native_20_percent_resale"}
	return _transaction_result(result)

func craft(recipe_id: String) -> Dictionary:
	if _operation_serial >= MAX_COUNT:
		return _fail("invalid_service_state")
	if not _recipes.has(recipe_id):
		return _fail("unknown_recipe")
	var recipe: Dictionary = _recipes[recipe_id]
	var error := _craft_error(recipe)
	if not error.is_empty():
		return _fail(error)
	var old_rng_state := _rng.state
	# EP3.5 server uses GetRandInt32(0,9999) <= MixingProbability, including its boundary.
	var draw := _rng.randi_range(0, 9999)
	var success := draw <= int(recipe.probability_10k)
	var additions: Array = [{"item_num":int(recipe.item_num), "count":1}] if success else []
	var result: Dictionary = inventory.exchange(recipe.ingredients, additions, -int(recipe.cost))
	if not bool(result.get("ok", false)):
		_rng.state = old_rng_state
		return _transaction_result(result)
	_changed()
	_operation_serial += 1
	return {"ok":true, "success":success, "cost":int(recipe.cost), "recipe_id":recipe_id,
		"item_num":int(recipe.item_num), "count":1 if success else 0, "roll":draw,
		"event":{"type":"crafted", "item_num":int(recipe.item_num), "count":1, "recipe_id":recipe_id,
			"event_id":"local-craft:%s" % _operation_serial} if success else {}}

func quote_service(kind: String, current: float, maximum: float, weapon_item_num: int = 0, count: int = MAX_COUNT) -> Dictionary:
	if inventory == null:
		return _fail("not_configured")
	if not is_finite(current) or not is_finite(maximum) or current < 0.0 or maximum <= 0.0 or current > maximum or maximum > MAX_COUNT or count <= 0 or count > MAX_COUNT:
		return _fail("invalid_service_state")
	var missing := maxi(0, int(maximum) - int(current))
	var amount := mini(missing, count)
	if amount <= 0:
		return _fail("already_full")
	var cost := 0
	var bundle := 1
	var billed_amount := amount
	var bullet_item := 0
	if kind in ["hp", "dp", "ep", "sp"]:
		cost = amount * int(_data.get("repair_cost_per_point", {}).get(kind, 0))
	elif kind in ["primary_ammo", "secondary_ammo"]:
		var slot := "primary" if kind == "primary_ammo" else "secondary"
		if int(inventory.equipped.get(slot, 0)) != weapon_item_num:
			return _fail("native_equipped_weapon_required")
		var weapon: Dictionary = inventory.catalog.get(weapon_item_num, {})
		var ammo: Dictionary = _ammo.get(int(weapon.get("Caliber", 0)), {})
		if weapon.is_empty() or ammo.is_empty():
			return _fail("native_ammunition_unavailable")
		bundle = int(ammo.MinTradeQuantity)
		var bundles := (amount + bundle - 1) / bundle
		cost = bundles * int(ammo.Price)
		billed_amount = bundles * bundle
		bullet_item = int(ammo.ItemNum)
	else:
		return _fail("invalid_resource")
	if cost <= 0 or cost > MAX_COUNT:
		return _fail("invalid_price")
	return {"ok":true, "resource":kind, "amount":amount, "billed_amount":billed_amount, "cost":cost,
		"bundle_size":bundle, "bullet_item_num":bullet_item, "affordable":inventory.credits >= cost,
		"effect":{"resource":kind, "amount":amount}, "scope":"native_refinery_formula_local_zero_tax"}

func service(kind: String, current: float, maximum: float, weapon_item_num: int = 0, count: int = MAX_COUNT) -> Dictionary:
	var quote := quote_service(kind, current, maximum, weapon_item_num, count)
	if not bool(quote.get("ok", false)):
		return quote
	var result: Dictionary = inventory.exchange([], [], -int(quote.cost))
	if not bool(result.get("ok", false)):
		return _transaction_result(result)
	_changed()
	return quote

func snapshot() -> Dictionary:
	return {"configured":inventory != null and not _data.is_empty(), "stock_count":_stock.size(), "recipe_count":_recipes.size(),
		"supported_recipes":int(_data.get("summary", {}).get("supported", 0)), "blocked_recipes":int(_data.get("summary", {}).get("blocked", 0)),
		"credits":int(inventory.credits) if inventory != null else 0, "revision":_revision, "operations":_operation_serial,
		"scope":"local_NPC_services_native_ITEM_mixing_refinery_formulas", "policy":_data.get("policy", {})}

func export_state() -> Dictionary:
	# decimal string preserves all64 RNG bits through JSON's double precision.
	return {"schema_version":1, "rng_state":str(_rng.state), "operations":_operation_serial}

func import_state(state: Dictionary) -> Dictionary:
	var serial: Variant = state.get("operations", -1)
	var encoded: Variant = state.get("rng_state", null)
	if int(state.get("schema_version", -1)) != 1 or not _valid_rng_state(encoded) or not (serial is int or serial is float) or not is_finite(float(serial)) or float(serial) != floorf(float(serial)) or float(serial) < 0 or float(serial) > MAX_COUNT:
		return _fail("invalid_service_state")
	_rng.state = int(encoded)
	_operation_serial = int(serial)
	_changed()
	return {"ok":true}

func _trade_error(item_num: int, count: int, mode: String) -> String:
	if inventory == null:
		return "not_configured"
	var item: Dictionary = inventory.catalog.get(item_num, {})
	if item.is_empty():
		return "unknown_item"
	if count <= 0 or count > MAX_COUNT:
		return "invalid_count"
	if (int(item.get("ItemAttribute", 0)) & (2 | (16 if mode == "buy" else 0))) != 0:
		return "native_no_transfer"
	if int(item.get("Price", 0)) <= 0 or int(item.get("MinTradeQuantity", 0)) <= 0:
		return "invalid_price"
	if mode == "buy":
		if not _stock.has(item_num):
			return "not_in_local_stock"
		var compatible := _compatible(item)
		if not compatible.is_empty():
			return compatible
		if count % int(item.MinTradeQuantity) != 0:
			return "native_bundle_quantity"
		var cost := int(item.Price) * (count / int(item.MinTradeQuantity))
		if cost > MAX_COUNT or inventory.credits < cost:
			return "insufficient_credits"
	else:
		if int(inventory.quantities.get(item_num, 0)) < count:
			return "item_not_owned"
		if not _countable.has(int(item.Kind)) and count != 1:
			return "native_sale_single_unit"
		# Local UI requires whole bundles; avoids native partial-bundle zero-payout sales.
		if _countable.has(int(item.Kind)) and count % int(item.MinTradeQuantity) != 0:
			return "native_bundle_quantity"
		if inventory.equipped.values().has(item_num) and int(inventory.quantities.get(item_num, 0)) - count <= 0:
			return "equipped_item"
	return ""

func _craft_error(recipe: Dictionary) -> String:
	if inventory == null:
		return "not_configured"
	if not bool(recipe.get("supported", false)):
		return str(recipe.get("reason", "invalid_native_bounds"))
	var compatible := _compatible(inventory.catalog.get(int(recipe.get("item_num", 0)), {}))
	if not compatible.is_empty():
		return compatible
	if int(inventory.credits) < int(recipe.get("cost", 0)):
		return "insufficient_credits"
	for part: Dictionary in recipe.get("ingredients", []):
		if int(inventory.quantities.get(int(part.item_num), 0)) < int(part.count):
			return "ingredients_missing"
		if inventory.equipped.values().has(int(part.item_num)) and int(inventory.quantities.get(int(part.item_num), 0)) <= int(part.count):
			return "equipped_item"
	if int(inventory.quantities.get(int(recipe.item_num), 0)) >= MAX_COUNT:
		return "inventory_overflow"
	return ""

func _compatible(item: Dictionary) -> String:
	if item.is_empty():
		return "unknown_item"
	var mask := int(item.get("ReqUnitKind", 0))
	if mask != 0 and (mask & int(GEAR_KINDS.get(str(inventory.gear_id), 0))) == 0:
		return "native_gear_requirement"
	if int(item.get("ReqMinLevel", 0)) > int(inventory.level) or (int(item.get("ReqMaxLevel", 0)) > 0 and int(item.ReqMaxLevel) < int(inventory.level)):
		return "native_level_requirement"
	return ""

func _shop_row(number: int) -> Dictionary:
	var item: Dictionary = inventory.catalog[number]
	return {"item_num":number, "name":str(item.get("ItemName", "")), "count":int(inventory.quantities.get(number, 0)),
		"buy_price":int(item.get("Price", 0)), "sell_price":_native_sell_price(int(item.get("Price", 0))),
		"bundle_size":int(item.get("MinTradeQuantity", 1)), "min_level":int(item.get("ReqMinLevel", 0)), "kind":int(item.get("Kind", 0)),
		"compatible":_compatible(item).is_empty(), "icon_path":str(inventory._icons.get(number, ""))}

func _recipe_row(recipe: Dictionary) -> Dictionary:
	var row: Dictionary = recipe.duplicate(true)
	var item: Dictionary = inventory.catalog.get(int(recipe.item_num), {})
	row.name = str(item.get("ItemName", "Item original #%s" % recipe.item_num))
	row.icon_path = str(inventory._icons.get(int(recipe.item_num), ""))
	row.compatible = _compatible(item).is_empty()
	row.reason_code = _craft_error(recipe)
	row.reason = _reason(row.reason_code)
	row.available = str(row.reason_code).is_empty()
	for part: Dictionary in row.ingredients:
		part.name = str(inventory.catalog.get(int(part.item_num), {}).get("ItemName", "#%s" % part.item_num))
		part.owned = int(inventory.quantities.get(int(part.item_num), 0))
	return row

func _matches(item: Dictionary, query: String, extra: String = "") -> bool:
	return query.is_empty() or ("%s %s %s" % [item.get("ItemNum", ""), item.get("ItemName", ""), extra]).to_lower().contains(query.to_lower())

func _inventory_key() -> String:
	var ids: Array = inventory.quantities.keys()
	ids.sort()
	var parts := PackedStringArray([str(inventory.level), str(inventory.gear_id), str(inventory.credits), str(_revision)])
	for identifier: Variant in ids:
		parts.append("%s:%s" % [identifier, inventory.quantities[identifier]])
	for slot: Variant in inventory.equipped:
		parts.append("%s=%s" % [slot, inventory.equipped[slot]])
	return "|".join(parts)

func _store_cache(key: String, value: Array) -> void:
	if _cache.size() >= 12:
		_cache.clear()
	_cache[key] = value

func _changed() -> void:
	_revision += 1
	_cache.clear()

func _reason(code: String) -> String:
	return str(REASONS.get(code, code.replace("_", " ")))

func _fail(error: String) -> Dictionary:
	return {"ok":false, "error":error, "reason":_reason(error)}

func _transaction_result(result: Dictionary) -> Dictionary:
	return _fail(str(result.get("error", "invalid_service_state")))

static func _valid_rng_state(value: Variant) -> bool:
	if not value is String or value.is_empty() or not value.is_valid_int():
		return false
	var digits: String = value.substr(1) if value.begins_with("-") else value
	if digits.is_empty() or (digits.length() > 1 and digits.begins_with("0")) or value == "-0" or value.begins_with("+"):
		return false
	var bound := "9223372036854775808" if value.begins_with("-") else "9223372036854775807"
	return digits.length() < bound.length() or (digits.length() == bound.length() and digits <= bound)

static func _native_sell_price(price: int) -> int:
	# C++ ITEM.Price conversion and GetItemSellingPriceRate() multiply are float32.
	# Seven current ITEM records differ by1SPI from rational Price/5.
	var source := PackedFloat32Array([float(price), 0.2])
	var rounded := PackedFloat32Array([float(source[0]) * float(source[1])])
	return int(rounded[0])
