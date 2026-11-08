#!/usr/bin/env python3
"""P-CD-09: rewrites the empty catch blocks of the runtime scripts into a trace of the swallowed error.

    catch { }   becomes   catch { Write-DomeniaSwallowed '<Category>' '<Function>' $_ }

and, in a pure rule (*.Model.ps1), which also runs in worker runspaces and in benches without the core:

    catch { }   becomes   catch { if (${function:Write-DomeniaRuleSwallowed}) { Write-DomeniaRuleSwallowed '<Category>' '<Function>' $_ } }

(Domenia-Common.Model.ps1: the trace of the core when it is reachable, else the in-memory ring; the guard keeps a bench
that loads a rule without Common.Model as it was).
Category is the module of the file (Domenia-Core.ps1 gives Core, Domenia-Storage.UI.ps1 gives Storage), Function the
top-level function that contains the catch (the file name for script code). The spacing of the block is kept
(catch{} gives catch{Write-DomeniaSwallowed ...}); a block written on one line stays on its line, so line numbers do not
move (an empty block spread over several lines gets the call on a line of its own). The BOM and the line endings of
each file are kept.
Deterministic and idempotent: a second run finds nothing to rewrite. Only EMPTY blocks are rewritten (no comment, no
statement); a block that already returns a fallback, sets a variable or traces is never touched. Reads and writes files
only; no PowerShell is executed. Without --apply nothing is written.

Write-DomeniaSwallowed exists only in the script scope of Domenia-Core.ps1. A catch that runs anywhere else would throw
CommandNotFoundException from inside the catch, so these blocks are left as they are and listed (--list) with a reason:
  here-string  worker code (here-string bodies, pinned by SHA-256), run in a runspace without the core;
  worker-file  *.Worker.ps1 (worker operations);
  bootstrap    Domenia-Start.ps1 and Domenia-Modules.ps1 (before or while the core loads);
  copied       a function whose definition is copied as text into another runspace (Get-Command ... .Definition);
  closure      a scriptblock bound by .GetNewClosure(): its dynamic module does not see the core script scope;
  remote       a scriptblock given to -ScriptBlock, -InitializationScript, AddScript(, Start-Job or Invoke-Command;
  early        script code of the core placed before the definition of Write-DomeniaSwallowed;
  exempt       the trace functions themselves (tools/audit_swallowed.py EXEMPT).
Scripts outside the core that run swept code (functions extracted from its syntax tree, UI modules dot-sourced: offline
previews, cache backup, automation interface, native parser check) load the core's own Write-DomeniaSwallowed first;
tools/tests/test_sweep_swallowed.py checks every such script.
"""
from pathlib import Path
import argparse
import json
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from audit_swallowed import CATCH_RX, EXEMPT, audited_files  # noqa: E402
from ps_sources import Enclosing, LineIndex, mask_ps, matching_brace, strip_comments, top_level_functions  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
TRACE = 'Write-DomeniaSwallowed'
RULE_TRACE = 'Write-DomeniaRuleSwallowed'
BOM = b'\xef\xbb\xbf'
BOOTSTRAP = ('Domenia-Start.ps1', 'Domenia-Modules.ps1')
CLOSURE_RX = re.compile(r'\s*\.GetNewClosure\s*\(')
REMOTE_RX = re.compile(r'(?i)(?:-ScriptBlock|-InitializationScript|\bAddScript\s*\(|\bStart-Job|\bInvoke-Command)\s*$')
COPY_NAME_RX = re.compile(r'(?i)Get-Command\s+(?:-Name\s+)?([A-Za-z][\w]*-[\w-]+)')
QUOTED_NAME_RX = re.compile(r'[\'"]([A-Za-z][\w]*-[\w-]+)[\'"]')
DEFINITION_RX = re.compile(r'\.Definition\b')
# The arguments of a trace call are a category and an operation, not a function to copy: a copier that traces its own
# catch blocks quotes its own name there, and would otherwise read as copied once swept (not stable over the output).
TRACE_CALL_RX = re.compile(r"Write-Domenia(?:Rule)?Swallowed\s+'[^']*'\s+'[^']*'")
MODULE_RX = re.compile(r'^Domenia-([A-Za-z0-9]+)\.')
REASONS = ('here-string', 'worker-file', 'bootstrap', 'copied', 'closure', 'remote', 'early', 'exempt')


def category(path):
    """Core for Domenia-Core.ps1, else the module name: Domenia-Storage.UI.ps1 gives Storage."""
    name = Path(path).name
    if name == 'Domenia-Core.ps1':
        return 'Core'
    m = MODULE_RX.match(name)
    return m.group(1) if m else Path(path).stem


def file_reason(path):
    """Reason to leave every catch of a file untouched, or None when its catches can be traced."""
    name = Path(path).name
    if name in BOOTSTRAP:
        return 'bootstrap'
    if name.endswith('.Worker.ps1'):
        return 'worker-file'
    return None


def is_rule(path):
    """A pure rule file (*.Model.ps1): its trace goes through the guarded Write-DomeniaRuleSwallowed."""
    return Path(path).name.endswith('.Model.ps1')


def read_source(path):
    """(text, has_bom) with the line endings of the file kept as they are."""
    raw = Path(path).read_bytes()
    bom = raw.startswith(BOM)
    return raw[len(BOM) if bom else 0:].decode('utf-8'), bom


def write_source(path, text, bom):
    Path(path).write_bytes((BOM if bom else b'') + text.encode('utf-8'))


def copied_functions(sources):
    """Names of the functions whose definition is copied as text into another runspace: in a function that reads
    (Get-Command ...).Definition, every name given to Get-Command and every quoted name of a runtime function, except
    the arguments of the trace calls written by this tool (the same answer before and after a sweep)."""
    known = set()
    for text in sources.values():
        known.update(name for name, _, _ in top_level_functions(text))
    found = set()
    for text in sources.values():
        masked = mask_ps(text)[0]
        view = strip_comments(text)
        for _, start, end in top_level_functions(text, masked):
            code = masked[start:end]
            if 'Get-Command' not in code or not DEFINITION_RX.search(code):
                continue
            body = TRACE_CALL_RX.sub('', view[start:end])
            found.update(COPY_NAME_RX.findall(body))
            found.update(name for name in QUOTED_NAME_RX.findall(body) if name in known)
    return found & known


def enclosing_blocks(masked, targets):
    """{offset of an opening brace in targets: [offsets of the opening braces that enclose it, outermost first]}."""
    wanted = set(targets)
    stack, out = [], {}
    for i, c in enumerate(masked):
        if c == '{':
            if i in wanted:
                out[i] = list(stack)
            stack.append(i)
        elif c == '}' and stack:
            stack.pop()
    return out


def context_reason(masked, opens):
    """closure or remote when one of the enclosing scriptblocks runs outside the core script scope."""
    for o in opens:
        close = matching_brace(masked, o)
        if CLOSURE_RX.match(masked, close):
            return 'closure'
        if REMOTE_RX.search(masked[max(0, o - 40):o]):
            return 'remote'
    return None


def trace_call(cat, operation, rule=False):
    if rule:
        return "if (${function:%s}) { %s '%s' '%s' $_ }" % (RULE_TRACE, RULE_TRACE, cat, operation)
    return "%s '%s' '%s' $_" % (TRACE, cat, operation)


def new_body(text, keyword, body, call):
    """Body text of the rewritten block: the spacing of the empty block is kept (catch{} and catch {} differ)."""
    if body == '':
        open_index = text.index('{', keyword)
        return ' ' + call + ' ' if text[open_index - 1] in ' \t' else call
    if '\n' not in body:
        return ' ' + call + ' '
    line_start = text.rfind('\n', 0, keyword) + 1
    indent = re.match(r'[ \t]*', text[line_start:]).group(0)
    return '\n' + indent + '    ' + call + body[body.rindex('\n'):]


def plan_file(path, root, text, copied):
    """(rewritten text, [rewritten rows], [left-out rows]) for one file; rows are dicts File, Line, Function, Reason."""
    rel = Path(path).relative_to(root).as_posix()
    masked = mask_ps(text)[0]
    spans = top_level_functions(text, masked)
    enclosing = Enclosing(spans)
    index = LineIndex(text)
    definition = min([start for name, start, _ in spans if name == TRACE], default=None)
    whole = file_reason(path)
    cat = category(path)
    matches = []
    for m in CATCH_RX.finditer(masked):
        open_index = m.end() - 1
        close = matching_brace(masked, open_index)
        if text[open_index + 1:close - 1].strip() == '':
            matches.append((m.start(), open_index, close))
    parents = enclosing_blocks(masked, [o for _, o, _ in matches])
    rewritten, left, edits = [], [], []
    for keyword, open_index, close in matches:
        owner = enclosing.at(keyword)
        row = {'File': rel, 'Line': index.line(keyword), 'Function': owner or ''}
        reason = whole
        if reason is None and owner in EXEMPT:
            reason = 'exempt'
        if reason is None and owner in copied:
            reason = 'copied'
        if reason is None:
            reason = context_reason(masked, parents.get(open_index, []))
        if reason is None and owner is None and definition is not None and keyword < definition:
            reason = 'early'
        if reason:
            row['Reason'] = reason
            left.append(row)
            continue
        operation = owner or Path(path).name
        body = text[open_index + 1:close - 1]
        edits.append((open_index + 1, close - 1, new_body(text, keyword, body, trace_call(cat, operation, is_rule(path)))))
        row['Category'] = cat
        rewritten.append(row)
    out = text
    for start, end, value in sorted(edits, reverse=True):
        out = out[:start] + value + out[end:]
    return out, rewritten, left


def here_string_rows(root):
    """Empty or discard catches inside here-strings (worker code), from the audit: they are never rewritten."""
    from audit_swallowed import findings
    return [{'File': r['File'], 'Line': r['Line'], 'Function': r['Function'], 'Reason': 'here-string'}
            for r in findings(root) if r['HereString'] and r['Kind'] == 'empty']


def sweep(root, apply=False):
    root = Path(root)
    paths = audited_files(root)
    sources = {p: read_source(p) for p in paths}
    copied = copied_functions({p: t for p, (t, _) in sources.items()})
    rewritten, left, changed = [], [], []
    for path in paths:
        text, bom = sources[path]
        out, done, kept = plan_file(path, root, text, copied)
        rewritten.extend(done)
        left.extend(kept)
        if out != text:
            changed.append(path.relative_to(root).as_posix())
            if apply:
                write_source(path, out, bom)
    left.extend(here_string_rows(root))
    left.sort(key=lambda r: (r['File'], r['Line']))
    return {'Rewritten': rewritten, 'Left': left, 'Changed': changed, 'Copied': sorted(copied)}


def summary(result, status):
    by_file, by_reason = {}, {reason: 0 for reason in REASONS}
    for r in result['Rewritten']:
        by_file[r['File']] = by_file.get(r['File'], 0) + 1
    for r in result['Left']:
        by_reason[r['Reason']] = by_reason.get(r['Reason'], 0) + 1
    return {'Status': status, 'Rewritten': len(result['Rewritten']), 'Files': dict(sorted(by_file.items())),
            'Left': len(result['Left']), 'LeftByReason': {k: v for k, v in by_reason.items() if v},
            'CopiedFunctions': result['Copied']}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--root', type=Path, default=ROOT, help='Racine dev a traiter (par defaut : ce depot).')
    ap.add_argument('--apply', action='store_true', help='Ecrire les fichiers ; sans cette option, simple plan.')
    ap.add_argument('--list', action='store_true', help='Afficher chaque catch vide laisse tel quel, avec sa raison.')
    a = ap.parse_args(argv)
    result = sweep(a.root.resolve(), apply=a.apply)
    if a.list:
        for r in result['Left']:
            print('%s:%d [%s] %s' % (r['File'], r['Line'], r['Reason'], r['Function'] or '<script>'))
    print(json.dumps(summary(result, 'APPLIED' if a.apply else 'PLAN'), ensure_ascii=False, indent=2))
    return 0


if __name__ == '__main__':
    sys.exit(main())
