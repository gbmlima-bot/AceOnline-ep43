extends SceneTree
const Store = preload("res://sqlite_store.gd")
const PATH := "user://test-server-store.sqlite"
const BACKUP_PATH := "user://test-server-store-backup.sqlite"
var checks := 0
var failures: Array[String] = []

class InjectedFailureDatabase:
	extends RefCounted
	var native: Object
	var prefix := ""
	var fired := false
	var query_result: Array:
		get: return native.get("query_result")
	var error_message: String:
		get: return "Injected transaction write failure" if fired else str(native.get("error_message"))
	func query_with_bindings(sql: String, bindings: Array) -> bool:
		if not fired and sql.begins_with(prefix):
			fired = true
			return false
		return bool(native.call("query_with_bindings",sql,bindings))
	func query(sql: String) -> bool:
		return bool(native.call("query",sql))
	func close_db() -> void:
		native.call("close_db")

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition: failures.append(message)

func _run() -> void:
	_clean(PATH)
	_clean(BACKUP_PATH)
	var store := Store.new()
	_check(store.open(PATH), "SQLite extension opens real database and migrates")
	if not failures.is_empty():
		printerr("Store startup failed: " + store.error_text)
		_finish()
		return
	_test_pragmas(store)
	var label := "Pilot O'Brien'; DROP TABLE pilots;--"
	var first: Dictionary = store.issue_pilot(label)
	var second: Dictionary = store.issue_pilot("Piloto João")
	_check(not first.is_empty() and not second.is_empty(), "operator issues two pilot identities")
	if first.is_empty() or second.is_empty():
		store.close()
		_finish()
		return
	_check(str(first.id).length()==32 and str(first.token).length()==64 and first.id!=second.id and first.token!=second.token, "CSPRNG pilot/token lengths and distinct values")
	_check(store.authenticate(first.token)=={"id":first.id,"label":label}, "binding preserves quoted SQL-like label without executing it")
	_check(store.authenticate(second.token).get("label")=="Piloto João", "UTF8 pilot authentication")
	_check(str(first.token)==str(first.token).to_upper() or store.authenticate(str(first.token).to_upper()).is_empty(), "opaque token authentication remains case-sensitive for session hash revalidation")
	_check(store.authenticate("not-a-token").is_empty() and store.authenticate("f".repeat(64)).is_empty(), "unknown or malformed token authenticates nobody")
	_check(store.issue_pilot("").is_empty() and store.issue_pilot("x".repeat(81)).is_empty() and store.issue_pilot("control\nlabel").is_empty(), "invalid operator labels rejected")
	_check(store.load_room().is_empty() and store.error_text.is_empty(), "new room is explicit empty state")
	var initial := {"pilots":{str(first.id):{"inventory":{"credits":100,"items":[{"item_num":7000790,"count":1}]},"world":{"wallet":{"credits":100,"experience":91}},"systems":{"skills":{"cooldowns":{7830010:2.0}},"services":{"rng_state":"-9223372036854775808","operations":1}}}}}
	var result: Dictionary = store.commit_room(initial,"buy-1",first.id,{"ok":true,"cost":60})
	_check(bool(result.get("ok",false)) and typeof(result.get("revision"))==TYPE_INT and result.revision==1, "aggregate and typed server revision commit together")
	_check(not initial.has("revision"), "commit does not mutate caller candidate")
	var persisted: Dictionary = store.load_room()
	_check(persisted.revision==1 and persisted.room_id=="main" and persisted.pilots[first.id].inventory.credits==100 and persisted.pilots[first.id].systems.skills.cooldowns.has("7830010"), "whole aggregate preserves integer-ID native dictionaries through JSON")
	var receipt: Dictionary = store.get_receipt(first.id,"buy-1")
	_check(receipt.revision==1 and receipt.result==JSON.parse_string('{"ok":true,"cost":60}'), "receipt atomically contains original result")
	var duplicate: Dictionary = store.commit_room({"revision":0,"pilots":{}},"buy-1",first.id,{"ok":false})
	_check(bool(duplicate.get("ok",false)) and bool(duplicate.get("duplicate",false)) and duplicate.revision==1 and duplicate.result.cost==60 and store.load_room()==persisted, "same request replays original result without rewinding or consuming again")
	_check(store.get_receipt(second.id,"buy-1").is_empty(), "receipt lookup is isolated by pilot identity")
	var bad: Dictionary = persisted.duplicate(true)
	bad.revision=0
	bad.pilots[first.id].inventory.credits=9999
	result=store.commit_room(bad,"stale",first.id,{})
	_check(not bool(result.ok) and result.error=="revision_conflict" and result.revision==1 and store.load_room()==persisted and store.get_receipt(first.id,"stale").is_empty(), "stale revision cannot overwrite aggregate or leave receipt")
	result=store.commit_room(persisted,"unknown-pilot","0".repeat(32),{})
	_check(not bool(result.ok) and result.error=="pilot_not_found" and store.load_room()==persisted, "unknown pilot cannot leave a partially updated room")
	for invalid: Dictionary in [{"revision":1.5},{"revision":-1},{"value":NAN},{"value":INF},{"object":Node.new()},{"unsafe_integer":9223372036854775807},{"collision":{1:"a","1":"b"}}]:
		_check(not bool(store.commit_room(invalid).get("ok",false)), "non-JSON/ambiguous/unsafe state rejected before transaction")
		if invalid.get("object") is Node: (invalid.object as Node).free()
	_check(store.load_room()==persisted, "invalid values preserve last durable aggregate")
	_test_atomic_failure(store,first.id,persisted,"INSERT INTO receipts", "receipt_write_failed")
	_test_atomic_failure(store,first.id,persisted,"COMMIT", "commit_failed")
	var second_connection := Store.new()
	_check(second_connection.open(PATH), "second SQLite connection observes same WAL database")
	var stale: Dictionary = second_connection.load_room()
	var next: Dictionary = persisted.duplicate(true)
	next.pilots[first.id].inventory.credits=90
	result=store.commit_room(next,"owner-update",first.id,{"ok":true})
	_check(bool(result.ok) and result.revision==2, "current owner revision advances once")
	_check(not bool(second_connection.commit_room(stale).get("ok",false)), "independent connection cannot commit stale copy")
	second_connection.close()
	var rotated: String = store.rotate_token(first.id)
	_check(rotated.length()==64 and rotated!=str(first.token) and store.authenticate(first.token).is_empty() and store.authenticate(rotated).get("id")==first.id, "rotation invalidates old credential and authenticates replacement")
	_check(store.rotate_token("0".repeat(32)).is_empty(), "rotation of nonexistent pilot produces no credential")
	_check(store.token_hash_active(first.id,rotated.sha256_text()), "current credential hash keeps authenticated session active")
	_check(not store.token_hash_active(first.id,str(first.token).sha256_text()), "rotated credential hash revokes existing session")
	_check(Store.valid_request_id("cli-42:buy_1.v1") and not Store.valid_request_id("x".repeat(129)) and not Store.valid_request_id("x\ny") and not Store.valid_request_id("ação"), "request ID network grammar is bounded ASCII without control characters")
	_check(_no_plaintext_tokens(first.token,second.token,rotated), "database and WAL never contain plaintext tokens")
	_test_retention(store,first.id,second.id)
	var expected: Dictionary = store.load_room()
	store.close()
	_check(store.open(PATH) and store.load_room()==expected and store.authenticate(rotated).get("id")==first.id, "real close/reopen preserves aggregate, sequence and hashed pilot credentials")
	var backup: Dictionary = store.backup(BACKUP_PATH)
	_check(bool(backup.get("ok",false)) and FileAccess.file_exists(BACKUP_PATH), "native SQLite online backup produces standalone database")
	var backup_store := Store.new()
	_check(backup_store.open(BACKUP_PATH) and backup_store.load_room()==expected and backup_store.authenticate(rotated).get("id")==first.id, "backup restores full latest aggregate and credentials without copying active WAL files")
	backup_store.close()
	_check(not bool(store.backup(BACKUP_PATH).get("ok",false)), "backup refuses to overwrite existing destination")
	_check(store.migrate(), "migration is idempotent")
	store._exec("PRAGMA user_version = 999")
	store.close()
	_check(not store.open(PATH) and not store.error_text.is_empty(), "future schema refuses accidental downgrade")
	store.close()
	_clean(PATH)
	_clean(BACKUP_PATH)
	_finish()

func _test_pragmas(store: RefCounted) -> void:
	for pair: Array in [["foreign_keys",1],["synchronous",2],["busy_timeout",5000],["user_version",1]]:
		_check(store._exec("PRAGMA "+str(pair[0])) and int(store._rows()[0].values()[0])==int(pair[1]), "required SQLite pragma "+str(pair[0]))
	_check(store._exec("PRAGMA journal_mode") and str(store._rows()[0].get("journal_mode","")).to_lower()=="wal", "real SQLite WAL journal enabled")

func _test_atomic_failure(store: RefCounted,pilot_id: String,previous: Dictionary,prefix: String,code: String) -> void:
	var native: Object = store._db
	var injected := InjectedFailureDatabase.new()
	injected.native=native
	injected.prefix=prefix
	store._db=injected
	var changed: Dictionary=previous.duplicate(true)
	changed.pilots[pilot_id].inventory.credits=1
	var result: Dictionary=store.commit_room(changed,"injected-"+code,pilot_id,{"ok":true})
	store._db=native
	_check(injected.fired and not bool(result.get("ok",false)) and result.get("error")==code, "injected transaction failure exercises "+code)
	_check(store.load_room()==previous and store.get_receipt(pilot_id,"injected-"+code).is_empty(), "SQLite rollback removes room update and receipt on "+code)

func _test_retention(store: RefCounted,pilot_id: String,other_id: String) -> void:
	var current: Dictionary=store.load_room()
	var second: Dictionary=store.commit_room(current,"protected",other_id,{"ok":true})
	_check(bool(second.get("ok",false)), "other pilot receipt fixture commits normally")
	var all_committed := true
	for index in range(Store.RECEIPTS_PER_PILOT+10):
		current=store.load_room()
		current["counter"]=index
		var result: Dictionary=store.commit_room(current,"retention-"+str(index),pilot_id,{"index":index})
		if not bool(result.get("ok",false)):
			all_committed=false
			break
	_check(all_committed, "more than1000 real FULL-synchronous commits complete")
	store._exec("SELECT COUNT(*) AS count FROM receipts WHERE pilot_id=?",[pilot_id])
	_check(int(store._rows()[0].count)==Store.RECEIPTS_PER_PILOT and Store.RECEIPTS_PER_PILOT>=1000, "receipt retention is bounded to1024 per pilot")
	_check(store.get_receipt(pilot_id,"retention-0").is_empty() and not store.get_receipt(pilot_id,"retention-"+str(Store.RECEIPTS_PER_PILOT+9)).is_empty(), "oldest receipts expire while latest remain replayable")
	_check(not store.get_receipt(other_id,"protected").is_empty(), "retention cannot erase another pilot receipts")
	# Same request ID may be independently used by a different pilot.
	current=store.load_room()
	_check(bool(store.commit_room(current,"protected",pilot_id,{"ok":true}).get("ok",false)), "receipt IDs are namespaced per pilot")

func _no_plaintext_tokens(one: String,two: String,three: String) -> bool:
	for suffix: String in ["","-wal","-shm"]:
		var path:=ProjectSettings.globalize_path(PATH)+suffix
		if not FileAccess.file_exists(path): continue
		var encoded:=FileAccess.get_file_as_bytes(path).hex_encode()
		for token: String in [one,two,three]:
			if encoded.contains(token.to_utf8_buffer().hex_encode()): return false
	return true

func _clean(path: String) -> void:
	for suffix: String in ["","-wal","-shm"]:
		var target:=ProjectSettings.globalize_path(path)+suffix
		if FileAccess.file_exists(target): DirAccess.remove_absolute(target)

func _finish() -> void:
	print("STORE_TEST="+JSON.stringify({"checks":checks,"failures":failures,"real_sqlite":true,"receipts_per_pilot":Store.RECEIPTS_PER_PILOT}))
	for failure: String in failures: push_error(failure)
	if failures.is_empty(): print("PASS: SQLite store — %d checks; hashed tokens, WAL/FULL, aggregate+revision+receipt transactions, rollback, retention and native online backup" % checks)
	quit(0 if failures.is_empty() else 1)
