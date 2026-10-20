import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

MODULE = Path(__file__).resolve().parents[1] / 'scripts/harvis_version_catalog.py'
spec = importlib.util.spec_from_file_location('catalog', MODULE)
catalog = importlib.util.module_from_spec(spec)
spec.loader.exec_module(catalog)

class CatalogTests(unittest.TestCase):
    def test_missing_source_is_not_empty_success(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = catalog.collect({'githubSnapshot': tmp + '/offline.json', 'applicationRoots': []}, tmp)
            self.assertTrue(result['warnings'])
            self.assertEqual(result['items'][0]['installedVersion'], None)

    def test_versions_declarations_and_running_are_distinct(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'snapshot.json'
            path.write_text(json.dumps({'generatedAt': '2020-01-01T00:00:00Z', 'repositories': [], 'plugins': [
                {'name': 'example', 'version': '2.0', 'sources': [{'path': '/example', 'version': '2.0'}],
                 'installations': [{'profile': 'web', 'version': '1.0', 'packagePresent': True},
                                   {'profile': 'other', 'version': '3.0', 'packagePresent': False}]}]}))
            result = catalog.collect({'githubSnapshot': str(path), 'applicationRoots': []}, tmp)
            plugin = result['items'][1]
            self.assertEqual(plugin['sourceVersion'], '2.0')
            self.assertEqual(plugin['installedVersion'], '1.0')
            self.assertIsNone(plugin['installations'][1]['version'])
            self.assertIsNone(plugin['runningVersion'])
            self.assertIsNone(plugin['publishedVersion'])
            self.assertIn('超过 2 小时', result['warnings'][0])

    def test_app_receipt_is_not_current_process_proof(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp) / 'HarvisBar.app/Contents'
            app.mkdir(parents=True)
            (app / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleShortVersionString': '1.2.3'}))
            result = catalog.collect({'applicationRoots': [tmp]}, tmp)
            item = result['items'][1]
            self.assertEqual(item['installedVersion'], '1.2.3')
            self.assertIsNone(item['runningVersion'])

    def test_repository_urls_strip_query_and_reject_credentials(self):
        self.assertIsNone(catalog.safe_url('https://user:secret@github.com/a/b'))
        self.assertIsNone(catalog.safe_url('javascript:alert(1)'))
        self.assertEqual(catalog.safe_url('https://github.com/a/b?token=secret#x'), 'https://github.com/a/b')

    def test_cli_failure_is_reported_not_version_zero(self):
        with tempfile.TemporaryDirectory() as tmp:
            executable = Path(tmp) / 'dsh'; executable.touch()
            with patch.object(catalog.subprocess, 'run', side_effect=OSError):
                result = catalog.collect({'dshExecutable': str(executable), 'applicationRoots': []}, tmp)
            self.assertIsNone(result['items'][0]['installedVersion'])
            self.assertTrue(any('DSH' in w for w in result['warnings']))

if __name__ == '__main__':
    unittest.main()
