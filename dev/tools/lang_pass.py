#!/usr/bin/env python3
"""P-UI-04: French language pass over the interface texts read by TE-01 (audit_wording.py). Offline; dry-run by default.

Inventory: every interface text collected by audit_wording.collect (XAML Content/Text/Header/ToolTip, literals passed to
the status and message calls, literals assigned to Text/Content/ToolTip/Header, Title/Text of Domenia-UX.help.json), plus
the XAML accessibility attributes AutomationProperties.Name and AutomationProperties.HelpText, which mirror them.
Maps (keys = the audit text, whitespace collapsed):
  engineering/d120/programme-2026-10-08/langue-corrections-sures.json     applied by --apply;
  engineering/d120/programme-2026-10-08/langue-corrections-a-relire.json  applied only with --include-review.
Report: faulty texts without a correction, corrections refused by the checks (accents, ʼ only, vouvoiement, same
placeholders), occurrences left for a manual edit, test files that pin an old text, projected remaining audit findings.
--apply rewrites only the exact source span of each interface text. Unchanged characters keep their source form (escapes,
entities, line breaks). Inserted text is encoded for its context: a single-quoted PowerShell string doubles a ' (an ʼ
never closes it), a double-quoted one escapes ` and " and refuses a $, a XAML attribute uses entities, the help JSON is
rewritten in its own format. A change touching an escape or a line break, a text also compared in code (-eq, -like,
switch...) and every test file are left to a manual edit. Encodings (BOM) and line endings are preserved.
"""
from collections import Counter
from difflib import SequenceMatcher
from pathlib import Path
import argparse, html, json, re, sys, unicodedata

sys.path.insert(0, str(Path(__file__).resolve().parent))
import audit_wording as aw  # noqa: E402  (single source of the interface-text extraction)

ROOT = aw.ROOT
MAP_DIR = Path('engineering/d120/programme-2026-10-08')
SURE_MAP = MAP_DIR / 'langue-corrections-sures.json'
REVIEW_MAP = MAP_DIR / 'langue-corrections-a-relire.json'
TESTS_DIR = Path('wad/tests')

A11Y_RX = re.compile(r'(?<=\s)AutomationProperties\.(Name|HelpText)="([^"]*)"')
ENTITY_RX = re.compile(r'&(#[xX][0-9a-fA-F]+|#\d+|\w+);')
TOKEN_RX = re.compile(r'\w+|\s+|[^\w\s]')
PLACEHOLDER_RX = re.compile(r'\$\{[^}]*\}|\$\((?:[^()]|\([^()]*\))*\)|\$[\w:]+|\{\d+(?:[,:][^}]*)?\}')
COMPARE_BEFORE_RX = re.compile(r'-[ci]?(?:eq|ne|like|notlike|match|notmatch|contains|notcontains|in|notin|replace)\s*$', re.I)
COMPARE_AFTER_RX = re.compile(r'^\s*-[ci]?(?:eq|ne|like|notlike|match|notmatch|contains|notcontains|in|notin)\b', re.I)
SWITCH_CASE_RX = re.compile(r'^\s*\{')
TYPOGRAPHIC_QUOTES = '‘’‚‛“”„'
PS_SPECIAL_ESCAPES = set('0abefnrtuv')


class Manual(Exception):
    """The occurrence cannot be rewritten safely; the reason goes to the report."""


def clean(text):
    """The audit key of a text (aw.findings collapses whitespace the same way)."""
    return ' '.join(text.split())


# ---------------------------------------------------------------- checks of a correction

def text_faults(text):
    """Audit rules (TE-01) still matched by a text: {rule: [words]}."""
    hits = {}
    for m in aw.ACCENT_RX.finditer(text):
        hits.setdefault('accent', set()).add(m.group(1))
    for m in aw.ELISION_RX.finditer(text):
        hits.setdefault('elision', set()).add(m.group(0).strip())
    for rx in aw.SECOND_RX:
        for m in rx.finditer(text):
            hits.setdefault('tutoiement', set()).add(m.group(0).strip(' .!?:;'))
    return {rule: sorted(words) for rule, words in sorted(hits.items())}


def placeholders(text):
    return Counter(PLACEHOLDER_RX.findall(text))


def fold(text):
    """Text without diacritics, apostrophes as spaces: equal folds mean a purely typographic correction."""
    text = unicodedata.normalize('NFD', text)
    text = ''.join(c for c in text if not unicodedata.combining(c))
    for c in "'ʼ’":
        text = text.replace(c, ' ')
    return clean(text)


def check_pair(old, new):
    """(errors, warnings) of a proposed correction. Errors refuse the pair; warnings send it to human review."""
    errors, warnings = [], []
    if not isinstance(new, str) or not new.strip():
        return ['texte vide'], warnings
    if new == old:
        errors.append('aucun changement')
    if new != clean(new):
        errors.append('espaces non normalises')
    if any(c in new for c in TYPOGRAPHIC_QUOTES):
        errors.append('guillemet typographique (delimiteur PowerShell)')
    if "'" in new:
        errors.append("apostrophe ' (utiliser U+02BC)")
    if placeholders(old) != placeholders(new):
        errors.append('variables ou parametres modifies')
    for rule, words in text_faults(new).items():
        errors.append('audit %s : %s' % (rule, ', '.join(words)))
    if fold(old) != fold(new):
        warnings.append('reformulation (pas seulement accents et apostrophes)')
    if len(new) > len(old) * 1.4 + 10:
        warnings.append('texte nettement plus long')
    return errors, warnings


def load_maps(root, sure=None, review=None):
    """{old: (new, origin)} of both maps; the safe map wins over the review map for a key present in both."""
    out = {}
    for origin, path in (('a-relire', review or root / REVIEW_MAP), ('sures', sure or root / SURE_MAP)):
        data = json.loads(Path(path).read_text(encoding='utf-8-sig'))
        if not isinstance(data, dict):
            raise ValueError('Table de corrections illisible : ' + str(path))
        for old, new in data.items():
            out[old] = (new, origin)
    return out


# ---------------------------------------------------------------- decoding with source positions

def segments_single(body):
    """[(char, start, end, canonical)] of a single-quoted PowerShell string body ('' is one quote)."""
    out, i = [], 0
    while i < len(body):
        if body[i] == "'" and i + 1 < len(body) and body[i + 1] == "'":
            out.append(("'", i, i + 2, True)); i += 2; continue
        out.append((body[i], i, i + 1, True)); i += 1
    return out


def segments_double(body):
    """Same for a double-quoted body. `n, `r, `t... are lossy in the audit text: never rewritten automatically."""
    out, i = [], 0
    while i < len(body):
        c = body[i]
        if c == '"' and i + 1 < len(body) and body[i + 1] == '"':
            out.append(('"', i, i + 2, True)); i += 2; continue
        if c == '`' and i + 1 < len(body):
            nxt = body[i + 1]
            out.append((nxt, i, i + 2, nxt not in PS_SPECIAL_ESCAPES)); i += 2; continue
        out.append((c, i, i + 1, True)); i += 1
    return out


def segments_xaml(body):
    """Same for a XAML attribute value; an entity is canonical only when encode_xaml would produce it."""
    out, i = [], 0
    while i < len(body):
        m = ENTITY_RX.match(body, i) if body[i] == '&' else None
        if m:
            ch = html.unescape(m.group(0))
            if len(ch) != 1:
                raise Manual('entite XAML inconnue ' + m.group(0))
            out.append((ch, i, m.end(), encode_xaml(ch) == m.group(0))); i = m.end(); continue
        out.append((body[i], i, i + 1, True)); i += 1
    return out


def segments_plain(body):
    return [(c, i, i + 1, True) for i, c in enumerate(body)]


def collapse(segments):
    """Segments of the audit text: whitespace runs become one space spanning the run, ends are stripped.
    A run is canonical only when it is a single ordinary space."""
    out, i, n = [], 0, len(segments)
    while i < n:
        if segments[i][0].isspace():
            j = i
            while j < n and segments[j][0].isspace():
                j += 1
            if out and j < n:
                single = (j - i == 1) and segments[i][0] == ' ' and segments[i][3]
                out.append((' ', segments[i][1], segments[j - 1][2], single))
            i = j
            continue
        out.append(segments[i]); i += 1
    return out


# ---------------------------------------------------------------- encoders of inserted text

def encode_single(text):
    if any(c in text for c in TYPOGRAPHIC_QUOTES):
        raise Manual('guillemet typographique dans une chaine PowerShell')
    return text.replace("'", "''")


def encode_double(text):
    if any(c in text for c in TYPOGRAPHIC_QUOTES):
        raise Manual('guillemet typographique dans une chaine PowerShell')
    if '$' in text:
        raise Manual('variable ajoutee ou deplacee dans une chaine entre guillemets doubles')
    return text.replace('`', '``').replace('"', '`"')


def encode_xaml(text):
    return text.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;').replace('"', '&quot;')


def encode_plain(text):
    return text


# ---------------------------------------------------------------- diff and rewrite

def diff_ops(old, new):
    """Non-equal opcodes between two texts: word-level alignment refined to characters inside replaced words."""
    a, b = list(TOKEN_RX.finditer(old)), list(TOKEN_RX.finditer(new))
    sm = SequenceMatcher(None, [m.group(0) for m in a], [m.group(0) for m in b], autojunk=False)
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag == 'equal':
            continue
        os_ = a[i1].start() if i1 < len(a) else len(old)
        oe = a[i2 - 1].end() if i2 > i1 else os_
        ns = b[j1].start() if j1 < len(b) else len(new)
        ne = b[j2 - 1].end() if j2 > j1 else ns
        if tag == 'replace':
            sub = SequenceMatcher(None, old[os_:oe], new[ns:ne], autojunk=False)
            for t, x1, x2, y1, y2 in sub.get_opcodes():
                if t != 'equal':
                    yield t, os_ + x1, os_ + x2, ns + y1, ns + y2
        else:
            yield tag, os_, oe, ns, ne


def rewrite(body, segments, new, encode):
    """New source body: segments describe the audit text (clean) of body; only the differing spans change."""
    old = ''.join(s[0] for s in segments)
    if old != clean(old):
        raise Manual('texte non normalisable')
    edits = []
    for tag, i1, i2, j1, j2 in diff_ops(old, new):
        if any(not segments[k][3] for k in range(i1, i2)):
            raise Manual('correction sur un echappement ou un saut de ligne')
        enc = encode(new[j1:j2])
        if i2 > i1:
            start, end = segments[i1][1], segments[i2 - 1][2]
        else:
            start = end = segments[i1][1] if i1 < len(segments) else (segments[-1][2] if segments else 0)
        edits.append((start, end, enc))
    out, last = [], 0
    for start, end, enc in sorted(edits):
        if start < last:
            raise Manual('modifications superposees')
        out.append(body[last:start]); out.append(enc); last = end
    out.append(body[last:])
    return ''.join(out)


# ---------------------------------------------------------------- inventory

def literal_spans(line, pos):
    """(start, end, quote) of the literals call_literals reads after pos; same scan, positions kept."""
    out, i, n, depth = [], pos, len(line), 0
    while i < n:
        c = line[i]
        if c in '\'"':
            j = i + 1
            while j < n:
                if line[j] == c:
                    if j + 1 < n and line[j + 1] == c:
                        j += 2; continue
                    break
                if c == '"' and line[j] == '`' and j + 1 < n:
                    j += 2; continue
                j += 1
            out.append((i, j, c)); i = j + 1; continue
        if c in '({':
            depth += 1
        elif c in ')}':
            if depth == 0:
                break
            depth -= 1
        elif c == ';' and depth == 0:
            break
        i += 1
    return out


def _occ(rel, line, kind, value, body, segments, encode, start=None, end=None, slot=None, note=None):
    return {'File': rel, 'Line': line, 'Kind': kind, 'Value': value, 'Text': clean(value), 'Body': body,
            'Segments': segments, 'Encode': encode, 'Start': start, 'End': end, 'Slot': slot, 'Manual': note}


def _xaml_occurrences(rel, text, line_of, regex, prefix):
    out = []
    for m in regex.finditer(text):
        body = m.group(2)
        value = html.unescape(body)
        if not value.strip() or value.lstrip().startswith('{'):
            continue
        note, segs = None, []
        try:
            segs = segments_xaml(body)
            if ''.join(s[0] for s in segs) != value:
                raise Manual('decodage XAML different de l audit')
            segs = collapse(segs)
        except Manual as exc:
            note = str(exc)
        out.append(_occ(rel, line_of(m.start()), prefix + m.group(1), value, body, segs, encode_xaml,
                        m.start(2), m.end(2), note=note))
    return out


def file_occurrences(root, rel):
    """Occurrences of a source file, in the order and with the values of aw.collect, plus accessibility attributes."""
    path = root / rel
    text = path.read_text(encoding='utf-8-sig')
    starts = [0] + [m.end() for m in re.finditer('\n', text)]

    def line_of(pos):
        lo, hi = 0, len(starts) - 1
        while lo < hi:
            mid = (lo + hi + 1) // 2
            if starts[mid] <= pos:
                lo = mid
            else:
                hi = mid - 1
        return lo + 1
    out = _xaml_occurrences(rel, text, line_of, aw.XAML_RX, '')
    out += _xaml_occurrences(rel, text, line_of, A11Y_RX, 'a11y.')
    if path.suffix != '.ps1':
        return out
    for number, line in enumerate(text.split('\n'), 1):
        stripped = line.lstrip()
        if stripped.startswith('#') or stripped.startswith('function '):
            continue
        offset = starts[number - 1]
        matches = [(m, m.group(1) or 'MessageBox') for m in aw.CALL_RX.finditer(line)]
        matches += [(m, 'assign.' + m.group(1)) for m in aw.ASSIGN_RX.finditer(line)]
        for m, kind in matches:
            expected = aw.call_literals(line[m.end():])
            spans = []
            for s, e, q in literal_spans(line, m.end()):
                body = line[s + 1:e]
                segs = segments_single(body) if q == "'" else segments_double(body)
                value = ''.join(x[0] for x in segs)
                if value.strip() and value.strip().upper() not in aw.LEVELS:
                    spans.append((s, e, q, body, segs, value))
            located = [x[5] for x in spans] == expected
            for s, e, q, body, segs, value in spans:
                note = None
                if not located:
                    note = 'litteral non localise de facon sure'
                elif e >= len(line) or line[e] != q:
                    note = 'chaine non terminee sur la ligne'
                out.append(_occ(rel, number, kind, value, body, collapse(segs),
                                encode_single if q == "'" else encode_double,
                                offset + s + 1, offset + e, note=note))
            if not located:
                for value in expected:
                    if value not in [x[5] for x in spans]:
                        out.append(_occ(rel, number, kind, value, None, [], None, note='litteral non localise'))
    return out


def help_occurrences(root, rel):
    path = root / rel
    raw = path.read_text(encoding='utf-8')
    data = json.loads(raw.lstrip('﻿'))
    same_format = json.dumps(data, ensure_ascii=False, indent=2) + '\n' == raw.lstrip('﻿')
    out = []
    for index, entry in enumerate(data):
        for key in ('Title', 'Text'):
            value = entry.get(key) if isinstance(entry, dict) else None
            if isinstance(value, str) and value.strip():
                out.append(_occ(rel, index + 1, 'help.' + key, value, value, collapse(segments_plain(value)), encode_plain,
                                slot=(index, key), note=None if same_format else 'format JSON de l aide non reconnu'))
    return out


def inventory(root):
    """All occurrences, and the audit items (aw.collect) that could not be matched to one."""
    root = Path(root)
    sources = ([root / 'wad/Domenia-Core.ps1', root / 'wad/Domenia-Start.ps1'] + sorted((root / 'wad/modules').glob('*.ps1')) +
               sorted((root / 'wad/modules').glob('*.xaml')))
    occ = []
    for path in sources:
        if path.is_file():
            occ += file_occurrences(root, path.relative_to(root).as_posix())
    help_path = root / 'wad/modules/Domenia-UX.help.json'
    if help_path.is_file():
        occ += help_occurrences(root, help_path.relative_to(root).as_posix())
    ours = Counter((o['File'], o['Line'], o['Kind'], o['Value']) for o in occ if not o['Kind'].startswith('a11y.'))
    theirs = Counter(aw.collect(root))
    missing = theirs - ours
    for (rel, line, kind, value), count in missing.items():
        for _ in range(count):
            occ.append(_occ(rel, line, kind, value, None, [], None, note='texte de l audit non localise'))
    return occ


# ---------------------------------------------------------------- references outside interface positions

def _quoted_forms(value):
    forms = ["'" + value.replace("'", "''") + "'"]
    if '`' not in value and '$' not in value and '"' not in value:
        forms.append('"' + value + '"')
    return forms


def code_comparisons(root, values, spans):
    """{value: ['file:line']} where a value is compared in code (wad .ps1 outside tests), excluding the edited spans."""
    root = Path(root)
    out = {}
    files = [p for p in sorted((root / 'wad').rglob('*.ps1')) if TESTS_DIR.as_posix() not in p.relative_to(root).as_posix()]
    for path in files:
        rel = path.relative_to(root).as_posix()
        text = path.read_text(encoding='utf-8-sig')
        for value in values:
            for form in _quoted_forms(value):
                for m in re.finditer(re.escape(form), text):
                    if (rel, m.start() + 1) in spans:
                        continue
                    line_start = text.rfind('\n', 0, m.start()) + 1
                    line_end = text.find('\n', m.end())
                    before = text[line_start:m.start()]
                    after = text[m.end():line_end if line_end >= 0 else len(text)]
                    if COMPARE_BEFORE_RX.search(before) or COMPARE_AFTER_RX.match(after) or \
                            (SWITCH_CASE_RX.match(after) and not before.strip()):
                        out.setdefault(value, []).append('%s:%d' % (rel, text.count('\n', 0, m.start()) + 1))
    return out


def test_references(root, values):
    """{value: ['file:line']} for every test file (wad/tests) containing the old text, raw or single-quoted."""
    root = Path(root)
    out = {}
    tests = root / TESTS_DIR
    if not tests.is_dir():
        return out
    for path in sorted(p for p in tests.rglob('*') if p.is_file() and p.suffix in ('.ps1', '.py', '.json', '.txt', '.xaml')):
        rel = path.relative_to(root).as_posix()
        lines = path.read_text(encoding='utf-8-sig', errors='replace').split('\n')
        for value in values:
            forms = {value, value.replace("'", "''"), encode_xaml(value)}
            for number, line in enumerate(lines, 1):
                if any(f in line for f in forms):
                    out.setdefault(value, []).append('%s:%d' % (rel, number))
    return out


# ---------------------------------------------------------------- plan and apply

def plan(root, maps, include_review=False):
    """Edits per occurrence and the full report (no file is written). Review pairs are applied only on request."""
    root = Path(root)
    occ = inventory(root)
    rows = aw.findings(root)
    faulty = {}
    for r in rows:
        faulty.setdefault(r['Text'], {'Rules': set(), 'Words': set(), 'Places': []})
        faulty[r['Text']]['Rules'].add(r['Rule'])
        faulty[r['Text']]['Words'].update(r['Words'])
        place = '%s:%d' % (r['File'], r['Line'])
        if place not in faulty[r['Text']]['Places']:
            faulty[r['Text']]['Places'].append(place)
    texts = {o['Text'] for o in occ}
    refused, accepted = [], {}
    for old in sorted(texts):
        if old not in maps or (maps[old][1] == 'a-relire' and not include_review):
            continue
        new, origin = maps[old]
        errors, warnings = check_pair(old, new)
        if errors:
            refused.append({'Text': old, 'New': new, 'Map': origin, 'Errors': errors})
        else:
            accepted[old] = (new, origin, warnings)
    spans = {(o['File'], o['Start']) for o in occ if o['Text'] in accepted and o['Start'] is not None}
    compared = code_comparisons(root, sorted({o['Value'] for o in occ if o['Text'] in accepted}), spans)
    edits, manual = [], []
    for o in occ:
        if o['Text'] not in accepted:
            continue
        new = accepted[o['Text']][0]
        try:
            if o['Manual']:
                raise Manual(o['Manual'])
            if o['Value'] in compared:
                raise Manual('texte compare dans le code : ' + ', '.join(compared[o['Value']][:3]))
            body = rewrite(o['Body'], o['Segments'], new, o['Encode'])
            edits.append(dict(o, NewBody=body, New=new, Map=accepted[o['Text']][1]))
        except Manual as exc:
            manual.append({'File': o['File'], 'Line': o['Line'], 'Kind': o['Kind'], 'Text': o['Text'], 'New': new,
                           'Reason': str(exc)})
    # A text is rewritten everywhere or nowhere: ToolTip, AutomationProperties.HelpText and the help JSON must stay equal.
    held = {m['Text'] for m in manual}
    for e in [e for e in edits if e['Text'] in held]:
        edits.remove(e)
        manual.append({'File': e['File'], 'Line': e['Line'], 'Kind': e['Kind'], 'Text': e['Text'], 'New': e['New'],
                       'Reason': 'retenu : une autre occurrence du meme texte demande une correction manuelle'})
    tests = test_references(root, sorted({e['Value'] for e in edits}))
    planned = Counter((e['File'], e['Line'], e['Kind'], e['Text']) for e in edits)
    remaining = 0
    for r in rows:
        key = (r['File'], r['Line'], r['Kind'], r['Text'])
        if planned[key] > 0:
            continue
        remaining += 1
    uncovered = [{'Text': t, 'Rules': sorted(v['Rules']), 'Words': sorted(v['Words']), 'Places': v['Places']}
                 for t, v in sorted(faulty.items()) if t not in maps]
    a11y_faulty = sorted({o['Text'] for o in occ if o['Kind'].startswith('a11y.') and text_faults(o['Text'])})
    report = {
        'Inventory': {'Occurrences': len(occ), 'Texts': len(texts), 'AuditFindings': len(rows), 'FaultyTexts': len(faulty)},
        'Coverage': {'Sure': sum(1 for t in faulty if t in maps and maps[t][1] == 'sures'),
                     'Review': sum(1 for t in faulty if t in maps and maps[t][1] == 'a-relire'),
                     'Uncovered': len(uncovered),
                     'AccessibilityFaultyUncovered': sum(1 for t in a11y_faulty if t not in maps)},
        'Planned': {'Edits': len(edits), 'Files': dict(sorted(Counter(e['File'] for e in edits).items())),
                    'AuditFindingsAfter': remaining},
        'Uncovered': uncovered,
        'Refused': refused,
        'ToReview': [{'Text': t, 'New': v[0], 'Map': v[1], 'Warnings': v[2]} for t, v in sorted(accepted.items()) if v[2]],
        'Manual': manual,
        'Tests': [{'Text': v, 'New': maps[clean(v)][0], 'References': refs} for v, refs in sorted(tests.items())],
    }
    return edits, report


def _write_text(path, text, original_bytes):
    data = text.encode('utf-8')
    if original_bytes.startswith(b'\xef\xbb\xbf'):
        data = b'\xef\xbb\xbf' + data
    path.write_bytes(data)


def apply(root, edits):
    """Write the planned edits; returns the files written."""
    root = Path(root)
    by_file = {}
    for e in edits:
        by_file.setdefault(e['File'], []).append(e)
    written = []
    for rel, items in sorted(by_file.items()):
        path = root / rel
        original = path.read_bytes()
        text = original.decode('utf-8-sig')
        if items[0]['Slot'] is not None:
            data = json.loads(text)
            for e in items:
                index, key = e['Slot']
                if data[index][key] != e['Value']:
                    raise RuntimeError('Aide modifiee pendant la passe : %s %s' % (rel, e['Line']))
                data[index][key] = e['NewBody']
            _write_text(path, json.dumps(data, ensure_ascii=False, indent=2) + '\n', original)
        else:
            out, last = [], 0
            for e in sorted(items, key=lambda x: x['Start']):
                if e['Start'] < last or text[e['Start']:e['End']] != e['Body']:
                    raise RuntimeError('Source modifiee ou chevauchement : %s:%d' % (rel, e['Line']))
                out.append(text[last:e['Start']]); out.append(e['NewBody']); last = e['End']
            out.append(text[last:])
            _write_text(path, ''.join(out), original)
        written.append(rel)
    return written


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--root', type=Path, default=ROOT, help='Racine dev (par defaut : ce depot).')
    ap.add_argument('--map', type=Path, help='Table sure (par defaut : %s).' % SURE_MAP.as_posix())
    ap.add_argument('--review-map', type=Path, help='Table a relire (par defaut : %s).' % REVIEW_MAP.as_posix())
    ap.add_argument('--include-review', action='store_true', help='Appliquer aussi la table a relire (apres decision).')
    ap.add_argument('--apply', action='store_true', help='Ecrire les corrections dans les sources (sinon : simulation).')
    ap.add_argument('--uncovered-json', type=Path, help='Ecrire la liste des textes fautifs sans correction (JSON).')
    ap.add_argument('--report', type=Path, help='Ecrire le rapport complet (JSON).')
    a = ap.parse_args(argv)
    root = a.root.resolve()
    maps = load_maps(root, a.map, a.review_map)
    edits, report = plan(root, maps, a.include_review)
    report['Status'] = 'DRY-RUN'
    if a.apply:
        report['Written'] = apply(root, edits)
        report['AuditFindingsNow'] = len(aw.findings(root))
        report['Status'] = 'APPLIED'
    if a.uncovered_json:
        a.uncovered_json.write_text(json.dumps([u['Text'] for u in report['Uncovered']], ensure_ascii=False, indent=1) + '\n',
                                    encoding='utf-8')
    if a.report:
        a.report.write_text(json.dumps(report, ensure_ascii=False, indent=1) + '\n', encoding='utf-8')
    summary = {k: report[k] for k in ('Status', 'Inventory', 'Coverage', 'Planned')}
    summary.update({'Refused': len(report['Refused']), 'ToReview': len(report['ToReview']), 'Manual': len(report['Manual']),
                    'TestsToUpdate': len(report['Tests'])})
    for k in ('Written', 'AuditFindingsNow'):
        if k in report:
            summary[k] = report[k]
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0


if __name__ == '__main__':
    sys.exit(main())
