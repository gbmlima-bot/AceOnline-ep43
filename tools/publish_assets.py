#!/usr/bin/env python3
"""Resume an existing GitHub draft Release. --dry-run is entirely local/read-only.

Requires Python 3.8+, gh, and release_parts.py beside this script. No login flow
is started here. Original ZIPs are never deleted. Only runner-owned parts may
be removed after remote verification. Publication remains draft by default.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

import release_parts


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    result = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for data in iter(lambda: stream.read(4 * 1024 * 1024), b""):
            result.update(data)
    return result.hexdigest()


def record(path, size=None, sha=None):
    path = Path(path).resolve()
    require(path.is_file(), "Missing input: " + str(path))
    require(size is None or path.stat().st_size == size, "Input size changed: " + str(path))
    return {"path": str(path), "name": path.name, "bytes": path.stat().st_size, "sha256": sha or digest(path)}


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    pending = path.with_name(path.name + ".pending")
    pending.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    pending.replace(path)


class GitHub:
    def __init__(self, repo, cli_login=False):
        self.repo = repo
        self.env = os.environ.copy()
        self.env.pop("GH_DEBUG", None)
        if cli_login:
            self.env.pop("GH_TOKEN", None)
            self.env.pop("GITHUB_TOKEN", None)
        self.env["GH_PROMPT_DISABLED"] = "1"
        self.env["GIT_TERMINAL_PROMPT"] = "0"

    def run(self, arguments, expect_json=True):
        process = subprocess.run(["gh"] + arguments, env=self.env, stdin=subprocess.DEVNULL,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        if process.returncode:
            # Never echo captured output: inherited debugging or signed URLs may
            # contain credentials. HTTP status alone is useful and safe to log.
            message = process.stderr + process.stdout
            status = re.search(r"HTTP\s+(\d{3})", message, re.I)
            if (status and status.group(1) == "401") or process.returncode == 4 or "bad credentials" in message.lower():
                raise RuntimeError("GitHub authentication failed (HTTP401/login required). Stopped without retry; complete gh auth login separately, then resume.")
            raise RuntimeError("gh failed (exit " + str(process.returncode) + (", HTTP" + status.group(1) if status else "") + "); no retry or credential output")
        return json.loads(process.stdout) if expect_json else None

    def release(self, release_id):
        return self.run(["api", "--hostname", "github.com", "repos/" + self.repo + "/releases/" + str(release_id)])

    def assets(self, release_id):
        result = {}
        for page in range(1, 1001):
            rows = self.run(["api", "--hostname", "github.com", "repos/" + self.repo + "/releases/" + str(release_id) + "/assets?per_page=100&page=" + str(page)])
            require(isinstance(rows, list), "Invalid release-assets response")
            for row in rows:
                require(row["name"] not in result, "Duplicate remote asset: " + row["name"])
                result[row["name"]] = row
            if len(rows) < 100:
                return result
        raise ValueError("Unexpected number of release assets")

    def upload(self, tag, path):
        print(json.dumps({"upload": Path(path).name}), flush=True)
        self.run(["release", "upload", tag, "--repo", "github.com/" + self.repo, "--", str(Path(path).resolve())], False)


def check_asset(expected, assets):
    actual = assets.get(expected["name"])
    if actual is None:
        return False
    require(actual.get("state") == "uploaded" and actual.get("size") == expected["bytes"], "Remote asset size/state mismatch: " + expected["name"])
    remote_digest = actual.get("digest")
    if remote_digest is not None:
        require(remote_digest == "sha256:" + expected["sha256"], "Remote SHA256 mismatch: " + expected["name"])
    return True


def load_plan(path):
    plan = json.loads(path.read_text(encoding="utf-8"))
    require(plan.get("version") == 1, "Unsupported publication plan")
    require(re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", plan.get("repository", "")), "Invalid repository")
    require(type(plan.get("release_id")) is int and plan["release_id"] > 0, "Invalid release ID")
    require(isinstance(plan.get("tag"), str) and plan["tag"] and not any(ord(c) < 32 for c in plan["tag"]), "Invalid tag")
    require(isinstance(plan.get("small_assets"), list) and isinstance(plan.get("groups"), list), "Missing asset plan")
    names, directories = set(), set()
    for item in plan["small_assets"] + plan["groups"]:
        release_parts.integer(item.get("bytes"), 0, 2**63 - 1, "input size")
        release_parts.sha256(item.get("sha256"))
        original = record(item["path"], item["bytes"], item["sha256"])
        require(original["name"] not in names, "Duplicate planned artifact")
        names.add(original["name"])
    for group in plan["groups"]:
        directory = Path(group["parts_dir"]).resolve()
        require(str(directory) not in directories, "Groups must use different part directories")
        directories.add(str(directory))
        require(directory.parent.is_dir() and not Path(group["parts_dir"]).is_symlink(), "Invalid parts directory")
        require(Path(group["path"]).resolve().parent != directory, "Parts directory cannot contain the original ZIP")
    return plan


def publish(plan, state_dir, cli_login=False, make_public=False):
    gh = GitHub(plan["repository"], cli_login)
    remote = gh.release(plan["release_id"])
    require(remote.get("id") == plan["release_id"] and remote.get("tag_name") == plan["tag"], "Release ID/tag mismatch")
    require(remote.get("draft") is True, "This runner changes draft Releases only")
    assets = gh.assets(plan["release_id"])
    ownership_path = state_dir / "owned-part-directories.json"
    owned = json.loads(ownership_path.read_text()) if ownership_path.exists() else []
    expected_all = []

    def ensure(expected):
        nonlocal assets
        if not check_asset(expected, assets):
            require(digest(expected["path"]) == expected["sha256"], "Local SHA256 changed: " + expected["name"])
            gh.upload(plan["tag"], expected["path"])
            assets = gh.assets(plan["release_id"])
            require(check_asset(expected, assets), "Uploaded asset not present: " + expected["name"])
        expected_all.append(expected)

    # First upload is the small helper, so an upload-host HTTP401 stops before
    # producing additional multi-GB parts or touching the existing Mac group.
    for item in plan["small_assets"]:
        ensure(record(item["path"], item["bytes"], item["sha256"]))

    for group in plan["groups"]:
        original = record(group["path"], group["bytes"], group["sha256"])
        directory = Path(group["parts_dir"]).resolve()
        local_manifest = directory / (original["name"] + ".parts.json")
        cached_manifest = state_dir / local_manifest.name
        manifest_path = local_manifest if local_manifest.is_file() else cached_manifest
        manifest = release_parts.load_manifest(manifest_path) if manifest_path.is_file() else None

        def entries(value, manifest_file):
            require(value["artifact"] == {k: original[k] for k in ("name", "bytes", "sha256")}, "Manifest does not match approved original")
            return [dict(part, path=str(directory / part["name"])) for part in value["parts"]] + [record(manifest_file)]

        # A cached manifest permits resuming without re-splitting a complete group.
        complete = manifest is not None and all(check_asset(item, assets) for item in entries(manifest, manifest_path))
        if not complete:
            if not local_manifest.is_file():
                require(not directory.exists(), "Existing incomplete parts directory; inspect it manually: " + str(directory))
                require(shutil.disk_usage(directory.parent).free >= original["bytes"] + 32 * 1024 * 1024, "Not enough temporary space for one group")
                local_manifest, manifest = release_parts.split(original["path"], directory)
                owned.append(str(directory))
                save(ownership_path, owned)
            else:
                manifest = release_parts.load_manifest(local_manifest)
            entries(manifest, local_manifest)  # Check original identity before reading/uploading.
            release_parts.verify(local_manifest)
            state_dir.mkdir(parents=True, exist_ok=True)
            if cached_manifest.exists():
                require(cached_manifest.read_bytes() == local_manifest.read_bytes(), "Cached manifest differs; refusing replacement")
            else:
                cached_manifest.write_bytes(local_manifest.read_bytes())
            for item in entries(manifest, local_manifest):
                ensure(item)
        else:
            expected_all.extend(entries(manifest, manifest_path))

        # Delete only an exact set of files created/marked by this runner. The
        # pre-existing Mac directory is deliberately never adopted for cleanup.
        if str(directory) in owned and directory.exists():
            expected_names = {part["name"] for part in manifest["parts"]} | {local_manifest.name}
            require({p.name for p in directory.iterdir()} == expected_names, "Unexpected files in owned parts directory; keeping everything")
            require(all(p.is_file() and not p.is_symlink() for p in directory.iterdir()), "Non-regular file in owned parts directory")
            for path in directory.iterdir():
                path.unlink()
            directory.rmdir()
            owned.remove(str(directory))
            save(ownership_path, owned)

    # Refresh and check every required asset again before optional publication.
    assets = gh.assets(plan["release_id"])
    require(all(check_asset(item, assets) for item in expected_all), "Release still lacks required assets")
    missing_digests = [item["name"] for item in expected_all if assets[item["name"]].get("digest") is None]
    result = {"repository": plan["repository"], "release_id": plan["release_id"], "tag": plan["tag"],
              "all_assets_present": True, "verified_assets": len(expected_all), "sha256_unavailable": missing_digests,
              "available_sha256_match": True, "draft": True, "original_zips_preserved": True}
    save(state_dir / "verification.json", result)
    if make_public:
        require(not missing_digests, "Publication requires GitHub SHA256 for every asset; draft retained")
        changed = gh.run(["api", "--hostname", "github.com", "--method", "PATCH", "repos/" + plan["repository"] + "/releases/" + str(plan["release_id"]), "-F", "draft=false"])
        require(changed.get("draft") is False, "Release publication not confirmed")
        result["draft"] = False
        save(state_dir / "verification.json", result)
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan", type=Path, required=True)
    parser.add_argument("--state-dir", type=Path)
    parser.add_argument("--cli-login", action="store_true", help="Remove GH_TOKEN/GITHUB_TOKEN only in gh subprocesses; use stored gh login")
    parser.add_argument("--dry-run", action="store_true", help="Local checks only: no gh, writes, splitting, upload or cleanup")
    parser.add_argument("--publish", action="store_true", help="Explicitly publish only after all assets and GitHub SHA256 pass")
    args = parser.parse_args(argv)
    try:
        plan = load_plan(args.plan.resolve())
        if args.dry_run:
            result = {"dry_run": True, "read_only": True, "network_calls": 0, "repository": plan["repository"],
                      "release_id": plan["release_id"], "tag": plan["tag"], "small_assets": len(plan["small_assets"]),
                      "groups": [{"artifact": Path(g["path"]).name, "bytes": g["bytes"], "parts_dir": g["parts_dir"],
                                  "existing_parts_preserved": Path(g["parts_dir"]).exists(), "expected_parts": max(1, (g["bytes"] + release_parts.MAX_PART_BYTES - 1) // release_parts.MAX_PART_BYTES)} for g in plan["groups"]],
                      "would_publish": args.publish, "hash_verification_deferred_to_execution": True}
        else:
            result = publish(plan, (args.state_dir or args.plan.resolve().parent / "publish-state").resolve(), args.cli_login, args.publish)
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    except (OSError, ValueError, RuntimeError) as error:
        print("ERROR: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
