#!/usr/bin/env python3
"""Export static model resource payloads byte-for-byte; never execute payloads.

Input is one explicitly selected, already extracted CGameData resource pack.
Container parsing and size caps come from read_legacy_resources.inventory.
Payloads are named by validated resource IDs, not used as arbitrary paths.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys

import read_legacy_resources as resources


def unpack(source, destination):
    if destination.exists():
        raise ValueError("Output directory already exists; refusing to overwrite")
    with source.open("rb") as stream:
        inventory = resources.inventory(stream, source)
        if sum(entry["size"] for entry in inventory["entries"]) > 512 * 1024**2:
            raise ValueError("Export payload total exceeds 512 MiB cap")
        plans = []
        filenames = set()
        for entry in inventory["entries"]:
            name = entry["name"]
            if not re.fullmatch(r"[A-Za-z0-9_-]{1,40}", name):
                raise ValueError("Unsafe or unsupported resource ID")
            prefix = resources.read_at(stream, entry["payload_offset"], min(16, entry["size"]))
            if prefix.startswith(b"xof ") and len(prefix) == 16:
                extension = "x"
                kind = "DirectX X model"
                x_header = prefix.decode("ascii", "backslashreplace")
            elif entry["image"]:
                extension = entry["image"]["format"]
                kind = "image"
                x_header = None
            else:
                extension = "bin"
                kind = "unidentified binary payload"
                x_header = None
            filename = name + "." + extension
            if filename in filenames:
                raise ValueError("Duplicate output filename")
            filenames.add(filename)
            plans.append((entry, filename, kind, x_header))
        destination.mkdir(parents=True, exist_ok=False)
        exported = []
        for entry, filename, kind, x_header in plans:
            payload = resources.read_at(stream, entry["payload_offset"], entry["size"])
            digest = hashlib.sha256(payload).hexdigest()
            if digest != entry["sha256"]:
                raise ValueError("Payload changed after inventory")
            target = destination / filename
            with target.open("xb") as output:
                output.write(payload)
            record = {"entry_name": entry["name"], "path": str(target.resolve()), "kind": kind, "sha256": digest, "source_sha256": digest, "size": entry["size"], "source_pack": str(source.resolve()), "source_pack_sha256": inventory["source_sha256"], "source_payload_offset": entry["payload_offset"], "source_entry_index": entry["index"], "transform": "none; exact original payload bytes", "x_header": x_header}
            if entry["image"]:
                record["image_header"] = entry["image"]
            exported.append(record)
    manifest = {"source_pack": str(source.resolve()), "source_pack_sha256": inventory["source_sha256"], "source_size": inventory["source_size"], "entries": exported, "execution": "No payload executed. Bounds and SHA256 checked; arbitrary binary/model/image payloads exported byte-for-byte."}
    with (destination / "manifest.json").open("x", encoding="utf-8") as output:
        json.dump(manifest, output, indent=2)
        output.write("\n")
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pack", type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()
    try:
        manifest = unpack(args.pack, args.output_dir)
        print(json.dumps({"source_pack_sha256": manifest["source_pack_sha256"], "entries": len(manifest["entries"]), "manifest": str(args.output_dir / "manifest.json")}))
        return 0
    except (OSError, ValueError) as exc:
        print(json.dumps({"error": str(exc)}), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
