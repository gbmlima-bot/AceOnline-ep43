extends SceneTree

const Arena = preload("res://scripts/online/arena_model.gd")
const World = preload("res://scripts/online/headless_world.gd")
const Combat = preload("res://scripts/combat_model.gd")
const Wire = preload("res://scripts/online/json_wire.gd")
var failures: Array[String] = []
var checks := 0
var world: RefCounted


func _initialize() -> void:
	world = World.new()
	_check(world.configure(3002), "Native headless terrain3002 did not configure")
	_test_authority_commands_and_persistence()
	_test_cooperative_combat_and_shared_clock()
	_test_offline_combat_compatibility()
	_test_eight_pilot_wire_budget()
	_test_bounded_command_cache()
	_test_departed_pilots_do_not_fill_snapshot()
	if failures.is_empty():
		print("PASS: online arena — %d checks; authoritative controls/flight, shared NPC HP/RNG/projectiles, cooperative native damage/rewards, replay rejection, reconnect and complete JSON persistence" % checks)
		quit(0)
	else:
		for failure: String in failures:
			push_error(failure)
		quit(1)


func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)


func _arena() -> RefCounted:
	var arena = Arena.new()
	_check(arena.configure({"room_id": "test-room", "seed": 12345, "max_players": 2}, world), "Arena native source configuration failed")
	return arena


func _test_authority_commands_and_persistence() -> void:
	var arena = _arena()
	_check(bool(arena.add_player("alice").ok) and bool(arena.add_player("bob").ok), "Two authenticated pilot records did not join")
	_check(not bool(arena.add_player("eve").ok), "Two-pilot capacity was bypassed")
	_check(arena.combat.targets.size() == 3 and arena.combat.pilot_states.size() == 2, "Joining pilots duplicated native NPC encounter")
	_check(float(arena.combat.targets[0].max_hp) == 303, "Original Hornian303HP was replaced by a test/combat shortcut")
	for controls: Dictionary in [{"position": [0, 0, 0]}, {"damage": 999}, {"aim_origin": [0, 0, 0]}, {"reward": 1000}, {"pitch": 2}, {"yaw": NAN}, {"primary": 1}]:
		_check(not bool(arena.submit_input("alice", 0, controls).ok), "Untrusted pose/damage/reward/invalid control accepted")
	_check(bool(arena.submit_input("alice", 0, {"yaw": 0.25, "brake": true}).ok), "Valid native flight axes were refused")
	_check(not bool(arena.submit_input("alice", 0, {"primary": true}).ok), "Duplicate input sequence replay was accepted")
	_check(not bool(arena.submit_input("unknown", 1, {}).ok), "Unknown identity submitted controls")
	_check(not bool(arena.submit_input("bob", 0, {"aim_direction": [0, 0, -100]}).ok), "Non-unit aim vector bypassed control validation")
	_check(bool(arena.submit_input("bob", 0, {"aim_direction": [0, 0, -1]}).ok), "Validated aim direction was refused")
	var start: Vector3 = arena.pilots.alice.flight.position
	arena.advance(0.1)
	_check((arena.pilots.alice.flight.position as Vector3).distance_to(start) > 1, "Authoritative FlightModel did not move from controls")
	_check(arena.tick == 12 and is_equal_approx(float(arena.combat.elapsed), 0.1), "Two pilots advanced shared NPC/combat clock twice")
	var cast: Dictionary = arena.command("alice", "cast1", "skill_use", {"slot": 1})
	_check(bool(cast.ok) and int(cast.item_num) == 7830011, "Explicit native I-GEAR starter FireShot did not execute")
	var sp: float = arena.pilots.alice.skills.sp
	var replay: Dictionary = arena.command("alice", "cast1", "skill_use", {"slot": 1.0})
	_check(bool(replay.ok) and bool(replay.get("replayed", false)) and arena.pilots.alice.skills.sp == sp, "Replayed command consumed SP or was rejected after JSONnumber normalization")
	_check(not bool(arena.command("alice", "cast1", "skill_use", {"slot": 2}).ok), "Reused requestID with changed body was accepted")
	_check(not bool(arena.command("alice", "shop", "buy", {"item_num": 7000040}).ok), "Field arena exposed remote shop without NPC")
	_check(not bool(arena.command("alice", "equip", "equip", {"item_num": 7000050, "slot": "primary"}).ok), "Unowned equipment became available online")
	# Damage/rounds/timing originate on the server; this fixture proves state is
	# not refreshed by serializing or joining another pilot.
	arena.combat.activate_pilot("alice")
	arena.combat.damage_player(200, "fixture")
	arena.combat.player.primary_ammo -= 17
	arena.combat.player.primary_cooldown = 0.125
	arena.combat.store_pilot()
	arena.combat.targets[0].hp -= 11
	var saved: Dictionary = JSON.parse_string(JSON.stringify(arena.export_state()))
	var restored = _arena()
	_check(restored.import_state(saved), "Complete arena aggregate failed JSON roundtrip")
	if restored.pilots.size() != 2:
		_check(false, "Restored room lost pilots")
		return
	_check(not bool(restored.pilots.alice.connected) and not bool(restored.pilots.bob.connected), "Restart persisted stale live socket connections")
	_check(restored.tick == arena.tick and restored.combat._rng_state == arena.combat._rng_state and _equal(restored.combat.targets, arena.combat.targets), "Restart changed shared NPC HP/life/RNG/tick")
	_check(_equal(restored.combat.pilot_states.alice.player, arena.combat.pilot_states.alice.player) and _equal(restored.combat.pilot_states.bob.player, arena.combat.pilot_states.bob.player), "Adding second restored pilot reset first pilot damage/ammo/recast")
	_check(bool(restored.add_player("alice").ok) and bool(restored.add_player("bob").ok), "Persistent identities did not reconnect")
	var recast: Dictionary = restored.command("alice", "cast1", "skill_use", {"slot": 1})
	_check(bool(recast.get("replayed", false)) and restored.pilots.alice.skills.sp == sp, "Command receipt did not survive restart")
	_check(not bool(restored.submit_input("alice", 0, {"primary": true}).ok), "Restart reset input sequence allowing replay")
	var snapshot: Dictionary = restored.snapshot("alice")
	_check(JSON.stringify(snapshot).to_utf8_buffer().size() < 16000 and snapshot.self.skills.rows.is_empty(), "Snapshot exceeded WSS16KiB budget or exposed full skill catalog")
	_check(not snapshot.self.inventory.has("combat_profile"), "Snapshot leaked unnecessary native aggregate equipment catalog")
	_check(not Wire.encode({"op": "snapshot", "state": snapshot}).is_empty(), "Snapshot contains non-JSONGodottypes or exceedsWSSlimits")
	var original: Dictionary = restored.export_state()
	var malformed := saved.duplicate(true)
	malformed.targets[0].hp = 999999
	_check(not restored.import_state(malformed) and restored.export_state() == original, "Invalid shared NPC state mutated live arena before rejection")
	malformed = saved.duplicate(true)
	malformed.pilots.alice.skills.sp = 999999
	_check(not restored.import_state(malformed) and restored.export_state() == original, "Invalid saved SP changed live arena before rejection")
	malformed = saved.duplicate(true)
	malformed.pilots.alice.flight.position = {"_vector3": [INF, 0, 0]}
	_check(not restored.import_state(malformed) and restored.export_state() == original, "Invalid saved pose bypassed finite validation")
	restored.remove_player("bob")
	var wounded: float = restored.combat.pilot_states.bob.player.hp
	_check(bool(restored.add_player("eve").ok) and bool(restored.pilots.bob.inventory != null), "Disconnect deleted persistent pilot or did not free connection slot")
	restored.remove_player("eve")
	_check(bool(restored.add_player("bob").ok) and restored.combat.pilot_states.bob.player.hp == wounded, "Rejoin refreshed pilot HP")


func _test_cooperative_combat_and_shared_clock() -> void:
	var arena = _arena()
	arena.add_player("alice")
	arena.add_player("bob")
	# Server-only stationary targeting fixture at clear altitude. All three
	# source Hornian HP and the original weapon equations remain unchanged.
	for identifier: String in ["alice", "bob"]:
		arena.pilots[identifier].flight.position = Vector3(0, 1500, 100)
		arena.pilots[identifier].flight.profile_ready = false
	for index in range(3):
		arena.combat.targets[index].position = Vector3(0, 1500, -100 - index * 700)
		arena.combat.targets[index].spawn_position = arena.combat.targets[index].position
		arena.combat.targets[index].speed = 0
		arena.combat.targets[index].hostile = false
	var kills := 0
	var rewards: Dictionary = {}
	var first_life_key := ""
	for frame in range(55):
		arena.submit_input("alice", frame, {"primary": true, "secondary": true})
		arena.submit_input("bob", frame, {"primary": true, "secondary": true})
		arena.advance(0.1)
		for event: Dictionary in arena.drain_events():
			if event.type == "target_destroyed" and int(event.id) == 0:
				kills += 1
				first_life_key = str(event.instance_id)
			if event.type == "pilot_reward" and str(event.reward_id).contains("/0:0/"):
				rewards[str(event.pilot_id)] = int(rewards.get(str(event.pilot_id), 0)) + 1
	_check(kills == 1 and arena.combat.targets[0].dead and not first_life_key.is_empty(), "Two pilots did not destroy exactly one shared native303HP Hornian")
	_check(int(rewards.get("alice", 0)) == 1 and int(rewards.get("bob", 0)) == 1, "Contributing pilots did not receive one idempotent reward for shared NPC life")
	_check(int(arena.pilots.alice.inventory.credits) >= 10 and int(arena.pilots.bob.inventory.credits) >= 10, "Local pilot10SPI kill rewards were not persisted to both inventories")
	_check(is_equal_approx(float(arena.combat.elapsed), 5.5) and arena.tick == 660, "Cooperative room clock advanced by player count")
	var before_credits := int(arena.pilots.alice.inventory.credits)
	var duplicate := {"type": "target_destroyed", "id": 0, "monster_code": 2000000, "pilot_id": "alice"}
	arena._process_event(duplicate)
	_check(arena.pilots.alice.inventory.credits == before_credits, "Duplicate destruction replay minted a second reward")
	var saved: Dictionary = JSON.parse_string(JSON.stringify(arena.export_state()))
	var restored = _arena()
	_check(restored.import_state(saved), "Active missiles/dead NPC/contributions failed restart roundtrip")
	_check(_equal(restored.combat.projectiles, arena.combat.projectiles) and restored.combat._next_projectile_id == arena.combat._next_projectile_id and restored._rewarded == arena._rewarded, "Restart lost projectile owners/IDs or kill reward ledger")
	restored.add_player("alice")
	restored.add_player("bob")
	restored._process_event(duplicate)
	_check(restored.pilots.alice.inventory.credits == before_credits, "Restart erased kill idempotency ledger")
	for frame in range(10):
		for id: String in ["alice", "bob"]:
			arena.submit_input(id, frame + 55, {"primary": true, "secondary": true})
			restored.submit_input(id, frame + 55, {"primary": true, "secondary": true})
		arena.advance(0.1)
		restored.advance(0.1)
	_check(arena.combat._rng_state == restored.combat._rng_state and _equal(arena.combat.targets, restored.combat.targets) and _equal(arena.combat.projectiles, restored.combat.projectiles), "Restart changed subsequent shared combat evolution/RNG/round trajectories")
	var event_batch: Array[Dictionary] = arena.drain_events()
	_check(not Wire.encode({"op": "events", "events": event_batch}).is_empty(), "Combat events leaked Vector3/Quaternion through network JSON boundary")
	# Removing a pilot leaves the same shared wounded/dead entities for late join.
	restored.remove_player("bob")
	var hp: float = restored.combat.targets[1].hp
	_check(bool(restored.add_player("late").ok) and restored.combat.targets[1].hp == hp and restored.combat.targets.size() == 3, "Late join regenerated the encounter")


func _test_offline_combat_compatibility() -> void:
	var native: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets/legacy_rules/combat.json"))
	var combat = Combat.new()
	_check(combat.configure({"primary": native.primary, "secondary": native.secondary, "player": {"level": 9}}), "Offline CombatModel no longer configured")
	combat.add_target({"HP": 303, "Level": 1, "hostile": false}, Vector3(0, 0, -100))
	combat.advance(0.5, {"primary": true})
	_check(combat.pilot_states.is_empty() and combat.player.primary_ammo == 997 and combat.targets[0].hp < 303, "Shared combat extension changed offline firing/cadence")


func _test_eight_pilot_wire_budget() -> void:
	var arena = Arena.new()
	_check(arena.configure({"room_id": "budget", "max_players": 8}, world), "Configured8pilot safetycap was rejected")
	for index in range(8):
		_check(bool(arena.add_player("pilot%d" % index).ok), "Pilot within8cap failed to join")
	for index in range(96):
		arena.combat.projectiles.append({"id": index, "position": Vector3(index, 1500, 0), "direction": Vector3.FORWARD, "pilot_id": "pilot%d" % (index % 8), "target_id": 0, "weapon": arena.combat.weapons.secondary})
	var snapshot: Dictionary = arena.snapshot("pilot0")
	var encoded := Wire.encode({"op": "snapshot", "state": snapshot})
	_check(not encoded.is_empty() and encoded.to_utf8_buffer().size() <= Wire.MAX_FRAME_BYTES, "8pilots+96authoritativeprojectiles exceeded16KiBWSSframe")
	_check(snapshot.projectiles.size() == 24 and int(snapshot.projectile_count) == 96 and arena.combat.projectiles.size() == 96, "Visual snapshot budget altered authoritative missiles")
	print("Arena wire budget8pilots/96rounds: ", encoded.to_utf8_buffer().size(), "bytes")


func _test_bounded_command_cache() -> void:
	var arena = _arena()
	arena.add_player("alice")
	var args := {"slot": 1, "item_num": 7830011}
	var completed := true
	for index in range(Arena.MAX_COMMANDS + 1):
		if not bool(arena.command("alice", "cache-%d" % index, "skill_assign", args).get("ok", false)):
			completed = false
			break
	_check(completed, "4097th legitimate command permanently exhausted lifetime command quota")
	_check(arena._commands.size() == Arena.MAX_COMMANDS and not arena._commands.has("alice/cache-0"), "Replay cache did not evict oldest entry within4096bound")
	var replay: Dictionary = arena.command("alice", "cache-%d" % Arena.MAX_COMMANDS, "skill_assign", args)
	_check(bool(replay.get("replayed", false)) and arena._commands.size() == Arena.MAX_COMMANDS, "Recent request stopped deduplicating after cache eviction")
	_check(bool(arena.command("alice", "a".repeat(128), "skill_assign", args).get("ok", false)), "Public128character requestID was rejected by sharedArena")
	_check(not bool(arena.command("alice", "a".repeat(129), "skill_assign", args).get("ok", false)) and not bool(arena.command("alice", "bad@request", "skill_assign", args).get("ok", false)), "Arena requestID differs from publicStoreASCII/lengthcontract")


func _test_departed_pilots_do_not_fill_snapshot() -> void:
	var arena = _arena()
	var joined := true
	for index in range(22):
		var identifier := "departed-%d" % index
		if not bool(arena.add_player(identifier).get("ok", false)):
			joined = false
		arena.remove_player(identifier)
	_check(joined and arena.pilots.size() == 22, "Departed pilot identities were not retained for server persistence")
	arena.add_player("active-a")
	arena.add_player("active-b")
	var public_state: Dictionary = arena.snapshot("active-a")
	_check(public_state.pilots.size() == 2 and public_state.pilots[0].id == "active-a" and public_state.pilots[1].id == "active-b", "Historic disconnected pilots leaked into public room snapshot")
	_check(not Wire.encode({"op": "snapshot", "state": public_state}).is_empty(), "22departedpilots+2livepilots exhausted16KiBWSSsnapshotbudget")
	_check(arena.export_state().pilots.size() == 24, "Snapshot filtering discarded historic pilot persistence")
	_check(arena.snapshot("departed-0").pilots.size() == 3, "Explicit own-pilot snapshot exception was lost")
	arena.combat.activate_pilot("departed-0")
	arena.combat.player.hp = 0.0
	arena.combat.player.dead = true
	arena.combat.player.respawn_remaining = 4.0
	arena.combat.store_pilot()
	var private_state: Dictionary = arena.combat.pilot_states["departed-0"].player.duplicate(true)
	var private_flight: Dictionary = Arena._capture_flight(arena.pilots["departed-0"].flight)
	_check(not bool(arena.submit_input("departed-0", 0, {"primary": true}).get("ok", false)), "Disconnected pilot submitted active controls")
	arena.advance(0.5)
	_check(_equal(arena.combat.pilot_states["departed-0"].player, private_state) and _equal(Arena._capture_flight(arena.pilots["departed-0"].flight), private_flight), "Shared simulation advanced private HP/respawn/flight of disconnected pilot")
	print("Arena wire budget22departed+2active: ", JSON.stringify({"op": "snapshot", "state": public_state}).to_utf8_buffer().size(), "bytes")


func _equal(left: Variant, right: Variant) -> bool:
	if (left is int or left is float) and (right is int or right is float):
		return absf(float(left) - float(right)) <= maxf(0.000000001, absf(float(left)) * 0.000000000000001)
	if left is Dictionary and right is Dictionary:
		if left.size() != right.size():
			return false
		for key: Variant in left:
			if not right.has(key) or not _equal(left[key], right[key]):
				return false
		return true
	if left is Array and right is Array:
		if left.size() != right.size():
			return false
		for index in range(left.size()):
			if not _equal(left[index], right[index]):
				return false
		return true
	return left == right
