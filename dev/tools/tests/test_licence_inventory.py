"""Licence inventory rules (point 146) on temporary trees; offline, no network.

Usage: python3 -m unittest discover -s dev/tools/tests -q
"""
import copy
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest

DEV = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(DEV / 'tools'))
import licence_inventory as li


def sha(data):
    return hashlib.sha256(data).hexdigest()


class LicenceInventoryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.repo = Path(self.temporary.name).resolve()
        self.root = self.repo / 'dev'
        files = {
            'Domenia.exe': b'MZ launcher',
            'tools/launcher/launcher.c': b'int main(void){return 0;}',
            'wad/Tiers.dll': b'MZ third party',
            'vendor/lib/src/Engine.cs': b'class Engine {}',
            'vendor/lib/LICENSE.txt': b'Permission is hereby granted',
            'wad/Domenia-Core.ps1': b'# code',
        }
        for relative, data in files.items():
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        self.members = sorted(files)
        self.inventory = {
            'Schema': li.SCHEMA, 'ReviewedOn': '2026-10-15', 'Rule': 'test',
            'Components': [
                {'Id': 'launcher', 'Name': 'Lanceur', 'Paths': ['Domenia.exe', 'tools/launcher/'], 'Delivery': 'Livre',
                 'Origin': 'Projet', 'Licence': 'Projet', 'Redistribution': 'Interne',
                 'Evidence': [{'Kind': 'Source', 'Ref': 'tools/launcher/launcher.c'}], 'Conditions': ''},
                {'Id': 'tiers', 'Name': 'Tiers', 'Paths': ['wad/Tiers.dll', 'vendor/lib/'], 'Delivery': 'Livre',
                 'Origin': 'Tiers', 'Licence': 'MIT', 'Redistribution': 'Accordee',
                 'Evidence': [{'Kind': 'LicenceText', 'Ref': 'vendor/lib/LICENSE.txt'}],
                 'Sha256': {'wad/Tiers.dll': sha(b'MZ third party')}, 'Conditions': 'Garder la notice.'},
            ]}

    def tearDown(self):
        self.temporary.cleanup()

    def run_rules(self, inventory=None, members=None):
        return li.validate(inventory or self.inventory, self.root, self.repo, self.members if members is None else members)

    def tiers(self, inventory):
        return [c for c in inventory['Components'] if c['Id'] == 'tiers'][0]

    def test_complete_inventory_passes_and_is_publishable(self):
        problems, report = self.run_rules()
        self.assertEqual(problems, [])
        self.assertTrue(report['Publishable'])
        self.assertEqual(report['Blocking'], [])

    def test_uncovered_binary_and_vendor_file_are_refused(self):
        inventory = copy.deepcopy(self.inventory)
        self.tiers(inventory)['Paths'] = ['wad/Tiers.dll']
        problems, _ = self.run_rules(inventory)
        self.assertTrue(any('vendor/lib/src/Engine.cs' in p for p in problems), problems)
        problems, _ = self.run_rules(members=self.members + ['wad/Nouveau.dll'])
        self.assertTrue(any('Fichier sans entree de licence : wad/Nouveau.dll' in p for p in problems), problems)

    def test_stale_path_and_double_coverage_are_refused(self):
        inventory = copy.deepcopy(self.inventory)
        inventory['Components'][0]['Paths'].append('wad/Disparu.dll')
        inventory['Components'][0]['Paths'].append('wad/Tiers.dll')
        problems, _ = self.run_rules(inventory)
        self.assertTrue(any('chemin absent' in p and 'wad/Disparu.dll' in p for p in problems), problems)
        self.assertTrue(any('plusieurs entrees' in p and 'wad/Tiers.dll' in p for p in problems), problems)

    def test_github_repository_alone_never_grants_redistribution(self):
        inventory = copy.deepcopy(self.inventory)
        self.tiers(inventory)['Evidence'] = [{'Kind': 'Depot', 'Ref': 'https://github.com/exemple/lib'}]
        problems, _ = self.run_rules(inventory)
        self.assertTrue(any('une source GitHub accessible ne suffit pas' in p for p in problems), problems)

    def test_terms_need_a_review_date_and_licence_text_must_exist(self):
        inventory = copy.deepcopy(self.inventory)
        self.tiers(inventory)['Evidence'] = [{'Kind': 'Terms', 'Ref': 'Conditions de l editeur'}]
        problems, _ = self.run_rules(inventory)
        self.assertTrue(any('ReviewedOn' in p for p in problems), problems)
        self.tiers(inventory)['Evidence'] = [{'Kind': 'Terms', 'Ref': 'Conditions de l editeur', 'ReviewedOn': '2026-10-15'}]
        self.assertEqual(self.run_rules(inventory)[0], [])
        self.tiers(inventory)['Evidence'] = [{'Kind': 'LicenceText', 'Ref': 'vendor/lib/ABSENT.txt'}]
        problems, _ = self.run_rules(inventory)
        self.assertTrue(any('introuvable' in p for p in problems), problems)

    def test_replaced_third_party_binary_needs_a_new_review(self):
        (self.root / 'wad/Tiers.dll').write_bytes(b'MZ other build')
        problems, _ = self.run_rules()
        self.assertTrue(any('different de celui dont la licence a ete relue' in p for p in problems), problems)
        inventory = copy.deepcopy(self.inventory)
        self.tiers(inventory)['Sha256'] = {}
        problems, _ = self.run_rules(inventory)
        self.assertTrue(any('sans empreinte relue' in p for p in problems), problems)

    def test_unestablished_redistribution_blocks_publication_with_an_alternative(self):
        inventory = copy.deepcopy(self.inventory)
        self.tiers(inventory)['Redistribution'] = 'NonEtablie'
        problems, _ = self.run_rules(inventory)
        self.assertTrue(any('alternative' in p for p in problems), problems)
        self.tiers(inventory)['Alternative'] = 'Faire deployer le composant par l organisation.'
        problems, report = self.run_rules(inventory)
        self.assertEqual(problems, [])
        self.assertFalse(report['Publishable'])
        self.assertEqual([b['Id'] for b in report['Blocking']], ['tiers'])

    def test_closed_values_and_consistency(self):
        cases = [
            ('Redistribution', 'Libre', 'Redistribution inconnue'),
            ('Delivery', 'Partiel', 'Delivery inconnu'),
            ('Origin', 'Ailleurs', 'Origin inconnu'),
        ]
        for field, value, message in cases:
            inventory = copy.deepcopy(self.inventory)
            self.tiers(inventory)[field] = value
            with self.subTest(field=field):
                self.assertTrue(any(message in p for p in self.run_rules(inventory)[0]))
        inventory = copy.deepcopy(self.inventory)
        self.tiers(inventory)['Redistribution'] = 'Interne'
        self.assertTrue(any('reserve au code du projet' in p for p in self.run_rules(inventory)[0]))
        inventory = copy.deepcopy(self.inventory)
        inventory['Components'].append({'Id': 'outil', 'Name': 'Outil', 'Paths': [], 'Delivery': 'Fabrication',
                                        'Origin': 'Tiers', 'Licence': 'MIT', 'Redistribution': 'Accordee',
                                        'Evidence': [{'Kind': 'Note', 'Ref': 'non livre'}]})
        self.assertTrue(any('SansObjet' in p for p in self.run_rules(inventory)[0]))
        inventory = copy.deepcopy(self.inventory)
        inventory['Components'].append(copy.deepcopy(inventory['Components'][0]))
        self.assertTrue(any('Composant en double : launcher' in p for p in self.run_rules(inventory)[0]))

    def test_unsafe_paths_are_refused(self):
        for bad in ('../secret.dll', '/abs/file.dll', 'C:/file.dll', 'wad\\file.dll'):
            inventory = copy.deepcopy(self.inventory)
            inventory['Components'][0]['Paths'] = ['Domenia.exe', bad]
            with self.subTest(path=bad):
                self.assertTrue(any('chemins relatifs' in p for p in self.run_rules(inventory)[0]))

    def test_guide_builder_dependencies_must_be_listed(self):
        guides = self.repo / 'guides'
        guides.mkdir()
        (guides / 'package.json').write_text(json.dumps({'dependencies': {'docx': '^9.9.0'}}), encoding='utf-8')
        problems, _ = self.run_rules()
        self.assertTrue(any('fabrication des guides sans entree : docx' in p for p in problems), problems)
        inventory = copy.deepcopy(self.inventory)
        inventory['Components'].append({'Id': 'npm-docx', 'Name': 'docx', 'Package': 'docx', 'Paths': [],
                                        'Delivery': 'Fabrication', 'Origin': 'Tiers', 'Licence': 'MIT',
                                        'Redistribution': 'SansObjet', 'Evidence': [{'Kind': 'Note', 'Ref': 'non livre'}]})
        self.assertEqual(self.run_rules(inventory)[0], [])

    def test_repository_inventory_matches_the_real_tree(self):
        problems, report = li.validate(li.load(), DEV, DEV.parent)
        self.assertEqual(problems, [])
        delivered = {c['Id'] for c in report['Components'] if c['Delivery'] == 'Livre'}
        self.assertTrue({'launcher', 'native', 'psexec', 'ad-management', 'm4d-admin-common'} <= delivered)


class ChecksumFileTests(unittest.TestCase):
    def test_sha256sums_lists_archives_and_report_in_sha256sum_format(self):
        sys.path.insert(0, str(DEV / 'tools'))
        import build_packages
        with tempfile.TemporaryDirectory() as temporary:
            out = Path(temporary)
            (out / 'b.zip').write_bytes(b'archive b')
            (out / 'a.zip').write_bytes(b'archive a')
            lines = build_packages.write_checksums(out, ['b.zip', 'a.zip'])
            raw = (out / 'SHA256SUMS').read_bytes()
            self.assertNotIn(b'\r', raw)
            self.assertEqual(raw.decode('utf-8'), sha(b'archive a') + '  a.zip\n' + sha(b'archive b') + '  b.zip\n')
            self.assertEqual(lines[0], sha(b'archive a') + '  a.zip')


if __name__ == '__main__':
    unittest.main(verbosity=2)
