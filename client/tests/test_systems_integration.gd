extends SceneTree
## Production-scene E2E: no wallet, quest completion, item or positive kill grants.
## Controlled poses and peaceful AI isolate native weapon resolution as in test_gameplay.
const ProgressStore = preload("res://scripts/local_save.gd")
var scene: Node3D
var systems: Node
var checks := 0
var failures: Array[String] = []
var kill_evidence: Array[Dictionary] = []
var transaction_evidence: Array[Dictionary] = []
var transfers: Array[int] = []
var saved_path := "user://systems-integration-v07.json"
var legacy_path := "user://systems-integration-v06.json"

func _initialize() -> void:
	_run.call_deferred()

func _check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures.append(message)

func _run() -> void:
	scene = (load("res://main.tscn") as PackedScene).instantiate()
	root.add_child(scene)
	scene.set_physics_process(false)
	scene.set_process(false)
	await process_frame
	systems = scene.get("systems")
	_check(is_instance_valid(systems) and scene._combat_ready, "production main initializes GameSystems and combat")
	if not is_instance_valid(systems) or not scene._combat_ready:
		await _finish()
		return
	systems.set_process(false)
	_check(int(scene.combat_runtime.inventory.credits) == 0, "E2E begins with zero earned SPI")
	_check(int(scene.combat_runtime.inventory.bonus_stats) == 0, "E2E begins with no unearned stat points")
	var initial: Dictionary = scene.combat_runtime.inventory.export_state()
	var original_position: Vector3 = scene.model.position
	scene.model.position = Vector3(100000,100000,100000)
	_check(not bool(systems._access("buy").ok), "distant field merchant access explicitly denied")
	_action("shop_buy:7000790:1")
	scene.model.position = original_position
	_check(scene.combat_runtime.inventory.export_state() == initial, "field without corresponding nearby merchant cannot purchase")
	_action("allocate_stat:attack:1")
	_check(scene.combat_runtime.inventory.export_state() == initial, "allocation without earned points grants neither stats nor currency")
	_action("accept_mission:101")
	_check(_mission("101").get("status") == "completed", "native dialogue101 unlocks combat chain")
	_action("accept_mission:102")
	await process_frame
	_check(scene.current_map_id == 3302 and _mission("102").get("status") == "active", "native102 accepts and warps to3302")
	await _complete_native_combat_mission("102", {2028200:1, 2028100:3})
	_check(scene.current_map_id == 2001, "102 returns to original city2001")
	_check(scene.combat_runtime.inventory.credits == 320 and scene.combat_runtime.inventory.experience == 91, "102 pays native320SPI/91XP only once")
	_interact_npc(3)
	_action("accept_mission:103")
	await process_frame
	_check(scene.current_map_id == 3303 and _mission("103").get("status") == "active", "native103 accepts at original city contact and warps3303")
	await _complete_native_combat_mission("103", {2002800:5, 2003000:2})
	_check(scene.current_map_id == 2001, "103 returns to original city2001")
	_check(scene.combat_runtime.inventory.credits == 770 and scene.combat_runtime.inventory.experience == 232, "two source missions earn exactly770SPI/232XP")
	_check(kill_evidence.size() == 11, "eleven production target_destroyed events were earned by actual weapons")
	for event: Dictionary in kill_evidence:
		_check(int(event.get("source_id", 0)) in [7000040,7901000] and not str(event.get("instance_id", "")).is_empty(), "quest evidence carries actual native weapon and target life")
	_test_city_economy()
	_test_skill_pipeline()
	await _test_progress_roundtrip()
	_test_ui_query_contract()
	await _finish()

func _action(value: String) -> void:
	scene.legacy_hud.local_action_requested.emit(value)
	scene._drain_simulation_events()

func _mission(identifier: String) -> Dictionary:
	for row: Dictionary in scene.world_runtime.get_state().missions:
		if str(row.id) == identifier:
			return row
	return {}

func _interact_npc(index: int) -> void:
	for npc: Dictionary in scene.world_runtime._npcs:
		if int(npc.get("source_npc_index", 0)) == index:
			scene.model.position = npc.position
			scene.world_runtime.interact_nearest(npc.position)
			return
	_check(false, "native NPC%d missing in map%d" % [index,scene.current_map_id])

func _close_input_modals() -> void:
	if scene.legacy_hud.is_world_panel_open():
		scene.legacy_hud.toggle_world_panel()
	if scene.legacy_hud.inventory_items.visible:
		scene.legacy_hud.toggle_inventory()
	scene.legacy_hud._chat_input.release_focus()
	scene.is_paused = false

func _complete_native_combat_mission(identifier: String, expected: Dictionary) -> void:
	var runtime: Node3D = scene.combat_runtime
	var counts: Dictionary = {}
	for target: Dictionary in runtime.model.targets:
		counts[int(target.monster_code)] = int(counts.get(int(target.monster_code),0)) + 1
	var species_match := counts.size() == expected.size()
	for code: Variant in expected:
		species_match = species_match and int(counts.get(code,0)) > 0 and int(counts.get(code,0)) <= int(expected[code])
	_check(species_match, "mission%s encounter contains all required native species without fabricated extra species" % identifier)
	if not species_match:
		return
	transfers.append(scene.current_map_id)
	_close_input_modals()
	scene.model.position = Vector3(0,1800,0)
	scene.model.movement_enabled = false
	scene.ship.position = scene.model.position
	for target: Dictionary in runtime.model.targets:
		target.hostile = false
		target.speed = 0.0
		target.position = Vector3(1000+int(target.id)*100,1800,-1000)
		target.spawn_position = target.position
	var initial_ammo := int(runtime.model.player.primary_ammo)
	for code: Variant in expected:
		var actors: Array[Dictionary] = []
		for actor: Dictionary in runtime.model.targets:
			if int(actor.monster_code) == int(code): actors.append(actor)
		for kill_index in range(int(expected[code])):
			var target: Dictionary = actors[kill_index % actors.size()]
			# Non-explicit maps intentionally spawn one local actor per source species.
			# Repeated objectives use its genuine timed respawn/new life identity.
			if bool(target.dead):
				var wait_steps := ceili((float(target.respawn_remaining)+0.1)*30.0)
				for _wait_index in range(wait_steps):
					runtime.advance(1.0/30.0, {}, {"position":scene.model.position,"forward":Vector3.FORWARD})
					scene._drain_simulation_events()
			_check(not bool(target.dead), "mission%s repeat uses genuine timed native-identity local respawn" % identifier)
			var native: Dictionary = runtime._native_monsters[int(target.monster_code)]
			_check(float(target.hp) == float(native.HP) and float(target.max_hp) == float(native.HP), "mission%s target starts with native HP" % identifier)
			target.position = Vector3(0,1800,-120)
			runtime.model.select_target(int(target.id))
			var steps := 0
			while not bool(target.dead) and steps < 1800:
				runtime.advance(1.0/30.0, {"primary":true,"secondary":true,"aim_origin":scene.model.position,"aim_direction":Vector3.FORWARD}, {"position":scene.model.position,"forward":Vector3.FORWARD})
				for event: Dictionary in runtime._events:
					if str(event.get("type", "")) == "target_destroyed":
						kill_evidence.append(event.duplicate(true))
				scene._drain_simulation_events()
				steps += 1
			_check(bool(target.dead), "native weapons kill mission%s source%d" % [identifier,int(target.monster_code)])
			if bool(target.dead):
				target.spawn_position = Vector3(2000,1800,-2000)
		# Species with a completed objective no longer respawn during this fixture.
		for target: Dictionary in actors:
			if bool(target.dead): target.respawn_remaining = 10000.0
	_check(int(runtime.model.player.primary_ammo) < initial_ammo, "mission%s consumed actual primary ammunition" % identifier)
	_check(_mission(identifier).get("status") == "ready", "mission%s becomes ready from actual weapon kills" % identifier)
	_action("claim_reward:" + identifier)
	await process_frame
	_check(_mission(identifier).get("status") == "completed", "mission%s claimed through actual HUD action" % identifier)
	var wallet := int(runtime.inventory.credits)
	_action("claim_reward:" + identifier)
	_check(int(runtime.inventory.credits) == wallet, "mission%s reward replay cannot mint SPI" % identifier)
	transfers.append(scene.current_map_id)

func _test_city_economy() -> void:
	var inventory = scene.combat_runtime.inventory
	_check(bool(systems._access("buy").ok) and bool(systems._access("maintenance").ok) and bool(systems._access("recipes").ok), "city console is backed by original merchant/refinery/laboratory NPCs")
	var money: int = inventory.credits
	var owned := int(inventory.quantities.get(7000790,0))
	_action("shop_buy:7000790:1")
	_check(inventory.credits == money-60 and int(inventory.quantities.get(7000790,0)) == owned+1, "earned SPI buys a real original fuel ITEM at native60 price")
	_action("shop_sell:7000790:1")
	_check(inventory.credits == money-48 and int(inventory.quantities.get(7000790,0)) == owned, "same owned ITEM sells for native12SPI without duplication")
	transaction_evidence.append({"operation":"buy_then_sell","item_num":7000790,"spent":60,"received":12})
	var before: Dictionary = inventory.export_state()
	_action("shop_sell:7000790:1")
	_check(inventory.export_state() == before, "replayed sale cannot sell an absent item")
	var player: Dictionary = scene.combat_runtime.model.player
	player.hp = float(player.max_hp)-10.0 # Damage fixture, never a positive resource grant.
	money = inventory.credits
	_action("service_repair:hp")
	_check(is_equal_approx(float(player.hp),float(player.max_hp)) and inventory.credits == money-50, "city repair applies10 native HP and debits50 earnedSPI")
	var max_ep := float(inventory.combat_profile().max_ep)
	scene.model.set_fuel_state(max_ep-2.0,max_ep)
	money = inventory.credits
	_action("service_repair:ep")
	_check(is_equal_approx(scene.model.fuel_fraction,1.0) and inventory.credits == money-2, "fuel service applies actual model EP and debits2SPI")
	var resource: Dictionary = systems._resource("primary_ammo")
	var quote: Dictionary = systems.services.quote_service("primary_ammo",float(resource.current),float(resource.maximum),int(resource.weapon_item_num))
	money = inventory.credits
	_action("service_ammo:primary")
	_check(bool(quote.ok) and int(player.primary_ammo) == int(resource.maximum) and inventory.credits == money-int(quote.cost), "native ammo bundle payment fills actual weapon magazine")
	transaction_evidence.append({"operation":"ammunition","cost":quote.get("cost",0),"amount":quote.get("amount",0),"billed_amount":quote.get("billed_amount",0)})
	money = inventory.credits
	_action("shop_buy:7002710:5")
	_check(inventory.credits == money-500 and int(inventory.quantities.get(7002710,0)) == 5, "remaining earned SPI buys all five native recipe0 ingredients")
	var previous_result := int(inventory.quantities.get(7000800,0))
	money = inventory.credits
	_action("craft_recipe:0")
	_check(int(inventory.quantities.get(7002710,0)) == 0 and int(inventory.quantities.get(7000800,0)) == previous_result+1 and inventory.credits == money, "city fabrication consumes purchased native inputs and creates one native catalyst")
	_check(int(systems.services.snapshot().operations) == 1, "successful fabrication advances persistent operation ledger once")
	before = inventory.export_state()
	_action("craft_recipe:0")
	_check(inventory.export_state() == before and int(systems.services.snapshot().operations) == 1, "second fabrication without inputs creates nothing and preserves ledger")
	_check(int(scene.world_runtime.get_state().wallet.credits) == inventory.credits and int(scene.combat_runtime.model.player.credits) == inventory.credits, "post-transaction wallet synchronizes world/combat/inventory")
	_check(int(scene.world_runtime.get_state().wallet.experience) == 232 and inventory.experience == 232, "all economy actions preserve native earned XP")

func _test_skill_pipeline() -> void:
	_close_input_modals()
	var inventory = scene.combat_runtime.inventory
	var combat = scene.combat_runtime.model
	var identifier := 7830011 # Native I-GEAR FireShot rank1, initial local training policy.
	_check(systems.skills.learned.has(identifier), "explicit local starter training includes compatible native FireShot rank1")
	_action("skill_assign:1:"+str(identifier))
	var seed_state: int = combat._rng_state
	var defender := {"level":inventory.level,"defense":0.0,"dodge":0.0}
	var baseline: Dictionary = {}
	for _attempt in range(30):
		seed_state = combat._rng_state
		baseline = combat.resolve_attack(combat.weapons.primary,combat.player,defender,100.0)
		if bool(baseline.hit): break
	_check(bool(baseline.get("hit",false)), "native weapon establishes an actual hit for modifier comparison")
	var ammo := int(combat.player.primary_ammo)
	var money: int = inventory.credits
	var sp: float = systems.skills.sp
	var result: Dictionary = systems.cast_slot(1)
	_check(bool(result.get("ok",false)) and is_equal_approx(systems.skills.sp,sp-10.0), "main skill cast uses native10SP through assigned hotbar")
	_check(is_equal_approx(float(combat.skill_modifiers.get("primary_min_attack",0.0)),0.05), "cast propagates native5percent buff to production combat modifiers")
	combat._rng_state = seed_state
	var buffed: Dictionary = combat.resolve_attack(combat.weapons.primary,combat.player,defender,100.0)
	_check(bool(buffed.hit) and is_equal_approx(float(buffed.damage),float(baseline.damage)*1.05), "same real weapon/RNG hit resolves5percent more damage after native skill")
	_check(combat.player.primary_ammo == ammo and inventory.credits == money, "skill usage grants no ammunition or SPI")
	var saved: Dictionary = systems.skills.export_state()
	_check(not bool(systems.cast_slot(1).get("ok",false)) and systems.skills.export_state() == saved, "cooldown recast denial preserves SP and timers")

func _test_progress_roundtrip() -> void:
	var checkpoint: Dictionary = scene._capture_local_progress()
	_check(checkpoint.get("systems",{}).has("services") and checkpoint.systems.skills.active.size() > 0, "checkpoint contains new service RNG ledger and active native skill")
	var result: Dictionary = ProgressStore.save_game(checkpoint,saved_path)
	_check(bool(result.get("ok",false)), "new systems checkpoint persists with checksum/atomic store")
	var read: Dictionary = ProgressStore.read_game(saved_path)
	_check(bool(read.get("ok",false)), "new systems checkpoint reads valid checksum")
	result = scene._restore_local_progress(read.get("snapshot",{}))
	_check(bool(result.get("ok",false)), "full production restore accepts new systems checkpoint")
	_check(systems.export_state() == checkpoint.systems, "new services RNG/operation ledger and skills roundtrip exactly")
	_check(scene.combat_runtime.inventory.export_state() == checkpoint.combat.inventory, "new systems restore preserves native items/wallet/progression")
	var corrupted: Dictionary = checkpoint.duplicate(true)
	corrupted.systems.services.rng_state = "999999999999999999999999999"
	var preserved: Dictionary = scene._capture_local_progress()
	_check(not bool(scene._restore_local_progress(corrupted).get("ok",false)), "corrupt new RNG checkpoint rejected")
	_check(_persistent_character_state(scene._capture_local_progress()) == _persistent_character_state(preserved), "corrupt nested systems rollback preserves persistent character/session fields while local encounter identity regenerates")
	var legacy: Dictionary = checkpoint.duplicate(true)
	legacy.release = "0.6.0"
	legacy.erase("systems")
	legacy.flight.erase("fuel")
	legacy.combat.inventory.erase("allocated_stats")
	legacy.combat.inventory.erase("grandfathered_equipment")
	result = scene._restore_local_progress(legacy)
	_check(bool(result.get("ok",false)), "0.6-shaped checkpoint migrates with optional systems/stat/fuel fields absent")
	_check(scene.combat_runtime.inventory.credits == int(checkpoint.combat.inventory.credits) and int(scene.combat_runtime.inventory.quantities.get(7000800,0)) > 0, "legacy migration preserves earned SPI and owned crafted item")
	_check(int(systems.services.snapshot().operations) == 0 and systems.skills.snapshot(false).active_count == 0, "legacy migration supplies fresh local systems without invented active skill or historical crafts")
	_check(bool(scene._restore_local_progress(checkpoint).get("ok",false)), "latest checkpoint remains restorable after legacy-shaped migration")
	# Exact checkpoint from the normal exported0.6 executable, not reconstructed0.7 data.
	var original_v06 := FileAccess.get_file_as_bytes("res://tests/fixtures/progress-v06.json")
	var hash := HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(original_v06)
	_check(hash.finish().hex_encode() == "2b7a92dbe222ce870f9a454c584a90b050e898c7ecd838e6e72cf63778edbc6a", "real exported0.6 checkpoint fixture is unchanged")
	var stream := FileAccess.open(legacy_path,FileAccess.WRITE)
	_check(stream != null, "real0.6 fixture copied to isolated user save path")
	if stream != null:
		stream.store_buffer(original_v06)
		stream.close()
	var original_read: Dictionary = ProgressStore.read_game(legacy_path)
	_check(bool(original_read.get("ok",false)) and str(original_read.get("snapshot",{}).get("release","")) == "0.6.0", "real exported0.6 envelope passes original checksum reader")
	result = scene._restore_local_progress(original_read.get("snapshot",{}))
	_check(bool(result.get("ok",false)), "real0.6 schema1 checkpoint migrates into native0.7 stats/resources")
	var profile: Dictionary = scene.combat_runtime.inventory.combat_profile()
	var old_player: Dictionary = original_read.get("snapshot",{}).get("combat",{}).get("player",{})
	var migrated: Dictionary = scene.combat_runtime.model.player
	_check(float(old_player.get("max_shield",0.0)) == 400.0 and is_equal_approx(float(migrated.max_shield),float(profile.max_shield)) and is_equal_approx(float(migrated.shield)/float(migrated.max_shield),float(old_player.shield)/float(old_player.max_shield)), "real legacy400DP migrates to native derived capacity while preserving resource fraction")
	_check(scene.current_map_id == 3002 and scene.combat_runtime.inventory.credits == 0 and scene.combat_runtime.inventory.experience == 0 and migrated.primary_ammo == 1000, "real legacy map/earned ledgers/ammunition remain intact")
	_check(int(systems.services.snapshot().operations) == 0 and systems.skills.snapshot(false).active_count == 0, "real0.6 migration initializes only missing systems state")
	_check(bool(scene._restore_local_progress(checkpoint).get("ok",false)) and scene.combat_runtime.inventory.credits == int(checkpoint.combat.inventory.credits), "0.7 checkpoint restores earned economy after migration of real0.6 save")
	await process_frame

func _test_ui_query_contract() -> void:
	_action('systems_query:{"mode":"recipes","query":"7000800","offset":0,"limit":100,"available":false}')
	if not scene.legacy_hud.is_world_panel_open(): scene.legacy_hud.toggle_world_panel()
	systems.refresh_ui()
	var service: Dictionary = scene.legacy_hud._systems_state.get("services",{})
	_check(service.get("mode") == "recipes" and int(service.get("limit",0)) == 8 and service.rows.size() <= 8, "systems/HUD recipe query honors eight-row pagination")
	_action('systems_query:{"mode":"maintenance","query":"","offset":0,"available":true}')
	service = scene.legacy_hud._systems_state.get("services",{})
	_check(bool(service.get("allowed",false)) and service.get("quotes",[]).size() == 6, "maintenance query exposes appropriate city authorization and six quotes")
	for quote: Dictionary in service.get("quotes",[]):
		_check(not str(quote.get("kind",quote.get("resource",""))).is_empty(), "full/failed service quotes retain resource identity for correct UI action")
	_check(not bool(systems.network.snapshot().get("connected",false)), "default session does not connect to a network automatically")

func _finish() -> void:
	for path: String in [saved_path,legacy_path]:
		for suffix: String in ["", ".bak", ".tmp"]:
			if FileAccess.file_exists(path+suffix): DirAccess.remove_absolute(path+suffix)
	var report := {"checks":checks,"failures":failures,"positive_kills":kill_evidence.size(),"weapons":[7000040,7901000],"native_missions":[102,103],"native_earned_spi":770,"native_earned_xp":232,"map_transfers":transfers,"transactions":transaction_evidence,"scope":"production_scene_native_weapons_and_rewards; poses/damage/AI scheduling fixtures only; no positive quest/ITEM/wallet grants"}
	print("SYSTEMS_E2E="+JSON.stringify(report))
	if is_instance_valid(scene): scene.queue_free()
	await process_frame
	if failures.is_empty():
		print("PASS: systems integration — %d checks; two real native combat missions→earned SPI→city buy/sell/refinery/crafting, skill damage/SP and legacy/new persistence" % checks)
		quit(0)
	else:
		for message: String in failures: push_error(message)
		quit(1)

func _persistent_character_state(value: Dictionary) -> Dictionary:
	var result: Dictionary = value.duplicate(true)
	# Restores deliberately generate new local encounter life identities.
	# Reusing the serial would invalidate anti-replay quest kill evidence.
	result.get("combat",{}).erase("encounter_serial")
	return result
