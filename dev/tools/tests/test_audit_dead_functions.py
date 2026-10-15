"""Offline checks of tools/audit_dead_functions.py (P-CD-02): reference rules, reachability, tests-only category and
ratchet. Fictitious trees in temporary folders, plus read-only consistency checks of this repository."""
import contextlib
import io
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

DEV = Path(__file__).resolve().parents[2]
TOOLS = DEV / 'tools'
sys.path.insert(0, str(TOOLS))
import audit_dead_functions as audit  # noqa: E402
import audit_function_names  # noqa: E402
from ps_sources import read_ps, top_level_functions  # noqa: E402

CORE = """# Fixture core
function Start-App {
    Get-Used
    Start-UiTask -Name 'x' -SuccessHandler 'Complete-ByHandler' -ErrorHandler "Fail-ByHandler"
    $definition = (Get-Command Get-ViaGetCommand -CommandType Function).Definition
    $fn = ${function:Get-ViaVariable}
    $code = @'
# Get-InWorkerComment
$r = Get-InWorker
function Get-WorkerLocal { 'only in the worker' }
'@
    # Get-InComment
    $text = 'function Get-DefinedInString {'
}
function Get-Used { Get-Used }
function Complete-ByHandler { }
function Fail-ByHandler { }
function Get-ViaGetCommand { }
function Get-ViaVariable { }
function Get-InWorker { }
function Get-InWorkerComment { }
function Get-InComment { }
function Get-DefinedInString { }
function Get-Recursive { Get-Recursive }
function Get-CycleA { Get-CycleB }
function Get-CycleB { Get-CycleA }
function Get-Dead { Get-OnlyFromDead }
function Get-OnlyFromDead { }
function Get-Tested { Get-HelperOfTested }
function Get-HelperOfTested { }
function Get-PyTested { }
function Get-PyComment { }
function Invoke-Click { }
$script:Ctrl['BtnGo'].Add_Click({ Invoke-Click })
Start-App
"""

LOADER = """function Get-DomeniaRuntimeModulePlan {
    @(
        [pscustomobject]@{ Phase='Modules'; Requires=@(); File='Fixture.Model.ps1'; DotSource=$true; Functions=@(
            'Get-ModuleListed',
            'Get-ModuleUsed'
        ) }
    )
}
"""

MODULE = """function Get-ModuleListed { }
function Get-ModuleUsed { }
$script:Routes = @{ Home = 'Get-ModuleUsed' }
"""

TEST_PS = """# Get-InComment is only named in this comment
Test-Case 'X' 'y' { Get-Tested }
function Get-Dead { 'a stub definition in a test is not a use' }
"""

TEST_PY = """# Get-PyComment
CHECKED = ['Get-PyTested']
"""


def write(root, rel, text):
    path = root / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, 'w', encoding='utf-8-sig', newline='\n') as handle:
        handle.write(text)


def fixture(root):
    write(root, 'wad/Domenia-Core.ps1', CORE)
    write(root, 'wad/Domenia-Modules.ps1', LOADER)
    write(root, 'wad/modules/Fixture.Model.ps1', MODULE)
    write(root, 'wad/tests/Test-Fixture.ps1', TEST_PS)
    with open(root / 'wad/tests/audit_fixture.py', 'w', encoding='utf-8', newline='\n') as handle:
        handle.write(TEST_PY)


def run(argv):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        code = audit.main(argv)
    text = out.getvalue()
    return code, json.loads(text[text.index('{'):]) if '{' in text else {}


class AnalyseTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='dead-functions-'))
        fixture(self.tmp)
        rows, self.total = audit.analyse(self.tmp)
        self.rows = {r['Name']: r for r in rows}

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_live_references(self):
        for live in ('Start-App', 'Get-Used', 'Complete-ByHandler', 'Fail-ByHandler', 'Get-ViaGetCommand',
                     'Get-ViaVariable', 'Get-InWorker', 'Invoke-Click', 'Get-ModuleUsed'):
            self.assertNotIn(live, self.rows, live)

    def test_dead_and_unreferenced(self):
        for dead in ('Get-InWorkerComment', 'Get-InComment', 'Get-DefinedInString', 'Get-Recursive', 'Get-Dead',
                     'Get-ModuleListed', 'Get-PyComment'):
            self.assertEqual(self.rows[dead]['Category'], 'dead', dead)
            self.assertEqual(self.rows[dead]['Kind'], 'unreferenced', dead)

    def test_unreachable_chain_and_cycle(self):
        self.assertEqual(self.rows['Get-OnlyFromDead']['Kind'], 'unreachable')
        self.assertEqual(self.rows['Get-OnlyFromDead']['Callers'], ['Get-Dead'])
        self.assertEqual(self.rows['Get-CycleA']['Callers'], ['Get-CycleB'])
        self.assertEqual(self.rows['Get-CycleB']['Category'], 'dead')

    def test_tests_only_direct_and_transitive(self):
        self.assertEqual(self.rows['Get-Tested']['Category'], 'tests-only')
        self.assertEqual(self.rows['Get-Tested']['Tests'], ['wad/tests/Test-Fixture.ps1'])
        self.assertEqual(self.rows['Get-HelperOfTested']['Category'], 'tests-only')
        self.assertEqual(self.rows['Get-HelperOfTested']['Kind'], 'unreachable')
        self.assertEqual(self.rows['Get-PyTested']['Category'], 'tests-only')

    def test_worker_definitions_are_not_audited(self):
        self.assertNotIn('Get-WorkerLocal', self.rows)
        self.assertEqual(self.total, 23)

    def test_location(self):
        row = self.rows['Get-Dead']
        self.assertEqual((row['File'], row['Line']), ('wad/Domenia-Core.ps1', 27))
        self.assertEqual(self.rows['Get-ModuleListed']['File'], 'wad/modules/Fixture.Model.ps1')


class RatchetTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='dead-ratchet-'))
        fixture(self.tmp)
        self.baseline = self.tmp / 'tools/baselines/dead-functions-baseline.json'
        self.args = ['--root', str(self.tmp)]

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_missing_reference_fails(self):
        code, report = run(self.args)
        self.assertEqual(code, 1)
        self.assertEqual(report['Status'], 'FAIL')

    def test_init_pass_increase_and_update(self):
        code, report = run(self.args + ['--init', '--source', 'fixture'])
        self.assertEqual((code, report['Status']), (0, 'INIT'))
        saved = json.loads(self.baseline.read_text(encoding='utf-8'))
        self.assertEqual(saved['Schema'], audit.SCHEMA)
        self.assertEqual(saved['Findings']['Get-Tested'], 'tests-only')
        self.assertEqual(saved['Total'], len(saved['Findings']))
        code, report = run(self.args + ['--init'])
        self.assertEqual(code, 1, 'An existing reference is never replaced by --init')
        code, report = run(self.args)
        self.assertEqual((code, report['Status'], report['Fixed']), (0, 'PASS', 0))

        write(self.tmp, 'wad/Domenia-Core.ps1', CORE + 'function Get-NewDead { }\n')
        code, report = run(self.args)
        self.assertEqual((code, report['Status']), (1, 'FAIL'))
        self.assertEqual([n['Name'] for n in report['New']], ['Get-NewDead'])
        before = self.baseline.read_text(encoding='utf-8')
        code, report = run(self.args + ['--update'])
        self.assertEqual(code, 1)
        self.assertEqual(self.baseline.read_text(encoding='utf-8'), before, 'An increase never rewrites the reference')

        write(self.tmp, 'wad/Domenia-Core.ps1', CORE.replace('function Get-Recursive { Get-Recursive }\n', ''))
        code, report = run(self.args)
        self.assertEqual((code, report['Status'], report['Fixed']), (0, 'PASS', 1))
        code, report = run(self.args + ['--update'])
        self.assertEqual((code, report['Status']), (0, 'UPDATED'))
        self.assertNotIn('Get-Recursive', json.loads(self.baseline.read_text(encoding='utf-8'))['Findings'])

    def test_category_change_is_not_an_increase(self):
        run(self.args + ['--init'])
        write(self.tmp, 'wad/tests/Test-Other.ps1', "Test-Case 'Z' 'z' { Get-Dead }\n")
        code, report = run(self.args)
        self.assertEqual((code, report['Status']), (0, 'PASS'))
        self.assertEqual(report['Summary'].get('tests-only/unreferenced', 0) >= 1, True)


class RepositoryTests(unittest.TestCase):
    """Read-only checks of this repository: the audit runs, sees what the closed loader declares, and its findings
    point at real definitions."""

    @classmethod
    def setUpClass(cls):
        cls.rows, cls.total = audit.analyse(DEV)

    def test_module_functions_match_the_closed_loader(self):
        for module in audit_function_names.read_plan():
            if not module['File'].endswith('.ps1'):
                continue
            text = read_ps(DEV / 'wad/modules' / module['File'])
            self.assertEqual([s[0] for s in top_level_functions(text)], module['Functions'], module['File'])

    def test_findings_point_at_definitions(self):
        self.assertGreater(self.total, 1000)
        cache = {}
        for row in self.rows:
            lines = cache.setdefault(row['File'], read_ps(DEV / row['File']).split('\n'))
            self.assertRegex(lines[row['Line'] - 1], r'(?i)^\s*(function|filter)\s+' + row['Name'] + r'\b', row['Name'])

    def test_reference_is_readable(self):
        data = audit.load(DEV / audit.BASELINE)
        self.assertEqual(data['Total'], len(data['Findings']))
        self.assertTrue(set(data['Findings'].values()) <= {'dead', 'tests-only'})


if __name__ == '__main__':
    unittest.main()
