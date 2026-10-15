extends SceneTree
const View = preload("res://scripts/online/online_view.gd")
const Arena = preload("res://scripts/online/arena_model.gd")
const World = preload("res://scripts/online/headless_world.gd")
const CombatScene = preload("res://scripts/combat_runtime.gd")
const Main = preload("res://scripts/main.gd")
const Flight = preload("res://scripts/flight_model.gd")
const NativeInventory = preload("res://scripts/inventory_model.gd")

class ActiveStub extends Node:
	var active := true
	var _checkpoint := {"marker":"offline_only"}
	var ticks := 0
	func physics_tick(_delta: float) -> void: ticks += 1

class HUDStub extends CanvasLayer:
	var public_state: Dictionary = {}
	var systems_state: Dictionary = {}
	func set_online_state(value: Dictionary) -> void: public_state=value
	func set_systems_state(value: Dictionary) -> void: systems_state=value
	func append_system_note(_message: String) -> void: pass
	func wants_keyboard() -> bool: return false
	var masked := true
	func blocks_weapons() -> bool: return masked

class InputClient extends Node:
	signal status_changed(status: String)
	signal snapshot_received(state: Dictionary)
	signal event_received(event: Dictionary)
	signal command_result(result: Dictionary)
	var inputs: Array = []
	var commands: Array = []
	func snapshot() -> Dictionary: return {"status":"connected","pilot_id":"pilot-a"}
	func is_connected_to_server() -> bool: return true
	func send_input(seq: int, controls: Dictionary) -> bool:
		inputs.append({"seq":seq,"controls":controls});return true
	func command(id: String, action: String, args: Dictionary) -> bool:
		commands.append({"request_id":id,"action":action,"args":args});return true

class SystemsStub extends Node:
	var suspended := false
	func suspend_for_online(value: bool) -> void: suspended=value

class GameStub extends Node3D:
	var model = Flight.new()
	var ship: Node3D
	var camera: Camera3D
	var legacy_hud: CanvasLayer
	var systems: Node
	var combat_runtime: Node3D
	var _combat_ready := true
	var _loading_progress := false
	var _primary_held := true
	var _secondary_held := true
	var _target_next := true
	var is_paused := true
	var _autosave_time := 25.0
	var _library_revision := 0
	var current_map_id := 3002
	var rings: Array[Node3D] = []
	var captures := 0
	var restores := 0
	var restored: Dictionary = {}
	func _ready() -> void:
		ship=Node3D.new();add_child(ship)
		camera=Camera3D.new();add_child(camera)
		legacy_hud=HUDStub.new();add_child(legacy_hud)
		systems=SystemsStub.new();add_child(systems)
		combat_runtime=CombatScene.new();add_child(combat_runtime)
		model.load_gear_profile("12003100")
	func _capture_local_progress() -> Dictionary:
		captures+=1
		return {"marker":"offline_only","credits":731}
	func _restore_local_progress(value: Dictionary) -> Dictionary:
		restores+=1;restored=value.duplicate(true)
		return {"ok":true}
	func _update_hud() -> void: pass
	func _aim_position() -> Vector2: return Vector2(480,300)

var checks:=0
var failures:Array[String]=[]
func _initialize()->void: run.call_deferred()
func run()->void:
	var world=World.new()
	check(world.configure(),"headless original world loads without renderer")
	var arena=Arena.new()
	check(arena.configure({"map_index":3002,"max_players":2},world),"real server arena configures")
	check(arena.add_player("pilot-a").ok and arena.add_player("pilot-b").ok,"two native I-GEAR profiles join")
	check(arena.submit_input("pilot-a",123,{}).ok,"server remembers input sequence independently of transport")
	var raw:Dictionary=arena.snapshot("pilot-a")
	var native=NativeInventory.new()
	check(native.configure(),"client resolves the complete native catalog independently of the server's minimal starter catalog")
	var parsed:Dictionary=View.decode_snapshot(raw,"pilot-a",native.catalog,native._icons)
	if not parsed.ok: print("DTO_REJECTION ",parsed)
	check(parsed.ok,"production arena snapshot passes typed client boundary")
	if parsed.ok:
		check(parsed.data.player.position is Vector3 and parsed.data.player.orientation is Quaternion,"wire arrays become engine vectors and quaternions")
		check(parsed.data.targets[0].position is Vector3 and parsed.data.targets[0].velocity is Vector3,"NPC visual poses are typed without local simulation")
		check(parsed.data.input_seq==123 and parsed.data.pilots.size()==2,"server sequence and peer list survive decoding")
		check(parsed.data.skills.hotbar.size()==8 and parsed.data.inventory.credits==arena.pilots["pilot-a"].inventory.credits,"skill and inventory HUD follow server models")
		check(not parsed.data.skills.rows.is_empty() and parsed.data.skills.assignment_available and parsed.data.skills.rows[0].learned and not parsed.data.skills.rows[0].learnable,"only server-owned native learned ranks populate the assignable online skills list")
	var classes=Arena.new()
	check(classes.configure({"map_index":3002,"max_players":4},world),"four-class presentation arena configures")
	for gear_id: String in View.GEAR_IDS:
		var pilot_id := "class-" + gear_id
		check(classes.add_player(pilot_id, {}, gear_id).ok,"server creates selected class " + gear_id)
		var class_wire: Dictionary = classes.snapshot(pilot_id)
		var class_view: Dictionary = View.decode_snapshot(class_wire,pilot_id,native.catalog,native._icons)
		check(class_view.ok and class_view.data.player.gear_id==gear_id and class_view.data.inventory.gear_id==gear_id and class_view.data.player.flight.gear_id==gear_id,"typed presentation preserves server class, flight and inventory " + gear_id)
		if gear_id == "12002100":
			for mode: String in ["landing", "taking_off", "ground", "siege"]:
				for pilot: Dictionary in class_wire.pilots:
					if pilot.pilot_id==pilot_id: pilot.flight.mode=mode
				check(View.decode_snapshot(class_wire,pilot_id,native.catalog,native._icons).ok,"A-GEAR presentation accepts authoritative " + mode)
	var bad:=raw.duplicate(true);bad.pilots[0].orientation=[0,0,0,0]
	check(not View.decode_snapshot(bad,"pilot-a",native.catalog,native._icons).ok,"degenerate orientation fails closed")
	bad=raw.duplicate(true);bad.map_index=2001
	check(not View.decode_snapshot(bad,"pilot-a",native.catalog,native._icons).ok,"arena cannot inject another map")
	bad=raw.duplicate(true);bad.pilots[0].gear_id="12000100"
	check(not View.decode_snapshot(bad,"pilot-a",native.catalog,native._icons).ok,"private inventory and pilot cannot disagree about the selected GEAR class")
	bad=raw.duplicate(true);bad.pilots[0].gear_id="unrecognized-class"
	check(not View.decode_snapshot(bad,"pilot-a",native.catalog,native._icons).ok,"unknown GEAR class is rejected")
	bad=raw.duplicate(true);bad.self.skills.learned_rows[0].id=-1
	check(not View.decode_snapshot(bad,"pilot-a",native.catalog,native._icons).ok,"unknown learned identities fail closed before exposing skill assignment")
	bad=raw.duplicate(true);bad.self.skills.hotbar[0].cooldown=-1
	check(not View.decode_snapshot(bad,"pilot-a",native.catalog,native._icons).ok,"negative remote skill timers fail closed")
	var capability_wire := raw.duplicate(true)
	capability_wire.self.inventory.equip_available=true
	capability_wire.self.inventory.allocate_stats_available=true
	var manageable: Dictionary = View.decode_snapshot(capability_wire,"pilot-a",native.catalog,native._icons)
	check(manageable.ok and manageable.data.inventory.equip_available and manageable.data.inventory.allocate_stats_available,"explicit server capabilities survive the typed equipment boundary")
	bad=capability_wire.duplicate(true);bad.self.inventory.entries[0].equippable_slots=["administrator"]
	check(not View.decode_snapshot(bad,"pilot-a",native.catalog,native._icons).ok,"unknown remote equipment slots fail closed")
	bad=capability_wire.duplicate(true);bad.self.inventory.entries[0].equippable_slots=["radar"]
	check(not View.decode_snapshot(bad,"pilot-a",native.catalog,native._icons).ok,"a remote equipment slot cannot override immutable native item position")
	bad=capability_wire.duplicate(true);bad.self.inventory.stat_cap=1000001
	check(not View.decode_snapshot(bad,"pilot-a",native.catalog,native._icons).ok,"unbounded remote stat caps fail closed")
	bad=raw.duplicate(true);bad.self.pilot_id="other"
	check(not View.decode_snapshot(bad,"pilot-a",native.catalog,native._icons).ok,"private inventory is bound to authenticated pilot")
	bad=raw.duplicate(true);bad.self.inventory.entries[0].icon_path="user://private-file"
	var safe:Dictionary=View.decode_snapshot(bad,"pilot-a",native.catalog,native._icons)
	check(safe.ok and not JSON.stringify(safe.data.inventory).contains("private-file"),"server paths cannot replace native item artwork bindings")
	bad=raw.duplicate(true);bad.self.inventory.entries[0].item_num=-1
	check(not View.decode_snapshot(bad,"pilot-a",native.catalog,native._icons).ok,"unknown item identities fail closed")
	var neutral:Dictionary=View.input_controls(true,Vector3(0,0,-10),true,true,true)
	check(neutral.pitch==0 and neutral.roll==0 and neutral.yaw==0 and not neutral.primary and not neutral.secondary and not neutral.target_next and not neutral.boost,"modal input neutralizes movement, weapons and target selection")
	check(neutral.ground_throttle==0 and not neutral.has("unit_stop"),"modal input neutralizes ground movement without inventing a unit-stop key")
	for action: String in ["pitch_up", "pitch_down", "roll_left", "roll_right", "yaw_left", "yaw_right", "boost", "brake"]:
		if not InputMap.has_action(action): InputMap.add_action(action)
	Input.action_press("pitch_up", 1.0)
	var drive: Dictionary = View.input_controls(false, Vector3.FORWARD, false, false, false)
	check(drive.ground_throttle==1.0 and drive.pitch==1.0,"W/S pitch axis also drives authoritative A-GEAR ground throttle")
	Input.action_release("pitch_up")
	check(neutral.aim_direction==[0.0,0.0,-1.0] and not neutral.has("position") and not neutral.has("aim_origin"),"input carries normalized direction only; server owns origin")
	var runtime=CombatScene.new();root.add_child(runtime)
	var elapsed:float=runtime.model.elapsed
	runtime.set_remote_mode(true)
	runtime.apply_remote_presentation([],[],{"hp":87,"available":true})
	runtime.advance(1.0,{"primary":true},{})
	check(runtime.snapshot().hp==87 and runtime.model.elapsed==elapsed,"remote presentation never advances CombatModel")
	runtime.set_remote_mode(false)
	check(not runtime.snapshot().get("available",false),"leaving remote mode restores local presentation source")
	runtime.queue_free()
	var main=Main.new();var stub=ActiveStub.new();main.online_view=stub
	main.world_runtime=Node.new();main.combat_runtime=CombatScene.new()
	check(main.is_online_active(),"production Main recognizes connecting authority mode")
	main._physics_process(1.0)
	check(stub.ticks==1,"production Main physics exits through online input branch")
	check(main._save_local_game().error=="online_profile_separate" and main._load_local_game().error=="online_profile_separate","manual offline persistence is refused while arena is active")
	check(main._capture_local_progress().marker=="offline_only","checkpoint capture cannot serialize remote progress")
	main.world_runtime.free();main.combat_runtime.free();stub.free();main.free()
	var game=GameStub.new();root.add_child(game);await process_frame
	var old_model=game.model
	var view=View.new();game.add_child(view);view.setup(game)
	var started:Dictionary=view.connect_online("ws://127.0.0.1:1/play","not-a-real-credential")
	if started.ok:
		check(view.active and game._loading_progress and game.systems.suspended,"real OnlineClient starts authority before network authentication")
		check(game.restores==0,"connect_to internal offline reset cannot restore checkpoint prematurely")
		check(game.model!=old_model and game.captures==1,"presentation gets a separate model and one offline checkpoint")
		check(not game._primary_held and not game._secondary_held,"held weapons are cleared on mode transition")
		view.disconnect_online()
		check(not view.active and game.model==old_model and game.restores==1,"disconnect restores the exact offline model and checkpoint once")
		check(game.restored.marker=="offline_only" and game.restored.credits==731 and not game._loading_progress and not game.systems.suspended,"offline balance and persistence guard recover without saving remote state")
		check(game.is_paused and game._autosave_time==0,"offline pause resumes and autosave clock restarts")
	else:
		check(game.restores==1 and not view.active,"immediate transport rejection restores offline safely")
	view._visual_signature="previous-session-armor"
	var rejoin:Dictionary=view.connect_online("ws://127.0.0.1:1/play","not-a-real-credential")
	check(view._visual_signature.is_empty(),"reconnection invalidates the previous GEAR visual signature")
	if rejoin.ok: view.disconnect_online()
	var counter=InputClient.new()
	var input_view=View.new();game.add_child(input_view);input_view.setup(game,counter)
	input_view._state={"tick":0}
	input_view._input_sequence=int(parsed.data.input_seq) if parsed.ok else 123
	input_view.active=true
	for _step in range(120): input_view.physics_tick(1.0/120.0)
	check(counter.inputs.size()==30 and counter.inputs[0].seq==124 and counter.inputs.back().seq==153,"input sends at30Hz and resumes strictly after the server's persisted sequence")
	check(not counter.inputs.is_empty() and not counter.inputs[0].controls.primary and not counter.inputs[0].controls.secondary,"production input cadence stays neutral while a modal is open")
	game.legacy_hud.masked=false
	check(input_view.cast_skill(1) and counter.commands.back().action=="skill_use" and counter.commands.back().args.slot==1,"skill activation emits an authoritative command instead of changing the local model")
	check(input_view.handle_action("skill_assign:8:7830011") and counter.commands.back().action=="skill_assign" and counter.commands.back().args=={"slot":8,"item_num":7830011},"assignment action is forwarded as an authoritative command")
	check(input_view.toggle_landing() and counter.commands.back().action=="toggle_landing" and input_view.toggle_siege() and counter.commands.back().action=="toggle_siege","landing and siege request server validation without local flight changes")
	input_view._inventory=manageable.data.inventory.duplicate(true)
	var owned_item: Dictionary={}
	for entry: Dictionary in input_view._inventory.entries:
		if not entry.equippable_slots.is_empty(): owned_item=entry;break
	check(not owned_item.is_empty() and input_view.handle_action("equip_item:%s:%s" % [owned_item.equippable_slots[0],owned_item.item_num]) and counter.commands.back().action=="equip" and counter.commands.back().args=={"slot":owned_item.equippable_slots[0],"item_num":owned_item.item_num},"owned-item selection routes an authoritative equip command with the native slot")
	input_view._inventory.bonus_stats=2
	check(input_view.handle_action("allocate_stat:attack:1") and counter.commands.back().action=="allocate_stat" and counter.commands.back().args=={"stat":"attack","count":1} and input_view._inventory.bonus_stats==2,"attribute action routes a server command without spending client points")
	var before_commands: int=counter.commands.size()
	check(not input_view.equip_item("radar",-1) and not input_view.equip_item("radar",2147483647) and not input_view.allocate_stat("attack",3) and counter.commands.size()==before_commands,"invalid identities and excessive point requests cannot emit a client command")
	input_view.active=false
	game.queue_free();await process_frame
	for failure:String in failures: push_error(failure)
	print(JSON.stringify({"suite":"online_view","status":"pass" if failures.is_empty() else "fail","checks":checks,"failures":failures.size()}))
	quit(0 if failures.is_empty() else 1)
func check(ok:bool,message:String)->void:
	checks+=1
	if not ok: failures.append(message)
