"""Offline checks of tools/strip_xaml_help.py (P-PF-24): help attributes of catalogued controls leave the main XAML,
the others stay, the check fails when they come back, and the real repository holds none.
Fictitious trees in temporary folders, plus a read-only check of this repository."""
import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest

DEV = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(DEV / 'tools'))
import strip_xaml_help as strip  # noqa: E402

XAML = '''<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <!-- <Button x:Name="BtnInComment" ToolTip="Commentaire"/> -->
  <StackPanel>
    <Button x:Name="BtnKnown" Content="Lire" ToolTip="Ancien texte &gt; 1" ToolTipService.ShowOnDisabled="True" AutomationProperties.Name="Lire" AutomationProperties.HelpText="Ancien texte &gt; 1"/>
    <TextBox x:Name="TxtKnown" Text="a > b" ToolTip="Saisie" AutomationProperties.HelpText="Saisie"/>
    <Button x:Name="BtnOther" Content="Autre" ToolTip="Reste dans le XAML" AutomationProperties.Name="Autre"/>
    <TextBlock Text="Sans nom" ToolTip="Reste aussi"/>
  </StackPanel>
</Window>'''


def tree(root: Path, xaml=XAML, bom=True):
    (root / 'wad/modules').mkdir(parents=True)
    (root / 'wad/Domenia-Core.ps1').write_bytes(b'\xef\xbb\xbf# Core sentinel\n')
    data = xaml.encode('utf-8')
    (root / 'wad/Domenia-Main.xaml').write_bytes((b'\xef\xbb\xbf' if bom else b'') + data)
    catalogue = [{'Name': 'BtnKnown', 'Title': 'Lire', 'Text': 'Texte du catalogue', 'Kind': 'Button'},
                 {'Name': 'TxtKnown', 'Title': 'Saisie', 'Text': 'Saisie', 'Kind': 'TextBox'}]
    (root / 'wad/modules/Domenia-UX.help.json').write_text(json.dumps(catalogue, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def run(root, *args):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        code = strip.main(['--root', str(root)] + list(args))
    return code, json.loads(out.getvalue())


class StripXamlHelp(unittest.TestCase):
    def test_check_fails_then_apply_removes_only_catalogued_attributes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            tree(root)
            code, report = run(root)
            self.assertEqual(1, code)
            self.assertEqual('FAIL', report['Status'])
            self.assertEqual(2, report['ControlsWithHelpAttributes'])
            self.assertEqual(['BtnKnown'], report['DivergedFromCatalogue'])
            self.assertEqual(['BtnOther'], report['UncataloguedWithToolTip'])
            code, report = run(root, '--apply')
            self.assertEqual(0, code)
            self.assertEqual(5, report['AttributesRemoved'])
            raw = (root / 'wad/Domenia-Main.xaml').read_bytes()
            self.assertTrue(raw.startswith(b'\xef\xbb\xbf'), 'BOM kept')
            self.assertNotIn(b'\r\n', raw, 'LF kept')
            text = raw.decode('utf-8-sig')
            self.assertIn('<Button x:Name="BtnKnown" Content="Lire" AutomationProperties.Name="Lire"/>', text)
            self.assertIn('<TextBox x:Name="TxtKnown" Text="a > b"/>', text)
            self.assertIn('<Button x:Name="BtnOther" Content="Autre" ToolTip="Reste dans le XAML" AutomationProperties.Name="Autre"/>', text)
            self.assertIn('<TextBlock Text="Sans nom" ToolTip="Reste aussi"/>', text)
            self.assertIn('<!-- <Button x:Name="BtnInComment" ToolTip="Commentaire"/> -->', text, 'comments untouched')
            self.assertTrue(text.startswith('<Window'))
            self.assertEqual((root / 'wad/Domenia-Core.ps1').read_bytes(), b'\xef\xbb\xbf# Core sentinel\n')
            code, report = run(root)
            self.assertEqual((0, 'PASS', 0), (code, report['Status'], report['ControlsWithHelpAttributes']))

    def test_check_fails_when_an_attribute_comes_back(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            tree(root, XAML.replace(' ToolTip="Ancien texte &gt; 1" ToolTipService.ShowOnDisabled="True"', '')
                 .replace(' AutomationProperties.HelpText="Ancien texte &gt; 1"', '')
                 .replace(' ToolTip="Saisie" AutomationProperties.HelpText="Saisie"', ' ToolTipService.ShowOnDisabled="True"'))
            code, report = run(root)
            self.assertEqual(1, code)
            self.assertEqual(['TxtKnown'], report['Controls'])

    def test_missing_main_xaml_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            tree(root)
            xaml_path = root / 'wad/Domenia-Main.xaml'
            xaml_path.unlink()
            with self.assertRaises(FileNotFoundError):
                strip.run(root, False)

    def test_repository_main_xaml_has_no_help_attribute_on_a_catalogued_control(self):
        summary = strip.run(DEV, False)
        self.assertEqual('PASS', summary['Status'], summary['Controls'])
        self.assertLess(summary['XamlBytesAfter'], 450000, 'Main XAML lighter than before PF-24 (590 kB)')


if __name__ == '__main__':
    unittest.main()
