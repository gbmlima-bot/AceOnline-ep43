extends Node
## Raw WebSocket JSON backend. Caddy supplies HTTPS/WSS and certificate handling.
## Authentication is performed by ServerApp, which then calls mark_authenticated.

signal connected(connection_id: int)
signal disconnected(connection_id: int)
signal message_received(connection_id: int, value: Dictionary)

const Wire = preload("res://scripts/online/json_wire.gd")
const MAX_CONNECTIONS := 32
const MAX_PENDING := 8
const HANDSHAKE_TIMEOUT_MSEC := 5000
const AUTH_TIMEOUT_MSEC := 8000
const IDLE_TIMEOUT_MSEC := 60000
const CLOSE_TIMEOUT_MSEC := 1000

var _listener := TCPServer.new()
var _connections: Dictionary = {}
var _next_id := 1
var _port := 0
var _bind := ""
var _metrics := {"accepted": 0, "opened": 0, "closed": 0, "received": 0, "sent": 0,
	"bytes_received": 0, "bytes_sent": 0, "invalid_frames": 0, "rate_limited": 0,
	"capacity_rejected": 0, "timed_out": 0, "send_failed": 0}


func start(port: int, bind_address: String = "0.0.0.0") -> Error:
	if port < 1 or port > 65535 or bind_address.is_empty():
		return ERR_INVALID_PARAMETER
	stop()
	var result := _listener.listen(port, bind_address)
	if result == OK:
		_port = port
		_bind = bind_address
	set_process(result == OK)
	return result


func mark_authenticated(identifier: int) -> bool:
	var connection: Dictionary = _connections.get(identifier, {})
	if connection.is_empty() or not connection.opened or connection.closing:
		return false
	connection.authenticated = true
	return true


func send_to(identifier: int, value: Dictionary) -> bool:
	var connection: Dictionary = _connections.get(identifier, {})
	if connection.is_empty() or connection.closing:
		return false
	var peer: WebSocketPeer = connection.peer
	if peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return false
	var payload := Wire.encode(value)
	if payload.is_empty():
		_metrics.send_failed += 1
		return false
	var result := peer.send_text(payload)
	if result != OK:
		_metrics.send_failed += 1
		disconnect_peer(identifier, "outbound_backpressure")
		return false
	_metrics.sent += 1
	_metrics.bytes_sent += payload.to_utf8_buffer().size()
	return true


func disconnect_peer(identifier: int, reason: String = "session_closed") -> void:
	var connection: Dictionary = _connections.get(identifier, {})
	if connection.is_empty() or connection.closing:
		return
	connection.closing = true
	connection.close_started = Time.get_ticks_msec()
	var peer: WebSocketPeer = connection.peer
	if peer.get_ready_state() == WebSocketPeer.STATE_OPEN:
		var safe_reason := ""
		for character: String in reason.left(100):
			if character.unicode_at(0) < 32 or character.unicode_at(0) == 127:
				continue
			if (safe_reason + character).to_utf8_buffer().size() > 100:
				break
			safe_reason += character
		peer.close(1008, safe_reason)
	else:
		(connection.tcp as StreamPeerTCP).disconnect_from_host()


func stop() -> void:
	_listener.stop()
	for identifier: int in _connections.keys():
		_remove_connection(identifier)
	_port = 0
	_bind = ""
	set_process(false)


func snapshot() -> Dictionary:
	var pending := 0
	var authenticated := 0
	for connection: Dictionary in _connections.values():
		if connection.authenticated:
			authenticated += 1
		else:
			pending += 1
	return {"running": _listener.is_listening(), "port": _port, "bind_address": _bind,
		"connections": _connections.size(), "pending": pending, "authenticated": authenticated,
		"max_connections": MAX_CONNECTIONS, "max_pending": MAX_PENDING,
		"max_frame_bytes": Wire.MAX_FRAME_BYTES, "protocol": Wire.PROTOCOL,
		"metrics": _metrics.duplicate(true)}


func _process(_delta: float) -> void:
	var accepted := 0
	while _listener.is_connection_available() and accepted < MAX_PENDING:
		accepted += 1
		_accept_connection(_listener.take_connection())
	var now := Time.get_ticks_msec()
	for identifier: int in _connections.keys():
		if not _connections.has(identifier):
			continue
		var connection: Dictionary = _connections[identifier]
		var peer: WebSocketPeer = connection.peer
		peer.poll()
		var state := peer.get_ready_state()
		if state == WebSocketPeer.STATE_CLOSED:
			_remove_connection(identifier)
			continue
		if connection.closing:
			if now - int(connection.close_started) >= CLOSE_TIMEOUT_MSEC:
				_remove_connection(identifier)
			continue
		if state == WebSocketPeer.STATE_CONNECTING and now - int(connection.created) > HANDSHAKE_TIMEOUT_MSEC:
			_metrics.timed_out += 1
			disconnect_peer(identifier, "websocket_handshake_timeout")
			continue
		if state != WebSocketPeer.STATE_OPEN:
			continue
		if not connection.opened:
			connection.opened = true
			_metrics.opened += 1
			send_to(identifier, {"op": "hello", "protocol": Wire.PROTOCOL})
			connected.emit(identifier)
			if not _connections.has(identifier):
				continue
		if not connection.authenticated and now - int(connection.created) > AUTH_TIMEOUT_MSEC:
			_metrics.timed_out += 1
			disconnect_peer(identifier, "authentication_timeout")
			continue
		if connection.authenticated and now - int(connection.last_seen) > IDLE_TIMEOUT_MSEC:
			_metrics.timed_out += 1
			disconnect_peer(identifier, "idle_timeout")
			continue
		var budget := 16
		while budget > 0 and peer.get_available_packet_count() > 0 and not connection.closing:
			budget -= 1
			var bytes := peer.get_packet()
			_metrics.bytes_received += bytes.size()
			if not peer.was_string_packet() or bytes.size() > Wire.MAX_FRAME_BYTES:
				_reject(identifier, "invalid_text_frame")
				break
			var value := Wire.decode(bytes)
			if value.is_empty() or not value.op in ["auth", "input", "command", "chat"]:
				_reject(identifier, "invalid_json_message")
				break
			if not _take_rate(connection, "messages", 60.0, 20.0):
				_metrics.rate_limited += 1
				disconnect_peer(identifier, "message_rate_limit")
				break
			if not connection.authenticated and value.op != "auth":
				_reject(identifier, "authentication_required")
				break
			var per_second := 30.0 if value.op == "input" else (10.0 if value.op == "command" else (2.0 if value.op == "chat" else 2.0))
			var capacity := 8.0 if value.op == "input" else (5.0 if value.op == "command" else 3.0)
			if not _take_rate(connection, str(value.op), per_second, capacity):
				_metrics.rate_limited += 1
				disconnect_peer(identifier, "operation_rate_limit")
				break
			connection.last_seen = now
			_metrics.received += 1
			message_received.emit(identifier, value)


func _accept_connection(tcp: StreamPeerTCP) -> void:
	if tcp == null:
		return
	var pending := 0
	for connection: Dictionary in _connections.values():
		if not connection.authenticated:
			pending += 1
	if _connections.size() >= MAX_CONNECTIONS or pending >= MAX_PENDING:
		_metrics.capacity_rejected += 1
		tcp.disconnect_from_host()
		return
	var peer := WebSocketPeer.new()
	peer.inbound_buffer_size = Wire.MAX_FRAME_BYTES * 2
	peer.outbound_buffer_size = Wire.MAX_FRAME_BYTES * 2
	peer.max_queued_packets = 16
	if peer.accept_stream(tcp) != OK:
		tcp.disconnect_from_host()
		return
	var now := Time.get_ticks_msec()
	_connections[_next_id] = {"peer": peer, "tcp": tcp, "created": now, "last_seen": now,
		"opened": false, "authenticated": false, "closing": false, "close_started": 0, "rates": {}}
	_next_id += 1
	_metrics.accepted += 1


func _reject(identifier: int, code: String) -> void:
	_metrics.invalid_frames += 1
	disconnect_peer(identifier, code)


func _remove_connection(identifier: int) -> void:
	var connection: Dictionary = _connections.get(identifier, {})
	if connection.is_empty():
		return
	(connection.tcp as StreamPeerTCP).disconnect_from_host()
	_connections.erase(identifier)
	_metrics.closed += 1
	if connection.opened:
		disconnected.emit(identifier)


static func _take_rate(connection: Dictionary, channel: String, per_second: float, capacity: float) -> bool:
	var now := Time.get_ticks_msec() / 1000.0
	var rates: Dictionary = connection.rates
	var bucket: Dictionary = rates.get(channel, {"time": now, "tokens": capacity})
	var tokens := minf(capacity, float(bucket.tokens) + maxf(0.0, now - float(bucket.time)) * per_second)
	var allowed := tokens >= 1.0
	rates[channel] = {"time": now, "tokens": tokens - 1.0 if allowed else tokens}
	return allowed


func _exit_tree() -> void:
	stop()
