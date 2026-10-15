extends SceneTree
## Reproduce the support audit using the production interpreter, without importing assets.

const Skills = preload("res://scripts/skill_model.gd")


func _initialize() -> void:
	var skills = Skills.new()
	if not skills.configure({"gear_id": "12003100", "level": 125, "max_sp": 200}):
		quit(1)
		return
	var snapshot: Dictionary = skills.snapshot()
	var rows: Array[Dictionary] = []
	var reasons: Dictionary = {}
	for item_num: Variant in skills.definitions:
		var record: Dictionary = skills.definitions[item_num]
		var reason := str(record.blocked_reason)
		if not reason.is_empty():
			reasons[reason] = int(reasons.get(reason, 0)) + 1
		rows.append({"item_num": int(item_num), "name": record.ItemName, "family": int(record.family), "rank": int(record.SkillLevel), "gear_mask": int(record.ReqUnitKind), "minimum_level": int(record.ReqMinLevel), "required_item_kind": int(record.ReqItemKind), "supported": reason.is_empty(), "blocked_reason": reason, "skill_type": int(record.SkillType), "target_type": int(record.SkillTargetType), "sp_cost": int(record.ReqSP), "recast_ms": int(record.ReAttacktime), "duration_ms": int(record.Time), "parameters": record.parameters, "source_record": record.get("_source", {})})
	var document := {"schema_version": 1, "release": "0.7.0", "summary": {"catalogued": rows.size(), "supported": int(snapshot.supported_count), "blocked": int(snapshot.blocked_count), "supported_is_not_automatically_learned": true, "blocked_reasons": reasons}, "source": {"omi_sha256": "4831431a42bd37ac3ecffc067989330f6304ce214c0a77e8062d28f1fffb5f48", "record_stride": 576, "destination_parameters": {"offset": 120, "count": 8, "encoding": "little-endian uint16"}, "parameter_values": {"offset": 136, "count": 8, "encoding": "little-endian float32"}, "historical_item_limit": "Current u16 IDs differ from EP3.5 BYTE IDs; source-specific scalar offsets and all8floatvalues retained. Zero-valued23910..23913metadata treated as no-op, never assigned a guessed effect."}, "evidence": ["EP3.5 Client/Common/AtumParam.h:1590-1777 destination constants;3124-3146 skill/target modes", "EP3.5 Server/GameServer/FieldServer/Main/FieldSkillManager.cpp:1361-1365 SetSkillParamFactor", "EP3.5 Client/Common/AtumSJ.cpp:496-503,608-631 attack, defense, dodge", "EP3.5 Client/Common/AtumSJ.cpp:854-881 reattack, multinum, shotnum;894 additive lockangle", "EP3.5 Client/Common/AtumParam.h:1341-1354 COMPARE_ITEMKIND;FieldSkillManager.cpp:1386-1397 equippedweaponrequirement", "EP3.5 Server/GameServer/FieldServer/Main/FieldIOCPSocket.cpp:1597-1615 SmartSP discount truncation/self-exclusion", "EP3.5 Server/GameServer/FieldServer/Main/FieldIOCPSocket2.cpp:4530-4595 additive parameters;4640-4664 immediateHP/DP", "EP3.5 Server/GameServer/FieldServer/Main/FieldTimerManager.h:21 SP3secondinterval;FieldTimerManager.cpp:565-606 SPregen3+floor(maxSP/500)", "EP3.5 Client/Common/AtumSJ.cpp:994,1010,1027 movementfactors;ShuttleChild.cpp:14373 boostspeedadd181"], "local_policy": ["Only effective ranks can be explicitly learned; base prototypes are catalogued and blocked.", "Optional learn_base_skills() is explicit offline initial training, never called by configure/import; grants no ITEM.", "Economic debit and NPC proximity belong to the caller's atomic school service.", "Native self targets and selectable immediateheals execute only on the current GEAR. Group effects are blocked; no fictitious party is created.", "Learned ranks, hotbar1..8,SP, buffduration and familyrecasts persist across save/load; classchanges clear activeforeignbuffs and retainSP/recasts.", "No targetspawns, accountskillownership or unknown specialeffects are inferred."], "implemented": ["Timed per-weapon minimum/maximum damage, hit, defense and dodge", "Native secondaryShotNum/MultiNum/ReAttacktime Berserker and lockangle Frenzy", "ImmediateHP andDP repair on ownGEAR", "SmartSP with native integerdiscount and ownskill exemption", "HyperMoving engine reaction/turn/boosterturn factors and flatboosterspeed", "Native ReqSP, Time/ReAttacktimemilliseconds, classmask, level/rank requirements and3secondSPregen"], "remaining": ["Toggle/charging modes and their SPdrain/projectile/movement semantics", "Party, area and remote target skills", "Native overlap-group table beyond samefamily replacement", "Original visualskillanimations/effects", "Gradualheal cancellation and remaining specialdestinationparameters"], "records": rows}
	var output := "res://../docs/skills-implementation.json"
	var file := FileAccess.open(output, FileAccess.WRITE)
	if file == null:
		quit(1)
		return
	file.store_string(JSON.stringify(document, "\t") + "\n")
	file.close()
	print(JSON.stringify(document.summary))
	quit(0)
