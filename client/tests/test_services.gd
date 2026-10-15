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
	_check(int(info.stock_count) == 2596 and int(info.recipe_count) == 39230 and int(info.supported_recipes) == 304, "frozen native/local coverage")
	var shop: Dictionary = services.shop_catalog("", 0, 100)
	_check(shop.rows.size() == 8 and shop.total > 0, "shop page cap")
	var next: Dictionary = services.shop_catalog("", 8, 8)
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
	if failures.is_empty():
		print("PASS: services — %s checks; native prices/bundles20percent sale,304 conservative mixing recipes, original refinery costs, atomic mutations and RNG save" % checks)
		quit(0)
	else:
		for message: String in failures:
			push_error(message)
		quit(1)
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
