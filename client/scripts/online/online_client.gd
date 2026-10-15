extends Node
## Dedicated PvE protocol. Credentials remain only in the authentication frame.
## Public connections require WSS with normal CA/hostname verification.

signal status_changed(state: String)
signal snapshot_received(state: Dictionary)
signal event_received(event: Dictionary)
signal command_result(result: Dictionary)

const Wire = preload("res://scripts/online/json_wire.gd")
const CONNECT_TIMEOUT_MSEC := 10000
const AUTH_TIMEOUT_MSEC := 8000
const MAX_SEQUENCE := 2147483647

var _peer: WebSocketPeer
var _status := "offline"
var _message := "Modo offline."
var _url := ""
var _pending_token := ""
var _pilot_id := ""
var _started := 0
var _auth_started := 0
var _auth_sent := false
var _last_input_sequence := -1
var _rates: Dictionary = {}
var _last_state: Dictionary = {}
var _metrics := {"received": 0, "sent": 0, "invalid_frames": 0, "rate_limited": 0}
var _exiting_tree := false


func _enter_tree() -> void:
	_exiting_tree = false


func connect_to(url: String, token: String) -> Error:
	var address := url.strip_edges()
	if not valid_url(address) or not _valid_token(token) or address.contains(token):
		return ERR_INVALID_PARAMETER
	disconnect_from_server()
	var candidate := WebSocketPeer.new()
	candidate.inbound_buffer_size = Wire.MAX_FRAME_BYTES * 2
	candidate.outbound_buffer_size = Wire.MAX_FRAME_BYTES * 2
	candidate.max_queued_packets = 16
	# No trusted certificate override, unsafe TLS option, or disabled hostname check.
	var result := candidate.connect_to_url(address, TLSOptions.client() if address.begins_with("wss://") else null)
	if result != OK:
		_set_status("error", "Não foi possível iniciar a conexão com o servidor.")
		return result
	_peer = candidate
	_url = address
	_pending_token = token
	_started = Time.get_ticks_msec()
	_set_status("connecting", "Conectando ao servidor dedicado…")
	set_process(true)
	return OK


func disconnect_from_server(reason: String = "") -> void:
	if _peer != null:
		if _peer.get_ready_state() == WebSocketPeer.STATE_OPEN:
			_peer.close(1000, "client_disconnect")
		_peer = null
	_pending_token = ""
	_pilot_id = ""
	_url = ""
	_auth_sent = false
	_last_input_sequence = -1
	_rates.clear()
	_last_state.clear()
	set_process(false)
	_set_status("offline", reason if not reason.is_empty() else "Modo offline.")


func send_input(sequence: int, controls: Dictionary) -> bool:
	if not is_connected_to_server() or sequence < 0 or sequence > MAX_SEQUENCE or sequence <= _last_input_sequence or not _valid_controls(controls):
		return false
	if not _take_rate("input", 30.0, 3.0):
		return false
	if not _send({"op": "input", "seq": sequence, "controls": controls}):
		return false
	_last_input_sequence = sequence
	return true


func command(request_id: String, action: String, args: Dictionary = {}) -> bool:
	if not is_connected_to_server() or not _valid_identifier(request_id, 96) or not _valid_identifier(action, 48) or args.size() > 32:
		return false
	var value := {"op": "command", "request_id": request_id, "action": action, "args": args}
	if Wire.encode(value).is_empty() or not _take_rate("command", 10.0, 5.0):
		return false
	return _send(value)


func send_chat(text: String) -> bool:
	if not is_connected_to_server() or text.is_empty() or text.length() > 280 or text.to_utf8_buffer().size() > 1024:
		return false
	for character: String in text:
		if character.unicode_at(0) < 32 or character.unicode_at(0) == 127:
			return false
	if text.strip_edges().is_empty() or not _take_rate("chat", 2.0, 3.0):
		return false
	return _send({"op": "chat", "text": text.strip_edges()})


func is_connected_to_server() -> bool:
	return _status == "connected" and _peer != null and _peer.get_ready_state() == WebSocketPeer.STATE_OPEN


func snapshot() -> Dictionary:
	return {"status": _status, "connected": is_connected_to_server(), "message": _message,
		"url": _url, "pilot_id": _pilot_id, "protocol": Wire.PROTOCOL,
		"metrics": _metrics.duplicate(true), "state": _last_state.duplicate(true)}


func _process(_delta: float) -> void:
	if _peer == null:
		return
	_peer.poll()
	var state := _peer.get_ready_state()
	if state == WebSocketPeer.STATE_CLOSED:
		_fail("Conexão encerrada pelo servidor.")
		return
	var now := Time.get_ticks_msec()
	if not _auth_sent and now - _started > CONNECT_TIMEOUT_MSEC:
		_fail("Tempo de conexão esgotado.")
		return
	if _auth_sent and _status != "connected" and now - _auth_started > AUTH_TIMEOUT_MSEC:
		_fail("Tempo de autenticação esgotado.")
		return
	if state != WebSocketPeer.STATE_OPEN:
		return
	var budget := 32
	while _peer != null and budget > 0 and _peer.get_available_packet_count() > 0:
		budget -= 1
		var bytes := _peer.get_packet()
		if not _peer.was_string_packet():
			_metrics.invalid_frames += 1
			_fail("O servidor enviou um formato de mensagem inválido.")
			return
		var value := Wire.decode(bytes)
		if value.is_empty():
			_metrics.invalid_frames += 1
			_fail("O servidor enviou uma mensagem inválida ou grande demais.")
			return
		_metrics.received += 1
		_handle_message(value)


func _handle_message(value: Dictionary) -> void:
	match str(value.op):
		"hello":
			if _auth_sent or value.get("protocol") != Wire.PROTOCOL or _pending_token.is_empty():
				_fail("Protocolo do servidor incompatível.")
				return
			_auth_sent = _send({"op": "auth", "protocol": Wire.PROTOCOL, "token": _pending_token})
			_pending_token = ""
			if not _auth_sent:
				_fail("Não foi possível autenticar a sessão.")
				return
			_auth_started = Time.get_ticks_msec()
			_set_status("authenticating", "Autenticando convite…")
		"auth_ok":
			if not _auth_sent or _status != "authenticating" or not value.get("pilot_id") is String or value.pilot_id.is_empty() or value.pilot_id.length() > 128:
				_fail("Resposta de autenticação inválida.")
				return
			_pilot_id = value.pilot_id
			_set_status("connected", "Servidor dedicado conectado. Combate e progresso do servidor.")
		"snapshot":
			if not is_connected_to_server() or not value.get("state") is Dictionary:
				_fail("Estado de sessão inválido.")
				return
			_last_state = value.state.duplicate(true)
			snapshot_received.emit(_last_state.duplicate(true))
		"event":
			if not is_connected_to_server() or not value.get("event") is Dictionary:
				_fail("Evento de sessão inválido.")
				return
			event_received.emit(value.event)
		"result":
			if not is_connected_to_server() or not value.get("request_id") is String or not value.get("ok") is bool:
				_fail("Resultado de operação inválido.")
				return
			command_result.emit(value)
		"error":
			# Never echo arbitrary server text: it could contain an invitation token.
			_fail("O servidor recusou a sessão ou a mensagem recebida.")
		_:
			_metrics.invalid_frames += 1
			_fail("Operação de protocolo desconhecida.")


func _send(value: Dictionary) -> bool:
	if _peer == null or _peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return false
	var payload := Wire.encode(value)
	if payload.is_empty() or _peer.send_text(payload) != OK:
		return false
	_metrics.sent += 1
	return true


func _fail(message: String) -> void:
	disconnect_from_server()
	_set_status("error", message)


func _set_status(state: String, message: String) -> void:
	_status = state
	_message = message
	# Children leave before their owner. A disconnect callback during teardown
	# must not restore an offline world into siblings that are being destroyed.
	if not _exiting_tree: status_changed.emit(state)


func _take_rate(channel: String, per_second: float, capacity: float) -> bool:
	var now := Time.get_ticks_msec() / 1000.0
	var bucket: Dictionary = _rates.get(channel, {"time": now, "tokens": capacity})
	var tokens := minf(capacity, float(bucket.tokens) + maxf(0.0, now - float(bucket.time)) * per_second)
	var allowed := tokens >= 1.0
	_rates[channel] = {"time": now, "tokens": tokens - 1.0 if allowed else tokens}
	if not allowed:
		_metrics.rate_limited += 1
	return allowed


static func valid_url(url: String) -> bool:
	if url.is_empty() or url.length() > 512:
		return false
	var pattern := RegEx.new()
	pattern.compile("^(wss?)://(\\[[0-9A-Fa-f:.%]+\\]|[^/:?#\\s@]+)(?::([0-9]{1,5}))?(/[^?#\\s]*)?$")
	var result := pattern.search(url)
	if result == null:
		return false
	var scheme := result.get_string(1)
	var host := result.get_string(2).to_lower().trim_prefix("[").trim_suffix("]")
	var port := result.get_string(3)
	if not port.is_empty() and (int(port) < 1 or int(port) > 65535):
		return false
	if scheme == "wss":
		return true
	return host in ["localhost", "127.0.0.1", "::1", "0:0:0:0:0:0:0:1"] or (host.begins_with("127.") and host.is_valid_ip_address())


static func _valid_token(token: String) -> bool:
	if token.is_empty() or token.length() > 256 or token.to_utf8_buffer().size() > 512:
		return false
	for character: String in token:
		if character.unicode_at(0) <= 32 or character.unicode_at(0) == 127:
			return false
	return true


static func _valid_identifier(value: String, limit: int) -> bool:
	if value.is_empty() or value.length() > limit:
		return false
	for character: String in value:
		var code := character.unicode_at(0)
		if not ((code >= 48 and code <= 57) or (code >= 65 and code <= 90) or (code >= 97 and code <= 122) or character in ["_", "-", ":", "."]):
			return false
	return true


static func _valid_controls(controls: Dictionary) -> bool:
	if controls.size() > 12:
		return false
	for key: Variant in controls:
		if not key is String:
			return false
		var value: Variant = controls[key]
		if key in ["pitch", "yaw", "roll", "ground_throttle"]:
			if not (value is float or value is int) or not is_finite(float(value)) or absf(float(value)) > 1.0:
				return false
		elif key in ["boost", "brake", "primary", "secondary", "target_next", "unit_stop"]:
			if not value is bool:
				return false
		elif key == "aim_direction":
			if not value is Array or value.size() != 3:
				return false
			for component: Variant in value:
				if not (component is float or component is int) or not is_finite(float(component)) or absf(float(component)) > 1.0:
					return false
			var aim := Vector3(float(value[0]), float(value[1]), float(value[2]))
			if aim.length_squared() < 0.5 or aim.length_squared() > 1.5:
				return false
		else:
			return false
	return true


func _exit_tree() -> void:
	_exiting_tree = true
	disconnect_from_server()
