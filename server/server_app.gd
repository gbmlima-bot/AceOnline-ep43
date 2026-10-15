extends Node
## One authoritative room, one SQLite writer, JSON/WSS at the edge.
const Store = preload("res://sqlite_store.gd")
const World = preload("res://scripts/online/headless_world.gd")
const Arena = preload("res://scripts/online/arena_model.gd")
const Transport = preload("res://scripts/online/ws_server.gd")
const PROTOCOL := "ace-pve/1"
const CHECKPOINT_SECONDS := 1.0
const MAX_COMMAND_ID := 128

var store = Store.new()
var world = World.new()
var room = Arena.new()
var transport: Node
var _health := TCPServer.new()
var _http_clients: Array[Dictionary] = []
var _sessions: Dictionary = {}
var _revision := 0
var _initialized := false
var _started_msec := 0
var _last_commit_msec := 0
var _snapshot_elapsed := 0.0
var _checkpoint_elapsed := 0.0
var _auth_recheck_elapsed := 0.0
var _snapshot_hz := 15.0
var _max_players := 2
var _data_dir := ""
var _stopping := false
var _shutdown_file := ""
var _config_valid := true
var _metrics := {"auth_rejected": 0, "commands": 0, "replayed_commands": 0, "inputs_rejected": 0, "commits": 0, "storage_failures": 0}


func _ready() -> void:
	_started_msec = Time.get_ticks_msec()
	_data_dir = OS.get_environment("ACE_DATA_DIR")
	if _data_dir.is_empty(): _data_dir = "user://server-data"
	var bind := OS.get_environment("ACE_BIND_ADDRESS")
	if bind.is_empty(): bind = "127.0.0.1"
	var port := _env_int("ACE_PORT", 9080, 1024, 65535)
	var health_port := _env_int("ACE_HEALTH_PORT", 9081, 1024, 65535)
	_max_players = _env_int("ACE_MAX_PLAYERS", 2, 1, 8)
	_snapshot_hz = float(_env_int("ACE_SNAPSHOT_HZ", 15, 5, 30))
	var map_id := _env_int("ACE_MAP_ID", 3002, 3002, 3002)
	_shutdown_file = OS.get_environment("ACE_SHUTDOWN_FILE")
	if not _config_valid: return
	if not store.open(_data_dir.path_join("ace-online.sqlite")):
		_fail_start("database_unavailable")
		return
	if not world.configure(map_id) or not room.configure({"room_id": "main", "map_index": map_id, "max_players": _max_players}, world):
		_fail_start("room_configuration_failed")
		return
	var saved: Dictionary = store.load_room("main")
	if not store.error_text.is_empty():
		_fail_start("database_room_read_failed")
		return
	if not saved.is_empty():
		_revision = int(saved.get("revision", 0))
		if not room.import_state(saved):
			_fail_start("persisted_room_invalid")
			return
	transport = Transport.new()
	transport.name = "OnlineTransport"
	add_child(transport)
	transport.connected.connect(_connected)
	transport.disconnected.connect(_disconnected)
	transport.message_received.connect(_message)
	if transport.start(port, bind) != OK or _health.listen(health_port, bind) != OK:
		_fail_start("listen_failed")
		return
	_initialized = true
	if not _commit(): return
	_log("server_ready", {"protocol": PROTOCOL, "map_index": map_id, "port": port, "health_port": health_port, "max_players": _max_players, "revision": _revision})
	get_tree().auto_accept_quit = false
	set_physics_process(true)


func _env_int(key: String, fallback: int, minimum: int, maximum: int) -> int:
	var value := OS.get_environment(key)
	if value.is_empty(): return fallback
	if not value.is_valid_int() or int(value) < minimum or int(value) > maximum:
		_config_valid = false
		push_error("Invalid server configuration: " + key)
		get_tree().quit(2)
		return fallback
	return int(value)


func _physics_process(delta: float) -> void:
	if not _initialized or _stopping: return
	if not _shutdown_file.is_empty() and FileAccess.file_exists(_shutdown_file):
		_shutdown()
		return
	room.advance(delta)
	_checkpoint_elapsed += delta
	var events: Array = room.drain_events()
	var critical := false
	for event: Dictionary in events:
		if str(event.get("type", "")) in ["pilot_reward", "target_destroyed", "player_died", "player_respawned", "command_result"]:
			critical = true
	# Motion dirties every tick; only rewards/deaths/commands require immediate durability.
	if critical or _checkpoint_elapsed >= CHECKPOINT_SECONDS:
		if not _commit(): return
	for event: Dictionary in events:
		_broadcast({"op": "event", "event": event})
	_snapshot_elapsed += delta
	if _snapshot_elapsed >= 1.0 / _snapshot_hz:
		_snapshot_elapsed = 0.0
		for connection_id: Variant in _sessions:
			_send_snapshot(int(connection_id))


func _process(delta: float) -> void:
	_poll_http()
	if not _initialized or _stopping: return
	_auth_recheck_elapsed += delta
	if _auth_recheck_elapsed >= 5.0:
		_auth_recheck_elapsed = 0.0
		for connection_id: Variant in _sessions.keys():
			var session: Dictionary = _sessions[connection_id]
			# Rotation disables an already-open session within five seconds.
			if not store.token_hash_active(str(session.pilot_id), str(session.token_hash)):
				transport.disconnect_peer(int(connection_id), "credential_revoked")


func _connected(connection_id: int) -> void:
	if not _initialized:
		transport.disconnect_peer(connection_id, "server_not_ready")
		return
	# Transport sends the protocol hello as soon as the WS handshake opens.


func _disconnected(connection_id: int) -> void:
	if not _sessions.has(connection_id): return
	var pilot_id := str(_sessions[connection_id].pilot_id)
	_sessions.erase(connection_id)
	room.remove_player(pilot_id)
	if _initialized and not _stopping: _commit()
	_log("pilot_left", {"pilot_id": pilot_id, "connected": _sessions.size()})


func _message(connection_id: int, message: Dictionary) -> void:
	if not _initialized or _stopping: return
	var op := str(message.get("op", ""))
	if not _sessions.has(connection_id):
		if op != "auth":
			transport.send_to(connection_id, {"op": "error", "code": "authentication_required", "message": "Autentique o piloto antes de enviar comandos."})
			return
		_authenticate(connection_id, message)
		return
	var pilot_id := str(_sessions[connection_id].pilot_id)
	match op:
		"input":
			if not message.get("seq") is int or not message.get("controls") is Dictionary:
				_metrics.inputs_rejected += 1
				return
			var accepted: Dictionary = room.submit_input(pilot_id, int(message.seq), message.controls)
			if not bool(accepted.get("ok", false)): _metrics.inputs_rejected += 1
		"command":
			_command(connection_id, pilot_id, message)
		"chat":
			var text: Variant = message.get("text", "")
			if not text is String or text.length() < 1 or text.length() > 280: return
			for index in range(text.length()):
				if text.unicode_at(index) < 32: return
			_broadcast({"op": "event", "event": {"type": "chat", "pilot_id": pilot_id, "text": text}})
		_:
			transport.send_to(connection_id, {"op": "error", "code": "unsupported_operation", "message": "Operação online não suportada."})


func _authenticate(connection_id: int, message: Dictionary) -> void:
	if str(message.get("protocol", "")) != PROTOCOL or not message.get("token") is String:
		_reject_auth(connection_id)
		return
	var token: String = message.token
	var pilot: Dictionary = store.authenticate(token)
	if pilot.is_empty():
		_reject_auth(connection_id)
		return
	for active: Dictionary in _sessions.values():
		if str(active.pilot_id) == str(pilot.id):
			transport.send_to(connection_id, {"op": "error", "code": "pilot_already_connected", "message": "Este piloto já está conectado."})
			transport.disconnect_peer(connection_id, "pilot_already_connected")
			return
	if _sessions.size() >= _max_players:
		transport.send_to(connection_id, {"op": "error", "code": "room_full", "message": "A sala está cheia."})
		transport.disconnect_peer(connection_id, "room_full")
		return
	var before: Dictionary = room.export_state()
	var result: Dictionary = room.add_player(str(pilot.id))
	if not bool(result.get("ok", false)):
		transport.disconnect_peer(connection_id, "character_unavailable")
		return
	if not _commit():
		room.import_state(before)
		return
	_sessions[connection_id] = {"pilot_id": str(pilot.id), "label": str(pilot.label), "token_hash": token.sha256_text()}
	transport.mark_authenticated(connection_id)
	transport.send_to(connection_id, {"op": "auth_ok", "pilot_id": str(pilot.id), "label": str(pilot.label), "protocol": PROTOCOL, "revision": _revision, "shared_combat": true, "map_index": 3002})
	_send_snapshot(connection_id)
	_log("pilot_joined", {"pilot_id": str(pilot.id), "connected": _sessions.size()})


func _reject_auth(connection_id: int) -> void:
	_metrics.auth_rejected += 1
	transport.send_to(connection_id, {"op": "error", "code": "invalid_credential", "message": "Credencial de piloto inválida."})
	transport.disconnect_peer(connection_id, "invalid_credential")


func _command(connection_id: int, pilot_id: String, message: Dictionary) -> void:
	var request_id: Variant = message.get("request_id", "")
	var action: Variant = message.get("action", "")
	var args: Variant = message.get("args", {})
	if not request_id is String or not Store.valid_request_id(request_id) or not action is String or not args is Dictionary:
		transport.send_to(connection_id, {"op": "result", "request_id": str(request_id).left(MAX_COMMAND_ID), "ok": false, "error": "invalid_command", "message": "Comando online inválido."})
		return
	var fingerprint := JSON.stringify({"action": action, "args": args}, "", true).sha256_text()
	var previous: Dictionary = store.get_receipt(pilot_id, request_id)
	if not store.error_text.is_empty():
		_storage_failure()
		return
	if not previous.is_empty():
		var saved_result: Dictionary = previous.get("result", {})
		if str(saved_result.get("request_digest", "")) != fingerprint:
			transport.send_to(connection_id, {"op": "result", "request_id": request_id, "ok": false, "error": "request_id_reused", "message": "O identificador já pertence a outro comando."})
			return
		_metrics.replayed_commands += 1
		var replay := saved_result.duplicate(true)
		replay["op"] = "result"
		replay["request_id"] = request_id
		replay["revision"] = int(previous.get("revision", 0))
		transport.send_to(connection_id, replay)
		return
	var before: Dictionary = room.export_state()
	var result: Dictionary = room.command(pilot_id, request_id, action, args)
	if not bool(result.get("ok", false)):
		_restore_live_room(before)
	result["request_digest"] = fingerprint
	var state: Dictionary = room.export_state()
	state["revision"] = _revision
	state["room_id"] = "main"
	var committed: Dictionary = store.commit_room(state, request_id, pilot_id, result)
	if not bool(committed.get("ok", false)):
		_restore_live_room(before)
		_storage_failure()
		return
	_revision = int(committed.revision)
	room.dirty = false
	_last_commit_msec = Time.get_ticks_msec()
	_checkpoint_elapsed = 0.0
	_metrics.commands += 1
	_metrics.commits += 1
	result["op"] = "result"
	result["request_id"] = request_id
	result["revision"] = _revision
	transport.send_to(connection_id, result)
	_send_snapshot(connection_id)


func _restore_live_room(state: Dictionary) -> void:
	if not room.import_state(state):
		_storage_failure()
		return
	for session: Dictionary in _sessions.values():
		if not bool(room.add_player(str(session.pilot_id)).get("ok", false)):
			_storage_failure()
			return


func _commit() -> bool:
	var state: Dictionary = room.export_state()
	state["revision"] = _revision
	state["room_id"] = "main"
	var result: Dictionary = store.commit_room(state)
	if not bool(result.get("ok", false)):
		_storage_failure()
		return false
	_revision = int(result.revision)
	room.dirty = false
	_checkpoint_elapsed = 0.0
	_last_commit_msec = Time.get_ticks_msec()
	_metrics.commits += 1
	return true


func _send_snapshot(connection_id: int) -> void:
	if not _sessions.has(connection_id): return
	var state: Dictionary = room.snapshot(str(_sessions[connection_id].pilot_id))
	state["revision"] = _revision
	state["player_count"] = _sessions.size()
	transport.send_to(connection_id, {"op": "snapshot", "state": state})


func _broadcast(value: Dictionary) -> void:
	for connection_id: Variant in _sessions:
		transport.send_to(int(connection_id), value)


func _poll_http() -> void:
	if not _health.is_listening(): return
	while _health.is_connection_available():
		var stream := _health.take_connection()
		if _http_clients.size() >= 8:
			stream.disconnect_from_host()
		else:
			_http_clients.append({"stream": stream, "data": PackedByteArray(), "started": Time.get_ticks_msec()})
	for index in range(_http_clients.size() - 1, -1, -1):
		var connection: Dictionary = _http_clients[index]
		var stream: StreamPeerTCP = connection.stream
		stream.poll()
		var available := stream.get_available_bytes()
		if available > 0:
			var received := stream.get_partial_data(mini(available, 4096))
			if int(received[0]) == OK: connection.data.append_array(received[1])
		var done: bool = connection.data.size() > 4096 or Time.get_ticks_msec() - int(connection.started) > 3000
		var request: String = (connection.data as PackedByteArray).get_string_from_utf8()
		if request.contains("\r\n\r\n"):
			var route := request.get_slice("\r\n", 0).split(" ")
			var path := str(route[1]) if route.size() == 3 and route[0] == "GET" else ""
			var code := 200 if _initialized and not _stopping else 503
			var response: Dictionary = {"ready": code == 200, "release": "0.8.0", "protocol": PROTOCOL}
			if path == "/metrics":
				response.merge(_metrics, true)
				response.merge({"revision": _revision, "players": _sessions.size(), "uptime_seconds": (Time.get_ticks_msec() - _started_msec) / 1000.0, "last_commit_age_seconds": (Time.get_ticks_msec() - _last_commit_msec) / 1000.0}, true)
			elif path not in ["/healthz", "/readyz"]:
				code = 404
				response = {"error": "not_found"}
			var body := JSON.stringify(response)
			var reason := "OK" if code == 200 else ("Not Found" if code == 404 else "Service Unavailable")
			stream.put_data(("HTTP/1.1 %d %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n%s" % [code, reason, body.to_utf8_buffer().size(), body]).to_utf8_buffer())
			done = true
		if done or stream.get_status() in [StreamPeerTCP.STATUS_NONE, StreamPeerTCP.STATUS_ERROR]:
			stream.disconnect_from_host()
			_http_clients.remove_at(index)


func _storage_failure() -> void:
	_metrics.storage_failures += 1
	_initialized = false
	_log("storage_unavailable", {"revision": _revision})
	if is_instance_valid(transport):
		_broadcast({"op": "error", "code": "storage_unavailable", "message": "Servidor indisponível; o progresso confirmado permanece salvo."})
	_stopping = true
	get_tree().quit(1)


func _fail_start(reason: String) -> void:
	_log("startup_failed", {"reason": reason})
	_stopping = true
	get_tree().quit(1)


func _log(event: String, fields: Dictionary = {}) -> void:
	var line := {"event": event, "release": "0.8.0", "time": int(Time.get_unix_time_from_system())}
	line.merge(fields)
	print(JSON.stringify(line))


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_shutdown()


func _shutdown() -> void:
	if _stopping: return
	if _initialized and not _commit(): return
	_stopping = true
	_initialized = false
	_log("server_stopped", {"revision": _revision})
	get_tree().quit()


func _exit_tree() -> void:
	_stopping = true
	if _initialized: _commit()
	_initialized = false
	if is_instance_valid(transport): transport.stop()
	_health.stop()
	for connection: Dictionary in _http_clients:
		(connection.stream as StreamPeerTCP).disconnect_from_host()
	_http_clients.clear()
	store.close()
