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
  - a right marked LabOnly (domain administrator) never receives Target evidence: Domenia does not require it there;
  - identifiers are closed (systems, protocols, rights), cells are unique, the published page is up to date.
The status of a cell is the strongest valid evidence: Cible > Laboratoire > Synthetique > Non couvert.

Usage:
  python tools/validation_matrix.py              check the matrix and the published page (non zero on any error)
  python tools/validation_matrix.py --write      rewrite engineering/d120/qualification/MATRICE-VALIDATION.md
  python tools/validation_matrix.py --classify-report <campaign.json>
                                                 environment of a campaign report from its recorded facts
Offline: reads files only, never contacts a domain. A status computed here is not a qualification by itself.
"""
from pathlib import Path
import argparse, json, re, sys

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


def check_evidence(evidence, cell, matrix, root, rights):
    """Errors of one evidence and its rank (0 when it does not count)."""
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
    return errors, (0 if errors else RANK[env])


def evaluate(matrix, root=ROOT):
    """Errors of the whole matrix and the status of every cell."""
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
            found, value = check_evidence(evidence, cell, matrix, root, vocab.get('Rights', {}))
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


def main(argv=None):
    ap = argparse.ArgumentParser(description='Matrice de validation Domenia (point 130).')
    ap.add_argument('--write', action='store_true', help='réécrire la page publiée')
    ap.add_argument('--classify-report', metavar='CAMPAGNE', help='environnement dʼun rapport de campagne')
    a = ap.parse_args(argv)
    matrix = load()
    if a.classify_report:
        report = json.loads(Path(a.classify_report).read_text(encoding='utf-8-sig'))
        facts = report.get('Environment') or {}
        print(json.dumps({'Environment': classify(facts.get('Domain'), facts.get('Computer'), matrix),
                          'Domain': facts.get('Domain'), 'Computer': facts.get('Computer'),
                          'Qualifying': bool(report.get('Qualifying'))}, ensure_ascii=False, indent=2))
        return 0
    errors, cells = evaluate(matrix)
    page = render(matrix, cells)
    if a.write and not errors:
        (ROOT / PAGE).write_text(page, encoding='utf-8', newline='\n')
    elif not a.write:
        current = (ROOT / PAGE).read_text(encoding='utf-8') if (ROOT / PAGE).exists() else ''
        if current != page:
            errors.append('Page publiée périmée : relancer tools/validation_matrix.py --write')
    summary = {name: sum(1 for c in cells if c['Status'] == name) for name in STATUS.values()}
    print(json.dumps({'Cells': len(cells), 'Status': summary, 'Errors': errors}, ensure_ascii=False, indent=2))
    return 1 if errors else 0


if __name__ == '__main__':
    sys.exit(main())
