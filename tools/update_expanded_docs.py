#!/usr/bin/env python3
"""Refresh 0.7 documentation from delivered catalogs; embed only verified captures."""
from __future__ import annotations

import argparse
import base64
import hashlib
import html
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "client/assets"
RELEASE = "0.7.0"
ARCHIVE_SHA = "8395f1f33dda8165f70f30d2a6ad094c5f64e144403fce98337e5012be795841"
GEAR_IDS = ["12000100", "12001100", "12002100", "12003100"]


def read_json(path: Path) -> dict:
    return json.loads(path.read_text()) if path.is_file() else {}


def number(value: int) -> str:
    return f"{value:,}".replace(",", ".")


def build_status() -> dict:
    library = ASSETS / "original_library"
    worlds = read_json(ASSETS / "original_worlds/catalog.json")
    world_rows = worlds.get("records", [])
    coverage = worlds.get("coverage", {})
    missions = read_json(ASSETS / "local_world/mission_support.json")
    actors = read_json(library / "actors/actors.json")
    gears = read_json(library / "gears/gears.json")
    catalogs = read_json(library / "catalogs-manifest.json").get("catalogs", {})
    images = read_json(library / "images-manifest.json").get("images", {})
    audio = read_json(library / "audio-manifest.json").get("audio", {})
    inventory = read_json(library / "inventory-manifest.json").get("inventory", {})
    extra_props = read_json(library / "extra_props/manifest.json").get("coverage", {})
    economy = read_json(ASSETS / "local_services/economy.json").get("summary", {})
    skills_coverage = read_json(ROOT / "docs/skills-implementation.json").get("summary", {})
    map_id = lambda row: int(row.get("map_index", row.get("map_id", 0)))
    available = [map_id(row) for row in world_rows if row.get("available")]
    complete = [map_id(row) for row in world_rows if row.get("status") == "complete"]
    partial = [map_id(row) for row in world_rows if row.get("status") == "partial"]
    unavailable = [map_id(row) for row in world_rows if not row.get("available")]
    validation = read_json(ROOT / "reports/validation.json")
    current_validation = validation.get("release") == RELEASE
    results = validation.get("results", []) if current_validation else []
    validation_pass = current_validation and bool(results) and all(result.get("passed") is True and result.get("exit_code") == 0 for result in results)
    status = {
        "schema_version": 2, "release": RELEASE, "project": "ACE Modern",
        "kind": "local_gameplay_with_optional_lan_presence",
        "summary_pt": "Jogo local com presença e chat LAN opcionais: equipamentos, atributos, habilidades suportadas, economia e missões ampliados; o servidor original não foi reconstruído.",
        "engine": {"version": "4.7.2", "variant": "standard_gdscript", "renderer": "gl_compatibility"},
        "original_client_executed": False, "server_connection": False, "account_authentication": False,
        "lan_network": {"implemented": True, "max_participants": 8, "transport": "Godot ENet", "default_port": 24680, "scope": "Presence, GEAR poses and plain-text chat only; combat, missions, inventory and rewards stay individual.", "original_protocol_server": False},
        "persistence": {"implemented": True, "scope": "local_profile_on_this_computer", "manual_save": "F5", "manual_load": "F9", "autosave_seconds": 30, "autosave_on_exit": True, "checksum_and_backup": True},
        "content": {
            "gear_count": 4, "gear_ids": GEAR_IDS,
            "map_catalog_count": len(world_rows), "explorable_map_count": len(available), "explorable_map_ids": available,
            "native_terrain_world_count": coverage.get("rendered_native_terrains", 0), "native_non_tile_world_count": coverage.get("native_non_tile_worlds", 0),
            "complete_static_scenery_maps": len(complete), "partial_static_scenery_maps": len(partial), "unavailable_map_count": len(unavailable),
            "complete_definition": "Available native terrain or native non-tile world composition, eligible collision/flags, original props and linked daytime sky/clouds without recorded static-resource gaps; not complete MMO gameplay.",
            "scenery_placements": coverage.get("placed_prop_instances", 0), "pooled_prop_models": coverage.get("converted_pooled_prop_models", 0),
            "source_prop_models": coverage.get("source_prop_models", 0), "sky_cloud_models": coverage.get("converted_sky_cloud_models", 0),
            "native_mapobject_codes": extra_props.get("native_mapobject_codes", 0), "available_mapobject_models": extra_props.get("converted_models", 0), "extra_prop_models_without_invented_placements": extra_props.get("extra_models_converted", 0),
            "native_events": coverage.get("events", len(worlds.get("events", []))), "native_portal_records": coverage.get("portals", len(worlds.get("portals", []))),
            "source_event_dats": coverage.get("source_event_dats", 0),
            "native_missions": missions.get("summary", {}).get("total", 0), "semantically_supported_missions": missions.get("summary", {}).get("supported", 0),
            "blocked_mission_scripts": missions.get("summary", {}).get("blocked", 0),
            "mission_availability": "Semantic support is not playability: map/actor availability and native level, faction, gear and prerequisite requirements still gate execution.",
            "supported_skill_ranks": skills_coverage.get("supported", 0), "blocked_skill_definitions": skills_coverage.get("blocked", 0),
            "native_items": catalogs.get("items", 0), "native_skill_definitions": catalogs.get("skill_definitions", 0),
            "local_shop_stock_items": economy.get("stock", 0), "crafting_recipe_definitions": economy.get("recipes", 0), "supported_crafting_recipes": economy.get("supported", 0), "blocked_crafting_recipes": economy.get("blocked", 0),
            "skill_coverage": skills_coverage,
            "progression": catalogs.get("progression", {}),
            "native_monster_records": actors.get("record_count", 0), "available_monster_records": actors.get("available_monster_count", 0), "monster_models": actors.get("model_count", 0),
            "native_armor_source_indices": gears.get("unique_native_source_indices", 0), "gear_appearance_models": gears.get("model_count", 0), "armor_items_with_model": gears.get("available_item_count", 0),
            "decoded_images": images.get("image_count", 0), "image_packs": images.get("pack_count", 0), "exact_item_icons": images.get("exact_item_icons", 0),
            "item_icon_bindings": images.get("item_bindings", 0), "mp3_count": audio.get("mp3_count", 0), "wav_count": audio.get("wav_count", 0),
            "bgm_bindings": audio.get("bgm_bindings", 0), "effect_sound_bindings": audio.get("effect_bindings", 0),
            "original_ui_images": 531, "selected_ui_groups": 19,
            "official_inventory_files": inventory.get("files", 0), "official_inventory_entries": inventory.get("entries", 0),
            "converted_glb_files": sum(1 for path in ASSETS.rglob("*.glb")),
        },
        "implemented": {
            "physics": "Selected native engine ITEMs and ported flight, boost/heat, brake, lateral thrust, inclination correction, landing and A-GEAR ground/siege branches. Advanced original state equivalence is unverified.",
            "world": "Original terrain/flags, pooled scenery, native portal destinations and DAT event/NPC positions when available. Partial and unavailable resources remain explicit in the browser.",
            "missions": "Bounded allowlist compiler for recovered scripts, original requirement gates, kill/dialogue/navigation objectives and idempotent rewards; unsupported clauses fail closed.",
            "combat": "Local PvE with native ITEM damage, cadence, ammo, heat, range and source formulas; native MEX identities/HP and selected Belligerence behaviors. World occlusion applies to weapons and visibility.",
            "inventory": "Owned local items and original icons; validated weapons, engine, armor, CPU, radar and supported accessories with native requirements and selected source modifiers. Catalog browsing does not grant ownership.",
            "equipment": "Source stat increments and caps, explicit bonus-point allocation, native armor/CPU/radar fields and fail-closed unsupported parameters. Equipped armor selects its recovered visual; cosmetic previews remain separate.",
            "skills": "Explicit paid learning, class/level/prerequisite gates, eight shortcuts, SP, cooldowns, supported self effects and combat modifiers. Unsupported targets and unported parameters remain blocked.",
            "economy": "Local shop stock with native ITEM prices/bundles and source sale percentage; conservative native mixing recipes with ingredient/SPI cost, success chance and persisted RNG. HP/DP/EP/SP and ammunition services use source cost rules. Stock, zero tax and city/contact access are explicit local policy.",
            "network": "Optional LAN host/join/disconnect and plain-text chat, up to eight participants. Remote GEAR presence only; no shared combat, authority, mission rewards, trade or original server emulation.",
            "progression": "Pinned native experience thresholds through level125 and source level-up limits; earned XP ledger, effective XP and discarded excess stay distinct. Native 2025 server progression is unverified.",
            "appearance": "Class-compatible native armor models can be tested visually from M without granting armor or changing combat/engine statistics. Default appearance can be restored.",
            "audio": "Original audio registry and map BGM bindings; music toggle in M. Importing sounds does not mean every original audio event is implemented.",
            "camera": "Local chase camera avoids eligible Collision1 world geometry; other props and original camera behavior are not claimed.",
            "water": "Static original water patches use native map metadata and water/black texture pixels with preserved alpha; complete original DirectX distortion/reflection shader is not ported.",
            "ui": "Original blue HUD and inventory artwork plus bounded searchable catalogs for missions/maps/items/appearances/services/skills, validated attribute controls and optional LAN connection. HP/DP/SP/ammo and eight skill shortcuts bind to actual local models.",
        },
        "native_quest_102": {
            "objectives": [{"monster_code": 2028200, "required": 1}, {"monster_code": 2028100, "required": 3}],
            "reward_spi": 320, "reward_xp": 91, "accept_map": 3302, "source_return_map": 9999,
            "source_return_meaning": "influence_city_map_index", "city_2001_available": 2001 in available, "city_2002_available": 2002 in available,
            "runtime_return_policy": "Resolve9999 by faction: influence2->2001,4->2002; local normal profile uses configured start city2001. Fallback to acceptance map is explicit only if required city resources are unavailable.",
            "reward_idempotent": True,
        },
        "adaptations": [
            "Fixed120Hz clock, keyboard/mouse control, radius4 contact body, continuous sweep, safe spawn, portal cooldown and instantaneous landing/takeoff bridges.",
            "Initial level9 profile, local starter reserve, encounter positions, scheduling, movement/attack fallbacks and respawn; no server spawn database was supplied.",
            "Initial local training enables compatible supported rank1 skills separately from native account ownership; subsequent learning is explicit and charged through the local school service.",
            "Native NPC position/name/greeting when DAT event9 is present; nearby NPC3 fallback position and interaction markers/range are explicit local policy.",
            "Quick map travel and armor appearance testing are exploration tools, not original routes or ownership.",
            "Local missile pursuit, hit volumes, reproducible RNG, modern lighting/materials and static model poses.",
            "3002 training quest and rings are new local content, separated from recovered missions.",
        ],
        "not_implemented": [
            "Original MMO server, authentication, accounts and shared multiplayer combat/economy/missions. Optional LAN only shares presence and chat.",
            "Maps marked unavailable, incomplete scenery gaps, every recovered mission clause and all special/group/skill interactions.",
            "Original spawn database, complete per-monster server attributes, native AI scheduler, mesh animations, Cinema missile paths and all original effects/shaders.",
            "Hyperbooster, complete flight state machine, every skill/enchant/formation modifier and complete takeoff/landing patterns. Fuel-depletion trigger/consumption is ported; falling movement is a local ballistic bridge.",
            "All original equipment/skill effects, instance enchantment, official shop stock/taxes and stateful crafting targets beyond the supported local subset.",
            "Complete original water distortion/reflection shader, weather/day-night renderer and proven visual or functional equivalence against the original client.",
        ],
        "platforms": {"macos": {"architecture": ["arm64", "x86_64"], "includes_apple_silicon_m4": True, "native_execution_tested": False, "notarized": False}, "windows": {"architecture": ["x86_64"], "native_execution_tested": False, "authenticode_signed": False}, "linux": {"role": "validation_environment"}},
        "validation": {"release_report_current": current_validation, "all_reported_suites_pass": validation_pass, "reported_suites": len(results), "reports": ["reports/validation.json", "reports/render-validation.json"], "native_macos_windows_execution_tested": False, "original_full_equivalence_verified": False},
        "deliverables": {"shared_folder": "ace-modern-systems", "macos": "ace-modern-systems-macos-v0.7.zip", "windows": "ace-modern-systems-windows-v0.7.zip", "sources": "ace-modern-systems-fontes-v0.7.zip", "html": "gameplay.html", "text": "gameplay.txt"},
        "screenshots": [],
        "provenance": {"archive_url": "https://install.masangsoft.com/20250709/ACEonline.7z", "archive_bytes": 1923818595, "archive_sha256": ARCHIVE_SHA, "omi_sha256": "4831431a42bd37ac3ecffc067989330f6304ce214c0a77e8062d28f1fffb5f48", "ep35_commit": "7c3e47ac47844e5c415d356a94d6201a0b9a38c4", "ep43_commit": "f880284fafa3af9b4b1a4bb2938efef1b328bb8e", "evidence": ["client/assets/original_worlds/catalog.json", "client/assets/local_world/mission_support.json", "client/assets/original_library/actors/actors.json", "client/assets/original_library/gears/gears.json", "client/assets/original_library/catalogs-manifest.json", "client/assets/original_library/images-manifest.json", "client/assets/original_library/audio-manifest.json", "docs/physics-original.json", "docs/combate-original.json", "docs/world-implementation.txt", "docs/recursos-originais.json"]},
        "historical_reports_preserved": ["docs/comparacao-layout.html", "docs/comparacao-assets.html"],
    }
    return status


CONTROLS = [
    ("W / S", "Inclinar; A-GEAR no solo: frente / ré"),
    ("A / D", "Empuxo lateral e inclinação visual; direção terrestre A"),
    ("Q / E", "Guinar; E próximo de NPC/portal interage"),
    ("Mouse · botões 1 / 2", "Mirar · arma primária / secundária"),
    ("Tab", "Selecionar alvo; trava exige cone, alcance e visibilidade"),
    ("Shift / Espaço", "Booster / freio"),
    ("G / T", "Pousar/decolar / cerco A-GEAR no solo"),
    ("M", "Biblioteca, serviços, habilidades, atributos e rede LAN; pausa o jogo local"),
    ("1–8", "Usar a habilidade atribuída, com SP e recarga validados"),
    ("I", "Inventário real arrastável; voo continua, armas ficam bloqueadas"),
    ("F2", "Alternar B/M/A/I-GEAR, inclusive no inventário"),
    ("F5 / F9", "Salvar / carregar o perfil local"),
    ("P / R", "Pausar / reiniciar voo e encontro; conserva progresso e inventário"),
    ("F1", "Ajuda"),
    ("Enter / Esc", "Enviar chat LAN quando conectado ou nota local / liberar campos de texto"),
]


def build_readme(status: dict) -> str:
    c = status["content"]
    n = lambda key: number(int(c[key]))
    controls = "\n".join(f"- {key}: {value}." for key, value in CONTROLS)
    return f"""# ACE Modern 0.7 — sistemas locais e presença LAN

Jogo local em Godot 4.7.2 para macOS e Windows. A reconstrução incorpora recursos recuperados do cliente oficial e regras selecionadas dos fontes EP3.5/EP4.3: voo, exploração, combate, missões, inventário, atributos, habilidades suportadas, serviços, crafting e áudio. O perfil é salvo neste computador. Uma conexão LAN opcional compartilha presença e chat entre até oito participantes; combate, missões e recompensas continuam individuais. O servidor e o MMO originais não foram reconstruídos.

## Executar

Na entrega ace-modern-systems, extraia o ZIP da plataforma e abra o aplicativo:

- ace-modern-systems-macos-v0.7.zip: macOS universal arm64 + x86_64, incluindo Mac M4.
- ace-modern-systems-windows-v0.7.zip: Windows x86_64.
- ace-modern-systems-fontes-v0.7.zip: projeto, dados convertidos, ferramentas e evidências.
- gameplay.html: apresentação com capturas novas incorporadas; gameplay.txt: descrição em texto.

Os exports são gerados e verificados no Linux. A execução nativa no macOS/M4 e no Windows ainda precisa de teste. O aplicativo macOS não é notarizado; o Windows não possui assinatura Authenticode.

Pelos fontes, importe client/project.godot no Godot 4.7.2 padrão, sem .NET, e pressione F5 no editor. Os recursos necessários para executar já estão no projeto; o cliente antigo e os conversores não são necessários. Renderer: GL Compatibility.

## Conteúdo absorvido

- {n('explorable_map_count')} de {n('map_catalog_count')} mundos exploráveis ({n('native_terrain_world_count')} com terreno nativo e {n('native_non_tile_world_count')} composições originais sem tiles): {n('complete_static_scenery_maps')} com cenário estático completo segundo os recursos verificados, {n('partial_static_scenery_maps')} parciais e {n('unavailable_map_count')} indisponíveis. Isso não equivale a todos os sistemas originais desses mapas. O catálogo registra {n('scenery_placements')} posições de cenário, {n('pooled_prop_models')} modelos de objeto e {n('native_portal_records')} registros originais de portal.
- A biblioteca ampliada cobre {n('available_mapobject_models')} dos {n('native_mapobject_codes')} modelos MAPOBJECT. Os {n('extra_prop_models_without_invented_placements')} modelos adicionais foram convertidos e catalogados sem inventar posições para colocá-los nos mapas.
- {n('native_missions')} scripts originais recuperados. O compilador suporta a semântica de {n('semantically_supported_missions')}; {n('blocked_mission_scripts')} têm cláusulas bloqueadas. Uma missão ainda depende dos mapas, modelos de inimigo, nível, facção, classe e pré-requisitos. O painel explica cada bloqueio; o número de scripts suportados não significa que todos estejam disponíveis ao perfil inicial.
- {n('native_items')} registros ITEM, {n('native_skill_definitions')} definições de habilidade e a tabela original de experiência até o nível {c['progression'].get('max_level',125)}. O inventário contém apenas os itens do perfil local; equipamentos e recompensas têm identidades nativas. As habilidades têm {n('supported_skill_ranks')} níveis com efeitos suportados e {n('blocked_skill_definitions')} definições bloqueadas (incluindo bases/protótipos), com aprendizado explícito pago, SP, recarga e oito atalhos; alvos e parâmetros não portados continuam bloqueados.
- {n('available_monster_records')} de {n('native_monster_records')} registros de inimigo têm apresentação 3D disponível, usando {n('monster_models')} modelos compartilhados. Dados originais de identidade, nível e HP são preservados. Posições, escalonamento e comportamentos ausentes do servidor usam políticas locais explícitas.
- {n('gear_appearance_models')} modelos originais de aparência GEAR, vinculados a {n('armor_items_with_model')} itens de armadura. M permite testar uma aparência compatível com a classe atual sem conceder a armadura ou alterar os atributos.
- {n('decoded_images')} imagens de {n('image_packs')} packs, incluindo ícones ITEM resolvidos por vínculo original; {n('mp3_count')} MP3 e {n('wav_count')} WAV. O runtime usa vínculos nativos de BGM e efeitos selecionados. Importar o catálogo não implementa automaticamente todos os eventos de áudio, habilidades ou efeitos.
- Economia local: {n('local_shop_stock_items')} modelos no estoque selecionado localmente; {n('supported_crafting_recipes')} receitas interpretadas de {n('crafting_recipe_definitions')}, com ingredientes, SPI e chance de sucesso originais recuperados. As demais permanecem bloqueadas com motivo. Preços, lotes, venda e manutenção têm fórmulas do fonte; estoque, imposto zero e acesso aos contatos são políticas locais.
- Atributos distribuíveis e equipamento real de armadura, CPU e radar; requisitos de atributos, nível, classe e modificadores suportados são revalidados. Bônus desconhecidos são bloqueados.
- Rede LAN opcional: hospedagem, entrada por IP e chat de texto simples, até oito participantes. Compartilha presença e naves; os sistemas de combate e progressão continuam individuais.
- Interface azul preservada: 531 imagens e 19 grupos selecionados. HP, escudo, munição, alvo, missões e inventário refletem os modelos. SP e os atalhos 1–8 refletem o SkillModel; efeitos ainda não implementados permanecem bloqueados.

## Experimentar

1. Em um perfil novo, a sessão começa no mapa 3002 com I-GEAR e nível local 9. Abra M para consultar missões ou mapas. O painel pausa a simulação; use os filtros e as páginas.
2. Perto do contato NPC3, aceite 101 e depois 102. A segunda missão leva ao terreno 3302: elimine 2028200 × 1 e 2028100 × 3; Tab seleciona o alvo e os botões do mouse disparam.
3. Ao concluir, receba 320 SPI e 91 XP uma única vez. O destino simbólico original 9999 resolve a cidade da facção: 2001 para VCN e 2002 para ANI; o perfil local normal usa a cidade inicial configurada, 2001. O retorno ao mapa de aceitação permanece apenas como fallback explícito caso os recursos da cidade faltem.
4. Em M → Mapas, use Visitar para explorar os mapas disponíveis. É uma ferramenta de viagem rápida local; os portais no mundo mantêm os destinos recuperados dos dados originais. Mapas parciais identificam lacunas de composição.
5. Em I, selecione um item possuído e use Equipar seleção. Posse, nível, classe e encaixe são validados. A aba Itens originais em M consulta modelos de item e não concede equipamento.
6. Em M → Aparências, teste modelos da sua classe ou alterne a classe com F2. Visual padrão restaura a nave base. O teste é cosmético e mantém as regras/equipamentos selecionados.
7. Em M → Serviços, consulte Comprar, Vender, Receitas e Manutenção. Os serviços exigem a cidade/contato apropriado, saldo e requisitos válidos. Crafting debita os ingredientes e SPI mesmo quando a tentativa falha, conforme a chance recuperada.
8. O treinamento inicial local disponibiliza habilidades básicas compatíveis, sem alegar posse de conta original. Em M → Habilidades, aprenda outra habilidade compatível e atribua a um dos slots 1–8. A ativação usa SP e recarga reais; um efeito não suportado mostra o motivo do bloqueio. Em M → Atributos, distribua os pontos obtidos por progressão.
9. Em M → Rede LAN, uma cópia hospeda e a outra informa seu IP local e porta 24680. A conexão mostra naves e permite chat, mantendo combate, inventário e missões independentes.
10. F5 salva, F9 carrega. Há salvamento automático a cada 30 segundos e ao sair, com checksum e backup. O perfil é local, sem login. M → Música ativa/silencia a trilha vinculada ao mapa.

O treino de 3002 e seus anéis são conteúdo novo, identificado como local. Os encontros fora das missões não representam uma recuperação do banco de spawns do servidor.

## Controles

{controls}

Ao digitar no chat ou na busca, as teclas não acionam voo/atalhos. O inventário mantém o voo; chat, inventário, ajuda e biblioteca bloqueiam disparos. R é um reset explícito de voo/encontro, sem apagar o progresso salvo.

## Fidelidade e limites

Os motores ITEM selecionados dirigem o núcleo portado de aceleração, giro, empuxo lateral, freio, boost/calor e movimento terrestre do A-GEAR. A colisão usa terreno, flags de água e objetos com MAPOBJECTINFO.Collision=1. Tiros, mísseis e visibilidade consultam o mundo. A câmera evita a geometria elegível; não se atribui colisão a todos os modelos apenas por estarem visíveis.

As superfícies estáticas de água usam os patches dos mapas e as texturas originais water/black, com alpha preservado. O shader DirectX completo de distorção/reflexo não foi portado.

O combate usa fórmulas do legado para cadência, munição por projétil, calor, alcance, acerto/defesa/perfuração e escudo antes de HP. O runtime inclui os ramos Belligerence interpretados, mas o escalonamento, posições e diversos atributos ausentes do servidor são locais. Cidades 2001/2002 não recebem encontros fabricados.

As cidades 2001/2002 têm terreno, objetos e posições de NPC originais para exploração e interação local. A sessão continua usando o GEAR em voo; o personagem a pé e a câmera humana da cidade não foram implementados.

O combustível usa o consumo por distância/tempo recuperado; a queda sem combustível tem gatilho nativo e trajetória balística adaptada localmente. EP atual, gasto e estado de falta de combustível são persistidos e reabastecidos pelos serviços suportados.

A progressão usa os limiares de experiência do fonte fixado, inclusive limites nativos de subida por recompensa. XP ganho, XP efetivo e excedente descartado são mantidos separados. Pontos de atributo podem ser distribuídos com os incrementos e limites recuperados por classe. A tabela pública não prova a configuração do servidor de 2025.

Ainda faltam servidor MMO/contas e combate compartilhado, spawns e IA completos, mapas indisponíveis e lacunas de cenário, cláusulas especiais de missão, todos os efeitos/atributos de habilidades e equipamentos, estoque/impostos oficiais e crafting com instâncias/enchant, estados avançados de voo e hyperbooster, equivalência física integral da queda sem combustível, animações, trajetórias Cinema e shaders/efeitos/clima completos, inclusive distorção/reflexo da água. As malhas são estáticas ou bind poses; luz, materiais, câmera, controles, colisão contínua e perfil inicial têm adaptações documentadas. Unidades físicas em metros não foram calibradas. O cliente original não foi executado para comparação visual ou funcional.

## Evidências e validação

docs/gameplay-status.json contém contagens e cobertura calculadas dos manifestos; docs/gameplay.txt e docs/gameplay.html apresentam a entrega. docs/world-implementation.txt, docs/physics-original.*, docs/combate-original.* e docs/ui-library.txt separam os dados recuperados das adaptações. Os catálogos completos ficam em client/assets/original_library e client/assets/original_worlds/catalog.json. Todos os {n('official_inventory_files')} arquivos do inventário oficial são rastreados por origem/hash; rastrear um arquivo não significa que seu comportamento foi implementado.

Pacote oficial: https://install.masangsoft.com/20250709/ACEonline.7z
SHA-256: {ARCHIVE_SHA}

Fontes fixados: EP3.5 https://github.com/bhsdp1/AceOnline-ep35, commit 7c3e47ac47844e5c415d356a94d6201a0b9a38c4; EP4.3 https://github.com/bhsdp1/AceOnline-ep43, commit f880284fafa3af9b4b1a4bb2938efef1b328bb8e. Nenhum executável original foi iniciado. O pacote oficial completo não está nos downloads.

Para validar/exportar, instale os templates oficiais 4.7.2 e execute na raiz:

python3 tools/validate.py --godot /caminho/do/Godot --original-source /caminho/do/cliente-original-extraido
python3 tools/export.py --godot /caminho/do/Godot --target macOS
python3 tools/export.py --godot /caminho/do/Godot --target Windows

No macOS, o editor costuma ser /Applications/Godot.app/Contents/MacOS/Godot. reports/validation.json registra a rodada atual de testes; reports/render-validation.json registra testes com renderização e export Linux. Somente relatórios com release 0.7.0 validam esta entrega. As capturas da apresentação são da reconstrução Godot 0.7, sem alegar execução do original. As comparações de interface 0.3 e recursos 0.4 são históricas e permanecem identificadas.

As licenças de Godot/Assimp/ferramentas não transferem licença aberta aos recursos do jogo. Os avisos e a fonte coreana Noto derivada/OFL estão em third_party/.
"""


def build_resources(status: dict) -> str:
    c = status["content"]
    return f"""RECURSOS ORIGINAIS — ACE MODERN 0.7

Cobertura calculada dos manifestos da entrega:
{json.dumps(c, ensure_ascii=False, indent=2)}

ORIGEM

Pacote: https://install.masangsoft.com/20250709/ACEonline.7z
SHA-256: {ARCHIVE_SHA}
OMI plaintext: 4831431a42bd37ac3ecffc067989330f6304ce214c0a77e8062d28f1fffb5f48
EP3.5: 7c3e47ac47844e5c415d356a94d6201a0b9a38c4
EP4.3: f880284fafa3af9b4b1a4bb2938efef1b328bb8e

Nenhum executável original do jogo ou launcher foi iniciado. O inventário
oficial rastreia arquivos por tamanho/hash; a presença no inventário não
equivale a conversão ou implementação funcional. O arquivo oficial completo
não é redistribuído. Os manifestos distinguem importado, parcial e bloqueado.

MALHAS E PIXELS

Os .obj são contêineres CGameData, não Wavefront OBJ. Payloads DirectX X
foram convertidos para GLB com poses, normais, UVs, hierarquia e vínculos de
textura documentados. JPEGs vinculados são incorporados sem recompressão;
TGAs decodificadas para PNG preservam pixels e alpha. Imagens da interface
azul original preservam também seus bytes e recortes/grupos. As demais
imagens decodificadas têm hashes de origem e RGBA nos índices.

Assimp/Blender e correções documentadas de pele/bind pose não reproduzem
automaticamente o renderer DirectX. Materiais modernos, iluminação, flags
de alpha, normais reparadas e orientação têm registros por modelo. Malhas
animadas usam poses estáticas/bind pose; animações, multitexture/glow e
efeitos anexos completos não foram portados. A-GEAR/B/M/I base e as
aparências importadas são recursos distintos; o teste visual de armadura
não modifica os atributos de equipamento do jogador.

MUNDO

O catálogo original MAP_INFO registra os vínculos DAT/MAP/TEX/SKY/CLD e
parâmetros. Mapas exploráveis possuem terreno/altura/flags e composição de
props carregáveis, ou uma composição original sem tiles marcada no catálogo.
Os mundos sem tiles conservam objetos/limites nativos sem criar um terreno
fictício. «Cenário estático completo» significa ausência de lacunas
registradas nesses recursos e céus/nuvens diurnos vinculados. Não significa
servidor, missões, animações ou dinâmica original completos. Mapas parciais
mantêm as lacunas visíveis no catálogo, sem substituição por arte genérica.

Poses, alturas e flags vêm dos DATs. A transformação de coordenadas de cada
terreno está nos metadados. A colisão segue diagonal B-D do fonte, flags de
água e faces de objetos Collision=1; alguns terrenos são renderizados com
diagonal A-C. Esfera de raio 4, sweep contínuo, folga, posição segura e câmera
com prevenção de oclusão são adaptações de integração do novo motor.

Patches estáticos de água seguem os metadados dos mapas e usam as texturas
water/black originais, com pixels e alpha preservados. O shader DirectX
completo de distorção/reflexo da água permanece ausente.

Eventos e destinos de portal são recuperados dos DATs; proximidade e
cooldown são políticas locais. NPCs usam nome/saudação BUILDINGNPC e posição
DAT event9 quando disponível. O fallback de NPC3 perto do início conserva
a indicação de posição local. Marcadores e alcance 120 são adaptações.

MISSÕES, ITENS E PROGRESSÃO

Os scripts recuperados preservam textos, ASTs, offsets e hashes. O compilador
executa apenas cláusulas de semântica reconhecida e bloqueia as demais;
requisitos de mapa/modelo, nível, facção, classe e missão anterior continuam
necessários. A quantidade de scripts semanticamente suportados não deve
ser anunciada como a quantidade de missões jogáveis pelo perfil inicial.

101/102 mantêm o fluxo inicial. 102 exige 2028200×1 e 2028100×3 em 3302 e
paga 320 SPI/91 XP uma vez. 9999 é alias de cidade da facção: 2→2001, 4→2002;
o perfil local normal usa start_city_map_id 2001. Só a indisponibilidade da
cidade ativa o fallback explícito ao mapa onde a missão foi aceita.

O catálogo ITEM preserva identidades e campos recuperados. Ícones normais
seguem SourceIndex; habilidades usam a ligação derivada de SKILL_BASE_NUM.
O índice distingue ícones exatos e fallback original 07900270, sem desenho
novo. A biblioteca não concede posse. O inventário local valida quantidade,
classe, nível, atributos e posição, aceita armas/motor/armadura/CPU/radar e
acessórios suportados, além de recompensa de item declarada pela missão.
A biblioteca completa é distinta dos subconjuntos executáveis de loja,
receitas e habilidades; cada operação revalida as condições e os recursos.

Os equipamentos usam requisitos e incrementos de atributo por classe recuperados.
Pontos podem ser distribuídos em M; armadura, CPU e radar aplicam os campos
portados. Bônus e campos desconhecidos bloqueiam o equipamento por inteiro.
O SkillModel executa apenas o subconjunto documentado, com SP, recarga e
aprendizado explícito; formação, múltiplos alvos e efeitos não portados ficam
bloqueados. Consulte docs/skills-implementation.json para cobertura detalhada.

O ServiceModel usa ITEM.Price/MinTradeQuantity, venda pelo percentual do fonte,
custos de refinaria e receitas conservadoras. Estoque de loja, imposto zero
e acesso por cidade/contato são políticas locais, sem banco de economia oficial.
Crafting consome ingredientes e SPI conforme a chance recuperada; o RNG local
é persistido, sem alegar a sequência do servidor original.

A tabela de experiência vem do fonte EP3.5 fixado, níveis 0..125. XP ganho,
XP efetivo e excedente descartado são separados; subida de nível e limite
por recompensa seguem os ramos portados. Pontos são distribuídos com os
incrementos por classe e limites recuperados. Não se presume a tabela do servidor de 2025.

INIMIGOS E COMBATE

MEX fornece identidade, aparência, nível, HP e campos efetivamente validados.
Nenhum banco de spawns do servidor foi obtido. Encontros de missão usam os
códigos originais dos objetivos; posições, scheduler, movimentos e atributos
ausentes do servidor são declarados locais. Cidades não recebem encontros
fabricados. Belligerence interpreta ramos reconhecidos sem alegar IA completa.

Cadência, munição por projétil, calor, alcance, chance, defesa/perfuração,
DP antes de HP e penalidade de colisão têm referências no fonte. Armas e
visibilidade consultam o mundo. Pursuit de míssil, volumes de acerto,
reaparecimento e RNG local não equivalem às trajetórias Cinema originais.

ÁUDIO E INTERFACE

MP3/WAV são preservados em seus formatos. BGM usa MAP_INFO.Bgm e o registro
nativo; efeitos usam vínculos identificados e fallback só quando declarado.
O catálogo de áudio é mais amplo que os eventos implementados no runtime.

O HUD e inventário preservam 531 imagens/19 grupos selecionados da interface
azul 2025. A janela comum usa inven; tc_inven é Trade Center. O painel M é
uma apresentação nova e explícita de exploração/biblioteca. HP/DP/munição,
alvo, missões, equipamento e quantidades refletem o estado local. SP e os
oito atalhos usam o modelo de habilidades; efeitos não portados permanecem incompletos. O combustível usa a fórmula por distância/tempo
recuperada; o movimento da queda sem combustível é uma ponte local.

EVIDÊNCIAS E LIMITES

Consulte client/assets/original_worlds/catalog.json, original_library/*,
local_world/mission_support.json, legacy_rules/* e docs/recursos-originais.json.
docs/physics-original.*, docs/world-implementation.txt, docs/combate-original.*
e docs/ui-library.txt detalham regras e adaptações. Relatórios atuais são
reports/validation.json e reports/render-validation.json com release 0.7.0.

Há perfil persistente local, economia local e LAN opcional de presença/chat,
sem autenticação, economia oficial ou combate/progressão compartilhados.
O ambiente validado é Linux; macOS universal/M4 e Windows x64 precisam de
execução nativa. Sem notarização Apple ou assinatura Authenticode. Não houve
comparação funcional/pixel integral com o cliente original em execução.
As licenças das ferramentas não atribuem licença aberta aos recursos do jogo.
Comparações 0.3/0.4 são históricas, sem apresentar capturas antigas como 0.7.
"""


def verified_captures(paths: list[Path]) -> list[dict]:
    report = read_json(ROOT / "reports/render-validation.json")
    if report.get("release") != RELEASE or not report.get("canonical_captures_verified"):
        raise SystemExit("HTML final requires current0.7 render-validation and verified canonical captures")
    captures = []
    verified = {str(entry.get("file", entry.get("path", ""))): str(entry.get("sha256", "")) for entry in report.get("canonical_captures", [])}
    for path in paths:
        source = path if path.is_absolute() else ROOT / path
        if not source.is_file() or source.suffix.lower() != ".png":
            raise SystemExit(f"PNG capture missing: {source}")
        relative = source.resolve().relative_to(ROOT.resolve()).as_posix()
        sha256 = hashlib.sha256(source.read_bytes()).hexdigest()
        if verified.get(source.name, verified.get(relative, "")) != sha256:
            raise SystemExit(f"Capture hash is not in the current canonical render report: {relative}")
        titles = {"preview": "Voo e interface original", "inventory": "Inventário e equipamentos possuídos", "systems-skills": "Habilidades, SP e atalhos", "systems-equipment": "Atributos e equipamentos", "systems-services": "Loja local e requisitos", "systems-recipes": "Receitas e ingredientes", "systems-maintenance": "Manutenção e reabastecimento", "systems-network": "Conexão e presença LAN", "world3351": "Mundo 3351 sem terreno de tiles — composição original"}
        captures.append({"path": relative, "title": titles.get(source.stem, source.stem.replace("-", " ").replace("_", " ")), "origin": "Godot reconstruction0.7, not original-client runtime", "sha256": sha256})
    if not captures:
        raise SystemExit("Pass at least one fresh --capture for the final HTML")
    return captures


def build_html(status: dict) -> str:
    c = status["content"]
    figures = []
    for capture in status["screenshots"]:
        encoded = base64.b64encode((ROOT / capture["path"]).read_bytes()).decode("ascii")
        figures.append(f'<figure><img loading="lazy" src="data:image/png;base64,{encoded}" alt="{html.escape(capture["title"])}"><figcaption>{html.escape(capture["title"])} · captura da reconstrução Godot 0.7</figcaption></figure>')
    table = "".join(f"<tr><td>{html.escape(key)}</td><td>{html.escape(value)}</td></tr>" for key, value in CONTROLS)
    suites = status["validation"]
    validation = f"{suites['reported_suites']} suítes registradas; todas passaram." if suites["all_reported_suites_pass"] else "Consulte os relatórios 0.7 de validação incluídos nos fontes."
    return f'''<!doctype html><html lang="pt-BR"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>ACE Modern 0.7 — sistemas locais e presença LAN</title>
<style>:root{{color-scheme:dark}}*{{box-sizing:border-box}}body{{margin:0;background:#06131d;color:#e5eff6;font:16px/1.6 system-ui,sans-serif}}main{{max-width:1120px;margin:auto;padding:48px 24px}}h1{{font-size:clamp(2rem,5vw,3.4rem);line-height:1.1}}h2{{margin-top:2.4rem;color:#97d5ff}}p{{max-width:900px}}small,figcaption{{color:#9bb7cc}}.eyebrow{{color:#68c8ff;letter-spacing:.16em;font-size:.8rem}}.stats{{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:16px;margin:32px 0}}.stats div{{padding:20px;background:#0c2537;border:1px solid #224d6b;border-radius:10px}}.stats strong{{display:block;font-size:2.2rem;color:#98dcff}}.note{{padding:20px;border-left:3px solid #e7bc70;background:#152329}}a{{color:#8dd4ff}}figure{{margin:28px 0}}img{{width:100%;height:auto;display:block;border-radius:10px;border:1px solid #24465d}}figcaption{{font-size:.85rem;padding-top:8px}}table{{width:100%;border-collapse:collapse}}td{{padding:10px 12px;border-bottom:1px solid #244051;vertical-align:top}}td:first-child{{color:#94d5ff;width:26%}}footer{{margin-top:48px;color:#9bb7cc;font-size:.85rem;overflow-wrap:anywhere}}details{{margin:24px 0}}summary{{cursor:pointer;color:#94d5ff}}.downloads{{display:flex;gap:12px;flex-wrap:wrap}}.downloads a{{background:#123952;border:1px solid #3988b9;padding:10px 16px;border-radius:8px;text-decoration:none}}</style><main>
<p class="eyebrow">AIRRIVALS / ACE ONLINE · RECONSTRUÇÃO LOCAL</p><h1>ACE Modern 0.7<br>Mais sistemas jogáveis, com presença LAN opcional.</h1><p>Voo, combate e missões com recursos recuperados do cliente e regras selecionadas do código legado. Agora com equipamentos, atributos, habilidades suportadas, serviços, crafting e presença/chat LAN opcionais.</p>
<div class="stats"><div><strong>{c['explorable_map_count']}/{c['map_catalog_count']}</strong>mundos exploráveis</div><div><strong>{number(c['native_items'])}</strong>registros ITEM</div><div><strong>{c['available_monster_records']}</strong>inimigos com apresentação 3D</div><div><strong>{c['gear_appearance_models']}</strong>aparências GEAR</div></div>
<p class="note"><b>Fidelidade e cobertura:</b> {c['native_terrain_world_count']} mundos usam terreno nativo e {c['native_non_tile_world_count']} usam composição original sem tiles. {c['complete_static_scenery_maps']} mapas têm cenário estático completo segundo os recursos verificados; {c['partial_static_scenery_maps']} são parciais e {c['unavailable_map_count']} indisponíveis. Dos {c['native_missions']} scripts recuperados, {c['semantically_supported_missions']} têm semântica interpretada; requisitos e recursos ainda limitam sua disponibilidade. O servidor, os spawns e todos os sistemas originais não foram reconstruídos.</p>
<div class="downloads"><a href="ace-modern-systems-macos-v0.7.zip">Baixar macOS / M4</a><a href="ace-modern-systems-windows-v0.7.zip">Baixar Windows</a><a href="ace-modern-systems-fontes-v0.7.zip">Código-fonte</a></div>
<h2>Capturas da versão atual</h2>{''.join(figures)}
<h2>Experimentar</h2><ol><li>Abra <b>M</b> para consultar missões, explorar mapas, procurar itens e testar aparências. A biblioteca pausa a simulação e identifica recursos indisponíveis.</li><li>No fluxo inicial, aceite 101 e 102 perto de NPC3. A missão 102 leva a 3302: elimine um 2028200 e três 2028100 para receber 320 SPI e 91 XP. O retorno 9999 resolve a cidade da facção.</li><li>Em <b>I</b>, consulte e equipe itens possuídos. A biblioteca de modelos não concede itens. Testar aparência muda apenas o visual da classe atual.</li><li>Em M, <b>Serviços</b> permite comprar/vender, consultar receitas e manter recursos no contato apropriado; <b>Habilidades</b> aprende e atribui os atalhos 1–8; <b>Atributos</b> distribui os pontos disponíveis.</li><li><b>Rede LAN</b> hospeda ou entra pelo IP do anfitrião, compartilhando naves e chat com até oito participantes. Combate e progresso seguem individuais.</li><li><b>F5</b> salva e <b>F9</b> carrega o perfil local. Há autosave a cada 30 segundos e ao sair. Em M, Música controla a trilha original vinculada ao mapa.</li></ol>
<h2>Controles</h2><table>{table}</table>
<details><summary>O que ainda falta</summary><p>Servidor MMO, autenticação, contas e combate/economia/progresso compartilhados; spawns/IA completos; mapas indisponíveis, cláusulas especiais de missão e lacunas de cenário; todos os efeitos de habilidades/equipamentos, estoque/impostos oficiais e crafting com instâncias; estados avançados de voo, hyperbooster e equivalência integral da queda sem combustível; animações, trajetórias Cinema e shaders/efeitos/água/clima completos. Movimento, câmera, encontros e materiais têm adaptações locais documentadas.</p></details>
<h2>Validação e materiais</h2><p>{validation} A execução foi validada no Linux; macOS universal/M4 e Windows x64 ainda precisam de teste nativo. Aplicativos sem notarização Apple ou assinatura Authenticode. Nenhum executável original do cliente foi iniciado.</p><p><a href="gameplay.txt">Descrição em texto</a> · <a href="ace-modern-systems-fontes-v0.7.zip">Fontes, catálogos, conversores e relatórios</a>. Os fontes incluem docs/gameplay-status.json, docs/recursos-originais.json e os manifestos com hashes.</p>
<footer>Base oficial: pacote 20250709, SHA-256 {ARCHIVE_SHA}. Recursos do jogo mantêm sua titularidade original. Capturas desta página são da reconstrução Godot 0.7. Relatórios de interface 0.3 e recursos 0.4 são históricos.</footer></main></html>'''


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--html", action="store_true", help="Embed explicitly supplied fresh, validated0.7 captures")
    parser.add_argument("--capture", type=Path, action="append", default=[])
    args = parser.parse_args()
    status = build_status()
    status["controls"] = [{"input": key, "action_pt": value} for key, value in CONTROLS]
    if args.html:
        status["screenshots"] = verified_captures(args.capture)
    else:
        previous = read_json(ROOT / "docs/gameplay-status.json")
        if previous.get("release") == RELEASE:
            status["screenshots"] = previous.get("screenshots", [])
    readme = build_readme(status)
    plain_readme = re.sub(r"^#{1,6}\s+", "", readme, flags=re.MULTILINE)
    (ROOT / "README.md").write_text(readme)
    (ROOT / "README.txt").write_text(plain_readme)
    (ROOT / "docs/gameplay.txt").write_text(plain_readme)
    (ROOT / "docs/gameplay-status.json").write_text(json.dumps(status, ensure_ascii=False, indent=2) + "\n")
    (ROOT / "docs/recursos-originais.txt").write_text(build_resources(status))
    if args.html:
        (ROOT / "docs/gameplay.html").write_text(build_html(status))
    print(json.dumps({"release": RELEASE, "maps": status["content"]["explorable_map_count"], "gear_models": status["content"]["gear_appearance_models"], "actor_records": status["content"]["available_monster_records"], "html_updated": args.html}, ensure_ascii=False))


if __name__ == "__main__":
    main()
