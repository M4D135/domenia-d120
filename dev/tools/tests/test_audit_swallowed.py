"""Offline checks of tools/audit_swallowed.py (P-CD-09): which catch blocks swallow, keys, exemption and ratchet.
Fictitious trees in temporary folders, plus read-only checks of this repository."""
import contextlib
import io
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

DEV = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(DEV / 'tools'))
import audit_swallowed as audit  # noqa: E402

CORE = """function Get-Swallowing {
    try { A } catch { }
    try { B } catch {
        # deliberately ignored
    }
    try { C } catch { $null }
    try { D } catch { $null = $_; [void]$_ }
    try { E } catch [System.IO.IOException], [System.UnauthorizedAccessException] { }
    try{F}catch{}
}
function Get-Handled {
    try { A } catch { return $null }
    try { B } catch { Write-DomeniaSwallowed 'Fixture' 'B' $_ }
    try { C } catch { 'value' }
    try { D } catch { $failed = $true }
    $catch = 'catch { }'
    # catch { } in a comment
}
function Get-Worker {
    $code = @'
try { Read-Remote } catch { }
# catch { } in a worker comment
'@
}
function Write-DomeniaSwallowed {
    try { X } catch { $null = $_ }
}
function Add-DomeniaSwallowedEntry {
    try { Y } catch { $null = $_ }
}
try { Start-App } catch { }
"""

MODULE = """function Get-ModuleSwallowing {
    try { A } catch { }
}
"""


def write(root, rel, text):
    path = root / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, 'w', encoding='utf-8-sig', newline='\n') as handle:
        handle.write(text)


def run(argv):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        code = audit.main(argv)
    text = out.getvalue()
    return code, json.loads(text[text.index('{'):])


class ClassifyTests(unittest.TestCase):
    def test_kinds(self):
        self.assertEqual(audit.classify('   ', ''), 'empty')
        self.assertEqual(audit.classify('   ', ' # note '), 'comment')
        self.assertEqual(audit.classify(' $null ', ' $null '), 'null')
        self.assertEqual(audit.classify(' $NULL = $_ ; $_ | Out-Null ', ''), 'null')
        self.assertIsNone(audit.classify(' return $null ', ''))
        self.assertIsNone(audit.classify(" 'x' ", ''))
        self.assertIsNone(audit.classify(' $null = Get-Thing ', ''))


class FindingsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='swallowed-'))
        write(self.tmp, 'wad/Domenia-Core.ps1', CORE)
        write(self.tmp, 'wad/modules/Fixture.UI.ps1', MODULE)
        self.rows = audit.findings(self.tmp)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_swallowing_blocks_and_kinds(self):
        rows = [r for r in self.rows if r['Function'] == 'Get-Swallowing']
        self.assertEqual([(r['Line'], r['Kind']) for r in rows],
                         [(2, 'empty'), (3, 'comment'), (6, 'null'), (7, 'null'), (8, 'empty'), (9, 'empty')])

    def test_handled_blocks_strings_and_comments_are_not_reported(self):
        self.assertEqual([r for r in self.rows if r['Function'] == 'Get-Handled'], [])

    def test_worker_code_and_keys(self):
        worker = [r for r in self.rows if r['Function'] == 'Get-Worker']
        self.assertEqual(len(worker), 1)
        self.assertTrue(worker[0]['HereString'])
        self.assertEqual(worker[0]['Line'], 21)
        counts = audit.counts(self.rows)
        self.assertEqual(counts['Get-Swallowing'], 6)
        self.assertEqual(counts['Get-Worker' + audit.HERE], 1)
        self.assertEqual(counts['wad/Domenia-Core.ps1|<script>'], 1)
        self.assertEqual(counts['Get-ModuleSwallowing'], 1)

    def test_write_domenia_swallowed_is_exempt(self):
        exempt = [r for r in self.rows if r['Exempt']]
        self.assertEqual([r['Function'] for r in exempt], ['Write-DomeniaSwallowed', 'Add-DomeniaSwallowedEntry'])
        counts = audit.counts(self.rows)
        self.assertNotIn('Write-DomeniaSwallowed', counts)
        self.assertNotIn('Add-DomeniaSwallowedEntry', counts)


class RatchetTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='swallowed-ratchet-'))
        write(self.tmp, 'wad/Domenia-Core.ps1', CORE)
        write(self.tmp, 'wad/modules/Fixture.UI.ps1', MODULE)
        self.baseline = self.tmp / 'tools/baselines/swallowed-baseline.json'
        self.args = ['--root', str(self.tmp)]

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_missing_reference_fails(self):
        code, report = run(self.args)
        self.assertEqual((code, report['Status']), (1, 'FAIL'))

    def test_init_pass_increase_move_and_update(self):
        code, report = run(self.args + ['--init', '--source', 'fixture'])
        self.assertEqual((code, report['Status'], report['Total'], report['Exempt']), (0, 'INIT', 9, 2))
        saved = json.loads(self.baseline.read_text(encoding='utf-8'))
        self.assertEqual(saved['Schema'], audit.SCHEMA)
        self.assertEqual(saved['Kinds'], {'comment': 1, 'empty': 6, 'null': 2})
        self.assertEqual(saved['Places'], {'code': 8, 'here-string': 1})
        self.assertEqual(run(self.args + ['--init'])[0], 1, 'An existing reference is never replaced by --init')
        code, report = run(self.args)
        self.assertEqual((code, report['Status']), (0, 'PASS'))

        # The same function moved to another file keeps its key.
        write(self.tmp, 'wad/modules/Fixture.UI.ps1', '')
        write(self.tmp, 'wad/modules/Other.UI.ps1', MODULE)
        self.assertEqual(run(self.args)[1]['Status'], 'PASS')

        write(self.tmp, 'wad/modules/Other.UI.ps1', MODULE.replace('catch { }', 'catch { }\n    try { B } catch { }'))
        code, report = run(self.args)
        self.assertEqual((code, report['Status']), (1, 'FAIL'))
        self.assertEqual(report['Exceeded'], {'Get-ModuleSwallowing': 1})
        before = self.baseline.read_text(encoding='utf-8')
        self.assertEqual(run(self.args + ['--update'])[0], 1)
        self.assertEqual(self.baseline.read_text(encoding='utf-8'), before, 'An increase never rewrites the reference')

        write(self.tmp, 'wad/modules/Other.UI.ps1', MODULE.replace('catch { }', "catch { Write-DomeniaSwallowed 'M' 'A' $_ }"))
        code, report = run(self.args)
        self.assertEqual((code, report['Status'], report['Fixed']), (0, 'PASS', 1))
        code, report = run(self.args + ['--update'])
        self.assertEqual((code, report['Status']), (0, 'UPDATED'))
        self.assertNotIn('Get-ModuleSwallowing', json.loads(self.baseline.read_text(encoding='utf-8'))['Findings'])


class RepositoryTests(unittest.TestCase):
    def test_repository_scan(self):
        rows = audit.findings(DEV)
        self.assertGreater(len(rows), 0)
        exempt = [r for r in rows if r['Exempt']]
        self.assertEqual({(r['File'], r['Function']) for r in exempt},
                         {('wad/Domenia-Core.ps1', 'Write-DomeniaSwallowed'),
                          ('wad/modules/Domenia-Common.Model.ps1', 'Add-DomeniaSwallowedEntry')})
        data = audit.load(DEV / audit.BASELINE)
        self.assertEqual(data['Total'], sum(data['Findings'].values()))


if __name__ == '__main__':
    unittest.main()
