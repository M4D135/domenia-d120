#!/usr/bin/env python3
"""Point 112: offline audit of the typographic scale and of the named spacing. Reads files only; no PowerShell runs.

Rules:
  1. the window resources (wad/Domenia-Main.xaml) define exactly the eight named sizes of the scale with their values, and the
     named spacing used by the shared styles, consistent with the metrics of wad/modules/SupportSuite.UI.json;
  2. every size reference ({DynamicResource FontSize...} in XAML, SetResourceReference(...FontSizeProperty,'FontSize...')
     in code) names one of these eight sizes;
  3. the page (wad/Domenia-Main.xaml, Get-DomeniaTreeHeaderTemplate) and the module views (wad/modules/*.xaml) hold no literal
     FontSize; elsewhere a literal FontSize (other windows such as the sign-in window, chart and board drawing code) is
     a ratchet: tools/baselines/typography-baseline.json gives the allowed count per file and function;
  4. literal Margin and Padding values of the page and of the module views are a ratchet too (per file): new layout
     takes the named spacing, the count never goes up.
--update-baseline rewrites the reference after a reduction and refuses any increase.

Usage: python3 tools/audit_typography.py [--report PATH] [--update-baseline]
"""
from pathlib import Path
import argparse, glob, json, re, sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'wad' / 'tests'))
from powershell_lex import functions  # noqa: E402

BASELINE = ROOT / 'tools' / 'baselines' / 'typography-baseline.json'
SCHEMA = 'DomeniaTypographyBaseline/1'
SCALE = {'FontSizeCaption': '11', 'FontSizeSmall': '12', 'FontSizeBody': '13', 'FontSizeSubtitle': '14',
         'FontSizeSection': '16', 'FontSizeTitle': '18', 'FontSizePageTitle': '22', 'FontSizeDisplay': '27'}
SPACING = {'SpaceStackSmall': '0,0,0,4', 'SpaceStack': '0,0,0,8', 'SpaceStackLarge': '0,0,0,12', 'SpaceSection': '0,0,0,16',
           'SpaceInline': '0,0,8,0', 'SpaceInlineSmall': '0,0,6,0', 'PadButton': '14,8', 'PadButtonSecondary': '14,7',
           'PadInput': '9,6', 'PadCompact': '6,4', 'PadCard': '18', 'PadTab': '12,8', 'MarginTab': '0,0,5,6',
           'PadToolTip': '12,10', 'PadHeader': '8,6'}
PAGE_FUNCTIONS = ('Get-DomeniaTreeHeaderTemplate',)
LITERAL_FONT = re.compile(r'FontSize="[0-9.]+"|Property="FontSize" Value="[0-9.]+"|\.FontSize\s*=\s*[0-9]')
FONT_KEY = re.compile(r"\{DynamicResource (FontSize\w*)\}|FontSizeProperty\s*,\s*'(FontSize\w*)'")
SPACING_LITERAL = re.compile(r'\b(?:Margin|Padding)="[0-9][0-9.,\s-]*"|Property="(?:Margin|Padding)" Value="[0-9][0-9.,\s-]*"')


def read(path):
    return Path(path).read_text(encoding='utf-8-sig')


def owner_counts(text, pattern):
    """Matches of pattern per top-level function of a PowerShell file ('' for script code)."""
    spans = sorted((a, b, name) for name, group in functions(text).items() for a, b in group)
    counts = {}
    for match in pattern.finditer(text):
        owner = ''
        for a, b, name in spans:
            if a <= match.start() < b:
                owner = name
                break
        counts[owner] = counts.get(owner, 0) + 1
    return counts


def main_xaml(root=ROOT):
    return read(Path(root) / 'wad' / 'Domenia-Main.xaml')


def collect(root=ROOT):
    root = Path(root)
    problems = []
    core = read(root / 'wad' / 'Domenia-Core.ps1')
    xaml = main_xaml(root)
    resources = xaml[xaml.index('<Window.Resources>'):xaml.index('</Window.Resources>')]
    defined = dict(re.findall(r'<sys:Double [^>]*x:Key="(FontSize\w+)"[^>]*>([^<]*)</sys:Double>', resources))
    if defined != SCALE:
        problems.append('Échelle typographique des ressources différente : %s' % json.dumps(defined, ensure_ascii=False, sort_keys=True))
    spacing = dict(re.findall(r'<Thickness x:Key="(\w+)">([^<]*)</Thickness>', resources))
    for key, value in SPACING.items():
        if spacing.get(key) != value:
            problems.append('Espacement nommé absent ou différent : %s = %r' % (key, spacing.get(key)))
    # The named spacing follows the metrics of the visual contract shared with the support suite.
    contract = json.loads(read(root / 'wad' / 'modules' / 'SupportSuite.UI.json')).get('Metrics', {})
    for key, metric in (('SpaceStack', 'SpaceSmall'), ('SpaceStackLarge', 'SpaceMedium'), ('PadCard', 'SpaceLarge')):
        size = SPACING[key].split(',')[-1]
        if str(contract.get(metric)) != size:
            problems.append('Espacement %s (%s) différent de la métrique %s du contrat visuel (%s)' % (key, size, metric, contract.get(metric)))
    sources = [root / 'wad' / 'Domenia-Core.ps1'] + sorted(Path(p) for p in glob.glob(str(root / 'wad' / 'modules' / '*.ps1')))
    views = sorted(Path(p) for p in glob.glob(str(root / 'wad' / 'modules' / '*.xaml'))) + [root / 'wad' / 'Domenia-Main.xaml']
    fonts = {}
    for path in sources:
        rel = path.relative_to(root).as_posix()
        text = read(path)
        for owner, count in owner_counts(text, LITERAL_FONT).items():
            fonts[rel + '|' + owner] = count
        for match in FONT_KEY.finditer(text):
            key = match.group(1) or match.group(2)
            if key not in SCALE:
                problems.append('%s : taille nommée inconnue %s' % (rel, key))
    for path in views:
        rel = path.relative_to(root).as_posix()
        text = read(path)
        count = len(LITERAL_FONT.findall(text))
        if count:
            fonts[rel + '|'] = count
        for match in FONT_KEY.finditer(text):
            key = match.group(1) or match.group(2)
            if key not in SCALE:
                problems.append('%s : taille nommée inconnue %s' % (rel, key))
    for function in PAGE_FUNCTIONS:
        if fonts.get('wad/Domenia-Core.ps1|' + function):
            problems.append('Taille de police littérale dans la page : %s (%d)' % (function, fonts['wad/Domenia-Core.ps1|' + function]))
    for path in views:
        rel = path.relative_to(root).as_posix()
        if fonts.get(rel + '|'):
            problems.append('Taille de police littérale dans la vue %s (%d)' % (rel, fonts[rel + '|']))
    spacing_counts = {}
    for path in views:
        spacing_counts[path.relative_to(root).as_posix()] = len(SPACING_LITERAL.findall(read(path)))
    return problems, fonts, spacing_counts


def compare(fonts, spacing_counts, baseline):
    increased = []
    allowed_fonts = baseline.get('FontSizeLiterals', {})
    for key, count in sorted(fonts.items()):
        if count > allowed_fonts.get(key, 0):
            increased.append('Taille de police littérale : %s (%d, référence %d)' % (key, count, allowed_fonts.get(key, 0)))
    allowed_spacing = baseline.get('SpacingLiterals', {})
    for key, count in sorted(spacing_counts.items()):
        if count > allowed_spacing.get(key, 0):
            increased.append('Marge ou remplissage littéral : %s (%d, référence %d)' % (key, count, allowed_spacing.get(key, 0)))
    fixed = sorted(k for k, n in allowed_fonts.items() if fonts.get(k, 0) < n) + \
        sorted(k for k, n in allowed_spacing.items() if spacing_counts.get(k, 0) < n)
    return increased, fixed


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--report', type=Path, help='Écrire le rapport complet (JSON).')
    ap.add_argument('--update-baseline', action='store_true', help='Réécrire la référence après une réduction (jamais une hausse).')
    args = ap.parse_args()
    problems, fonts, spacing_counts = collect()
    baseline = json.loads(read(BASELINE)) if BASELINE.is_file() else {}
    increased, fixed = compare(fonts, spacing_counts, baseline)
    if args.update_baseline:
        if increased and BASELINE.is_file():
            print(json.dumps({'Status': 'FAIL', 'Increased': increased}, ensure_ascii=False, indent=2))
            return 1
        data = {'Schema': SCHEMA,
                'Note': baseline.get('Note', 'Point 112 : tailles de police et marges littérales encore admises, par fichier et fonction. Une hausse fait échouer tools/audit_typography.py.'),
                'FontSizeLiterals': dict(sorted(fonts.items())), 'SpacingLiterals': dict(sorted(spacing_counts.items()))}
        BASELINE.parent.mkdir(parents=True, exist_ok=True)
        with open(BASELINE, 'w', encoding='utf-8', newline='\n') as handle:
            handle.write(json.dumps(data, ensure_ascii=False, indent=2) + '\n')
        baseline = data
        increased, fixed = compare(fonts, spacing_counts, baseline)
    status = 'FAIL' if (problems or increased) else 'PASS'
    report = {'Status': status, 'Problems': problems, 'Increased': increased, 'Fixed': fixed,
              'Scale': SCALE, 'FontSizeLiterals': sum(fonts.values()), 'SpacingLiterals': sum(spacing_counts.values())}
    if args.report:
        args.report.write_text(json.dumps(dict(report, Fonts=fonts, Spacing=spacing_counts), ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 1 if status == 'FAIL' else 0


if __name__ == '__main__':
    sys.exit(main())
