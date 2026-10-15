"""Shipped release documents checked against the repository (points 145 and following). Offline, read-only.

Usage: python3 -m unittest discover -s dev/tools/tests -q
"""
import json
from pathlib import Path
import re
import unittest

DEV = Path(__file__).resolve().parents[2]
REPO = DEV.parent
MATRIX = DEV / 'wad' / 'modules' / 'Domenia-Compatibility.json'
STATUSES = {'Qualifie', 'Teste', 'Attendu', 'NonPrisEnCharge'}
MATCH_KEYS = {'Product', 'MinBuild', 'MaxBuild', 'Edition', 'MinVersion', 'MaxVersion', 'Bitness', 'MinRelease',
              'MaxRelease', 'Present'}


class CompatibilityMatrixTests(unittest.TestCase):
    """Point 145: the matrix shipped with the modules only claims what a report of the repository shows."""

    @classmethod
    def setUpClass(cls):
        cls.matrix = json.loads(MATRIX.read_text(encoding='utf-8-sig'))

    def entries(self):
        for dimension in self.matrix['Dimensions']:
            for entry in dimension['Entries']:
                yield dimension, entry

    def test_schema_statuses_and_unique_ids(self):
        self.assertEqual(self.matrix['Schema'], 'DomeniaCompatibilityMatrix/1')
        self.assertRegex(self.matrix['ReviewedOn'], r'^\d{4}-\d{2}-\d{2}$')
        self.assertEqual(set(self.matrix['Statuses']), STATUSES)
        dimensions = [d['Id'] for d in self.matrix['Dimensions']]
        self.assertEqual(len(dimensions), len(set(dimensions)))
        self.assertTrue({'Windows', 'PowerShell', 'DotNet', 'Sqlite', 'Directory', 'Cim'} <= set(dimensions))
        for dimension in self.matrix['Dimensions']:
            ids = [e['Id'] for e in dimension['Entries']]
            self.assertEqual(len(ids), len(set(ids)), dimension['Id'])

    def test_tested_entries_cite_an_existing_report_and_nothing_is_qualified(self):
        for dimension, entry in self.entries():
            with self.subTest(entry=entry['Id']):
                self.assertIn(entry['Status'], STATUSES)
                self.assertNotEqual(entry['Status'], 'Qualifie', 'aucun rapport Windows lie au ZIP')
                if entry['Status'] == 'Teste':
                    refs = [e['Ref'] for e in entry['Evidence'] if e.get('Ref')]
                    self.assertTrue(refs)
                    for ref in refs:
                        self.assertTrue((REPO / ref).exists(), ref)

    def test_observed_entries_have_known_conditions_and_ordered_build_ranges(self):
        for dimension, entry in self.entries():
            with self.subTest(entry=entry['Id']):
                keys = set(entry['Match'])
                self.assertTrue(keys <= MATCH_KEYS, keys - MATCH_KEYS)
                if dimension['Observed']:
                    self.assertTrue(keys)
                for low, high in (('MinBuild', 'MaxBuild'), ('MinRelease', 'MaxRelease')):
                    if low in keys and high in keys:
                        self.assertLessEqual(entry['Match'][low], entry['Match'][high])

    def test_windows_client_ranges_do_not_overlap(self):
        windows = [d for d in self.matrix['Dimensions'] if d['Id'] == 'Windows'][0]
        for product in ('Client', 'Server'):
            ranges = sorted((e['Match']['MinBuild'], e['Match']['MaxBuild']) for e in windows['Entries']
                            if e['Match'].get('Product') == product)
            for (a_low, a_high), (b_low, b_high) in zip(ranges, ranges[1:]):
                self.assertLess(a_high, b_low, (product, a_low, a_high, b_low, b_high))

    def test_no_apostrophe_or_typographic_quote_breaks_the_french_text(self):
        text = MATRIX.read_text(encoding='utf-8-sig')
        self.assertFalse(re.search('[‘’“”]', text))


class MainXamlControlTests(unittest.TestCase):
    """Named controls added by the release-engineering lot: policy entry, accessible name, tooltip equal to the help
    text and to the help catalogue entry (rules of the team, checked on the real main XAML)."""
    CONTROLS = ('LblUxAboutCompatibility', 'ExpStorageDataPolicy', 'LblStorageDataPolicy', 'DgStorageDataPolicy')

    @classmethod
    def setUpClass(cls):
        import sys
        import xml.etree.ElementTree as ET
        sys.path.insert(0, str(DEV / 'wad' / 'tests'))
        from powershell_lex import functions
        core = (DEV / 'wad' / 'Domenia-Core.ps1').read_text(encoding='utf-8-sig')
        spans = functions(core)['Get-MainXaml']
        start, end = spans[0]
        xaml = re.search(r'@"\n(.*?)\n"@', core[start:end], re.S).group(1)
        cls.root = ET.fromstring(xaml)
        cls.policy = core[core.index('$script:GuiElementPolicy = [ordered]@{'):]
        cls.policy = cls.policy[:cls.policy.index('\n}\n')]
        cls.help = {e['Name']: e for e in json.loads((DEV / 'wad' / 'modules' / 'Domenia-UX.help.json').read_text(encoding='utf-8'))}
        cls.xname = '{http://schemas.microsoft.com/winfx/2006/xaml}Name'

    def find(self, name):
        found = [e for e in self.root.iter() if e.get(self.xname) == name]
        self.assertEqual(len(found), 1, name)
        return found[0]

    def test_new_controls_are_declared_named_and_described(self):
        for name in self.CONTROLS:
            with self.subTest(control=name):
                element = self.find(name)
                self.assertIn('"%s" = "Default"' % name, self.policy)
                self.assertTrue(element.get('AutomationProperties.Name'))
                tip = element.get('ToolTip')
                if tip is not None:
                    self.assertEqual(tip, element.get('AutomationProperties.HelpText'))
                    self.assertIn(name, self.help)
                    self.assertEqual(self.help[name]['Text'], tip)
                    self.assertEqual(element.get('ToolTipService.ShowOnDisabled'), 'True')
                for value in element.attrib.values():
                    self.assertFalse(re.search('[\u2018\u2019\u201c\u201d]', value), value)


if __name__ == '__main__':
    unittest.main(verbosity=2)
