#!/usr/bin/env python3
"""P-CD-02: offline list of the top-level runtime functions that nothing uses. Reads files only; no PowerShell runs.

Audited definitions: the top-level functions of wad/Domenia-Core.ps1, wad/Domenia-Modules.ps1 and wad/modules/*.ps1
(the closed loader dot-sources them into one scope). Functions defined inside here-strings belong to worker code and
are not top-level.
A reference is the name of a function written as a whole word (case-insensitive) anywhere but in a comment:
  - in code: call, ${function:Name}, Add_Click and other event script blocks, & Name;
  - in a string: handler names (-SuccessHandler, -ErrorHandler, -PublishHandler, -CompleteHandler...), names given
    to Get-Command (worker helpers copied by their definition), route, palette and subscription tables;
  - in here-strings: worker code calling a function (its own comments are blanked like any other comment).
These never count: the definition itself (`function Name`, also inside a string), a reference from the function's own
body (recursion), and the closed lists `Functions=@(...)` of wad/Domenia-Modules.ps1 (they name every module function).
A function is live when it is reachable from a root: a reference outside every top-level function of a runtime file
(script code of the core, of the loader and of the modules, wad/Domenia-Start.ps1, module JSON and XAML files).
Reachability follows the references made from the body of each live function, so a function called only by dead code
is dead too ("unreachable"), next to the functions referenced nowhere ("unreferenced").
Tests and offline tooling (wad/tests, wad/maintenance, tools, engineering: .ps1 and .py, comments excluded) are
not roots: a dead function that they reach is reported separately as "tests-only". The scripts of wad/Support and of
the dev root run in their own process and are neither definitions nor references.
Limits: a name built at run time ('Complete-' + $kind) is not seen, so every finding is a candidate to read before
removing it; a homonym in a worker here-string counts as a reference to the top-level function (safe direction).
The reference tools/baselines/dead-functions-baseline.json is a ratchet keyed by function name: a new unused function
makes the audit fail, a function moving between "dead" and "tests-only" does not. --update rewrites the reference
after removals and refuses any increase.
"""
from collections import deque
from pathlib import Path
import argparse
import io
import json
import re
import sys
import tokenize

sys.path.insert(0, str(Path(__file__).resolve().parent))
from ps_sources import Enclosing, LineIndex, mask_ps, read_ps, strip_comments, top_level_functions  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
BASELINE = Path('tools/baselines/dead-functions-baseline.json')
SCHEMA = 'DomeniaDeadFunctionsBaseline/1'
LOADER = 'wad/Domenia-Modules.ps1'
NAME_RX = re.compile(r'[\w-]+')
DEFINITION_RX = re.compile(r'(?i)(?<![\w-])(?:function|filter|workflow)\s+([\w-]+)')
LOADER_LIST_RX = re.compile(r'(?i)\bFunctions\s*=\s*@\(')
TEST_ROOTS = ('wad/tests', 'wad/maintenance', 'tools', 'engineering')
TEST_SUFFIXES = ('.ps1', '.py')
SKIPPED_DIRS = {'__pycache__', '.git'}


def definition_files(root):
    return [root / 'wad/Domenia-Core.ps1', root / LOADER] + sorted((root / 'wad/modules').glob('*.ps1'))


def runtime_files(root):
    extra = [root / 'wad/Domenia-Start.ps1'] + sorted((root / 'wad/modules').glob('*.json')) + sorted((root / 'wad/modules').glob('*.xaml'))
    return [p for p in definition_files(root) + extra if p.is_file()]


def test_files(root):
    found = []
    for top in TEST_ROOTS:
        base = root / top
        if not base.is_dir():
            continue
        for path in sorted(base.rglob('*')):
            if path.is_file() and path.suffix.lower() in TEST_SUFFIXES and not (set(path.relative_to(root).parts) & SKIPPED_DIRS):
                found.append(path)
    return found


def loader_list_spans(masked):
    """[start, end) of the inside of every Functions=@(...) list of the closed loader."""
    spans = []
    for m in LOADER_LIST_RX.finditer(masked):
        depth, cur = 1, m.end()
        while cur < len(masked) and depth:
            if masked[cur] == '(':
                depth += 1
            elif masked[cur] == ')':
                depth -= 1
            cur += 1
        spans.append((m.end(), cur - 1))
    return spans


def reference_view(rel, text):
    """Text in which only references can match: comments blanked, strings kept, loader lists blanked."""
    if rel.endswith('.json') or rel.endswith('.xaml'):
        return text
    view = strip_comments(text)
    if rel == LOADER:
        chars = list(view)
        for start, end in loader_list_spans(mask_ps(text)[0]):
            for i in range(start, end):
                if chars[i] != '\n':
                    chars[i] = ' '
        view = ''.join(chars)
    return view


def python_view(text):
    """Python source without its comments (strings kept); the raw text when it does not tokenize."""
    try:
        chars = list(text)
        starts = [0]
        for line in text.split('\n'):
            starts.append(starts[-1] + len(line) + 1)
        for tok in tokenize.generate_tokens(io.StringIO(text).readline):
            if tok.type == tokenize.COMMENT:
                a = starts[tok.start[0] - 1] + tok.start[1]
                b = starts[tok.end[0] - 1] + tok.end[1]
                for i in range(a, b):
                    chars[i] = ' '
        return ''.join(chars)
    except (tokenize.TokenError, IndentationError, SyntaxError):
        return text


def references(view, known):
    """[(offset, lower name)] of the known function names written in view, definitions excluded."""
    definitions = {m.start(1) for m in DEFINITION_RX.finditer(view)}
    out = []
    for m in NAME_RX.finditer(view):
        token = m.group(0)
        start = m.start()
        stripped = token.lstrip('-')
        start += len(token) - len(stripped)
        name = stripped.rstrip('-').lower()
        if name in known and start not in definitions:
            out.append((start, name))
    return out


def analyse(root):
    """Findings, rows sorted by file and line."""
    root = Path(root)
    defs = {}
    texts = {}
    spans_by_file = {}
    for path in definition_files(root):
        if not path.is_file():
            continue
        rel = path.relative_to(root).as_posix()
        text = read_ps(path)
        texts[rel] = text
        spans = top_level_functions(text)
        spans_by_file[rel] = spans
        index = LineIndex(text)
        for name, start, _end in spans:
            defs.setdefault(name.lower(), {'Name': name, 'File': rel, 'Line': index.line(start)})
    known = set(defs)
    edges = {name: set() for name in known}
    callers = {name: set() for name in known}
    roots = set()
    for path in runtime_files(root):
        rel = path.relative_to(root).as_posix()
        text = texts.get(rel)
        if text is None:
            text = read_ps(path)
        enclosing = Enclosing(spans_by_file.get(rel, []))
        for offset, name in references(reference_view(rel, text), known):
            owner = enclosing.at(offset)
            if owner is None:
                roots.add(name)
                continue
            owner = owner.lower()
            if owner != name:
                edges[owner].add(name)
                callers[name].add(owner)
    live = reach(roots, edges)
    tested = {}
    for path in test_files(root):
        rel = path.relative_to(root).as_posix()
        raw = path.read_text(encoding='utf-8-sig', errors='replace').replace('\r\n', '\n')
        view = python_view(raw) if path.suffix.lower() == '.py' else strip_comments(raw)
        for _offset, name in references(view, known):
            if name not in live:
                tested.setdefault(name, set()).add(rel)
    test_live = reach(set(tested), edges, exclude=live)
    rows = []
    for name, info in defs.items():
        if name in live:
            continue
        dead_callers = sorted(defs[c]['Name'] for c in callers[name])
        rows.append({
            'Name': info['Name'], 'File': info['File'], 'Line': info['Line'],
            'Category': 'tests-only' if name in test_live else 'dead',
            'Kind': 'unreachable' if dead_callers else 'unreferenced',
            'Callers': dead_callers,
            'Tests': sorted(tested.get(name, set())),
        })
    rows.sort(key=lambda r: (r['File'], r['Line']))
    return rows, len(defs)


def reach(start, edges, exclude=()):
    seen = set()
    queue = deque(n for n in start if n not in exclude)
    while queue:
        name = queue.popleft()
        if name in seen:
            continue
        seen.add(name)
        for target in edges.get(name, ()):
            if target not in seen and target not in exclude:
                queue.append(target)
    return seen


def current_findings(rows):
    return {r['Name']: r['Category'] for r in rows}


def compare(current, reference):
    """Names absent from the reference (case-insensitive) and the number of reference names no longer reported."""
    ref = {k.lower() for k in reference}
    cur = {k.lower() for k in current}
    new = sorted((k for k in current if k.lower() not in ref), key=str.lower)
    return new, len(ref - cur)


def document(current, source, total_functions):
    categories = {}
    for category in current.values():
        categories[category] = categories.get(category, 0) + 1
    return {'Schema': SCHEMA, 'Source': source, 'Functions': total_functions, 'Total': len(current),
            'Categories': dict(sorted(categories.items())),
            'Findings': dict(sorted(current.items(), key=lambda kv: kv[0].lower()))}


def load(path):
    data = json.loads(Path(path).read_text(encoding='utf-8'))
    if data.get('Schema') != SCHEMA or not isinstance(data.get('Findings'), dict):
        raise ValueError('Reference des fonctions mortes illisible : ' + str(path))
    return data


def write(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, 'w', encoding='utf-8', newline='\n') as handle:
        handle.write(json.dumps(data, ensure_ascii=False, indent=1) + '\n')


def summary(rows):
    out = {}
    for r in rows:
        key = r['Category'] + '/' + r['Kind']
        out[key] = out.get(key, 0) + 1
    return dict(sorted(out.items()))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--root', type=Path, default=ROOT, help='Racine dev a auditer (par defaut : ce depot).')
    ap.add_argument('--baseline', type=Path, help='Reference (par defaut : tools/baselines/dead-functions-baseline.json sous --root).')
    ap.add_argument('--update', action='store_true', help='Abaisser la reference apres suppressions ; toute hausse est refusee.')
    ap.add_argument('--init', action='store_true', help='Creer la reference initiale (refuse si elle existe deja).')
    ap.add_argument('--source', default='', help='Libelle de la source enregistree avec --init ou --update.')
    ap.add_argument('--list', action='store_true', help='Afficher chaque fonction signalee (fichier, ligne, categorie, appelants, tests).')
    a = ap.parse_args(argv)
    root = a.root.resolve()
    baseline = a.baseline or (root / BASELINE)
    rows, total_functions = analyse(root)
    current = current_findings(rows)
    if a.list:
        for r in rows:
            detail = ''
            if r['Callers']:
                detail += ' ; appelee seulement par du code mort : ' + ', '.join(r['Callers'])
            if r['Tests']:
                detail += ' ; tests : ' + ', '.join(r['Tests'])
            print('%s:%d [%s/%s] %s%s' % (r['File'], r['Line'], r['Category'], r['Kind'], r['Name'], detail))
    if a.init:
        if baseline.exists():
            print(json.dumps({'Status': 'FAIL', 'Reason': 'Reference deja presente : utiliser --update.'}, ensure_ascii=False))
            return 1
        write(baseline, document(current, a.source or 'reference initiale', total_functions))
        print(json.dumps({'Status': 'INIT', 'Total': len(current), 'Summary': summary(rows)}, ensure_ascii=False))
        return 0
    if not baseline.is_file():
        print(json.dumps({'Status': 'FAIL', 'Reason': 'Reference absente : ' + str(baseline) + ' (creer avec --init).'}, ensure_ascii=False))
        return 1
    reference = load(baseline)
    new, fixed = compare(current, reference['Findings'])
    by_name = {r['Name']: r for r in rows}
    report = {'Status': 'FAIL' if new else 'PASS', 'Functions': total_functions, 'Total': len(current),
              'Reference': reference.get('Total', 0), 'Fixed': fixed, 'Summary': summary(rows),
              'New': [{k: by_name[n][k] for k in ('Name', 'File', 'Line', 'Category', 'Kind', 'Callers', 'Tests')} for n in new]}
    if a.update:
        if new:
            report['Reason'] = 'Hausse refusee : supprimer ou raccorder les nouvelles fonctions avant d abaisser la reference.'
        else:
            write(baseline, document(current, a.source or reference.get('Source', ''), total_functions))
            report['Status'] = 'UPDATED'
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 1 if new else 0


if __name__ == '__main__':
    sys.exit(main())
