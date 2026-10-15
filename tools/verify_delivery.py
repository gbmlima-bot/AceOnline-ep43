#!/usr/bin/env python3
"""Read-only verification of the completed ACE Modern0.7 delivery.

Run after package.py has finished. Does not extract archives, execute programs,
contact a network, or write to the project/delivery. Reports JSON to stdout.
"""
from __future__ import annotations
import ast
import argparse
import base64
import hashlib
from html.parser import HTMLParser
import json
from pathlib import Path,PurePosixPath
import plistlib
import re
import struct
import sys
from urllib.parse import unquote,urlsplit
import zipfile

RELEASE="0.7.0"
EXPECTED_DOWNLOADS={
    "ace-modern-systems-macos-v0.7.zip","ace-modern-systems-windows-v0.7.zip",
    "ace-modern-systems-fontes-v0.7.zip","preview.png","inventory.png","gameplay.html","gameplay.txt"}
EXPECTED_SUITES={"library-ui","original-assets","combat-runtime","props-converter","protocol-python",
    "gameplay-integration","scene-controls","original-library","mission-compiler","world-expansion",
    "local-save","godot-import","legacy-ui","combat-model","expanded-world-data","world-importer",
    "world-model","scene-smoke","expanded-game","rules-parser","quest-parser","inventory","actor-library",
    "protocol-godot","original-data-assets","flight-model","terrain-converter",
    "services-data","inventory-equipment","skills","services","multiplayer","systems-ui","systems-integration"}


class VerificationError(ValueError):pass


def require(value,message):
    if not value:raise VerificationError(message)


def hash_stream(stream):
    digest=hashlib.sha256();total=0
    for block in iter(lambda:stream.read(1024*1024),b""):
        digest.update(block);total+=len(block)
    return digest.hexdigest(),total


def validation_suite_names(source):
    """Inspect the packaged runner as data; never import or execute it."""
    tree=ast.parse(source)
    found=[]
    for node in ast.walk(tree):
        if not isinstance(node,ast.Assign) or not any(isinstance(target,ast.Name) and target.id=="commands" for target in node.targets):
            continue
        require(isinstance(node.value,ast.List),"Validation commands must remain an explicit list")
        for entry in node.value.elts:
            require(isinstance(entry,ast.Tuple) and entry.elts and isinstance(entry.elts[0],ast.Constant) and isinstance(entry.elts[0].value,str),"Unrecognized validation command schema")
            found.append(entry.elts[0].value)
    require(found and len(found)==len(set(found)),"Validation runner has missing/duplicate suite names")
    return set(found)


def hash_file(path):
    with path.open("rb") as stream:return hash_stream(stream)


def read_json_zip(archive,name,limit=32*1024*1024):
    info=archive.getinfo(name)
    require(info.file_size<=limit,"JSON exceeds reader policy: "+name)
    return json.loads(archive.read(name))


def safe_zip(archive,prefix=None):
    infos=archive.infolist();names=[x.filename for x in infos]
    require(len(names)==len(set(names)),"ZIP contains duplicate member names")
    for info in infos:
        pure=PurePosixPath(info.filename)
        require(info.filename and not pure.is_absolute() and ".." not in pure.parts and "\\" not in info.filename,
                "Unsafe ZIP member path: "+info.filename)
        require(not info.flag_bits & 1,"Encrypted ZIP members cannot be verified: "+info.filename)
        if prefix:require(info.filename.startswith(prefix),"Unexpected source ZIP prefix: "+info.filename)
    return {info.filename:info for info in infos}


class PageLinks(HTMLParser):
    def __init__(self):super().__init__(convert_charrefs=True);self.links=[];self.inline_images=[]
    def handle_starttag(self,tag,attrs):
        for key,value in attrs:
            if value is None:continue
            if key in ("href","src","poster"):self.links.append((tag,key,value))
            if tag=="img" and key=="src" and value.startswith("data:image/"):
                self.inline_images.append(value)
            if key=="style":
                self.links.extend((tag,"style",match) for match in re.findall(r"url\(['\"]?([^)'\"]+)",value))


def relative_html_links(html,out):
    parser=PageLinks();parser.feed(html);relative=[];remote=[];embedded=[]
    for tag,key,target in parser.links:
        parts=urlsplit(target)
        if parts.scheme=="data":continue
        if parts.scheme or parts.netloc:
            require(key=="href" and tag=="a","Shared HTML depends on a remote page resource: "+target)
            remote.append(target);continue
        if not parts.path:continue
        decoded=unquote(parts.path)
        resolved=(out/decoded).resolve()
        require(resolved.is_relative_to(out),"Shared HTML link leaves delivery directory: "+target)
        require(resolved.is_file(),"Broken relative HTML link: "+target)
        relative.append(decoded)
    for value in parser.inline_images:
        metadata,body=value.split(",",1)
        require(";base64" in metadata,"Expected base64 embedded capture")
        data=base64.b64decode(body,validate=True)
        require(data.startswith(b"\x89PNG\r\n\x1a\n"),"Embedded capture is not PNG")
        require(struct.unpack_from(">II",data,16)==(1440,900),"Unexpected embedded capture dimensions")
        embedded.append(hashlib.sha256(data).hexdigest())
    return {"relative_links":sorted(set(relative)),"remote_links":sorted(set(remote)),"embedded_capture_hashes":embedded}


def rendered_log_result(archive,name,suite):
    info=archive.getinfo("ace-modern/reports/"+name)
    require(info.file_size<=32*1024*1024,"Rendered log exceeds reader policy: "+name)
    text=archive.read(info).decode("utf-8")
    require(not any(marker in text for marker in ("ERROR:","SCRIPT ERROR","Parse Error:")),"Error in rendered log: "+name)
    matches=[]
    for line in text.splitlines():
        if not line.startswith("{"):continue
        try:row=json.loads(line)
        except json.JSONDecodeError:continue
        if row.get("suite")==suite:matches.append(row)
    require(len(matches)==1,"Expected exactly one suite result in "+name)
    return matches[0]


def assert_rendered_result(archive,rendered,key,log,suite):
    row=rendered.get(key,{})
    require(isinstance(row,dict) and type(row.get("checks")) is int and row["checks"]>0 and row.get("failures")==0,
            "Unexpected rendered check result: "+key)
    require(row==rendered_log_result(archive,log,suite),"Render report differs from its captured log: "+key)
    return row["checks"]


def assert_rendered_systems(archive,rendered,key,log):
    name="ace-modern/reports/"+log
    info=archive.getinfo(name)
    require(info.file_size<=32*1024*1024,"Rendered systems log exceeds reader policy")
    text=archive.read(info).decode("utf-8")
    require(not any(marker in text for marker in ("ERROR:","SCRIPT ERROR","Parse Error:")),"Error in rendered systems integration log")
    matches=[]
    for line in text.splitlines():
        if line.startswith("SYSTEMS_E2E="):
            matches.append(json.loads(line.removeprefix("SYSTEMS_E2E=")))
    require(len(matches)==1,"Expected exactly one SYSTEMS_E2E result in rendered log")
    row=matches[0]
    require(isinstance(row,dict) and type(row.get("checks")) is int and row["checks"]>0
            and row.get("failures")==[] and row.get("positive_kills")==11,
            "Rendered systems integration must pass and earn eleven actual kills")
    require(row==rendered.get(key),"Render report differs from its SYSTEMS_E2E log")
    return row["checks"]


def verify_sources(source_zip,shared_hashes):
    with zipfile.ZipFile(source_zip) as archive:
        members=safe_zip(archive,"ace-modern/")
        manifest=read_json_zip(archive,"ace-modern/reports/artifacts.json")
        require(manifest.get("version")==RELEASE,"Source artifact manifest is not0.7.0")
        require(manifest.get("official_client_executed") is False,"Source manifest must retain original-client execution limit")
        rows=manifest.get("files",[]);require(rows,"Source manifest contains no files")
        require(len(rows)==len({r["path"] for r in rows}),"Duplicate paths in source manifest")
        total=0;hashes={}
        for index,row in enumerate(rows,1):
            path=PurePosixPath(row["path"])
            require(not path.is_absolute() and ".." not in path.parts and "\\" not in row["path"],"Unsafe source manifest path")
            member="ace-modern/"+path.as_posix()
            require(member in members,"Manifested source file missing: "+member)
            require(members[member].file_size==row["bytes"],"Source size mismatch: "+member)
            with archive.open(member) as stream:sha,size=hash_stream(stream)
            require(size==row["bytes"] and sha==row["sha256"],"Source SHA mismatch: "+member)
            hashes[member]=sha;total+=size
            if index%5000==0:print(json.dumps({"source_files_verified":index,"of":len(rows)}),flush=True)
        manifested={"ace-modern/"+r["path"] for r in rows}
        unexpected=[name for name,info in members.items() if not info.is_dir() and name not in manifested and not name.startswith("ace-modern/reports/")]
        require(not unexpected,"Unmanifested non-report files in source ZIP: "+str(unexpected[:5]))
        # Reports are intentionally excluded from the recursive artifact manifest.
        # Reading each report to EOF also independently validates its ZIP CRC.
        report_count=0
        for name,info in members.items():
            if name.startswith("ace-modern/reports/") and not info.is_dir():
                with archive.open(info) as stream:hashes[name],size=hash_stream(stream)
                require(size==info.file_size,"Report length mismatch: "+name);report_count+=1
        validation=read_json_zip(archive,"ace-modern/reports/validation.json")
        require(validation.get("release")==RELEASE,"Validation report is not0.7.0")
        suites=validation.get("results",[])
        require(len(suites)==34 and {r["name"] for r in suites}==EXPECTED_SUITES,"Expected exact34 validation suites")
        runner=archive.read("ace-modern/tools/validate.py").decode("utf-8")
        require(validation_suite_names(runner)==EXPECTED_SUITES,"Suite coverage differs from packaged tools/validate.py")
        require(all(r.get("passed") is True and r.get("exit_code")==0 for r in suites),"A validation suite did not pass")
        rendered=read_json_zip(archive,"ace-modern/reports/render-validation.json")
        require(rendered.get("release")==RELEASE,"Render validation report is not0.7.0")
        for key in ("original_assets_rendered","gameplay_rendered","linux_export_headless","linux_export_rendered","canonical_captures_verified"):
            require(rendered.get(key) is True,"Missing rendered validation flag: "+key)
        specs=(("rendered_original_assets","original-assets-rendered.log","original_assets"),
               ("rendered_gameplay","gameplay-e2e-rendered.log","gameplay_e2e"),
               ("rendered_expanded_game","expanded-game-rendered.log","expanded_game"))
        render_checks={key:assert_rendered_result(archive,rendered,key,log,suite) for key,log,suite in specs}
        systems_key=next((key for key in ("rendered_systems_integration","rendered_systems") if key in rendered),None)
        systems_logs=[name for name in ("systems-integration-rendered.log","systems-integration-rendered-v07.log")
                      if "ace-modern/reports/"+name in members]
        if systems_key is not None or systems_logs:
            require(systems_key is not None,"Rendered systems log exists without a matching render report result")
            require(systems_logs,"Rendered systems result has no reproducible log")
            require(len(systems_logs)==1,"Ambiguous rendered systems logs; keep one canonical result")
            render_checks[systems_key]=assert_rendered_systems(archive,rendered,systems_key,systems_logs[0])
        assets=rendered["rendered_original_assets"]
        require(type(assets.get("gpu_placement_getters_verified")) is int and assets["gpu_placement_getters_verified"]>0
                and assets.get("gpu_placement_getters_skipped_dummy")==0,"Real-renderer GPU placement verification missing")
        require(len(rendered["rendered_gameplay"].get("real_weapon_kills",[]))==4,"Expected4 real-weapon training kills")
        for kill in rendered["rendered_gameplay"]["real_weapon_kills"]:
            require(isinstance(kill,dict) and kill.get("source_id") in (7000040,7901000) and kill.get("type")=="target_destroyed" and kill.get("instance_id"),
                    "Training kill lacks native-weapon/target-life evidence")
        captures=rendered.get("canonical_captures",[]);require(captures,"No canonical captures")
        for capture in captures:
            require(isinstance(capture.get("file"),str) and PurePosixPath(capture["file"]).name==capture["file"],"Capture must be a top-level report file")
            name="ace-modern/reports/"+capture["file"]
            require(hashes.get(name)==capture["sha256"],"Canonical capture SHA mismatch: "+name)
            with archive.open(name) as stream:header=stream.read(24)
            require(header[:8]==b"\x89PNG\r\n\x1a\n" and list(struct.unpack_from(">II",header,16))==capture["size"],"Canonical PNG dimensions mismatch: "+name)
            if capture["file"] in shared_hashes:
                require(shared_hashes[capture["file"]]==capture["sha256"],"Shared capture differs from rendered source capture")
        preview=rendered.get("native_release_preview")
        if preview is not None:
            require(isinstance(preview,dict) and isinstance(preview.get("file"),str) and PurePosixPath(preview["file"]).name==preview["file"],"Invalid native release preview descriptor")
            name="ace-modern/reports/"+preview["file"]
            require(hashes.get(name)==preview.get("sha256"),"Native release preview SHA mismatch")
            with archive.open(name) as stream:header=stream.read(24)
            require(len(header)==24 and header[:8]==b"\x89PNG\r\n\x1a\n" and list(struct.unpack_from(">II",header,16))==preview.get("size"),"Native release preview dimensions mismatch")
        browser=rendered.get("gameplay_browser")
        if browser is not None:
            require(isinstance(browser,dict) and browser.get("release")==RELEASE and browser.get("passed") is True
                    and browser.get("html_sha256")==shared_hashes.get("gameplay.html"),"Browser report does not validate current shared HTML")
        status=read_json_zip(archive,"ace-modern/docs/gameplay-status.json")
        require(status.get("release")==RELEASE,"Packaged gameplay status is not0.7.0")
        for name in ("gameplay.html","gameplay.txt"):
            require(hashes.get("ace-modern/docs/"+name)==shared_hashes.get(name),"Shared document differs from packaged source: "+name)
        return {"source_files":len(rows),"source_bytes":total,"reports_crc_verified":report_count,"validation_suites":len(suites),
                "render_checks":render_checks,"canonical_captures":len(captures),
                "canonical_capture_hashes":[x["sha256"] for x in captures],"rendered_build_sha256":rendered.get("build_sha256",{})}


def verify_native_archives(out,build_hashes):
    result={}
    with zipfile.ZipFile(out/"ace-modern-systems-windows-v0.7.zip") as archive:
        members=safe_zip(archive)
        exe="ACE-Modern.exe";require(exe in members,"Windows executable missing")
        with archive.open(exe) as stream:
            header=stream.read(4096)
        require(len(header)>=64 and header[:2]==b"MZ","Invalid Windows MZ signature")
        pe=struct.unpack_from("<I",header,0x3c)[0]
        require(pe>=64 and pe+6<=members[exe].file_size,"Invalid Windows PE header offset")
        if pe+6<=len(header):signature=header[pe:pe+6]
        else:
            with archive.open(exe) as stream:stream.seek(pe);signature=stream.read(6)
        require(signature[:4]==b"PE\0\0" and struct.unpack_from("<H",signature,4)[0]==0x8664,"Windows executable must be PE x86_64")
        with archive.open(exe) as stream:digest,size=hash_stream(stream)
        require(build_hashes.get("build/windows/ACE-Modern.exe")==digest,"Windows executable differs from the rendered report export hash")
        result["windows"]={"architecture":"x86_64","exe_sha256":digest,"exe_bytes":size}
        for name,info in members.items():
            if not info.is_dir() and name!=exe:
                with archive.open(info) as stream:hash_stream(stream)
    with zipfile.ZipFile(out/"ace-modern-systems-macos-v0.7.zip") as archive:
        members=safe_zip(archive)
        candidates=[name for name,info in members.items() if ".app/Contents/MacOS/" in name and not info.is_dir()]
        require(len(candidates)==1,"Expected one macOS app executable")
        executable=candidates[0]
        with archive.open(executable) as stream:header=stream.read(4096)
        require(len(header)>=8 and header[:4]==b"\xca\xfe\xba\xbe","macOS executable is not fat MachO")
        count=struct.unpack_from(">I",header,4)[0];require(1<=count<=32,"Invalid macOS fat architecture count")
        require(len(header)>=8+count*20,"Truncated macOS fat architecture table")
        cpus={struct.unpack_from(">I",header,8+index*20)[0] for index in range(count)}
        require({0x1000007,0x100000c}.issubset(cpus),"macOS universal must contain x86_64 and arm64")
        require(members[executable].external_attr>>16 & 0o111,"macOS app executable lost executable permission")
        plist_name=executable.split(".app/",1)[0]+".app/Contents/Info.plist"
        info=plistlib.loads(archive.read(plist_name))
        require(str(info.get("CFBundleShortVersionString"))==RELEASE,"macOS Info.plist release differs from0.7.0")
        # Streaming every member detects CRC damage without buffering the app.
        for name,member in members.items():
            if not member.is_dir():
                with archive.open(member) as stream:hash_stream(stream)
        result["macos"]={"architectures":["arm64","x86_64"],"version":info["CFBundleShortVersionString"],"executable_permission":True}
    return result


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir",type=Path,default=Path("/workspace/shared/ace-modern-systems"))
    args=parser.parse_args();out=args.output_dir.resolve()
    require(out.is_dir(),"Delivery directory does not exist; run only after package.py finishes")
    downloads=json.loads((out/"downloads.json").read_text())
    require(isinstance(downloads,list) and len(downloads)==7,"Expected7 published artifacts in downloads.json")
    require({Path(row["path"]).name for row in downloads}==EXPECTED_DOWNLOADS,"Published download filenames differ from0.6 delivery")
    shared_hashes={};total=0
    for row in downloads:
        require(isinstance(row,dict) and isinstance(row.get("path"),str),"Malformed download descriptor")
        path=out/Path(row["path"]).name
        require(path.is_file(),"Published artifact missing: "+path.name)
        digest,size=hash_file(path)
        require(size==row["bytes"] and digest==row["sha256"],"Published artifact SHA/size mismatch: "+path.name)
        shared_hashes[path.name]=digest;total+=size
        print(json.dumps({"download_verified":path.name,"bytes":size}),flush=True)
    source=verify_sources(out/"ace-modern-systems-fontes-v0.7.zip",shared_hashes)
    page=relative_html_links((out/"gameplay.html").read_text(),out)
    require(len(page["embedded_capture_hashes"])>=1,"Shared HTML has no embedded screenshots")
    require(all(digest in source["canonical_capture_hashes"] for digest in page["embedded_capture_hashes"]),"HTML includes a screenshot outside verified canonical captures")
    natives=verify_native_archives(out,source["rendered_build_sha256"])
    print(json.dumps({"status":"PASS","release":RELEASE,"read_only":True,"downloads":7,"download_bytes":total,
        "sources":source,"shared_html":page,"native_archive_structure":natives},ensure_ascii=False,indent=2))
    return 0


if __name__=="__main__":
    try:raise SystemExit(main())
    except (VerificationError,OSError,KeyError,TypeError,ValueError,struct.error,zipfile.BadZipFile) as exc:
        print(json.dumps({"status":"FAIL","error":str(exc)},ensure_ascii=False),file=sys.stderr);raise SystemExit(1)
