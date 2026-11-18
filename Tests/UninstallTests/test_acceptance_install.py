import importlib.util
from pathlib import Path
import tempfile
import unittest
import os
import json
import zipfile
import io

spec=importlib.util.spec_from_file_location('acceptance_install',Path(__file__).resolve().parents[2]/'scripts/acceptance-install.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
class Crash(BaseException):pass
class Service:
    def __init__(self):self.on=False;self.fail=False;self.checked=0
    def verify(self,payload):self.checked+=1
    def loaded(self):return self.on
    def bootstrap(self,p):
        self.on=True
        if self.fail:raise RuntimeError('failed after registration')
    def bootout(self):self.on=False

class AcceptanceInstallTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.root=Path(self.tmp.name);self.s=Service()
        self.files={'NeSpat.app/Contents/helper':b'NO EXECUTOR','profile.json':b'{"enabled":false}'}
        self.manifest={'files':{n:{'mode':0o644} for n in self.files}}
    def tearDown(self):self.tmp.cleanup()
    def tx(self,fault=lambda _:None):return m.Transaction(self.root/'base',self.root/'daemon.plist',self.root/'transaction.json',self.s,os.getuid(),fault)
    def assert_clean(self):
        self.assertFalse((self.root/'base').exists());self.assertFalse((self.root/'daemon.plist').exists());self.assertFalse(self.s.on)
    def test_install_then_exact_rollback_is_idempotent(self):
        t=self.tx();t.install(self.files,self.manifest,lambda:True)
        self.assertTrue(self.s.on);self.assertEqual(self.s.checked,1)
        self.assertEqual(json.loads(t.journal.read_text())['phase'],'installed')
        self.tx().rollback();self.tx().rollback();self.assert_clean()
    def test_preflight_unknown_or_failure_never_writes(self):
        for probe in [lambda:False,lambda:(_ for _ in ()).throw(m.Stop('unknown'))]:
            with self.assertRaises(m.Stop):self.tx().install(self.files,self.manifest,probe)
            self.assertEqual(list(self.root.iterdir()),[])
    def test_exception_every_stage_rolls_back(self):
        for event in ['stage-created','staged-file:NeSpat.app/Contents/helper','staged-file:profile.json','prepared','before-base','renamed-base','after-base','before-plist','renamed-plist','after-plist','before-bootstrap','after-bootstrap','committed']:
            with self.subTest(event=event):
                def fail(x):
                    if x==event:raise RuntimeError(x)
                t=self.tx(fail)
                with self.assertRaises(RuntimeError):t.install(self.files,self.manifest,lambda:True)
                self.assert_clean();t.journal.unlink()
    def test_crash_every_stage_new_process_can_rollback(self):
        for event in ['reserved','stage-created','staged-file:NeSpat.app/Contents/helper','staged-file:profile.json','prepared','before-base','renamed-base','after-base','before-plist','renamed-plist','after-plist','before-bootstrap','after-bootstrap','committed']:
            with self.subTest(event=event):
                def fail(x):
                    if x==event:raise Crash(x)
                with self.assertRaises(Crash):self.tx(fail).install(self.files,self.manifest,lambda:True)
                self.tx().rollback();self.assert_clean();(self.root/'transaction.json').unlink()
    def test_crash_during_rollback_restarts(self):
        for event in ['service-stopped','removed-plist','removed-base','rolled-back']:
            with self.subTest(event=event):
                t=self.tx();t.install(self.files,self.manifest,lambda:True)
                def fail(x):
                    if x==event:raise Crash(x)
                t.fault=fail
                with self.assertRaises(Crash):t.rollback()
                self.tx().rollback();self.assert_clean();t.journal.unlink()
    def test_bootstrap_partial_success_rolled_back(self):
        self.s.fail=True
        with self.assertRaises(RuntimeError):self.tx().install(self.files,self.manifest,lambda:True)
        self.assert_clean()
    def test_foreign_destination_never_removed(self):
        (self.root/'base').mkdir();(self.root/'base/foreign').write_text('retain')
        with self.assertRaises(m.Stop):self.tx().install(self.files,self.manifest,lambda:True)
        self.assertEqual((self.root/'base/foreign').read_text(),'retain')
    def test_changed_installed_files_block_removal(self):
        t=self.tx();t.install(self.files,self.manifest,lambda:True)
        (t.base/'foreign').write_text('retain')
        with self.assertRaises(m.Stop):self.tx().rollback()
        self.assertTrue(self.s.on);self.assertTrue((t.base/'foreign').exists())
    def test_unknown_journal_and_link_fail_closed(self):
        t=self.tx();t.journal.write_text('{}');t.journal.chmod(0o600)
        with self.assertRaises(m.Stop):self.tx().rollback()
        t.journal.unlink();t.journal.symlink_to(self.root/'foreign')
        with self.assertRaises((m.Stop,FileNotFoundError)):self.tx().rollback()
    def test_bad_zip_rejected_without_writes(self):
        for n in ['../escape','/absolute','unknown']:
            b=io.BytesIO()
            with zipfile.ZipFile(b,'w') as z:z.writestr(n,b'x')
            data=b.getvalue()
            with self.assertRaises((m.Stop,KeyError)):m.package(data,m.SHA(data))
        self.assertEqual(list(self.root.iterdir()),[])
    def test_corrupt_hash_rejected(self):
        with self.assertRaises(m.Stop):m.package(b'unknown','0'*64)

    def test_reinstall_after_resumed_rollback_preserves_history(self):
        t=self.tx();t.install(self.files,self.manifest,lambda:True);t.rollback()
        self.tx().install(self.files,self.manifest,lambda:True)
        self.assertEqual(len(list(self.root.glob('transaction.json.completed-*'))),1)
        self.tx().rollback();self.assert_clean()
    def test_failed_stage_verification_never_publishes(self):
        def fail(_):raise m.Stop('Bad staged signature')
        self.s.verify=fail
        with self.assertRaises(m.Stop):self.tx().install(self.files,self.manifest,lambda:True)
        self.assert_clean()
    def test_failed_bootout_preserves_files_for_retry(self):
        t=self.tx();t.install(self.files,self.manifest,lambda:True)
        self.s.bootout=lambda:None
        with self.assertRaises(m.Stop):self.tx().rollback()
        self.assertTrue(t.base.exists() and t.plist.exists())
    def test_directory_transaction_lock_supported_rootless(self):
        import fcntl
        fd=os.open(self.root,os.O_RDONLY|os.O_DIRECTORY)
        try:fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
        finally:os.close(fd)

    def test_crash_inside_recursive_removal_resumes_without_deleting_foreign(self):
        t=self.tx();t.install(self.files,self.manifest,lambda:True)
        def fail(x):
            if x.startswith('removed-child:'):raise Crash(x)
        t.fault=fail
        with self.assertRaises(Crash):t.rollback()
        self.tx().rollback();self.assert_clean()
    def test_injected_file_write_failure_is_rolled_back(self):
        from unittest.mock import patch
        original=Path.write_bytes
        def fail(p,data):
            if p.name=='helper':raise OSError('ENOSPC mock')
            return original(p,data)
        with patch.object(Path,'write_bytes',fail):
            with self.assertRaises(OSError):self.tx().install(self.files,self.manifest,lambda:True)
        self.assert_clean()

    def test_complete_signed_package_roundtrip_and_extra_file_rejection(self):
        names=['NeSpat.app/Contents/Info.plist','NeSpat.app/Contents/_CodeSignature/CodeResources','NeSpat.app/Contents/MacOS/NeSpat','NeSpat.app/Contents/Library/Helpers/NeSpatPrivilegeHelper','NeSpat.app/Contents/Resources/AppIcon.icns']
        data={n:b'signed-fixture' for n in names}
        data['profile.json']=json.dumps({'acceptanceOnly':True,'enabled':False,'version':1,'allowedUID':501,'setup':'12345678-1234-1234-1234-123456789012'}).encode()
        manifest={'mode':'acceptance-only','files':{n:{'sha256':m.SHA(b),'mode':0o755 if '/MacOS/' in n or '/Helpers/' in n else 0o644} for n,b in data.items()}}
        def archive(extra=False):
            stream=io.BytesIO()
            with zipfile.ZipFile(stream,'w') as z:
                for n,b in data.items():z.writestr(n,b)
                z.writestr('acceptance-manifest.json',json.dumps(manifest))
                if extra:z.writestr('unexpected',b'no')
            return stream.getvalue()
        b=archive();self.assertEqual(m.package(b,m.SHA(b))[0],data)
        b=archive(True)
        with self.assertRaises(m.Stop):m.package(b,m.SHA(b))

class PreinstallProbeTests(unittest.TestCase):
    def setUp(self):
        from unittest.mock import patch
        import subprocess,plistlib
        self.tmp=tempfile.TemporaryDirectory();self.root=Path(self.tmp.name)
        self.patches=[];self.sleep=False;self.service_conflict=False;self.unknown_service=False;self.running=False
        self.signature_bad=False;self.owner_bad=False
        def security(*_):
            if self.owner_bad:raise m.Stop('owner/permissions/ACL unknown')
        def signatures(*_):
            if self.signature_bad:raise m.Stop('pin invalid')
        def run(args,**kwargs):
            if args[0]=='/usr/bin/pgrep':return subprocess.CompletedProcess(args,0 if self.running else 1,'','')
            if args[:2]==['/bin/launchctl','print']:
                return subprocess.CompletedProcess(args,0 if self.service_conflict else 1 if self.unknown_service else 113,'','Could not find service' if not self.unknown_service else 'not permitted')
            raise AssertionError('Unexpected subprocess '+repr(args))
        def checked(args):
            self.assertEqual(args,['/usr/sbin/ioreg','-a','-r','-c','IOPMrootDomain'])
            return subprocess.CompletedProcess(args,0,plistlib.dumps([{} if self.sleep is None else {'SleepDisabled':self.sleep}]).decode(),'')
        original=Path.iterdir
        def dirs(p):return iter([]) if str(p)=='/Users' else original(p)
        for target,value in [('BASE',self.root/'base'),('PLIST',self.root/'daemon.plist'),('JOURNAL',self.root/'journal'),('secure',security),('signatures',signatures),('checked_run',checked)]:
            p=patch.object(m,target,value);p.start();self.patches.append(p)
        for p in [patch.object(m.subprocess,'run',run),patch.object(Path,'iterdir',dirs)]:p.start();self.patches.append(p)
    def tearDown(self):
        for p in reversed(self.patches):p.stop()
        self.tmp.cleanup()
    def probe(self):return m.system_probe(self.root,{'allowedUID':501})
    def test_fresh_install_probe_needs_no_profile_lock_or_service(self):
        self.assertTrue(self.probe());self.assertEqual(list(self.root.iterdir()),[])
    def test_unknown_or_disabled_sleep_stops(self):
        for value in [True,0,1,'No',None]:
            self.sleep=value
            with self.assertRaises(m.Stop):self.probe()
    def test_service_conflict_and_unknown_stops(self):
        self.service_conflict=True
        with self.assertRaises(m.Stop):self.probe()
        self.service_conflict=False;self.unknown_service=True
        with self.assertRaises(m.Stop):self.probe()
    def test_running_gui_stops(self):
        self.running=True
        with self.assertRaises(m.Stop):self.probe()
    def test_owners_permissions_acl_and_pin_failures_stop(self):
        self.owner_bad=True
        with self.assertRaises(m.Stop):self.probe()
        self.owner_bad=False;self.signature_bad=True
        with self.assertRaises(m.Stop):self.probe()
    def test_existing_transaction_stops(self):
        m.JOURNAL.write_text('{"version":1,"mode":"acceptance-only","phase":"preparing"}')
        with self.assertRaises(m.Stop):self.probe()
    def test_existing_destination_stops(self):
        m.BASE.mkdir()
        with self.assertRaises(m.Stop):self.probe()
