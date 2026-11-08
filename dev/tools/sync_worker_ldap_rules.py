#!/usr/bin/env python3
"""CD-13 / CO-33 / CO-34: keep the worker copies of the LDAP text rules identical to their pure source.

Workers run in their own runspaces with the common worker text ($script:WorkerCommon in wad/Domenia-Core.ps1); they
cannot call the modules of the interface. The RFC 4515 literal (ConvertTo-DomeniaLdapLiteral) and the ADsPath DN
escaping (ConvertTo-DomeniaAdsPathDn) are written once, in wad/modules/Domenia-Search.Model.ps1, and copied into the
common worker text as Escape-WLdap and ConvertTo-WAdsPathDn, between two marker lines.

Default: check only (exit 1 and a diff when the copy differs). --apply rewrites the generated block in place.
The common worker text is not a pinned operation body: no operation hash changes when this block is regenerated.
Reads and writes files only; never runs PowerShell or application code.
"""
from pathlib import Path
import argparse, difflib, re, sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'wad/tests'))
from powershell_lex import functions  # noqa: E402

MODEL = ROOT / 'wad/modules/Domenia-Search.Model.ps1'
CORE = ROOT / 'wad/Domenia-Core.ps1'
# Source function in the pure model -> name of its copy in the common worker text.
RULES = [('ConvertTo-DomeniaLdapLiteral', 'Escape-WLdap'), ('ConvertTo-DomeniaAdsPathDn', 'ConvertTo-WAdsPathDn')]
BEGIN = '# BEGIN generated LDAP text rules: tools/sync_worker_ldap_rules.py from modules/Domenia-Search.Model.ps1. Do not edit here.'
END = '# END generated LDAP text rules'


def source_function(text, name):
    spans = functions(text).get(name, [])
    if len(spans) != 1:
        raise ValueError('Fonction source absente ou ambigue : ' + name)
    start, end = spans[0]
    return text[start:end]


def render():
    model = MODEL.read_text(encoding='utf-8-sig')
    blocks = []
    for source, target in RULES:
        body = source_function(model, source)
        body = re.sub(r'^function\s+' + re.escape(source) + r'\b', 'function ' + target, body, count=1)
        # Comment-only lines document the source; the copy keeps the code only.
        lines = [line for line in body.split('\n') if not re.match(r'^\s*#', line)]
        body = '\n'.join(lines)
        for other, renamed in RULES:
            body = re.sub(r'(?<![\w-])' + re.escape(other) + r'(?![\w-])', renamed, body)
        if re.search(r'(?<![\w-])[A-Za-z]+-Domenia[A-Za-z0-9]+', body):
            raise ValueError('La copie worker appelle encore une fonction de module : ' + target)
        blocks.append(body)
    return BEGIN + '\n' + '\n'.join(blocks) + '\n' + END


def current(core):
    pattern = re.compile(re.escape(BEGIN) + r'\n(?:.*?\n)?' + re.escape(END), re.S)
    found = pattern.findall(core)
    if len(found) != 1:
        raise ValueError('Bloc genere absent ou duplique dans le code commun des workers.')
    common = re.search(r"(?ms)^\$script:WorkerCommon = @'\n(.*?)\n'@", core)
    if common is None or found[0] not in common.group(1):
        raise ValueError('Le bloc genere doit se trouver dans $script:WorkerCommon.')
    return pattern, found[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--apply', action='store_true', help='rewrite the generated block (default: check only)')
    args = parser.parse_args()
    raw = CORE.read_bytes()
    if not raw.startswith(b'\xef\xbb\xbf') or b'\r\n' in raw:
        raise SystemExit('Domenia-Core.ps1 doit rester en UTF-8 avec BOM et fins de ligne LF.')
    core = raw[3:].decode('utf-8')
    pattern, block = current(core)
    expected = render()
    if block == expected:
        print('Copies worker des regles LDAP identiques a Domenia-Search.Model.ps1.')
        return 0
    if not args.apply:
        sys.stdout.writelines(difflib.unified_diff(block.splitlines(True), expected.splitlines(True), 'WorkerCommon', 'Search.Model'))
        print('\nCopie worker differente : relire puis relancer avec --apply.')
        return 1
    updated = pattern.sub(lambda _m: expected, core, count=1)
    CORE.write_bytes(b'\xef\xbb\xbf' + updated.encode('utf-8'))
    print('Bloc genere reecrit dans le code commun des workers.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
