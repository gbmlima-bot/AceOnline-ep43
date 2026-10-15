#!/usr/bin/env python3
"""Package source v0.8 -> v0.9 plus the current data-only Linux server.

The v0.8 desktop executables are never patched. A source checkout and Godot
4.7.2 are required to run this client. No original artwork is repackaged.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import stat
import sys
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
RELEASE = "0.9.0"
BASE_RELEASE = "0.8.0"
KIT_DIR = "ace-completion-source-kit-v0.9"
BASE_ZIP = Path("/tmp/ace-github-publication/ace-modern-fontes-v0.8.zip")
BASE_SHA256 = "1d8acfa14f0a9fa9c6782c5811cab72172fba83a4001527b8b042f603c696f1c"
ARCHIVE_ROOT = "ace-modern/"
MISSION_DATA = "client/assets/local_world/mission_support.json"
ECONOMY_DATA = "client/assets/local_services/economy.json"
UPDATED_DATA = {MISSION_DATA, ECONOMY_DATA}
DERIVED_DATA = {
    "client/assets/legacy_rules/server_item_compatibility.json": "774c85fae7a3a8503111a2bd49a4a6fa177913363ce18541023909254fc5e652",
    "client/assets/legacy_rules/native_spawns.json": "2ebbc60416a1ebcdc3f20824f967dd3d917fccd6a7e506b9dd42df8e54039aa4",
}
# Names are closed deliberately: no original .bak databases, account tables or
# arbitrary files under native_server may enter a source update.
NATIVE_SOURCE_SHA256 = "e5ae92ac1b2e89ee2ef480d85785aa95d3c2588d386092b988efac558b4a4674"
NATIVE_TABLES = frozenset("""
ti_ActionByLevel ti_ArenaInfo ti_ArenaMapinfo ti_BuildingNPC ti_BurningMap
ti_Cinema ti_CityTargetWarpMap ti_CityTargetWarpMap1 ti_EnchantInfo ti_EventMonster
ti_HPAction ti_HappyHourEvent ti_InfinityMode ti_InfinityMonster ti_InfinityShop
ti_InfluenceRate ti_InfluenceWar ti_InvokingWearItemDPNum ti_InvokingWearItemDPNumByUse
ti_Item ti_ItemEvent ti_ItemMatching ti_ItemMixingInfo ti_ItemParamOverlap
ti_LevelAdjustment ti_LevelAdjustmentReward ti_LuckyMachine ti_MapInfo ti_MapObject
ti_Monster ti_MonsterItem ti_MonsterMultiTarget ti_MysteryItemDrop ti_OperatorAction
ti_PetLevel ti_QuestMatching ti_RareItemInfo ti_Revision ti_Shop
ti_StrategyPointSummonMapIndex ti_TutorialInfo ti_WayPoint ti_WayPointMove ti_pet
""".split())
NATIVE_MANIFEST = "client/assets/native_server/manifest.json"
NATIVE_SERVER_JSON = {f"client/assets/native_server/{name}.json" for name in NATIVE_TABLES} | {NATIVE_MANIFEST}


def support():
    """Reuse reviewed path/hash/atomic-write helpers without altering old releases."""
    candidates = [Path(__file__).with_name("package_online_kit.py"),
                  Path(__file__).parent / "support/package_online_kit.py"]
    path = next((p for p in candidates if p.is_file() and not p.is_symlink()), None)
    if path is None:
        raise ValueError("Missing reviewed package_online_kit.py support module")
    spec = importlib.util.spec_from_file_location("ace_v09_safety", path)
    module = importlib.util.module_from_spec(spec)
    # A standalone --dry-run must not create __pycache__ inside the verified kit.
    previous = sys.dont_write_bytecode
    try:
        sys.dont_write_bytecode = True
        spec.loader.exec_module(module)
    finally:
        sys.dont_write_bytecode = previous
    return module


S = support()


def allowed(name: str) -> bool:
    if name in UPDATED_DATA or name in NATIVE_SERVER_JSON or name in DERIVED_DATA:
        return True
    return S.overlay_kind(name) == "text"


def validate_text(root: Path, name: str) -> None:
    if not allowed(name):
        raise ValueError(f"Non-source destination in overlay: {name}")
    data = S.checked_file(root, name).read_bytes()
    if b"\0" in data:
        raise ValueError(f"Binary source overlay: {name}")
    data.decode("utf-8")
    if name in DERIVED_DATA:
        if hashlib.sha256(data).hexdigest() != DERIVED_DATA[name]:
            raise ValueError(f"Unreviewed derived native JSON: {name}")
        if not isinstance(json.loads(data), dict):
            raise ValueError(f"Invalid derived native JSON: {name}")
    elif name == MISSION_DATA:
        value = json.loads(data)
        if not isinstance(value.get("records"), list) or not isinstance(value.get("summary"), dict):
            raise ValueError("Invalid bounded mission-support JSON")
    elif name in NATIVE_SERVER_JSON:
        value = json.loads(data)
        if not isinstance(value, dict) or value.get("schema_version") != 1:
            raise ValueError(f"Invalid static native JSON schema: {name}")
        if name != NATIVE_MANIFEST:
            columns, rows = value.get("columns"), value.get("rows")
            if value.get("table") != Path(name).stem or value.get("source_sha256") != NATIVE_SOURCE_SHA256:
                raise ValueError(f"Unreviewed static native table/source: {name}")
            if not isinstance(columns, list) or not columns or not all(isinstance(c, str) and c for c in columns) or len(columns) != len(set(columns)) or not isinstance(rows, list):
                raise ValueError(f"Invalid static native table columns/rows: {name}")
            for row in rows:
                if not isinstance(row, list) or len(row) != len(columns) or any(
                    type(cell) not in {str, int, float, bool, type(None)} or (type(cell) is float and not math.isfinite(cell)) for cell in row
                ):
                    raise ValueError(f"Invalid static native table cell/row: {name}")
    elif name in UPDATED_DATA:
        if not isinstance(json.loads(data), (dict, list)):
            raise ValueError(f"Static gameplay JSON must be an object or array: {name}")


def validate_native_provenance(root: Path, names: set[str]) -> None:
    included = names & NATIVE_SERVER_JSON
    if not included:
        return
    if NATIVE_MANIFEST not in included:
        raise ValueError("Static native tables require their reviewed provenance manifest")
    manifest = json.loads(S.checked_file(root, NATIVE_MANIFEST).read_text(encoding="utf-8"))
    if manifest.get("source", {}).get("sha256") != NATIVE_SOURCE_SHA256 or not isinstance(manifest.get("exported"), list):
        raise ValueError("Static native provenance source is not the reviewed backup hash")
    rows = []
    for table in manifest["exported"]:
        if table.get("table") not in NATIVE_TABLES or table.get("file") != table["table"] + ".json":
            raise ValueError("Unexpected static table in native provenance")
        rows.append({"path": "client/assets/native_server/" + table["file"], "bytes": table.get("bytes"), "sha256": table.get("sha256")})
    expected = S.rows_index(rows)
    if included != set(expected) | {NATIVE_MANIFEST}:
        raise ValueError("Static native tables differ from their provenance manifest")
    for name, row in expected.items():
        if not S.matches(S.checked_file(root, name), row):
            raise ValueError(f"Static native provenance checksum mismatch: {name}")


def source_files(source: Path) -> dict[str, Path]:
    files = {}
    for directory in ("client", "server", "deploy", "third_party", "docs", "tools"):
        for path in sorted((source / directory).rglob("*")):
            name = path.relative_to(source).as_posix()
            if allowed(name) and path.is_file():
                validate_text(source, name)
                files[name] = path
    for name in ("README.md", "README.txt", ".gitignore"):
        if (source / name).exists():
            validate_text(source, name)
            files[name] = source / name
    validate_native_provenance(source, set(files))
    if S.project_version(S.checked_file(source, "client/project.godot")) != RELEASE:
        raise ValueError("Client project must be version 0.9.0 before packaging")
    server = S.checked_file(source, "server/project.godot").read_text(encoding="utf-8")
    if not re.search(r'^config/version="0\.9\.0"\s*$', server, re.M):
        raise ValueError("Server project must be version 0.9.0 before packaging")
    for name in ("client/scripts/online/json_wire.gd", "server/server_app.gd"):
        if not re.search(r'const PROTOCOL\s*:?=\s*"ace-pve/2"', S.checked_file(source, name).read_text(encoding="utf-8")):
            raise ValueError(f"Expected ace-pve/2 protocol in {name}")
    return files


def data_row(name: str, data: bytes) -> dict:
    return {"path": name, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}


def base_and_overlay(archive: Path, files: dict[str, Path], expected_sha256: str = BASE_SHA256) -> tuple[dict, dict, dict[str, Path]]:
    if S.digest(archive) != expected_sha256:
        raise ValueError("Official v0.8 source ZIP SHA256 mismatch")
    overlay, originals, anchors, assets = {}, {}, {}, []
    with zipfile.ZipFile(archive) as zipped:
        entries = {}
        folded = set()
        for item in zipped.infolist():
            if item.is_dir():
                continue
            S.safe_name(item.filename)
            if not item.filename.startswith(ARCHIVE_ROOT):
                raise ValueError("Unexpected root in v0.8 source ZIP")
            name = item.filename.removeprefix(ARCHIVE_ROOT)
            if name.casefold() in folded or stat.S_ISLNK(item.external_attr >> 16):
                raise ValueError(f"Duplicate/case-colliding/symlink base ZIP entry: {name}")
            folded.add(name.casefold())
            entries[name] = item
            if name.startswith("client/assets/") and name not in UPDATED_DATA:
                assets.append({"path": name, "bytes": item.file_size})
                if "manifest" in Path(name).name and name.endswith(".json"):
                    anchors[name] = data_row(name, zipped.read(item))
        project = zipped.read(ARCHIVE_ROOT + "client/project.godot")
        if not re.search(rb'^config/version="0\.8\.0"\s*$', project, re.M):
            raise ValueError("Base ZIP client version is not 0.8.0")
        for name, path in sorted(files.items()):
            old = zipped.read(entries[name]) if name in entries else None
            if old is not None and old == path.read_bytes():
                continue
            overlay[name] = path
            if old is not None:
                originals[name] = data_row(name, old)
        # Data excluded from the size-only preserved inventory are always pinned,
        # including when a future build happens to leave one table unchanged.
        for name in UPDATED_DATA:
            if name in entries and name not in originals:
                originals[name] = data_row(name, zipped.read(entries[name]))
        if "client/project.godot" not in overlay or "server/project.godot" not in overlay:
            raise ValueError("Overlay must update both client/server project versions")
        originals.update(anchors)
    baseline = {"schema_version": 1, "release": BASE_RELEASE, "source_zip": archive.name,
                "source_zip_sha256": expected_sha256, "files": sorted(originals.values(), key=lambda row: row["path"])}
    inventory = {"schema_version": 1, "release": BASE_RELEASE,
                 "verification": "all_preserved_asset_paths_and_sizes_plus_sha256_of_native_manifests; not per-asset hashes",
                 "files": sorted(assets, key=lambda row: row["path"])}
    return baseline, inventory, overlay


def validation_gate(source: Path, path: Path) -> tuple[dict, dict[str, bytes]]:
    if not path.is_absolute():
        path = source / path
    report = json.loads(path.read_text(encoding="utf-8"))
    results = report.get("results")
    if report.get("release") != RELEASE or not isinstance(results, list) or not results:
        raise ValueError("Validation report must have release 0.9.0 and nonempty results")
    logs = {}
    for result in results:
        if result.get("passed") is not True or not result.get("name"):
            raise ValueError("Validation report contains failed or unnamed checks")
        for field in ("log", "evidence"):
            if not result.get(field):
                continue
            raw = Path(result[field])
            log = raw if raw.is_absolute() else source / raw
            if not log.resolve().is_relative_to(source.resolve()) or log.is_symlink() or not log.is_file():
                raise ValueError("Validation evidence must be regular files within the source project")
            name = log.relative_to(source).as_posix()
            payload = log.read_bytes()
            if S.ERROR_LOG.search(payload.decode("utf-8", errors="replace")):
                raise ValueError(f"Engine/script error in validation evidence: {name}")
            if field == "evidence" and log.suffix == ".json":
                value = json.loads(payload)
                if value.get("passed") is False or value.get("failures"):
                    raise ValueError(f"Failed validation evidence: {name}")
            logs[name] = payload
    return {"report": report, "report_sha256": S.digest(path),
            "logs": [data_row(name, data) for name, data in sorted(logs.items())]}, logs


def server_files(source: Path, bundle: Path) -> dict[str, Path]:
    # This verifies the freshly built bundle against CURRENT source, its whitelist,
    # SQLite/world provenance and the pinned official Godot 4.7.2 binary.
    return S.bundle_files(bundle, source)


def write_archive(output: Path, files: dict[str, Path | bytes], force: bool = False) -> dict:
    if output.suffix.lower() != ".zip" or output.is_symlink() or (output.exists() and not force):
        raise ValueError("Choose a new regular .zip output; --force permits replacing an old ZIP")
    rows = []
    for name, value in sorted(files.items()):
        rows.append({**data_row(name, value), "executable": name == "apply-update.py"} if isinstance(value, bytes) else S.row_for(value, name))
    S.rows_index(rows)
    payload = dict(files)
    payload["kit-manifest.json"] = S.json_bytes({"schema_version": 1, "release": RELEASE, "files": rows})
    modes = {r["path"]: r.get("executable", False) for r in rows}
    output.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary_name = tempfile.mkstemp(prefix=".ace-completion-kit-", suffix=".zip", dir=output.parent)
    os.close(fd)
    temporary = Path(temporary_name)
    try:
        with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6, allowZip64=True) as zipped:
            for name, value in sorted(payload.items()):
                with zipped.open(S.zip_info(KIT_DIR + "/" + name, modes.get(name, False)), "w", force_zip64=True) as target:
                    if isinstance(value, bytes):
                        target.write(value)
                    else:
                        with value.open("rb") as original:
                            import shutil
                            shutil.copyfileobj(original, target, 1024 * 1024)
        with zipfile.ZipFile(temporary) as zipped:
            if zipped.testzip() is not None:
                raise ValueError("Generated ZIP failed CRC validation")
            for row in rows:
                h = hashlib.sha256()
                with zipped.open(KIT_DIR + "/" + row["path"]) as stream:
                    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                        h.update(chunk)
                if h.hexdigest() != row["sha256"] or zipped.getinfo(KIT_DIR + "/" + row["path"]).file_size != row["bytes"]:
                    raise ValueError(f"Source changed while packaging: {row['path']}")
        os.replace(temporary, output)
    finally:
        temporary.unlink(missing_ok=True)
    return {"release": RELEASE, "files": len(rows), "zip_bytes": output.stat().st_size,
            "sha256": S.digest(output), "output": str(output)}


def package(source: Path, bundle: Path, archive: Path, validation: Path, output: Path, force: bool = False) -> dict:
    source = source.resolve()
    if output.resolve() == archive.resolve() or output.resolve().is_relative_to(bundle.resolve()):
        raise ValueError("Output must not replace the base ZIP or enter the server bundle")
    evidence, logs = validation_gate(source, validation)
    baseline, inventory, overlay = base_and_overlay(archive, source_files(source))
    server = server_files(source, bundle)
    rows = [S.row_for(path, name) for name, path in sorted(overlay.items())]
    files = {"server-bundle/" + name: path for name, path in server.items()}
    files.update({"source-overlay/" + name: path for name, path in overlay.items()})
    files.update({"apply-update.py": Path(__file__).resolve(),
                  "support/package_online_kit.py": Path(S.__file__).resolve(),
                  "base-manifest.json": S.json_bytes(baseline),
                  "preserved-assets.json": S.json_bytes(inventory),
                  "overlay-manifest.json": S.json_bytes({"schema_version": 1, "release": RELEASE, "files": rows}),
                  "validation.json": S.json_bytes(evidence), "LEIA-ME.txt": INSTRUCTIONS.encode("utf-8")})
    files.update({"evidence/" + name: data for name, data in logs.items()})
    return {**write_archive(output, files, force), "source_overlay_files": len(overlay),
            "preserved_asset_files": len(inventory["files"]), "server_files": len(server)}


def apply_update(kit: Path, base: Path, dry_run: bool = False, source_zip: Path | None = None) -> dict:
    if kit.is_symlink() or base.is_symlink() or not kit.is_dir() or not base.is_dir():
        raise ValueError("Kit/base must be real directories, not symlinks")
    kit, base = kit.resolve(), base.resolve()
    if kit == base or kit.is_relative_to(base) or base.is_relative_to(kit):
        raise ValueError("Extract the kit and v0.8 project into separate directories")
    outer = S.load_json(S.checked_file(kit, "kit-manifest.json"))
    if outer.get("release") != RELEASE:
        raise ValueError("Kit release mismatch")
    payload = S.check_rows(kit, outer["files"])
    actual = set()
    for path in kit.rglob("*"):
        if path.is_symlink():
            raise ValueError(f"Symlink in kit: {path}")
        if path.is_file():
            actual.add(path.relative_to(kit).as_posix())
    if actual != set(payload) | {"kit-manifest.json"}:
        raise ValueError("Kit has missing or unexpected files")
    baseline = S.load_json(S.checked_file(kit, "base-manifest.json"))
    inventory = S.load_json(S.checked_file(kit, "preserved-assets.json"))
    overlay_manifest = S.load_json(S.checked_file(kit, "overlay-manifest.json"))
    if baseline.get("release") != BASE_RELEASE or inventory.get("release") != BASE_RELEASE or overlay_manifest.get("release") != RELEASE:
        raise ValueError("Base/overlay release mismatch")
    originals = S.rows_index(baseline["files"])
    overlay = S.check_rows(kit / "source-overlay", overlay_manifest["files"])
    if {"source-overlay/" + name for name in overlay} != {name for name in payload if name.startswith("source-overlay/")}:
        raise ValueError("Overlay manifest differs from kit manifest")
    for name in overlay:
        validate_text(kit / "source-overlay", name)
    validate_native_provenance(kit / "source-overlay", set(overlay))
    if "client/project.godot" not in overlay or "server/project.godot" not in overlay:
        raise ValueError("Overlay must include both client/server project versions")
    if S.project_version(S.checked_file(kit / "source-overlay", "client/project.godot")) != RELEASE:
        raise ValueError("Overlay project version mismatch")
    server_text = S.checked_file(kit / "source-overlay", "server/project.godot").read_text(encoding="utf-8")
    if not re.search(r'^config/version="0\.9\.0"\s*$', server_text, re.M):
        raise ValueError("Overlay server version mismatch")
    version = S.project_version(S.checked_file(base, "client/project.godot"))
    if version not in {BASE_RELEASE, RELEASE}:
        raise ValueError(f"Expected source version 0.8.0, found {version}")
    if source_zip is not None and S.digest(source_zip) != baseline["source_zip_sha256"]:
        raise ValueError("Optional original source ZIP SHA256 mismatch")
    asset_names = set()
    for row in inventory["files"]:
        name = S.safe_name(row["path"])
        if not name.startswith("client/assets/") or name in UPDATED_DATA or type(row.get("bytes")) is not int or row["bytes"] < 0 or name.casefold() in asset_names:
            raise ValueError("Invalid preserved asset inventory")
        asset_names.add(name.casefold())
        path = S.destination_path(base, name)
        if not path.is_file() or path.stat().st_size != row["bytes"]:
            raise ValueError(f"Preserved base asset missing or size changed: {name}")
    for name, row in originals.items():
        target = S.destination_path(base, name)
        if not S.matches(target, row) and not (name in overlay and S.matches(target, overlay[name])):
            raise ValueError(f"Base file changed or missing: {name}; use a fresh v0.8 source extraction")
    changed = []
    for name, row in overlay.items():
        target = S.destination_path(base, name)
        if S.matches(target, row):
            continue
        if name not in originals and target.exists():
            raise ValueError(f"New source file conflicts with an existing file: {name}")
        changed.append(name)
    if version == RELEASE and changed:
        raise ValueError("Project says 0.9.0 but overlay is incomplete; restore source backup")
    result = {"release": RELEASE, "base_files_hashed": len(originals), "preserved_asset_sizes_verified": len(asset_names),
              "changed_files": len(changed), "dry_run": dry_run, "already_applied": not changed,
              "native_desktop_executables_updated": False}
    if dry_run or not changed:
        return result
    changed.sort(key=lambda name: (name == "client/project.godot", name))
    backup_parent = S.destination_path(base, ".online-update-backups/placeholder").parent
    backup_parent.mkdir(exist_ok=True)
    backup = Path(tempfile.mkdtemp(prefix="v0.9-", dir=backup_parent))
    old = {}
    for name in changed:
        path = S.destination_path(base, name)
        old[name] = (path.read_bytes(), bool(path.stat().st_mode & 0o111)) if path.exists() else None
        if old[name] is not None:
            S.atomic_write(backup / name, old[name][0], old[name][1])
    written = []
    try:
        for name in changed:
            data = S.checked_file(kit / "source-overlay", name).read_bytes()
            if len(data) != overlay[name]["bytes"] or hashlib.sha256(data).hexdigest() != overlay[name]["sha256"]:
                raise ValueError(f"Overlay changed while applying: {name}")
            S.atomic_write(S.destination_path(base, name), data, overlay[name].get("executable", False))
            written.append(name)
        S.atomic_write(backup / "update-receipt.json", S.json_bytes({**result, "changed_paths": changed}))
    except Exception:
        for name in reversed(written):
            path = S.destination_path(base, name)
            if old[name] is None:
                path.unlink(missing_ok=True)
            else:
                S.atomic_write(path, old[name][0], old[name][1])
        raise
    result["source_backup"] = str(backup)
    return result


INSTRUCTIONS = """ACE Modern — fontes e servidor 0.9.0 (ace-pve/2)

Este é um pacote incremental de FONTES sobre ace-modern-fontes-v0.8.zip.
Não é um instalador do cliente gráfico. Os .app/.exe 0.8 ficam inalterados:
suas melhorias 0.9 só aparecem ao executar/exportar o projeto atualizado.
O cliente 0.9 exige servidor 0.9; protocolo ace-pve/1 não é compatível.
O conteúdo continua uma reconstrução parcial, não o MMO original completo.

Atualizar fontes preservando os 45 mil assets originais:
1. Baixe as três partes de ace-modern-fontes-v0.8.zip na release0.8 e monte
   o ZIP com release_parts.py (ou use seu ZIP original já verificado).
2. Extraia o fonte0.8 para uma pasta nova. Feche o editor. Preserve o ZIP.
3. Extraia este kit em OUTRA pasta. Abra o terminal na pasta deste kit.
4. Faça uma prévia sem escrever:
   python3 apply-update.py --base /caminho/ace-modern --dry-run
5. Aplique (há backup e rollback de falhas de escrita):
   python3 apply-update.py --base /caminho/ace-modern
   Opcional: --base-source-zip /caminho/ace-modern-fontes-v0.8.zip
6. Instale Godot4.7.2 para seu macOS/Windows, importe o projeto
   /caminho/ace-modern/client/project.godot e pressione F5 para executar o
   projeto principal. A primeira importação pode demorar.

O aplicador verifica SHA256 dos arquivos que substitui e dos manifestos
nativos, e a presença/tamanho de todos os assets preservados. Ele não calcula
hash individual de cada asset. A opção --base-source-zip confere também o
SHA256 do ZIP original. Somente mission_support.json, local_services/economy.json
e JSONs estáticos novos explicitamente revisados em native_server e legacy_rules são escritos
entre os dados de assets. Arte, texturas e áudio não são substituídos.
Perfis, saves e userdata não são apagados. Arquivos modificados ou symlinks
causam recusa; use uma extração limpa. Arquivos anteriores ficam em
.online-update-backups/v0.9-*/ com recibo. O rollback cobre falhas detectadas
de escrita; mantenha sua cópia original para quedas de energia/fechamentos.

Servidor independente (Linux x86_64): server-bundle/
Leia server-bundle/OPERACAO.txt. Ele contém Godot4.7.2 oficial e somente os
dados numéricos necessários da sala3002; não inclui a arte nem os outros mapas.
Não há hospedagem pública incluída. Não substitua nem apague seus volumes
SQLite ao atualizar. Crie backup antes, e use clientes/servidor da mesma versão.

Os testes do relatório validation.json não equivalem a testes nativos no Mac
ou Windows. Confira também o SHA256 publicado deste ZIP: os manifestos
detectam corrupção, mas não são uma assinatura digital de autenticidade.
"""


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    applying = Path(__file__).name == "apply-update.py"
    if applying:
        parser.add_argument("--base", type=Path, required=True)
        parser.add_argument("--base-source-zip", type=Path)
        parser.add_argument("--dry-run", action="store_true")
    else:
        parser.add_argument("--source", type=Path, default=ROOT)
        parser.add_argument("--server-bundle", type=Path, required=True)
        parser.add_argument("--base-source-zip", type=Path, default=BASE_ZIP)
        parser.add_argument("--validation-report", type=Path, default=Path("reports/completion-validation-v09.json"))
        parser.add_argument("--output", type=Path, required=True)
        parser.add_argument("--force", action="store_true")
    args = parser.parse_args()
    try:
        result = apply_update(Path(__file__).resolve().parent, args.base, args.dry_run, args.base_source_zip) if applying else package(
            args.source, args.server_bundle, args.base_source_zip, args.validation_report, args.output, args.force)
    except (ValueError, OSError, KeyError, TypeError, zipfile.BadZipFile, UnicodeError) as exc:
        parser.exit(1, f"Refused: {exc}\n")
    print(json.dumps({"ok": True, **result}, ensure_ascii=False))


if __name__ == "__main__":
    main()
