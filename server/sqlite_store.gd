extends RefCounted
## One durable aggregate per room. No client-authored checkpoint is trusted here.
## godot-sqlite4.9, bound values, WAL/FULL, atomic room revision and receipt.
const EXTENSION_PATH := "res://addons/godot-sqlite/gdsqlite.gdextension"
const SCHEMA_VERSION := 1
const RECEIPTS_PER_PILOT := 1024
const MAX_STATE_BYTES := 16 * 1024 * 1024
const MAX_RESULT_BYTES := 1024 * 1024
const MAX_REVISION := 9007199254740991
var error_text := ""
var _db: Object
var _path := ""

func open(path: String) -> bool:
	close()
	error_text = ""
	if path.is_empty() or path.begins_with("res://") or _contains_nul(path):
		return _error("Invalid database path")
	_path = ProjectSettings.globalize_path(path)
	if not _path.is_absolute_path():
		return _error("Database path must be absolute or user://")
	if DirAccess.make_dir_recursive_absolute(_path.get_base_dir()) != OK:
		return _error("Cannot create database directory")
	if not ClassDB.class_exists("SQLite") and FileAccess.file_exists(EXTENSION_PATH):
		GDExtensionManager.load_extension(EXTENSION_PATH)
	if not ClassDB.class_exists("SQLite"):
		return _error("godot-sqlite extension is unavailable")
	_db = ClassDB.instantiate("SQLite")
	_db.set("path", _path)
	_db.set("default_extension", "")
	_db.set("foreign_keys", true)
	_db.set("verbosity_level", 0)
	if not bool(_db.call("open_db")):
		var detail := str(_db.get("error_message"))
		close()
		return _error("Cannot open SQLite database: " + detail)
	if OS.get_name() in ["Linux", "macOS", "FreeBSD", "NetBSD", "OpenBSD"]:
		FileAccess.set_unix_permissions(_path, 384) #0600; SQLite WAL inherits DB permissions.
	for sql: String in ["PRAGMA foreign_keys = ON", "PRAGMA busy_timeout = 5000", "PRAGMA journal_mode = WAL", "PRAGMA synchronous = FULL"]:
		if not _exec(sql):
			close()
			return false
	if not _exec("PRAGMA journal_mode") or str(_rows()[0].get("journal_mode", "")).to_lower() != "wal":
		close()
		return _error("SQLite WAL journal did not enable")
	if not _exec("PRAGMA busy_timeout") or int(_rows()[0].get("timeout", 0)) != 5000:
		close()
		return _error("SQLite busy timeout did not enable")
	if not _exec("PRAGMA foreign_keys") or int(_rows()[0].get("foreign_keys", 0)) != 1:
		close()
		return _error("SQLite foreign keys did not enable")
	if not _exec("PRAGMA synchronous") or int(_rows()[0].get("synchronous", 0)) != 2:
		close()
		return _error("SQLite FULL synchronization did not enable")
	if not migrate():
		close()
		return false
	return true

func close() -> void:
	if _db != null and is_instance_valid(_db):
		_db.call("close_db")
	_db = null

func migrate() -> bool:
	if not _exec("PRAGMA user_version"):
		return false
	var version := int(_rows()[0].get("user_version", 0))
	if version > SCHEMA_VERSION:
		return _error("Database schema is newer than this server")
	if not _exec("BEGIN IMMEDIATE"):
		return false
	var statements: Array[String] = [
		"CREATE TABLE IF NOT EXISTS pilots (id TEXT PRIMARY KEY NOT NULL CHECK(length(id)=32), label TEXT NOT NULL CHECK(length(label) BETWEEN 1 AND 80), token_hash TEXT UNIQUE NOT NULL CHECK(length(token_hash)=64), created_at INTEGER NOT NULL, token_updated_at INTEGER NOT NULL, enabled INTEGER NOT NULL DEFAULT 1 CHECK(enabled IN (0,1)))",
		"CREATE TABLE IF NOT EXISTS rooms (id TEXT PRIMARY KEY NOT NULL, revision INTEGER NOT NULL CHECK(typeof(revision)='integer' AND revision>=0), state_json TEXT NOT NULL, updated_at INTEGER NOT NULL)",
		"CREATE TABLE IF NOT EXISTS receipts (pilot_id TEXT NOT NULL REFERENCES pilots(id) ON DELETE CASCADE, request_id TEXT NOT NULL CHECK(length(request_id) BETWEEN 1 AND 128), room_id TEXT NOT NULL REFERENCES rooms(id) ON DELETE CASCADE, revision INTEGER NOT NULL CHECK(typeof(revision)='integer' AND revision>0), result_json TEXT NOT NULL, created_at INTEGER NOT NULL, PRIMARY KEY(pilot_id,request_id))",
		"CREATE INDEX IF NOT EXISTS receipts_pilot_revision ON receipts(pilot_id, revision DESC)",
		"PRAGMA user_version = 1"
	]
	for sql: String in statements:
		if not _exec(sql):
			_rollback()
			return false
	if not _exec("COMMIT"):
		_rollback()
		return false
	return true

func issue_pilot(label: String) -> Dictionary:
	error_text = ""
	var clean := label.strip_edges()
	if not _valid_label(clean):
		_error("Pilot label must contain1..80 printable characters")
		return {}
	var crypto := Crypto.new()
	var id_bytes := crypto.generate_random_bytes(16)
	var token_bytes := crypto.generate_random_bytes(32)
	if id_bytes.size() != 16 or token_bytes.size() != 32:
		_error("Secure random generator failed")
		return {}
	var identifier := id_bytes.hex_encode()
	var token := token_bytes.hex_encode()
	var now := int(Time.get_unix_time_from_system())
	if not _exec("INSERT INTO pilots(id,label,token_hash,created_at,token_updated_at) VALUES(?,?,?,?,?)", [identifier, clean, token.sha256_text(), now, now]):
		return {}
	return {"id": identifier, "label": clean, "token": token}

func authenticate(token: String) -> Dictionary:
	error_text = ""
	if token.length() != 64 or not token.is_valid_hex_number(false):
		return {}
	if not _exec("SELECT id,label FROM pilots WHERE token_hash=? AND enabled=1 LIMIT 1", [token.sha256_text()]):
		return {}
	var result := _rows()
	if result.is_empty():
		return {}
	return {"id": str(result[0].id), "label": str(result[0].label)}

func token_hash_active(pilot_id: String, sha256: String) -> bool:
	error_text = ""
	if not _valid_pilot_id(pilot_id) or sha256.length() != 64 or not sha256.is_valid_hex_number(false):
		return false
	if not _exec("SELECT id FROM pilots WHERE id=? AND token_hash=? AND enabled=1 LIMIT 1", [pilot_id,sha256.to_lower()]):
		return false
	return not _rows().is_empty()

func rotate_token(identifier: String) -> String:
	error_text = ""
	if not _valid_pilot_id(identifier):
		_error("Invalid pilot identifier")
		return ""
	var token_bytes := Crypto.new().generate_random_bytes(32)
	if token_bytes.size() != 32:
		_error("Secure random generator failed")
		return ""
	var token := token_bytes.hex_encode()
	if not _exec("BEGIN IMMEDIATE"):
		return ""
	if not _exec("SELECT id FROM pilots WHERE id=? AND enabled=1", [identifier]):
		_rollback()
		return ""
	if _rows().is_empty():
		_error("Pilot not found")
		_rollback()
		return ""
	if not _exec("UPDATE pilots SET token_hash=?,token_updated_at=? WHERE id=?", [token.sha256_text(), int(Time.get_unix_time_from_system()), identifier]) or not _exec("COMMIT"):
		_rollback()
		return ""
	return token

func load_room(room_id: String = "main") -> Dictionary:
	error_text = ""
	if not _valid_room_id(room_id):
		_error("Invalid room identifier")
		return {}
	if not _exec("SELECT revision,state_json FROM rooms WHERE id=? LIMIT 1", [room_id]):
		return {}
	var result := _rows()
	if result.is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(str(result[0].state_json))
	if not parsed is Dictionary:
		_error("Stored room JSON is invalid")
		return {}
	parsed["room_id"] = room_id
	parsed["revision"] = int(result[0].revision)
	return parsed

func get_receipt(pilot_id: String, request_id: String) -> Dictionary:
	error_text = ""
	if not _valid_pilot_id(pilot_id) or not _valid_request_id(request_id):
		return {}
	if not _exec("SELECT room_id,revision,result_json FROM receipts WHERE pilot_id=? AND request_id=? LIMIT 1", [pilot_id,request_id]):
		return {}
	var result := _rows()
	if result.is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(str(result[0].result_json))
	if not parsed is Dictionary:
		_error("Stored receipt JSON is invalid")
		return {}
	return {"pilot_id": pilot_id, "request_id": request_id, "room_id":str(result[0].room_id), "revision":int(result[0].revision), "result":parsed}

func commit_room(state: Dictionary, request_id: String = "", pilot_id: String = "", result: Dictionary = {}) -> Dictionary:
	error_text = ""
	var room_id := str(state.get("room_id", "main"))
	if not _valid_room_id(room_id) or not _json_value(state) or not _json_value(result):
		return _failure("invalid_room_state")
	var with_receipt := not request_id.is_empty() or not pilot_id.is_empty()
	if with_receipt and (not _valid_pilot_id(pilot_id) or not _valid_request_id(request_id)):
		return _failure("invalid_receipt_identity")
	var expected: Variant = state.get("revision", 0)
	if not _revision_number(expected):
		return _failure("invalid_revision")
	var result_json := JSON.stringify(result)
	if result_json.to_utf8_buffer().size() > MAX_RESULT_BYTES:
		return _failure("result_too_large")
	if not _exec("BEGIN IMMEDIATE"):
		return _failure("begin_failed")
	if with_receipt:
		var receipt := get_receipt(pilot_id, request_id)
		if not error_text.is_empty():
			_rollback()
			return _failure("receipt_read_failed")
		if not receipt.is_empty():
			_rollback()
			if str(receipt.room_id) != room_id:
				return _failure("request_room_conflict")
			return {"ok":true,"revision":int(receipt.revision),"result":receipt.result,"duplicate":true}
	if with_receipt:
		if not _exec("SELECT id FROM pilots WHERE id=? AND enabled=1", [pilot_id]):
			_rollback()
			return _failure("pilot_read_failed")
		if _rows().is_empty():
			_rollback()
			return _failure("pilot_not_found")
	if not _exec("SELECT revision FROM rooms WHERE id=?", [room_id]):
		_rollback()
		return _failure("room_read_failed")
	var rows := _rows()
	var current := int(rows[0].revision) if not rows.is_empty() else 0
	if current != int(expected):
		_rollback()
		return {"ok":false,"revision":current,"error":"revision_conflict"}
	if current >= MAX_REVISION:
		_rollback()
		return _failure("revision_limit")
	var revision := current + 1
	var candidate := state.duplicate(true)
	candidate["room_id"] = room_id
	candidate["revision"] = revision
	var payload := JSON.stringify(candidate)
	if payload.to_utf8_buffer().size() > MAX_STATE_BYTES:
		_rollback()
		return _failure("room_too_large")
	var now := int(Time.get_unix_time_from_system())
	if not _exec("INSERT INTO rooms(id,revision,state_json,updated_at) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,state_json=excluded.state_json,updated_at=excluded.updated_at", [room_id,revision,payload,now]):
		_rollback()
		return _failure("room_write_failed")
	if with_receipt:
		if not _exec("INSERT INTO receipts(pilot_id,request_id,room_id,revision,result_json,created_at) VALUES(?,?,?,?,?,?)", [pilot_id,request_id,room_id,revision,result_json,now]):
			_rollback()
			return _failure("receipt_write_failed")
		if not _exec("DELETE FROM receipts WHERE pilot_id=? AND rowid NOT IN (SELECT rowid FROM receipts WHERE pilot_id=? ORDER BY rowid DESC LIMIT ?)", [pilot_id,pilot_id,RECEIPTS_PER_PILOT]):
			_rollback()
			return _failure("receipt_retention_failed")
	if not _exec("COMMIT"):
		_rollback()
		return _failure("commit_failed")
	return {"ok":true,"revision":revision,"result":result.duplicate(true)}

func backup(destination: String) -> Dictionary:
	error_text = ""
	if _db == null or not _db.has_method("backup_to"):
		return _failure("backup_unavailable")
	var target := ProjectSettings.globalize_path(destination)
	if not target.is_absolute_path() or target == _path or FileAccess.file_exists(target):
		return _failure("backup_destination_must_be_new")
	if DirAccess.make_dir_recursive_absolute(target.get_base_dir()) != OK:
		return _failure("backup_directory_failed")
	if not bool(_db.call("backup_to", target)):
		return _failure("backup_failed")
	if OS.get_name() in ["Linux", "macOS", "FreeBSD", "NetBSD", "OpenBSD"]:
		FileAccess.set_unix_permissions(target,384)
	return {"ok":true,"path":target}

func _exec(sql: String, bindings: Array = []) -> bool:
	if _db == null:
		return _error("Database is not open")
	if not bool(_db.call("query_with_bindings", sql, bindings)):
		return _error(str(_db.get("error_message")))
	return true

func _rows() -> Array:
	return (_db.get("query_result") as Array).duplicate(true)

func _rollback() -> void:
	var previous := error_text
	if _db != null:
		_db.call("query", "ROLLBACK")
	error_text = previous

func _error(message: String) -> bool:
	error_text = message
	return false

func _failure(code: String) -> Dictionary:
	if error_text.is_empty(): error_text = code
	return {"ok":false,"error":code}

static func _valid_pilot_id(identifier: String) -> bool:
	return identifier.length() == 32 and identifier.is_valid_hex_number(false)

static func valid_request_id(identifier: String) -> bool:
	# Network contract: ^[A-Za-z0-9._:-]{1,128}$
	if identifier.is_empty() or identifier.length() > 128: return false
	for index in range(identifier.length()):
		var code := identifier.unicode_at(index)
		if not ((code >= 48 and code <= 57) or (code >= 65 and code <= 90) or (code >= 97 and code <= 122) or code in [45,46,58,95]): return false
	return true

static func _valid_request_id(identifier: String) -> bool:
	return valid_request_id(identifier)

static func _valid_room_id(identifier: String) -> bool:
	return identifier.length() > 0 and identifier.length() <= 64 and identifier.is_valid_identifier()

static func _valid_label(label: String) -> bool:
	if label.is_empty() or label.length() > 80: return false
	for index in range(label.length()):
		if label.unicode_at(index) < 32 or label.unicode_at(index) == 127: return false
	return true

static func _revision_number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) == floorf(float(value)) and float(value) >= 0.0 and float(value) <= MAX_REVISION

static func _json_value(value: Variant, depth: int = 0) -> bool:
	if depth > 32: return false
	if value == null or value is bool or value is String: return true
	if value is int: return int(value) >= -MAX_REVISION and int(value) <= MAX_REVISION
	if value is float: return is_finite(float(value))
	if value is Array:
		for member: Variant in value:
			if not _json_value(member,depth+1): return false
		return true
	if value is Dictionary:
		var canonical_keys: Dictionary = {}
		for key: Variant in value:
			# Native skill/proof dictionaries use integer IDs; JSON turns these into strings.
			if not (key is String or key is int) or canonical_keys.has(str(key)) or not _json_value(value[key],depth+1): return false
			canonical_keys[str(key)] = true
		return true
	return false

static func _contains_nul(value: String) -> bool:
	for index in range(value.length()):
		if value.unicode_at(index) == 0: return true
	return false
