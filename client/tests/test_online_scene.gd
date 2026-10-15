extends SceneTree
## Production main/OnlineView against a real separate dedicated ServerApp.
## No online HP, damage, poses, rewards or actor events are injected.
const Wire = preload("res://scripts/online/json_wire.gd")
const SAVE_PATH := "user://test-online-scene-offline.json"
var scene: Node3D
var checks := 0
var failures: Array[String] = []
var fixture: Dictionary = {}
var fixture_path := ""
var capture_path := ""
var peer: WebSocketPeer
var peer_ready := false
var peer_hello := false
var peer_state: Dictionary = {}
var capture_written := false
var measured_input_hz := 0.0
var offline_checkpoint: Dictionary = {}
var offline_inventory: Dictionary = {}
var offline_elapsed := 0.0
var menu_observation:Dictionary={}
var initial_draw_seconds:=0.0


func _initialize() -> void:
	for argument:String in OS.get_cmdline_user_args():
		if argument.begins_with("--fixture="):fixture_path=argument.trim_prefix("--fixture=")
		if argument.begins_with("--capture="):capture_path=argument.trim_prefix("--capture=")
	_run.call_deferred()


func _run() -> void:
	root.size=Vector2i(1440,900)
	_check(not fixture_path.is_empty() and FileAccess.file_exists(fixture_path),"private server fixture is present")
	if failures.is_empty():
		_check((FileAccess.get_unix_permissions(fixture_path)&511)==384,"ephemeral invitation fixture has0600 permissions")
		var parsed:Variant=JSON.parse_string(FileAccess.get_file_as_string(fixture_path))
		DirAccess.remove_absolute(fixture_path) # Invitations remain only in memory before any connection.
		if parsed is Dictionary:fixture=parsed
		_check(fixture.get("pilots") is Array and fixture.pilots.size()==2 and fixture.get("url") is String,"fixture contains exactly two isolated pilots")
	if not failures.is_empty():
		await _finish()
		return
	for suffix:String in ["",".bak",".tmp"]:DirAccess.remove_absolute(SAVE_PATH+suffix)
	var draw_started:=Time.get_ticks_msec()
	scene=(load("res://main.tscn") as PackedScene).instantiate()
	root.add_child(scene)
	scene.set_physics_process(false)
	scene.set_process(false)
	scene._save_path=SAVE_PATH
	scene._progress_enabled=false
	scene.is_paused=true
	await process_frame
	# A real user cannot authenticate until the initial window has drawn. Let
	# llvmpipe compile the native world's first-frame shaders before network clocks.
	if DisplayServer.get_name()!="headless":await RenderingServer.frame_post_draw
	await process_frame
	initial_draw_seconds=(Time.get_ticks_msec()-draw_started)/1000.0
	_check(scene._combat_ready and is_instance_valid(scene.online_view),"production scene initializes native world/combat and OnlineView")
	if not scene._combat_ready or not is_instance_valid(scene.online_view):
		await _finish()
		return
	_close_modals()
	offline_checkpoint=scene._capture_local_progress().duplicate(true)
	offline_inventory=scene.combat_runtime.inventory.export_state().duplicate(true)
	offline_elapsed=scene.combat_runtime.model.elapsed
	_check(bool(scene._save_local_game(false).get("ok",false)),"offline profile checkpoint can be saved before entering online mode")
	var saved_hash:=FileAccess.get_sha256(SAVE_PATH)
	var auth_fail:Dictionary=scene.online_view.connect_online(fixture.url,"f".repeat(64))
	_check(bool(auth_fail.get("ok",false)),"real invalid-credential attempt begins through production OnlineView")
	await _wait_until(func()->bool:return not scene.is_online_active(),12.0)
	if scene.is_online_active() or scene.online_view.client.snapshot().status!="error":
		print("ONLINE_SCENE_DIAGNOSTIC="+JSON.stringify({"stage":"invalid_auth","view":scene.online_view.snapshot(),"client":scene.online_view.client.snapshot(),"client_processing":scene.online_view.client.is_processing(),"loading":scene._loading_progress,"paused":scene.is_paused}))
	_check(not scene.is_online_active() and scene.online_view.client.snapshot().status=="error","authentication failure exits online mode and restores offline authority")
	_check(_same_offline_profile() and FileAccess.get_sha256(SAVE_PATH)==saved_hash,"authentication failure leaves offline inventory, flight and save unchanged")
	var connected:Dictionary=scene.online_view.connect_online(fixture.url,str(fixture.pilots[0].token))
	if not bool(connected.get("ok",false)):
		print("ONLINE_SCENE_DIAGNOSTIC="+JSON.stringify({"stage":"valid_connect","result":connected,"view":scene.online_view.snapshot()}))
	_check(bool(connected.get("ok",false)) and scene.is_online_active(),"authority changes before production connection/authentication callbacks")
	_check(not bool(scene._save_local_game(false).get("ok",true)),"even the connecting state cannot write an online session to offline save")
	await _wait_until(func()->bool:return bool(scene.online_view.snapshot().ready),10.0)
	_check(bool(scene.online_view.snapshot().ready) and scene.online_view.client.is_connected_to_server(),"real server snapshot reaches production view and passes native DTO validation")
	if not bool(scene.online_view.snapshot().ready):
		await _finish()
		return
	scene.set_physics_process(true)
	scene.set_process(true)
	scene._progress_enabled=true # Exercise actual autosave guards while active.
	await _connect_second()
	await _wait_until(func()->bool:return int(scene.online_view.snapshot().player_count)==2 and scene.online_view._peers.size()==1,5.0)
	_check(peer_ready and int(scene.online_view.snapshot().player_count)==2 and scene.online_view._peers.size()==1,"second real pilot becomes a native GEAR peer visual")
	_check(scene.current_map_id==3002 and scene.model.gear_id=="12003100" and scene.online_view._state.targets.size()==3,"server chooses actual map3002/I-GEAR and three shared NPCs")
	_check(scene.combat_runtime._remote_targets.size()==3,"production combat presentation instantiates all three native NPC models")
	var original_actors:=true
	for node:Node in scene.combat_runtime._remote_targets.values():
		original_actors=original_actors and not str(node.get_meta("original_resource_path","")).is_empty()
	_check(original_actors,"remote NPC presentation uses converted original resources")
	_check(not str(scene.ship.get_meta("original_resource_path","")).is_empty(),"player ship uses actual native GEAR resource")
	_check(scene.legacy_hud.is_online_active() and str(scene.legacy_hud._vital_labels[4].text)==str(roundi(float(scene.online_view._self.sp))),"blue HUD SP value is sourced from server snapshot")
	var fuel:Dictionary=scene.online_view._self.flight.get("fuel",{})
	_check(bool(fuel.get("configured",false)) and str(scene.legacy_hud._vital_labels[6].text)==str(roundi(float(fuel.get("current",-1)))),"blue HUD fuel uses actual server EP rather than inventing a percentage value")
	var skill_buttons:Array=scene.legacy_hud._skill_buttons
	_check(not skill_buttons.is_empty() and skill_buttons[0].icon!=null,"server-provided native skill resolves to a real quickbar icon")
	var sequence_before:int=scene.online_view.snapshot().input_seq
	var time_before:=Time.get_ticks_msec()
	await _pump(1.1)
	var span:float=(Time.get_ticks_msec()-time_before)/1000.0
	measured_input_hz=(int(scene.online_view.snapshot().input_seq)-sequence_before)/span
	_check(measured_input_hz>1.0 and measured_input_hz<=33.0,"production frame/physics loop bounds outgoing input sequence to30Hz")
	_check(scene.combat_runtime.model.elapsed==offline_elapsed and scene.combat_runtime.inventory.export_state()==offline_inventory,"online frame loop does not advance local combat or mutate offline inventory")
	var server_sp:float=scene.online_view._self.sp
	if server_sp>0 and not skill_buttons[0].disabled:
		_action("skill_slot_1")
		await _wait_until(func()->bool:return float(scene.online_view._self.get("sp",server_sp))<server_sp,3.0)
		_check(float(scene.online_view._self.get("sp",server_sp))<server_sp,"production skill shortcut debits actual server SP")
	else:
		_check(false,"a recovered initial skill is usable in the real arena")
	_action("cycle_gear")
	scene._cycle_gear()
	scene._on_local_action("equip_item:engine:7002590")
	scene._on_local_action("travel_map:2001")
	_action("save_local_game")
	_action("load_local_game")
	_check(scene.model.gear_id=="12003100" and scene.current_map_id==3002 and scene.combat_runtime.inventory.export_state()==offline_inventory,"F2/equip/travel shortcuts cannot alter authoritative class or offline inventory")
	_check(not bool(scene._save_local_game(false).get("ok",true)) and not bool(scene._load_local_game().get("ok",true)),"direct save/load entry points remain guarded during online session")
	scene._process(31.0)
	_check(FileAccess.get_sha256(SAVE_PATH)==saved_hash and not FileAccess.file_exists(SAVE_PATH+".bak"),"real autosave interval cannot replace or back up offline checkpoint with server state")
	_action("toggle_world")
	_check(scene.legacy_hud.is_world_panel_open(),"M opens production library while online")
	scene.legacy_hud._select_library_tab("online")
	var tick_before:int=scene.online_view.snapshot().tick
	var peer_tick_before:int=peer_state.get("tick",-1)
	var elapsed_before:float=scene.online_view._state.elapsed
	var targets_before:Variant=scene.online_view._state.targets.duplicate(true)
	var ammo_before:int=scene.online_view._self.primary_ammo
	Input.action_press("boost")
	Input.action_press("pitch_up")
	scene._primary_held=true
	scene._secondary_held=true
	scene._target_next=true
	await _wait_until(func()->bool:return int(scene.online_view.snapshot().tick)>tick_before+30 and int(peer_state.get("tick",-1))>peer_tick_before+30,3.0)
	var menu_tick:int=scene.online_view.snapshot().tick
	var npc_positions_changed:bool=scene.online_view._state.targets!=targets_before
	var npc_speeds:Array=[]
	var own_npcs:Array=[]
	var peer_npcs:Array=[]
	for target:Dictionary in scene.online_view._state.targets:
		npc_speeds.append((target.velocity as Vector3).length())
		own_npcs.append([int(target.id),int(target.monster_code)])
	for target:Dictionary in peer_state.get("targets",[]):peer_npcs.append([int(target.id),int(target.monster_code)])
	menu_observation={"tick_before":tick_before,"tick_after":menu_tick,"elapsed_before":elapsed_before,"elapsed_after":scene.online_view._state.elapsed,"targets_changed":npc_positions_changed,"native_npc_speeds":npc_speeds,"peer_tick_before":peer_tick_before,"peer_tick_after":peer_state.get("tick",-1)}
	_check(menu_tick>tick_before+30 and float(scene.online_view._state.elapsed)>elapsed_before,"M menu keeps the real shared server clock and simulation advancing")
	_check(int(peer_state.get("tick",-1))>peer_tick_before+30 and own_npcs.size()==3 and own_npcs==peer_npcs,"independent second pilot also receives advancing snapshots for the same three shared native NPCs while M is open")
	_check(not bool(scene.online_view._self.flight.get("boosting",true)) and int(scene.online_view._self.primary_ammo)==ammo_before,"M masks held booster/weapons instead of pausing server or submitting active controls")
	Input.action_release("boost")
	Input.action_release("pitch_up")
	scene._primary_held=false
	scene._secondary_held=false
	scene._target_next=false
	_check(_snapshot_has_no_tokens(scene.online_view.snapshot()) and scene.legacy_hud._online_token.text.is_empty(),"public status and visible credential field contain no invitation token")
	await _capture()
	_action("toggle_world")
	var old_sequence:int=scene.online_view.snapshot().input_seq
	scene.set_physics_process(false)
	scene.set_process(false)
	scene.online_view.disconnect_online()
	_check(not scene.is_online_active() and _same_offline_profile(),"disconnect restores full offline checkpoint and original paused state")
	_check(FileAccess.get_sha256(SAVE_PATH)==saved_hash and scene.combat_runtime.inventory.export_state()==offline_inventory,"disconnect preserves original offline save and inventory exactly")
	var reconnect:Dictionary=scene.online_view.connect_online(fixture.url,str(fixture.pilots[0].token))
	_check(bool(reconnect.get("ok",false)),"same production view can reconnect")
	await _wait_until(func()->bool:return bool(scene.online_view.snapshot().ready),5.0)
	_check(bool(scene.online_view.snapshot().ready) and int(scene.online_view.snapshot().input_seq)>=old_sequence and scene.online_view.snapshot().pilot_id==fixture.pilots[0].id,"reconnect restores server identity and sequence without resetting local profile")
	scene.online_view.disconnect_online()
	_check(_same_offline_profile() and FileAccess.get_sha256(SAVE_PATH)==saved_hash,"second disconnect again restores offline checkpoint without granting server progress")
	await _pump(0.15)
	var exit_session:Dictionary=scene.online_view.connect_online(fixture.url,str(fixture.pilots[0].token))
	_check(bool(exit_session.get("ok",false)),"production scene can enter the final close-while-online fixture")
	await _wait_until(func()->bool:return bool(scene.online_view.snapshot().ready),5.0)
	_check(bool(scene.online_view.snapshot().ready),"close fixture has a real authenticated server snapshot")
	var exiting:Node=scene
	scene.queue_free()
	await exiting.tree_exited
	await process_frame
	scene=null
	var quit_saved_hash:=FileAccess.get_sha256(SAVE_PATH)
	var quit_has_backup:=FileAccess.file_exists(SAVE_PATH+".bak")
	if quit_saved_hash!=saved_hash or quit_has_backup:print("ONLINE_SCENE_DIAGNOSTIC="+JSON.stringify({"stage":"quit","same_save":quit_saved_hash==saved_hash,"backup_created":quit_has_backup}))
	_check(quit_saved_hash==saved_hash and not quit_has_backup,"quitting the production scene while online never autosaves server state over offline profile")
	await _finish()


func _action(name:String) -> void:
	var event:=InputEventAction.new()
	event.action=name
	event.pressed=true
	scene._unhandled_input(event)


func _close_modals() -> void:
	if scene.legacy_hud.is_world_panel_open():scene.legacy_hud.toggle_world_panel()
	if scene.legacy_hud.inventory_items.visible:scene.legacy_hud.toggle_inventory()
	if is_instance_valid(scene.legacy_hud._help_panel):scene.legacy_hud._help_panel.hide()
	scene.legacy_hud._chat_input.release_focus()


func _same_offline_profile() -> bool:
	if not is_instance_valid(scene) or scene.is_online_active():return false
	var current:Dictionary=scene._capture_local_progress().duplicate(true)
	var expected:Dictionary=offline_checkpoint.duplicate(true)
	# Existing offline checkpoint semantics regenerate local encounters. Their new
	# life epoch is not character progress; every saved player/resource field remains exact.
	current.combat.erase("encounter_serial")
	expected.combat.erase("encounter_serial")
	return JSON.stringify(current,"",true)==JSON.stringify(expected,"",true) and scene.is_paused


func _connect_second() -> void:
	peer=WebSocketPeer.new()
	peer.inbound_buffer_size=32768
	peer.outbound_buffer_size=32768
	peer.connect_to_url(fixture.url)
	await _wait_until(func()->bool:return peer_hello,3.0)
	peer.send_text(Wire.encode({"op":"auth","protocol":Wire.PROTOCOL,"token":fixture.pilots[1].token}))
	await _wait_until(func()->bool:return peer_ready,3.0)


func _pump(duration:float) -> void:
	var deadline:=Time.get_ticks_msec()+int(duration*1000)
	while true:
		if peer!=null:
			peer.poll()
			while peer.get_available_packet_count()>0:
				var message:=Wire.decode(peer.get_packet())
				if message.is_empty():continue
				match str(message.op):
					"hello":peer_hello=true
					"auth_ok":peer_ready=true
					"snapshot":peer_state=message.state
		if Time.get_ticks_msec()>=deadline:return
		await create_timer(0.01).timeout


func _wait_until(predicate:Callable,duration:float) -> bool:
	var deadline:=Time.get_ticks_msec()+int(duration*1000)
	while not bool(predicate.call()) and Time.get_ticks_msec()<deadline:await _pump(0.02)
	return bool(predicate.call())


func _snapshot_has_no_tokens(value:Variant) -> bool:
	var text:=JSON.stringify(value)
	for pilot:Dictionary in fixture.get("pilots",[]):
		if text.contains(str(pilot.token)):return false
	return true


func _capture() -> void:
	if capture_path.is_empty():return
	if DisplayServer.get_name()=="headless":
		_check(false,"requested visual capture requires an actual GL display")
		return
	await RenderingServer.frame_post_draw
	var image:=root.get_texture().get_image()
	_check(image!=null and not image.is_empty(),"real OpenGL viewport capture is available")
	if image!=null and not image.is_empty():
		capture_written=image.save_png(capture_path)==OK
		_check(capture_written,"connected native arena/HUD screenshot is saved without credentials")


func _finish() -> void:
	Input.action_release("boost")
	Input.action_release("pitch_up")
	if peer!=null and peer.get_ready_state()==WebSocketPeer.STATE_OPEN:peer.close(1000,"fixture_done")
	if is_instance_valid(scene):
		scene.set_physics_process(false)
		scene.set_process(false)
		scene._progress_enabled=false
		if scene.is_online_active():scene.online_view.disconnect_online()
		scene.queue_free()
		await process_frame
	await process_frame # Flush queued native visual deletion before rendering-server shutdown.
	for suffix:String in ["",".bak",".tmp"]:DirAccess.remove_absolute(SAVE_PATH+suffix)
	print("ONLINE_SCENE_E2E="+JSON.stringify({"checks":checks,"failures":failures,"real_server":true,"production_main":true,"online_state_not_injected":true,"input_hz":measured_input_hz,"display":DisplayServer.get_name(),"capture_written":capture_written,"tokens_logged":false,"initial_draw_seconds":initial_draw_seconds,"menu_clock":menu_observation}))
	for failure:String in failures:printerr(failure)
	quit(0 if failures.is_empty() else 1)


func _check(value:bool,label:String) -> void:
	checks+=1
	if not value:failures.append(label)
