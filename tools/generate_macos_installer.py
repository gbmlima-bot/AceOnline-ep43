#!/usr/bin/env python3
"""Generate the 0.9 Mac installer from verified export/package metadata.

No network, exports, publication, downloads or native execution. The historical
0.8 installer remains byte-for-byte unchanged. Every output must be new.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

import release_parts

VERSION = "0.9.0"
ZIP_NAME = "ace-modern-online-macos-v0.9.zip"
RELEASE_URL = "https://github.com/gbmlima-bot/AceOnline-ep43/releases/download/ace-modern-v0.9.0"
TEMPLATE = Path(__file__).resolve().with_name("install_macos.sh")
TEMPLATE_SHA256 = "fca846334016546b0fda04451cbb5299f1234ba0fecf49e6ea67059f5f8b15fb"
APP_PATHS = (
    "Contents/Info.plist",
    "Contents/MacOS/ACE Modern",
    "Contents/PkgInfo",
    "Contents/Resources/ACE Modern.pck",
    "Contents/Resources/PrivacyInfo.xcprivacy",
    "Contents/Resources/icon.icns",
    "Contents/_CodeSignature/CodeResources",
)
MAX_REPORT_BYTES = 16 * 1024 * 1024


class InstallerError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise InstallerError(message)


def positive_size(value, label):
    require(type(value) is int and 0 < value <= 2**63 - 1, "Invalid " + label)
    return value


def sha256(value):
    require(isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) is not None, "Invalid SHA-256")
    return value


def load_report(path):
    require(path.is_file() and not path.is_symlink(), "Report must be a regular local file: " + str(path))
    require(path.stat().st_size <= MAX_REPORT_BYTES, "Report too large")
    value = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=release_parts.unique_keys)
    require(isinstance(value, dict), "Report must be an object")
    return value


def validate_metadata(desktop, archive, manifest):
    require(desktop.get("verified") is True and desktop.get("artifact_kind") == "app_directory", "Verified .app directory report required")
    require(desktop.get("release") == VERSION, "Desktop report release must be " + VERSION)
    for report in (desktop, archive):
        require(report.get("platform") == "macos", "macOS report required")
        architectures = report.get("architectures")
        require(isinstance(architectures, list) and len(architectures) == 2 and set(architectures) == {"arm64", "x86_64"}, "Universal arm64/x86_64 app required")
        require(report.get("native_executed") is False, "Expected cross-export report without a native macOS execution claim")
        require(report.get("executable_permission") is True and report.get("plist_version") == VERSION, "Executable permission/plist version mismatch")
        require(isinstance(report.get("pck"), dict) and report["pck"].get("application_version") == VERSION, "PCK version mismatch")
        positive_size(report.get("bytes"), "artifact size")
        sha256(report.get("sha256"))
    require(archive.get("zip_crc_all_members") is True, "Complete final ZIP CRC verification required")
    require(desktop["pck"] == archive["pck"], "Directory and ZIP PCK verification reports differ")
    tree = desktop.get("tree")
    require(isinstance(tree, list) and len(tree) == 7, "App must contain exactly seven reviewed files")
    require(all(isinstance(row, dict) for row in tree), "Invalid app tree")
    require([row.get("path") for row in tree] == list(APP_PATHS), "App file names/order differ from the seven reviewed paths")
    for row in tree:
        require(set(row) == {"path", "bytes", "sha256", "mode"}, "Unexpected file/symlink metadata")
        positive_size(row["bytes"], "app file size")
        sha256(row["sha256"])
        require(type(row["mode"]) is int and 0 <= row["mode"] <= 0o777, "Invalid app permissions")
    require(tree[1]["mode"] & 0o111, "Mach-O executable permission missing")
    require(sum(row["bytes"] for row in tree) == desktop["bytes"], "App tree byte sum does not match export report")
    encoded = json.dumps(tree, sort_keys=True, separators=(",", ":")).encode()
    require(hashlib.sha256(encoded).hexdigest() == desktop["sha256"], "App tree SHA-256 does not match export report")
    release_parts.validate_manifest(manifest)
    require(manifest["artifact"]["name"] == ZIP_NAME, "Parts manifest must describe " + ZIP_NAME)
    require(manifest["artifact"]["sha256"] == archive["sha256"] and manifest["artifact"]["bytes"] == archive["bytes"], "Parts artifact hash/size differs from verified ZIP")
    for index, part in enumerate(manifest["parts"], 1):
        require(part["name"] == ZIP_NAME + ".part-" + str(index).zfill(3), "Unexpected part filename")
    return tree


def replace_scalar(text, name, value):
    result, count = re.subn(r"(?m)^" + re.escape(name) + r"=.*$", name + "=" + value, text)
    require(count == 1, "Historical template scalar changed: " + name)
    return result


def replace_array(text, name, values):
    replacement = name + "=(\n" + "".join("  " + value + "\n" for value in values) + ")"
    result, count = re.subn(r"(?ms)^" + re.escape(name) + r"=\(\n.*?^\)", replacement, text)
    # Historical size arrays use a single line; handle only their exact shape.
    if count == 0:
        result, count = re.subn(r"(?m)^" + re.escape(name) + r"=\([^\n]*\)$", replacement, text)
    require(count == 1, "Historical template array changed: " + name)
    return result


def generate(desktop_report, zip_report, parts_manifest, output):
    desktop_report, zip_report, parts_manifest, output = map(Path, (desktop_report, zip_report, parts_manifest, output))
    desktop = load_report(desktop_report)
    archive = load_report(zip_report)
    manifest = release_parts.load_manifest(parts_manifest)
    tree = validate_metadata(desktop, archive, manifest)
    require(not output.exists() and not output.is_symlink(), "Output already exists; historical/current installers are preserved")
    template_bytes = TEMPLATE.read_bytes()
    require(hashlib.sha256(template_bytes).hexdigest() == TEMPLATE_SHA256, "Historical 0.8 installer changed; review its logic before generating another release")
    text = template_bytes.decode("utf-8")
    text = text.replace("0.8.0", VERSION).replace("v0.8", "v0.9").replace("ACE Modern 0.8", "ACE Modern 0.9").replace("install_macos.sh", "install_macos_v09.sh")
    text = replace_scalar(text, "RELEASE_URL", "'" + RELEASE_URL + "'")
    text = replace_scalar(text, "ZIP_NAME", "'" + ZIP_NAME + "'")
    text = replace_scalar(text, "ZIP_SHA", "'" + archive["sha256"] + "'")
    text = replace_scalar(text, "ZIP_BYTES", str(archive["bytes"]))
    text = replace_array(text, "PART_NAMES", ['"$ZIP_NAME.part-' + str(index).zfill(3) + '"' for index in range(1, len(manifest["parts"]) + 1)])
    text = replace_array(text, "PART_HASHES", ["'" + row["sha256"] + "'" for row in manifest["parts"]])
    text = replace_array(text, "PART_SIZES", [str(row["bytes"]) for row in manifest["parts"]])
    text = replace_array(text, "APP_FILES", ["'" + row["path"] + "'" for row in tree])
    text = replace_array(text, "APP_HASHES", ["'" + row["sha256"] + "'" for row in tree])
    text = replace_array(text, "APP_SIZES", [str(row["bytes"]) for row in tree])
    require("0.8" not in text, "Historical release literal remained in generated installer")
    syntax = subprocess.run(["bash", "-n"], input=text, capture_output=True, text=True, timeout=10)
    require(syntax.returncode == 0, "Generated shell syntax failed: " + syntax.stderr)
    # Exclusive creation cannot replace the historic installer or an earlier run.
    with output.open("x", encoding="utf-8", newline="\n") as stream:
        stream.write(text)
    return {"script": str(output), "release": VERSION, "bytes": output.stat().st_size,
            "sha256": hashlib.sha256(output.read_bytes()).hexdigest(),
            "parts": len(manifest["parts"]), "app_files": len(tree),
            "shell_syntax_checked": True, "native_executed": False, "published": False}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--desktop-report", type=Path, required=True)
    parser.add_argument("--zip-report", type=Path, required=True)
    parser.add_argument("--parts-manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=TEMPLATE.with_name("install_macos_v09.sh"))
    args = parser.parse_args(argv)
    try:
        result = generate(args.desktop_report, args.zip_report, args.parts_manifest, args.output)
    except (InstallerError, release_parts.PartsError, OSError, ValueError, subprocess.SubprocessError) as error:
        parser.exit(1, "Installer generation failed: " + str(error) + "\n")
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
