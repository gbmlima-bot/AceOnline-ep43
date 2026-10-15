extends SceneTree
const Inventory = preload("res://scripts/inventory_model.gd")
const Services = preload("res://scripts/service_model.gd")
var checks := 0
var failures: Array[String] = []
func _initialize() -> void:
	call_deferred("_run")
func _check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures.append(message)
func _run() -> void:
	var inventory := Inventory.new()
	_check(inventory.configure(), "native catalog configure")
	inventory.credits = 1000000
	var services := Services.new()
	_check(services.configure(inventory), "service catalog configure")
	var info: Dictionary = services.snapshot()
	_check(int(info.stock_count) == int(services._data.summary.stock) and int(info.recipe_count) == 39230 and int(info.supported_recipes) == 304, "frozen native/local coverage")
	if bool(info.native_shop_mode):
		_check(int(info.native_shop_count) > 0 and services.shop_catalog().total == 0, "recovered shops require a contact")
		var first: Dictionary = services._native_shops.values()[0]
		var native_map := int(first.map_id) if int(first.map_id) != 0 else 2001
		_check(bool(services.bind_shop_contact({"source_building_index":first.building_index,"building_kind":first.building_kind,"source_npc_index":first.npc_index,"map_id":native_map},native_map).ok), "real recovered shop binds")
		_check(services.shop_catalog("",0,8,false).total == first.entries.size(), "real recovered shop does not expose union of other shops")
		# Price/refinery/crafting regressions below use an explicit local-stock
		# fixture, independently of which legacy items pass version matching.
		var local_fixture: Dictionary = services._data.duplicate(true)
		local_fixture.erase("native_shops")
		for number: int in [7000060,7000020,7000500,7004000]:
			if not local_fixture.stock_item_nums.has(number): local_fixture.stock_item_nums.append(number)
		_check(services.configure(inventory,local_fixture), "local transaction fixture setup")
	var shop: Dictionary = services.shop_catalog("", 0, 100, false)
	_check(shop.rows.size() == 8 and shop.total > 0, "shop page cap")
	var next: Dictionary = services.shop_catalog("", 8, 8, false)
	_check(shop.rows[0].item_num != next.rows[0].item_num, "shop pagination")
	_check(services.recipe_catalog("", 0, 999, false, false).rows.size() == 8, "recipe page cap")
	var buy_id := 7000060
	var native_item: Dictionary = inventory.catalog[buy_id]
	_check(Services._native_sell_price(77899900) == 15579981, "native float32 resale rounding")
	var before := inventory.export_state()
	var result: Dictionary = services.buy(buy_id)
	_check(bool(result.ok) and int(result.cost) == int(native_item.Price), "native ITEM buy price")
	_check(inventory.credits == int(before.credits) - int(native_item.Price) and inventory.quantities[buy_id] == 1, "buy one atomic debit/credit")
	result = services.sell(buy_id)
	_check(bool(result.ok) and int(result.income) == int(native_item.Price) / 5, "native20percent sell price")
	_check(int(inventory.quantities.get(buy_id, 0)) == 0 and inventory.credits == int(before.credits) - int(native_item.Price) + int(native_item.Price) / 5, "sale item removed once")
	before = inventory.export_state()
	_check(not bool(services.buy(buy_id, -1).ok), "negative purchase rejected")
	_check(not bool(services.buy(1234).ok), "invented item rejected")
	_check(not bool(services.sell(buy_id).ok), "unowned sale rejected")
	_check(inventory.export_state() == before, "invalid trades no mutation")
	inventory.credits = 0
	before = inventory.export_state()
	_check(not bool(services.buy(buy_id).ok) and inventory.export_state() == before, "insufficient money atomic")
	inventory.credits = 1000000
	inventory.add_item(buy_id)
	_check(bool(inventory.equip_item(buy_id, "primary").ok), "native test weapon equip")
	before = inventory.export_state()
	_check(not bool(services.sell(buy_id).ok) and inventory.export_state() == before, "equipped final unit protected")
	var high: int = 7000020
	_check(not bool(services.buy(high).ok), "native level checked")
	var a_only: int = 7000500
	_check(not bool(services.buy(a_only).ok), "native GEAR checked")
	var ammo := 7004000
	var price := inventory.credits
	_check(not bool(services.buy(ammo, 1).ok), "native minimum bundle")
	_check(bool(services.buy(ammo, 100).ok) and inventory.credits == price - 7 and inventory.quantities[ammo] == 100, "native bullet packet buy")
	inventory.add_item(7000040)
	inventory.equip_item(7000040, "primary")
	var quote: Dictionary = services.quote_service("hp", 90.0, 100.0)
	_check(bool(quote.ok) and quote.amount == 10 and quote.cost == 50, "native HP5SPI")
	_check(services.quote_service("dp", 90.0, 100.0).cost == 30, "native DP3SPI")
	_check(services.quote_service("ep", 90.0, 100.0).cost == 10, "native EP1SPI")
	_check(services.quote_service("sp", 90.0, 100.0).cost == 2000, "native SP200SPI")
	_check(not bool(services.quote_service("secondary_ammo", 0.0, 1500.0, 7000040).ok), "ammunition enforces equipped slot")
	quote = services.quote_service("primary_ammo", 1499.0, 1500.0, 7000040)
	_check(bool(quote.ok) and quote.amount == 1 and quote.billed_amount == 100 and quote.cost == 7 and quote.bullet_item_num == ammo, "native caliber and rounded package")
	price = inventory.credits
	result = services.service("primary_ammo", 1499.0, 1500.0, 7000040)
	_check(bool(result.ok) and result.effect.amount == 1 and inventory.credits == price - 7, "ammo service payment and clamped effect")
	_check(not bool(services.quote_service("hp", 100.0, 100.0).ok), "no full-resource charge")
	_check(not bool(services.quote_service("hp", NAN, 100.0).ok), "NaN rejected")
	_check(not bool(services.quote_service("primary_ammo", 0.0, 1.0, 1234).ok), "unknown ammo rejected")
	inventory.credits = 0
	before = inventory.export_state()
	_check(not bool(services.service("hp", 0.0, 100.0).ok) and inventory.export_state() == before, "service insufficient money atomic")
	inventory.credits = 1000000
	_test_crafting(inventory, services)
	_test_state(inventory, services)
	_test_native_shop_binding()
	if failures.is_empty():
		print("PASS: services — %s checks; native prices/bundles20percent sale,304 conservative mixing recipes, original refinery costs, atomic mutations and RNG save" % checks)
		quit(0)
	else:
		for message: String in failures:
			push_error(message)
		quit(1)

func _test_native_shop_binding() -> void:
	var inventory := Inventory.new()
	_check(inventory.configure(), "native shop fixture inventory")
	inventory.credits = 1000000
	var fixture := {"schema_version":1,"stock_item_nums":[7000060,7004000],"native_countable_kinds":[23],
		"native_shops":{"shops":[
			{"building_index":9001,"building_kind":0,"map_id":2001,"npc_index":101,"entries":[{"item_num":7000060}]},
			{"building_index":9002,"building_kind":2,"map_id":2001,"npc_index":102,"entries":[{"item_num":7004000}]}]}}
	var service := Services.new()
	_check(service.configure(inventory,fixture), "native shop fixture configure")
	var before: Dictionary = inventory.export_state()
	_check(service.buy(7000060).error == "native_shop_contact_required", "native buy requires contact")
	_check(inventory.export_state() == before, "missing native contact leaves inventory unchanged")
	var contact := {"source_building_index":9001,"building_kind":0,"source_npc_index":101,"map_id":2001}
	var unknown := {"source_building_index":9999,"building_kind":100,"source_npc_index":0,"map_id":2001}
	var options: Array[Dictionary] = service.shop_options([contact,unknown,contact.duplicate(true)],2001)
	_check(options.size() == 1 and options[0].building_index == 9001 and options[0].native_stock_count == 1, "shop options exclude unknown stock and duplicate contacts")
	_check(int(service.snapshot().active_shop) == 0 and inventory.export_state() == before, "listing shop options does not bind or mutate")
	_check(service.shop_options([contact],2002).is_empty(), "shop options reject contacts from another map")
	_check(bool(service.bind_shop_contact(contact,2001).ok), "matching native building binds")
	_check(service.shop_catalog().total == 1 and service.shop_catalog().rows[0].item_num == 7000060, "native stock isolated by building")
	_check(service.buy(7004000,100).error == "not_in_native_shop" and inventory.export_state() == before, "another shop's item cannot be purchased")
	_check(bool(service.buy(7000060).ok), "native member purchase succeeds")
	before = inventory.export_state()
	_check(not bool(service.bind_shop_contact(contact,2002).ok), "native map identity checked")
	_check(service.buy(7000060).error == "native_shop_contact_required" and inventory.export_state() == before, "failed contact clears stale shop permission")
	contact.source_npc_index = 999
	_check(not bool(service.bind_shop_contact(contact,2001).ok), "native NPC identity checked")
	contact = {"source_building_index":9002,"building_kind":2,"source_npc_index":102,"map_id":2001}
	_check(bool(service.bind_shop_contact(contact,2001).ok) and service.shop_catalog().rows[0].item_num == 7004000, "switching native shop invalidates catalog cache")
	_check(bool(service.buy(7004000,100).ok), "native shop bundles retain original price")
func _test_crafting(inventory: RefCounted, services: RefCounted) -> void:
	var row: Dictionary = services._recipes["10"]
	var ingredient := int(row.ingredients[0].item_num)
	var result_id := int(row.item_num)
	var before: Dictionary = inventory.export_state()
	_check(not bool(services.craft("10").ok) and inventory.export_state() == before, "missing recipe ingredients atomic")
	inventory.add_item(ingredient, 5)
	var money: int = inventory.credits
	var previous := int(inventory.quantities.get(result_id, 0))
	var result: Dictionary = services.craft("10")
	_check(bool(result.ok) and bool(result.success) and result.count == 1, "guaranteed native recipe")
	_check(inventory.credits == money - 346 and int(inventory.quantities.get(ingredient, 0)) == 0 and inventory.quantities[result_id] == previous + 1, "native ingredient count/result/cost")
	_check(result.event.type == "crafted" and result.event.item_num == result_id and not str(result.event.event_id).is_empty(), "craft event source identity")
	before = inventory.export_state()
	_check(not bool(services.craft("10").ok) and inventory.export_state() == before, "craft cannot duplicate used ingredients")
	_check(not bool(services.craft("not-a-recipe").ok), "unknown recipe rejected")
	var blocked: Dictionary = {}
	for value: Dictionary in services._recipes.values():
		if not value.supported:
			blocked = value
			break
	before = inventory.export_state()
	_check(not blocked.is_empty() and not bool(services.craft(str(blocked.recipe_id)).ok) and inventory.export_state() == before, "unsupported recipe remains blocked")
	# Fixture changes probability only to exercise a real failure path, not production catalog.
	var fixture: Dictionary = services._data.duplicate(true)
	fixture.recipes = [{"recipe_id":"fixture", "item_num":result_id, "count":1,"cost":346,"probability_10k":0,"supported":true,"ingredients":[{"item_num":ingredient,"count":5}]}]
	var probabilistic := Services.new()
	_check(probabilistic.configure(inventory, fixture), "failure-path fixture setup")
	probabilistic._rng.seed = 12345
	inventory.add_item(ingredient, 5)
	money = inventory.credits
	previous = int(inventory.quantities.get(result_id, 0))
	result = probabilistic.craft("fixture")
	_check(bool(result.ok) and not bool(result.success) and result.event.is_empty(), "native random failure supported")
	_check(inventory.credits == money - 346 and int(inventory.quantities.get(ingredient, 0)) == 0 and inventory.quantities[result_id] == previous, "failed craft consumes ingredients and money exactly once")
	# Inventory saturation must reject before RNG/credits/removals mutate.
	inventory.quantities[result_id] = Inventory.MAX_COUNT
	inventory.add_item(ingredient, 5)
	before = inventory.export_state()
	var saved: Dictionary = services.export_state()
	_check(not bool(services.craft("10").ok) and inventory.export_state() == before and services.export_state() == saved, "result overflow transaction and RNG no mutation")
	inventory.quantities[result_id] = previous
	var available: Dictionary = services.recipe_catalog("7002840", 0, 8, true, true)
	_check(available.total > 0 and available.rows.size() <= 8 and available.rows[0].available, "craftable search on-demand")
func _test_state(inventory: RefCounted, services: RefCounted) -> void:
	var saved: Dictionary = JSON.parse_string(JSON.stringify(services.export_state()))
	var restored := Services.new()
	restored.configure(inventory)
	_check(bool(restored.import_state(saved).ok) and restored.export_state() == services.export_state(), "lossless RNG operation ledger JSON save")
	var previous: Dictionary = restored.export_state()
	_check(not bool(restored.import_state({"schema_version":1,"rng_state":"999999999999999999999999","operations":0}).ok) and restored.export_state() == previous, "out-of-range RNG rejected")
	_check(not bool(restored.import_state({"schema_version":1,"rng_state":"1","operations":1.5}).ok) and restored.export_state() == previous, "fractional operation ledger rejected")
	# A cached query must see an external inventory reward without per-frame full compilation.
	var one: Dictionary = services.shop_catalog("7000060", 0, 8, true, "sell")
	inventory.add_item(7000060)
	var two: Dictionary = services.shop_catalog("7000060", 0, 8, true, "sell")
	_check(two.rows.size() == 1 and two.rows[0].count > one.rows[0].count, "external inventory changes invalidate browse cache")
