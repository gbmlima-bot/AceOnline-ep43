"""Parser/guard tests use synthetic binary containers, never export the game."""
import hashlib
import io
import json
import contextlib
from pathlib import Path
import plistlib
import shutil
import struct
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock
import zipfile
import package_online_desktop as pkg


def project_binary(version='0.8.0'):
    key=b'application/config/version';value=version.encode()
    variant=struct.pack('<II',4,len(value))+value
    variant+=b'\0'*((-len(variant))%4)
    return b'ECFG'+struct.pack('<II',1,len(key))+key+struct.pack('<I',len(variant))+variant


def pack(version='0.8.0',remap=False):
    files={'res://project.binary':project_binary(version)}
    for number,relative in enumerate(pkg.REQUIRED_SCRIPTS):
        name='res://'+relative
        if remap:
            compiled='res://.godot/exported/abc/export-%d-%s.gdc'%(number,Path(relative).stem)
            files[name+'.remap']=('[remap]\n\npath="'+compiled+'"\n').encode()
            files[compiled]=b'GDSC'+b'tokenized-fixture'*3
        else:files[name]=b'extends Node\n# synthetic parser fixture\n'
    payload=bytearray();directory=bytearray(struct.pack('<I',len(files)))
    for name,data in files.items():
        encoded=name.removeprefix('res://').encode();encoded+=b'\0'*((-len(encoded))%4)
        directory+=struct.pack('<I',len(encoded))+encoded+struct.pack('<QQ',len(payload),len(data))+hashlib.md5(data).digest()+struct.pack('<I',0)
        payload+=data
    header=struct.pack('<4sIIIIIQQ',b'GDPC',4,4,7,2,2,112,112+len(payload))
    header+=b'\0'*(112-len(header))
    return bytes(header+payload+directory)


def macho():
    data=bytearray(8192);data[:8]=struct.pack('>4sI',b'\xca\xfe\xba\xbe',2)
    for index,(cpu,offset) in enumerate(((0x1000007,4096),(0x100000c,6144))):
        data[8+index*20:28+index*20]=struct.pack('>IIIII',cpu,0,offset,512,9)
        data[offset:offset+32]=struct.pack('<IIIIIIII',0xfeedfacf,cpu,0,2,1,8,0,0)
    return bytes(data)


class OnlineDesktopParserTests(unittest.TestCase):
    def test_pck_v4_end_directory_and_native_resource_hashes(self):
        data=pack(remap=True);stream=io.BytesIO(data)
        index,entries=pkg.pck_index(stream,len(data))
        self.assertGreater(index['directory_offset'],index['file_base'])
        payloads=pkg.read_code_payloads(stream,entries)
        result=pkg.verify_pck_code(index,entries,payloads)
        self.assertEqual(result['application_version'],'0.8.0')
        self.assertEqual(len(result['required_script_bindings']),len(pkg.REQUIRED_SCRIPTS))
        self.assertTrue(all(row['packed'].endswith('.gdc') for row in result['required_script_bindings']))
    def test_source_script_export_and_stale_version_rejected(self):
        data=pack();stream=io.BytesIO(data);index,entries=pkg.pck_index(stream,len(data))
        self.assertEqual(pkg.verify_pck_code(index,entries,pkg.read_code_payloads(stream,entries))['file_count'],len(pkg.REQUIRED_SCRIPTS)+1)
        with self.assertRaises(RuntimeError):pkg.verify_pck_code(index,entries,{'res://project.binary':project_binary('0.7.0')})
    def test_truncated_or_corrupted_pck_rejected(self):
        with self.assertRaises(RuntimeError):pkg.pck_index(io.BytesIO(b'GDPC'),4)
        data=bytearray(pack());data[112]^=1;stream=io.BytesIO(data);_,entries=pkg.pck_index(stream,len(data))
        with self.assertRaises(RuntimeError):pkg.read_code_payloads(stream,entries)
    def test_universal_cpu_slices_and_permissions(self):
        data=macho();self.assertEqual(pkg.verify_macho(io.BytesIO(data),len(data)),['arm64','x86_64'])
        broken=bytearray(data);broken[6144]=0
        with self.assertRaises(RuntimeError):pkg.verify_macho(io.BytesIO(broken),len(broken))
    def test_app_and_zip_have_same_verified_online_payload(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);app=root/'ACE Modern.app'
            (app/'Contents/MacOS').mkdir(parents=True);(app/'Contents/Resources').mkdir()
            exe=app/'Contents/MacOS/ACE Modern';exe.write_bytes(macho());exe.chmod(0o755)
            (app/'Contents/Resources/ACE Modern.pck').write_bytes(pack(remap=True))
            (app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleShortVersionString':'0.8.0','CFBundleVersion':'0.8.0'}))
            report=pkg.verify_mac(app);self.assertEqual(report['artifact_kind'],'app_directory')
            self.assertFalse(report['native_executed']);self.assertFalse(report['zip_crc_all_members'])
            target=root/'app.zip'
            with zipfile.ZipFile(target,'w',zipfile.ZIP_DEFLATED) as archive:
                for path in app.rglob('*'):archive.write(path,path.relative_to(root).as_posix())
            zipped=pkg.verify_mac(target)
            self.assertTrue(zipped['zip_crc_all_members'])
            self.assertEqual(zipped['pck']['required_script_bindings'],report['pck']['required_script_bindings'])
    def test_embedded_windows_pe32plus_pack(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'client.exe';header=bytearray(512)
            header[:2]=b'MZ';struct.pack_into('<I',header,0x3c,0x80);header[0x80:0x84]=b'PE\0\0'
            struct.pack_into('<HHIIIHH',header,0x84,0x8664,1,0,0,0,112,2)
            struct.pack_into('<H',header,0x98,0x20b);struct.pack_into('<I',header,0x98+16,0x1000)
            pck=pack(remap=True);path.write_bytes(header+pck+struct.pack('<Q4s',len(pck),b'GDPC'))
            result=pkg.verify_windows(path)
            self.assertEqual(result['architectures'],['x86_64']);self.assertEqual(result['pck']['start'],512)
    def test_historic_metadata_requires_matching_zip_and_source_survivor(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);old=root/'ace-modern-systems-macos-v0.7.zip';old.write_bytes(b'archive')
            source=root/'ace-modern-systems-fontes-v0.7.zip';source.write_bytes(b'preserved')
            records=[{'path':str(path),'bytes':path.stat().st_size,'sha256':pkg.digest(path)} for path in (old,source)]
            (root/'downloads.json').write_text(json.dumps(records))
            self.assertEqual(pkg.old_metadata(old)['sha256'],pkg.digest(old))
            old.write_bytes(b'changed')
            with self.assertRaises(RuntimeError):pkg.old_metadata(old)
            self.assertTrue(source.exists())

    def test_historical_index_keeps_original_and_repairs_platform_versions(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);source=root/'ace-modern-systems-fontes-v0.7.zip';source.write_bytes(b'original source')
            records=[{'path':str(root/pkg.OLD_NAMES['macos']),'bytes':1,'sha256':'old-mac'},
                     {'path':str(root/pkg.OLD_NAMES['windows']),'bytes':1,'sha256':'old-win'},
                     {'path':str(source),'bytes':source.stat().st_size,'sha256':pkg.digest(source)}]
            original=json.dumps(records).encode();(root/'downloads.json').write_bytes(original)
            historical=pkg.ensure_historical_index(root)
            new={'path':'/new/'+pkg.NAMES['macos'],'release':'0.8.0','bytes':2,'sha256':'new-mac','platform':'macos'}
            pkg.update_historical_index(root,'macos',new)
            updated=json.loads((root/'downloads.json').read_text())
            self.assertEqual(historical.read_bytes(),original)
            self.assertEqual(updated[0],new)
            self.assertEqual(updated[1]['release'],'0.7.0')
            self.assertEqual(updated[2]['release'],'0.7.0');self.assertEqual(updated[2]['artifact_kind'],'full_source')
            self.assertTrue(source.is_file())

    def _publication_fixture(self,directory,release='0.8.0'):
        root=Path(directory);app=root/'staging/ACE Modern.app'
        (app/'Contents/MacOS').mkdir(parents=True);(app/'Contents/Resources').mkdir()
        exe=app/'Contents/MacOS/ACE Modern';exe.write_bytes(macho());exe.chmod(0o755)
        (app/'Contents/Resources/ACE Modern.pck').write_bytes(pack(version=release,remap=True))
        (app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleShortVersionString':release,'CFBundleVersion':release}))
        report=pkg.verify_mac(app,release);report.update({'release':release,'verified':True,'artifact':str(app)})
        report_path=root/'verified.json';report_path.write_text(json.dumps(report))
        old_directory=root/'historical';old_directory.mkdir()
        old=old_directory/pkg.OLD_NAMES['macos'];old.write_bytes(b'old generated archive')
        source=old_directory/'ace-modern-systems-fontes-v0.7.zip';source.write_bytes(b'historic complete source')
        records=[{'path':str(path),'bytes':path.stat().st_size,'sha256':pkg.digest(path)} for path in (old,source)]
        (old_directory/'downloads.json').write_text(json.dumps(records))
        return root,old,source,SimpleNamespace(report=report_path,output_dir=root/'published',retire_old=True,clean_staging=False)

    def test_publication_validates_and_publishes_before_retiring_previous_download(self):
        with tempfile.TemporaryDirectory() as directory:
            root,old,source,args=self._publication_fixture(directory)
            verifier=pkg.verify_mac;verified=[]
            def checking_verifier(path,release=None):
                self.assertTrue(old.exists())
                result=verifier(path,release);verified.append(result['zip_crc_all_members']);return result
            replace=pkg.os.replace
            def checking_replace(source_path,target_path):
                if str(source_path).endswith('.part'):
                    self.assertTrue(old.exists());self.assertEqual(verified,[True])
                return replace(source_path,target_path)
            with mock.patch.object(pkg,'ROOT',root),mock.patch.object(pkg,'OLD_DIRECTORY',old.parent),mock.patch.object(pkg,'verify_mac',checking_verifier),mock.patch.object(pkg.os,'replace',checking_replace),contextlib.redirect_stdout(io.StringIO()):
                pkg.publish(args)
            self.assertFalse(old.exists());self.assertTrue(source.exists())
            self.assertTrue((args.output_dir/pkg.NAMES['macos']).exists())
            self.assertEqual(json.loads((old.parent/'retirement-macos-v08.json').read_text())['state'],'retired_replaced')
            self.assertEqual(json.loads((old.parent/'downloads.json').read_text())[0]['release'],'0.8.0')

    def test_failed_new_zip_validation_preserves_previous_download(self):
        with tempfile.TemporaryDirectory() as directory:
            root,old,source,args=self._publication_fixture(directory)
            with mock.patch.object(pkg,'ROOT',root),mock.patch.object(pkg,'OLD_DIRECTORY',old.parent),mock.patch.object(pkg,'verify_mac',side_effect=RuntimeError('invalid replacement')):
                with self.assertRaisesRegex(RuntimeError,'invalid replacement'):pkg.publish(args)
            self.assertTrue(old.exists());self.assertTrue(source.exists())
            self.assertFalse((args.output_dir/pkg.NAMES['macos']).exists())
            self.assertEqual(json.loads((old.parent/'downloads.json').read_text())[0]['path'],str(old))

    def test_requested_release_and_runtime_default_reject_stale_pck(self):
        data=pack(version='0.9.0');stream=io.BytesIO(data)
        index,entries=pkg.pck_index(stream,len(data));payloads=pkg.read_code_payloads(stream,entries)
        self.assertEqual(pkg.verify_pck_code(index,entries,payloads,release='0.9.0')['application_version'],'0.9.0')
        with self.assertRaisesRegex(RuntimeError,'version mismatch'):
            pkg.verify_pck_code(index,entries,payloads)
        with mock.patch.object(pkg,'RELEASE','0.9.0'):
            self.assertEqual(pkg.verify_pck_code(index,entries,payloads)['application_version'],'0.9.0')

    def test_release_names_and_archive_notices(self):
        self.assertEqual(pkg.artifact_name('macos'),pkg.NAMES['macos'])
        self.assertEqual(pkg.artifact_name('windows','0.9.0'),'ace-modern-online-windows-v0.9.zip')
        self.assertEqual(pkg.artifact_name('macos','0.9.1'),'ace-modern-online-macos-v0.9.1.zip')
        self.assertEqual(pkg.report_tag('0.9.0'),'v09')
        with self.assertRaises(RuntimeError):pkg.release_version('../0.9.0')
        with tempfile.TemporaryDirectory() as directory:
            archive=io.BytesIO()
            with mock.patch.object(pkg,'ROOT',Path(directory)),zipfile.ZipFile(archive,'w') as writer:
                pkg.add_notices(writer,'0.9.0')
            with zipfile.ZipFile(io.BytesIO(archive.getvalue())) as reader:
                self.assertIn('ACE Modern0.9',reader.read('LEIA-ME-ONLINE.txt').decode())

    def test_v09_publication_preserves_previous_packages_and_index(self):
        with tempfile.TemporaryDirectory() as directory:
            root,old,source,args=self._publication_fixture(directory,'0.9.0')
            args.release='0.9.0';args.retire_old=False
            args.output_dir.mkdir();previous=args.output_dir/pkg.NAMES['macos'];previous.write_bytes(b'preserved 0.8 download')
            delivery={'platform':'macos','release':'0.8.0','path':str(previous),'sha256':pkg.digest(previous),'bytes':previous.stat().st_size}
            (args.output_dir/'downloads.json').write_text(json.dumps([delivery]))
            old_index=(old.parent/'downloads.json').read_bytes()
            with mock.patch.object(pkg,'ROOT',root),mock.patch.object(pkg,'OLD_DIRECTORY',old.parent),contextlib.redirect_stdout(io.StringIO()):
                pkg.publish(args)
            self.assertEqual(previous.read_bytes(),b'preserved 0.8 download')
            self.assertEqual((old.parent/'downloads.json').read_bytes(),old_index)
            self.assertTrue(old.exists());self.assertTrue(source.exists())
            current=args.output_dir/'ace-modern-online-macos-v0.9.zip'
            self.assertEqual(pkg.verify_mac(current,'0.9.0')['plist_version'],'0.9.0')
            rows=json.loads((args.output_dir/'downloads.json').read_text())
            self.assertEqual(rows[0],delivery);self.assertEqual(rows[1]['release'],'0.9.0')
            report=json.loads((root/'reports/desktop-macos-published-v09.json').read_text())
            self.assertIsNone(report['retirement']);self.assertFalse(report['delivery']['native_executed'])

    def test_v09_cannot_retire_historical_downloads(self):
        with tempfile.TemporaryDirectory() as directory:
            root,old,source,args=self._publication_fixture(directory,'0.9.0');args.release='0.9.0'
            with mock.patch.object(pkg,'ROOT',root),mock.patch.object(pkg,'OLD_DIRECTORY',old.parent):
                with self.assertRaisesRegex(RuntimeError,'newer releases preserve previous packages'):pkg.publish(args)
            self.assertTrue(old.exists());self.assertTrue(source.exists());self.assertFalse(args.output_dir.exists())

    def test_export_uses_requested_release_and_preserves_tmpdir(self):
        with tempfile.TemporaryDirectory() as directory:
            root,old,source,args=self._publication_fixture(directory,'0.9.0')
            (root/'client/scripts').mkdir(parents=True)
            (root/'client/project.godot').write_text('[application]\nconfig/version="0.9.0"\n')
            (root/'client/export_presets.cfg').write_text('# synthetic export fixture\n')
            export_args=SimpleNamespace(release='0.9.0',authorize_export=True,platform='macos',staging=root/'exported',godot='mock-godot',data_home=root/'data',cache_home=root/'cache',report=None)
            def fake_export(command,**kwargs):
                self.assertEqual(kwargs['env']['TMPDIR'],str(root/'scratch'))
                shutil.copytree(root/'staging/ACE Modern.app',Path(command[-1]))
                return SimpleNamespace(returncode=0)
            with mock.patch.object(pkg,'ROOT',root),mock.patch.object(pkg.subprocess,'run',side_effect=fake_export),mock.patch.dict(pkg.os.environ,{'TMPDIR':str(root/'scratch')}),contextlib.redirect_stdout(io.StringIO()):
                pkg.export(export_args)
            report=json.loads((root/'reports/desktop-macos-v09.json').read_text())
            self.assertEqual(report['release'],'0.9.0');self.assertFalse(report['native_executed'])
            self.assertTrue((root/'reports/export-macos-v09.log').exists())

    def test_cli_release_defaults_and_explicit_version(self):
        common=['package_online_desktop.py','export','--platform','macos','--godot','mock-godot','--staging','unused']
        for options,expected in (([],'0.8.0'),(['--release','0.9.0'],'0.9.0')):
            with self.subTest(options=options),mock.patch('sys.argv',common+options),mock.patch.object(pkg,'export') as handler:
                pkg.main()
                self.assertEqual(handler.call_args.args[0].release,expected)

if __name__=='__main__':unittest.main()
