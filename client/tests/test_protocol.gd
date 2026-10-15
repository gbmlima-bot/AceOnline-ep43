extends SceneTree
## Run: godot --headless --path client --script res://tests/test_protocol.gd

const Framing = preload("res://scripts/protocol/plain_framing.gd")

var _checks: int = 0
var _failures: Array[String] = []


func _initialize() -> void:
	var fixture_path: String = ProjectSettings.globalize_path("res://").path_join("../protocol/fixtures/framing.json")
	var file: FileAccess = FileAccess.open(fixture_path, FileAccess.READ)
	_check(file != null, "fixtures are readable")
	if file == null:
		_report()
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	_check(parsed is Dictionary, "fixtures contain a JSON object")
	if not parsed is Dictionary:
		_report()
		return
	var fixtures: Dictionary = parsed
	var valid: Array = fixtures.get("valid", [])
	var invalid: Array = fixtures.get("invalid", [])
	var truncated: Array = fixtures.get("truncated", [])
	_check(not valid.is_empty(), "valid fixtures exist")
	_check(not invalid.is_empty(), "invalid fixtures exist")
	for entry: Dictionary in valid:
		_test_valid_fixture(entry)
	for entry: Dictionary in invalid:
		_test_invalid_fixture(entry)
	for entry: Dictionary in truncated:
		_test_truncated_fixture(entry)
	_test_multiple_frames(valid)
	_test_boundaries()
	_test_empty_feed_and_reset()
	_test_atomic_failure(valid, invalid)
	_report()


func _test_valid_fixture(entry: Dictionary) -> void:
	var label: String = str(entry.get("id", "unnamed"))
	var wire: PackedByteArray = str(entry["frame_hex"]).hex_decode()
	var expected_payload: PackedByteArray = str(entry["payload_hex"]).hex_decode()
	var expected_sequence: int = int(entry.get("raw_sequence", wire[3]))
	var expected_flags: int = int(entry.get("raw_flags", wire[2]))
	for split: int in range(wire.size() + 1):
		var parser = Framing.new()
		var first: Dictionary = parser.feed(wire.slice(0, split))
		var second: Dictionary = parser.feed(wire.slice(split))
		_check(first["ok"] and second["ok"], "%s split %d accepted" % [label, split])
		var frames: Array = first["frames"] + second["frames"]
		_check_frame(frames, expected_payload, expected_flags, expected_sequence, "%s split %d" % [label, split])
		_check(parser.pending_size() == 0, "%s split %d drained" % [label, split])
		_check(parser.finish()["ok"], "%s split %d finish" % [label, split])
	# Test every incomplete prefix, including partial headers and bodies.
	for prefix: int in range(1, wire.size()):
		var parser = Framing.new()
		var fed: Dictionary = parser.feed(wire.slice(0, prefix))
		_check(fed["ok"] and fed["frames"].is_empty(), "%s prefix %d waits" % [label, prefix])
		_check(parser.pending_size() == prefix, "%s prefix %d pending" % [label, prefix])
		_check_error(parser.finish(), "truncated_frame", "%s prefix %d truncated" % [label, prefix])
		_check_error(parser.finish(), "parser_failed", "%s prefix %d latched finish" % [label, prefix])
		_check_error(parser.feed(PackedByteArray()), "parser_failed", "%s prefix %d latched feed" % [label, prefix])
	var encoded: Dictionary = Framing.encode_unencoded(expected_payload)
	if expected_payload.size() <= Framing.MAX_PAYLOAD_SIZE:
		var expected_encoded: PackedByteArray = wire.duplicate()
		expected_encoded[2] = 0
		expected_encoded[3] = 0
		if entry.has("expected_encoded_hex"):
			expected_encoded = str(entry["expected_encoded_hex"]).hex_decode()
		_check(encoded["ok"] and encoded["bytes"] == expected_encoded, "%s encoder normalization" % label)
	else:
		_check_error(encoded, "invalid_length", "%s receive-only size" % label)


func _test_invalid_fixture(entry: Dictionary) -> void:
	var label: String = str(entry.get("id", "unnamed"))
	var wire: PackedByteArray = str(entry["frame_hex"]).hex_decode()
	var expected_error: String = str(entry["error"])
	for split: int in range(wire.size() + 1):
		var parser = Framing.new()
		var first: Dictionary = parser.feed(wire.slice(0, split))
		var second: Dictionary = parser.feed(wire.slice(split))
		var rejected: Dictionary = second if first["ok"] else first
		_check_error(rejected, expected_error, "%s split %d rejected" % [label, split])
		_check(rejected["frames"].is_empty(), "%s split %d atomic" % [label, split])
		_check_error(parser.feed(PackedByteArray()), "parser_failed", "%s split %d latched feed" % [label, split])
		_check_error(parser.finish(), "parser_failed", "%s split %d latched finish" % [label, split])
		parser.reset()
		_check(parser.pending_size() == 0 and parser.finish()["ok"], "%s split %d reset" % [label, split])


func _test_truncated_fixture(entry: Dictionary) -> void:
	var label: String = str(entry.get("id", "unnamed"))
	var wire: PackedByteArray = str(entry["frame_hex"]).hex_decode()
	var parser = Framing.new()
	var result: Dictionary = parser.feed(wire)
	_check(result["ok"] and result["frames"].is_empty(), "%s awaits bytes" % label)
	_check(parser.pending_size() == wire.size(), "%s retains prefix" % label)
	_check_error(parser.finish(), "truncated_frame", "%s finish detects truncation" % label)
	_check_error(parser.feed(PackedByteArray()), "parser_failed", "%s finish latches failure" % label)


func _test_multiple_frames(valid: Array) -> void:
	var joined: PackedByteArray = PackedByteArray()
	for entry: Dictionary in valid:
		joined.append_array(str(entry["frame_hex"]).hex_decode())
	var parser = Framing.new()
	var result: Dictionary = parser.feed(joined)
	_check(result["ok"] and result["frames"].size() == valid.size(), "all fixtures in one feed")
	var received: Array = result["frames"]
	if received.size() == valid.size():
		for index: int in range(valid.size()):
			var entry: Dictionary = valid[index]
			var frame: PackedByteArray = str(entry["frame_hex"]).hex_decode()
			_check_frame([received[index]], str(entry["payload_hex"]).hex_decode(), int(frame[2]), int(frame[3]), "joined frame %d" % index)
	_check(parser.pending_size() == 0 and parser.finish()["ok"], "joined frames drained")
	# Bytewise delivery exercises a long stream without retaining consumed bytes.
	parser.reset()
	var bytewise_count: int = 0
	for byte: int in joined:
		var one: Dictionary = parser.feed(PackedByteArray([byte]))
		_check(one["ok"], "bytewise stream accepted")
		bytewise_count += one["frames"].size()
		_check(parser.pending_size() < Framing.HEADER_SIZE + Framing.LEGACY_RECEIVE_BODY_CEILING, "bytewise buffer bounded")
	_check(bytewise_count == valid.size() and parser.finish()["ok"], "bytewise frame count")


func _test_boundaries() -> void:
	for size: int in [1, 1492, 1493, 1496]:
		var payload: PackedByteArray = PackedByteArray()
		payload.resize(size)
		for index: int in range(size):
			payload[index] = index & 0xff
		var wire: PackedByteArray = PackedByteArray([size & 0xff, (size >> 8) & 0xff, 0x7f, 0xff])
		wire.append_array(payload)
		var parser = Framing.new()
		var result: Dictionary = parser.feed(wire)
		_check(result["ok"], "decoder boundary %d accepted" % size)
		_check_frame(result["frames"], payload, 0x7f, 0xff, "decoder boundary %d" % size)
		_check(parser.finish()["ok"], "decoder boundary %d finish" % size)
		for split: int in range(wire.size() + 1):
			parser.reset()
			var first: Dictionary = parser.feed(wire.slice(0, split))
			var second: Dictionary = parser.feed(wire.slice(split))
			_check(first["ok"] and second["ok"], "boundary %d split %d accepted" % [size, split])
			_check_frame(first["frames"] + second["frames"], payload, 0x7f, 0xff, "boundary %d split %d" % [size, split])
			_check(parser.pending_size() == 0 and parser.finish()["ok"], "boundary %d split %d drained" % [size, split])
		var encoded: Dictionary = Framing.encode_unencoded(payload)
		if size <= Framing.MAX_PAYLOAD_SIZE:
			_check(encoded["ok"], "encoder boundary %d accepted" % size)
			var normalized: PackedByteArray = encoded["bytes"]
			_check(normalized.size() == Framing.HEADER_SIZE + size and normalized[2] == 0 and normalized[3] == 0, "encoder boundary %d canonical" % size)
		else:
			_check_error(encoded, "invalid_length", "encoder boundary %d rejected" % size)
			_check(encoded["bytes"].is_empty(), "encoder boundary %d emits nothing" % size)
	# A body at the broad receive limit keeps at most one partial frame in memory.
	var large_frame: PackedByteArray = PackedByteArray([0xd8, 0x05, 0, 0])
	large_frame.resize(Framing.HEADER_SIZE + Framing.LEGACY_RECEIVE_BODY_CEILING)
	var large_parser = Framing.new()
	for index: int in range(large_frame.size()):
		var one: Dictionary = large_parser.feed(large_frame.slice(index, index + 1))
		_check(one["ok"], "maximum frame bytewise accepted")
		_check(large_parser.pending_size() < Framing.HEADER_SIZE + Framing.LEGACY_RECEIVE_BODY_CEILING, "maximum frame pending bounded")
		_check(one["frames"].size() == (1 if index == large_frame.size() - 1 else 0), "maximum frame completes only at final byte")
	var long_stream: PackedByteArray = PackedByteArray()
	for repeat_index: int in range(64):
		long_stream.append_array(large_frame)
	long_stream.append_array(PackedByteArray([1, 0]))
	large_parser.reset()
	var long_result: Dictionary = large_parser.feed(long_stream)
	_check(long_result["ok"] and long_result["frames"].size() == 64 and large_parser.pending_size() == 2, "large feed drains complete frames and keeps only tail")
	_check_error(Framing.encode_unencoded(PackedByteArray()), "invalid_length", "empty payload rejected")
	for size: int in [0, 1497, 65535]:
		var parser = Framing.new()
		var result: Dictionary = parser.feed(PackedByteArray([size & 0xff, (size >> 8) & 0xff, 0, 0]))
		_check_error(result, "invalid_length", "decoder boundary %d rejected" % size)
	for flags: int in [0x80, 0x81, 0xff]:
		var parser = Framing.new()
		_check_error(parser.feed(PackedByteArray([1, 0, flags, 0, 0])), "unsupported_encoded_frame", "encoded flags %d rejected" % flags)
	# No sequence continuity, validation or state is imposed on unencoded frames.
	var sequence_stream: PackedByteArray = PackedByteArray()
	for sequence: int in [255, 0, 0, 17, 3]:
		sequence_stream.append_array(PackedByteArray([1, 0, 0, sequence, 42]))
	var parser = Framing.new()
	var sequence_result: Dictionary = parser.feed(sequence_stream)
	_check(sequence_result["ok"] and sequence_result["frames"].size() == 5, "arbitrary sequence order accepted")
	var frame_index: int = 0
	for sequence: int in [255, 0, 0, 17, 3]:
		if frame_index < sequence_result["frames"].size():
			_check(int(sequence_result["frames"][frame_index]["raw_sequence"]) == sequence, "raw sequence retained")
		frame_index += 1


func _test_empty_feed_and_reset() -> void:
	var parser = Framing.new()
	var empty: Dictionary = parser.feed(PackedByteArray())
	_check(empty["ok"] and empty["frames"].is_empty() and parser.pending_size() == 0, "empty feed is no-op")
	parser.feed(PackedByteArray([1, 0]))
	empty = parser.feed(PackedByteArray())
	_check(empty["ok"] and empty["frames"].is_empty() and parser.pending_size() == 2, "empty feed retains prefix")
	parser.reset()
	_check(parser.pending_size() == 0 and parser.finish()["ok"], "reset discards prefix")
	var resumed: Dictionary = parser.feed(PackedByteArray([1, 0, 0, 0, 42]))
	_check_frame(resumed["frames"], PackedByteArray([42]), 0, 0, "reset resumes parser")
	# A completed frame is still returned when followed by an incomplete one.
	parser.reset()
	var partial_tail: Dictionary = parser.feed(PackedByteArray([1, 0, 0, 0, 42, 1, 0]))
	_check(partial_tail["ok"] and partial_tail["frames"].size() == 1 and parser.pending_size() == 2, "complete frame plus partial tail")
	_check_error(parser.finish(), "truncated_frame", "partial tail truncated")
	parser.reset()
	_check(parser.feed(PackedByteArray([1, 0, 0, 0, 42]))["ok"], "reset after truncation resumes")


func _test_atomic_failure(valid: Array, invalid: Array) -> void:
	if valid.is_empty() or invalid.is_empty():
		return
	var good: PackedByteArray = str(valid[0]["frame_hex"]).hex_decode()
	var bad: PackedByteArray = str(invalid[0]["frame_hex"]).hex_decode()
	var together: PackedByteArray = good.duplicate()
	together.append_array(bad)
	together.append_array(good)
	var parser = Framing.new()
	var result: Dictionary = parser.feed(together)
	_check_error(result, str(invalid[0]["error"]), "valid plus invalid feed rejected")
	_check(result["frames"].is_empty(), "failed feed emits no earlier frames")
	_check(parser.pending_size() <= Framing.HEADER_SIZE + Framing.LEGACY_RECEIVE_BODY_CEILING, "failed feed bounded")
	_check_error(parser.feed(good), "parser_failed", "failed parser ignores subsequent frame")
	parser.reset()
	_check(parser.feed(good)["ok"], "reset after invalid frame resumes")


func _check_frame(frames: Array, payload: PackedByteArray, flags: int, sequence: int, label: String) -> void:
	_check(frames.size() == 1, "%s has one frame" % label)
	if frames.size() != 1:
		return
	var frame: Dictionary = frames[0]
	_check(frame["payload"] == payload, "%s payload matches" % label)
	_check(int(frame["raw_flags"]) == flags, "%s flags retained" % label)
	_check(int(frame["raw_sequence"]) == sequence, "%s sequence retained" % label)


func _check_error(result: Dictionary, expected: String, label: String) -> void:
	_check(not result.get("ok", true) and str(result.get("error", "")) == expected, label)


func _check(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(label)


func _report() -> void:
	for failure: String in _failures:
		printerr(JSON.stringify({"suite": "plain_framing", "failure": failure}))
	print(JSON.stringify({"suite": "plain_framing", "status": "pass" if _failures.is_empty() else "fail", "checks": _checks, "failures": _failures.size()}))
	quit(0 if _failures.is_empty() else 1)
