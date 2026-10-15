#!/usr/bin/env python3
"""Licence and dependency inventory of the Domenia deliveries (point 146). Offline, no network.

tools/licence-inventory.json lists every delivered component, every third-party source kept in the DEV tree and every
build tool, with its licence and its redistribution status. This tool checks the inventory against the real tree:
  - every binary or asset of the DEV archive (exe, dll, ico, images, fonts, archives, catalogs) and every file under
    vendor/ is covered by exactly one component, and no component names a path that no longer exists;
  - a redistribution is 'Accordee' only on a licence text kept in the repository (LicenceText) or on terms that were
    re-read and dated (Terms with ReviewedOn); a reachable GitHub repository (Depot) or a note is never enough;
  - a third-party binary is bound to the SHA-256 that was reviewed: a replaced file needs a new review;
  - the direct dependencies of the guide builder (guides/package.json) are listed as build tools.
A delivered component whose redistribution is 'NonEtablie' or 'Refusee' is not an inventory error: it is reported as
blocking, and build_packages.py records the delivery as not publishable. Nothing here gives legal advice; the statuses
are those written and dated in the inventory.

Usage: python3 tools/licence_inventory.py --check [--require-publishable] [--report PATH]
"""
from pathlib import Path
import argparse, hashlib, json, re, sys

ROOT = Path(__file__).resolve().parents[1]
INVENTORY = ROOT / 'tools' / 'licence-inventory.json'
SCHEMA = 'DomeniaLicenceInventory/1'
DELIVERIES = ('Livre', 'Systeme', 'Fabrication')
ORIGINS = ('Projet', 'Tiers')
STATUSES = ('Interne', 'Accordee', 'NonEtablie', 'Refusee', 'SansObjet')
EVIDENCE_KINDS = ('Source', 'LicenceText', 'Terms', 'Depot', 'Lock', 'Note')
BLOCKING = ('NonEtablie', 'Refusee')
# Files whose licence is not the project's text licence by default: binaries, images, fonts, archives and catalogs.
COVERED_EXTENSIONS = ('.exe', '.dll', '.sys', '.ocx', '.msi', '.cat', '.zip', '.ico', '.png', '.jpg', '.jpeg', '.gif',
                      '.bmp', '.svg', '.ttf', '.otf', '.woff', '.woff2')
BOUND_EXTENSIONS = ('.exe', '.dll', '.sys', '.ocx', '.msi')
MAX_INVENTORY_BYTES = 1024 * 1024
ID_PATTERN = re.compile(r'^[a-z0-9][a-z0-9-]{0,63}$')
DATE_PATTERN = re.compile(r'^\d{4}-\d{2}-\d{2}$')
SHA_PATTERN = re.compile(r'^[0-9a-fA-F]{64}$')


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest().lower()


def load(path=INVENTORY):
    path = Path(path)
    if path.stat().st_size > MAX_INVENTORY_BYTES:
        raise ValueError('Inventaire des licences trop volumineux : ' + str(path))
    return json.loads(path.read_text(encoding='utf-8-sig'))


def safe_relative(value):
    """A POSIX relative path inside the tree, or '' when the value is not one."""
    text = str(value)
    if not text or text.startswith('/') or '\\' in text or ':' in text:
        return ''
    if any(part in ('', '.', '..') for part in text.rstrip('/').split('/')):
        return ''
    return text


def covers(entry, member):
    return member == entry or (entry.endswith('/') and member.startswith(entry))


def resolve_reference(ref, root, repo):
    """A Source, LicenceText or Lock reference is a file of the DEV tree, or of the repository for guides/..."""
    relative = safe_relative(ref)
    if not relative:
        return None
    for base in (root, repo):
        if base is not None and (Path(base) / relative).is_file():
            return Path(base) / relative
    return None


def text_field(component, name):
    value = component.get(name, '')
    return value.strip() if isinstance(value, str) else ''


def check_component(component, root, repo, problems):
    """Structural and consistency rules of one entry; returns its id ('' when unusable)."""
    if not isinstance(component, dict):
        problems.append('Entree de licence invalide : objet attendu.')
        return ''
    cid = component.get('Id', '')
    if not isinstance(cid, str) or not ID_PATTERN.match(cid):
        problems.append('Identifiant de composant invalide : ' + repr(cid))
        return ''
    label = 'Composant ' + cid + ' : '
    for name in ('Name', 'Licence'):
        if not text_field(component, name):
            problems.append(label + name + ' manquant.')
    delivery = component.get('Delivery')
    origin = component.get('Origin')
    status = component.get('Redistribution')
    if delivery not in DELIVERIES:
        problems.append(label + 'Delivery inconnu (' + repr(delivery) + ').')
    if origin not in ORIGINS:
        problems.append(label + 'Origin inconnu (' + repr(origin) + ').')
    if status not in STATUSES:
        problems.append(label + 'Redistribution inconnue (' + repr(status) + ').')
    paths = component.get('Paths', [])
    if not isinstance(paths, list) or any(not isinstance(p, str) or not safe_relative(p) for p in paths):
        problems.append(label + 'Paths doit lister des chemins relatifs du depot.')
        paths = []
    if delivery == 'Livre' and not paths:
        problems.append(label + 'un composant livre nomme au moins un chemin.')
    if delivery in ('Systeme', 'Fabrication') and status != 'SansObjet':
        problems.append(label + 'un composant non livre a la redistribution SansObjet.')
    if delivery == 'Livre' and status == 'SansObjet':
        problems.append(label + 'un composant livre a un statut de redistribution.')
    if status == 'Interne' and origin != 'Projet':
        problems.append(label + 'Interne est reserve au code du projet.')
    if delivery == 'Livre' and origin == 'Projet' and status not in ('Interne', 'Accordee'):
        problems.append(label + 'le code du projet livre est Interne ou Accordee.')
    evidence = component.get('Evidence', [])
    if not isinstance(evidence, list) or not evidence:
        problems.append(label + 'au moins une preuve (Evidence) est requise.')
        evidence = []
    kinds = []
    for item in evidence:
        if not isinstance(item, dict) or item.get('Kind') not in EVIDENCE_KINDS or not text_field(item, 'Ref'):
            problems.append(label + 'preuve invalide : Kind connu et Ref requis.')
            continue
        kind = item['Kind']
        kinds.append(kind)
        if kind in ('Source', 'LicenceText', 'Lock') and resolve_reference(item['Ref'], root, repo) is None:
            problems.append(label + 'preuve ' + kind + ' introuvable : ' + item['Ref'])
        if kind == 'Terms' and not DATE_PATTERN.match(str(item.get('ReviewedOn', ''))):
            problems.append(label + 'conditions (Terms) sans date de relecture ReviewedOn.')
    if status == 'Accordee' and not any(k in ('LicenceText', 'Terms') for k in kinds):
        problems.append(label + 'Accordee exige un texte de licence joint ou des conditions relues et datees ; '
                        'une source GitHub accessible ne suffit pas.')
    if status in BLOCKING and not text_field(component, 'Alternative'):
        problems.append(label + 'une redistribution ' + status + ' indique une alternative.')
    pins = component.get('Sha256', {})
    if pins is None:
        pins = {}
    if not isinstance(pins, dict):
        problems.append(label + 'Sha256 doit associer un chemin a une empreinte.')
        pins = {}
    for path, value in pins.items():
        if path not in paths or not SHA_PATTERN.match(str(value)):
            problems.append(label + 'empreinte invalide ou hors de Paths : ' + str(path))
    if delivery == 'Livre' and origin == 'Tiers':
        for path in paths:
            if path.endswith('/') or not path.lower().endswith(BOUND_EXTENSIONS):
                continue
            expected = str(pins.get(path, '')).lower()
            if not expected:
                problems.append(label + 'binaire tiers sans empreinte relue : ' + path)
                continue
            target = Path(root) / path
            if target.is_file() and digest(target) != expected:
                problems.append(label + 'binaire tiers different de celui dont la licence a ete relue : ' + path
                                + ' (relire la licence de ce fichier, puis mettre a jour l empreinte).')
    return cid


def validate(inventory, root=ROOT, repo=None, members=None):
    """(problems, report) for an inventory against the tree. members: DEV archive paths (default: build_packages)."""
    root = Path(root)
    repo = Path(repo) if repo is not None else root.parent
    problems = []
    if not isinstance(inventory, dict) or inventory.get('Schema') != SCHEMA:
        return ['Schema de l inventaire des licences non pris en charge.'], None
    if not DATE_PATTERN.match(str(inventory.get('ReviewedOn', ''))):
        problems.append('ReviewedOn manquant ou invalide (AAAA-MM-JJ).')
    components = inventory.get('Components')
    if not isinstance(components, list) or not components:
        return problems + ['Aucun composant dans l inventaire des licences.'], None
    seen = set()
    for component in components:
        cid = check_component(component, root, repo, problems)
        if cid:
            if cid in seen:
                problems.append('Composant en double : ' + cid)
            seen.add(cid)
    if members is None:
        sys.path.insert(0, str(ROOT / 'tools'))
        from build_packages import select_members
        members = select_members(root)
    entries = [(c.get('Id', ''), p) for c in components if isinstance(c, dict)
               for p in (c.get('Paths') if isinstance(c.get('Paths'), list) else []) if isinstance(p, str)]
    for member in members:
        if not (member.lower().endswith(COVERED_EXTENSIONS) or member.startswith('vendor/')):
            continue
        owners = sorted({cid for cid, entry in entries if covers(entry, member)})
        if not owners:
            problems.append('Fichier sans entree de licence : ' + member)
        elif len(owners) > 1:
            problems.append('Fichier couvert par plusieurs entrees (' + ', '.join(owners) + ') : ' + member)
    for cid, entry in entries:
        if not any(covers(entry, member) for member in members):
            problems.append('Composant ' + cid + ' : chemin absent de l arbre livre : ' + entry)
    packages = {c.get('Package') for c in components if isinstance(c, dict) and c.get('Delivery') == 'Fabrication'}
    manifest = repo / 'guides' / 'package.json'
    lock_rows = []
    if manifest.is_file():
        declared = json.loads(manifest.read_text(encoding='utf-8-sig'))
        for name in sorted((declared.get('dependencies') or {}).keys()) + sorted((declared.get('devDependencies') or {}).keys()):
            if name not in packages:
                problems.append('Dependance de fabrication des guides sans entree : ' + name)
        lock = repo / 'guides' / 'package-lock.json'
        if lock.is_file():
            data = json.loads(lock.read_text(encoding='utf-8-sig'))
            for key, value in sorted((data.get('packages') or {}).items()):
                if key.startswith('node_modules/') and isinstance(value, dict):
                    lock_rows.append({'Package': key[len('node_modules/'):], 'Version': value.get('version', ''),
                                      'DeclaredLicence': value.get('license', '')})
    blocking = [{'Id': c['Id'], 'Name': c.get('Name', ''), 'Redistribution': c.get('Redistribution'),
                 'Alternative': text_field(c, 'Alternative')}
                for c in components if isinstance(c, dict) and c.get('Delivery') == 'Livre'
                and c.get('Redistribution') in BLOCKING and isinstance(c.get('Id'), str)]
    rows = [{'Id': c.get('Id', ''), 'Name': c.get('Name', ''), 'Delivery': c.get('Delivery', ''),
             'Origin': c.get('Origin', ''), 'Licence': c.get('Licence', ''),
             'Redistribution': c.get('Redistribution', ''), 'Paths': c.get('Paths', [])}
            for c in components if isinstance(c, dict)]
    report = {'Schema': SCHEMA, 'ReviewedOn': inventory.get('ReviewedOn', ''), 'Components': rows,
              'Blocking': blocking, 'Publishable': not blocking,
              'BuildToolPackages': lock_rows,
              'BuildToolNote': 'Licences npm telles que declarees par package-lock.json (metadonnees du paquet, non relues).',
              'Rule': inventory.get('Rule', '')}
    return problems, report


def summary(root=ROOT, repo=None, path=None):
    """Report used by build_packages.py; raises ValueError when the inventory itself is invalid."""
    problems, report = validate(load(path or (Path(root) / 'tools' / 'licence-inventory.json')), root, repo)
    if problems:
        raise ValueError('Inventaire des licences invalide :\n' + '\n'.join(problems))
    return report


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--check', action='store_true', help='Verifier l inventaire contre l arbre (defaut).')
    ap.add_argument('--require-publishable', action='store_true',
                    help='Echouer aussi quand un composant livre a une redistribution NonEtablie ou Refusee.')
    ap.add_argument('--report', type=Path, help='Ecrire le rapport JSON a ce chemin.')
    args = ap.parse_args()
    problems, report = validate(load())
    status = 'FAIL' if problems else 'PASS'
    if not problems and args.require_publishable and report and not report['Publishable']:
        status = 'BLOCKED'
    output = {'Status': status, 'Problems': problems,
              'Blocking': report['Blocking'] if report else [], 'Publishable': bool(report and report['Publishable'])}
    if args.report and report is not None:
        args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(output, ensure_ascii=False, indent=2))
    return 0 if status == 'PASS' else 1


if __name__ == '__main__':
    sys.exit(main())
