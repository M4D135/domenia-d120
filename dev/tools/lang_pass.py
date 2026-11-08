#!/usr/bin/env python3
"""P-UI-04: French language pass over the interface texts of TE-01 (audit_wording.py). Offline; dry-run by default.

Inventory: every interface text that audit_wording reads (its own functions, nothing parsed twice: XAML Content, Text,
Header and ToolTip, literals passed to the status and message calls, literals assigned to Text, Content, ToolTip and
Header, Title and Text of Domenia-UX.help.json), plus the accessibility texts that mirror them: XAML
AutomationProperties.Name and AutomationProperties.HelpText, literals passed to AutomationProperties SetName and
SetHelpText. A ToolTip, its HelpText and its help entry are therefore corrected together or not at all.
Maps (keys = the audit text, whitespace collapsed; keys and values are normalized the same way when read):
  engineering/d120/programme-2026-10-08/langue-corrections-sures.json     accents and apostrophes, applied by --apply;
  engineering/d120/programme-2026-10-08/langue-corrections-a-relire.json  wording changes (person of the verb...),
                                                                           applied only with --include-review.
--merge FILE adds a JSON object {old: new} to the maps after the checks: a purely typographic pair goes to the safe
map, any other one to the review map; a key already mapped to another value is refused.
Report: faulty texts without a correction, pairs refused by the checks (an audit fault left, ' instead of U+02BC,
typographic quote, variables or placeholders changed), occurrences left for a manual edit, test files that pin an
old text, literal references outside the interface positions, projected audit findings after the pass.
--apply rewrites only the differing characters of each interface text. Unchanged characters keep their source form
(escapes, entities, line breaks, repeated spaces). Inserted text is encoded for its context: a single-quoted PowerShell
string doubles a ' (an ʼ never closes it), a double-quoted one escapes ` and " and refuses a $, a XAML attribute uses
entities (and refuses $ and ` inside a .ps1), the help JSON keeps its format. Left to a manual edit: a change touching an
escape or a line break, a literal that is itself a comparison operand or a key, a text whose comparison in code
(-eq, -like, -match, switch, .Contains...) would give another result once corrected, overlapping spans. Test files are
never written: they are listed. Encodings (BOM) and line endings are preserved.
Comparisons are found by literal, not by data flow: any literal equal to the text counts, whatever is compared. A key,
an index, a property name or a ContainsKey operand equal to the text is reported as a possible dependency (Possible).
A comparison read and judged unrelated to the text is recorded in
engineering/d120/programme-2026-10-08/langue-dependances-ecartees.json ({Text, File, Code, Reason}: Code is the exact
trimmed source line, so a changed line holds the text again; an entry that clears nothing is reported).
Places of the help JSON are entry numbers (the audit's convention), not file lines.
"""
from collections import Counter
from difflib import SequenceMatcher
from pathlib import Path
import argparse, html, json, re, sys, unicodedata

sys.path.insert(0, str(Path(__file__).resolve().parent))
import audit_wording as aw  # noqa: E402  (single source of the interface-text extraction and of the rules)

ROOT = aw.ROOT
MAP_DIR = Path('engineering/d120/programme-2026-10-08')
SURE_MAP = MAP_DIR / 'langue-corrections-sures.json'
REVIEW_MAP = MAP_DIR / 'langue-corrections-a-relire.json'
CLEARED = MAP_DIR / 'langue-dependances-ecartees.json'
TESTS_DIR = Path('wad/tests')
SURE, REVIEW = 'sures', 'a-relire'

A11Y_RX = re.compile(r'(?<=\s)AutomationProperties\.(Name|HelpText)="([^"]*)"')
A11Y_CALL_RX = re.compile(r'AutomationProperties\]::Set(Name|HelpText)\(')
ENTITY_RX = re.compile(r'&(#[xX][0-9a-fA-F]+|#\d+|\w+);')
TOKEN_RX = re.compile(r'\w+|\s+|[^\w\s]')
PLACEHOLDER_RX = re.compile(r'\$\{[^}]*\}|\$\((?:[^()]|\([^()]*\))*\)|\$[\w:]+|\{\d+(?:[,:][^}]*)?\}')
ESCAPED_TAIL_RX = re.compile(r'(?:rn)+[^\W\d_a-z][^\W\d_]*$')
TYPOGRAPHIC_QUOTES = '‘’‚‛“”„'
PS_SPECIAL_ESCAPES = set('0abefnrtuv')
LITERAL = r"""(?:'(?:[^']|'')*'|"(?:[^"`]|`.)*")"""

# Comparison contexts of a literal in PowerShell code: (regex on the text before it, regex on the text after it).
OPERATOR = r'-(?P<case>[ci]?)(?P<op>eq|ne|like|notlike|match|notmatch|contains|notcontains|in|notin|replace|split)'
OP_BEFORE_RX = re.compile(OPERATOR + r'\s*$', re.I)
OP_LIST_BEFORE_RX = re.compile(r'-(?P<case>[ci]?)(?P<op>in|notin)\s*@?\(\s*(?:' + LITERAL + r'\s*,\s*)*$', re.I)
OP_AFTER_RX = re.compile(r'^\s*' + OPERATOR + r'\b', re.I)
OP_LIST_AFTER_RX = re.compile(r'^(?:\s*,\s*' + LITERAL + r')*\s*\)\s*-(?P<case>[ci]?)(?P<op>contains|notcontains)\b', re.I)
METHOD_BEFORE_RX = re.compile(r'\.(?P<op>Contains|ContainsKey|StartsWith|EndsWith|Equals|IndexOf|LastIndexOf|Replace|Split)'
                              r'\(\s*$')
KEY_BEFORE_RX = re.compile(r'(?:^|[@{;(]|\s)\s*$')
KEY_AFTER_RX = re.compile(r'^\s*=(?!=)')
INDEX_BEFORE_RX = re.compile(r'\[\s*$')
INDEX_AFTER_RX = re.compile(r'^\s*\]')
CASE_AFTER_RX = re.compile(r'^\s*\{')


class Manual(Exception):
    """The occurrence cannot be rewritten safely; the reason goes to the report."""


clean = aw.normalize


# ---------------------------------------------------------------- checks of a correction

def placeholders(text):
    """Variables, subexpressions and format items of a text. The audit decodes `r`n as « rn », so a variable followed by
    line breaks swallows the next word ($messagernrnVerifie): that word is not part of the variable. The rewrite checks
    the variables again on the source itself (source_variables)."""
    return Counter(ESCAPED_TAIL_RX.sub('', p) if p[1:2].isalpha() else p for p in PLACEHOLDER_RX.findall(text))


def source_variables(body):
    """Variables of a double-quoted PowerShell body, read on the source: a backtick ends a variable name there."""
    return Counter(PLACEHOLDER_RX.findall(body))


def fold(text):
    """Text without diacritics, apostrophes as spaces: equal folds mean a purely typographic correction."""
    text = unicodedata.normalize('NFD', text)
    text = ''.join(c for c in text if not unicodedata.combining(c))
    for c in "'ʼ’":
        text = text.replace(c, ' ')
    return clean(text)


def check_pair(old, new):
    """(errors, warnings) of a proposed correction. Errors refuse the pair; warnings send it to the review map."""
    errors, warnings = [], []
    if not isinstance(new, str) or not new.strip():
        return ['texte vide'], warnings
    if new == old:
        errors.append('aucun changement')
    if new != clean(new):
        errors.append('espaces non normalisés')
    if any(c in new for c in TYPOGRAPHIC_QUOTES):
        errors.append('guillemet typographique (délimiteur PowerShell)')
    if "'" in new:
        errors.append("apostrophe ' (utiliser U+02BC)")
    if placeholders(old) != placeholders(new):
        errors.append('variables ou paramètres modifiés')
    if Counter(c for c in old if c in '$`') != Counter(c for c in new if c in '$`'):
        errors.append('caractère $ ou ` ajouté ou retiré')
    for rule, words in aw.faults(new).items():
        errors.append('audit %s : %s' % (rule, ', '.join(words)))
    if fold(old) != fold(new):
        warnings.append('reformulation (pas seulement accents et apostrophes)')
    if len(new) > len(old) * 1.4 + 10:
        warnings.append('texte nettement plus long')
    return errors, warnings


def read_map(path):
    """{old: new} of a correction map, keys and values normalized; raises on a malformed map or a conflicting key."""
    data = json.loads(Path(path).read_text(encoding='utf-8-sig'))
    if not isinstance(data, dict) or not all(isinstance(k, str) and isinstance(v, str) for k, v in data.items()):
        raise ValueError('Table de corrections illisible : ' + str(path))
    out = {}
    for old, new in data.items():
        key, value = clean(old), clean(new)
        if key in out and out[key] != value:
            raise ValueError('Table de corrections contradictoire pour « %s » : %s' % (key, path))
        out[key] = value
    return out


def write_map(path, data):
    """Same format as the maps of the programme: one pair per line, no indentation, no final newline."""
    Path(path).write_text(json.dumps(data, ensure_ascii=False, indent=0), encoding='utf-8', newline='\n')


def map_paths(root, sure=None, review=None):
    root = Path(root)
    return Path(sure or root / SURE_MAP), Path(review or root / REVIEW_MAP)


def load_maps(root, sure=None, review=None):
    """{old: (new, origin)} of both maps; the safe map wins over the review map for a key present in both."""
    sure_path, review_path = map_paths(root, sure, review)
    out = {old: (new, REVIEW) for old, new in read_map(review_path).items()}
    out.update({old: (new, SURE) for old, new in read_map(sure_path).items()})
    return out


def merge(root, pairs, sure=None, review=None, write=True):
    """Add {old: new} pairs to the maps after check_pair. Returns the report; the maps are written only when no pair
    is refused (a refused pair means the file to merge needs fixing first)."""
    sure_path, review_path = map_paths(root, sure, review)
    raw = {SURE: json.loads(sure_path.read_text(encoding='utf-8-sig')),
           REVIEW: json.loads(review_path.read_text(encoding='utf-8-sig'))}
    known = load_maps(root, sure_path, review_path)
    report = {SURE: [], REVIEW: [], 'Unchanged': [], 'Refused': []}
    for old, new in pairs.items():
        if not isinstance(old, str) or not isinstance(new, str) or old != clean(old):
            report['Refused'].append({'Text': old, 'New': new, 'Errors': ['clé non normalisée']})
            continue
        errors, warnings = check_pair(old, new)
        if old in known:
            if known[old][0] == new:
                report['Unchanged'].append(old)
                continue
            errors.append('déjà corrigé autrement dans la table %s : %s' % (known[old][1], known[old][0]))
        if errors:
            report['Refused'].append({'Text': old, 'New': new, 'Errors': errors})
            continue
        target = REVIEW if warnings else SURE
        raw[target][old] = new
        known[old] = (new, target)
        report[target].append(old)
    if write and not report['Refused']:
        if report[SURE]:
            write_map(sure_path, raw[SURE])
        if report[REVIEW]:
            write_map(review_path, raw[REVIEW])
    return report


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
                raise Manual('entité XAML inconnue ' + m.group(0))
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
        raise Manual('guillemet typographique dans une chaîne PowerShell')
    return text.replace("'", "''")


def encode_double(text):
    if any(c in text for c in TYPOGRAPHIC_QUOTES):
        raise Manual('guillemet typographique dans une chaîne PowerShell')
    if '$' in text:
        raise Manual('variable ajoutée ou déplacée dans une chaîne entre guillemets doubles')
    return text.replace('`', '``').replace('"', '`"')


def encode_xaml(text):
    return text.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;').replace('"', '&quot;')


def encode_xaml_ps(text):
    """XAML inside a PowerShell string or here-string: $ and ` may be live there."""
    if '$' in text or '`' in text:
        raise Manual('caractère $ ou ` inséré dans du XAML porté par une chaîne PowerShell')
    if any(c in text for c in TYPOGRAPHIC_QUOTES):
        raise Manual('guillemet typographique dans une chaîne PowerShell')
    return encode_xaml(text)


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
    if not segments or old != clean(old):
        raise Manual('texte non normalisable')
    edits = []
    for tag, i1, i2, j1, j2 in diff_ops(old, new):
        if any(not segments[k][3] for k in range(i1, i2)):
            raise Manual('correction sur un échappement, une entité ou un saut de ligne')
        enc = encode(new[j1:j2])
        if i2 > i1:
            start, end = segments[i1][1], segments[i2 - 1][2]
        else:
            start = end = segments[i1][1] if i1 < len(segments) else segments[-1][2]
        edits.append((start, end, enc))
    out, last = [], 0
    for start, end, enc in sorted(edits):
        if start < last:
            raise Manual('modifications superposées')
        out.append(body[last:start]); out.append(enc); last = end
    out.append(body[last:])
    return ''.join(out)


def decode(body, kind_quote):
    """The text a rewritten source body stands for (used to verify a rewrite)."""
    if kind_quote == "'":
        return ''.join(s[0] for s in segments_single(body))
    if kind_quote == '"':
        return ''.join(s[0] for s in segments_double(body))
    if kind_quote == 'xaml':
        return html.unescape(body)
    return body


# ---------------------------------------------------------------- inventory

def _occ(rel, line, kind, value, body=None, segments=(), encode=None, quote=None, start=None, end=None, slot=None,
         note=None):
    return {'File': rel, 'Line': line, 'Kind': kind, 'Value': value, 'Text': clean(value), 'Body': body,
            'Segments': list(segments), 'Encode': encode, 'Quote': quote, 'Start': start, 'End': end, 'Slot': slot,
            'Manual': note}


def literal_context(line, start, end):
    """Why a literal at line[start..end] (quote positions) is code rather than text, or None."""
    before, after = line[:start], line[end + 1:]
    if OP_BEFORE_RX.search(before) or OP_LIST_BEFORE_RX.search(before) or OP_AFTER_RX.match(after) or \
            OP_LIST_AFTER_RX.match(after) or METHOD_BEFORE_RX.search(before):
        return 'littéral opérande dʼune comparaison'
    if (INDEX_BEFORE_RX.search(before) and INDEX_AFTER_RX.match(after)) or \
            (KEY_AFTER_RX.match(after) and KEY_BEFORE_RX.search(before)):
        return 'littéral utilisé comme clé'
    return None


def _code_occurrences(rel, number, offset, line, calls):
    out = []
    for kind, pos in calls:
        for s, e, q, value in aw.literal_spans(line[pos:]):
            if not aw.is_label(value):
                continue
            s, e = s + pos, e + pos
            body = line[s + 1:e]
            segs = segments_single(body) if q == "'" else segments_double(body)
            note = None
            if ''.join(x[0] for x in segs) != value:
                note = 'décodage différent de lʼaudit'
            elif e >= len(line):
                note = 'chaîne non terminée sur la ligne'
            else:
                note = literal_context(line, s, e)
            out.append(_occ(rel, number, kind, value, body, collapse(segs),
                            encode_single if q == "'" else encode_double, q, offset + s + 1, offset + e, note=note))
    return out


def file_occurrences(root, rel):
    """Occurrences of a source file: the values of audit_wording.collect with their exact source spans, plus the
    accessibility texts. Positions refer to the file decoded without newline translation."""
    path = Path(root) / rel
    text = path.read_bytes().decode('utf-8-sig')
    line_of = aw.line_locator(text)
    encode = encode_xaml_ps if path.suffix == '.ps1' else encode_xaml
    out = []
    for regex, prefix in ((aw.XAML_RX, ''), (A11Y_RX, 'a11y.')):
        for m, value in aw.xaml_values(text, regex):
            body, note, segs = m.group(2), None, []
            try:
                segs = segments_xaml(body)
                if ''.join(s[0] for s in segs) != value:
                    raise Manual('décodage XAML différent de lʼaudit')
                segs = collapse(segs)
            except Manual as exc:
                note = str(exc)
            out.append(_occ(rel, line_of(m.start()), prefix + m.group(1), value, body, segs, encode, 'xaml',
                            m.start(2), m.end(2), note=note))
    if path.suffix != '.ps1':
        return out
    offset = 0
    for number, raw in enumerate(text.split('\n'), 1):
        # aw.collect reads with newline translation: drop the CR of a CRLF so both see the same line.
        line = raw[:-1] if raw.endswith('\r') else raw
        out += _code_occurrences(rel, number, offset, line, aw.code_calls(line))
        if not (line.lstrip().startswith('#') or line.lstrip().startswith('function ')):
            calls = [('a11y.Set' + m.group(1), m.end()) for m in A11Y_CALL_RX.finditer(line)]
            out += _code_occurrences(rel, number, offset, line, calls)
        offset += len(raw) + 1
    return out


def help_occurrences(root, rel):
    path = Path(root) / rel
    raw = path.read_bytes().decode('utf-8-sig')
    data = json.loads(raw)
    same_format = json.dumps(data, ensure_ascii=False, indent=2) + '\n' == raw
    out = []
    for index, entry in enumerate(data):
        for key in aw.HELP_KEYS:
            value = entry.get(key) if isinstance(entry, dict) else None
            if isinstance(value, str) and value.strip():
                out.append(_occ(rel, index + 1, 'help.' + key, value, value, collapse(segments_plain(value)), encode_plain,
                                'json', slot=(index, key), note=None if same_format else 'format JSON de lʼaide non reconnu'))
    return out


def inventory(root):
    """All occurrences. An audit item (aw.collect) without a matching occurrence is added as a manual one."""
    root = Path(root)
    occ = []
    for path in aw.interface_sources(root):
        occ += file_occurrences(root, path.relative_to(root).as_posix())
    if (root / aw.HELP_JSON).is_file():
        occ += help_occurrences(root, aw.HELP_JSON.as_posix())
    ours = Counter((o['File'], o['Line'], o['Kind'], o['Value']) for o in occ if not o['Kind'].startswith('a11y.'))
    theirs = Counter(aw.collect(root))
    for (rel, line, kind, value), count in (theirs - ours).items():
        for _ in range(count):
            occ.append(_occ(rel, line, kind, value, note='texte de lʼaudit non localisé'))
    return occ


# ---------------------------------------------------------------- comparisons and references in code and tests

def ps_strings(line):
    """(start, end, quote, value) of every complete string literal of a PowerShell line, comments excluded."""
    out, i, n = [], 0, len(line)
    while i < n:
        c = line[i]
        if c == '#':
            break
        if c in '\'"':
            j, buf = i + 1, []
            while j < n:
                if line[j] == c:
                    if j + 1 < n and line[j + 1] == c:
                        buf.append(c); j += 2; continue
                    break
                if c == '"' and line[j] == '`' and j + 1 < n:
                    buf.append(line[j + 1]); j += 2; continue
                buf.append(line[j]); j += 1
            if j >= n:
                break
            out.append((i, j, c, ''.join(buf))); i = j + 1; continue
        i += 1
    return out


def wildcard_regex(pattern):
    """PowerShell -like pattern as a Python regex matching the whole text."""
    out, i, n = [], 0, len(pattern)
    while i < n:
        c = pattern[i]
        if c == '`' and i + 1 < n:
            out.append(re.escape(pattern[i + 1])); i += 2; continue
        if c == '*':
            out.append('.*')
        elif c == '?':
            out.append('.')
        elif c == '[' and pattern.find(']', i + 2) > i:
            j = pattern.find(']', i + 2)
            out.append('[' + pattern[i + 1:j].replace('\\', '\\\\') + ']'); i = j + 1; continue
        else:
            out.append(re.escape(c))
        i += 1
    return '(?s)' + ''.join(out) + r'\Z'


# PowerShell operators judged as an equality (positive form: -ne is judged as -eq), plus the two kinds that
# line_comparisons adds: 'key' (hashtable key, index or property name) and 'case' (switch clause).
EQUALITY_OPS = {'eq', 'ne', 'in', 'notin', 'contains', 'notcontains', 'key', 'case'}
# .NET methods are tagged 'method:<Name>' so that String.Contains (a substring check) is never confused with the
# -contains operator (a membership test). Contains, IndexOf and LastIndexOf also exist on lists and hashtables, where
# they test membership: Comparisons follows them both ways.
METHOD = 'method:'
EQUALITY_METHODS = {'containskey', 'equals'}
SUBSTRING_METHODS = {'contains', 'indexof', 'lastindexof', 'replace', 'split'}
MEMBERSHIP_METHODS = {'contains', 'indexof', 'lastindexof'}
PATTERN_SYNTAX_RX = re.compile(r'\\.|\[[^\]]*\]|\{\d*,?\d*\}|\(\?[^)]*?[:)>]|`.')
WORD_RX = re.compile(r'[^\W\d_]{3,}')


def method_name(op):
    """Lowered .NET method name of a 'method:<Name>' kind, or None for an operator."""
    op = op.lower()
    return op[len(METHOD):] if op.startswith(METHOD) else None


def is_exact(op):
    """True when the comparison is with the whole text (equality, membership, key), False for a pattern or a part."""
    name = method_name(op)
    return name in EQUALITY_METHODS if name is not None else op.lower() in EQUALITY_OPS


def comparison(op, case, literal):
    """Predicate telling whether a text satisfies a comparison with a literal operand (the positive form of the
    operator: -notlike is judged as -like). String methods compare with the case."""
    sensitive = case.lower() == 'c'
    flags = 0 if sensitive else re.I
    name = method_name(op)
    if name is not None:
        if name == 'equals':
            return lambda t: t == literal
        if name == 'containskey':  # a PowerShell hashtable ignores the case of its keys
            return lambda t: t.lower() == literal.lower()
        if name == 'startswith':
            return lambda t: t.startswith(literal)
        if name == 'endswith':
            return lambda t: t.endswith(literal)
        if name in SUBSTRING_METHODS:
            return lambda t: literal in t
        raise ValueError('méthode de comparaison inconnue : ' + op)
    op = op.lower()
    if op in EQUALITY_OPS:
        if sensitive:
            return lambda t: t == literal
        return lambda t: t.lower() == literal.lower()
    if op in ('like', 'notlike'):
        rx = re.compile(wildcard_regex(literal), flags)
        return lambda t: bool(rx.match(t))
    if op in ('match', 'notmatch', 'replace', 'split'):
        try:
            rx = re.compile(re.sub(r'\(\?<(?=[A-Za-z_])', '(?P<', literal), flags)
        except re.error:
            return lambda t: literal in t
        return lambda t: bool(rx.search(t))
    raise ValueError('opérateur de comparaison inconnu : ' + op)


def comparison_label(op, case=''):
    """How a comparison kind is shown in the report: -ceq, .Contains, clé, switch."""
    if method_name(op) is not None:
        return '.' + op[len(METHOD):]
    if op.lower() == 'key':
        return 'clé'
    if op.lower() == 'case':
        return 'switch'
    return '-' + case.lower() + op.lower()


def content_words(op, literal):
    """Folded words (3 letters or more) written in a pattern or a substring, outside the pattern syntax; None for an
    exact comparison. A pattern without any word (character classes only) checks a shape, not a wording: it is not
    followed."""
    if is_exact(op):
        return None
    if method_name(op) is not None:  # a substring has no pattern syntax: [x] or \. are plain characters there
        return {fold(w).lower() for w in WORD_RX.findall(literal)}
    return {fold(w).lower() for w in WORD_RX.findall(PATTERN_SYNTAX_RX.sub(' ', literal))}


def line_comparisons(line):
    """(op, case, literal) of each comparison of a code line whose operand is a literal that can be evaluated.
    op is the operator name (eq, like, contains...), 'method:<Name>' for a .NET method, 'key' or 'case'."""
    out = []
    for s, e, q, value in ps_strings(line):
        if q == '"' and '$' in value:
            continue
        before, after = line[:s], line[e + 1:]
        m = OP_BEFORE_RX.search(before) or OP_LIST_BEFORE_RX.search(before) or OP_AFTER_RX.match(after) or \
            OP_LIST_AFTER_RX.match(after)
        if m:
            out.append((m.group('op'), m.group('case'), value)); continue
        m = METHOD_BEFORE_RX.search(before)
        if m:
            out.append((METHOD + m.group('op'), '', value)); continue
        if (INDEX_BEFORE_RX.search(before) and INDEX_AFTER_RX.match(after)) or \
                (KEY_AFTER_RX.match(after) and KEY_BEFORE_RX.search(before)):
            out.append(('key', '', value)); continue
        if not before.strip() and CASE_AFTER_RX.match(after):
            out.append(('case', '', value))
            if any(c in value for c in '*?['):
                out.append(('like', '', value))
    return out


def code_files(root, tests=False):
    """PowerShell files of wad: outside wad/tests (code) or inside it (tests)."""
    root = Path(root)
    out = []
    for path in sorted((root / 'wad').rglob('*.ps1')):
        inside = (root / TESTS_DIR) in path.parents
        if inside == tests:
            out.append(path)
    return out


class Comparisons:
    """The literal comparisons of a set of files, indexed: exact ones by their lowered literal, patterns and
    substrings by the first three letters of each of their words (see content_words)."""

    def __init__(self, root=None, files=()):
        self.exact, self.by_prefix, self.count = {}, {}, 0
        for path in files:
            rel = path.relative_to(Path(root)).as_posix()
            for number, line in enumerate(path.read_text(encoding='utf-8-sig').split('\n'), 1):
                if line.lstrip().startswith('#'):
                    continue
                for op, case, literal in line_comparisons(line):
                    self.add(op, case, literal, '%s:%d' % (rel, number), line.strip())

    def add(self, op, case, literal, place, code=''):
        words = content_words(op, literal)
        if not literal.strip() or words == set():
            return
        label = comparison_label(op, case)
        possible = op.lower() == 'key' or method_name(op) == 'containskey'  # a lookup by name, not a test of the text
        self._index(comparison(op, case, literal), words, literal, place, label, possible, code)
        if method_name(op) in MEMBERSHIP_METHODS:
            # The same call on a list or a hashtable tests membership: followed as -contains too.
            self._index(comparison('contains', '', literal), None, literal, place, label, False, code)

    def _index(self, predicate, words, literal, place, label, possible, code):
        info = {'Place': place, 'Comparison': label, 'Possible': possible, 'Code': code}
        entry = (self.count, predicate, words, info)
        self.count += 1
        if words is None:
            self.exact.setdefault(literal.lower(), []).append(entry)
        else:
            for prefix in {w[:3] for w in words}:
                self.by_prefix.setdefault(prefix, []).append(entry)

    def lost(self, old, new):
        """The comparisons that recognize old and no longer recognize new, once per place and kind, in file order:
        {Place, Comparison, Possible, Code}. Followed: exact comparisons, and patterns or substrings with a word that
        starts a word of old (« registre » is not followed inside « enregistre »). The reverse change, a pattern
        already written with the accents, is not a dependency on the old text."""
        variants = [(old, new), (clean(old), clean(new))]
        candidates = {}
        for text, _ in variants:
            for entry in self.exact.get(text.lower(), []):
                candidates[entry[0]] = entry
        for word in set(re.findall(r'[^\W\d_]+', fold(old).lower())):
            for entry in self.by_prefix.get(word[:3], []):
                if entry[0] not in candidates and any(word.startswith(w) for w in entry[2]):
                    candidates[entry[0]] = entry
        out, seen = [], set()
        for _, predicate, _, info in sorted(candidates.values(), key=lambda e: e[0]):
            key = (info['Place'], info['Comparison'])
            if key not in seen and any(predicate(a) and not predicate(b) for a, b in variants):
                seen.add(key)
                out.append(dict(info))
        return out

    def changed(self, old, new):
        """Places of lost(old, new), each once."""
        places = []
        for info in self.lost(old, new):
            if info['Place'] not in places:
                places.append(info['Place'])
        return places


def describe(dependencies, limit=3):
    """Short text of dependencies for a manual reason: place (comparison[, possible]), at most limit of them."""
    parts = ['%s (%s%s)' % (d['Place'], d['Comparison'], ', possible' if d['Possible'] else '')
             for d in dependencies[:limit]]
    if len(dependencies) > limit:
        more = len(dependencies) - limit
        parts.append('et %d autre%s' % (more, 's' if more > 1 else ''))
    return ', '.join(parts)


def read_cleared(path):
    """{(text, file, code): reason} of the comparisons read and judged unrelated to their text. A missing file is an
    empty list; a malformed entry or a duplicate raises."""
    path = Path(path)
    if not path.is_file():
        return {}
    data = json.loads(path.read_text(encoding='utf-8-sig'))
    fields = ('Text', 'File', 'Code', 'Reason')
    if not isinstance(data, list):
        raise ValueError('Liste des dépendances écartées illisible : ' + str(path))
    out = {}
    for item in data:
        if not isinstance(item, dict) or set(item) != set(fields) or \
                not all(isinstance(item[f], str) and item[f].strip() for f in fields):
            raise ValueError('Dépendance écartée incomplète (Text, File, Code, Reason) : %s' % (item,))
        if item['Text'] != clean(item['Text']) or item['Code'] != item['Code'].strip():
            raise ValueError('Dépendance écartée non normalisée : %s' % (item,))
        key = (item['Text'], item['File'], item['Code'])
        if key in out:
            raise ValueError('Dépendance écartée en double : %s' % (item,))
        out[key] = item['Reason']
    return out


def _is_word_char(c):
    return c.isalnum() or c == '_'


def text_references(root, files, values, skip=frozenset()):
    """{value: ['file:line']} of the lines of files that contain a value (raw, quote-doubled, entity or backtick form)
    between non-word characters; (file, line) pairs listed in skip are ignored."""
    root = Path(root)
    forms = {v: {v, v.replace("'", "''"), encode_xaml(v), v.replace('"', '`"')} for v in values}
    out = {}
    for path in files:
        rel = path.relative_to(root).as_posix()
        text = path.read_text(encoding='utf-8-sig', errors='replace')
        line_of = aw.line_locator(text)
        for value, variants in forms.items():
            lines = set()
            for form in variants:
                i = text.find(form)
                while i >= 0:
                    j = i + len(form)
                    if (i == 0 or not _is_word_char(text[i - 1])) and (j >= len(text) or not _is_word_char(text[j])):
                        number = line_of(i)
                        if (rel, number) not in skip:
                            lines.add(number)
                    i = text.find(form, i + 1)
            if lines:
                out.setdefault(value, []).extend('%s:%d' % (rel, n) for n in sorted(lines))
    return out


def _place_key(place):
    rel, _, number = place.rpartition(':')
    return rel, int(number)


def test_files(root):
    tests = Path(root) / TESTS_DIR
    if not tests.is_dir():
        return []
    return sorted(p for p in tests.rglob('*') if p.is_file() and p.suffix in ('.ps1', '.py', '.json', '.txt', '.xaml'))


# ---------------------------------------------------------------- plan and apply

def plan(root, maps, include_review=False, cleared=None):
    """Edits per occurrence and the full report (no file is written). Review pairs are applied only on request.
    cleared: read_cleared() of the comparisons judged unrelated to their text (default: the list of the tree)."""
    root = Path(root)
    if cleared is None:
        cleared = read_cleared(root / CLEARED)
    occ = inventory(root)
    rows = aw.findings(root)
    faulty = {}
    for r in rows:
        entry = faulty.setdefault(r['Text'], {'Rules': set(), 'Words': set(), 'Places': []})
        entry['Rules'].add(r['Rule'])
        entry['Words'].update(r['Words'])
        place = '%s:%d' % (r['File'], r['Line'])
        if place not in entry['Places']:
            entry['Places'].append(place)
    # Accessibility texts are outside the audit; their faults are listed with the same rules.
    for o in occ:
        if o['Kind'].startswith('a11y.') and o['Text'] not in faulty:
            found = aw.faults(o['Text'])
            if found:
                faulty[o['Text']] = {'Rules': set(found), 'Words': {w for ws in found.values() for w in ws}, 'Places': [],
                                     'A11y': True}
        if o['Kind'].startswith('a11y.') and o['Text'] in faulty and faulty[o['Text']].get('A11y'):
            place = '%s:%d' % (o['File'], o['Line'])
            if place not in faulty[o['Text']]['Places']:
                faulty[o['Text']]['Places'].append(place)
    texts = {o['Text'] for o in occ}
    refused, accepted, pending = [], {}, []
    for old in sorted(texts):
        if old not in maps:
            continue
        new, origin = maps[old]
        if origin == REVIEW and not include_review:
            pending.append(old)
            continue
        errors, warnings = check_pair(old, new)
        if errors:
            refused.append({'Text': old, 'New': new, 'Map': origin, 'Errors': errors})
        else:
            accepted[old] = (new, origin, warnings)
    found = Comparisons(root, code_files(root))
    dependencies, cleared_rows, used = {}, [], set()
    for old in sorted(accepted):
        kept = []
        for d in found.lost(old, accepted[old][0]):
            key = (old, _place_key(d['Place'])[0], d['Code'])
            if key in cleared:
                used.add(key)
                cleared_rows.append({'Text': old, 'Place': d['Place'], 'Comparison': d['Comparison'],
                                     'Reason': cleared[key]})
            else:
                kept.append(d)
        dependencies[old] = kept
    edits, manual = [], []
    for o in occ:
        if o['Text'] not in accepted:
            continue
        new = accepted[o['Text']][0]
        try:
            if o['Manual']:
                raise Manual(o['Manual'])
            if dependencies[o['Text']]:
                raise Manual('comparaison dans le code changée : ' + describe(dependencies[o['Text']]))
            body = rewrite(o['Body'], o['Segments'], new, o['Encode'])
            if clean(decode(body, o['Quote'])) != new:
                raise Manual('réécriture non vérifiable')
            if o['Quote'] == '"' and source_variables(body) != source_variables(o['Body']):
                raise Manual('variable modifiée dans une chaîne entre guillemets doubles')
            edits.append(dict(o, NewBody=body, New=new, Map=accepted[o['Text']][1]))
        except Manual as exc:
            manual.append({'File': o['File'], 'Line': o['Line'], 'Kind': o['Kind'], 'Text': o['Text'], 'New': new,
                           'Reason': str(exc)})
    by_file = {}
    for e in edits:
        if e['Start'] is not None:
            by_file.setdefault(e['File'], []).append(e)
    overlapping = set()
    for items in by_file.values():
        items.sort(key=lambda x: (x['Start'], x['End']))
        for a, b in zip(items, items[1:]):
            if b['Start'] < a['End']:
                overlapping.update((id(a), id(b)))
    # A text is rewritten everywhere or nowhere: ToolTip, HelpText and the help entry must stay equal.
    held = {m['Text'] for m in manual} | {e['Text'] for e in edits if id(e) in overlapping}
    kept = []
    for e in edits:
        if e['Text'] in held:
            reason = 'occurrences superposées' if id(e) in overlapping else \
                'retenu : une autre occurrence du même texte demande une correction manuelle'
            manual.append({'File': e['File'], 'Line': e['Line'], 'Kind': e['Kind'], 'Text': e['Text'], 'New': e['New'],
                           'Reason': reason})
        else:
            kept.append(e)
    edits = kept
    edited_values = sorted({e['Value'] for e in edits})
    tests = text_references(root, test_files(root), edited_values)
    test_patterns = Comparisons(root, code_files(root, tests=True))
    pattern_refs = {}
    for text in sorted({e['Text'] for e in edits}):
        places = test_patterns.changed(text, accepted[text][0])
        if places:
            pattern_refs[text] = places
    interface_lines = {(o['File'], o['Line']) for o in occ if o['Start'] is not None}
    others = text_references(root, code_files(root), edited_values, skip=interface_lines)
    planned = Counter((e['File'], e['Line'], e['Kind'], e['Text']) for e in edits)
    remaining = sum(1 for r in rows if planned[(r['File'], r['Line'], r['Kind'], r['Text'])] == 0)
    uncovered = [{'Text': t, 'Rules': sorted(v['Rules']), 'Words': sorted(v['Words']), 'Places': v['Places'],
                  'Accessibility': bool(v.get('A11y'))} for t, v in sorted(faulty.items()) if t not in maps]
    test_rows = {}
    for value, refs in tests.items():
        test_rows.setdefault(clean(value), {'Literal': set(), 'Pattern': set()})['Literal'].update(refs)
    for text, refs in pattern_refs.items():
        test_rows.setdefault(text, {'Literal': set(), 'Pattern': set()})['Pattern'].update(refs)
    report = {
        'Inventory': {'Occurrences': len(occ), 'Texts': len(texts), 'AuditFindings': len(rows),
                      'FaultyTexts': sum(1 for v in faulty.values() if not v.get('A11y')),
                      'AccessibilityFaultyTexts': sum(1 for v in faulty.values() if v.get('A11y'))},
        'Coverage': {'Sure': sum(1 for t in faulty if t in maps and maps[t][1] == SURE),
                     'Review': sum(1 for t in faulty if t in maps and maps[t][1] == REVIEW),
                     'Uncovered': len(uncovered)},
        'Planned': {'Edits': len(edits), 'Texts': len({e['Text'] for e in edits}),
                    'Files': dict(sorted(Counter(e['File'] for e in edits).items())), 'AuditFindingsAfter': remaining},
        'Uncovered': uncovered,
        'Refused': refused,
        'ReviewPending': len(pending),
        # A safe pair that is more than typographic belongs to the review map.
        'Warnings': [{'Text': t, 'New': v[0], 'Warnings': v[2]} for t, v in sorted(accepted.items()) if v[2] and v[1] == SURE],
        'Manual': manual,
        'Tests': [{'Text': t, 'New': accepted[t][0], 'Literal': sorted(v['Literal'], key=_place_key),
                   'Pattern': sorted(v['Pattern'], key=_place_key)}
                  for t, v in sorted(test_rows.items())],
        'References': [{'Text': clean(v), 'References': refs} for v, refs in sorted(others.items())],
        # Comparisons that hold a text (Possible: a key, an index or a property name equal to the text), the ones
        # cleared by the reviewed list, and the entries of that list that clear nothing any more.
        'Dependencies': [{'Text': t, 'New': accepted[t][0], 'Places': deps}
                         for t, deps in sorted(dependencies.items()) if deps],
        'Cleared': cleared_rows,
        'UnusedCleared': [{'Text': t, 'File': f, 'Code': c} for (t, f, c) in sorted(cleared)
                          if (t, f, c) not in used and t not in pending],
    }
    return edits, report


def _write_text(path, text, original_bytes):
    data = text.encode('utf-8')
    if original_bytes.startswith(b'\xef\xbb\xbf'):
        data = b'\xef\xbb\xbf' + data
    path.write_bytes(data)


def apply(root, edits):
    """Write the planned edits; returns the files written. Every file is checked before the first write."""
    root = Path(root)
    by_file = {}
    for e in edits:
        by_file.setdefault(e['File'], []).append(e)
    outputs = []
    for rel, items in sorted(by_file.items()):
        path = root / rel
        original = path.read_bytes()
        text = original.decode('utf-8-sig')
        if any(e['Slot'] is not None for e in items):
            if any(e['Slot'] is None for e in items):
                raise RuntimeError('Fichier dʼaide mêlé à du code : ' + rel)
            data = json.loads(text)
            for e in items:
                index, key = e['Slot']
                if data[index][key] != e['Value']:
                    raise RuntimeError('Aide modifiée pendant la passe : %s %s' % (rel, e['Line']))
                data[index][key] = e['NewBody']
            outputs.append((path, json.dumps(data, ensure_ascii=False, indent=2) + '\n', original))
        else:
            out, last = [], 0
            for e in sorted(items, key=lambda x: x['Start']):
                if e['Start'] < last or text[e['Start']:e['End']] != e['Body']:
                    raise RuntimeError('Source modifiée ou chevauchement : %s:%d' % (rel, e['Line']))
                out.append(text[last:e['Start']]); out.append(e['NewBody']); last = e['End']
            out.append(text[last:])
            outputs.append((path, ''.join(out), original))
    for path, text, original in outputs:
        _write_text(path, text, original)
    return [path.relative_to(root).as_posix() for path, _, _ in outputs]


def summary(report):
    out = {k: report[k] for k in ('Status', 'Inventory', 'Coverage', 'Planned', 'ReviewPending')}
    out['Refused'] = len(report['Refused'])
    out['Warnings'] = len(report['Warnings'])
    out['References'] = len(report['References'])
    out['Dependencies'] = ['%s : %s' % (d['Text'], describe(d['Places'], len(d['Places'])))
                           for d in report['Dependencies']]
    out['Cleared'] = len(report['Cleared'])
    out['UnusedCleared'] = ['%s | %s | %s' % (u['Text'], u['File'], u['Code']) for u in report['UnusedCleared']]
    out['Manual'] = ['%s:%d %s | %s | %s' % (m['File'], m['Line'], m['Kind'], m['Reason'], m['Text']) for m in report['Manual']]
    out['TestsToUpdate'] = ['%s -> %s : %s' % (t['Text'], t['New'], ', '.join(t['Literal'] + ['motif ' + p for p in t['Pattern']]))
                            for t in report['Tests']]
    for k in ('Written', 'AuditFindingsNow', 'Verification'):
        if k in report:
            out[k] = report[k]
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--root', type=Path, default=ROOT, help='Racine dev (par défaut : ce dépôt).')
    ap.add_argument('--map', type=Path, help='Table sûre (par défaut : %s).' % SURE_MAP.as_posix())
    ap.add_argument('--review-map', type=Path, help='Table à relire (par défaut : %s).' % REVIEW_MAP.as_posix())
    ap.add_argument('--cleared', type=Path,
                    help='Comparaisons relues et écartées (par défaut : %s).' % CLEARED.as_posix())
    ap.add_argument('--include-review', action='store_true', help='Appliquer aussi la table à relire (après décision).')
    ap.add_argument('--apply', action='store_true', help='Écrire les corrections dans les sources (sinon : simulation).')
    ap.add_argument('--merge', type=Path, help='Ajouter aux tables les paires {ancien: nouveau} de ce fichier JSON.')
    ap.add_argument('--uncovered-json', type=Path, help='Écrire les textes fautifs sans correction (JSON).')
    ap.add_argument('--report', type=Path, help='Écrire le rapport complet (JSON).')
    a = ap.parse_args(argv)
    root = a.root.resolve()
    if a.merge:
        if a.apply:
            ap.error('--merge et --apply sont deux étapes distinctes.')
        result = merge(root, json.loads(a.merge.read_text(encoding='utf-8-sig')), a.map, a.review_map)
        result['Status'] = 'REFUSED' if result['Refused'] else 'MERGED'
        print(json.dumps({'Status': result['Status'], 'Sure': len(result[SURE]), 'Review': len(result[REVIEW]),
                          'Unchanged': len(result['Unchanged']), 'Refused': result['Refused']}, ensure_ascii=False, indent=2))
        return 1 if result['Refused'] else 0
    maps = load_maps(root, a.map, a.review_map)
    edits, report = plan(root, maps, a.include_review, read_cleared(a.cleared or root / CLEARED))
    report['Status'] = 'DRY-RUN'
    code = 0
    if a.apply:
        report['Written'] = apply(root, edits)
        report['AuditFindingsNow'] = len(aw.findings(root))
        report['Verification'] = 'OK' if report['AuditFindingsNow'] == report['Planned']['AuditFindingsAfter'] else 'ECART'
        report['Status'] = 'APPLIED'
        code = 0 if report['Verification'] == 'OK' else 1
    if a.uncovered_json:
        a.uncovered_json.write_text(json.dumps(report['Uncovered'], ensure_ascii=False, indent=1) + '\n', encoding='utf-8')
    if a.report:
        a.report.write_text(json.dumps(report, ensure_ascii=False, indent=1) + '\n', encoding='utf-8')
    print(json.dumps(summary(report), ensure_ascii=False, indent=2))
    return code


if __name__ == '__main__':
    sys.exit(main())
