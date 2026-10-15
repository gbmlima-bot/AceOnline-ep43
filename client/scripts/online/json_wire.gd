extends RefCounted
## Bounded text JSON only. This protocol never serializes Godot objects.

const PROTOCOL := "ace-pve/1"
const MAX_FRAME_BYTES := 16 * 1024
const MAX_DEPTH := 12
const MAX_SAFE_INTEGER := 9007199254740991


static func encode(value: Dictionary) -> String:
	if not _valid_value(value, 0) or not value.get("op") is String:
		return ""
	var text := JSON.stringify(value)
	return text if text.to_utf8_buffer().size() <= MAX_FRAME_BYTES else ""


static func decode(bytes: PackedByteArray) -> Dictionary:
	if bytes.is_empty() or bytes.size() > MAX_FRAME_BYTES:
		return {}
	var text := bytes.get_string_from_utf8()
	if text.to_utf8_buffer() != bytes or not _bounded_nesting(text):
		return {}
	var parser := JSON.new()
	if parser.parse(text) != OK:
		return {}
	var value: Variant = parser.data
	if not value is Dictionary or not value.get("op") is String or value.op.is_empty() or value.op.length() > 32 or not _valid_value(value, 0):
		return {}
	return _normalize_numbers(value)


static func _valid_value(value: Variant, depth: int) -> bool:
	if depth > MAX_DEPTH:
		return false
	if value is Dictionary:
		if value.size() > 256:
			return false
		for key: Variant in value:
			if not key is String or key.length() > 128 or not _valid_value(value[key], depth + 1):
				return false
		return true
	if value is Array:
		if value.size() > 1024:
			return false
		for element: Variant in value:
			if not _valid_value(element, depth + 1):
				return false
		return true
	if value is float:
		return is_finite(value) and absf(value) <= float(MAX_SAFE_INTEGER)
	if value is int:
		return value >= -MAX_SAFE_INTEGER and value <= MAX_SAFE_INTEGER
	if value is String:
		return value.length() <= MAX_FRAME_BYTES and value.to_utf8_buffer().size() <= MAX_FRAME_BYTES
	return value == null or value is bool or value is int or value is String


static func _normalize_numbers(value: Variant) -> Variant:
	if value is Dictionary:
		for key: String in value:
			value[key] = _normalize_numbers(value[key])
	elif value is Array:
		for index in range(value.size()):
			value[index] = _normalize_numbers(value[index])
	elif value is float and floor(value) == value:
		return int(value)
	return value


static func _bounded_nesting(text: String) -> bool:
	var depth := 0
	var quoted := false
	var escaped := false
	for character: String in text:
		if quoted:
			if escaped:
				escaped = false
			elif character == "\\":
				escaped = true
			elif character == '"':
				quoted = false
		elif character == '"':
			quoted = true
		elif character == "{" or character == "[":
			depth += 1
			if depth > MAX_DEPTH:
				return false
		elif character == "}" or character == "]":
			depth -= 1
			if depth < 0:
				return false
	return depth == 0 and not quoted
