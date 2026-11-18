import fcntl
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('nespat_uninstall', REPO / 'scripts/uninstall.py')
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)


class FakeMac:
    def __init__(self):
        self.state = 'No'
        self.states = []
        self.running = False
        self.bad_signature = False
        self.signature_identifier = 'local.nespat.app'
        self.commands = []
        self.force_result = 0
        self.force_applies = True
        self.bootout_result = 0
        self.agent_loaded = False

    def __call__(self, args):
        self.commands.append(args)
        code, out, err = 0, '', ''
        if args[0] == '/usr/sbin/ioreg':
            state = self.states.pop(0) if self.states else self.state
            out = '' if state == 'unknown' else '    "SleepDisabled" = {}\n'.format(state)
        elif args[0] == '/usr/bin/pgrep':
            code = 0 if self.running else 1
        elif args[0] == '/usr/bin/codesign':
            code = 1 if self.bad_signature else 0
            err = 'Identifier={}\n'.format(self.signature_identifier)
        elif args[0] == '/usr/bin/sudo':
            code = self.force_result
            if code == 0 and self.force_applies:
                self.state = 'No'
        elif args[0] == '/bin/launchctl':
            code = self.bootout_result if args[1] == 'bootout' else (0 if self.agent_loaded else 1)
        else:
            raise AssertionError('Unexpected command: ' + repr(args))
        return subprocess.CompletedProcess(args, code, out, err)


class UninstallTests(unittest.TestCase):
    def setUp(self):
        base = REPO / '.build/uninstall-tests'
        base.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=str(base))
        self.root = Path(self.temp.name)
        self.app = self.root / 'Applications/NeSpat.app'
        self.support = self.root / 'Support/NeSpat'
        self.logs = self.root / 'Logs/NeSpat'
        self.agent = self.root / 'Agents/local.nespat.watchdog.plist'
        self.make_app(self.app)
        self.support.mkdir(parents=True)
        self.logs.mkdir(parents=True)
        self.log = self.logs / 'recovery.log'
        self.log.write_text('preserve recovery information')
        self.mac = FakeMac()
        self.locations = module.Locations((self.app,), self.support, self.logs, self.agent)
        self.uninstaller = module.Uninstaller(self.locations, self.mac)

    def tearDown(self):
        self.temp.cleanup()

    def make_app(self, app, identifier='local.nespat.app'):
        (app / 'Contents/MacOS').mkdir(parents=True)
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': identifier, 'CFBundleExecutable': 'NeSpat', 'CFBundlePackageType': 'APPL'}))
        (app / 'Contents/MacOS/NeSpat').write_text('fixture; never executed')

    def journal(self, **fields):
        (self.support / 'session.json').write_text(json.dumps(fields))

    def assert_preserved(self):
        self.assertTrue(self.app.exists())
        self.assertTrue(self.log.exists())

    def test_missing_journal_and_disabled_preserves_every_recovery_file(self):
        self.mac.state = 'Yes'
        with self.assertRaises(module.UnsafeUninstall):
            self.uninstaller.uninstall()
        self.assert_preserved()
        self.assertFalse(any(c[0] in ('/usr/bin/sudo', '/bin/launchctl') for c in self.mac.commands))

    def test_missing_journal_and_unknown_preserves_files(self):
        self.mac.state = 'unknown'
        with self.assertRaises(module.UnsafeUninstall):
            self.uninstaller.uninstall()
        self.assert_preserved()

    def test_owned_false_is_not_a_substitute_for_system_read(self):
        self.journal(owned=False)
        self.mac.state = 'Yes'
        with self.assertRaises(module.UnsafeUninstall):
            self.uninstaller.uninstall()
        self.assert_preserved()
        self.assertTrue((self.support / 'session.json').exists())

    def test_confirmed_sleep_and_identified_fixture_can_be_removed(self):
        self.uninstaller.uninstall()
        self.assertFalse(self.app.exists())
        self.assertFalse(self.support.exists())
        self.assertFalse(self.logs.exists())
        self.assertFalse(any(c[0] == '/usr/bin/sudo' for c in self.mac.commands))

    def test_active_pending_and_corrupt_journal_block_removal(self):
        for phase in ('active', 'pending'):
            self.journal(owned=True, phase=phase)
            with self.assertRaises(module.UnsafeUninstall):
                self.uninstaller.uninstall()
            self.assert_preserved()
        (self.support / 'session.json').write_text('corrupt')
        with self.assertRaises(ValueError):
            self.uninstaller.uninstall()
        self.assert_preserved()

    def test_unrelated_bundle_blocks_all_copies_before_any_deletion(self):
        other = self.root / 'Other/NeSpat.app'
        self.make_app(other, identifier='someone.else.app')
        locations = module.Locations((self.app, other), self.support, self.logs, self.agent)
        with self.assertRaises(module.UnsafeUninstall):
            module.Uninstaller(locations, self.mac).uninstall()
        self.assert_preserved()
        self.assertTrue(other.exists())

    def test_invalid_code_signature_and_identifier_are_rejected(self):
        self.mac.bad_signature = True
        with self.assertRaises(module.UnsafeUninstall):
            self.uninstaller.uninstall()
        self.mac.bad_signature = False
        self.mac.signature_identifier = 'another.app'
        with self.assertRaises(module.UnsafeUninstall):
            self.uninstaller.uninstall()
        self.assert_preserved()

    def test_app_and_journal_symlinks_are_rejected(self):
        link = self.root / 'Linked.app'
        link.symlink_to(self.app, target_is_directory=True)
        locations = module.Locations((link,), self.support, self.logs, self.agent)
        with self.assertRaises(module.UnsafeUninstall):
            module.Uninstaller(locations, self.mac).uninstall()
        external = self.root / 'external.json'
        external.write_text('{"owned":false}')
        (self.support / 'session.json').symlink_to(external)
        with self.assertRaises(module.UnsafeUninstall):
            self.uninstaller.uninstall()
        self.assert_preserved()
        self.assertTrue(external.exists())

    def test_file_owner_mismatch_is_rejected_without_chown(self):
        real_uid = os.getuid()
        from unittest.mock import patch
        with patch.object(module.os, 'getuid', return_value=real_uid + 1):
            with self.assertRaises(module.UnsafeUninstall):
                self.uninstaller.uninstall()
        self.assert_preserved()

    def test_gui_lock_excludes_uninstaller(self):
        with (self.support / 'session.lock').open('w') as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaises(module.UnsafeUninstall):
                self.uninstaller.uninstall()
        self.assert_preserved()
        self.assertEqual(self.mac.commands, [])

    def test_live_process_blocks_removal(self):
        self.mac.running = True
        with self.assertRaises(module.UnsafeUninstall):
            self.uninstaller.uninstall()
        self.assert_preserved()

    def test_changed_state_before_deletion_preserves_files(self):
        self.mac.states = ['No', 'No', 'Yes']
        with self.assertRaises(module.UnsafeUninstall):
            self.uninstaller.uninstall()
        self.assert_preserved()

    def test_ambiguous_registry_result_is_not_normal_sleep(self):
        from unittest.mock import patch
        result = subprocess.CompletedProcess([], 0, '"SleepDisabled" = No\n"SleepDisabled" = Yes\n', '')
        with patch.object(self.uninstaller, 'run', return_value=result):
            with self.assertRaises(module.UnsafeUninstall):
                self.uninstaller.require_enabled()
        self.assert_preserved()

    def test_unrelated_agent_is_preserved(self):
        self.agent.parent.mkdir(parents=True)
        self.agent.write_bytes(plistlib.dumps({'Label': 'someone.else.agent'}))
        with self.assertRaises(module.UnsafeUninstall):
            self.uninstaller.uninstall()
        self.assert_preserved()
        self.assertTrue(self.agent.exists())
        self.assertFalse(any(c[0] == '/bin/launchctl' for c in self.mac.commands))

    def test_force_failure_and_unknown_state_never_delete_recovery_files(self):
        self.mac.state = 'Yes'
        self.mac.force_result = 1
        with self.assertRaises(module.UnsafeUninstall):
            self.uninstaller.uninstall(force=True)
        self.assert_preserved()
        self.mac.commands.clear(); self.mac.state = 'unknown'
        with self.assertRaises(module.UnsafeUninstall):
            self.uninstaller.uninstall(force=True)
        self.assertFalse(any(c[0] == '/usr/bin/sudo' for c in self.mac.commands))
        self.assert_preserved()

    def test_force_success_requires_observed_normal_sleep(self):
        self.mac.state = 'Yes'
        self.uninstaller.uninstall(force=True)  # FakeMac handles sudo; no real root operation.
        self.assertFalse(self.app.exists())
        self.assertEqual(sum(c[0] == '/usr/bin/sudo' for c in self.mac.commands), 1)

    def valid_agent(self):
        self.agent.parent.mkdir(parents=True, exist_ok=True)
        self.agent.write_bytes(plistlib.dumps({
            'Label': 'local.nespat.watchdog',
            'ProgramArguments': [str(self.app / 'Contents/MacOS/NeSpat'), '--watchdog']}))

    def test_identified_agent_can_be_removed_after_all_checks(self):
        self.valid_agent()
        self.uninstaller.uninstall()
        self.assertFalse(self.agent.exists())
        self.assertFalse(self.app.exists())
        self.assertTrue(any(c[:2] == ['/bin/launchctl', 'bootout'] for c in self.mac.commands))

    def test_agent_that_cannot_stop_preserves_recovery_files(self):
        self.valid_agent()
        self.mac.bootout_result = 1
        self.mac.agent_loaded = True
        with self.assertRaises(module.UnsafeUninstall):
            self.uninstaller.uninstall()
        self.assert_preserved()
        self.assertTrue(self.agent.exists())

    def test_success_code_without_observed_restore_does_not_delete(self):
        self.mac.state = 'Yes'
        self.mac.force_applies = False
        with self.assertRaises(module.UnsafeUninstall):
            self.uninstaller.uninstall(force=True)
        self.assert_preserved()

    def test_lock_symlink_is_rejected(self):
        target = self.root / 'other.lock'
        target.write_text('do not modify')
        (self.support / 'session.lock').symlink_to(target)
        with self.assertRaises(OSError):
            self.uninstaller.uninstall()
        self.assert_preserved()
        self.assertEqual(target.read_text(), 'do not modify')

    def test_real_signature_check_rejects_unsigned_bundle_without_signing(self):
        executable = self.app / 'Contents/MacOS/NeSpat'
        shutil.copyfile('/usr/bin/true', executable)
        executable.chmod(0o755)
        # Real read-only verification only. Do not sign fixtures under v7.2 constraints.
        with self.assertRaises(module.UnsafeUninstall):
            module.Uninstaller(self.locations).verify_app(self.app)
        self.assert_preserved()


if __name__ == '__main__':
    unittest.main()
