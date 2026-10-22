#!/usr/bin/env python3
"""Applies v2/docs/status/*.json to v2/docs/features.json (status lines only, format kept byte for byte) and to
v2/docs/FEATURES.md (status of each function, remaining work of the partial ones, legend, summary table, page counts).

Rules: the status file of the page that owns a function wins (features.json "page"; "machine" is in schema.json);
a transverse function takes the status of the file that claims it. PST-001 stays "abandonne". KEEP lists the functions
whose former status is kept after a check made at the integration (their declared remainder is in the merged shell)."""
import collections
import glob
import json
import re
import sys

ROOT = sys.argv[1]
FEAT_JSON = f'{ROOT}/v2/docs/features.json'
FEAT_MD = f'{ROOT}/v2/docs/FEATURES.md'
OWNER_FILE = {'machine': 'schema'}
KEEP = {
    'PAR-006': 'Réévaluée à l’intégration (22/10/2026) : le reste déclaré par Paramètres (repli temporaire du menu sur un écran étroit, dépliage pour la session sans changer la préférence) est fait par la coque fusionnée (`web/js/app.js`, `foldNavigation`, `autoReleased`).',
    'PAR-008': 'Réévaluée à l’intégration (22/10/2026) : le reste déclaré par Paramètres (Ctrl T, listé dans les raccourcis) est fait par la coque fusionnée (`web/js/app.js`, `toggleTheme`, liste des raccourcis).',
}

features = json.load(open(FEAT_JSON, encoding='utf-8'))
page_of = {f['id']: f['page'] for f in features}
before = {f['id']: f['status'] for f in features}

claims = collections.defaultdict(dict)   # id -> {file: (status, reste)}
for path in sorted(glob.glob(f'{ROOT}/v2/docs/status/*.json')):
    name = path.rsplit('/', 1)[1][:-5]
    data = json.load(open(path, encoding='utf-8'))
    for status in ('fait', 'ameliore'):
        for fid in data.get(status, []):
            claims[fid][name] = (status, None)
    for item in data.get('partiel', []):
        claims[item['id']][name] = ('partiel', item['reste'])

after = dict(before)
reste = {}
conflicts = []
for fid, by_file in claims.items():
    if fid not in page_of:
        sys.exit(f'unknown id {fid}')
    owner = OWNER_FILE.get(page_of[fid], page_of[fid])
    if owner in by_file:
        status, rest = by_file[owner]
    else:
        values = set(by_file.values())
        if len({v[0] for v in values}) > 1:
            sys.exit(f'transverse conflict {fid}: {by_file}')
        status, rest = next(iter(by_file.values()))
    if len({v[0] for v in by_file.values()}) > 1:
        conflicts.append((fid, owner, {k: v[0] for k, v in by_file.items()}))
    if fid == 'PST-001':
        continue
    if fid in KEEP:
        continue
    after[fid] = status
    if status == 'partiel':
        reste[fid] = rest

# ---------------------------------------------------------------- features.json: status lines only
lines = open(FEAT_JSON, encoding='utf-8').read().split('\n')
current = None
changed = 0
for i, line in enumerate(lines):
    m = re.match(r'^  "id": "([^"]+)",$', line)
    if m:
        current = m.group(1)
        continue
    m = re.match(r'^(  "status": ")([^"]+)(".*)$', line)
    if m:
        if m.group(2) != after[current]:
            lines[i] = m.group(1) + after[current] + m.group(3)
            changed += 1
        current = None
open(FEAT_JSON, 'w', encoding='utf-8').write('\n'.join(lines))
check = {f['id']: f['status'] for f in json.load(open(FEAT_JSON, encoding='utf-8'))}
assert check == after, 'features.json does not hold the expected statuses'

# ---------------------------------------------------------------- FEATURES.md
md = open(FEAT_MD, encoding='utf-8').read()
md_lines = md.split('\n')
out = []
i = 0
seen = set()
while i < len(md_lines):
    line = md_lines[i]
    m = re.match(r'^#### ([A-Z]{3}-\d{3}) · ', line)
    if not m:
        out.append(line)
        i += 1
        continue
    fid = m.group(1)
    seen.add(fid)
    out.append(line)
    i += 1
    # Up to the status line: keep the blank lines and the notes, except an older note of this script.
    block = []
    while i < len(md_lines) and not re.match(r'^`(a-faire|fait|ameliore|partiel|abandonne)` · ', md_lines[i]):
        if md_lines[i].startswith('#### '):
            sys.exit(f'no status line for {fid}')
        block.append(md_lines[i])
        i += 1
    status_line = md_lines[i]
    i += 1
    block = [b for b in block if not (b.startswith('> Reste à faire : ') or b.startswith('> Réévaluée à l’intégration'))]
    while len(block) > 1 and block[-1] == '' and block[-2] == '':
        block.pop()
    if not block:
        block = ['']
    note = None
    if after[fid] == 'partiel':
        note = '> Reste à faire : ' + ' '.join(reste[fid].split())
    elif fid in KEEP:
        note = '> ' + KEEP[fid]
    if note:
        block += [note, '']
    out.extend(block)
    out.append(re.sub(r'^`[a-z-]+`', f'`{after[fid]}`', status_line))
assert seen == set(after), f'FEATURES.md and features.json differ: {sorted(set(after) ^ seen)[:10]}'
md = '\n'.join(out)

# Counts per page.
LABELS = [('fait', 'faite', 'faites'), ('ameliore', 'améliorée', 'améliorées'), ('partiel', 'partielle', 'partielles'),
          ('a-faire', 'à faire', 'à faire'), ('abandonne', 'abandonnée', 'abandonnées')]
by_page = collections.defaultdict(collections.Counter)
for fid, status in after.items():
    by_page[page_of[fid]][status] += 1


def sentence(page):
    c = by_page[page]
    total = sum(c.values())
    parts = [f'{c[k]} {one if c[k] == 1 else many}' for k, one, many in LABELS if c[k]]
    if parts == [f'{total} à faire']:
        return f'{total} fonctions, toutes à faire.'
    return f'{total} fonctions : ' + ', '.join(parts) + '.'


PREFIX_PAGE = {}
for fid, page in page_of.items():
    PREFIX_PAGE.setdefault(fid[:3], page)


def page_line(section_prefix):
    return sentence(PREFIX_PAGE[section_prefix])


# Replace the count line that follows each « ## Title (PFX) » heading.
def fix_counts(text):
    result = []
    prefix = None
    for line in text.split('\n'):
        h = re.match(r'^## .*\(([A-Z]{3})\)$', line)
        if h:
            prefix = h.group(1)
        elif prefix and re.match(r'^\d+ fonctions(, dont \d+ faites?| :|, toutes)', line):
            line = page_line(prefix)
            prefix = None
        result.append(line)
    return '\n'.join(result)


md = fix_counts(md)

# Summary table.
rows = []
table = re.search(r'\| Page \| Préfixe \| Fonctions \|[^\n]*\n\|[-:| ]+\n((?:\|[^\n]*\n)+)', md)
total = collections.Counter()
for row in table.group(1).strip('\n').split('\n'):
    cells = [c.strip() for c in row.strip('|').split('|')]
    if cells[0].startswith('**Total'):
        continue
    page = PREFIX_PAGE[cells[1]]
    c = by_page[page]
    total.update(c)
    rows.append(f'| {cells[0]} | {cells[1]} | {sum(c.values())} | {c["fait"]} | {c["ameliore"]} | {c["partiel"]} | {c["a-faire"]} | {c["abandonne"]} |')
rows.append(f'| **Total** | | **{sum(total.values())}** | **{total["fait"]}** | **{total["ameliore"]}** | **{total["partiel"]}** | **{total["a-faire"]}** | **{total["abandonne"]}** |')
new_table = ('| Page | Préfixe | Fonctions | Faites | Améliorées | Partielles | À faire | Abandonnées |\n'
             '|---|---|---:|---:|---:|---:|---:|---:|\n' + '\n'.join(rows) + '\n')
md = md[:table.start()] + new_table + md[table.end():]

# Legend (idempotent: the lines of `partiel` written by earlier runs are replaced, never repeated).
md = re.sub(r'^\| `partiel` \|[^\n]*\n', '', md, flags=re.M)
old_abandon = re.search(r'^\| `abandonne` \|[^\n]*$', md, re.M)
md = (md[:old_abandon.start()]
      + '| `partiel` | Domenia 2 fait une partie de la fonction ; ce qui reste à faire est écrit sous la fonction (« Reste à faire », repris de `docs/status/<page>.json`). |\n'
      + "| `abandonne` | La fonction n'est pas reprise. Ce statut n'est posé que sur une décision écrite et datée de David : PST-001 (WAPT, décision du 22/10/2026). |"
      + md[old_abandon.end():])

# Method: the statuses of the second wave.
step5 = re.search(r"^5\. \*\*Statut\.\*\*[^\n]*$", md, re.M)
if 'vague 2' not in step5.group(0):
    md = (md[:step5.end()]
          + " À l'intégration de la vague 2 (22/10/2026), les statuts des fonctions des écrans ont été repris des fichiers"
          + " `docs/status/<page>.json` (le fichier de la page propriétaire l'emporte quand deux écrans citent la même fonction) ;"
          + " PST-001 est `abandonne` sur décision de David du 22/10/2026."
          + md[step5.end():])

# Proofs of the second wave.
done = '## Fonctions déjà faites dans Domenia 2\n\n'
proof = ("Ce tableau date de l'établissement du catalogue (21/10/2026). Depuis l'intégration de la vague 2 (22/10/2026), les"
         " preuves des fonctions des écrans sont dans leurs contrats `docs/ops/<page>.md` et dans les notes de"
         " `docs/status/<page>.json`.\n\n")
assert done in md
if proof not in md:
    md = md.replace(done, done + proof, 1)

open(FEAT_MD, 'w', encoding='utf-8').write(md)

print(f'features.json: {changed} status line(s) changed')
print('statuses:', dict(collections.Counter(after.values())))
print('conflicts (owner wins):', conflicts)
print('downgrades from fait:', [(k, before[k], after[k]) for k in after if before[k] == 'fait' and after[k] not in ('fait', 'ameliore')])
