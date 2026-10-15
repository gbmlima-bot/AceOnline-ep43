extends Node
## New game's LAN flight visits and session chat. This is not the ACE protocol.
## Players' combat, enemies, missions and rewards remain separate local sessions.

signal peers_updated
signal chat_received(peer_id: int, text: String)
signal status_changed(status: String)

const DEFAULT_PORT := 24680
const MAX_PLAYERS := 8
const STATE_HZ := 15.0
const CHAT_LIMIT := 280
const ALLOWED_GEARS := ["12000100", "12001100", "12002100", "12003100"]
const MAX_COORDINATE := 2000000.0
const JOIN_TIMEOUT_MSEC := 10000

var _api: SceneMultiplayer
var _peer: ENetMultiplayerPeer
var _mode := "offline"
var _status := "offline"
var _address := ""
var _port := DEFAULT_PORT
var _message := "Sessão local. Combate e progresso individuais."
var _states: Dictionary = {}
var _members: Array[int] = []
var _chat: Array[Dictionary] = []
var _rates: Dictionary = {}
var _last_publish_msec := -100000
var _broadcast_elapsed := 0.0
var _join_started := 0
var _revision := 0
var _last_remote_revision := -1
var _rejected_states := 0
var _rejected_chats := 0


func _ready() -> void:
	_api = SceneMultiplayer.new()
	_api.allow_object_decoding = false
	get_tree().set_multiplayer(_api, get_path())
	_api.peer_connected.connect(_on_peer_connected)
	_api.peer_disconnected.connect(_on_peer_disconnected)
	_api.connected_to_server.connect(_on_connected)
	_api.connection_failed.connect(_on_connection_failed)
	_api.server_disconnected.connect(_on_server_disconnected)
	set_process(true)


func host(port: int = DEFAULT_PORT) -> Error:
	if port < 1024 or port > 65535 or _api == null:
		return ERR_INVALID_PARAMETER
	leave()
	var candidate := ENetMultiplayerPeer.new()
	var result := candidate.create_server(port, MAX_PLAYERS - 1, 2)
	if result != OK:
		_set_status("error", "Não foi possível abrir a porta UDP %d." % port)
		return result
	_peer = candidate
	_api.multiplayer_peer = _peer
	_mode = "host"
	_address = "0.0.0.0"
	_port = port
	_members = [1]
	_set_status("hosting", "Anfitrião LAN · UDP %d · até %d pilotos. Combate individual." % [port, MAX_PLAYERS])
	peers_updated.emit()
	return OK


func join(address: String, port: int = DEFAULT_PORT) -> Error:
	var clean := address.strip_edges()
	if not _valid_address(clean) or port < 1024 or port > 65535 or _api == null:
		return ERR_INVALID_PARAMETER
	leave()
	var candidate := ENetMultiplayerPeer.new()
	var result := candidate.create_client(clean, port, 2)
	if result != OK:
		_set_status("error", "Não foi possível iniciar a conexão LAN.")
		return result
	_peer = candidate
	_api.multiplayer_peer = _peer
	_mode = "client"
	_address = clean
	_port = port
	_join_started = Time.get_ticks_msec()
	_set_status("connecting", "Conectando a %s:%d…" % [clean, port])
	return OK


func leave() -> void:
	if _peer != null:
		_peer.close()
	if _api != null:
		_api.multiplayer_peer = null
	_peer = null
	_mode = "offline"
	_address = ""
	_states.clear()
	_members.clear()
	_chat.clear()
	_rates.clear()
	_last_publish_msec = -100000
	_broadcast_elapsed = 0.0
	_join_started = 0
	_revision = 0
	_last_remote_revision = -1
	_set_status("offline", "Sessão local. Combate e progresso individuais.")
	peers_updated.emit()


func publish_state(state: Dictionary) -> bool:
	if not _is_connected():
		return false
	var clean := _validate_state(state)
	if clean.is_empty():
		_rejected_states += 1
		return false
	var now := Time.get_ticks_msec()
	if now - _last_publish_msec < int(1000.0 / STATE_HZ):
		return false
	_last_publish_msec = now
	var identifier := _api.get_unique_id()
	if _mode == "host":
		_store_state(identifier, clean)
	else:
		_rpc_state.rpc_id(1, clean)
	return true


func send_chat(text: String) -> bool:
	if not _is_connected():
		return false
	var clean := _validate_chat(text)
	var identifier := _api.get_unique_id()
	if clean.is_empty() or not _take_rate(identifier, "out_chat", 1.0, 3.0):
		_rejected_chats += 1
		return false
	if _mode == "host":
		_relay_chat(identifier, clean)
	else:
		_rpc_chat.rpc_id(1, clean)
	return true


func snapshot() -> Dictionary:
	return {"status": _status, "mode": _mode, "connected": _is_connected(),
		"address": _address, "host": _address, "port": _port,
		"peer_id": _api.get_unique_id() if _is_connected() else 0,
		"peer_count": _members.size(), "members": _members.duplicate(),
		"peers": _states.duplicate(true), "chat": _chat.duplicate(true),
		"message": _message, "max_players": MAX_PLAYERS,
		"shared_combat": false, "transport": "ENet UDP LAN",
		"rejected_states": _rejected_states, "rejected_chats": _rejected_chats}


func _process(delta: float) -> void:
	if _status == "connecting" and Time.get_ticks_msec() - _join_started > JOIN_TIMEOUT_MSEC:
		_fail("Tempo de conexão LAN esgotado. Verifique o IP, a porta UDP e a rede.")
	if _mode != "host" or not _is_connected():
		return
	_broadcast_elapsed += delta
	if _broadcast_elapsed >= 1.0 / STATE_HZ:
		_broadcast_elapsed = 0.0
		_broadcast_states()


@rpc("any_peer", "call_remote", "unreliable_ordered", 0)
func _rpc_state(value: Variant) -> void:
	if _mode != "host":
		return
	var sender := _api.get_remote_sender_id()
	if sender <= 1 or not _members.has(sender) or not _take_rate(sender, "state", 20.0, 6.0):
		_rejected_states += 1
		return
	var clean := _validate_state(value)
	if clean.is_empty():
		_rejected_states += 1
		return
	_store_state(sender, clean)


@rpc("authority", "call_remote", "unreliable_ordered", 0)
func _rpc_roster(revision: int, members: Array, states: Dictionary) -> void:
	if _mode != "client" or _api.get_remote_sender_id() != 1 or revision <= _last_remote_revision or members.size() > MAX_PLAYERS or states.size() > MAX_PLAYERS:
		return
	var clean_members: Array[int] = []
	for identifier: Variant in members:
		if not identifier is int or identifier < 1 or clean_members.has(identifier):
			return
		clean_members.append(identifier)
	if not clean_members.has(1) or not clean_members.has(_api.get_unique_id()):
		return
	var clean_states: Dictionary = {}
	for key: Variant in states:
		if not key is String or not key.is_valid_int() or not clean_members.has(int(key)):
			return
		var raw: Variant = states[key]
		if not raw is Dictionary or not raw.get("peer_id") is int or raw.peer_id != int(key):
			return
		var payload: Dictionary = raw.duplicate()
		payload.erase("peer_id")
		var clean := _validate_state(payload)
		if clean.is_empty():
			return
		clean.peer_id = int(key)
		clean_states[key] = clean
	_last_remote_revision = revision
	_members = clean_members
	_states = clean_states
	peers_updated.emit()


@rpc("any_peer", "call_remote", "reliable", 1)
func _rpc_chat(value: Variant) -> void:
	if _mode != "host":
		return
	var sender := _api.get_remote_sender_id()
	if sender <= 1 or not _members.has(sender) or not _take_rate(sender, "chat", 1.0, 3.0):
		_rejected_chats += 1
		return
	var clean := _validate_chat(value)
	if clean.is_empty():
		_rejected_chats += 1
		return
	_relay_chat(sender, clean)


@rpc("authority", "call_remote", "reliable", 1)
func _rpc_chat_delivered(identifier: int, text: String, display_name: String) -> void:
	var clean := _validate_chat(text)
	if _mode != "client" or _api.get_remote_sender_id() != 1 or identifier < 1 or clean.is_empty():
		return
	_append_chat(identifier, clean, _clean_name(display_name))


func _store_state(identifier: int, clean: Dictionary) -> void:
	clean.peer_id = identifier
	_states[str(identifier)] = clean
	peers_updated.emit()


func _broadcast_states() -> void:
	if _members.size() <= 1:
		return
	_revision += 1
	_rpc_roster.rpc(_revision, _members, _states)


func _relay_chat(identifier: int, text: String) -> void:
	var display_name := str(_states.get(str(identifier), {}).get("name", "Piloto %d" % identifier))
	_append_chat(identifier, text, display_name)
	if _members.size() > 1:
		_rpc_chat_delivered.rpc(identifier, text, display_name)


func _append_chat(identifier: int, text: String, display_name: String) -> void:
	_chat.append({"peer_id": identifier, "text": text, "name": display_name})
	if _chat.size() > 100:
		_chat.pop_front()
	chat_received.emit(identifier, text)
	peers_updated.emit()


func _on_peer_connected(identifier: int) -> void:
	if _mode != "host":
		return
	if _members.size() >= MAX_PLAYERS or identifier <= 1:
		_peer.disconnect_peer(identifier)
		return
	if not _members.has(identifier):
		_members.append(identifier)
	_broadcast_states()
	peers_updated.emit()


func _on_peer_disconnected(identifier: int) -> void:
	if _mode != "host":
		return
	_members.erase(identifier)
	_states.erase(str(identifier))
	for key: Variant in _rates.keys():
		if str(key).begins_with(str(identifier) + ":"):
			_rates.erase(key)
	_broadcast_states()
	peers_updated.emit()


func _on_connected() -> void:
	if _mode == "client":
		_members = [1, _api.get_unique_id()]
		_set_status("connected", "Visita LAN conectada. Combate, inimigos e recompensas individuais.")
		peers_updated.emit()


func _on_connection_failed() -> void:
	_fail("Falha ao conectar. Verifique o IP, a porta UDP e se o anfitrião está aberto.")


func _on_server_disconnected() -> void:
	_fail("O anfitrião encerrou a sessão. Seu jogo e progresso locais continuam disponíveis.")


func _fail(message: String) -> void:
	leave()
	_set_status("error", message)


func _set_status(status: String, message: String) -> void:
	_status = status
	_message = message
	status_changed.emit(_status)


func _is_connected() -> bool:
	return _peer != null and _peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED and _mode != "offline"


func _take_rate(identifier: int, channel: String, per_second: float, capacity: float) -> bool:
	var key := "%d:%s" % [identifier, channel]
	var now := Time.get_ticks_msec() / 1000.0
	var bucket: Dictionary = _rates.get(key, {"tokens": capacity, "time": now})
	var tokens := minf(capacity, float(bucket.tokens) + maxf(0.0, now - float(bucket.time)) * per_second)
	var allowed := tokens >= 1.0
	_rates[key] = {"tokens": tokens - 1.0 if allowed else tokens, "time": now}
	return allowed


static func _validate_state(value: Variant) -> Dictionary:
	if not value is Dictionary or value.size() < 5 or value.size() > 7:
		return {}
	for key: Variant in value:
		if not key is String or not key in ["map_index", "gear_id", "position", "rotation", "speed", "name", "appearance_id"]:
			return {}
	if not value.get("map_index") is int or value.map_index < 1 or value.map_index > 1000000:
		return {}
	if not value.get("gear_id") is String or not value.gear_id in ALLOWED_GEARS:
		return {}
	if not _valid_vector(value.get("position"), MAX_COORDINATE) or not _valid_vector(value.get("rotation"), 100.0):
		return {}
	if not _finite_number(value.get("speed")) or float(value.speed) < 0.0 or float(value.speed) > 2000.0:
		return {}
	if value.has("name") and (not value.name is String or value.name.length() > 24 or value.name.to_utf8_buffer().size() > 96):
		return {}
	var appearance: Variant = value.get("appearance_id", 0)
	if not appearance is int or (appearance != 0 and (appearance < 8000000 or appearance > 8999999)):
		return {}
	var rotation: Array = value.rotation
	return {"map_index": value.map_index, "gear_id": value.gear_id,
		"position": value.position.duplicate(),
		"rotation": [wrapf(float(rotation[0]), -PI, PI), wrapf(float(rotation[1]), -PI, PI), wrapf(float(rotation[2]), -PI, PI)],
		"speed": float(value.speed), "name": _clean_name(value.get("name", "Piloto")),
		"appearance_id": appearance}


static func _valid_vector(value: Variant, bound: float) -> bool:
	if not value is Array or value.size() != 3:
		return false
	for component: Variant in value:
		if not _finite_number(component) or absf(float(component)) > bound:
			return false
	return true


static func _finite_number(value: Variant) -> bool:
	return (value is float or value is int) and is_finite(float(value))


static func _valid_address(value: String) -> bool:
	if value.is_empty() or value.length() > 253:
		return false
	for character: String in value:
		var code := character.unicode_at(0)
		if not ((code >= 48 and code <= 57) or (code >= 65 and code <= 90) or (code >= 97 and code <= 122) or character in [".", ":", "-", "%", "_"]):
			return false
	return true


static func _clean_name(value: String) -> String:
	var clean := ""
	for character: String in value.left(24):
		if character.unicode_at(0) >= 32 and character.unicode_at(0) != 127:
			clean += character
	clean = clean.strip_edges()
	return clean if not clean.is_empty() else "Piloto"


static func _validate_chat(value: Variant) -> String:
	if not value is String or value.length() > CHAT_LIMIT or value.to_utf8_buffer().size() > 1024:
		return ""
	var clean := ""
	for character: String in value:
		var code := character.unicode_at(0)
		if code >= 32 and code != 127:
			clean += character
	return clean.strip_edges()


func _exit_tree() -> void:
	if _peer != null:
		_peer.close()
	if _api != null:
		_api.multiplayer_peer = null
	if get_tree() != null:
		get_tree().set_multiplayer(null, get_path())
