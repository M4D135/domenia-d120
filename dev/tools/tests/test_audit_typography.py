"""Typographic scale and named spacing (point 112). Offline, read-only on the repository.

Usage: python3 -m unittest discover -s dev/tools/tests -q
"""
import json
from pathlib import Path
import sys
import unittest
import tempfile

DEV = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(DEV / 'tools'))
import audit_typography as at


class TypographyRulesTests(unittest.TestCase):
    def test_literal_sizes_are_counted_per_function_and_code_assignments_too(self):
        text = ('function Get-A {\n    @"\n<TextBlock FontSize="12"/><TextBlock FontSize="{DynamicResource FontSizeBody}"/>\n"@\n}\n'
                'function Set-B {\n    $t.FontSize=15\n    $t.SetResourceReference([Windows.Controls.TextBlock]::FontSizeProperty,\'FontSizeTitle\')\n}\n')
        counts = at.owner_counts(text, at.LITERAL_FONT)
        self.assertEqual(counts, {'Get-A': 1, 'Set-B': 1})

    def test_size_references_name_the_scale(self):
        keys = [m.group(1) or m.group(2) for m in at.FONT_KEY.finditer(
            'FontSize="{DynamicResource FontSizeSmall}" X.SetResourceReference([Windows.Controls.Control]::FontSizeProperty,\'FontSizeHuge\')')]
        self.assertEqual(keys, ['FontSizeSmall', 'FontSizeHuge'])
        self.assertNotIn('FontSizeHuge', at.SCALE)
        self.assertEqual(len(at.SCALE), 8, 'huit tailles nommées')

    def test_ratchet_reports_increases_and_reductions(self):
        baseline = {'FontSizeLiterals': {'a.ps1|F': 2}, 'SpacingLiterals': {'v.xaml': 5}}
        increased, fixed = at.compare({'a.ps1|F': 3}, {'v.xaml': 4}, baseline)
        self.assertEqual(len(increased), 1)
        self.assertEqual(fixed, ['v.xaml'])
        increased, _ = at.compare({'b.ps1|G': 1}, {}, baseline)
        self.assertEqual(len(increased), 1, 'un nouveau fichier ne passe pas sans référence')


    def test_main_xaml_reader_uses_supplied_root_without_fallback(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'wad').mkdir()
            path = root / 'wad/Domenia-Main.xaml'
            path.write_text('temporary view', encoding='utf-8')
            self.assertEqual(at.main_xaml(root), 'temporary view')
            path.unlink()
            with self.assertRaises(FileNotFoundError):
                at.main_xaml(root)

    def test_external_page_and_tree_template_literal_fonts_are_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'wad/modules').mkdir(parents=True)
            xaml = at.main_xaml(DEV).replace('<Window ', '<Window FontSize="12" ', 1)
            self.assertNotEqual(xaml, at.main_xaml(DEV))
            (root / 'wad/Domenia-Main.xaml').write_text(xaml, encoding='utf-8')
            (root / 'wad/Domenia-Core.ps1').write_text('function Get-DomeniaTreeHeaderTemplate {\n\'<TextBlock FontSize="12"/>\'\n}', encoding='utf-8')
            (root / 'wad/modules/SupportSuite.UI.json').write_bytes((DEV / 'wad/modules/SupportSuite.UI.json').read_bytes())
            problems, fonts, spacing = at.collect(root)
            self.assertTrue(any('Domenia-Main.xaml' in p for p in problems))
            self.assertTrue(any('Get-DomeniaTreeHeaderTemplate' in p for p in problems))
            self.assertEqual(fonts['wad/Domenia-Main.xaml|'], 1)
            self.assertIn('wad/Domenia-Main.xaml', spacing)


class RepositoryTypographyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.problems, cls.fonts, cls.spacing = at.collect()
        cls.baseline = json.loads((DEV / 'tools' / 'baselines' / 'typography-baseline.json').read_text(encoding='utf-8'))

    def test_page_and_views_use_only_the_named_sizes(self):
        self.assertEqual(self.problems, [])
        for function in at.PAGE_FUNCTIONS:
            self.assertNotIn('wad/Domenia-Core.ps1|' + function, self.fonts)
        self.assertFalse([k for k in self.fonts if k.endswith('.xaml|')])

    def test_no_literal_above_the_reviewed_reference(self):
        increased, _fixed = at.compare(self.fonts, self.spacing, self.baseline)
        self.assertEqual(increased, [])


if __name__ == '__main__':
    unittest.main(verbosity=2)
