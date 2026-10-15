"""Point 130: offline tests of tools/validation_matrix.py (laboratory kept apart from the real domain).
Non qualifying: no Windows, no PowerShell, no domain. The shipped matrix is read, never written."""
import copy, sys, unittest
from pathlib import Path
DEV = Path(__file__).resolve().parents[2]
TOOLS = DEV / 'tools'
if str(TOOLS) not in sys.path: sys.path.insert(0, str(TOOLS))
import validation_matrix as vm

SHA = 'a' * 64


def base_matrix():
    return {
        'Schema': vm.SCHEMA, 'LabDomains': ['cnamts.local'], 'LabHosts': ['CNAMTS-W11-01'],
        'Systems': [{'Id': 'dc-2022', 'Label': 'DC 2022'}],
        'Protocols': [{'Id': 'ldap', 'Label': 'LDAP'}],
        'Rights': [{'Id': 'reader', 'Label': 'Lecteur'}, {'Id': 'domain-admin', 'Label': 'Admin', 'LabOnly': True}],
        'Cells': [{'System': 'dc-2022', 'Protocol': 'ldap', 'Right': 'reader', 'Scenario': 'Lecture', 'Evidence': []}],
    }


def with_evidence(*evidence, right='reader'):
    m = base_matrix()
    m['Cells'][0]['Right'] = right
    m['Cells'][0]['Evidence'] = list(evidence)
    return m


def target(**extra):
    e = {'Environment': 'Target', 'Report': 'C:/rapports/campagne.json', 'Sha256': SHA, 'Date': '2026-11-02',
         'Domain': 'production.example', 'Computer': 'ADM-PC-01'}
    e.update(extra)
    return e


class ValidationMatrixTests(unittest.TestCase):
    def test_shipped_matrix_is_valid_and_published_page_is_current(self):
        matrix = vm.load()
        errors, cells = vm.evaluate(matrix)
        self.assertEqual(errors, [])
        self.assertEqual((DEV / vm.PAGE).read_text(encoding='utf-8'), vm.render(matrix, cells))

    def test_shipped_target_cells_rest_on_target_reports_only(self):
        matrix = vm.load()
        errors, cells = vm.evaluate(matrix)
        self.assertEqual(errors, [])
        for cell in cells:
            if cell['Status'] != 'Cible':
                continue
            reports = [e for e in cell['Evidence'] if e.get('Environment') == 'Target']
            self.assertTrue(reports, cell['Scenario'])
            for e in reports:
                self.assertEqual(vm.classify(e.get('Domain'), e.get('Computer'), matrix), 'Target', cell['Scenario'])

    def test_synthetic_evidence_never_exceeds_synthetic(self):
        errors, cells = vm.evaluate(with_evidence({'Environment': 'Synthetic', 'Reference': 'wad/tests/Test-DomeniaNetworkFaults.ps1'}))
        self.assertEqual(errors, [])
        self.assertEqual(cells[0]['Status'], 'Synthétique')

    def test_synthetic_evidence_with_a_domain_or_report_is_refused(self):
        errors, cells = vm.evaluate(with_evidence({'Environment': 'Synthetic', 'Reference': 'wad/tests/Test-DomeniaNetworkFaults.ps1', 'Domain': 'production.example'}))
        self.assertTrue(any('synthétique' in e for e in errors))
        self.assertEqual(cells[0]['Status'], 'Non couvert')

    def test_synthetic_evidence_needs_an_existing_test_file(self):
        errors, _ = vm.evaluate(with_evidence({'Environment': 'Synthetic', 'Reference': 'wad/tests/Test-Absent.ps1'}))
        self.assertTrue(any('fichier de test existant' in e for e in errors))
        errors, _ = vm.evaluate(with_evidence({'Environment': 'Synthetic', 'Reference': 'tools/validation_matrix.py'}))
        self.assertTrue(any('wad/tests' in e for e in errors))

    def test_lab_report_is_never_target_evidence(self):
        for domain, computer in (('cnamts.local', 'ADM-PC-01'), ('CNAMTS.LOCAL.', 'ADM-PC-01'), ('sous.cnamts.local', 'X'), ('production.example', 'cnamts-w11-01')):
            errors, cells = vm.evaluate(with_evidence(target(Domain=domain, Computer=computer)))
            self.assertTrue(any('présenté comme preuve du domaine cible' in e for e in errors), (domain, computer))
            self.assertEqual(cells[0]['Status'], 'Non couvert')

    def test_valid_target_report_proves_the_cell(self):
        errors, cells = vm.evaluate(with_evidence(target(), {'Environment': 'Synthetic', 'Reference': 'wad/tests/Test-DomeniaNetworkFaults.ps1'}))
        self.assertEqual(errors, [])
        self.assertEqual(cells[0]['Status'], 'Cible')

    def test_lab_evidence_must_come_from_the_lab(self):
        lab = {'Environment': 'Lab', 'Report': 'C:/rapports/labo.json', 'Sha256': SHA, 'Date': '2026-10-20', 'Domain': 'cnamts.local', 'Computer': 'CNAMTS-W11-01'}
        errors, cells = vm.evaluate(with_evidence(lab))
        self.assertEqual(errors, [])
        self.assertEqual(cells[0]['Status'], 'Laboratoire')
        errors, _ = vm.evaluate(with_evidence(dict(lab, Domain='production.example', Computer='ADM-PC-01')))
        self.assertTrue(any('déclaré comme laboratoire' in e for e in errors))

    def test_execution_evidence_needs_report_hash_date_domain_and_host(self):
        for field in ('Report', 'Sha256', 'Date', 'Domain', 'Computer'):
            e = target(); e.pop(field)
            errors, cells = vm.evaluate(with_evidence(e))
            self.assertTrue(errors, field)
            self.assertEqual(cells[0]['Status'], 'Non couvert', field)
        errors, _ = vm.evaluate(with_evidence(target(Sha256='abc'), target(Date='02/11/2026')))
        self.assertTrue(any('SHA-256' in e for e in errors))
        self.assertTrue(any('AAAA-MM-JJ' in e for e in errors))
        errors, _ = vm.evaluate(with_evidence(target(Report='wad/tests/Test-DomeniaNetworkFaults.ps1')))
        self.assertTrue(any('nʼest pas un rapport' in e for e in errors))

    def test_lab_only_right_never_receives_target_evidence(self):
        errors, cells = vm.evaluate(with_evidence(target(), right='domain-admin'))
        self.assertTrue(any('réservé au laboratoire' in e for e in errors))
        self.assertEqual(cells[0]['Status'], 'Non couvert')

    def test_closed_vocabulary_and_unique_cells(self):
        m = base_matrix(); m['Cells'].append(copy.deepcopy(m['Cells'][0]))
        errors, _ = vm.evaluate(m)
        self.assertTrue(any('double' in e for e in errors))
        m = base_matrix(); m['Cells'][0]['Protocol'] = 'telnet'
        errors, _ = vm.evaluate(m)
        self.assertTrue(any('inconnu' in e for e in errors))
        m = base_matrix(); m['LabDomains'] = []
        errors, _ = vm.evaluate(m)
        self.assertTrue(any('LabDomains' in e for e in errors))

    def test_report_without_domain_is_unknown(self):
        m = base_matrix()
        self.assertEqual(vm.classify('', 'ADM-PC-01', m), 'Unknown')
        self.assertEqual(vm.classify('production.example', 'ADM-PC-01', m), 'Target')
        self.assertEqual(vm.classify('cnamts.local', 'ADM-PC-01', m), 'Lab')

    def test_rendering_is_deterministic(self):
        matrix = vm.load()
        _, cells = vm.evaluate(matrix)
        self.assertEqual(vm.render(matrix, cells), vm.render(matrix, cells))


if __name__ == '__main__':
    unittest.main()
