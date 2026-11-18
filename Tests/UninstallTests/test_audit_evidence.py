import importlib.util
from pathlib import Path
import tempfile,unittest
from unittest.mock import patch
spec=importlib.util.spec_from_file_location('audit_evidence',Path(__file__).resolve().parents[2]/'scripts/audit_evidence.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
class AuditEvidenceTests(unittest.TestCase):
    def test_directories_unique_and_existing_logs_never_overwritten(self):
        with tempfile.TemporaryDirectory() as tmp:
            a=m.Evidence.create(tmp,'audit');b=m.Evidence.create(tmp,'audit')
            try:
                self.assertNotEqual(a.path,b.path);self.assertEqual(a.path.stat().st_mode&0o777,0o700)
                a.write('log.json',b'old')
                with self.assertRaises(FileExistsError):a.write('log.json',b'new')
                self.assertEqual((a.path/'log.json').read_bytes(),b'old')
            finally:a.close();b.close()
    def test_creation_failure_immediately_propagates(self):
        with patch.object(m.tempfile,'mkdtemp',side_effect=FileExistsError('collision')):
            with self.assertRaises(FileExistsError):m.Evidence.create('/never-written','audit')
    def test_duplicate_command_log_refuses_before_execution(self):
        with tempfile.TemporaryDirectory() as tmp:
            e=m.Evidence.create(tmp,'audit')
            try:
                e.write('cmd.json',b'old')
                with patch.object(m.subprocess,'run') as run:
                    with self.assertRaises(FileExistsError):e.run('cmd',['never-run'],tmp)
                    run.assert_not_called()
            finally:e.close()
    def test_log_path_escape_and_symlink_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            e=m.Evidence.create(tmp,'audit')
            try:
                with self.assertRaises(ValueError):e.write('../outside',b'x')
                (e.path/'link').symlink_to('/nonexistent')
                with self.assertRaises(FileExistsError):e.write('link',b'x')
            finally:e.close()
