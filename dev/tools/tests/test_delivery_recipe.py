"""Delivery acceptance rules (point 150) on temporary build folders and lab runs. Offline.

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
import delivery_recipe as dr


def sha(data):
    return hashlib.sha256(data).hexdigest()


class RecipeAndIssuesTests(unittest.TestCase):
    def test_shipped_recipe_is_complete_and_documents_support_and_rollback(self):
        recipe = dr.read_json(dr.RECIPE)
        self.assertEqual(dr.validate_recipe(recipe), [])
        self.assertEqual(sorted(c['Id'] for c in recipe['Criteria']), ['R%02d' % i for i in range(1, 14)])
        self.assertTrue(all(c['Blocking'] for c in recipe['Criteria']))
        broken = copy.deepcopy(recipe)
        broken['Rollback'] = []
        self.assertTrue(any('retour arrière' in p for p in dr.validate_recipe(broken)))

    def test_shipped_register_lists_open_incidents_and_blocks_on_a_bloquant(self):
        outcome, opened = dr.check_issues(dr.read_json(dr.ISSUES))
        self.assertEqual(outcome['Status'], 'FAIL')
        self.assertIn('KI-001', outcome['Detail'])
        self.assertGreaterEqual(len(opened), 5)

    def test_incomplete_incident_fails_and_minor_ones_pass(self):
        base = {'Schema': 'DomeniaKnownIssues/1', 'Issues': [
            {'Id': 'KI-001', 'Title': 'T', 'Severity': 'Mineur', 'Status': 'Ouvert', 'Impact': 'I', 'Workaround': 'W', 'Source': 'S'},
            {'Id': 'KI-002', 'Title': 'T', 'Severity': 'Bloquant', 'Status': 'Résolu', 'Impact': 'I', 'Workaround': 'W', 'Source': 'S'}]}
        outcome, opened = dr.check_issues(base)
        self.assertEqual(outcome['Status'], 'PASS')
        self.assertEqual([i['Id'] for i in opened], ['KI-001'])
        bad = copy.deepcopy(base)
        bad['Issues'][0]['Workaround'] = ''
        self.assertIn('Workaround manquant', dr.check_issues(bad)[0]['Detail'])
        bad = copy.deepcopy(base)
        bad['Issues'][1]['Id'] = 'KI-001'
        self.assertEqual(dr.check_issues(bad)[0]['Status'], 'FAIL')


class OutputSummaryTests(unittest.TestCase):
    def test_failed_check_is_summarised_by_its_reason(self):
        self.assertEqual(dr.summarize_output('{}\nFAILED: A x\nFAILED: B y\n', ''), 'FAILED: A x | FAILED: B y')
        text = json.dumps({'Status': 'PASS', 'Problems': [], 'Blocking': [{'Id': 'psexec'}], 'Publishable': False})
        self.assertEqual(dr.summarize_output(text, ''), 'Bloquants : psexec')
        self.assertEqual(dr.summarize_output(json.dumps({'Status': 'FAIL', 'New': ['Quotes|a.md|X']}), ''), 'New : Quotes|a.md|X')
        self.assertEqual(dr.summarize_output('a\nb\nc\nd', ''), 'b | c | d')


class BuildFolderTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.out = Path(self.temporary.name)
        prod, dev = b'zip prod', b'zip dev'
        (self.out / 'P.zip').write_bytes(prod)
        (self.out / 'D.zip').write_bytes(dev)
        self.report = {'Build': 'B', 'IdenticalRuntimeFiles': 120,
                       'prod': {'Archive': 'P.zip', 'Sha256': sha(prod).upper(), 'Files': 120, 'ZipIntegrity': True, 'ManifestValid': True},
                       'dev': {'Archive': 'D.zip', 'Sha256': sha(dev).upper(), 'Files': 480, 'ZipIntegrity': True, 'ManifestValid': True},
                       'Environment': {'Commit': 'a' * 40, 'Dirty': False}}
        self.write()

    def tearDown(self):
        self.temporary.cleanup()

    def write(self):
        (self.out / 'build-report.json').write_text(json.dumps(self.report), encoding='utf-8')
        lines = [sha((self.out / n).read_bytes()) + '  ' + n for n in ('D.zip', 'P.zip', 'build-report.json')]
        (self.out / 'SHA256SUMS').write_text('\n'.join(lines) + '\n', encoding='utf-8')

    def test_valid_folder_passes(self):
        self.assertEqual(dr.check_build(self.out)['Status'], 'PASS')

    def test_tampered_archive_fails(self):
        (self.out / 'P.zip').write_bytes(b'changed')
        self.assertIn('SHA-256', dr.check_build(self.out)['Detail'])

    def test_dirty_tree_fails(self):
        self.report['Environment']['Dirty'] = True
        self.write()
        self.assertIn('commit propre', dr.check_build(self.out)['Detail'])

    def test_runtime_not_compared_fails(self):
        self.report['IdenticalRuntimeFiles'] = 0
        self.write()
        self.assertIn('identique', dr.check_build(self.out)['Detail'])

    def test_second_build_must_give_identical_archives(self):
        self.assertEqual(dr.check_rebuild(self.out, None)['Status'], 'NON_MESURE')
        with tempfile.TemporaryDirectory() as other:
            other = Path(other)
            for name in ('P.zip', 'D.zip', 'build-report.json', 'SHA256SUMS'):
                (other / name).write_bytes((self.out / name).read_bytes())
            self.assertEqual(dr.check_rebuild(self.out, other)['Status'], 'PASS')
            (other / 'P.zip').write_bytes(b'other bytes')
            lines = [hashlib.sha256((other / n).read_bytes()).hexdigest() + '  ' + n for n in ('D.zip', 'P.zip')]
            (other / 'SHA256SUMS').write_text('\n'.join(lines) + '\n', encoding='utf-8')
            self.assertIn('P.zip', dr.check_rebuild(self.out, other)['Detail'])

    def test_missing_report_is_not_measured(self):
        (self.out / 'build-report.json').unlink()
        self.assertEqual(dr.check_build(self.out)['Status'], 'NON_MESURE')
        self.assertEqual(dr.check_windows(self.out, None)['Status'], 'NON_MESURE')


class LabRunTests(unittest.TestCase):
    def run_dir(self, root, name, suites):
        folder = Path(root) / name
        folder.mkdir()
        for suite, (tests, code) in suites.items():
            (folder / (suite + '.ps1.json')).write_text(json.dumps({'Tests': [{'Name': n, 'Status': s} for n, s in tests.items()]}), encoding='utf-8')
            (folder / (suite + '.ps1.json.exit')).write_text(str(code), encoding='utf-8')
        return folder

    def test_regressions_and_scale_suites(self):
        with tempfile.TemporaryDirectory() as root:
            old = self.run_dir(root, 'old', {'Test-DomeniaA': ({'a': 'Passed', 'b': 'Failed'}, 1)})
            same = self.run_dir(root, 'same', {'Test-DomeniaA': ({'a': 'Passed', 'b': 'Passed'}, 0)})
            worse = self.run_dir(root, 'worse', {'Test-DomeniaA': ({'a': 'Failed', 'b': 'Passed'}, 1)})
            self.assertEqual(dr.check_regressions(old, same)['Status'], 'PASS')
            self.assertIn('Test-DomeniaA :: a', dr.check_regressions(old, worse)['Detail'])
            self.assertEqual(dr.check_regressions(None, same)['Status'], 'NON_MESURE')
            criterion = {'Suites': ['Test-DomeniaScale']}
            scale = self.run_dir(root, 'scale', {'Test-DomeniaScale': ({'10000 postes': 'Passed'}, 0)})
            self.assertEqual(dr.check_scale(criterion, scale)['Status'], 'PASS')
            self.assertEqual(dr.check_scale(criterion, same)['Status'], 'FAIL')
            self.assertEqual(dr.check_scale(criterion, None)['Status'], 'NON_MESURE')


class HotspotCriterionTests(unittest.TestCase):
    def test_hot_spots_need_the_campaign_reports(self):
        self.assertEqual(dr.check_hotspots(None)['Status'], 'NON_MESURE')
        with tempfile.TemporaryDirectory() as run:
            run = Path(run)
            (run / 'Test-DomeniaHotspots.ps1.json').write_text(json.dumps({'Failed': 0, 'Hotspots': [
                {'Id': 'observation-decode', 'PowerShellMs': 9000, 'CompiledMs': 300, 'Units': 2000, 'Parity': True},
                {'Id': 'probe-aggregation', 'PowerShellMs': 4000, 'CompiledMs': 500, 'Units': 2000, 'Parity': True},
                {'Id': 'probe-selection', 'PowerShellMs': 2500, 'CompiledMs': 200, 'Units': 2000, 'Parity': True}]}), encoding='utf-8')
            self.assertEqual(dr.check_hotspots(run)['Status'], 'NON_MESURE', 'le moteur de requête attend sa suite d’échelle')
            (run / 'Test-DomeniaQueryScale.ps1.json').write_text(json.dumps({'Status': 'PASS', 'Records': 20000, 'ElapsedSeconds': 3.5}), encoding='utf-8')
            self.assertEqual(dr.check_hotspots(run)['Status'], 'PASS')
            (run / 'Test-DomeniaHotspots.ps1.json').write_text(json.dumps({'Failed': 0, 'Hotspots': [
                {'Id': 'observation-decode', 'PowerShellMs': 400, 'CompiledMs': 300, 'Units': 2000, 'Parity': True},
                {'Id': 'probe-aggregation', 'PowerShellMs': 4000, 'CompiledMs': 500, 'Units': 2000, 'Parity': True},
                {'Id': 'probe-selection', 'PowerShellMs': 2500, 'CompiledMs': 200, 'Units': 2000, 'Parity': True}]}), encoding='utf-8')
            outcome = dr.check_hotspots(run)
            self.assertEqual(outcome['Status'], 'FAIL')
            self.assertIn('observation-reader', outcome['Detail'])
            # A failed case of the measuring suite (a parity check that threw) refuses every hot spot it measured.
            (run / 'Test-DomeniaHotspots.ps1.json').write_text(json.dumps({'Failed': 1, 'Hotspots': [
                {'Id': 'observation-decode', 'PowerShellMs': 9000, 'CompiledMs': 300, 'Units': 2000, 'Parity': True},
                {'Id': 'probe-aggregation', 'PowerShellMs': 4000, 'CompiledMs': 500, 'Units': 2000, 'Parity': True},
                {'Id': 'probe-selection', 'PowerShellMs': 2500, 'CompiledMs': 200, 'Units': 2000, 'Parity': True}]}), encoding='utf-8')
            self.assertEqual(dr.check_hotspots(run)['Status'], 'FAIL')


class VerdictTests(unittest.TestCase):
    def test_unmeasured_blocking_criterion_never_delivers_and_report_shows_it(self):
        recipe = dr.read_json(dr.RECIPE)
        results = {c['Id']: dr.result('PASS', 'ok') for c in recipe['Criteria']}
        self.assertEqual(dr.verdict(recipe, results), ('Livrable', []))
        results['R08'] = dr.result('NON_MESURE', 'Aucun rapport')
        decision, reasons = dr.verdict(recipe, results)
        self.assertEqual(decision, 'Non livrable')
        self.assertTrue(reasons[0].startswith('R08 non mesuré'))
        issues = [{'Id': 'KI-009', 'Title': 'T', 'Severity': 'Mineur', 'Impact': 'I', 'Workaround': 'W'}]
        text = dr.render(recipe, results, decision, reasons, issues, 'B')
        for needle in ('Verdict : **Non livrable**', 'Non mesuré', 'KI-009', '## Support', '## Retour arrière', '-RestoreLatest'):
            self.assertIn(needle, text)
        with self.assertRaises(ValueError):
            dr.result('PEUT-ETRE', 'x')


if __name__ == '__main__':
    unittest.main(verbosity=2)
