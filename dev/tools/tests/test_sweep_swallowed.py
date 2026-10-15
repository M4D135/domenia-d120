"""Offline checks of tools/sweep_swallowed.py (P-CD-09): rewriting of the empty catch blocks into a trace, blocks left as
they are (worker code, pure rules, copied functions, closures, remote scriptblocks, bootstrap), encoding and
idempotence. Fictitious trees in temporary folders, plus read-only checks of this repository; nothing is executed."""
import contextlib
import io
import json
from pathlib import Path
import re
import shutil
import sys
import tempfile
import unittest

DEV = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(DEV / 'tools'))
import audit_swallowed as audit  # noqa: E402
import sweep_swallowed as sweep  # noqa: E402
from ps_sources import mask_ps, top_level_functions  # noqa: E402

CORE = """param([string]$Server)
try { Early } catch { }
function Write-DomeniaSwallowed {
    try { X } catch { $null = $_ }
}
function Get-Plain {
    try { A } catch { }
    try{B}catch{}
    try { C } catch {}
    try { D } catch [System.IO.IOException] { }
    try { E } catch {
    }
    try { F } catch { # kept: a comment says why
    }
    try { G } catch { $fallback = $true }
    $text = 'try { H } catch { }'
}
function Start-Remote {
    Invoke-Command -Session $s -ScriptBlock { try { I } catch { } }
    $ps.AddScript({ try { J } catch { } })
}
function Get-Closure {
    $handler = { try { K } catch { } }.GetNewClosure()
    $plain = { try { L } catch { } }
}
function Get-WorkerCode {
    return @'
try { Remote } catch { }
'@
}
function Invoke-DomeniaCopiedProbe {
    try { M } catch { }
}
function Start-CopiedRunspace {
    $definition = (Get-Command -Name Invoke-DomeniaCopiedProbe -CommandType Function).Definition
    foreach ($helper in @('Get-DomeniaCopiedHelper')) { $d = (Get-Command $helper -CommandType Function).Definition }
}
function Get-DomeniaCopiedHelper {
    try { N } catch { }
}
try { Main } catch { }
"""

UI = "function Show-Panel {\n    try { A } catch { }\n}\n"
MODEL = "function Get-Rule {\n    try { A } catch { }\n}\n"
WORKER = "function Get-W {\n    try { A } catch { }\n}\n"
START = "try { Check } catch { }\n"


def write(root, rel, text, bom=True):
    path = root / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes((b'\xef\xbb\xbf' if bom else b'') + text.encode('utf-8'))
    return path


def run(argv):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        code = sweep.main(argv)
    text = out.getvalue()
    return code, json.loads(text[text.index('{'):]), text


class HelpersTests(unittest.TestCase):
    def test_category_from_module(self):
        self.assertEqual(sweep.category('wad/Domenia-Core.ps1'), 'Core')
        self.assertEqual(sweep.category('wad/modules/Domenia-Storage.UI.ps1'), 'Storage')
        self.assertEqual(sweep.category('wad/modules/Domenia-Accounts.Async.ps1'), 'Accounts')
        self.assertEqual(sweep.category('wad/modules/Domenia-DirectoryStore.Store.UI.ps1'), 'DirectoryStore')
        self.assertEqual(sweep.category('wad/modules/Fixture.UI.ps1'), 'Fixture.UI')

    def test_file_reasons(self):
        self.assertEqual(sweep.file_reason('wad/Domenia-Start.ps1'), 'bootstrap')
        self.assertEqual(sweep.file_reason('wad/Domenia-Modules.ps1'), 'bootstrap')
        self.assertEqual(sweep.file_reason('wad/modules/Domenia-Park.Worker.ps1'), 'worker-file')
        self.assertEqual(sweep.file_reason('wad/modules/Domenia-Park.Model.ps1'), 'model')
        self.assertIsNone(sweep.file_reason('wad/modules/Domenia-Park.UI.ps1'))
        self.assertIsNone(sweep.file_reason('wad/Domenia-Core.ps1'))

    def test_new_body_keeps_spacing(self):
        call = "Write-DomeniaSwallowed 'Core' 'F' $_"
        self.assertEqual(sweep.new_body('catch{}', 0, '', call), call)
        self.assertEqual(sweep.new_body('catch {}', 0, '', call), ' ' + call + ' ')
        self.assertEqual(sweep.new_body('catch { }', 0, ' ', call), ' ' + call + ' ')
        text = '    try { A } catch {\n    }'
        keyword = text.index('catch')
        self.assertEqual(sweep.new_body(text, keyword, '\n    ', call), '\n        ' + call + '\n    ')


class SweepTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='sweep-swallowed-'))
        self.core = write(self.tmp, 'wad/Domenia-Core.ps1', CORE)
        self.ui = write(self.tmp, 'wad/modules/Domenia-Panel.UI.ps1', UI.replace('\n', '\r\n'), bom=True)
        self.model = write(self.tmp, 'wad/modules/Domenia-Panel.Model.ps1', MODEL)
        self.worker = write(self.tmp, 'wad/modules/Domenia-Panel.Worker.ps1', WORKER)
        self.start = write(self.tmp, 'wad/Domenia-Start.ps1', START)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def core_text(self):
        return self.core.read_bytes().decode('utf-8-sig')

    def test_plan_writes_nothing(self):
        before = {p: p.read_bytes() for p in (self.core, self.ui, self.model, self.worker, self.start)}
        code, report, _ = run(['--root', str(self.tmp)])
        self.assertEqual((code, report['Status']), (0, 'PLAN'))
        self.assertEqual(report['Rewritten'], 8)
        for path, data in before.items():
            self.assertEqual(path.read_bytes(), data, path.name)

    def test_apply_rewrites_only_core_scope_blocks(self):
        code, report, _ = run(['--root', str(self.tmp), '--apply'])
        self.assertEqual((code, report['Status'], report['Rewritten']), (0, 'APPLIED', 8))
        self.assertEqual(report['Files'], {'wad/Domenia-Core.ps1': 7, 'wad/modules/Domenia-Panel.UI.ps1': 1})
        self.assertEqual(report['LeftByReason'], {'here-string': 1, 'worker-file': 1, 'model': 1, 'bootstrap': 1,
                                                  'copied': 2, 'closure': 1, 'remote': 2, 'early': 1})
        self.assertEqual(report['CopiedFunctions'], ['Get-DomeniaCopiedHelper', 'Invoke-DomeniaCopiedProbe'])
        text = self.core_text()
        self.assertIn("try { A } catch { Write-DomeniaSwallowed 'Core' 'Get-Plain' $_ }", text)
        self.assertIn("try{B}catch{Write-DomeniaSwallowed 'Core' 'Get-Plain' $_}", text)
        self.assertIn("try { C } catch { Write-DomeniaSwallowed 'Core' 'Get-Plain' $_ }", text)
        self.assertIn("catch [System.IO.IOException] { Write-DomeniaSwallowed 'Core' 'Get-Plain' $_ }", text)
        self.assertIn("try { E } catch {\n        Write-DomeniaSwallowed 'Core' 'Get-Plain' $_\n    }", text)
        self.assertIn("try { F } catch { # kept: a comment says why\n    }", text, 'A commented block is never rewritten')
        self.assertIn('$fallback = $true', text)
        self.assertIn("$text = 'try { H } catch { }'", text, 'A string is never rewritten')
        self.assertIn("$plain = { try { L } catch { Write-DomeniaSwallowed 'Core' 'Get-Closure' $_ } }", text)
        self.assertIn('$handler = { try { K } catch { } }.GetNewClosure()', text)
        self.assertIn('-ScriptBlock { try { I } catch { } }', text)
        self.assertIn('$ps.AddScript({ try { J } catch { } })', text)
        self.assertIn("try { Remote } catch { }\n'@", text, 'Worker code is never rewritten')
        self.assertIn('try { M } catch { }', text)
        self.assertIn('try { N } catch { }', text)
        self.assertIn("try { Early } catch { }", text, 'Script code above the definition cannot call it')
        self.assertIn("try { Main } catch { Write-DomeniaSwallowed 'Core' 'Domenia-Core.ps1' $_ }", text)
        self.assertIn('try { X } catch { $null = $_ }', text)

    def test_encoding_line_endings_and_untouched_files(self):
        model, worker, start = self.model.read_bytes(), self.worker.read_bytes(), self.start.read_bytes()
        run(['--root', str(self.tmp), '--apply'])
        self.assertTrue(self.core.read_bytes().startswith(b'\xef\xbb\xbf'), 'BOM kept')
        ui = self.ui.read_bytes()
        self.assertTrue(ui.startswith(b'\xef\xbb\xbf'))
        self.assertEqual(ui.decode('utf-8-sig'),
                         "function Show-Panel {\r\n    try { A } catch { Write-DomeniaSwallowed 'Panel' 'Show-Panel' $_ }\r\n}\r\n",
                         'CRLF kept where the file has it')
        self.assertEqual(self.core_text().count('\n'), CORE.count('\n') + 1, 'Only the block spread over two lines grows')
        self.assertNotIn('\r', self.core_text(), 'LF kept')
        self.assertEqual((self.model.read_bytes(), self.worker.read_bytes(), self.start.read_bytes()), (model, worker, start))

    def test_file_without_bom_stays_without_bom(self):
        write(self.tmp, 'wad/modules/Domenia-Plain.UI.ps1', UI, bom=False)
        run(['--root', str(self.tmp), '--apply'])
        data = (self.tmp / 'wad/modules/Domenia-Plain.UI.ps1').read_bytes()
        self.assertFalse(data.startswith(b'\xef\xbb\xbf'))
        self.assertIn(b"Write-DomeniaSwallowed 'Plain' 'Show-Panel' $_", data)

    def test_idempotent(self):
        run(['--root', str(self.tmp), '--apply'])
        first = {p: p.read_bytes() for p in (self.core, self.ui)}
        code, report, _ = run(['--root', str(self.tmp), '--apply'])
        self.assertEqual((code, report['Rewritten']), (0, 0))
        for path, data in first.items():
            self.assertEqual(path.read_bytes(), data, path.name)

    def test_list_names_each_block_left(self):
        _, _, text = run(['--root', str(self.tmp), '--list'])
        self.assertIn('wad/Domenia-Core.ps1:2 [early] <script>', text)
        self.assertIn('wad/Domenia-Core.ps1:23 [closure] Get-Closure', text)
        self.assertIn('wad/Domenia-Core.ps1:19 [remote] Start-Remote', text)
        self.assertIn('wad/Domenia-Core.ps1:28 [here-string] Get-WorkerCode', text)
        self.assertIn('wad/Domenia-Core.ps1:32 [copied] Invoke-DomeniaCopiedProbe', text)
        self.assertIn('wad/modules/Domenia-Panel.Model.ps1:2 [model] Get-Rule', text)

    def test_audit_drops_after_apply(self):
        before = audit.counts(audit.findings(self.tmp))
        run(['--root', str(self.tmp), '--apply'])
        after = audit.counts(audit.findings(self.tmp))
        self.assertEqual(sum(before.values()) - sum(after.values()), 8)
        self.assertEqual(after.get('Get-Plain'), 1, 'Only the commented block stays reported')
        self.assertNotIn('Show-Panel', after)


class RepositoryTests(unittest.TestCase):
    def test_trace_is_defined_before_any_script_code_of_the_core(self):
        # Every catch of the core may call the trace: no script statement runs before its definition.
        text = (DEV / 'wad/Domenia-Core.ps1').read_bytes().decode('utf-8-sig')
        masked = mask_ps(text)[0]
        spans = top_level_functions(text, masked)
        definition = [start for name, start, _ in spans if name == sweep.TRACE]
        self.assertEqual(len(definition), 1)
        code, cursor = [], 0
        for _, start, end in spans:
            if start >= definition[0]:
                break
            code.append(masked[cursor:start])
            cursor = end
        script = re.sub(r'(?is)^\s*\[CmdletBinding\(\)\]\s*param\s*\(.*?\n\)', '', ''.join(code), count=1)
        self.assertEqual(script.strip(), '', 'Script code before Write-DomeniaSwallowed')

    def test_repository_is_swept(self):
        result = sweep.sweep(DEV, apply=False)
        self.assertEqual(result['Rewritten'], [], 'Run tools/sweep_swallowed.py --apply')
        reasons = {r['Reason'] for r in result['Left']}
        self.assertLessEqual(reasons, {'here-string', 'model', 'bootstrap', 'copied', 'worker-file', 'closure', 'remote'})
        self.assertIn('Invoke-DomeniaInProcessAuthProbe', result['Copied'])
        self.assertIn('Get-DomeniaStructuredError', result['Copied'])


if __name__ == '__main__':
    unittest.main()
