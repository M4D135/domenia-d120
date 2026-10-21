# Generate v2/web/js/parite.js from dev/web/PARITE.json (Domenia 1 WPF control inventory).
import json, sys
src, out = sys.argv[1], sys.argv[2]
root = json.load(open(src, encoding='utf-8'))

SKIP = {'Path', 'Ellipse', 'Track', 'Popup', 'ContentPresenter', 'Canvas', 'UserControl', 'ContentControl', 'GridSplitter'}
MAP = {
    'rechercher': ['Rechercher'],
    'fiche': ['Fiche'],
    'comptes': ['Comptes'],
    'relations': ['Utilisateurs et postes'],
    'poste': ['Poste'],
    'assistance': ['Vue Assistance', 'Vue Support', 'Outils/Assistance'],
    'requetes': ['Vue Query', 'Outils/Atelier de requêtes'],
    'audit': ['Vue AdAudit', 'Outils/Audit AD'],
    'schema': ['Vue DirectorySchema'],
    'synchro': ['Vue DirectorySync'],
    'machine': ['Vue MachineAccount'],
    'operations': ['Vue Operations', 'Outils/Journal'],
    'parametres': ['', 'Outils', 'Outils/Fiabilité', 'Outils/Vérification', 'Outils/Base autonome',
                   'Outils/Charge & stats', 'Outils/Relevés', 'Outils/Domaine', 'Outils/Commandes',
                   'Vue CommandPalette', 'Vue Inline'],
}
NICE = {'Vue Assistance': 'Assistance', 'Vue Support': 'Atelier support', 'Vue Query': 'Atelier de requêtes',
        'Vue AdAudit': 'Audit AD', 'Vue DirectorySchema': 'Schéma de l’annuaire', 'Vue DirectorySync': 'Synchronisation',
        'Vue MachineAccount': 'Comptes machine', 'Vue Operations': 'Opérations', 'Vue CommandPalette': 'Palette de commandes',
        'Vue Inline': 'Confirmations en ligne', '': 'Fenêtre principale'}

ACCENTS = {'Resume': 'Résumé', 'Coordonnees': 'Coordonnées', 'Incidents expliques': 'Incidents expliqués',
           'Reperes de session': 'Repères de session'}

def tab(name):
    name = clean(name)
    return ACCENTS.get(name, name)

def find(path):
    node = root
    if path == '':
        return node
    for part in path.split('/'):
        node = next(c for c in node.get('children', []) if c['tab'] == part)
    return node

def clean(s):
    return ' '.join((s or '').replace('ʼ', '’').split())

def features(node):
    seen, items = set(), []
    for c in node.get('controls', []):
        if c['type'] in SKIP:
            continue
        title = clean(c['help']) or clean(c['label'])
        if len(title) < 3 or title in seen:
            continue
        seen.add(title)
        detail = clean(c['text'])
        if len(detail) > 240:
            detail = detail[:237].rsplit(' ', 1)[0] + '…'
        items.append([title, detail])
    return items

def sections(path, recurse, primary):
    node = find(path)
    base = '' if primary else NICE.get(path, path.split('/')[-1])
    out = []
    def walk(n, label):
        f = features(n)
        if f:
            out.append({'s': label, 'f': f})
        if recurse:
            for ch in n.get('children', []):
                walk(ch, f"{label} › {tab(ch['tab'])}" if label else tab(ch['tab']))
    walk(node, base)
    return out

data = {}
for page, paths in MAP.items():
    secs = []
    for n, p in enumerate(paths):
        secs += sections(p, recurse=(p not in ('', 'Outils')), primary=(n == 0 and p != ''))
    data[page] = secs

total = sum(len(s['f']) for v in data.values() for s in v)
body = json.dumps(data, ensure_ascii=False, separators=(',', ':'))
with open(out, 'w', encoding='utf-8') as fh:
    fh.write('// Domenia 1 functions still to port, grouped by Domenia 2 page. Generated from dev/web/PARITE.json\n')
    fh.write('// (WPF control inventory): s = section ('' = main screen), f = [title, detail]. Regenerate rather than edit by hand.\n')
    fh.write(f'export const PARITE = {body};\n')
print('features', total, {k: sum(len(s['f']) for s in v) for k, v in data.items()})
