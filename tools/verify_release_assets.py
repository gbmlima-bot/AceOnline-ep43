#!/usr/bin/env python3
"""Read-only GitHub Release asset audit; no upload, split, cleanup or publication.

--dry-run performs local checks only and makes no network calls. Requires the
adjacent publish_assets.py and release_parts.py helpers. Credentials are never
printed; --cli-login selects stored gh authentication in the subprocess only.
"""
import argparse
import json
from pathlib import Path
import sys

import publish_assets as publisher
import release_parts


def expected_assets(plan, state_dir, manifest_dirs):
    expected = [publisher.record(item["path"], item["bytes"], item["sha256"]) for item in plan["small_assets"]]
    missing_manifests = []
    for group in plan["groups"]:
        original = publisher.record(group["path"], group["bytes"], group["sha256"])
        filename = original["name"] + ".parts.json"
        directories = [Path(group["parts_dir"]), state_dir] + manifest_dirs
        candidates = [directory / filename for directory in directories if (directory / filename).is_file()]
        if not candidates:
            missing_manifests.append(filename)
            continue
        manifest_path = candidates[0]
        manifest = release_parts.load_manifest(manifest_path)
        publisher.require(manifest["artifact"] == {key: original[key] for key in ("name", "bytes", "sha256")}, "Manifest does not match approved ZIP: " + filename)
        publisher.require(all(path.read_bytes() == manifest_path.read_bytes() for path in candidates[1:]), "Conflicting local copies of manifest: " + filename)
        expected.extend({key: part[key] for key in ("name", "bytes", "sha256")} for part in manifest["parts"])
        expected.append(publisher.record(manifest_path))
    publisher.require(len({item["name"] for item in expected}) == len(expected), "Duplicate expected asset name")
    return expected, missing_manifests


def audit(plan, expected, missing_manifests, cli_login=False):
    gh = publisher.GitHub(plan["repository"], cli_login)
    release = gh.release(plan["release_id"])
    publisher.require(release.get("id") == plan["release_id"] and release.get("tag_name") == plan["tag"], "Release ID/tag mismatch")
    actual = gh.assets(plan["release_id"])
    rows = []
    for item in expected:
        remote = actual.get(item["name"])
        row = {"name": item["name"], "expected_bytes": item["bytes"], "expected_sha256": item["sha256"]}
        if remote is None:
            row["status"] = "missing"
        else:
            row.update({"asset_id": remote.get("id"), "remote_bytes": remote.get("size"), "remote_digest": remote.get("digest")})
            try:
                publisher.check_asset(item, actual)
                row["status"] = "verified_sha256" if remote.get("digest") is not None else "sha256_unavailable"
            except ValueError:
                row["status"] = "size_state_or_sha256_mismatch"
        rows.append(row)
    extras = sorted(set(actual) - {item["name"] for item in expected})
    return {"read_only": True, "repository": plan["repository"], "release_id": plan["release_id"], "tag": plan["tag"],
            "release_draft": release.get("draft"), "expected_assets": len(expected), "remote_assets": len(actual),
            "verified_sha256_assets": sum(row["status"] == "verified_sha256" for row in rows),
            "missing_local_manifests": missing_manifests, "extra_remote_assets": extras,
            "passed": not missing_manifests and all(row["status"] == "verified_sha256" for row in rows), "assets": rows}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan", type=Path, required=True)
    parser.add_argument("--state-dir", type=Path)
    parser.add_argument("--manifest-dir", type=Path, action="append", default=[])
    parser.add_argument("--cli-login", action="store_true")
    parser.add_argument("--dry-run", action="store_true", help="Local only: no gh/network calls or writes")
    parser.add_argument("--output", type=Path, help="Optional local audit JSON; not used in dry-run")
    args = parser.parse_args(argv)
    try:
        plan_path = args.plan.resolve()
        plan = publisher.load_plan(plan_path)
        state_dir = (args.state_dir or plan_path.parent / "publish-state").resolve()
        expected, missing = expected_assets(plan, state_dir, args.manifest_dir + [plan_path.parent])
        if args.dry_run:
            result = {"dry_run": True, "read_only": True, "network_calls": 0, "expected_assets_known": len(expected),
                      "missing_local_manifests": missing, "output_not_written": True}
        else:
            result = audit(plan, expected, missing, args.cli_login)
            if args.output:
                publisher.save(args.output.resolve(), result)
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0 if args.dry_run or result["passed"] else 1
    except (OSError, ValueError, RuntimeError) as error:
        print("ERROR: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
