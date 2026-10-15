"""Compiled code limited to measured hot spots (point 132). Offline, read-only on the repository.

Usage: python3 -m unittest discover -s dev/tools/tests -q
"""
import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest

DEV = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(DEV / 'tools'))
import compiled_code as cc


class RegisterTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.register = json.loads((DEV / 'tools' / 'compiled-code.json').read_text(encoding='utf-8'))

    def test_every_compiled_site_of_the_repository_is_registered(self):
        problems, units = cc.validate(self.register)
        self.assertEqual(problems, [])
        sources, binaries, inline = cc.scan_sites()
        self.assertIn('native/ObservationReader.cs', sources)
        self.assertIn('wad/modules/Domenia.Native.dll', binaries)
        self.assertIn('wad/Domenia-Core.ps1:Get-DomeniaNetUseSource', inline)
        self.assertIn('wad/Domenia-Core.ps1:Initialize-DomeniaWinSqliteNative', inline)

    def test_unregistered_source_binary_or_interop_fails(self):
        sites = ({'native/ObservationReader.cs', 'native/Nouveau.cs'}, {'wad/modules/Autre.dll'}, {'wad/modules/X.UI.ps1:Get-X'})
        problems, _ = cc.validate(self.register, DEV, sites)
        self.assertTrue(any('native/Nouveau.cs' in p for p in problems))
        self.assertTrue(any('wad/modules/Autre.dll' in p for p in problems))
        self.assertTrue(any('X.UI.ps1:Get-X' in p for p in problems))

    def test_incomplete_units_are_refused(self):
        broken = copy.deepcopy(self.register)
        hot = [u for u in broken['Units'] if u['Id'] == 'observation-reader'][0]
        hot['Measure'] = {'Suite': 'Test-DomeniaInexistant', 'Comparison': 'Intuition'}
        interop = [u for u in broken['Units'] if u['Kind'] == 'Interop'][0]
        interop['Api'] = ''
        broken['Units'].append(copy.deepcopy(broken['Units'][0]))
        problems, _ = cc.validate(broken)
        text = ' | '.join(problems)
        for needle in ('suite de mesure absente', 'mesure incomplète', 'interface Windows (Api) manquante', 'en double'):
            self.assertIn(needle, text)


class DecisionTests(unittest.TestCase):
    def setUp(self):
        self.register = {'MinimumGain': 2.0, 'Units': [
            {'Id': 'a', 'Kind': 'PointChaud', 'Measure': {'Suite': 'S', 'Hotspot': 'h-a', 'Comparison': 'PowerShell', 'Metrics': ['PowerShellMs', 'CompiledMs']}},
            {'Id': 'b', 'Kind': 'PointChaud', 'Measure': {'Suite': 'Q', 'Hotspot': 'h-b', 'Comparison': 'Budget', 'Metrics': ['Records', 'ElapsedSeconds']}},
            {'Id': 'c', 'Kind': 'Interop'}]}

    def decisions(self, reports):
        return {d['Id']: d['Decision'] for d in cc.decide(self.register, reports)}

    def test_without_measure_nothing_is_justified(self):
        self.assertEqual(self.decisions(None), {'a': 'Mesure à produire', 'b': 'Mesure à produire', 'c': 'Hors mesure (Interop)'})

    def test_gain_and_parity_decide(self):
        fast = {'Hotspots': [{'Id': 'h-a', 'PowerShellMs': 900, 'CompiledMs': 100, 'Units': 2000, 'Parity': True}]}
        self.assertEqual(self.decisions([fast])['a'], 'Justifié')
        slow = {'Hotspots': [{'Id': 'h-a', 'PowerShellMs': 150, 'CompiledMs': 100, 'Units': 2000, 'Parity': True}]}
        self.assertEqual(self.decisions([slow])['a'], 'Non justifié')
        different = {'Hotspots': [{'Id': 'h-a', 'PowerShellMs': 900, 'CompiledMs': 100, 'Units': 2000, 'Parity': False}]}
        self.assertEqual(self.decisions([different])['a'], 'Non justifié')

    def test_budget_unit_records_the_scale_report(self):
        scale = {'Status': 'PASS', 'Records': 20000, 'ElapsedSeconds': 3.2}
        self.assertEqual(self.decisions([scale])['b'], 'Budget mesuré')


if __name__ == '__main__':
    unittest.main(verbosity=2)
