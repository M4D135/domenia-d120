# Generate v2/web/js/parite.js from dev/web/PARITE.json (Domenia 1 WPF control inventory).
#   python3 tools/gen_parite.py ../dev/web/PARITE.json web/js/parite.js
# WPF bindings ({Binding …}) are dropped. Status or placeholder sentences of text blocks (« Arbre prêt. »,
# « Sélectionnez un objet. ») are not functions: they go to one group per page, flagged m = 1 (« États et consignes »),
# so their wording and guarantees stay in the list without being counted as functions. Texts get the French typography of FrenchText (typographic apostrophe,
# no-break spaces inside « », before « : » and « % », between thousands and after a number) and the known typos of
# Domenia 1 are fixed here, never in the generated file.
import json, re, sys
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

NBSP, NNBSP = '\u00a0', '\u202f'
# Typos of the Domenia 1 inventory (missing accents), fixed on the way.
TYPOS = [(r'\bCreer\b', 'Créer'), (r'\bcreer\b', 'créer'), (r'\battributs affiches\b', 'attributs affichés'),
         (r'\bPret\b', 'Prêt'), (r'\bpret\b', 'prêt'), (r'\bchargee(s?)\b', r'chargée\1'), (r'\baffichee(s?)\b', r'affichée\1'),
         (r'\bciblee\b', 'ciblée'), (r'\bdiagnostic invente\b', 'diagnostic inventé'), (r'\bdesactive', 'désactive'),
         (r'\bautomatique a la\b', 'automatique à la'),
         (r'\bPrenom\b', 'Prénom'), (r'\bTelephone\b', 'Téléphone'), (r'\b([Dd])everrouill', r'\1éverrouill'),
         (r'\bdelegable\b', 'délégable'), (r'\bDelegation\b', 'Délégation'), (r'\bdelegation\b', 'délégation'),
         (r'\bapprouvee\b', 'approuvée'), (r'\bpre-authentification\b', 'pré-authentification'), (r'\bparait\b', 'paraît'),
         (r'\bSociete\b', 'Société'), (r'\bentite\b', 'entité'), (r'\bDepartement\b', 'Département'), (r'\bregion\b', 'région'),
         (r'\bReactive\b', 'Réactive'), (r'\bcontroleur\b', 'contrôleur'), (r'\ble resume\b', 'le résumé'),
         (r'\binterrogee\b', 'interrogée'), (r'\bNom affiche\b', 'Nom affiché'),
         (r'\b([Dd])ecochee\b', r'\1écochée'), (r'\b([Cc])ochee\b', r'\1ochée'), (r'\btestee\b', 'testée'), (r'\bPortee\b', 'Portée'),
         (r'\bepinglee\b', 'épinglée'), (r'\bplanifiee\b', 'planifiée'), (r'\brattrapees\b', 'rattrapées'), (r'\bagregees\b', 'agrégées'),
         (r'\bmembre indique\b', 'membre indiqué')]

def typography(s):
    s = s.replace("'", '’')
    s = re.sub(r'«\s*', '«' + NBSP, s)
    s = re.sub(r'\s*»', NBSP + '»', s)
    s = re.sub(r'\s+([:%])', NBSP + r'\1', s)
    s = re.sub(r'\s+([;?!])', NNBSP + r'\1', s)
    # 20 000 → 20 000 (thin no-break space), never cut inside a number.
    s = re.sub(r'(?<=\d) (?=\d{3}\b)', NNBSP, s)
    # A number stays with the word that follows it (« 7 derniers jours », « 3 postes »).
    s = re.sub(r'(?<=\b\d) (?=[A-Za-zÀ-ÿ])|(?<=\d\d) (?=[A-Za-zÀ-ÿ])', NBSP, s)
    return s

def clean(s):
    s = ' '.join((s or '').replace('ʼ', '’').split())
    for pattern, fixed in TYPOS:
        s = re.sub(pattern, fixed, s)
    return typography(s)

def kind(c, title):
    """« binding » (dropped), « message » (status or placeholder sentence of a text block) or « function »."""
    raw = ' '.join(str(c.get(k) or '') for k in ('label', 'help', 'text'))
    if '{Binding' in raw or title.startswith('{'):
        return 'binding'
    if c['type'] in ('TextBlock', 'Label', 'Run') and not clean(c.get('help')) and not clean(c.get('text')) \
            and re.search(r'[.…]$', title):
        return 'message'
    return 'function'

MESSAGES = 'États et consignes de l’écran'
messages = []

def features(node):
    seen, items = set(), []
    for c in node.get('controls', []):
        if c['type'] in SKIP:
            continue
        title = clean(c['help']) or clean(c['label'])
        if len(title) < 3 or title in seen:
            continue
        k = kind(c, title)
        if k == 'binding':
            continue
        if k == 'message':
            seen.add(title)
            messages.append(title)
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
        before = len(messages)
        f = features(n)
        if f:
            out.append({'s': label, 'f': f})
        # A message says where it appears (the section), as the detail of its line.
        for at in range(before, len(messages)):
            messages[at] = [messages[at], label or 'Écran principal']
        if recurse:
            for ch in n.get('children', []):
                walk(ch, f"{label} › {tab(ch['tab'])}" if label else tab(ch['tab']))
    walk(node, base)
    return out

data = {}
for page, paths in MAP.items():
    secs = []
    messages.clear()
    for n, p in enumerate(paths):
        secs += sections(p, recurse=(p not in ('', 'Outils')), primary=(n == 0 and p != ''))
    if messages:
        secs.append({'s': MESSAGES, 'm': 1, 'f': [m for m in messages]})
    data[page] = secs

total = sum(len(s['f']) for v in data.values() for s in v if not s.get('m'))
body = json.dumps(data, ensure_ascii=False, separators=(',', ':'))
with open(out, 'w', encoding='utf-8') as fh:
    fh.write('// Domenia 1 functions still to port, grouped by Domenia 2 page. Generated from dev/web/PARITE.json\n')
    fh.write('// (WPF control inventory) by tools/gen_parite.py: s = section (empty: main screen), f = [title, detail];\n')
    fh.write('// m = 1: states and instructions of the screen (status sentences), shown apart and not counted as functions.\n')
    fh.write('// Regenerate rather than edit by hand.\n')
    fh.write(f'export const PARITE = {body};\n')
print('features', total, {k: sum(len(s['f']) for s in v if not s.get('m')) for k, v in data.items()},
      'messages', sum(len(s['f']) for v in data.values() for s in v if s.get('m')))
