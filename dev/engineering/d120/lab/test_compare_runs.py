#!/usr/bin/env python3
"""TE-04: frozen test reference keyed by suite and test name (compare_runs.py). Synthetic reports only."""
import json, os, sys, tempfile, unittest
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import compare_runs


def write_run(folder, suites):
    os.makedirs(folder, exist_ok=True)
    for suite, (tests, exit_code) in suites.items():
        with open(os.path.join(folder, suite + '.ps1.json'), 'w', encoding='utf-8') as handle:
            json.dump({'Suite': suite, 'Tests': [{'Name': n, 'Status': s} for n, s in tests.items()]}, handle)
        if exit_code is not None:
            with open(os.path.join(folder, suite + '.ps1.json.exit'), 'w', encoding='utf-8') as handle:
                handle.write(str(exit_code))


class CompareRunsTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.TemporaryDirectory()
        self.old = os.path.join(self.root.name, 'old')
        write_run(self.old, {
            'Test-DomeniaTheme': ({'XML reel PowerShell : Light / Get-LoginXamlLegacy': 'PASS', 'Sauvegarde isolee': 'PASS'}, 0),
            'Test-DomeniaLogin': ({'Probe complet simule': 'Passed', 'Ancien cas': 'FAIL'}, 1),
        })

    def tearDown(self):
        self.root.cleanup()

    def test_freeze_keeps_every_test_by_name_and_reloads(self):
        out = os.path.join(self.root.name, 'reference.json')
        reference = compare_runs.freeze(self.old, out, 'campagne de test')
        self.assertEqual(reference['Schema'], compare_runs.SCHEMA)
        self.assertEqual(reference['Totals'], {'Passed': 3, 'Failed': 1, 'Skipped': 0, 'Suites': 2})
        reloaded = compare_runs.load(out)
        self.assertEqual(reloaded, compare_runs.load(self.old))
        lines, regress, _, _, _ = compare_runs.compare(compare_runs.load(out), compare_runs.load(self.old))
        self.assertEqual(regress, 0, lines)

    def test_unreadable_report_refuses_the_reference(self):
        with open(os.path.join(self.old, 'Test-Broken.ps1.json'), 'w', encoding='utf-8') as handle:
            handle.write('{not json')
        with self.assertRaises(SystemExit):
            compare_runs.freeze(self.old, os.path.join(self.root.name, 'reference.json'))

    def test_removed_test_is_a_regression_unless_declared_retired(self):
        new = os.path.join(self.root.name, 'new')
        write_run(new, {
            'Test-DomeniaTheme': ({'Sauvegarde isolee': 'PASS'}, 0),
            'Test-DomeniaLogin': ({'Probe complet simule': 'PASS', 'Ancien cas': 'PASS', 'SE-16 : nouveau': 'FAIL'}, 1),
        })
        lines, regress, fixed, added, retired = compare_runs.compare(compare_runs.load(self.old), compare_runs.load(new))
        self.assertEqual((regress, fixed, added, retired), (1, 1, 1, 0), lines)
        self.assertIn('NEW-FAIL Test-DomeniaLogin :: SE-16 : nouveau', lines)
        lines, regress, _, _, retired = compare_runs.compare(compare_runs.load(self.old), compare_runs.load(new), ['Test-DomeniaTheme :: * / Get-LoginXamlLegacy'])
        self.assertEqual((regress, retired), (0, 1), lines)

    def test_missing_suite_needs_every_passing_test_retired(self):
        new = os.path.join(self.root.name, 'new')
        write_run(new, {'Test-DomeniaLogin': ({'Probe complet simule': 'PASS', 'Ancien cas': 'FAIL'}, 1)})
        _, regress, _, _, _ = compare_runs.compare(compare_runs.load(self.old), compare_runs.load(new))
        self.assertEqual(regress, 1)
        _, regress, _, _, retired = compare_runs.compare(compare_runs.load(self.old), compare_runs.load(new), ['Test-DomeniaTheme :: *'])
        self.assertEqual((regress, retired), (0, 2))

    def test_command_line_exit_codes(self):
        out = os.path.join(self.root.name, 'reference.json')
        self.assertEqual(compare_runs.main(['--freeze', self.old, out, '--label', 'x']), 0)
        new = os.path.join(self.root.name, 'new')
        write_run(new, {'Test-DomeniaTheme': ({'Sauvegarde isolee': 'FAIL'}, 1)})
        self.assertEqual(compare_runs.main([out, new]), 1)
        self.assertEqual(compare_runs.main([out]), 0)
        retired = os.path.join(self.root.name, 'retired.json')
        with open(retired, 'w', encoding='utf-8') as handle:
            json.dump(['Test-DomeniaTheme :: * / Get-LoginXamlLegacy'], handle)
        write_run(new, {'Test-DomeniaTheme': ({'Sauvegarde isolee': 'PASS'}, 0), 'Test-DomeniaLogin': ({'Probe complet simule': 'PASS', 'Ancien cas': 'FAIL'}, 1)})
        self.assertEqual(compare_runs.main([out, new]), 1)
        self.assertEqual(compare_runs.main([out, new, '--retired', retired]), 0)


if __name__ == '__main__':
    unittest.main()
