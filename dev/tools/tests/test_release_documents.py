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


if __name__ == '__main__':
    unittest.main(verbosity=2)
