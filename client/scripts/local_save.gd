class_name LocalSave
extends RefCounted
## Offline progress only. Native account credentials and original server data
## are never part of this format. Writes keep the previous valid file as backup.

const DEFAULT_PATH := "user://progress.json"
const FORMAT := "ace-modern-local-save"
const MAX_BYTES := 16 * 1024 * 1024


static func exists(path: String = DEFAULT_PATH) -> bool:
	return FileAccess.file_exists(path) or FileAccess.file_exists(path + ".bak")


static func save_game(snapshot: Dictionary, path: String = DEFAULT_PATH) -> Dictionary:
	if not _valid_path(path):
		return _error("invalid_path", "O progresso só pode ser salvo na pasta local do jogo.")
	if not _valid_snapshot(snapshot):
		return _error("invalid_snapshot", "O estado da sessão está incompleto.")
	var payload := JSON.stringify(snapshot)
	if payload.to_utf8_buffer().size() > MAX_BYTES / 2:
		return _error("save_too_large", "O progresso excede o limite do arquivo local.")
	var document := JSON.stringify({"format": FORMAT, "schema_version": 1, "sha256": payload.sha256_text(), "payload": payload})
	if document.to_utf8_buffer().size() > MAX_BYTES:
		return _error("save_too_large", "O progresso excede o limite do arquivo local.")
	var directory := ProjectSettings.globalize_path(path.get_base_dir())
	if DirAccess.make_dir_recursive_absolute(directory) != OK:
		return _error("directory_unavailable", "Não foi possível abrir a pasta de progresso.")
	var temporary := path + ".tmp"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return _error("write_failed", "Não foi possível gravar o progresso local.")
	file.store_string(document)
	file.flush()
	var write_error := file.get_error()
	file.close()
	if write_error != OK:
		DirAccess.remove_absolute(temporary)
		return _error("write_failed", "Não foi possível concluir a gravação do progresso.")
	var backup := path + ".bak"
	if FileAccess.file_exists(path):
		# Do not overwrite a good backup with a damaged primary file.
		if bool(_read_one(path).get("ok", false)):
			if FileAccess.file_exists(backup):
				DirAccess.remove_absolute(backup)
			if DirAccess.rename_absolute(path, backup) != OK:
				DirAccess.remove_absolute(temporary)
				return _error("backup_failed", "Não foi possível preservar o progresso anterior.")
		else:
			DirAccess.remove_absolute(path)
	if DirAccess.rename_absolute(temporary, path) != OK:
		if not FileAccess.file_exists(path) and FileAccess.file_exists(backup):
			DirAccess.copy_absolute(backup, path)
		return _error("commit_failed", "Não foi possível concluir a gravação do progresso.")
	return {"ok": true, "path": path, "message": "Progresso salvo neste dispositivo."}


static func read_game(path: String = DEFAULT_PATH) -> Dictionary:
	if not _valid_path(path):
		return _error("invalid_path", "Caminho de progresso inválido.")
	var primary := _read_one(path)
	if bool(primary.get("ok", false)):
		primary["backup_used"] = false
		return primary
	var backup := _read_one(path + ".bak")
	if bool(backup.get("ok", false)):
		backup["backup_used"] = true
		backup["message"] = "Progresso recuperado da cópia anterior."
		return backup
	return primary


static func _read_one(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return _error("not_found", "Ainda não há progresso salvo neste dispositivo.")
	if file.get_length() <= 0 or file.get_length() > MAX_BYTES:
		file.close()
		return _error("invalid_size", "O arquivo de progresso tem um tamanho inválido.")
	var raw := file.get_as_text()
	file.close()
	var document: Variant = JSON.parse_string(raw)
	if not document is Dictionary or document.get("format") != FORMAT or int(document.get("schema_version", 0)) != 1:
		return _error("invalid_format", "O arquivo de progresso não é compatível.")
	var payload: Variant = document.get("payload")
	if not payload is String or str(document.get("sha256", "")) != payload.sha256_text():
		return _error("checksum_mismatch", "O arquivo de progresso está danificado.")
	var snapshot: Variant = JSON.parse_string(payload)
	if not snapshot is Dictionary or not _valid_snapshot(snapshot):
		return _error("invalid_snapshot", "O arquivo de progresso está incompleto.")
	return {"ok": true, "snapshot": snapshot, "path": path, "message": "Progresso carregado deste dispositivo."}


static func _valid_snapshot(value: Dictionary) -> bool:
	return int(value.get("schema_version", 0)) == 1 and value.get("world") is Dictionary and value.get("combat") is Dictionary and value.get("flight") is Dictionary


static func _valid_path(path: String) -> bool:
	return path.begins_with("user://") and not path.contains("..") and path.ends_with(".json") and path.length() < 256


static func _error(code: String, message: String) -> Dictionary:
	return {"ok": false, "error": code, "message": message}
