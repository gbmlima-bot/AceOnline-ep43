#!/usr/bin/env python3
"""Split release assets and restore them using only Python's standard library.

No network calls. Inputs are read only. Every output must be new.
Python 3.8+; run with `python3 release_parts.py --help` (Windows: `py -3`).
"""
import argparse
import errno
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile


MAX_PART_BYTES = 1_500_000_000  # Decimal 1.5 GB, below GitHub's 2 GB asset limit.
BUFFER_BYTES = 4 * 1024 * 1024
MAX_MANIFEST_BYTES = 16 * 1024 * 1024
MAX_PARTS = 100_000
FORMAT = "ace-release-parts"


class PartsError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise PartsError(message)


def safe_name(name):
    require(isinstance(name, str) and 0 < len(name.encode("utf-8")) <= 255, "Invalid file name")
    require(name not in (".", "..") and not any(c in name for c in '/\\:<>"|?*'), "File names must be portable basenames")
    require(not any(ord(c) < 32 for c in name) and not name.endswith((" ", ".")), "Unsafe file name")
    reserved = {"CON", "PRN", "AUX", "NUL"} | {prefix + str(n) for prefix in ("COM", "LPT") for n in list(range(1, 10)) + ["¹", "²", "³"]}
    require(name.split(".", 1)[0].upper() not in reserved, "Reserved Windows file name")
    return name


def integer(value, minimum, maximum, label):
    require(type(value) is int and minimum <= value <= maximum, "Invalid " + label)
    return value


def sha256(value):
    require(isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) is not None, "Invalid SHA256")
    return value


def unique_keys(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "Duplicate manifest key: " + key)
        result[key] = value
    return result


def validate_manifest(manifest):
    require(isinstance(manifest, dict), "Manifest must be an object")
    require(manifest.get("format") == FORMAT and type(manifest.get("version")) is int and manifest["version"] == 1, "Unsupported manifest format/version")
    part_size = integer(manifest.get("part_size_bytes"), 1, MAX_PART_BYTES, "part size")
    artifact = manifest.get("artifact")
    require(isinstance(artifact, dict), "Missing artifact metadata")
    safe_name(artifact.get("name"))
    size = integer(artifact.get("bytes"), 0, 2**63 - 1, "artifact size")
    sha256(artifact.get("sha256"))
    parts = manifest.get("parts")
    require(isinstance(parts, list) and 1 <= len(parts) <= MAX_PARTS, "Invalid parts list")
    require(len(parts) == max(1, (size + part_size - 1) // part_size), "Part count does not match artifact size")
    seen = set()
    for index, part in enumerate(parts, 1):
        require(isinstance(part, dict), "Invalid part metadata")
        require(type(part.get("index")) is int and part["index"] == index, "Parts must remain in manifest order")
        name = safe_name(part.get("name"))
        require(name.casefold() not in seen and name.casefold() != artifact["name"].casefold(), "Duplicate/conflicting part name")
        seen.add(name.casefold())
        expected = min(part_size, max(0, size - (index - 1) * part_size))
        require(integer(part.get("bytes"), 0, part_size, "part length") == expected, "Part lengths do not match artifact size")
        sha256(part.get("sha256"))
    return manifest


def load_manifest(path):
    require(path.is_file() and not path.is_symlink(), "Manifest must be a regular local file")
    with path.open("rb") as stream:
        data = stream.read(MAX_MANIFEST_BYTES + 1)
    require(len(data) <= MAX_MANIFEST_BYTES, "Manifest is too large")
    return validate_manifest(json.loads(data.decode("utf-8"), object_pairs_hook=unique_keys))


def file_identity(info):
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns)


def split(source, output_dir, part_size=MAX_PART_BYTES):
    source, output_dir = Path(source).resolve(), Path(output_dir).resolve()
    integer(part_size, 1, MAX_PART_BYTES, "part size")
    require(source.is_file(), "Source must be an existing file")
    safe_name(source.name)
    require(len(source.name.encode("utf-8")) <= 240, "Source basename is too long for portable part names")
    require(not output_dir.exists(), "Output directory already exists; choose a new one")
    require(output_dir.parent.is_dir(), "Output directory's parent must already exist")
    created = False
    try:
        with source.open("rb") as stream:
            before = os.fstat(stream.fileno())
            count = max(1, (before.st_size + part_size - 1) // part_size)
            require(count <= MAX_PARTS, "Too many parts; use a larger part size")
            output_dir.mkdir()  # Exclusive creation preserves every existing file.
            created = True
            complete_hash = hashlib.sha256()
            parts = []
            for index in range(1, count + 1):
                name = source.name + ".part-" + str(index).zfill(3)
                expected = min(part_size, max(0, before.st_size - (index - 1) * part_size))
                remaining, part_hash = expected, hashlib.sha256()
                with (output_dir / name).open("xb") as part:
                    while remaining:
                        data = stream.read(min(BUFFER_BYTES, remaining))
                        require(data, "Source changed or was truncated during split")
                        part.write(data)
                        part_hash.update(data)
                        complete_hash.update(data)
                        remaining -= len(data)
                    part.flush()
                    os.fsync(part.fileno())
                parts.append({"index": index, "name": name, "bytes": expected, "sha256": part_hash.hexdigest()})
            require(not stream.read(1), "Source grew during split")
            require(file_identity(before) == file_identity(os.fstat(stream.fileno())) == file_identity(source.stat()), "Source changed during split")
        manifest = validate_manifest({"format": FORMAT, "version": 1, "part_size_bytes": part_size,
                                      "artifact": {"name": source.name, "bytes": before.st_size, "sha256": complete_hash.hexdigest()}, "parts": parts})
        manifest_path = output_dir / (source.name + ".parts.json")
        pending = output_dir / ".manifest.incomplete"
        serialized = (json.dumps(manifest, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
        require(len(serialized) <= MAX_MANIFEST_BYTES, "Manifest would be too large; use a larger part size")
        with pending.open("xb") as stream:
            stream.write(serialized)
            stream.flush()
            os.fsync(stream.fileno())
        pending.rename(manifest_path)  # Manifest appears last, after every part.
        return manifest_path, manifest
    except BaseException:
        if created:
            shutil.rmtree(output_dir, ignore_errors=True)
        raise


def read_verified_parts(manifest_path, manifest, output=None):
    complete_hash, total = hashlib.sha256(), 0
    for part in manifest["parts"]:
        path = manifest_path.parent / part["name"]
        require(path.is_file() and not path.is_symlink(), "Missing/non-regular part: " + part["name"])
        part_hash, remaining = hashlib.sha256(), part["bytes"]
        with path.open("rb") as stream:
            before = os.fstat(stream.fileno())
            require(before.st_size == remaining, "Part size mismatch: " + part["name"])
            while remaining:
                data = stream.read(min(BUFFER_BYTES, remaining))
                require(data, "Truncated part: " + part["name"])
                part_hash.update(data)
                complete_hash.update(data)
                if output is not None:
                    output.write(data)
                remaining -= len(data)
                total += len(data)
            require(not stream.read(1), "Part contains extra bytes: " + part["name"])
            require(file_identity(before) == file_identity(os.fstat(stream.fileno())), "Part changed while reading: " + part["name"])
        require(part_hash.hexdigest() == part["sha256"], "Part SHA256 mismatch: " + part["name"])
    require(total == manifest["artifact"]["bytes"], "Final size mismatch")
    require(complete_hash.hexdigest() == manifest["artifact"]["sha256"], "Final SHA256 mismatch")
    return {"bytes": total, "sha256": complete_hash.hexdigest(), "parts_verified": len(manifest["parts"])}


def verify(manifest_path):
    manifest_path = Path(manifest_path).absolute()
    return read_verified_parts(manifest_path, load_manifest(manifest_path))


def restore(manifest_path, output=None):
    manifest_path = Path(manifest_path).absolute()
    manifest = load_manifest(manifest_path)
    output = Path(output).absolute() if output is not None else manifest_path.parent / manifest["artifact"]["name"]
    inputs = [manifest_path] + [manifest_path.parent / part["name"] for part in manifest["parts"]]
    require(all(output.resolve() != path.resolve() for path in inputs), "Output cannot replace a manifest or part")
    require(not output.exists() and not output.is_symlink(), "Output already exists; refusing to overwrite it")
    require(output.parent.is_dir(), "Output parent directory must already exist")
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="wb", prefix=".ace-release-restore-", dir=str(output.parent), delete=False) as stream:
            temporary = Path(stream.name)
            result = read_verified_parts(manifest_path, manifest, stream)
            stream.flush()
            os.fsync(stream.fileno())
        # Windows rename fails if the destination exists. POSIX hard-link creation
        # provides the same no-overwrite guarantee, followed by removing our temp.
        if os.name == "nt":
            temporary.rename(output)
        else:
            try:
                os.link(str(temporary), str(output))
            except OSError as error:
                if error.errno in (errno.EPERM, errno.EOPNOTSUPP, errno.ENOSYS):
                    raise PartsError("Destination filesystem does not support safe publication; choose a local destination with hard-link support") from error
                raise
            temporary.unlink()
        return dict(result, output=str(output))
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    command = commands.add_parser("split", help="Create parts and manifest in a new directory")
    command.add_argument("source", type=Path)
    command.add_argument("--output-dir", type=Path, required=True)
    command.add_argument("--part-size", type=int, default=MAX_PART_BYTES, help="Bytes per part; maximum/default 1500000000")
    command = commands.add_parser("restore", help="Restore only after all sizes and hashes pass")
    command.add_argument("manifest", type=Path)
    command.add_argument("--output", type=Path)
    command = commands.add_parser("verify", help="Verify all parts without creating the archive")
    command.add_argument("manifest", type=Path)
    args = parser.parse_args(argv)
    try:
        if args.command == "split":
            path, manifest = split(args.source, args.output_dir, args.part_size)
            result = {"manifest": str(path), "manifest_sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "artifact": manifest["artifact"], "parts": len(manifest["parts"])}
        elif args.command == "restore":
            result = restore(args.manifest, args.output)
        else:
            result = verify(args.manifest)
        print(json.dumps(dict(ok=True, **result), ensure_ascii=False))
        return 0
    except (OSError, ValueError) as error:
        print("ERROR: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
