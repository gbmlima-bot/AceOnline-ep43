class_name ItemUseModel
extends RefCounted
## Instant ENERGY kits: FieldIOCPSocket.cpp:22945..23684, EP35.
## Effects come from every descriptor in the pinned current OMI, not item names.
## Only self-use is ported; unknown/newer parameters block the whole item.

const HEALS := {59: "hp", 83: "shield", 60: "sp", 61: "ep"}
const RESOURCE_KEYS := ["hp", "shield", "sp", "ep"]
const MAX_COOLDOWN := 4294967.295 # Native unsigned ReAttacktime milliseconds.
const ARENA_ITEM := 0x00000100
const CANNOT_INFINITY := 0x00400000
const ONLY_INFINITY := 0x00800000
var _cooldowns: Dictionary = {}


func supported_effects(item: Dictionary) -> Dictionary:
	# CINFInven::SendUseItem selects ENERGY only from invalid equipment position.
	# Native ITEM has no UsingType scalar: Kind/Position select the use path.
	if int(item.get("Kind", -1)) != 18 or int(item.get("Position", -1)) != 99:
		return _failure("unsupported_item_use", "Este tipo de item ainda não tem uso implementado.")
	if str(item.get("equipment_layout", "")) != "pinned_omi_u16x8_120_f32x8_136" or not item.get("native_parameters") is Array or item.native_parameters.size() != 8:
		return _failure("native_item_parameters_unavailable", "Parâmetros originais do item indisponíveis.")
	var effects: Array[Dictionary] = []
	var destinations: Array[int] = []
	for index in range(8):
		var parameter: Variant = item.native_parameters[index]
		if not parameter is Dictionary or int(parameter.get("index", -1)) != index:
			return _failure("native_item_parameters_unavailable", "Sequência dos parâmetros originais inválida.")
		var destination := int(parameter.get("parameter", -1))
		var value := float(parameter.get("value", NAN))
		if not is_finite(value):
			return _failure("invalid_native_item_effect", "Valor original do efeito inválido.")
		if destination == 0 and value == 0.0:
			continue
		# The original instant path reads slot0, and only a HP/DP pair in slot1.
		# In particular 23900/23901/23902 and 436/437 are newer, unrecovered effects.
		if not HEALS.has(destination) or value <= 0.0 or index > 1 or destinations.has(destination):
			return _failure("native_item_effect_not_ported", "Efeito original %d ainda não implementado; item preservado." % destination)
		if index == 1 and (destinations.size() != 1 or not ((destinations[0] == 59 and destination == 83) or (destinations[0] == 83 and destination == 59))):
			return _failure("native_item_effect_not_ported", "Esta combinação de efeitos ainda não foi portada.")
		destinations.append(destination)
		effects.append({"resource": HEALS[destination], "amount": value})
	if effects.is_empty() or int(item.native_parameters[0].parameter) not in HEALS:
		return _failure("native_item_effect_not_ported", "Este item não contém um efeito de recuperação implementado.")
	var milliseconds := float(item.get("ReAttacktime", -1))
	if not is_finite(milliseconds) or milliseconds <= 0.0 or milliseconds != floorf(milliseconds) or milliseconds > MAX_COOLDOWN * 1000.0:
		return _failure("invalid_native_item_cooldown", "Intervalo original do item inválido.")
	return {"ok": true, "effects": effects, "cooldown": milliseconds / 1000.0,
		"primary_resource": str(effects[0].resource)}


func can_use(inventory: RefCounted, item_num: int, resources: Dictionary, context: Dictionary = {}) -> Dictionary:
	var item: Dictionary = inventory.catalog.get(item_num, {})
	if item.is_empty():
		return _failure("unknown_native_item", "Item original desconhecido.")
	if int(inventory.quantities.get(item_num, 0)) <= 0:
		return _failure("item_not_owned", "Este item não está no inventário do piloto.")
	if inventory.equipped.values().has(item_num):
		return _failure("item_is_equipped", "Remova o item do equipamento antes de usá-lo.")
	var plan := supported_effects(item)
	if not bool(plan.ok):
		return plan
	if bool(resources.get("dead", false)) or not _valid_resource(resources, "hp") or float(resources.hp) <= 0.0:
		return _failure("pilot_dead", "Não é possível usar o item com a nave destruída.")
	if bool(context.get("bazaar_active", false)):
		return _failure("bazaar_active", "Encerre a loja pessoal para usar o item.")
	if bool(context.get("trading", false)) or context.get("trading_items", []).has(item_num):
		return _failure("item_is_trading", "O item está em uma negociação.")
	if bool(context.get("item_parameter_overlap", false)):
		return _failure("native_item_parameter_overlap", "Um efeito de item incompatível já está ativo.")
	var required_gear := int(item.get("ReqUnitKind", 0))
	if (required_gear & int(inventory.GEAR_KINDS.get(inventory.gear_id, 0))) == 0:
		return _failure("native_gear_requirement", "O item exige outra classe GEAR.")
	if int(item.get("ReqMinLevel", 0)) > inventory.level or (int(item.get("ReqMaxLevel", 0)) > 0 and inventory.level > int(item.ReqMaxLevel)):
		return _failure("native_level_requirement", "O nível do piloto não atende aos requisitos do item.")
	var attributes := int(item.get("ItemAttribute", 0))
	var infinity_server := bool(context.get("infinity_server", false))
	if ((attributes & CANNOT_INFINITY) != 0 and infinity_server) or ((attributes & ONLY_INFINITY) != 0 and not infinity_server):
		return _failure("native_infinity_requirement", "O item não pode ser usado neste modo de servidor.")
	if bool(context.get("arena_map", false)) and (attributes & ARENA_ITEM) == 0:
		return _failure("native_arena_requirement", "Esta arena exige kits próprios.")
	var primary_resource := str(plan.primary_resource)
	# Native HP/DP pair checks the freeze debuff of slot0; shield paralysis skips
	# its DP portion, permitting an HP recovery without a false shield refill.
	if primary_resource in ["hp", "shield", "sp"] and bool(context.get("freeze_" + primary_resource, false)):
		return _failure("native_recovery_frozen", "A recuperação deste recurso está bloqueada.")
	var changes: Dictionary = {}
	var applied: Dictionary = {}
	for effect: Dictionary in plan.effects:
		var key := str(effect.resource)
		if key == "shield" and bool(context.get("shield_paralyzed", false)):
			continue
		if not _valid_resource(resources, key):
			return _failure("invalid_resource_state", "Estado do recurso %s inválido." % key)
		if cooldown_for(key) > 0.0:
			return _failure("native_item_cooldown", "A recuperação de %s ainda está em recarga." % key, {"resource": key, "remaining": cooldown_for(key)})
		if key == "ep" and float(resources.ep) <= 0.0:
			return _failure("native_empty_ep", "O kit original exige combustível restante; use o abastecimento na base.")
		var current := float(resources[key])
		var next := minf(float(resources["max_" + key]), current + float(effect.amount))
		if next > current:
			changes[key] = next
			applied[key] = next - current
	if changes.is_empty():
		return _failure("resource_already_full", "Os recursos recuperáveis pelo item já estão completos ou bloqueados.")
	return {"ok": true, "item_num": item_num, "changes": changes, "applied": applied, "cooldown": float(plan.cooldown)}


func use_item(inventory: RefCounted, item_num: int, resources: Dictionary, context: Dictionary = {}) -> Dictionary:
	var plan := can_use(inventory, item_num, resources, context)
	if not bool(plan.ok):
		return plan
	# No yield/callback between the removal and resource writes. Failure leaves
	# resources and recasts untouched; InventoryModel owns its atomic stack debit.
	var removed: Dictionary = inventory.remove_item(item_num, 1)
	if not bool(removed.get("ok", false)):
		return removed
	for key: String in plan.changes:
		resources[key] = float(plan.changes[key])
		_cooldowns[key] = float(plan.cooldown)
	var result := {"ok": true, "item_num": item_num, "consumed": 1, "applied": plan.applied,
		"message": "Kit utilizado; uma unidade consumida.", "cooldowns": _cooldowns.duplicate()}
	if plan.changes.has("ep"):
		result["ep_current"] = float(resources.ep)
		result["ep_max"] = float(resources.max_ep)
	return result


func advance(delta: float) -> void:
	if not is_finite(delta) or delta <= 0.0:
		return
	for key: String in _cooldowns.keys():
		var remaining := maxf(0.0, float(_cooldowns[key]) - delta)
		if remaining <= 0.0:
			_cooldowns.erase(key)
		else:
			_cooldowns[key] = remaining


func cooldown_for(resource: String) -> float:
	return float(_cooldowns.get(resource, 0.0))


func export_state() -> Dictionary:
	return {"schema_version": 1, "cooldowns": _cooldowns.duplicate()}


func import_state(state: Dictionary) -> bool:
	# Missing state in a 0.8 save means no item-use system existed yet.
	if state.is_empty():
		_cooldowns.clear()
		return true
	if state.size() != 2 or state.get("schema_version", null) != 1 or not state.get("cooldowns") is Dictionary:
		return false
	var candidate: Dictionary = {}
	for key: Variant in state.cooldowns:
		var value: Variant = state.cooldowns[key]
		if not key is String or key not in RESOURCE_KEYS or not (value is int or value is float) or not is_finite(float(value)) or float(value) <= 0.0 or float(value) > MAX_COOLDOWN:
			return false
		candidate[key] = float(value)
	_cooldowns = candidate
	return true


static func _valid_resource(resources: Dictionary, key: String) -> bool:
	var current: Variant = resources.get(key)
	var maximum: Variant = resources.get("max_" + key)
	return (current is float or current is int) and (maximum is float or maximum is int) and is_finite(float(current)) and is_finite(float(maximum)) and float(maximum) > 0.0 and float(current) >= 0.0 and float(current) <= float(maximum)


static func _failure(error: String, message: String, extra: Dictionary = {}) -> Dictionary:
	var result := {"ok": false, "error": error, "message": message}
	result.merge(extra)
	return result
