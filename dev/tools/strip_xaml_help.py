#!/usr/bin/env python3
"""P-PF-24: one source for the help texts of the main window. Reads files only; no PowerShell runs.

wad/modules/Domenia-UX.help.json is the only source of the help of a catalogued control: at load time
Initialize-DomeniaUxControlHelp (Domenia-UX.UI.ps1) gives each control of the catalogue its tool tip, its help text
for screen readers and its ShowOnDisabled. The main XAML (Get-MainXaml in wad/Domenia-Core.ps1) therefore carries none
of these three attributes for such a control:
  ToolTip   AutomationProperties.HelpText   ToolTipService.ShowOnDisabled
AutomationProperties.Name stays in the XAML (accessible name before the catalogue loads, and for the tests that read
the XAML). A control absent from the catalogue keeps its attributes: nothing is removed without an entry to replace it.

  (default)  check: the exit code is 1 when a catalogued control carries one of the three attributes again.
  --apply    removes them from the XAML (UTF-8 with BOM and LF kept) and prints what was removed.
  --report   writes the JSON summary to a file.

After a merge that brings back such attributes (a new control written the former way), run --apply then the check:
the texts of the catalogue win, as they already do at run time.
"""
from __future__ import annotations
from pathlib import Path
import argparse
import json
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
CORE = Path('wad/Domenia-Core.ps1')
HELP = Path('wad/modules/Domenia-UX.help.json')
ATTRIBUTES = ('ToolTip', 'AutomationProperties.HelpText', 'ToolTipService.ShowOnDisabled')
ATTRIBUTE_RX = re.compile(r'\s+(ToolTip|AutomationProperties\.HelpText|ToolTipService\.ShowOnDisabled)="([^"]*)"')
NAME_RX = re.compile(r'\sx:Name="([^"]+)"')
START = 'function Get-MainXaml {\n@"\n'
END = '\n"@\n'


def main_xaml_span(core: str):
    """Start and end offsets of the XAML literal of Get-MainXaml."""
    start = core.find(START)
    if start < 0:
        raise ValueError('Get-MainXaml introuvable ou ecrit autrement (here-string attendue juste apres la fonction).')
    start += len(START)
    end = core.find(END, start)
    if end < 0:
        raise ValueError('Fin du XAML principal introuvable.')
    return start, end


def start_tags(xaml: str):
    """Yields (start, end) of every element start tag, comments, declarations and end tags left aside."""
    i, n = 0, len(xaml)
    while i < n:
        lt = xaml.find('<', i)
        if lt < 0:
            return
        if xaml.startswith('<!--', lt):
            close = xaml.find('-->', lt + 4)
            i = n if close < 0 else close + 3
            continue
        if lt + 1 < n and xaml[lt + 1] in '/!?':
            gt = xaml.find('>', lt)
            i = n if gt < 0 else gt + 1
            continue
        j, quote = lt + 1, ''
        while j < n:
            c = xaml[j]
            if quote:
                if c == quote:
                    quote = ''
            elif c in '"\'':
                quote = c
            elif c == '>':
                break
            j += 1
        yield lt, j + 1
        i = j + 1


def load_catalogue(root: Path):
    entries = json.loads((root / HELP).read_text(encoding='utf-8-sig'))
    return {str(e['Name']): e for e in entries}


def analyse(xaml: str, catalogue: dict):
    """Returns the rewritten XAML and the list of findings, one per catalogued element carrying help attributes."""
    out, previous, findings, uncatalogued = [], 0, [], []
    for start, end in start_tags(xaml):
        tag = xaml[start:end]
        name = NAME_RX.search(tag)
        if not name:
            continue
        found = ATTRIBUTE_RX.findall(tag)
        if not found:
            continue
        if name[1] not in catalogue:
            if any(a == 'ToolTip' for a, _ in found):
                uncatalogued.append(name[1])
            continue
        text = str(catalogue[name[1]].get('Text', ''))
        tip = next((v for a, v in found if a == 'ToolTip'), None)
        findings.append({'Name': name[1], 'Attributes': [a for a, _ in found],
                         'Diverged': (tip is not None) and (tip.replace('&quot;', '"').replace('&amp;', '&') != text)})
        out.append(xaml[previous:start])
        out.append(ATTRIBUTE_RX.sub('', tag))
        previous = end
    out.append(xaml[previous:])
    return ''.join(out), findings, uncatalogued


def run(root: Path, apply: bool):
    path = root / CORE
    raw = path.read_bytes()
    bom = raw.startswith(b'\xef\xbb\xbf')
    core = raw.decode('utf-8-sig')
    catalogue = load_catalogue(root)
    start, end = main_xaml_span(core)
    xaml = core[start:end]
    stripped, findings, uncatalogued = analyse(xaml, catalogue)
    summary = {
        'Status': 'PASS' if not findings else ('APPLIED' if apply else 'FAIL'),
        'Catalogued': len(catalogue),
        'ControlsWithHelpAttributes': len(findings),
        'AttributesRemoved': sum(len(f['Attributes']) for f in findings) if apply else 0,
        'DivergedFromCatalogue': sorted(f['Name'] for f in findings if f['Diverged']),
        'UncataloguedWithToolTip': sorted(set(uncatalogued)),
        'XamlBytesBefore': len(xaml.encode('utf-8')),
        'XamlBytesAfter': len(stripped.encode('utf-8')),
        'Controls': [f['Name'] for f in findings][:50],
    }
    if apply and findings:
        text = core[:start] + stripped + core[end:]
        data = text.encode('utf-8')
        path.write_bytes((b'\xef\xbb\xbf' if bom else b'') + data)
    return summary


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--root', type=Path, default=ROOT, help='Dossier dev (par defaut : celui de cet outil).')
    ap.add_argument('--apply', action='store_true', help='Retire les attributs des controles catalogues.')
    ap.add_argument('--report', type=Path, help='Rapport JSON.')
    a = ap.parse_args(argv)
    summary = run(a.root.resolve(), a.apply)
    text = json.dumps(summary, ensure_ascii=False, indent=2)
    if a.report:
        a.report.write_text(text + '\n', encoding='utf-8')
    print(text)
    return 1 if summary['Status'] == 'FAIL' else 0


if __name__ == '__main__':
    sys.exit(main())
