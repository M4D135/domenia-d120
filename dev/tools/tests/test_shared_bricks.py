#!/usr/bin/env python3
"""Point 134: the shared bricks contract (engineering/d120/contrats/briques-communes.json) must match the code.

Every listed source exists, every listed function is defined exactly once in its file, every quoted evidence is present,
a pure brick does no WPF, network or disk work, and the common query library matches its declared SHA-256.
Reads files only; no PowerShell is executed.
"""
from pathlib import Path
import hashlib, json, re, sys, unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'wad' / 'tests'))
from powershell_lex import functions  # noqa: E402

CONTRACT = ROOT / 'engineering' / 'd120' / 'contrats' / 'briques-communes.json'
IMPURE = re.compile(r'\b(?:Windows\.Controls|System\.Windows|Get-CimInstance|Invoke-WebRequest|Invoke-RestMethod|HttpClient|WebClient|TcpClient|'
                    r'DirectoryEntry|DirectorySearcher|WriteAllText|WriteAllBytes|Set-Content|Out-File|New-Item)\b')


def read(relative):
    return (ROOT / relative).read_text(encoding='utf-8-sig')


class SharedBricksContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.data = json.loads(CONTRACT.read_text(encoding='utf-8'))

    def test_schema_and_statuses(self):
        self.assertEqual(self.data['Schema'], 'Domenia.SharedBricks/1')
        statuses = set(self.data['Statuses'])
        ids = [brick['Id'] for brick in self.data['Bricks']]
        self.assertEqual(len(ids), len(set(ids)), 'identifiant de brique repete')
        for wanted in ('requetes', 'identite', 'coffre', 'journal', 'interface'):
            self.assertIn(wanted, ids, 'brique demandee absente : ' + wanted)
        for brick in self.data['Bricks']:
            self.assertIn(brick['Status'], statuses, brick['Id'])
            self.assertIn(brick['Kind'], ('Pur', 'Natif', 'Mixte', 'Donnees', 'Contrat'), brick['Id'])
            self.assertTrue(brick['Remaining'].strip(), brick['Id'])
            for product in ('Pesto', 'FilPro'):
                self.assertTrue(brick['Needs'][product].strip(), brick['Id'] + ' ' + product)

    def test_sources_functions_and_evidence_exist(self):
        for brick in self.data['Bricks']:
            for source in brick['Sources']:
                path = ROOT / source['File']
                self.assertTrue(path.is_file(), brick['Id'] + ' : ' + source['File'])
                if 'Functions' in source:
                    spans = functions(read(source['File']))
                    for name in source['Functions']:
                        self.assertEqual(len(spans.get(name, [])), 1, brick['Id'] + ' : ' + name + ' dans ' + source['File'])
                if 'Contains' in source:
                    self.assertIn(source['Contains'], read(source['File']), brick['Id'] + ' : ' + source['File'])
            for evidence in brick['Evidence']:
                self.assertIn(evidence['Contains'], read(evidence['File']), brick['Id'] + ' : preuve absente de ' + evidence['File'])

    def test_pure_bricks_do_no_ui_network_or_disk_work(self):
        for brick in self.data['Bricks']:
            if brick['Kind'] != 'Pur':
                continue
            for source in brick['Sources']:
                text = read(source['File'])
                spans = functions(text)
                for name in source.get('Functions', []):
                    start, end = spans[name][0]
                    self.assertIsNone(IMPURE.search(text[start:end]), brick['Id'] + ' : ' + name + ' n est pas pur')

    def test_query_library_hash_matches_its_declaration(self):
        declared = json.loads(read('wad/modules/Domenia-CommonLibrary.json'))
        dll = ROOT / 'wad' / 'modules' / 'M4D.Admin.Common.Query.dll'
        actual = hashlib.sha256(dll.read_bytes()).hexdigest()
        self.assertEqual(actual, declared['Files'][0]['SHA256'].lower())
        self.assertFalse(declared['RuntimeDownload'], 'telechargement a l execution')
        self.assertIn(actual, read('wad/Domenia-Modules.ps1'), 'empreinte absente du plan de types')
        requetes = [b for b in self.data['Bricks'] if b['Id'] == 'requetes'][0]
        self.assertTrue(declared['LocalModification'] and 'Reverser' in requetes['Remaining'], 'modification locale non suivie')


if __name__ == '__main__':
    unittest.main()
