class_name PlainFraming
extends RefCounted
## Offline, opaque framing for the legacy protocol's unencoded branch.
## SocketHeader.h:25-32 defines the four-byte header and 1492-byte send limit.
## WinPacket.h:244-346 accepts bodies through 1496 bytes and only tests flag bit 7.
## IOCPSocket.cpp:861-902 does not use the raw header sequence for unencoded input.
## This module retains header metadata without interpreting sequence or payload.
## Little-endian is an explicit Windows x86 profile; fixtures are synthetic.

const HEADER_SIZE: int = 4
const MAX_PAYLOAD_SIZE: int = 1492
const LEGACY_RECEIVE_BODY_CEILING: int = 1496

var _pending: PackedByteArray = PackedByteArray()
var _frame_size: int = 0
var _failed: bool = false


static func encode_unencoded(payload: PackedByteArray) -> Dictionary:
	if payload.is_empty() or payload.size() > MAX_PAYLOAD_SIZE:
		return {"ok": false, "bytes": PackedByteArray(), "error": "invalid_length"}
	var result: PackedByteArray = PackedByteArray()
	result.resize(HEADER_SIZE + payload.size())
	result[0] = payload.size() & 0xff
	result[1] = (payload.size() >> 8) & 0xff
	# The legacy unencoded sender writes both flag and sequence as zero.
	result[2] = 0
	result[3] = 0
	for index: int in range(payload.size()):
		result[HEADER_SIZE + index] = payload[index]
	return {"ok": true, "bytes": result, "error": ""}


func feed(chunk: PackedByteArray) -> Dictionary:
	if _failed:
		return _feed_error("parser_failed")
	var frames: Array[Dictionary] = []
	var offset: int = 0
	while offset < chunk.size():
		if _frame_size == 0:
			var header_end: int = mini(chunk.size(), offset + HEADER_SIZE - _pending.size())
			_pending.append_array(chunk.slice(offset, header_end))
			offset = header_end
			if _pending.size() < HEADER_SIZE:
				break
			var body_size: int = int(_pending[0]) | (int(_pending[1]) << 8)
			if body_size == 0 or body_size > LEGACY_RECEIVE_BODY_CEILING:
				return _fail("invalid_length")
			if (_pending[2] & 0x80) != 0:
				return _fail("unsupported_encoded_frame")
			_frame_size = HEADER_SIZE + body_size
		var body_end: int = mini(chunk.size(), offset + _frame_size - _pending.size())
		_pending.append_array(chunk.slice(offset, body_end))
		offset = body_end
		if _pending.size() == _frame_size:
			frames.append({
				"payload": _pending.slice(HEADER_SIZE),
				"raw_flags": int(_pending[2]),
				"raw_sequence": int(_pending[3]),
			})
			_pending = PackedByteArray()
			_frame_size = 0
	return {"ok": true, "frames": frames, "error": ""}


func finish() -> Dictionary:
	if _failed:
		return {"ok": false, "error": "parser_failed"}
	if not _pending.is_empty():
		_failed = true
		return {"ok": false, "error": "truncated_frame"}
	return {"ok": true, "error": ""}


func reset() -> void:
	_pending = PackedByteArray()
	_frame_size = 0
	_failed = false


func pending_size() -> int:
	return _pending.size()


func _fail(error: String) -> Dictionary:
	_failed = true
	# A malformed frame discards every frame parsed in this feed call.
	return _feed_error(error)


func _feed_error(error: String) -> Dictionary:
	return {"ok": false, "frames": [], "error": error}
