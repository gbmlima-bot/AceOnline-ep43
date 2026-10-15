extends SceneTree
## Starts TWO independent Godot processes over localhost; no game assets needed.
const Network = preload("res://scripts/local_multiplayer.gd")

var _checks := 0
var _failures: Array[String] = []
var _network: Node
var _role := ""
var _port := 0
var _result := ""
var _ready_path := ""


func _initialize() -> void:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--role="): _role = argument.trim_prefix("--role=")
		if argument.begins_with("--port="): _port = int(argument.trim_prefix("--port="))
		if argument.begins_with("--result="): _result = argument.trim_prefix("--result=")
		if argument.begins_with("--ready="): _ready_path = argument.trim_prefix("--ready=")
	call_deferred("_run")


func _run() -> void:
	if _role.is_empty():
		await _orchestrate()
		return
	_network = Network.new()
	_network.name = "LocalMultiplayer"
	root.add_child(_network)
	_unit_validation()
	if _role == "host":
		await _host()
	else:
		await _client()
	_network.queue_free()
	await process_frame
	var result := {"suite": "multiplayer_" + _role, "checks": _checks, "failures": _failures}
	FileAccess.open(_result, FileAccess.WRITE).store_string(JSON.stringify(result))
	print(JSON.stringify(result))
	quit(0 if _failures.is_empty() else 1)


func _orchestrate() -> void:
	var socket := PacketPeerUDP.new()
	_check(socket.bind(0, "127.0.0.1") == OK, "localhost UDP test port can be reserved")
	_port = socket.get_local_port()
	socket.close()
	var directory := OS.get_cache_dir().path_join("ace-multiplayer-test-%d" % OS.get_process_id())
	DirAccess.make_dir_recursive_absolute(directory)
	var ready := directory.path_join("ready")
	var host_result := directory.path_join("host.json")
	var client_result := directory.path_join("client.json")
	var common := ["--headless", "--path", ProjectSettings.globalize_path("res://"), "--script", "res://tests/test_multiplayer.gd", "--", "--port=%d" % _port, "--ready=" + ready]
	var host_args := common.duplicate()
	host_args.append_array(["--role=host", "--result=" + host_result])
	var host_pid := OS.create_process(OS.get_executable_path(), host_args)
	_check(host_pid > 0, "independent host process starts")
	var deadline := Time.get_ticks_msec() + 15000
	while not FileAccess.file_exists(ready) and Time.get_ticks_msec() < deadline and OS.is_process_running(host_pid):
		await create_timer(0.05).timeout
	_check(FileAccess.file_exists(ready), "host opened UDP socket before client launch")
	var client_args := common.duplicate()
	client_args.append_array(["--role=client", "--result=" + client_result])
	var client_pid := OS.create_process(OS.get_executable_path(), client_args)
	_check(client_pid > 0, "independent client process starts")
	deadline = Time.get_ticks_msec() + 25000
	while (OS.is_process_running(host_pid) or OS.is_process_running(client_pid)) and Time.get_ticks_msec() < deadline:
		await create_timer(0.05).timeout
	for identifier: int in [host_pid, client_pid]:
		if OS.is_process_running(identifier):
			OS.kill(identifier)
			_check(false, "network worker finishes without timeout")
	for path: String in [host_result, client_result]:
		_check(FileAccess.file_exists(path), "worker writes reproducible result")
		if FileAccess.file_exists(path):
			var value: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
			_check(value is Dictionary and value.get("failures", ["missing"]).is_empty(), "worker validations pass: " + path.get_file())
			if value is Dictionary:
				_checks += int(value.get("checks", 0))
	for path: String in [ready, host_result, client_result]:
		DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(directory)
	print(JSON.stringify({"suite": "multiplayer", "checks": _checks, "failures": _failures.size(), "independent_processes": 2, "transport": "ENet UDP localhost"}))
	for failure: String in _failures: push_error(failure)
	quit(0 if _failures.is_empty() else 1)


func _unit_validation() -> void:
	var good := _state("host", 3002)
	_check(not Network._validate_state(good).is_empty(), "valid native GEAR/pose accepted")
	var bad := good.duplicate(true)
	bad.peer_id = 1
	_check(Network._validate_state(bad).is_empty(), "self-selected peer identifier rejected")
	bad = good.duplicate(true)
	bad.position = [NAN, 0.0, 0.0]
	_check(Network._validate_state(bad).is_empty(), "non-finite positions rejected")
	bad.position = [0.0, INF, 0.0]
	_check(Network._validate_state(bad).is_empty(), "infinite positions rejected")
	bad.position = [2000001.0, 0.0, 0.0]
	_check(Network._validate_state(bad).is_empty(), "out-of-bounds position rejected")
	bad = good.duplicate(true)
	bad.speed = "160"
	_check(Network._validate_state(bad).is_empty(), "numeric-looking string speed rejected")
	bad = good.duplicate(true)
	bad.map_index = 0
	_check(Network._validate_state(bad).is_empty(), "invalid map rejected")
	bad = good.duplicate(true)
	bad.gear_id = "res://malicious.gd"
	_check(Network._validate_state(bad).is_empty(), "arbitrary resource path cannot become a GEAR")
	bad = good.duplicate(true)
	bad.appearance_id = -1
	_check(Network._validate_state(bad).is_empty(), "invalid appearance rejected")
	bad = good.duplicate(true)
	bad.damage = 999999
	_check(Network._validate_state(bad).is_empty(), "pose protocol cannot carry combat or reward claims")
	bad = good.duplicate(true)
	bad.name = "x".repeat(25)
	_check(Network._validate_state(bad).is_empty(), "oversized display name rejected")
	_check(Network._validate_chat(" x\n\u0001 y ") == "x y", "chat removes control characters")
	_check(Network._validate_chat("x".repeat(281)).is_empty(), "oversized chat rejected")
	_check(Network._validate_chat({"text": "nested"}).is_empty(), "non-string chat rejected")
	_check(_network.host(1) == ERR_INVALID_PARAMETER, "privileged/invalid port rejected")
	_check(_network.join("https://example.org", _port) == ERR_INVALID_PARAMETER, "URL is not a LAN address")
	_check(not _network.publish_state(good), "offline publication is disabled")
	_check(not _network.send_chat("offline"), "offline message is not represented as delivered")
	_check(_network._take_rate(90, "unit", 1.0, 3.0) and _network._take_rate(90, "unit", 1.0, 3.0) and _network._take_rate(90, "unit", 1.0, 3.0) and not _network._take_rate(90, "unit", 1.0, 3.0), "token bucket caps a burst")
	_check(_network._take_rate(91, "unit", 1.0, 3.0), "rate limit is isolated per transport peer")
	_check(_network.join("127.0.0.1\n", _port) == OK, "edge whitespace in host field is safely trimmed")
	_network.leave()
	_check(_network.join("127.0\n.0.1", _port) == ERR_INVALID_PARAMETER, "embedded control character in address is rejected")


func _host() -> void:
	_check(_network.host(_port) == OK, "host opens ENet server")
	FileAccess.open(_ready_path, FileAccess.WRITE).store_string("ready")
	var greeted := false
	var approved := false
	var disconnected := false
	var finished := false
	var first_client := 0
	var deadline := Time.get_ticks_msec() + 20000
	while Time.get_ticks_msec() < deadline:
		_network.publish_state(_state("host", 3002))
		var current: Dictionary = _network.snapshot()
		for key: String in current.peers:
			if int(key) == 1: continue
			var other: Dictionary = current.peers[key]
			if not greeted:
				first_client = int(key)
				_check(other.peer_id == int(key) and other.name == "client", "real transport sender owns client pose")
				_check(other.position == [120.0, 105.0, -90.0] and other.gear_id == "12002100", "client pose and native GEAR cross process")
				greeted = _network.send_chat("host-hello")
			if other.map_index == 3303 and not approved and _has_chat(current, "client-hello"):
				_check(current.rejected_states >= 3, "host rejects malformed and spoofed remote states")
				_check(current.rejected_chats >= 1, "host rejects oversized remote chat")
				approved = _network.send_chat("host-approved")
			if disconnected and int(key) != first_client and _has_chat(current, "rejoined"):
				_check(true, "client reconnects with a fresh transport identity")
				finished = true
		if approved and not disconnected and current.peer_count == 1:
			_check(current.peers.size() == 1 and not current.peers.has(str(first_client)), "disconnect removes ghost pose and membership")
			disconnected = true
		if finished:
			_network.leave()
			break
		await create_timer(0.04).timeout
	_check(greeted and approved and disconnected and finished, "complete host visit/chat/reconnect exchange")
	await create_timer(0.25).timeout
	_check(_network.snapshot().peers.is_empty() and _network.snapshot().peer_count == 0, "host leave clears state")


func _client() -> void:
	_check(_network.join("127.0.0.1", _port) == OK, "client starts localhost connection")
	var sent := false
	var changed_map := false
	var rejoined := false
	var new_chat_sent := false
	var saw_host := false
	var closed := false
	var deadline := Time.get_ticks_msec() + 20000
	while Time.get_ticks_msec() < deadline:
		var current: Dictionary = _network.snapshot()
		if current.connected:
			_network.publish_state(_state("client", 3303 if changed_map else 3002))
		if current.peers.has("1") and not saw_host:
			var other: Dictionary = current.peers["1"]
			_check(other.name == "host" and other.map_index == 3002 and other.peer_id == 1, "host-authorized roster delivers host state")
			saw_host = true
		if not sent and _has_chat(current, "host-hello"):
			_check(_network.send_chat("client-hello"), "client sends real session chat")
			var spoof := _state("client", 3002)
			spoof.peer_id = 1
			_network._rpc_state.rpc_id(1, spoof)
			var invalid := _state("client", 3002)
			invalid.position = [NAN, 0, 0]
			_network._rpc_state.rpc_id(1, invalid)
			invalid = _state("client", 3002)
			invalid.map_index = "3002"
			_network._rpc_state.rpc_id(1, invalid)
			_network._rpc_chat.rpc_id(1, "x".repeat(281))
			_check(_network.send_chat("second") and _network.send_chat("third") and not _network.send_chat("fourth"), "local chat burst is bounded")
			sent = true
			changed_map = true
		if not rejoined and _has_chat(current, "host-approved"):
			_network.leave()
			_check(_network.snapshot().chat.is_empty() and _network.snapshot().peers.is_empty(), "client leave clears session data")
			await create_timer(0.3).timeout
			_check(_network.join("127.0.0.1", _port) == OK, "client can rejoin without restarting game")
			rejoined = true
		if rejoined and current.connected and current.peers.has(str(current.peer_id)) and not new_chat_sent:
			new_chat_sent = _network.send_chat("rejoined")
		if rejoined and current.status == "error":
			_check(current.peers.is_empty() and current.peer_count == 0 and not current.connected, "server disconnect clears client ghost state")
			closed = true
			break
		await create_timer(0.04).timeout
	_check(saw_host and sent and rejoined and new_chat_sent and closed, "complete client visit/chat/host-disconnect exchange")


func _state(role: String, map_index: int) -> Dictionary:
	return {"map_index": map_index, "gear_id": "12002100" if role == "client" else "12003100", "position": [120.0, 105.0, -90.0], "rotation": [0.1, 0.2, -0.3], "speed": 160.0, "name": role}


func _has_chat(value: Dictionary, text: String) -> bool:
	for entry: Dictionary in value.chat:
		if entry.text == text: return true
	return false


func _check(value: bool, label: String) -> void:
	_checks += 1
	if not value: _failures.append(label)
