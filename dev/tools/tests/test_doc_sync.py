"""Documentation and help synchronisation rules (point 149). Offline, read-only on the repository.

Usage: python3 -m unittest discover -s dev/tools/tests -q
"""
import json
from pathlib import Path
import sys
import unittest

DEV = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(DEV / 'tools'))
import doc_sync as ds


class QuoteRulesTests(unittest.TestCase):
    def setUp(self):
        self.values = {ds.normalize(v) for v in (
            'Objets AD', 'Ping', 'Inventaire rapide (≈1 min)', 'Bon état',
            'Code précédent restauré. Version avant : ', ' ; version après : ', 'Installer ces ', ' fichiers ? (O/N)',
            'Prépare le champ dans lʼonglet 1. Créer. Vous choisissez ensuite la condition.')}
        self.joined = '\n'.join(sorted(self.values))

    def found(self, quote):
        return ds.quote_found(quote, self.values, self.joined)

    def test_short_quotes_must_be_a_whole_label(self):
        self.assertTrue(self.found('Objets AD'))
        self.assertTrue(self.found('Bon état'))
        self.assertFalse(self.found('Bon etat'), 'les accents comptent')
        self.assertFalse(self.found('Créer'), 'un mot dans une phrase n’est pas un libellé')
        self.assertFalse(self.found('Base locale'))

    def test_templates_need_every_fixed_part(self):
        self.assertTrue(self.found('Installer ces N fichiers ? (O/N)'))
        self.assertTrue(self.found('Code précédent restauré. Version avant : … ; version après : …'))
        self.assertFalse(self.found('Code précédent restauré. Version initiale : …'))
        self.assertFalse(self.found('Désinstaller ces N fichiers ? (O/N)'))

    def test_apostrophes_and_spaces_are_normalised(self):
        self.assertEqual(ds.normalize('l’onglet  1'), 'lʼonglet 1')
        self.assertEqual(ds.normalize("l'onglet"), 'lʼonglet')
        self.assertEqual(ds.fold('Dégradé'), 'degrade')

    def test_proposals_give_the_current_text_of_an_unaccented_quote(self):
        self.assertEqual(ds.propose('Bon etat', self.values), ['Bon état'])

    def test_catalogue_table_cells_are_interface_texts_but_code_lines_are_not(self):
        text = "$t = @'\nfleet.disabled|Inventaire du périmètre|Comptes désactivés encore dans lʼOU|Value|Kpi|S|Détail\n" \
               "Get-Item | Where-Object { $_.Name } | Select-Object -First 1 | Sort-Object\nshort|line\n'@\n"
        cells = set(ds.table_cells(text))
        self.assertIn('Comptes désactivés encore dans lʼOU', cells)
        self.assertIn('Inventaire du périmètre', cells)
        self.assertNotIn('Where-Object { $_.Name }', cells, 'une ligne de code nʼest pas une table')
        self.assertNotIn('short', cells, 'trop peu de cellules pour une table')

    def test_ratchet_reports_new_and_fixed_gaps(self):
        gaps = {'Quotes': [{'Guide': 'a.md', 'Line': 3, 'Quote': 'X'}], 'Retired': [], 'HelpOrphans': [],
                'Guides': [], 'Figures': []}
        new, fixed = ds.compare(gaps, {'Allowed': {}})
        self.assertEqual(new, ['Quotes|a.md|X'])
        new, fixed = ds.compare({k: [] for k in gaps}, {'Allowed': {'Quotes|a.md|X': 1}})
        self.assertEqual((new, fixed), ([], ['Quotes|a.md|X']))
        moved = {'Quotes': [{'Guide': 'a.md', 'Line': 99, 'Quote': 'X'}], 'Retired': [], 'HelpOrphans': [],
                 'Guides': [], 'Figures': []}
        self.assertEqual(ds.compare(moved, {'Allowed': {'Quotes|a.md|X': 1}}), ([], []), 'le numéro de ligne ne compte pas')


class RepositorySyncTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.gaps, cls.captures, cls.quotes, cls.helps = ds.collect()
        cls.baseline = json.loads((DEV / 'tools' / 'baselines' / 'doc-sync-baseline.json').read_text(encoding='utf-8'))

    def test_no_new_gap_against_the_reviewed_baseline(self):
        new, _fixed = ds.compare(self.gaps, self.baseline)
        self.assertEqual(new, [])

    def test_no_retired_label_and_guides_describe_the_delivered_version(self):
        self.assertEqual(self.gaps['Retired'], [])
        self.assertEqual(self.gaps['Guides'], [])
        self.assertGreater(self.quotes, 500)

    def test_new_controls_of_this_lot_have_help_entries_naming_real_controls(self):
        orphans = {row['Name'] for row in self.gaps['HelpOrphans']}
        for name in ('DgStorageDataPolicy', 'BtnFirstStepConnection', 'BtnFirstStepDashboard', 'BtnObjectReread', 'BtnCompMove'):
            self.assertNotIn(name, orphans)

    def test_every_help_entry_names_a_control_of_the_pack(self):
        # W17: the eight entries of removed controls are gone; no help entry without its control is tolerated.
        self.assertEqual(self.gaps['HelpOrphans'], [])
        self.assertFalse([k for k in self.baseline['Allowed'] if k.startswith('HelpOrphans|')])


if __name__ == '__main__':
    unittest.main(verbosity=2)
