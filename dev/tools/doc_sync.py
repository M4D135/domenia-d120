#!/usr/bin/env python3
"""Documentation and help synchronised with the delivered pack (point 149). Offline, read-only.

Checks, from the sources that build the pack:
  1. every interface text quoted in the guides (« ... » in guides/*.md) is displayed by the pack: an XAML attribute or
     a string literal of the runtime, the launcher, the installer and the support scripts. Templates use … (or N, M)
     for the variable parts; each fixed part must exist. Short quotes must be a whole label, not a word inside one;
  2. no help text, guide or interface text names a retired label (tools/doc-sync.json, RetiredLabels);
  3. every entry of the contextual help catalogue (wad/modules/Domenia-UX.help.json) names a control of the pack;
  4. each guide sheet describes the delivered version (DisplayName of tools/release-contract.json) and its Word and
     PDF deliverables exist in DOC/;
  5. the guide figures exist and carry the SHA-256 recorded by the capture provenance; the provenance manifest is
     compared with the current package manifest (captures older than the pack are reported, never presented as
     current).
Known gaps are kept in tools/baselines/doc-sync-baseline.json (ratchet: a new gap fails, a fixed one is reported).
Nothing is rebuilt here: the DOCX/PDF are produced by guides/build_guide.js and the captures by the Windows harness.

Usage: python3 tools/doc_sync.py [--check] [--report PATH] [--update-baseline]
"""
from pathlib import Path
import argparse, glob, hashlib, json, re, sys, unicodedata
import xml.etree.ElementTree as ET

DEV = Path(__file__).resolve().parents[1]
REPO = DEV.parent
CONFIG = DEV / 'tools' / 'doc-sync.json'
BASELINE = DEV / 'tools' / 'baselines' / 'doc-sync-baseline.json'
HELP = DEV / 'wad' / 'modules' / 'Domenia-UX.help.json'
SHORT_QUOTE = 40
ATTRIBUTES = ('Content', 'Text', 'Header', 'ToolTip', 'Title', 'AutomationProperties.Name', 'AutomationProperties.HelpText')
XNAME = '{http://schemas.microsoft.com/winfx/2006/xaml}Name'


def normalize(text):
    """Same text whatever the apostrophe, the non-breaking spaces or the line breaks."""
    text = str(text).replace('’', 'ʼ').replace("'", 'ʼ').replace(' ', ' ').replace(' ', ' ')
    return re.sub(r'\s+', ' ', text).strip()


def fold(text):
    """Accent-insensitive form, used only to propose the current text of a quote."""
    return ''.join(c for c in unicodedata.normalize('NFD', normalize(text)) if unicodedata.category(c) != 'Mn').lower()


def read(path):
    return Path(path).read_text(encoding='utf-8-sig')


def ui_sources(dev=DEV):
    """Files whose texts a user of the pack can see."""
    patterns = ['wad/Domenia-Core.ps1', 'wad/Domenia-Start.ps1', 'wad/modules/*.ps1', 'wad/modules/*.xaml',
                'wad/modules/*.json', 'wad/Support/*.ps1', 'wad/Support/*.cmd', 'wad/maintenance/*.ps1', '*.cmd',
                'INSTALLER-MISE-A-JOUR.ps1', 'tools/launcher/launcher.c', 'tools/Fabriquer-Prod.ps1',
                'tools/Production.Source.ps1', 'tools/Signer-Distribution.ps1', 'tools/Test-DomeniaSignature.ps1']
    files = []
    for pattern in patterns:
        files.extend(sorted(Path(p) for p in glob.glob(str(Path(dev) / pattern))))
    return files


LITERAL = re.compile(r"'((?:[^'\n]|'')*)'|\"((?:[^\"\\\n`]|\\.|`.)*)\"")


def literals(dev=DEV):
    """Normalised interface texts: XAML attribute values and string literals of the scripts and the launcher."""
    found = set()
    for path in ui_sources(dev):
        text = read(path)
        for match in LITERAL.finditer(text):
            value = match.group(1) if match.group(1) is not None else match.group(2)
            value = value.replace("''", "'")
            if path.suffix == '.c':
                # C escapes of the launcher messages: the text shown has a single backslash.
                value = value.replace('\\\\', '\\').replace('\\n', ' ')
            if value.strip():
                found.add(normalize(value))
        for match in re.finditer(r'\b(?:%s)="([^"]*)"' % '|'.join(re.escape(a) for a in ATTRIBUTES), text):
            if match.group(1).strip():
                found.add(normalize(match.group(1)))
    return found


def is_whole_label(quote, value):
    if value == quote:
        return True
    for candidate in (value.rstrip(' :.·…'),):
        if candidate == quote.rstrip(' :.·…'):
            return True
    if value.startswith(quote) and not value[len(quote)].isalnum():
        return True
    if value.endswith(quote) and not value[-len(quote) - 1].isalnum():
        return True
    return False


def quote_found(quote, values, joined):
    q = normalize(quote)
    parts = [p.strip(' .:') for p in re.split(r'…|\bN\b|\bM\b', q)]
    if len(parts) > 1:
        parts = [p for p in parts if len(p) >= 3]
        return all(p in joined for p in parts)
    if len(q) > SHORT_QUOTE:
        return q in joined
    return any(is_whole_label(q, v) for v in values if q in v)


def propose(quote, values):
    """Current interface texts equal to the quote once accents and apostrophes are ignored (at most three)."""
    target = fold(quote)
    if len(target) < 3:
        return []
    exact = sorted(v for v in values if fold(v) == target)
    if exact:
        return exact[:3]
    return sorted(v for v in values if target in fold(v) and len(v) <= len(quote) * 3)[:3]


def guide_quotes(repo=REPO):
    rows = []
    for path in sorted(Path(repo, 'guides').glob('*.md')):
        if path.name.upper() in ('BRIEF.MD', 'LIRE-KIT.MD') or path.name.startswith('PROMPT_'):
            continue
        for number, line in enumerate(read(path).splitlines(), 1):
            for match in re.finditer(r'«\s*([^»]+?)\s*»', line):
                rows.append({'Guide': path.name, 'Line': number, 'Quote': normalize(match.group(1))})
    return rows


def main_xaml_names(dev=DEV):
    sys.path.insert(0, str(Path(dev) / 'wad' / 'tests'))
    from powershell_lex import functions
    core = read(Path(dev) / 'wad' / 'Domenia-Core.ps1')
    start, end = functions(core)['Get-MainXaml'][0]
    root = ET.fromstring(re.search(r'@"\n(.*?)\n"@', core[start:end], re.S).group(1))
    names = {e.get(XNAME) for e in root.iter() if e.get(XNAME)}
    for path in glob.glob(str(Path(dev) / 'wad' / 'modules' / '*.xaml')):
        try:
            names |= {e.get(XNAME) for e in ET.fromstring(read(path)).iter() if e.get(XNAME)}
        except ET.ParseError:
            continue
    return names


def code_names(dev=DEV):
    """Control names created by code ($x.Name='...' or Name='...' in a control template built in a script)."""
    names = set()
    for path in sorted(glob.glob(str(Path(dev) / 'wad' / 'modules' / '*.ps1'))) + [str(Path(dev) / 'wad' / 'Domenia-Core.ps1')]:
        for match in re.finditer(r"\.Name\s*=\s*'([A-Za-z][A-Za-z0-9_]*)'|\bx:Name=\"([A-Za-z][A-Za-z0-9_]*)\"|Name\s*=\s*'([A-Za-z][A-Za-z0-9_]*)'", read(path)):
            names.add(next(g for g in match.groups() if g))
    return names


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest().upper()


def collect(dev=DEV, repo=REPO):
    config = json.loads(read(Path(dev) / 'tools' / 'doc-sync.json'))
    contract = json.loads(read(Path(dev) / 'tools' / 'release-contract.json'))
    values = literals(dev)
    joined = '\n'.join(sorted(values))
    gaps = {'Quotes': [], 'Retired': [], 'HelpOrphans': [], 'Guides': [], 'Figures': []}
    # 1. Quotes of the guides.
    for row in guide_quotes(repo):
        if not quote_found(row['Quote'], values, joined):
            gaps['Quotes'].append(dict(row, Current=propose(row['Quote'], values)))
    # 2. Retired labels.
    help_entries = json.loads(read(Path(dev) / 'wad' / 'modules' / 'Domenia-UX.help.json'))
    texts = [('wad/modules/Domenia-UX.help.json:' + e['Name'], e.get('Text', '') + ' ' + e.get('Title', '')) for e in help_entries]
    for path in sorted(Path(repo, 'guides').glob('*.md')):
        if path.name.upper() in ('BRIEF.MD', 'LIRE-KIT.MD') or path.name.startswith('PROMPT_'):
            continue
        texts.append(('guides/' + path.name, read(path)))
    for label in config.get('RetiredLabels', []):
        for where, text in texts:
            if label['Pattern'] in normalize(text):
                gaps['Retired'].append({'Where': where, 'Label': label['Pattern'], 'Replacement': label['Replacement']})
    # 3. Help entries naming no control of the pack.
    known = main_xaml_names(dev) | code_names(dev)
    for entry in help_entries:
        if entry['Name'] not in known:
            gaps['HelpOrphans'].append({'Name': entry['Name'], 'Title': entry.get('Title', '')})
    # 4. Guide sheets and deliverables.
    for sheet in sorted(Path(repo, 'guides').glob('*.json')):
        if sheet.name in ('package.json', 'package-lock.json'):
            continue
        data = json.loads(read(sheet))
        if not isinstance(data, dict) or 'output' not in data:
            continue
        for field in ('product', 'edition'):
            if data.get(field) != contract['DisplayName']:
                gaps['Guides'].append({'Sheet': sheet.name, 'Problem': '%s = %r, version livrée %r' % (field, data.get(field), contract['DisplayName'])})
        for extension in ('.docx', '.pdf'):
            target = Path(repo, 'DOC', data['output'] + extension)
            if not target.is_file():
                gaps['Guides'].append({'Sheet': sheet.name, 'Problem': 'livrable absent : DOC/' + target.name})
        # 5. Figures.
        provenance_path = Path(repo, 'guides', 'captures', 'capture-provenance.json')
        recorded = {}
        if provenance_path.is_file():
            recorded = {i['File']: i['SHA256'].upper() for i in json.loads(read(provenance_path)).get('Images', [])}
        for name, figure in sorted((data.get('figures') or {}).items()):
            image = Path(repo, 'guides', figure['file'])
            if not image.is_file():
                gaps['Figures'].append({'Sheet': sheet.name, 'Figure': name, 'Problem': 'image absente : ' + figure['file']})
            elif image.name in recorded and recorded[image.name] != sha(image):
                gaps['Figures'].append({'Sheet': sheet.name, 'Figure': name, 'Problem': 'image différente de la capture enregistrée : ' + image.name})
            elif image.name not in recorded:
                gaps['Figures'].append({'Sheet': sheet.name, 'Figure': name, 'Problem': 'image sans provenance de capture : ' + image.name})
    captures = {'ProvenanceManifestSHA256': '', 'CurrentManifestSHA256': '', 'Current': None}
    provenance_path = Path(repo, 'guides', 'captures', 'capture-provenance.json')
    manifest = Path(dev, 'wad', 'package-manifest.json')
    if provenance_path.is_file() and manifest.is_file():
        captures['ProvenanceManifestSHA256'] = str(json.loads(read(provenance_path)).get('SourceManifestSHA256', '')).upper()
        captures['CurrentManifestSHA256'] = sha(manifest)
        captures['Current'] = captures['ProvenanceManifestSHA256'] == captures['CurrentManifestSHA256']
    return gaps, captures, len(guide_quotes(repo)), len(help_entries)


def keys(gaps):
    """Stable identity of each gap for the ratchet (line numbers excluded)."""
    out = {}
    for kind, rows in gaps.items():
        for row in rows:
            if kind == 'Quotes':
                key = '%s|%s|%s' % (kind, row['Guide'], row['Quote'])
            elif kind == 'Retired':
                key = '%s|%s|%s' % (kind, row['Where'], row['Label'])
            elif kind == 'HelpOrphans':
                key = '%s|%s' % (kind, row['Name'])
            elif kind == 'Guides':
                key = '%s|%s|%s' % (kind, row['Sheet'], row['Problem'])
            else:
                key = '%s|%s|%s|%s' % (kind, row['Sheet'], row['Figure'], row['Problem'])
            out[key] = out.get(key, 0) + 1
    return out


def compare(gaps, baseline):
    current = keys(gaps)
    allowed = baseline.get('Allowed', {})
    new = sorted(k for k, n in current.items() if n > allowed.get(k, 0))
    fixed = sorted(k for k, n in allowed.items() if current.get(k, 0) < n)
    return new, fixed


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--check', action='store_true', help='Comparer a la reference (defaut).')
    ap.add_argument('--report', type=Path, help='Ecrire le rapport complet (JSON).')
    ap.add_argument('--update-baseline', action='store_true', help='Enregistrer les ecarts actuels comme reference, apres relecture.')
    args = ap.parse_args()
    gaps, captures, quotes, helps = collect()
    baseline = json.loads(read(BASELINE)) if BASELINE.is_file() else {'Allowed': {}}
    if args.update_baseline:
        BASELINE.parent.mkdir(parents=True, exist_ok=True)
        data = {'Schema': 'DomeniaDocSyncBaseline/1', 'Note': baseline.get('Note', ''), 'Allowed': dict(sorted(keys(gaps).items()))}
        with open(BASELINE, 'w', encoding='utf-8', newline='\n') as handle:
            handle.write(json.dumps(data, ensure_ascii=False, indent=2) + '\n')
        baseline = data
    new, fixed = compare(gaps, baseline)
    report = {'Status': 'FAIL' if new else 'PASS', 'New': new, 'Fixed': fixed,
              'Counts': {k: len(v) for k, v in gaps.items()}, 'GuideQuotes': quotes, 'HelpEntries': helps,
              'Captures': captures,
              'CapturesNote': ('Captures prises sur le manifeste courant.' if captures['Current'] else
                               'Captures prises sur un autre manifeste que le pack courant : les refaire avec guides/captures/capture-guides.ps1 avant une livraison.'),
              'Gaps': gaps}
    if args.report:
        args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    summary = {k: report[k] for k in ('Status', 'New', 'Fixed', 'Counts', 'GuideQuotes', 'HelpEntries', 'CapturesNote')}
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 1 if new else 0


if __name__ == '__main__':
    sys.exit(main())
