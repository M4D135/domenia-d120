#!/usr/bin/env python3
"""P-CD-09: offline list of the catch blocks that swallow an error. Reads files only; no PowerShell is executed.

Audited scripts: wad/Domenia-Core.ps1, wad/Domenia-Start.ps1, wad/Domenia-Modules.ps1 and wad/modules/*.ps1, script
code and here-string bodies (worker code, lexed again as PowerShell). A catch block swallows when its body, once its
comments are removed, is:
  empty    nothing at all: catch { };
  comment  only comments: catch { # ignored };
  null     only explicit discards: $null, $null = $_, [void]$_, $_ | Out-Null (one or several statements).
A catch that returns a fallback value, sets a variable or calls Write-DomeniaSwallowed is not reported.
Each finding is keyed by the top-level function that contains it ('<file>|<script>' for script code), with
' [here-string]' appended for worker code, so a catch moving inside its function or a function moving between files
changes nothing. The reference tools/baselines/swallowed-baseline.json is a ratchet: one more swallowing catch in a key
makes the audit fail (the report lists every catch of that key under New, since the added one cannot be told apart);
--update rewrites the reference after corrections and refuses any increase.
Not audited: catch blocks inside ordinary one-line strings, trap statements, and scripts outside the runtime above.
Write-DomeniaSwallowed itself is exempt (EXEMPT below): the trace of a swallowed error cannot trace its own failure.
"""
from pathlib import Path
import argparse
import json
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from ps_sources import (Enclosing, HERE_STRINGS, LineIndex, here_string_body, mask_ps, matching_brace, read_ps,  # noqa: E402
                        segments, strip_comments, top_level_functions)

ROOT = Path(__file__).resolve().parents[1]
BASELINE = Path('tools/baselines/swallowed-baseline.json')
SCHEMA = 'DomeniaSwallowedBaseline/1'
HERE = ' [here-string]'
EXEMPT = {'Write-DomeniaSwallowed': 'Trace d une erreur ignoree : elle ne peut pas tracer son propre echec et ne leve jamais.'}
CATCH_RX = re.compile(r'(?i)(?<![\w$.:-])catch(?:\s*\[[^\]\r\n]*\](?:\s*,\s*\[[^\]\r\n]*\])*)?\s*\{')
DISCARD_RX = re.compile(r'(?i)^(?:\$null|\$null\s*=\s*\$_|\[void\]\s*\$_|\$_\s*\|\s*Out-Null)$')


def audited_files(root):
    paths = [root / 'wad/Domenia-Core.ps1', root / 'wad/Domenia-Start.ps1', root / 'wad/Domenia-Modules.ps1']
    return [p for p in paths + sorted((root / 'wad/modules').glob('*.ps1')) if p.is_file()]


def classify(body, raw):
    """'empty', 'comment' or 'null' for a swallowing body (comments blanked in body, raw keeps them); None otherwise."""
    statements = [s.strip() for s in re.split(r'[;\n]', body) if s.strip()]
    if not statements:
        return 'comment' if raw.strip() else 'empty'
    if all(DISCARD_RX.match(s) for s in statements):
        return 'null'
    return None


def catch_blocks(text, offset=0, here=False):
    """[(absolute offset, kind, here)] of the swallowing catch blocks of text and of its here-string bodies."""
    masked = mask_ps(text)[0]
    view = strip_comments(text)
    found = []
    for m in CATCH_RX.finditer(masked):
        open_index = m.end() - 1
        close = matching_brace(masked, open_index)
        kind = classify(view[open_index + 1:close - 1], text[open_index + 1:close - 1])
        if kind:
            found.append((offset + m.start(), kind, here))
    for seg_kind, start, end in segments(text):
        if seg_kind in HERE_STRINGS:
            body_start, body_end = here_string_body(text, start, end)
            if body_end > body_start:
                found.extend(catch_blocks(text[body_start:body_end], offset + body_start, True))
    return found


def findings(root):
    root = Path(root)
    rows = []
    for path in audited_files(root):
        rel = path.relative_to(root).as_posix()
        text = read_ps(path)
        enclosing = Enclosing(top_level_functions(text))
        index = LineIndex(text)
        for position, kind, here in catch_blocks(text):
            owner = enclosing.at(position)
            rows.append({'File': rel, 'Line': index.line(position), 'Function': owner or '', 'Kind': kind, 'HereString': here,
                         'Key': (owner or (rel + '|<script>')) + (HERE if here else ''), 'Exempt': owner in EXEMPT})
    rows.sort(key=lambda r: (r['File'], r['Line']))
    return rows


def counts(rows):
    out = {}
    for r in rows:
        if not r['Exempt']:
            out[r['Key']] = out.get(r['Key'], 0) + 1
    return out


def compare(current, reference):
    """Keys whose count exceeds the reference and the number of swallowing catches removed since."""
    exceeded = {k: v - reference.get(k, 0) for k, v in current.items() if v > reference.get(k, 0)}
    fixed = sum(max(0, v - current.get(k, 0)) for k, v in reference.items())
    return exceeded, fixed


def breakdown(rows):
    kinds, places = {}, {'code': 0, 'here-string': 0}
    for r in rows:
        if r['Exempt']:
            continue
        kinds[r['Kind']] = kinds.get(r['Kind'], 0) + 1
        places['here-string' if r['HereString'] else 'code'] += 1
    return dict(sorted(kinds.items())), places


def document(current, rows, source):
    kinds, places = breakdown(rows)
    return {'Schema': SCHEMA, 'Source': source, 'Total': sum(current.values()), 'Kinds': kinds, 'Places': places,
            'Findings': dict(sorted(current.items(), key=lambda kv: kv[0].lower()))}


def load(path):
    data = json.loads(Path(path).read_text(encoding='utf-8'))
    if data.get('Schema') != SCHEMA or not isinstance(data.get('Findings'), dict):
        raise ValueError('Reference des catch silencieux illisible : ' + str(path))
    return data


def write(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, 'w', encoding='utf-8', newline='\n') as handle:
        handle.write(json.dumps(data, ensure_ascii=False, indent=1) + '\n')


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--root', type=Path, default=ROOT, help='Racine dev a auditer (par defaut : ce depot).')
    ap.add_argument('--baseline', type=Path, help='Reference (par defaut : tools/baselines/swallowed-baseline.json sous --root).')
    ap.add_argument('--update', action='store_true', help='Abaisser la reference apres corrections ; toute hausse est refusee.')
    ap.add_argument('--init', action='store_true', help='Creer la reference initiale (refuse si elle existe deja).')
    ap.add_argument('--source', default='', help='Libelle de la source enregistree avec --init ou --update.')
    ap.add_argument('--list', action='store_true', help='Afficher chaque catch silencieux (fichier, ligne, fonction, nature).')
    a = ap.parse_args(argv)
    root = a.root.resolve()
    baseline = a.baseline or (root / BASELINE)
    rows = findings(root)
    current = counts(rows)
    kinds, places = breakdown(rows)
    exempt = sum(1 for r in rows if r['Exempt'])
    if a.list:
        for r in rows:
            print('%s:%d [%s%s%s] %s' % (r['File'], r['Line'], r['Kind'], ', here-string' if r['HereString'] else '',
                                         ', exempte' if r['Exempt'] else '', r['Function'] or '<script>'))
    if a.init:
        if baseline.exists():
            print(json.dumps({'Status': 'FAIL', 'Reason': 'Reference deja presente : utiliser --update.'}, ensure_ascii=False))
            return 1
        write(baseline, document(current, rows, a.source or 'reference initiale'))
        print(json.dumps({'Status': 'INIT', 'Total': sum(current.values()), 'Kinds': kinds, 'Places': places, 'Exempt': exempt}, ensure_ascii=False))
        return 0
    if not baseline.is_file():
        print(json.dumps({'Status': 'FAIL', 'Reason': 'Reference absente : ' + str(baseline) + ' (creer avec --init).'}, ensure_ascii=False))
        return 1
    reference = load(baseline)
    exceeded, fixed = compare(current, reference['Findings'])
    new = [r for r in rows if not r['Exempt'] and r['Key'] in exceeded]
    report = {'Status': 'FAIL' if exceeded else 'PASS', 'Total': sum(current.values()), 'Reference': reference.get('Total', 0),
              'Fixed': fixed, 'Kinds': kinds, 'Places': places, 'Exempt': exempt,
              'Exceeded': dict(sorted(exceeded.items())),
              'New': [{k: r[k] for k in ('File', 'Line', 'Function', 'Kind', 'HereString')} for r in new]}
    if a.update:
        if exceeded:
            report['Reason'] = 'Hausse refusee : tracer ou traiter les nouveaux catch silencieux avant d abaisser la reference.'
        else:
            write(baseline, document(current, rows, a.source or reference.get('Source', '')))
            report['Status'] = 'UPDATED'
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 1 if exceeded else 0


if __name__ == '__main__':
    sys.exit(main())
