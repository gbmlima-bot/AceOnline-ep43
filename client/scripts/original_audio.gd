class_name OriginalAudio
extends Node
## Native BGM index/file bindings and proven SOUND_* effects, played locally.
## Event timing is the new runtime's integration; no invented weapon sounds.

const REGISTRY := "res://assets/original_library/audio/registry.json"
var music: AudioStreamPlayer
var voices: Array[AudioStreamPlayer] = []
var muted := false
var current_bgm := -1
var current_path := ""
var _registry: Dictionary = {}
var _voice_index := 0


func _ready() -> void:
	music = AudioStreamPlayer.new()
	music.name = "OriginalMapMusic"
	music.volume_db = -15.0
	add_child(music)
	for index in range(8):
		var voice := AudioStreamPlayer.new()
		voice.name = "OriginalEffect%d" % index
		voice.volume_db = -12.0
		add_child(voice)
		voices.append(voice)
	if FileAccess.file_exists(REGISTRY):
		var value: Variant = JSON.parse_string(FileAccess.get_file_as_string(REGISTRY))
		if value is Dictionary:
			_registry = value
	music.finished.connect(_repeat_music)


func select_map(source_map: Dictionary) -> void:
	var identifier := int(source_map.get("Bgm", 0))
	var entry: Variant = _registry.get("bgm_by_id", {}).get(str(identifier), {})
	var path := str(entry.get("path", "")) if entry is Dictionary else str(entry)
	if identifier == current_bgm and path == current_path:
		return
	current_bgm = identifier
	current_path = path
	music.stop()
	music.stream = null
	if path.is_empty() or not ResourceLoader.exists(path):
		return
	var stream := load(path) as AudioStream
	if stream == null:
		return
	music.stream = stream
	if not muted:
		music.play()


func play_effect(identifier: String) -> bool:
	return _play_entry(_registry.get("effects", {}).get(identifier, {}))


func play_binding(group: String, identifier: int, event: String) -> bool:
	return _play_entry(_registry.get(group, {}).get(str(identifier), {}).get(event, {}))


func play_weapon(identifier: int, gear_id: String) -> bool:
	var entry: Dictionary = _registry.get("weapon_effects", {}).get(str(identifier), {})
	return _play_entry(entry.get("fire_by_gear", {}).get(gear_id, entry.get("fire", {})))


func _play_entry(entry: Variant) -> bool:
	if muted or voices.is_empty():
		return false
	var path := str(entry.get("path", "")) if entry is Dictionary else ""
	if path.is_empty() or not ResourceLoader.exists(path):
		return false
	var stream := load(path) as AudioStream
	if stream == null:
		return false
	var voice := voices[_voice_index % voices.size()]
	_voice_index += 1
	voice.stream = stream
	voice.play()
	return true


func toggle_muted() -> bool:
	muted = not muted
	if muted:
		music.stop()
		for voice: AudioStreamPlayer in voices:
			voice.stop()
	elif music.stream != null:
		music.play()
	return muted


func snapshot() -> Dictionary:
	return {"available": not _registry.is_empty(), "muted": muted, "bgm_id": current_bgm, "path": current_path, "playing": music.playing if is_instance_valid(music) else false}


func _repeat_music() -> void:
	if not muted and music.stream != null:
		music.play()


func _exit_tree() -> void:
	# Release playback handles before AudioServer shuts down (also with Dummy).
	if is_instance_valid(music):
		music.stop()
		music.stream = null
	for voice: AudioStreamPlayer in voices:
		if is_instance_valid(voice):
			voice.stop()
			voice.stream = null
