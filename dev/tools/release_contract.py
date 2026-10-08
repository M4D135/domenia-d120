#!/usr/bin/env python3
"""Single release identity (D010) and shipped-component inventory (D117). Offline, no network.

tools/release-contract.json is the ONLY place where the version is written by hand. This tool:
  --check   verifies that every version site of wad/Domenia-Core.ps1, wad/Domenia.release.json and the pinned
            component hashes agree with the contract (exit 1 on any difference);
  --stamp   rewrites the version sites of the core and wad/Domenia.release.json from the contract.
Each site must match its expected number of occurrences: a renamed or duplicated site fails instead of being skipped.
FI-14: RuntimeFileLimit is the ceiling of runtime files that wad/Domenia-Start.ps1 accepts (read from
wad/Domenia.release.json at startup). --check fails above it and warns from 80 % of it, before a lot crosses it.
"""
from pathlib import Path
import argparse, hashlib, json, re, sys

ROOT = Path(__file__).resolve().parents[1]
CONTRACT = ROOT / 'tools' / 'release-contract.json'
CORE = ROOT / 'wad' / 'Domenia-Core.ps1'
RUNTIME_FILE = ROOT / 'wad' / 'Domenia.release.json'
REQUIRED = ('Schema', 'Product', 'Version', 'Release', 'Build', 'DisplayName', 'Channel', 'ReleaseStatus', 'DataSchemaVersion', 'Components')
DEFAULT_RUNTIME_LIMIT = 250
ALERT_RATIO = 0.8

# (name, regex with ONE group = the value, expected count, value builder)
SITES = [
    ('Version', re.compile(r'^\$script:Version = "([^"]*)"$', re.M), 3, lambda c: c['Version']),
    ('MasterBuild', re.compile(r'^\$script:MasterBuild = "([^"]*)"$', re.M), 1, lambda c: c['Build']),
    ('DomeniaBuild', re.compile(r'^\$script:DomeniaBuild = "([^"]*)"$', re.M), 1, lambda c: c['DisplayName']),
    ('NavFooter', re.compile(r'<TextBlock Text="(DOMENIA [^"]*)" Foreground="\{DynamicResource MutedColor\}" FontSize="11"/>'), 1,
     lambda c: 'DOMENIA %s · %s' % (c['Version'], c['Release'])),
    ('ReadyLog', re.compile(r'Add-DomeniaUiLog -Area "Application" -Text "([^"]*) pret\."'), 1, lambda c: c['DisplayName']),
    ('StartTrace', re.compile(r'Write-StartupTrace -Stage "Application" -Status "START" -Detail "(Demarrage [^"]*)"'), 1,
     lambda c: 'Demarrage %s (%s)' % (c['DisplayName'], c['Build'])),
]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_contract():
    contract = json.loads(CONTRACT.read_text(encoding='utf-8-sig'))
    missing = [k for k in REQUIRED if k not in contract or contract[k] in (None, '', [])]
    if missing:
        raise ValueError('Contrat de release incomplet : ' + ', '.join(missing))
    if contract['Schema'] != 'DomeniaReleaseContract/1':
        raise ValueError('Schema de contrat non pris en charge : ' + str(contract['Schema']))
    if not re.fullmatch(r'RC\d+\.\d+\.\d+', contract['Release']):
        raise ValueError('Release invalide : ' + contract['Release'])
    if contract['Release'] not in contract['Build'] or contract['Version'] not in contract['DisplayName']:
        raise ValueError('Build ou DisplayName incoherent avec Version/Release.')
    limit = contract.get('RuntimeFileLimit', DEFAULT_RUNTIME_LIMIT)
    if type(limit) is not int or not 10 <= limit <= 1000:
        raise ValueError('RuntimeFileLimit invalide : entier de 10 a 1000 attendu.')
    return contract


def runtime_limit_state(contract, count):
    """(problem, warning) for the runtime file count against the startup ceiling (FI-14)."""
    limit = contract.get('RuntimeFileLimit', DEFAULT_RUNTIME_LIMIT)
    if count > limit:
        return ('%d fichiers runtime pour un plafond de %d : Domenia-Start refuserait de demarrer.' % (count, limit), '')
    if count >= ALERT_RATIO * limit:
        return ('', 'Alerte plafond : %d fichiers runtime sur %d (80 %% atteints). Relever RuntimeFileLimit avant le prochain ajout.' % (count, limit))
    return ('', '')


def runtime_document(contract):
    keep = ['Schema', 'Product', 'Version', 'Release', 'Build', 'DisplayName', 'Date', 'Channel', 'ReleaseStatus',
            'DataSchemaVersion', 'MinimumPowerShell', 'RuntimeFileLimit', 'Components', 'SystemComponents']
    return {k: contract[k] for k in keep if k in contract}


def check(contract, problems, warnings=None):
    text = CORE.read_text(encoding='utf-8-sig')
    for name, rx, count, value in SITES:
        found = rx.findall(text)
        if len(found) != count:
            problems.append(f'Site de version {name} : {len(found)} occurrence(s), {count} attendue(s).')
            continue
        expected = value(contract)
        for actual in found:
            if actual != expected:
                problems.append(f'Site de version {name} : "{actual}" au lieu de "{expected}".')
    if not RUNTIME_FILE.is_file():
        problems.append('wad/Domenia.release.json absent (lancer --stamp).')
    elif json.loads(RUNTIME_FILE.read_text(encoding='utf-8-sig')) != runtime_document(contract):
        problems.append('wad/Domenia.release.json differe du contrat (lancer --stamp).')
    for comp in contract['Components']:
        path = ROOT / comp['Path']
        if not path.is_file():
            problems.append('Composant absent : ' + comp['Path'])
        elif comp.get('Pinned') and sha(path) != comp['Sha256'].lower():
            problems.append('Composant epingle modifie : ' + comp['Path'])
    # The same runtime list as the packaging tool (imported here only: build_packages reads the contract at import).
    sys.path.insert(0, str(ROOT / 'tools'))
    from build_packages import runtime_paths
    problem, warning = runtime_limit_state(contract, len(runtime_paths(ROOT)))
    if problem:
        problems.append(problem)
    if warning and warnings is not None:
        warnings.append(warning)


def stamp(contract):
    raw = CORE.read_bytes()
    bom = raw.startswith(b'\xef\xbb\xbf')
    text = raw.decode('utf-8-sig')
    for name, rx, count, value in SITES:
        found = rx.findall(text)
        if len(found) != count:
            raise ValueError(f'Site de version {name} : {len(found)} occurrence(s), {count} attendue(s) ; estampillage refuse.')
        expected = value(contract)
        text = rx.sub(lambda m: m.group(0)[:m.start(1) - m.start(0)] + expected + m.group(0)[m.end(1) - m.start(0):], text)
    CORE.write_bytes((b'\xef\xbb\xbf' if bom else b'') + text.encode('utf-8'))
    RUNTIME_FILE.write_text(json.dumps(runtime_document(contract), ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--stamp', action='store_true')
    ap.add_argument('--check', action='store_true')
    a = ap.parse_args()
    contract = load_contract()
    if a.stamp:
        stamp(contract)
    problems = []
    warnings = []
    check(contract, problems, warnings)
    print(json.dumps({'Build': contract['Build'], 'Status': 'FAIL' if problems else 'PASS', 'Problems': problems, 'Warnings': warnings}, ensure_ascii=False, indent=2))
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main())
