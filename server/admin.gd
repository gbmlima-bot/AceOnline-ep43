extends SceneTree
## Operator-only provisioning; tokens are printed once to this CLI's stdout.
const Store = preload("res://sqlite_store.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var data_dir := "user://server-data"
	var positional: Array[String] = []
	var args := OS.get_cmdline_user_args()
	var index := 0
	while index < args.size():
		var argument := str(args[index])
		if argument.begins_with("--data-dir="):
			data_dir = argument.trim_prefix("--data-dir=")
		elif argument == "--data-dir" and index + 1 < args.size():
			index += 1
			data_dir = str(args[index])
		elif argument.begins_with("--"):
			_fail("Unknown admin option")
			return
		else:
			positional.append(argument)
		index += 1
	if positional.is_empty():
		_fail("Usage: --data-dir=PATH create-pilot LABEL | rotate-token PILOT_ID | backup NEW_PATH | migrate")
		return
	var store := Store.new()
	if not store.open(data_dir.path_join("ace-online.sqlite")):
		_fail(store.error_text)
		return
	var command := positional[0]
	match command:
		"create-pilot":
			if positional.size() < 2:
				_fail("create-pilot requires a label")
				return
			var pilot: Dictionary = store.issue_pilot(" ".join(positional.slice(1)))
			if pilot.is_empty():
				_fail(store.error_text)
				return
			# Do not run this command in build logs; deliver the token privately.
			print(JSON.stringify(pilot))
		"rotate-token":
			if positional.size() != 2:
				_fail("rotate-token requires a pilot ID")
				return
			var token: String = store.rotate_token(positional[1])
			if token.is_empty():
				_fail(store.error_text)
				return
			print(JSON.stringify({"id":positional[1],"token":token}))
		"backup":
			if positional.size() != 2:
				_fail("backup requires a new destination path")
				return
			var backup: Dictionary = store.backup(positional[1])
			if not bool(backup.get("ok",false)):
				_fail(store.error_text)
				return
			print(JSON.stringify(backup))
		"migrate":
			print(JSON.stringify({"ok":true,"schema_version":Store.SCHEMA_VERSION}))
		_:
			_fail("Unknown admin command")
			return
	store.close()
	quit(0)

func _fail(message: String) -> void:
	printerr(message)
	quit(1)
