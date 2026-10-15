#!/usr/bin/env python3
"""Bounded-storage desktop export, native/PCK verification and optional retirement.

Export does not publish or retire anything. Publishing needs a verified replacement
and an explicit --retire-old authorization. Historic source archives are untouched.
"""
from __future__ import annotations
import argparse
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import struct
import subprocess
import time
import zipfile

ROOT = Path(__file__).resolve().parents[1]
RELEASE = '0.8.0'
CHUNK = 4 * 1024 * 1024
PRESETS = {'macos':'macOS', 'windows':'Windows'}
NAMES = {'macos':'ace-modern-online-macos-v0.8.zip', 'windows':'ace-modern-online-windows-v0.8.zip'}
OLD_NAMES = {'macos':'ace-modern-systems-macos-v0.7.zip', 'windows':'ace-modern-systems-windows-v0.7.zip'}
OLD_DIRECTORY = Path('/workspace/shared/ace-modern-systems')
REQUIRED_SCRIPTS = ['scripts/main.gd', 'scripts/game_systems.gd', 'scripts/legacy_hud.gd',
                    'scripts/online/online_client.gd', 'scripts/online/json_wire.gd',
                    'scripts/online/arena_model.gd','scripts/online/online_view.gd','scripts/combat_runtime.gd']
README_TEMPLATE = '''ACE Modern{version} — cliente desktop\n\nInclui o modo offline e o cliente da sala dedicada do novo jogo. A sala piloto\nonline exige URL WSS e token individual fornecidos pelo operador. Não se conecta\naos servidores do jogo legado. Tokens não devem ser compartilhados publicamente.\n\nOs executáveis foram exportados no Linux. macOS e Windows ainda exigem teste\nnativo. O aplicativo macOS é universal(Apple Silicon+Intel), com assinatura\nad-hoc e sem notarização. Windows é x86_64, sem assinatura Authenticode.\n\nOs materiais e fontes completos das versões anteriores continuam preservados.\nA reprodução integral do MMO original não está incluída nesta versão piloto.\n'''
README = README_TEMPLATE.format(version='0.8')


def require(condition, message):
    if not condition: raise RuntimeError(message)


def release_version(release=None):
    value = RELEASE if release is None else release
    require(isinstance(value,str) and re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)',value),
            'Release must be a numeric major.minor.patch version, for example 0.9.0')
    return value


def release_label(release=None):
    version=release_version(release)
    return version[:-2] if version.endswith('.0') else version


def report_tag(release=None):
    major,minor,patch=release_version(release).split('.')
    return 'v0'+minor if major=='0' and patch=='0' else 'v'+'_'.join((major,minor,patch))


def artifact_name(platform,release=None):
    require(platform in PRESETS,'Unsupported desktop platform')
    return 'ace-modern-online-'+platform+'-v'+release_label(release)+'.zip'


def digest(path: Path) -> str:
    with path.open('rb') as stream: return hashlib.file_digest(stream,'sha256').hexdigest()


def utc_now():return time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime())


def write_json(path: Path, value):
    path.parent.mkdir(parents=True,exist_ok=True)
    temporary=path.with_name(path.name+'.tmp')
    with temporary.open('w') as stream:
        json.dump(value,stream,ensure_ascii=False,indent=2)
        stream.write('\n');stream.flush();os.fsync(stream.fileno())
    os.replace(temporary,path)


def read_exact(stream, count):
    data=stream.read(count)
    require(len(data)==count,'Truncated binary structure')
    return data


def u32(stream): return struct.unpack('<I',read_exact(stream,4))[0]
def u64(stream): return struct.unpack('<Q',read_exact(stream,8))[0]


def safe_members(archive):
    members={}
    for item in archive.infolist():
        name=item.filename;p=PurePosixPath(name)
        require(not p.is_absolute() and '..' not in p.parts and '\\' not in name and name not in members,'Unsafe or duplicate ZIP member: '+name)
        members[name]=item
    return members


def pck_index(stream, total_size, start=0):
    """Godot4.7 supports PCKv2/v3/v4; exported4.7.2 currently writes v4."""
    stream.seek(start)
    require(read_exact(stream,4)==b'GDPC','PCK magic missing')
    version=u32(stream);engine=[u32(stream),u32(stream),u32(stream)]
    require(version in (2,3,4) and engine==[4,7,2],'Unexpected PCK/engine version')
    flags=u32(stream)
    require(not flags & (1|4),'Encrypted/sparse PCK is not supported by this verifier')
    base=u64(stream)
    if version in (3,4) or flags&2: base+=start
    if version in (3,4): directory=start+u64(stream);stream.seek(directory)
    else: read_exact(stream,64);directory=stream.tell()
    require(start<=directory<total_size and start<=base<total_size,'Invalid PCK directory/data offset')
    count=u32(stream);require(0<count<=1000000,'Invalid PCK file count')
    entries={}
    for _ in range(count):
        length=u32(stream);require(0<length<=16384,'Invalid PCK path size')
        raw=read_exact(stream,length).rstrip(b'\x00').decode('utf-8')
        relative=raw.removeprefix('res://')
        require(relative and not PurePosixPath(relative).is_absolute() and '..' not in PurePosixPath(relative).parts and '\\' not in relative and '\x00' not in relative and '://' not in relative,'Unsafe PCK resource path')
        path='res://'+relative
        offset=base+u64(stream);size=u64(stream);md5=read_exact(stream,16).hex();file_flags=u32(stream)
        require(path not in entries,'Duplicate PCK resource')
        require(not file_flags and base<=offset<=total_size and size<=total_size-offset,'Unsupported/corrupt PCK entry: '+path)
        entries[path]={'offset':offset,'bytes':size,'md5':md5}
    return {'version':version,'engine':engine,'flags':flags,'start':start,'file_base':base,'directory_offset':directory,'file_count':count},entries


def binary_settings(data):
    stream=io.BytesIO(data);require(read_exact(stream,4)==b'ECFG','Missing project.binary settings signature')
    count=u32(stream);require(count<100000,'Invalid binary settings count');result={}
    for _ in range(count):
        length=u32(stream);require(length<=16384,'Invalid settings key size');key=read_exact(stream,length).decode('utf-8')
        size=u32(stream);require(size<=16*1024*1024,'Invalid setting payload');value=read_exact(stream,size)
        if len(value)>=8 and struct.unpack_from('<I',value)[0]&0xffff==4:
            length=struct.unpack_from('<I',value,4)[0]
            require(length<=len(value)-8,'Invalid string setting')
            result[key]=value[8:8+length].decode('utf-8')
    return result


def read_code_payloads(stream, entries):
    selected={path:entry for path,entry in entries.items() if path=='res://project.binary' or path.endswith(('.gdc','.gd','.gd.remap'))}
    require(sum(row['bytes'] for row in selected.values())<64*1024*1024,'Unexpected code payload size')
    payloads={}
    for path,entry in sorted(selected.items(),key=lambda pair:pair[1]['offset']):
        stream.seek(entry['offset']);data=read_exact(stream,entry['bytes'])
        require(hashlib.md5(data).hexdigest()==entry['md5'],'PCK resource MD5 mismatch: '+path)
        payloads[path]=data
    return payloads


def verify_pck_code(index,entries,payloads,release=None,require_online=True):
    release=release_version(release)
    require('res://project.binary' in payloads,'PCK project.binary missing')
    settings=binary_settings(payloads['res://project.binary'])
    require(settings.get('application/config/version')==release,'PCK application version mismatch')
    required=REQUIRED_SCRIPTS if require_online else REQUIRED_SCRIPTS[:3]
    bindings=[]
    for relative in required:
        source='res://'+relative;packed=source
        if source not in payloads:
            remap=source+'.remap'
            require(remap in payloads,'PCK script remap missing: '+source)
            match=re.search(rb'^path="([^"]+)"',payloads[remap],re.M)
            require(match is not None,'PCK script remap is malformed: '+source)
            packed=match.group(1).decode('utf-8')
        require(packed in payloads and len(payloads[packed])>16,'PCK script payload missing: '+source)
        bindings.append({'source':source,'packed':packed,**entries[packed]})
    return {**index,'application_version':release,'required_script_bindings':bindings,'project_binary_md5':entries['res://project.binary']['md5'],'code_md5_verified':len(payloads)}


def app_fingerprint(path):
    records=[]
    for member in sorted(path.rglob('*')):
        relative=member.relative_to(path).as_posix()
        if member.is_symlink():
            records.append({'path':relative,'symlink':os.readlink(member),'mode':member.lstat().st_mode&0o777})
        elif member.is_file():
            records.append({'path':relative,'bytes':member.stat().st_size,'sha256':digest(member),'mode':member.stat().st_mode&0o777})
    encoded=json.dumps(records,sort_keys=True,separators=(',',':')).encode()
    return {'sha256':hashlib.sha256(encoded).hexdigest(),'bytes':sum(row.get('bytes',0) for row in records),'tree':records}


def verify_macho(stream,total_size):
    stream.seek(0);header=read_exact(stream,8)
    require(header[:4]==b'\xca\xfe\xba\xbe','Executable is not fat Mach-O')
    count=struct.unpack_from('>I',header,4)[0];require(1<=count<=32,'Invalid fat architecture count')
    table=read_exact(stream,count*20);segments=[];cpus=set()
    for index in range(count):
        cpu,subtype,offset,size,alignment=struct.unpack_from('>IIIII',table,index*20)
        require(offset>=8+count*20 and size>=32 and offset+size<=total_size and alignment<=30 and offset%(1<<alignment)==0,'Invalid fat Mach-O slice')
        cpus.add(cpu);segments.append((offset,offset+size,cpu))
    ordered=sorted(segments)
    require(all(ordered[i][1]<=ordered[i+1][0] for i in range(len(ordered)-1)),'Overlapping fat Mach-O slices')
    for offset,end,cpu in ordered:
        stream.seek(offset);slice_header=read_exact(stream,32)
        require(slice_header[:4]==b'\xcf\xfa\xed\xfe' and struct.unpack_from('<I',slice_header,4)[0]==cpu,'Mach-O64 slice CPU/magic mismatch')
        filetype,ncommands,sizecommands=struct.unpack_from('<III',slice_header,12)
        require(filetype==2 and ncommands>0 and sizecommands<=end-offset-32,'Invalid Mach-O executable load commands')
    require({0x1000007,0x100000c}.issubset(cpus),'Mac executable must contain arm64 and x86_64')
    return ['arm64','x86_64']


def verify_mac_app(path: Path,release=None,require_online=True):
    release=release_version(release)
    require(path.name.endswith('.app') and path.is_dir(),'Expected a macOS .app bundle directory')
    executables=[x for x in (path/'Contents/MacOS').iterdir() if x.is_file()]
    require(len(executables)==1,'Expected one .app executable')
    executable=executables[0]
    with executable.open('rb') as stream: verify_macho(stream,executable.stat().st_size)
    require(executable.stat().st_mode&0o111,'Mac executable permission missing')
    plist=plistlib.loads((path/'Contents/Info.plist').read_bytes())
    require(str(plist.get('CFBundleShortVersionString'))==release and str(plist.get('CFBundleVersion'))==release,'App Info.plist version mismatch')
    pcks=list((path/'Contents/Resources').glob('*.pck'));require(len(pcks)==1,'Expected one .app resource PCK')
    with pcks[0].open('rb') as stream:
        index,entries=pck_index(stream,pcks[0].stat().st_size)
        payloads=read_code_payloads(stream,entries)
    report=verify_pck_code(index,entries,payloads,release,require_online)
    return {'platform':'macos','artifact_kind':'app_directory','architectures':['arm64','x86_64'],
            'native_executed':False,'zip_crc_all_members':False,'executable_permission':True,
            'plist_version':release,'pck':report,**app_fingerprint(path)}


def verify_mac(path: Path,release=None,require_online=True):
    release=release_version(release)
    if path.is_dir(): return verify_mac_app(path,release,require_online)
    with zipfile.ZipFile(path) as archive:
        members=safe_members(archive)
        executables=[name for name,item in members.items() if '.app/Contents/MacOS/' in name and not item.is_dir()]
        require(len(executables)==1,'Expected one macOS app executable');executable=executables[0]
        with archive.open(executable) as stream: verify_macho(stream,members[executable].file_size)
        require(members[executable].external_attr>>16&0o111,'Mac executable permission missing')
        plist_path=executable.split('.app/',1)[0]+'.app/Contents/Info.plist'
        plist=plistlib.loads(archive.read(plist_path))
        require(str(plist.get('CFBundleShortVersionString'))==release and str(plist.get('CFBundleVersion'))==release,'Info.plist version mismatch')
        pcks=[name for name in members if name.endswith('.pck')];require(len(pcks)==1,'Expected one macOS resource PCK')
        pck=pcks[0]
        # Seeking to v4's final directory reads/decompresses all prior bytes;
        # consuming the tail triggers ZipExtFile's complete member CRC check.
        with archive.open(pck) as stream:
            index,entries=pck_index(stream,members[pck].file_size)
            while stream.read(CHUNK): pass
        for name,item in members.items():
            if not item.is_dir() and name!=pck:
                with archive.open(item) as stream:
                    while stream.read(CHUNK): pass
        with archive.open(pck) as stream: payloads=read_code_payloads(stream,entries)
        pck_report=verify_pck_code(index,entries,payloads,release,require_online)
    return {'platform':'macos','architectures':['arm64','x86_64'],'native_executed':False,'zip_crc_all_members':True,
            'executable_permission':True,'plist_version':release,'pck':pck_report,'sha256':digest(path),'bytes':path.stat().st_size}


def verify_windows(path: Path,release=None,require_online=True):
    release=release_version(release)
    with path.open('rb') as stream:
        require(read_exact(stream,2)==b'MZ','Windows MZ signature missing');stream.seek(0x3c);pe=u32(stream)
        stream.seek(pe);require(read_exact(stream,4)==b'PE\0\0','Windows PE signature missing')
        machine,sections,stamp,symbol_table,symbols,optional_size,characteristics=struct.unpack('<HHIIIHH',read_exact(stream,20))
        require(machine==0x8664 and 1<=sections<=96 and optional_size>=112,'Windows executable must be PE32+ x86_64')
        optional=read_exact(stream,optional_size)
        require(struct.unpack_from('<H',optional)[0]==0x20b and struct.unpack_from('<I',optional,16)[0]>0,'Windows PE32+ entrypoint is missing')
        stream.seek(-12,2);pack_size=u64(stream);require(read_exact(stream,4)==b'GDPC','Embedded PCK footer missing')
        start=path.stat().st_size-12-pack_size;require(start>pe,'Invalid embedded PCK size')
        index,entries=pck_index(stream,path.stat().st_size-12,start)
        payloads=read_code_payloads(stream,entries)
        pck_report=verify_pck_code(index,entries,payloads,release,require_online)
    return {'platform':'windows','architectures':['x86_64'],'native_executed':False,'pck':pck_report,'sha256':digest(path),'bytes':path.stat().st_size}


def source_fingerprint():
    paths=[ROOT/'client/project.godot',ROOT/'client/export_presets.cfg',*sorted((ROOT/'client/scripts').rglob('*.gd'))]
    return {str(path.relative_to(ROOT)):{'sha256':digest(path),'bytes':path.stat().st_size} for path in paths}


def add_notices(archive,release=None):
    archive.writestr('LEIA-ME-ONLINE.txt',README_TEMPLATE.format(version=release_label(release)))
    for path in sorted((ROOT/'third_party').glob('*')):
        if path.is_file(): archive.write(path,'third_party/'+path.name)


def verify_artifact(platform,path,release=None):
    return verify_mac(path,release) if platform=='macos' else verify_windows(path,release)


def export(args):
    release=release_version(getattr(args,'release',None));tag=report_tag(release)
    require(args.authorize_export,'Export needs --authorize-export after the root declares the client frozen')
    require('config/version="'+release+'"' in (ROOT/'client/project.godot').read_text(),'Client release does not match '+release)
    before=source_fingerprint()
    stage=args.staging.resolve();stage.mkdir(parents=True,exist_ok=True)
    artifact=stage/('ACE Modern.app' if args.platform=='macos' else 'ACE-Modern.exe')
    require(not artifact.exists(),'Export target already exists; choose a fresh staging directory')
    log=ROOT/'reports'/('export-'+args.platform+'-'+tag+'.log');log.parent.mkdir(parents=True,exist_ok=True)
    cache_home=args.cache_home or Path('/tmp/ace-export-cache-'+tag)
    env=os.environ.copy();env['XDG_DATA_HOME']=str(args.data_home.resolve())
    env['XDG_CACHE_HOME']=str(cache_home.resolve());env.setdefault('TMPDIR','/tmp')
    cache_home.mkdir(parents=True,exist_ok=True)
    with log.open('w') as stream:
        process=subprocess.run([args.godot,'--headless','--path',str(ROOT/'client'),'--export-release',PRESETS[args.platform],str(artifact)],env=env,stdout=stream,stderr=subprocess.STDOUT)
    text=log.read_text(errors='replace')
    require(process.returncode==0 and not any(marker in text for marker in ['ERROR:','SCRIPT ERROR:','Parse Error:']),'Godot export failed; see '+str(log))
    require(source_fingerprint()==before,'Client code changed during export; replacement is not frozen')
    report=verify_artifact(args.platform,artifact,release)
    report.update({'release':release,'artifact':str(artifact),'export_log':str(log),'source_fingerprint':before,'verified':True,'verified_at_utc':utc_now()})
    output=args.report or ROOT/'reports'/('desktop-'+args.platform+'-'+tag+'.json')
    write_json(output,report)
    print(json.dumps({'platform':args.platform,'verified':True,'artifact':str(artifact),'report':str(output),'native_executed':False}),flush=True)


def verify(args):
    release=release_version(getattr(args,'release',None))
    report=verify_artifact(args.platform,args.artifact.resolve(),release)
    report.update({'release':release,'artifact':str(args.artifact.resolve()),'verified':True,'verified_at_utc':utc_now()})
    write_json(args.report,report)
    print(json.dumps({'platform':args.platform,'verified':True,'report':str(args.report),'native_executed':False}))


def old_metadata(old):
    manifest=old.parent/'downloads-v07-historical.json'
    if not manifest.is_file():manifest=old.parent/'downloads.json'
    records=json.loads(manifest.read_text())
    record=next((row for row in records if Path(row['path']).name==old.name),None)
    require(record is not None,'Historical delivery metadata missing')
    require(old.stat().st_size==record['bytes'] and digest(old)==record['sha256'],'Historical package differs from recorded delivery')
    # Historic full-source packages are mandatory survivors, never retirement targets.
    for row in records:
        if '-fontes-' in Path(row['path']).name:
            require(Path(row['path']).is_file(),'Historical full-source package must remain preserved')
    return dict(record)


def ensure_historical_index(directory):
    original=directory/'downloads.json';historical=directory/'downloads-v07-historical.json'
    if not historical.exists():shutil.copy2(original,historical)
    return historical


def update_historical_index(directory,platform,delivery):
    index=directory/'downloads.json';records=json.loads(index.read_text())
    updated=[];replaced=False
    for record in records:
        if Path(record['path']).name==OLD_NAMES[platform]:
            updated.append(dict(delivery));replaced=True
        else:
            copy=dict(record);copy.setdefault('release','0.7.0')
            if '-fontes-' in Path(copy['path']).name:copy.setdefault('artifact_kind','full_source')
            updated.append(copy)
    require(replaced,'Historical platform entry missing while repairing download links')
    write_json(index,updated)


def publish(args):
    release=release_version(getattr(args,'release',None));tag=report_tag(release)
    report=json.loads(args.report.read_text());platform=report.get('platform')
    require(platform in PRESETS and report.get('release')==release and report.get('verified') is True,'Verified '+release+' report required')
    retire_old=getattr(args,'retire_old',False)
    require(not retire_old or release=='0.8.0','--retire-old is limited to the historical 0.8.0 replacement of 0.7.0; newer releases preserve previous packages')
    source=Path(report['artifact'])
    current=app_fingerprint(source) if source.is_dir() else {'sha256':digest(source),'bytes':source.stat().st_size}
    require(current['bytes']==report['bytes'] and current['sha256']==report['sha256'],'Verified replacement changed or disappeared')
    output=args.output_dir.resolve();output.mkdir(parents=True,exist_ok=True);target=output/artifact_name(platform,release)
    require(not target.exists(),'Published target already exists')
    old=None;retirement=None;retirement_path=None
    if retire_old:
        old=OLD_DIRECTORY/OLD_NAMES[platform]
        historical=ensure_historical_index(old.parent)
        previous=old_metadata(old)
    # Leave the previous public download available throughout compression and
    # validation. A conservative raw-size bound includes ZIP overhead/notices.
    required_space=current['bytes']+max(64*1024*1024,current['bytes']//100)
    require(shutil.disk_usage(output).free>=required_space,'Not enough space to publish the new ZIP while retaining the previous public download')
    if retire_old:
        retirement={'old':previous,'replacement':str(target),'replacement_raw_sha256':report['sha256'],'release':release,'reason':'Verified0.8 desktop replacement; historic full-source archives preserved','state':'replacement_verified_retirement_authorized','historical_index':{'path':str(historical),'sha256':digest(historical),'bytes':historical.stat().st_size}}
        retirement_path=old.parent/('retirement-'+platform+'-'+tag+'.json')
        write_json(retirement_path,retirement)
    temporary=target.with_name(target.name+'.part')
    require(not temporary.exists(),'Partial publication target already exists; choose a fresh output directory or inspect that partial file')
    if platform=='macos':
        if source.is_dir():
            with zipfile.ZipFile(temporary,'w',zipfile.ZIP_DEFLATED,compresslevel=6,allowZip64=True) as archive:
                for member in sorted(source.rglob('*')):
                    name=source.name+'/'+member.relative_to(source).as_posix()
                    if member.is_symlink():
                        entry=zipfile.ZipInfo(name);entry.create_system=3
                        entry.external_attr=(0o120777)<<16
                        archive.writestr(entry,os.readlink(member).encode())
                    else:archive.write(member,name)
                add_notices(archive,release)
            zipped=verify_mac(temporary,release)
            write_json(ROOT/'reports'/('desktop-macos-zip-'+tag+'.json'),zipped)
            require(zipped['zip_crc_all_members'],'Final Mac ZIP CRC validation failed')
        else:
            shutil.copyfile(source,temporary)
            require(digest(temporary)==report['sha256'],'Published Mac copy differs from verified ZIP')
    else:
        with zipfile.ZipFile(temporary,'w',zipfile.ZIP_DEFLATED,compresslevel=6,allowZip64=True) as archive:
            archive.write(source,'ACE-Modern.exe');add_notices(archive,release)
        with zipfile.ZipFile(temporary) as archive:
            members=safe_members(archive)
            with archive.open('ACE-Modern.exe') as stream:
                sha=hashlib.file_digest(stream,'sha256').hexdigest()
            require(sha==report['sha256'],'Published Windows executable differs from verified raw export')
            for name,item in members.items():
                if not item.is_dir() and name!='ACE-Modern.exe':
                    with archive.open(item) as stream:
                        while stream.read(CHUNK):pass
    os.replace(temporary,target)
    delivery={'path':str(target),'bytes':target.stat().st_size,'sha256':digest(target),'platform':platform,'release':release,'native_executed':False,'verification_report':str(args.report),'published_at_utc':utc_now()}
    if retire_old:
        retirement.update({'state':'replacement_published','replacement_sha256':delivery['sha256'],'replacement_bytes':delivery['bytes']})
        write_json(retirement_path,retirement)
        update_historical_index(old.parent,platform,delivery)
    index=output/'downloads.json';downloads=json.loads(index.read_text()) if index.is_file() else []
    downloads=[row for row in downloads if not (row.get('platform')==platform and row.get('release')==release)];downloads.append(delivery);write_json(index,downloads)
    if retire_old:
        # Both indexes point to the verified replacement before explicit retirement.
        old.unlink()
        retirement['state']='retired_replaced';write_json(retirement_path,retirement)
    published=ROOT/'reports'/('desktop-'+platform+'-published-'+tag+'.json');write_json(published,{'delivery':delivery,'retirement':retirement,'raw_verification':report})
    if args.clean_staging:
        if source.is_dir():shutil.rmtree(source)
        else:source.unlink()
    print(json.dumps({'published':delivery,'retired':str(old) if retire_old else None,'historic_sources_preserved':True}),flush=True)


def main():
    parser=argparse.ArgumentParser(description=__doc__);sub=parser.add_subparsers(dest='command',required=True)
    p=sub.add_parser('export');p.add_argument('--release',default=RELEASE,type=release_version);p.add_argument('--platform',choices=PRESETS,required=True);p.add_argument('--godot',required=True);p.add_argument('--staging',type=Path,required=True);p.add_argument('--data-home',type=Path,default=Path('/workspace/tools/godot-data'));p.add_argument('--cache-home',type=Path);p.add_argument('--authorize-export',action='store_true');p.add_argument('--report',type=Path);p.set_defaults(run=export)
    p=sub.add_parser('verify');p.add_argument('--release',default=RELEASE,type=release_version);p.add_argument('--platform',choices=PRESETS,required=True);p.add_argument('--artifact',type=Path,required=True);p.add_argument('--report',type=Path,required=True);p.set_defaults(run=verify)
    p=sub.add_parser('publish');p.add_argument('--release',default=RELEASE,type=release_version);p.add_argument('--report',type=Path,required=True);p.add_argument('--output-dir',type=Path,default=Path('/workspace/shared/ace-modern-online'));p.add_argument('--retire-old',action='store_true',help='Historical 0.8.0 only: explicitly retire the verified 0.7.0 executable ZIP');p.add_argument('--clean-staging',action='store_true');p.set_defaults(run=publish)
    args=parser.parse_args();args.run(args)

if __name__=='__main__': main()
