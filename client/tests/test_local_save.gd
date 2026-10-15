extends SceneTree

const Save = preload("res://scripts/local_save.gd")
const PATH := "user://test-local-save.json"
var failures: Array[String] = []
var checks := 0


func _initialize() -> void:
	for suffix: String in ["", ".tmp", ".bak"]:
		DirAccess.remove_absolute(PATH + suffix)
	var snapshot := {"schema_version": 1, "world": {"map_id": 3002, "progress": {"102": {"kills": 2}}}, "combat": {"inventory": {"credits": 320}}, "flight": {"position": [1, 105, 3]}}
	_check(not Save.read_game(PATH).ok, "missing progress is explicit")
	_check(not Save.save_game(snapshot, "res://test.json").ok, "cannot write to application resources")
	_check(not Save.save_game(snapshot, "user://../test.json").ok, "cannot traverse user data directory")
	_check(not Save.save_game({}, PATH).ok, "incomplete state rejected before writing")
	_check(Save.save_game(snapshot, PATH).ok, "first atomic write succeeds")
	_check(Save.read_game(PATH).snapshot.world.progress["102"].kills == 2, "mission progress round-trips as data")
	snapshot.world.progress["102"].kills = 3
	_check(Save.save_game(snapshot, PATH).ok, "second write preserves prior state")
	var damaged := FileAccess.open(PATH, FileAccess.WRITE)
	damaged.store_string("{\"format\":\"ace-modern-local-save\",\"schema_version\":1,\"sha256\":\"incorrect\",\"payload\":\"{}\"}")
	damaged.close()
	var recovered: Dictionary = Save.read_game(PATH)
	_check(recovered.ok and recovered.backup_used and recovered.snapshot.world.progress["102"].kills == 2, "tampered primary recovers exact previous checkpoint")
	_check(Save.save_game(snapshot, PATH).ok, "damaged primary can be replaced without destroying backup")
	_check(Save.read_game(PATH).snapshot.world.progress["102"].kills == 3, "new checkpoint replaces damaged state")
	_check(Save.exists(PATH), "existing checkpoint is discoverable")
	for suffix: String in ["", ".tmp", ".bak"]:
		DirAccess.remove_absolute(PATH + suffix)
	print(JSON.stringify({"suite": "local_save", "checks": checks, "failures": failures.size()}))
	for failure: String in failures:
		push_error(failure)
	quit(0 if failures.is_empty() else 1)


func _check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)
