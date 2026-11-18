import unittest
from unittest.mock import patch
from pathlib import Path
import json,os,subprocess
OS_RUN=subprocess.run
import test_acceptance_install as fixtures
m=fixtures.m

class LegacyEndedPreflightTests(unittest.TestCase):
    setUpBase=fixtures.PreinstallProbeTests.setUp
    tearDown=fixtures.PreinstallProbeTests.tearDown
    probe=fixtures.PreinstallProbeTests.probe
    def setUp(self):
        self.setUpBase()
        self.home=self.root/'home';self.support=self.home/'Library/Application Support/NeSpat';self.support.mkdir(parents=True)
        self.home.chmod(0o700)
        self.file=self.support/'session.json';self.lock=self.support/'session.lock';self.lock.touch();self.lock.chmod(0o600)
        self.data={'owned':False,'pid':42,'owner':{'pid':42,'executable':'/old/NeSpat.app/Contents/MacOS/NeSpat','startSeconds':12,'startMicroseconds':2,'bootID':'12345678-1234-1234-1234-123456789012'},'originalSleepDisabled':False,'identifier':'12345678-1234-1234-1234-123456789012','lastReason':'ordinary sleep confirmed'}
        self.write(self.data)
        prior=Path.iterdir
        def homes(p):return iter([self.home]) if str(p)=='/Users' else prior(p)
        p=patch.object(Path,'iterdir',homes);p.start();self.patches.append(p)
    def write(self,data):self.file.write_text(json.dumps(data));self.file.chmod(0o600)
    def test_proven_ended_identity_format_with_actual_No_is_allowed(self):
        before=self.file.read_bytes();self.assertTrue(self.probe());self.assertEqual(self.file.read_bytes(),before)
    def test_owned_true_stops(self):
        self.data['owned']=True;self.write(self.data)
        with self.assertRaises(m.Stop):self.probe()
    def test_damaged_json_duplicate_keys_and_nonfinite_stop(self):
        for raw in ['{','{"owned":false,"owned":true}','NaN']:
            self.file.write_text(raw)
            with self.assertRaises(m.Stop):self.probe()
    def test_unknown_original_four_field_and_incomplete_stop(self):
        for value in [{'owned':False,'pid':42,'lastReason':'sleep restored'},dict(self.data,version=99),{},dict(self.data,owner=None)]:
            self.write(value)
            with self.assertRaises(m.Stop):self.probe()
    def test_wrong_types_stop(self):
        for key,value in [('owned',0),('pid',True),('originalSleepDisabled',0),('identifier',1),('lastReason',False)]:
            data=dict(self.data);data[key]=value;self.write(data)
            with self.assertRaises(m.Stop):self.probe()
        for key,value in [('pid',True),('startSeconds',-1),('startMicroseconds',1000000),('bootID','unknown'),('executable',4)]:
            data=dict(self.data);data['owner']=dict(self.data['owner'],**{key:value});self.write(data)
            with self.assertRaises(m.Stop):self.probe()
    def test_possible_unfinished_recovery_always_stops(self):
        for key,value in [('phase','pending'),('phase','active'),('until',None),('until',10),('needsAttention',True),('needsAttention',False),('retryAfter',None),('retryAfter',1),('emergencyAttempt','12345678-1234-1234-1234-123456789012'),('durationSeconds',60)]:
            self.write(dict(self.data,**{key:value}))
            with self.assertRaises(m.Stop):self.probe()
    def test_actual_sleep_Yes_or_unknown_stops(self):
        for value in [True,None,0,'No']:
            self.sleep=value
            with self.assertRaises(m.Stop):self.probe()
    def test_active_helper_or_gui_stops(self):
        self.service_conflict=True
        with self.assertRaises(m.Stop):self.probe()
        self.service_conflict=False;self.running=True
        with self.assertRaises(m.Stop):self.probe()
    def test_journal_content_change_between_checks_stops(self):
        with patch.object(m,'signatures',lambda *_:self.write(dict(self.data,owned=True))):
            with self.assertRaises(m.Stop):self.probe()
    def test_identical_bytes_replaced_inode_stops(self):
        def replace(*_):
            temp=self.support/'candidate';temp.write_bytes(self.file.read_bytes());temp.chmod(0o600);os.replace(temp,self.file)
        with patch.object(m,'signatures',replace):
            with self.assertRaises(m.Stop):self.probe()
    def test_journal_removed_or_created_between_checks_stops(self):
        with patch.object(m,'signatures',lambda *_:self.file.unlink()):
            with self.assertRaises(m.Stop):self.probe()
        self.write(self.data)
        extra=self.home/'second'
        # Initially absent journal must not become silently admissible midway through a probe.
        self.file.unlink()
        with patch.object(m,'signatures',lambda *_:self.write(self.data)):
            with self.assertRaises(m.Stop):self.probe()
    def test_symlink_hardlink_and_permissions_stop(self):
        self.file.chmod(0o644)
        with self.assertRaises(m.Stop):self.probe()
        self.file.chmod(0o600);other=self.support/'link';os.link(self.file,other)
        with self.assertRaises(m.Stop):self.probe()
        other.unlink();raw=self.file.read_bytes();self.file.unlink();other.write_bytes(raw);other.chmod(0o600);self.file.symlink_to(other)
        with self.assertRaises(m.Stop):self.probe()
    def test_missing_or_busy_lock_stops(self):
        self.lock.unlink()
        with self.assertRaises(m.Stop):self.probe()
    def test_service_appears_during_signature_check_stops(self):
        def active(*_):self.service_conflict=True
        with patch.object(m,'signatures',active):
            with self.assertRaises(m.Stop):self.probe()
    def test_busy_existing_lock_stops(self):
        import fcntl
        fd=os.open(self.lock,os.O_RDONLY)
        try:
            fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
            with self.assertRaises(m.Stop):self.probe()
        finally:os.close(fd)
    def test_lock_replaced_between_checks_stops(self):
        def replace(*_):
            candidate=self.support/'lock-candidate';candidate.touch();candidate.chmod(0o600);os.replace(candidate,self.lock)
        with patch.object(m,'signatures',replace):
            with self.assertRaises(m.Stop):self.probe()
    def test_sleep_becomes_disabled_between_checks_stops(self):
        def change(*_):self.sleep=True
        with patch.object(m,'signatures',change):
            with self.assertRaises(m.Stop):self.probe()
    def test_wrong_owner_and_unknown_ACL_stop(self):
        import types,stat
        fake=types.SimpleNamespace(st_mode=stat.S_IFREG|0o600,st_uid=os.getuid()+1,st_nlink=1)
        with patch.object(m.os,'fstat',return_value=fake):
            with self.assertRaises(m.Stop):m.legacy_metadata(0,os.getuid())
        with patch.object(m,'legacy_no_acl',side_effect=m.Stop('unknown ACL')):
            with self.assertRaises(m.Stop):self.probe()

    def test_restrictive_directory_deny_ACL_allowed_but_grants_stop(self):
        for entry,allowed in [('everyone deny delete',True),('everyone allow readattr',False)]:
            OS_RUN(['/bin/chmod','+a',entry,str(self.home)],check=True,capture_output=True)
            try:
                if allowed:self.assertTrue(self.probe())
                else:
                    with self.assertRaises(m.Stop):self.probe()
            finally:OS_RUN(['/bin/chmod','-N',str(self.home)],check=True,capture_output=True)
    def test_parent_directory_symlink_stops(self):
        library=self.home/'Library';saved=self.home/'SavedLibrary';library.rename(saved);library.symlink_to(saved,target_is_directory=True)
        with self.assertRaises(m.Stop):self.probe()
    def test_helper_running_outside_launchd_stops(self):
        original=m.subprocess.run
        def run(args,**kwargs):
            if args==['/usr/bin/pgrep','-x','NeSpatPrivilegeHelper']:return subprocess.CompletedProcess(args,0,'42\n','')
            return original(args,**kwargs)
        with patch.object(m.subprocess,'run',run):
            with self.assertRaises(m.Stop):self.probe()
