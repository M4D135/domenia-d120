import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('compare_rebuild', Path(__file__).resolve().parents[2] / 'tools/compare-rebuild.py')
compare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(compare)


class RebuildComparisonTests(unittest.TestCase):
    def pack(self, root, content=b'compiled fixture'):
        (root / 'wad').mkdir(parents=True)
        (root / 'Domenia.exe').write_bytes(content)
        (root / 'wad/package-manifest.json').write_text(json.dumps({'format': 1, 'files': [
            {'path': 'Domenia.exe', 'length': len(content), 'sha256': hashlib.sha256(content).hexdigest()}]}), encoding='utf-8')
        (root / 'wad/.lifecycle.lock').write_bytes(b'')

    def test_equal_bytes_do_not_claim_execution_or_trust(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); a, b = root / 'a', root / 'b'
            self.pack(a); self.pack(b)
            result = compare.compare(a, b)
            self.assertTrue(result['equal'])
            self.assertEqual(3, len(result['files']))
            self.assertEqual('not-run', result['windowsAcceptance'])
            self.assertEqual('not-assessed', result['publisherTrust'])

    def test_changed_missing_extra_and_lying_manifest_are_named(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); a, b = root / 'a', root / 'b'
            self.pack(a); self.pack(b, b'other build')
            (b / 'wad/extra.txt').write_text('unexpected', encoding='utf-8')
            (b / 'wad/.lifecycle.lock').unlink()
            result = compare.compare(a, b)
            self.assertFalse(result['equal'])
            rows = {r['path']: r['status'] for r in result['files']}
            self.assertEqual('different', rows['Domenia.exe'])
            self.assertEqual('added', rows['wad/extra.txt'])
            self.assertEqual('missing', rows['wad/.lifecycle.lock'])
            self.assertEqual('wad/extra.txt', result['rebuiltManifestErrors'][0]['path'])
            (b / 'Domenia.exe').write_bytes(b'altered')
            self.assertTrue(any(x['path'] == 'Domenia.exe' for x in compare.compare(a, b)['rebuiltManifestErrors']))


if __name__ == '__main__':
    unittest.main()
