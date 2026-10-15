"""Read-only worker recipe guard, exercised on disposable source copies."""
from contextlib import contextmanager
from pathlib import Path
import json
import re
import shutil
import sys
import tempfile
import unittest

DEV = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(DEV / 'tools'))
import check_worker_composition as guard


class WorkerCompositionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='domenia-composition-')
        cls.root = Path(cls.temp.name)
        (cls.root / 'wad').mkdir()
        (cls.root / 'tools').mkdir()
        shutil.copytree(DEV / 'wad/modules', cls.root / 'wad/modules')
        for rel in ['wad/Domenia-Core.ps1', 'tools/Production.Source.ps1', 'tools/operation-contracts.json']:
            shutil.copyfile(DEV / rel, cls.root / rel)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    @contextmanager
    def changed(self, rel, change):
        path = self.root / rel
        before = path.read_bytes()
        try:
            after = change(before.decode('utf-8-sig'))
            self.assertNotEqual(before.decode('utf-8-sig'), after)
            path.write_bytes((b'\xef\xbb\xbf' if before.startswith(b'\xef\xbb\xbf') else b'') + after.encode('utf-8'))
            yield
        finally:
            path.write_bytes(before)

    def rejected(self, message):
        problems = guard.check(self.root)
        self.assertTrue(any(message in p for p in problems), problems)

    def test_current_recipes(self):
        self.assertEqual([], guard.check(self.root))

    def test_runtime_module_removal(self):
        with self.changed('wad/modules/Domenia-QueryLibrary.Model.ps1',
                          lambda s: s.replace("'Domenia-ProbeCatalog.Model.ps1',", '', 1)):
            self.rejected('liste ou ordre')

    def test_catalog_injections(self):
        for rel in ['wad/modules/Domenia-QueryLibrary.Model.ps1', 'tools/Production.Source.ps1']:
            with self.subTest(rel=rel), self.changed(rel, lambda s: s.replace('.Probes)")', '.Probe)")', 1)):
                self.rejected('injection du catalogue')

    def test_prod_modules(self):
        with self.changed('tools/Production.Source.ps1',
                          lambda s: s.replace("'ProbeCatalog.Model',", '', 1)):
            self.rejected('$localStoreModules')

    def test_contract_digest(self):
        def change(s):
            rows = json.loads(s)
            row = next(r for r in rows if r['Operation'] != 'LocalStore')
            row['Sha256'] = '0' * 64
            return json.dumps(rows)
        with self.changed('tools/operation-contracts.json', change):
            self.rejected('corps, contrat et registre divergent')

    def test_duplicate_operation(self):
        with self.changed('tools/operation-contracts.json', lambda s: json.dumps(json.loads(s) + [json.loads(s)[0]])):
            self.rejected('operation dupliquee')

    def test_registry_fingerprint(self):
        with self.changed('wad/Domenia-Core.ps1', lambda s: re.sub(r'(\$expectedFingerprint\s*=\s*")[0-9A-F]{64}', r'\g<1>' + '0' * 64, s, count=1)):
            self.rejected('empreinte globale')

    def test_catalog_change(self):
        with self.changed('wad/modules/Domenia-ProbeCatalog.json', lambda s: s + ' '):
            self.rejected('LocalStore : corps, contrat et registre divergent')

    def test_crlf(self):
        with self.changed('wad/Domenia-Core.ps1', lambda s: s.replace('\n', '\r\n')), self.changed('wad/modules/Domenia-ProbeCatalog.json', lambda s: s.replace('\n', '\r\n')):
            self.assertEqual([], guard.check(self.root))

    def test_missing_root_and_restoration(self):
        before = guard.contracts.ROOT, guard.sqlite.ROOT
        self.assertTrue(guard.check(self.root / 'missing'))
        self.assertEqual(before, (guard.contracts.ROOT, guard.sqlite.ROOT))

    def test_invalid_contract_and_restoration(self):
        before = guard.contracts.ROOT, guard.sqlite.ROOT
        with self.changed('tools/operation-contracts.json', lambda s: '{'):
            self.assertTrue(guard.check(self.root))
        self.assertEqual(before, (guard.contracts.ROOT, guard.sqlite.ROOT))


if __name__ == '__main__':
    unittest.main()
