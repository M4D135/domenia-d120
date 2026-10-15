#!/usr/bin/env python3
"""Point 130: validation matrix of Domenia by system, protocol and right, laboratory kept apart from the real domain.

The matrix (engineering/d120/qualification/validation-matrix.json) lists the cells Domenia must be validated on and the
evidence collected for each cell. Every evidence states its environment:
  Synthetic  a test suite whose network, directory or workstation is replaced by doubles (wad/tests);
  Lab        a report produced in the laboratory domain (LabDomains / LabHosts of the matrix);
  Target     a report produced on the real domain, by a host that is not a laboratory host.
Rules enforced (an error makes the command fail):
  - a synthetic evidence names an existing test file and no domain, host or report: it never proves a network;
  - a Lab or Target evidence names its report file, its SHA-256, its date, its domain and its host;
  - a report produced in the laboratory domain or on a laboratory host is never accepted as Target evidence;
  - when the report file is readable here, its SHA-256 is recomputed and its environment is classified from the facts
    it recorded itself (Environment block of Invoke-D120Campaign.ps1): any difference with the declared hash, domain,
    host or environment is an error. A report that is not readable here is listed as not re-read (not an error: reports
    are kept outside dev, often on the machine that produced them);
  - a right marked LabOnly (domain administrator) never receives Target evidence: Domenia does not require it there;
  - identifiers are closed (systems, protocols, rights), cells are unique, the published page is up to date.
The status of a cell is the strongest valid evidence: Cible > Laboratoire > Synthetique > Non couvert.

Usage:
  python tools/validation_matrix.py              check the matrix and the published page (non zero on any error)
  python tools/validation_matrix.py --write      rewrite engineering/d120/qualification/MATRICE-VALIDATION.md
  python tools/validation_matrix.py --classify-report <campaign.json>
                                                 environment of a campaign report from its recorded facts
  python tools/validation_matrix.py --add-evidence <campaign.json> --cell SYSTEME/PROTOCOLE/DROIT [--note TEXTE]
                                                 add a Lab or Target evidence built from the report itself (hash,
                                                 domain, host and date read from the file, never typed), then rewrite
                                                 the matrix and the published page
Offline: reads files only, never contacts a domain. A status computed here is not a qualification by itself.
"""
from pathlib import Path
import argparse, hashlib, json, re, sys

ROOT = Path(__file__).resolve().parents[1]
MATRIX = Path('engineering/d120/qualification/validation-matrix.json')
PAGE = Path('engineering/d120/qualification/MATRICE-VALIDATION.md')
SCHEMA = 'DomeniaValidationMatrix/1'
ENVIRONMENTS = ('Synthetic', 'Lab', 'Target')
RANK = {'Target': 3, 'Lab': 2, 'Synthetic': 1}
STATUS = {3: 'Cible', 2: 'Laboratoire', 1: 'Synthétique', 0: 'Non couvert'}
SHORT = {3: 'C', 2: 'L', 1: 'S', 0: '·'}
SHA = re.compile(r'^[0-9a-fA-F]{64}$')
DATE = re.compile(r'^\d{4}-\d{2}-\d{2}$')
ID = re.compile(r'^[a-z0-9][a-z0-9-]{1,40}$')


def norm(value):
    return str(value or '').strip().rstrip('.').lower()


def classify(domain, computer, matrix):
    """Environment of a report from its facts: Lab when its domain or its host is a laboratory one, else Target.
    Unknown when the domain is missing: a report without its domain proves nothing about a network."""
    labs = {norm(d) for d in matrix.get('LabDomains', [])}
    hosts = {norm(h) for h in matrix.get('LabHosts', [])}
    d, c = norm(domain), norm(computer)
    if not d:
        return 'Unknown'
    if d in labs or any(d.endswith('.' + lab) for lab in labs) or c in hosts:
        return 'Lab'
    return 'Target'


def report_facts(path):
    """Facts of a campaign report read from the file itself: SHA-256 of its bytes, domain and host recorded in its
    Environment block, date (AAAA-MM-JJ) of its last finished step. Raises OSError or ValueError when unreadable."""
    data = Path(path).read_bytes()
    try:
        report = json.loads(data.decode('utf-8-sig'))
    except ValueError as exc:
        raise ValueError('rapport illisible (%s) : %s' % (path, exc))
    if not isinstance(report, dict):
        raise ValueError('rapport sans objet JSON : %s' % path)
    facts = report.get('Environment') if isinstance(report.get('Environment'), dict) else {}
    ended = sorted(str(step.get('EndedUtc') or '')[:10] for step in (report.get('Steps') or [])
                   if isinstance(step, dict) and DATE.match(str(step.get('EndedUtc') or '')[:10]))
    return {'Sha256': hashlib.sha256(data).hexdigest(), 'Domain': str(facts.get('Domain') or '').strip(),
            'Computer': str(facts.get('Computer') or '').strip(), 'Date': ended[-1] if ended else '',
            'Kind': str(report.get('Kind') or ''), 'Qualifying': bool(report.get('Qualifying'))}


def verify_report(evidence, matrix, where):
    """Errors when the report named by a Lab or Target evidence is readable here and differs from the declaration.
    Returns (errors, re_read)."""
    reference = str(evidence.get('Report', '')).strip()
    if not reference or not Path(reference).is_file():
        return [], False
    try:
        facts = report_facts(reference)
    except (OSError, ValueError) as exc:
        return ['%s : %s' % (where, exc)], True
    errors = []
    if facts['Sha256'] != str(evidence.get('Sha256', '')).strip().lower():
        errors.append('%s : SHA-256 du rapport différent de lʼempreinte déclarée' % where)
    if (norm(facts['Domain']) != norm(evidence.get('Domain'))) or (norm(facts['Computer']) != norm(evidence.get('Computer'))):
        errors.append('%s : domaine et poste déclarés (%s, %s) différents de ceux relevés dans le rapport (%s, %s)'
                      % (where, evidence.get('Domain'), evidence.get('Computer'), facts['Domain'], facts['Computer']))
    actual = classify(facts['Domain'], facts['Computer'], matrix)
    if actual != evidence.get('Environment'):
        errors.append('%s : le rapport lui-même relève de lʼenvironnement %s, pas %s'
                      % (where, actual, evidence.get('Environment')))
    return errors, True


def check_evidence(evidence, cell, matrix, root, rights, unread=None):
    """Errors of one evidence and its rank (0 when it does not count). unread collects the reports not re-read here."""
    errors = []
    where = '%s/%s/%s' % (cell.get('System'), cell.get('Protocol'), cell.get('Right'))
    env = evidence.get('Environment')
    if env not in ENVIRONMENTS:
        return ['%s : environnement inconnu %r' % (where, env)], 0
    if env == 'Synthetic':
        ref = str(evidence.get('Reference', ''))
        if not ref or not (root / ref).is_file():
            errors.append('%s : preuve synthétique sans fichier de test existant (%r)' % (where, ref))
        if not ref.startswith('wad/tests/'):
            errors.append('%s : une preuve synthétique désigne une suite de wad/tests (%r)' % (where, ref))
        for field in ('Domain', 'Computer', 'Report', 'Sha256'):
            if evidence.get(field):
                errors.append('%s : une preuve synthétique ne porte ni domaine, ni poste, ni rapport (%s)' % (where, field))
        return errors, (0 if errors else RANK[env])
    for field in ('Report', 'Sha256', 'Date', 'Domain', 'Computer'):
        if not str(evidence.get(field, '')).strip():
            errors.append('%s : preuve %s sans %s' % (where, env, field))
    if evidence.get('Sha256') and not SHA.match(str(evidence['Sha256'])):
        errors.append('%s : empreinte SHA-256 invalide' % where)
    if evidence.get('Date') and not DATE.match(str(evidence['Date'])):
        errors.append('%s : date attendue AAAA-MM-JJ' % where)
    if str(evidence.get('Report', '')).startswith('wad/tests/'):
        errors.append('%s : une suite de test nʼest pas un rapport dʼexécution' % where)
    actual = classify(evidence.get('Domain'), evidence.get('Computer'), matrix)
    if env == 'Target' and actual != 'Target':
        errors.append('%s : rapport du laboratoire (%s, %s) présenté comme preuve du domaine cible'
                      % (where, evidence.get('Domain'), evidence.get('Computer')))
    if env == 'Lab' and actual != 'Lab':
        errors.append('%s : rapport hors laboratoire (%s, %s) déclaré comme laboratoire'
                      % (where, evidence.get('Domain'), evidence.get('Computer')))
    if env == 'Target' and rights.get(cell.get('Right'), {}).get('LabOnly'):
        errors.append('%s : droit réservé au laboratoire, aucune preuve sur le domaine cible' % where)
    found, re_read = verify_report(evidence, matrix, where)
    errors.extend(found)
    if (not re_read) and (unread is not None):
        unread.append('%s : %s' % (where, evidence.get('Report')))
    return errors, (0 if errors else RANK[env])


def evaluate(matrix, root=ROOT, unread=None):
    """Errors of the whole matrix and the status of every cell. unread collects the reports not re-read here."""
    errors = []
    if matrix.get('Schema') != SCHEMA:
        errors.append('Schéma attendu %s' % SCHEMA)
    vocab = {}
    for key in ('Systems', 'Protocols', 'Rights'):
        items = matrix.get(key) or []
        ids = [str(i.get('Id', '')) for i in items]
        if not items or len(ids) != len(set(ids)) or any(not ID.match(i) for i in ids):
            errors.append('%s : identifiants absents, invalides ou en double' % key)
        vocab[key] = {str(i.get('Id')): i for i in items}
    if not matrix.get('LabDomains'):
        errors.append('LabDomains absent : impossible de distinguer laboratoire et domaine réel')
    seen, cells = set(), []
    for cell in matrix.get('Cells') or []:
        key = (cell.get('System'), cell.get('Protocol'), cell.get('Right'))
        for value, kind in zip(key, ('Systems', 'Protocols', 'Rights')):
            if value not in vocab.get(kind, {}):
                errors.append('Cellule %s : %s inconnu (%r)' % ('/'.join(map(str, key)), kind, value))
        if key in seen:
            errors.append('Cellule en double : %s' % '/'.join(map(str, key)))
        seen.add(key)
        if not str(cell.get('Scenario', '')).strip():
            errors.append('Cellule %s : scénario absent' % '/'.join(map(str, key)))
        rank, kinds = 0, []
        for evidence in cell.get('Evidence') or []:
            found, value = check_evidence(evidence, cell, matrix, root, vocab.get('Rights', {}), unread)
            errors.extend(found)
            rank = max(rank, value)
            if value:
                kinds.append(evidence['Environment'])
        cells.append(dict(cell, Rank=rank, Status=STATUS[rank]))
    return errors, cells


def render(matrix, cells):
    """Deterministic French page: one table per system (protocols x rights), then the detail of every cell."""
    systems = matrix['Systems']; protocols = matrix['Protocols']; rights = matrix['Rights']
    by_key = {(c['System'], c['Protocol'], c['Right']): c for c in cells}
    counts = {name: sum(1 for c in cells if c['Status'] == name) for name in STATUS.values()}
    lines = ['# Matrice de validation Domenia', '',
             'Page générée par `tools/validation_matrix.py --write` depuis `validation-matrix.json` : ne pas la modifier à la main.', '',
             'Chaque cellule croise un système, un protocole et un droit. Son état est la preuve valide la plus forte :', '',
             '- **C** : *Cible* — rapport dʼexécution produit sur le domaine réel, hors domaine et postes du laboratoire.',
             '- **L** : *Laboratoire* — rapport produit dans le domaine du laboratoire (%s).' % ', '.join(matrix.get('LabDomains', [])),
             '- **S** : *Synthétique* — suite de test dont le réseau, lʼannuaire ou le poste sont remplacés par des doubles. '
             'Une preuve synthétique ne prouve jamais le comportement du réseau cible.',
             '- **·** : *Non couvert* — aucune preuve.', '- **—** : combinaison sans objet.', '',
             'Bilan : %d cellule(s) prouvée(s) sur le domaine cible, %d en laboratoire, %d seulement synthétique(s), %d non couverte(s).'
             % (counts['Cible'], counts['Laboratoire'], counts['Synthétique'], counts['Non couvert']), '']
    for system in systems:
        if not any(k[0] == system['Id'] for k in by_key):
            continue
        lines += ['## ' + system['Label'], '', '| Protocole | ' + ' | '.join(r['Label'] for r in rights) + ' |',
                  '|---|' + '---|' * len(rights)]
        for protocol in protocols:
            row = []
            for right in rights:
                cell = by_key.get((system['Id'], protocol['Id'], right['Id']))
                row.append('—' if cell is None else SHORT[cell['Rank']])
            if all(v == '—' for v in row):
                continue
            lines.append('| ' + protocol['Label'] + ' | ' + ' | '.join(row) + ' |')
        lines.append('')
    lines += ['## Détail des cellules', '']
    labels = {k: {i['Id']: i['Label'] for i in matrix[k]} for k in ('Systems', 'Protocols', 'Rights')}
    for cell in cells:
        lines.append('- **%s · %s · %s** — %s. État : %s.' % (labels['Systems'][cell['System']], labels['Protocols'][cell['Protocol']],
                                                         labels['Rights'][cell['Right']], cell['Scenario'], cell['Status']))
        for evidence in cell.get('Evidence') or []:
            if evidence.get('Environment') == 'Synthetic':
                lines.append('  - Synthétique : `%s`%s' % (evidence.get('Reference'), (' — ' + evidence['Note']) if evidence.get('Note') else ''))
            else:
                lines.append('  - %s : `%s` (SHA-256 %s, %s, %s sur %s)%s' % (
                    {'Lab': 'Laboratoire', 'Target': 'Cible'}.get(evidence.get('Environment'), evidence.get('Environment')),
                    evidence.get('Report'), str(evidence.get('Sha256', ''))[:12], evidence.get('Date'), evidence.get('Computer'),
                    evidence.get('Domain'), (' — ' + evidence['Note']) if evidence.get('Note') else ''))
        if cell.get('Notes'):
            lines.append('  - Remarque : ' + cell['Notes'])
    return '\n'.join(lines) + '\n'


def load(root=ROOT):
    return json.loads((root / MATRIX).read_text(encoding='utf-8'))


def add_evidence(matrix, report_path, cell_key, note='', root=ROOT):
    """Adds to one cell (SYSTEME/PROTOCOLE/DROIT) the Lab or Target evidence of a campaign report. Hash, domain, host
    and date come from the file, and the environment from those facts: nothing is typed. Returns the errors (the matrix
    is left unchanged when there is one) and the evidence added."""
    parts = str(cell_key or '').split('/')
    if len(parts) != 3:
        return ['Cellule attendue SYSTEME/PROTOCOLE/DROIT : %r' % cell_key], None
    cell = next((c for c in matrix.get('Cells') or [] if (c.get('System'), c.get('Protocol'), c.get('Right')) == tuple(parts)), None)
    if cell is None:
        return ['Cellule inconnue : %s' % cell_key], None
    try:
        facts = report_facts(report_path)
    except (OSError, ValueError) as exc:
        return ['Rapport illisible : %s' % exc], None
    environment = classify(facts['Domain'], facts['Computer'], matrix)
    if environment == 'Unknown':
        return ['Rapport sans domaine relevé (bloc Environment) : il ne prouve rien sur un réseau.'], None
    if not facts['Date']:
        return ['Rapport sans étape terminée datée : date dʼexécution inconnue.'], None
    if any(str(e.get('Sha256', '')).lower() == facts['Sha256'] for e in cell.get('Evidence') or []):
        return ['Rapport déjà enregistré pour la cellule %s.' % cell_key], None
    evidence = {'Environment': environment, 'Report': str(Path(report_path).resolve()), 'Sha256': facts['Sha256'],
                'Date': facts['Date'], 'Domain': facts['Domain'], 'Computer': facts['Computer']}
    if note:
        evidence['Note'] = str(note)
    rights = {str(r.get('Id')): r for r in matrix.get('Rights') or []}
    errors, _ = check_evidence(evidence, cell, matrix, root, rights)
    if errors:
        return errors, None
    cell.setdefault('Evidence', []).append(evidence)
    return [], evidence


def main(argv=None):
    ap = argparse.ArgumentParser(description='Matrice de validation Domenia (point 130).')
    ap.add_argument('--write', action='store_true', help='réécrire la page publiée')
    ap.add_argument('--classify-report', metavar='CAMPAGNE', help='environnement dʼun rapport de campagne')
    ap.add_argument('--add-evidence', metavar='CAMPAGNE', help='ajouter la preuve dʼun rapport de campagne à une cellule')
    ap.add_argument('--cell', metavar='SYSTEME/PROTOCOLE/DROIT', help='cellule de la preuve ajoutée')
    ap.add_argument('--note', default='', help='remarque de la preuve ajoutée')
    a = ap.parse_args(argv)
    matrix = load()
    if a.classify_report:
        facts = report_facts(a.classify_report)
        print(json.dumps({'Environment': classify(facts['Domain'], facts['Computer'], matrix), 'Domain': facts['Domain'],
                          'Computer': facts['Computer'], 'Date': facts['Date'], 'Sha256': facts['Sha256'],
                          'Qualifying': facts['Qualifying']}, ensure_ascii=False, indent=2))
        return 0
    if a.add_evidence:
        found, evidence = add_evidence(matrix, a.add_evidence, a.cell, a.note)
        if not found:
            # The whole matrix must stay valid before anything is written.
            found, _ = evaluate(matrix)
        if found:
            print(json.dumps({'Added': None, 'Errors': found}, ensure_ascii=False, indent=2))
            return 1
        (ROOT / MATRIX).write_text(json.dumps(matrix, ensure_ascii=False, indent=2) + '\n', encoding='utf-8', newline='\n')
        a.write = True
        print(json.dumps({'Added': evidence}, ensure_ascii=False, indent=2))
    unread = []
    errors, cells = evaluate(matrix, unread=unread)
    page = render(matrix, cells)
    if a.write and not errors:
        (ROOT / PAGE).write_text(page, encoding='utf-8', newline='\n')
    elif not a.write:
        current = (ROOT / PAGE).read_text(encoding='utf-8') if (ROOT / PAGE).exists() else ''
        if current != page:
            errors.append('Page publiée périmée : relancer tools/validation_matrix.py --write')
    summary = {name: sum(1 for c in cells if c['Status'] == name) for name in STATUS.values()}
    print(json.dumps({'Cells': len(cells), 'Status': summary, 'ReportsNotReread': unread, 'Errors': errors}, ensure_ascii=False, indent=2))
    return 1 if errors else 0


if __name__ == '__main__':
    sys.exit(main())
