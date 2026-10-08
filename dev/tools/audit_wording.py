#!/usr/bin/env python3
"""TE-01: offline audit of the French interface wording. Reads files only; no PowerShell is executed.

Interface strings read (wad/Domenia-Core.ps1, wad/Domenia-Start.ps1, wad/modules):
  - XAML attributes Content, Text, Header and ToolTip (here-strings of the core and modules, module .xaml files);
  - string literals passed to Set-Status, Set-DomeniaContextHint and the message boxes (Show-InfoBox, Show-WarningBox,
    Show-ErrorBox, Confirm-Action, Confirm-WarningAction, Show-DomeniaDialog, [Windows.MessageBox]::Show);
  - string literals assigned in code to the Text, Content, ToolTip and Header properties (« $label.Text = '...' »);
  - Title and Text of wad/modules/Domenia-UX.help.json.
Rules:
  accent    a word written without its accent (Etat, Derniere, Detecter, Perimetre, Synthese, resultat...);
  elision   d, l, n or qu followed by a space instead of an apostrophe (« l OU », « d un », « n est »);
  tutoiement a second-person singular form (tu, ton, ta, tes, Ferme-le, Choisis...): the interface says « vous ».
The reference tools/baselines/wording-baseline.json is a ratchet. Each finding is keyed by rule and exact text, so
moving a sentence between files changes nothing, while a new faulty sentence (or one more copy of an old one) makes
the audit fail. --update rewrites the reference after corrections and refuses any increase.
Integration note: a lot that edits a historical faulty label must correct all of its faults. The key is the whole text,
so a label partly corrected becomes a new text: the old key goes down, the new one goes up and the build fails.
"""
from pathlib import Path
import argparse, html, json, re, sys

ROOT = Path(__file__).resolve().parents[1]
BASELINE = Path('tools/baselines/wording-baseline.json')
SCHEMA = 'DomeniaWordingBaseline/1'

ACCENT_WORDS = '''etat etats derniere dernieres detecter detecte detectee detectees detectes detection detections
perimetre perimetres synthese syntheses resultat resultats selection selections selectionner selectionne selectionnee
selectionnees selectionnes securite reseau reseaux donnee donnees verifier verifie verifiee verifiees verifies
verification verifications precedent precedente precedents precedentes acces operation operations parametre parametres
propriete proprietes element elements requete requetes duree durees activite activites categorie categories memoire
echec echecs ecriture ecritures etape etapes delai delais demarrage demarrer arreter telecharger telechargement systeme
systemes probleme problemes detail details deja apres tres ete cree creee creees crees modifiee modifiees recuperer
recuperation entree entrees cle cles repertoire repertoires numero numeros preference preferences reessayer controle
controles controler elevation generer generee'''.split()
ACCENT_PHRASES = ['a jour', 'a distance', 'a partir']
SECOND_PERSON_START = '''Choisis Saisis Remplis Attends Extrais Prends Reprends Mets Remets Fais Refais Lis Relis Ecris
Écris Reviens Viens Vois Dis Sors Rejoins Peux Veux Dois Sais'''.split()


def _variants(word):
    return {word, word[:1].upper() + word[1:], word.upper()}


ACCENT_RX = re.compile(r'(?<![\w])(' + '|'.join(sorted({v for w in ACCENT_WORDS for v in _variants(w)} |
                                                        {v for p in ACCENT_PHRASES for v in _variants(p)},
                                                        key=len, reverse=True)) + r')(?![\w])')
ELISION_RX = re.compile(r"(?<![\w'ʼ’])([dlnDLN]|[Qq]u) (?=[aeiouyhAEIOUYHàâäéèêëîïôöûüÀÂÉÈÊÎÔÛ])")
SECOND_RX = [
    re.compile(r'(?<![\w])(tu|toi|ton|ta|tes|te|Tu|Toi|Ton|Ta|Tes|Te|TU)(?![\w])'),
    re.compile(r"(?<![\w])[tT]['ʼ’](?=[^\W\d_])"),
    re.compile(r'(?<![\w])[^\W\d_]{2,}(?<!ez)(?<!tes)-(le|la|les|moi|toi|lui|leur|en|y)(?![\w-])'),
    re.compile(r'(?:^|[.!?:;]\s+)(' + '|'.join(SECOND_PERSON_START) + r')(?![\w-])'),
]
XAML_RX = re.compile(r'(?<=\s)(Content|Text|Header|ToolTip)="([^"]*)"')
CALL_RX = re.compile(r'(?<![\w-])(Set-Status|Set-DomeniaContextHint|Show-InfoBox|Show-WarningBox|Show-ErrorBox|Confirm-Action|'
                     r'Confirm-WarningAction|Show-DomeniaDialog)(?![\w-])|\[(?:System\.)?Windows\.MessageBox\]::Show\(')
ASSIGN_RX = re.compile(r'\.(Text|Content|ToolTip|Header)\s*\+?=(?!=)')
LEVELS = {'INFO', 'WARN', 'ERROR', 'OK', 'SUCCESS', 'DEBUG'}


def call_literals(line):
    """String literals of the arguments that follow a call on the same line, up to ; or an unmatched ) or }."""
    out = []
    i, n, depth = 0, len(line), 0
    while i < n:
        c = line[i]
        if c in '\'"':
            q, j, buf = c, i + 1, []
            while j < n:
                if line[j] == q:
                    if j + 1 < n and line[j + 1] == q:
                        buf.append(q); j += 2; continue
                    break
                if q == '"' and line[j] == '`' and j + 1 < n:
                    buf.append(line[j + 1]); j += 2; continue
                buf.append(line[j]); j += 1
            out.append(''.join(buf)); i = j + 1; continue
        if c in '({':
            depth += 1
        elif c in ')}':
            if depth == 0:
                break
            depth -= 1
        elif c == ';' and depth == 0:
            break
        i += 1
    return [s for s in out if s.strip() and s.strip().upper() not in LEVELS]


def collect(root):
    """(file, line, source kind, text) for every interface string."""
    root = Path(root)
    items = []
    sources = ([root / 'wad/Domenia-Core.ps1', root / 'wad/Domenia-Start.ps1'] + sorted((root / 'wad/modules').glob('*.ps1')) +
               sorted((root / 'wad/modules').glob('*.xaml')))
    for path in sources:
        if not path.is_file():
            continue
        rel = path.relative_to(root).as_posix()
        text = path.read_text(encoding='utf-8-sig')
        starts = [0]
        for m in re.finditer('\n', text):
            starts.append(m.end())

        def line_of(pos):
            lo, hi = 0, len(starts) - 1
            while lo < hi:
                mid = (lo + hi + 1) // 2
                if starts[mid] <= pos:
                    lo = mid
                else:
                    hi = mid - 1
            return lo + 1
        for m in XAML_RX.finditer(text):
            value = html.unescape(m.group(2))
            if value.strip() and not value.lstrip().startswith('{'):
                items.append((rel, line_of(m.start()), m.group(1), value))
        if path.suffix == '.ps1':
            for number, line in enumerate(text.split('\n'), 1):
                stripped = line.lstrip()
                if stripped.startswith('#') or stripped.startswith('function '):
                    continue
                for m in CALL_RX.finditer(line):
                    for value in call_literals(line[m.end():]):
                        items.append((rel, number, m.group(1) or 'MessageBox', value))
                for m in ASSIGN_RX.finditer(line):
                    for value in call_literals(line[m.end():]):
                        items.append((rel, number, 'assign.' + m.group(1), value))
    help_path = root / 'wad/modules/Domenia-UX.help.json'
    if help_path.is_file():
        rel = help_path.relative_to(root).as_posix()
        for index, entry in enumerate(json.loads(help_path.read_text(encoding='utf-8-sig'))):
            for key in ('Title', 'Text'):
                value = entry.get(key) if isinstance(entry, dict) else None
                if isinstance(value, str) and value.strip():
                    items.append((rel, index + 1, 'help.' + key, value))
    return items


def findings(root):
    rows = []
    for rel, line, kind, text in collect(root):
        clean = ' '.join(text.split())
        hits = []
        for m in ACCENT_RX.finditer(clean):
            hits.append(('accent', m.group(1)))
        for m in ELISION_RX.finditer(clean):
            hits.append(('elision', m.group(0).strip()))
        for rx in SECOND_RX:
            for m in rx.finditer(clean):
                hits.append(('tutoiement', m.group(0).strip(' .!?:;')))
        for rule in sorted({h[0] for h in hits}):
            words = sorted({h[1] for h in hits if h[0] == rule})
            rows.append({'Rule': rule, 'Text': clean, 'Words': words, 'File': rel, 'Line': line, 'Kind': kind})
    return rows


def counts(rows):
    out = {}
    for r in rows:
        key = r['Rule'] + '|' + r['Text']
        out[key] = out.get(key, 0) + 1
    return out


def compare(current, reference):
    """Keys whose count exceeds the reference (new faulty text) and the number of findings fixed since."""
    exceeded = {k: v - reference.get(k, 0) for k, v in current.items() if v > reference.get(k, 0)}
    fixed = sum(max(0, v - current.get(k, 0)) for k, v in reference.items())
    return exceeded, fixed


def document(current, source):
    rules = {}
    for key, value in current.items():
        rule = key.split('|', 1)[0]
        rules[rule] = rules.get(rule, 0) + value
    return {'Schema': SCHEMA, 'Source': source, 'Total': sum(current.values()), 'Rules': dict(sorted(rules.items())),
            'Findings': dict(sorted(current.items()))}


def load(path):
    data = json.loads(path.read_text(encoding='utf-8'))
    if data.get('Schema') != SCHEMA or not isinstance(data.get('Findings'), dict):
        raise ValueError('Reference de libelles illisible : ' + str(path))
    return data


def write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, 'w', encoding='utf-8', newline='\n') as handle:
        handle.write(json.dumps(data, ensure_ascii=False, indent=1) + '\n')


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--root', type=Path, default=ROOT, help='Racine dev a auditer (par defaut : ce depot).')
    ap.add_argument('--baseline', type=Path, help='Reference (par defaut : tools/baselines/wording-baseline.json sous --root).')
    ap.add_argument('--update', action='store_true', help='Abaisser la reference apres corrections ; toute hausse est refusee.')
    ap.add_argument('--init', action='store_true', help='Creer la reference initiale (refuse si elle existe deja).')
    ap.add_argument('--source', default='', help='Libelle de la source enregistree avec --init ou --update.')
    ap.add_argument('--list', action='store_true', help='Afficher chaque constat (fichier, ligne, regle, texte).')
    a = ap.parse_args(argv)
    root = a.root.resolve()
    baseline = a.baseline or (root / BASELINE)
    rows = findings(root)
    current = counts(rows)
    if a.init:
        if baseline.exists():
            print(json.dumps({'Status': 'FAIL', 'Reason': 'Reference deja presente : utiliser --update.'}, ensure_ascii=False))
            return 1
        write(baseline, document(current, a.source or 'reference initiale'))
        print(json.dumps({'Status': 'INIT', 'Total': sum(current.values())}, ensure_ascii=False))
        return 0
    reference = load(baseline)
    exceeded, fixed = compare(current, reference['Findings'])
    new = [r for r in rows if (r['Rule'] + '|' + r['Text']) in exceeded]
    report = {'Status': 'FAIL' if exceeded else 'PASS', 'Total': sum(current.values()), 'Reference': reference.get('Total', 0),
              'Fixed': fixed, 'New': [{'File': r['File'], 'Line': r['Line'], 'Rule': r['Rule'], 'Words': r['Words'], 'Text': r['Text']} for r in new]}
    if a.update:
        if exceeded:
            report['Reason'] = 'Hausse refusee : corriger les nouveaux libelles avant d abaisser la reference.'
        else:
            write(baseline, document(current, a.source or reference.get('Source', '')))
            report['Status'] = 'UPDATED'
    if a.list:
        for r in rows:
            print('%s:%d [%s] %s : %s' % (r['File'], r['Line'], r['Rule'], ', '.join(r['Words']), r['Text']))
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 1 if exceeded else 0


if __name__ == '__main__':
    sys.exit(main())
