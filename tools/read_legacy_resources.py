#!/usr/bin/env python3
"""Read plain Win32 CGameData archives; extract only explicitly selected images.

Format evidence: EP3.5 GameDataLast.h/.cpp and kronthto/ao-archive.
No decryption, decompression, image decoding or execution is performed.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import sys

HEADER = struct.Struct("<5i")
ENTRY = struct.Struct("<3i10s2s")
MAX_FILE = 2 * 1024**3
MAX_ENTRY = 128 * 1024**2
MAX_COUNT = 200_000
MAX_PIXELS = 64_000_000


class FormatError(ValueError):
    pass


def read_at(stream, offset, size):
    stream.seek(offset)
    data = stream.read(size)
    if len(data) != size:
        raise FormatError(f"Short read at offset {offset}, requested {size}")
    return data


def digest_range(stream, offset, size):
    stream.seek(offset)
    result = hashlib.sha256()
    remaining = size
    while remaining:
        data = stream.read(min(1024 * 1024, remaining))
        if not data:
            raise FormatError("Source changed or short payload")
        result.update(data)
        remaining -= len(data)
    return result.hexdigest()


def dimensions(width, height):
    return width > 0 and height > 0 and width * height <= MAX_PIXELS


def image_info(prefix, suffix, size):
    """Conservative header recognition; this is not a complete image validator."""
    if prefix.startswith(b"DDS ") and len(prefix) >= 128:
        header_size, flags, height, width = struct.unpack_from("<4I", prefix, 4)
        if header_size == 124 and struct.unpack_from("<I", prefix, 76)[0] == 32 and dimensions(width, height):
            fourcc = prefix[84:88].decode("ascii", "backslashreplace")
            return {"format": "dds", "width": width, "height": height, "fourcc": fourcc, "recognition": "DDS header; payload codec not decoded"}
    if prefix.startswith(b"\x89PNG\r\n\x1a\n") and len(prefix) >= 33 and prefix[12:16] == b"IHDR":
        width, height = struct.unpack_from(">2I", prefix, 16)
        if dimensions(width, height):
            return {"format": "png", "width": width, "height": height, "recognition": "PNG signature/IHDR; CRC and pixels not decoded"}
    if prefix.startswith(b"BM") and len(prefix) >= 54:
        declared, pixel_offset, dib = struct.unpack_from("<I4xII", prefix, 2)
        width, height = struct.unpack_from("<ii", prefix, 18)
        if dib >= 40 and dimensions(width, abs(height)) and 14 + dib <= pixel_offset <= size and declared <= size:
            return {"format": "bmp", "width": width, "height": abs(height), "recognition": "BMP/DIB header; pixels not decoded"}
    # TGA has no leading magic; require its v2 footer to avoid guessing.
    if suffix.endswith(b"TRUEVISION-XFILE.\x00") and len(prefix) >= 18 and size >= 44:
        id_len, cmap, kind = prefix[:3]
        width, height, depth = struct.unpack_from("<HHB", prefix, 12)
        if cmap in (0, 1) and kind in (1, 2, 3, 9, 10, 11) and depth in (8, 15, 16, 24, 32) and dimensions(width, height) and 18 + id_len < size - 26:
            return {"format": "tga", "width": width, "height": height, "depth": depth, "recognition": "TGA v2 footer/header; RLE and pixels not decoded"}
    if prefix.startswith(b"\xff\xd8\xff") and suffix.endswith(b"\xff\xd9"):
        return {"format": "jpg", "recognition": "JPEG SOI/EOI markers; dimensions and entropy stream not decoded"}
    return None


def inventory(stream, path):
    size = os.fstat(stream.fileno()).st_size
    if size < HEADER.size or size > MAX_FILE:
        raise FormatError(f"Source size {size} outside accepted range")
    encode_num, identification, payload_size, count, parity = HEADER.unpack(read_at(stream, 0, HEADER.size))
    if (encode_num, identification) != (1000, 1000):
        raise FormatError("Unknown header: expected plain CGameData 1000/1000; no decryption or variant guessing")
    if count < 0 or count > MAX_COUNT or HEADER.size + count * ENTRY.size > size:
        raise FormatError("Invalid entry count")
    entries = []
    offset = HEADER.size
    payload_total = 0
    for index in range(count):
        if offset + ENTRY.size > size:
            raise FormatError(f"Entry {index}: header outside source")
        entry_id, length, entry_parity, raw_name, padding = ENTRY.unpack(read_at(stream, offset, ENTRY.size))
        payload_offset = offset + ENTRY.size
        if length < 0 or length > MAX_ENTRY or length > size - payload_offset:
            raise FormatError(f"Entry {index}: invalid payload bounds/size {length}")
        raw_short = raw_name.split(b"\0", 1)[0]
        name = raw_short.decode("ascii", "backslashreplace")
        prefix = read_at(stream, payload_offset, min(length, 160))
        suffix = read_at(stream, payload_offset + max(0, length - 26), min(length, 26))
        entry = {"index": index, "id": entry_id, "name": name, "name_bytes_hex": raw_name.hex(), "padding_hex": padding.hex(), "header_offset": offset, "payload_offset": payload_offset, "size": length, "parity": entry_parity, "sha256": digest_range(stream, payload_offset, length), "image": image_info(prefix, suffix, length), "prefix_hex": prefix[:16].hex()}
        entries.append(entry)
        payload_total += length
        offset = payload_offset + length
    if offset != size:
        raise FormatError(f"Unparsed trailing bytes: {size - offset}; unsupported variant or malformed source")
    warnings = []
    if payload_size != payload_total:
        warnings.append("Header m_FileSize differs from summed payload sizes; meaning not assumed; all individual bounds checked")
    return {"source": str(path.resolve()), "source_size": size, "source_sha256": digest_range(stream, 0, size), "format": "plain Win32 CGameData, 20-byte header / interleaved 24-byte entry headers", "header": {"encode_num": encode_num, "identification": identification, "declared_payload_size": payload_size, "entry_count": count, "parity": parity}, "warnings": warnings, "entries": entries}


def extract_selected(stream, report, names, destination):
    wanted = set(names)
    selected = [e for e in report["entries"] if e["name"] in wanted]
    missing = wanted - {e["name"] for e in selected}
    if missing:
        raise FormatError("Selected names absent: " + ", ".join(sorted(missing)))
    if any(e["image"] is None for e in selected):
        raise FormatError("Selection includes unrecognized image bytes; no conversion/decryption guessing")
    if sum(e["size"] for e in selected) > 512 * 1024**2:
        raise FormatError("Selected payloads exceed 512 MiB extraction cap")
    destination.mkdir(parents=True, exist_ok=True)
    if destination.is_symlink():
        raise FormatError("Output directory must not be a symlink")
    destination = destination.resolve()
    extracted = []
    for entry in selected:
        safe_name = re.sub(r"[^a-zA-Z0-9_-]", "_", entry["name"])[:40] or "entry"
        filename = f'{entry["index"]:06d}_{safe_name}.{entry["image"]["format"]}'
        target = destination / filename
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
        fd = os.open(target, flags, 0o600)
        try:
            with os.fdopen(fd, "wb") as output:
                stream.seek(entry["payload_offset"])
                remaining = entry["size"]
                digest = hashlib.sha256()
                while remaining:
                    chunk = stream.read(min(1024 * 1024, remaining))
                    if not chunk:
                        raise FormatError("Source changed during extraction")
                    output.write(chunk)
                    digest.update(chunk)
                    remaining -= len(chunk)
                if digest.hexdigest() != entry["sha256"]:
                    raise FormatError("Payload digest changed during extraction")
        except Exception:
            target.unlink(missing_ok=True)
            raise
        extracted.append({"index": entry["index"], "name": entry["name"], "path": str(target), "sha256": entry["sha256"]})
    report["extracted"] = extracted


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path, help="One explicit, already extracted resource file")
    parser.add_argument("--extract-name", action="append", default=[], help="Exact case-sensitive entry name; repeat for selected images")
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--manifest", type=Path, help="New JSON manifest file; never overwrites")
    args = parser.parse_args()
    if args.extract_name and not args.output_dir:
        parser.error("--extract-name requires --output-dir")
    if args.output_dir and not args.extract_name:
        parser.error("--output-dir requires explicit --extract-name selection")
    try:
        with args.archive.open("rb") as stream:
            if not os.path.isfile(args.archive):
                raise FormatError("Input must be a regular file")
            report = inventory(stream, args.archive)
            if args.extract_name:
                extract_selected(stream, report, args.extract_name, args.output_dir)
        result = json.dumps(report, ensure_ascii=True, indent=2) + "\n"
        if args.manifest:
            with args.manifest.open("x", encoding="utf-8") as output:
                output.write(result)
        else:
            print(result, end="")
        return 0
    except (OSError, FormatError, struct.error) as exc:
        print(json.dumps({"error": str(exc), "archive": str(args.archive)}), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
