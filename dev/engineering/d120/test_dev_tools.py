"""Offline tests of the DEV tools changed by lot L05 (SE-15, SP-09, FI-14, CD-14, TE-01). Non qualifying: no Windows,
no PowerShell, temporary trees only (the real tree is read, never written)."""
import contextlib, hashlib, io, json, subprocess, sys, tempfile, unittest
from pathlib import Path
DEV = Path(__file__).resolve().parents[2]
TOOLS = DEV / 'tools'
if str(TOOLS) not in sys.path: sys.path.insert(0, str(TOOLS))
import audit_wording, build_packages, release_contract


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.t = tempfile.TemporaryDirectory(); self.root = Path(self.t.name) / 'dev'
        for rel in ('wad/x.ps1', 'engineering/d120/lab/lab.sh', 'engineering/d120/release_guard.py', 'wad/docs/history/old.md', 'wad/docs/GUIDE.md'):
            p = self.root / rel; p.parent.mkdir(parents=True, exist_ok=True); p.write_text('x')

    def tearDown(self): self.t.cleanup()

    def test_dev_archive_excludes_lab_and_history(self):
        members = build_packages.select_members(self.root)
        self.assertEqual(members, ['engineering/d120/release_guard.py', 'wad/docs/GUIDE.md', 'wad/x.ps1'])

    def test_stage_copy_is_outside_the_tree_and_never_mixed(self):
        stage = Path(self.t.name) / 'stage'
        prod = {'Files': [{'Path': 'wad/x.ps1'}]}
        out = build_packages.write_stage(stage, ['wad/x.ps1'], prod, self.root)
        self.assertEqual(out['Files'], 1)
        self.assertEqual((stage / 'wad/x.ps1').read_text(), 'x')
        self.assertEqual(json.loads((stage / 'tools/prod-manifest.json').read_text())['Files'][0]['Path'], 'wad/x.ps1')
        with self.assertRaises(ValueError): build_packages.write_stage(stage, ['wad/x.ps1'], prod, self.root)
        with self.assertRaises(ValueError): build_packages.write_stage(self.root / 'stage', ['wad/x.ps1'], prod, self.root)

    def test_installer_ships_in_prod_runtime(self):
        self.assertIn('wad/Support/INSTALLER-MISE-A-JOUR.ps1', build_packages.runtime_paths())


class RuntimeLimitTests(unittest.TestCase):
    def test_alert_from_80_percent_and_failure_above(self):
        contract = {'RuntimeFileLimit': 100}
        self.assertEqual(release_contract.runtime_limit_state(contract, 79), ('', ''))
        problem, warning = release_contract.runtime_limit_state(contract, 80)
        self.assertEqual(problem, ''); self.assertIn('80 %', warning)
        problem, warning = release_contract.runtime_limit_state(contract, 101)
        self.assertIn('plafond de 100', problem)

    def test_default_limit_and_current_contract(self):
        self.assertEqual(release_contract.runtime_limit_state({}, 199), ('', ''))
        contract = release_contract.load_contract()
        self.assertEqual(contract['RuntimeFileLimit'], json.loads((DEV / 'wad/Domenia.release.json').read_text(encoding='utf-8-sig'))['RuntimeFileLimit'])


class WorkerContractToolTests(unittest.TestCase):
    """CD-14 on the real tree without --apply: the diff is shown, nothing is written and the exit code asks for review."""
    def run_tool(self, *args):
        return subprocess.run([sys.executable, str(TOOLS / 'update_worker_contracts.py'), *args], capture_output=True, text=True)

    def test_add_and_remove_show_diff_and_require_apply(self):
        files = [DEV / 'tools/operation-contracts.json', DEV / 'wad/Domenia-Core.ps1']
        before = [digest(p) for p in files]
        removed = self.run_tool('--remove', 'EmbeddedPathBrowse')
        self.assertEqual(removed.returncode, 1, removed.stderr)
        self.assertIn('-        EmbeddedPathBrowse', removed.stderr); self.assertIn('$expectedFingerprint', removed.stderr)
        self.assertIn('Removed:EmbeddedPathBrowse', removed.stdout)
        added = self.run_tool('--add', 'SampleReviewOp', 'Get-DomeniaEmbeddedPathCode')
        self.assertEqual(added.returncode, 1, added.stderr)
        self.assertIn('"Operation": "SampleReviewOp"', added.stderr); self.assertIn('Added:SampleReviewOp', added.stdout)
        self.assertEqual(self.run_tool('--add', 'EmbeddedPathBrowse', 'Get-DomeniaEmbeddedPathCode').returncode, 2)
        self.assertEqual(self.run_tool('--remove', 'UnknownOperation').returncode, 2)
        self.assertEqual(before, [digest(p) for p in files])
        self.assertEqual(self.run_tool().returncode, 0)


class WordingAuditTests(unittest.TestCase):
    def setUp(self):
        self.t = tempfile.TemporaryDirectory(); self.root = Path(self.t.name)
        (self.root / 'wad/modules').mkdir(parents=True)
        self.core = self.root / 'wad/Domenia-Core.ps1'
        self.write("<TextBlock Text=\"État du poste\"/>\nSet-Status 'Recherche terminée.' 'INFO'\n")
        (self.root / 'wad/modules/Domenia-UX.help.json').write_text(json.dumps([{'Name': 'X', 'Title': 'Aide', 'Text': 'Ouvre lʼobjet.'}]), encoding='utf-8')
        self.baseline = self.root / 'baseline.json'

    def tearDown(self): self.t.cleanup()

    def write(self, text): self.core.write_text(text, encoding='utf-8-sig')

    def audit(self, *extra):
        with contextlib.redirect_stdout(io.StringIO()):
            return audit_wording.main(['--root', str(self.root), '--baseline', str(self.baseline), *extra])

    def test_rules(self):
        self.write("<Button Content=\"Detecter\" ToolTip=\"Ferme-le puis choisis l OU de ton compte.\"/>\n"
                   "Set-Status ('Etat : '+$x+' n est pas a jour') 'WARN'\nSet-DomeniaContextHint -Title 'Synthese' -Text 'Fermez-le.'\n")
        rules = {(r['Rule'], tuple(r['Words'])) for r in audit_wording.findings(self.root)}
        self.assertIn(('accent', ('Detecter',)), rules)
        self.assertIn(('elision', ('l',)), rules)
        self.assertIn(('tutoiement', ('Ferme-le', 'ton')), rules)
        self.assertIn(('accent', ('Etat',)), rules); self.assertIn(('accent', ('a jour',)), rules); self.assertIn(('elision', ('n',)), rules)
        self.assertIn(('accent', ('Synthese',)), rules)
        self.assertNotIn('Fermez-le.', [r['Text'] for r in audit_wording.findings(self.root)])

    def test_ratchet_fails_on_new_text_and_only_goes_down(self):
        self.write("<TextBlock Text=\"Etat\"/>\n<TextBlock Text=\"Etat\"/>\n")
        self.assertEqual(self.audit('--init', '--source', 'test'), 0)
        self.assertEqual(self.audit(), 0)
        self.write("<TextBlock Text=\"Etat\"/>\n<TextBlock Text=\"Etat\"/>\n<TextBlock Text=\"Derniere lecture\"/>\n")
        self.assertEqual(self.audit(), 1)
        self.assertEqual(self.audit('--update'), 1)
        self.write("<TextBlock Text=\"Etat\"/>\n<TextBlock Text=\"Etat\"/>\n<TextBlock Text=\"Etat\"/>\n")
        self.assertEqual(self.audit(), 1, 'one more copy of an old faulty text')
        self.write("<TextBlock Text=\"État\"/>\n<TextBlock Text=\"Etat\"/>\n")
        self.assertEqual(self.audit('--update'), 0)
        self.assertEqual(json.loads(self.baseline.read_text(encoding='utf-8'))['Total'], 1)
        self.write("<TextBlock Text=\"Etat\"/>\n<TextBlock Text=\"Etat\"/>\n")
        self.assertEqual(self.audit(), 1, 'the lowered reference is the new ceiling')

    def test_repository_reference_is_not_exceeded(self):
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(audit_wording.main([]), 0)


if __name__ == '__main__':
    unittest.main()
