#!/usr/bin/env python3
"""D120 integration helper: applies the lane manifests (engineering/d120/raccordement/lot-*.json) to the shared files
that lanes are not allowed to edit. Offline and deterministic; review the resulting git diff before committing.

  - wad/Domenia-Modules.ps1      : one plan entry per declared module (Functions computed from the file itself, never
                                   copied from the manifest), Phase/Requires from the manifest; type files.
  - wad/Domenia-Start.ps1        : required runtime paths outside the closed module plan (modules are derived, PF-19).
  - Get-DomeniaWorkerOperationHashes (core) + tools/operation-contracts.json : new operations, then hashes and the
                                   registry fingerprint are recomputed by tools/update_worker_contracts.py --apply.
  - wad/modules/Domenia-UX.help.json : help entries (existing names are never overwritten).
  - Invoke-DomeniaSelfTest (core) : required functions list.
Usage: python tools/integrate_lots.py [--apply] [lot-id ...]
"""
from pathlib import Path
import argparse, json, re, subprocess, sys

ROOT = Path(__file__).resolve().parents[1]
WAD = ROOT / 'wad'
LOTS = ROOT / 'engineering' / 'd120' / 'raccordement'
sys.path.insert(0, str(ROOT / 'tools'))
from audit_function_names import scan  # noqa: E402


def read(path):
    return path.read_text(encoding='utf-8-sig')


def write(path, text, bom=True):
    path.write_bytes((b'\xef\xbb\xbf' if bom else b'') + text.encode('utf-8'))


def top_functions(rel):
    return [n for n, _l, indent in scan(WAD / 'modules' / rel) if indent == 0]


def plan_entry(module):
    file = module['File']
    funcs = top_functions(file) if file.endswith('.ps1') else []
    phase = module.get('Phase', 'Modules')
    reqs = ','.join("'%s'" % r for r in module.get('Requires', []))
    dot = '$true' if module.get('DotSource', True) else '$false'
    body = ',\n'.join("            '%s'" % f for f in funcs)
    inner = ('\n' + body + '\n        ') if funcs else ''
    return f"        [pscustomobject]@{{ Phase='{phase}'; Requires=@({reqs}); File='{file}'; DotSource={dot}; Functions=@({inner}) }}"


def apply_modules(lots, problems):
    path = WAD / 'Domenia-Modules.ps1'
    text = read(path)
    head, rest = text.split('function Get-DomeniaRuntimeModulePlan {\n    @(\n', 1)
    body, tail = rest.split('\n    )\n}\n', 1)
    entries = re.split(r'\n(?=        \[pscustomobject\]@\{)', '\n' + body.strip('\n'))
    entries = [e.strip('\n') for e in entries if e.strip()]
    comments = [e for e in entries if not e.lstrip().startswith('[pscustomobject]')]
    blocks = [e for e in entries if e.lstrip().startswith('[pscustomobject]')]
    by_file = {}
    for b in blocks:
        m = re.search(r"File='([^']+)'", b)
        by_file[m.group(1)] = b
    order = [re.search(r"File='([^']+)'", b).group(1) for b in blocks]
    for lot in lots:
        for module in lot.get('Modules', []):
            file = module['File'].split('/')[-1]
            module = dict(module, File=file)
            if not (WAD / 'modules' / file).is_file():
                problems.append(f"{lot['Lot']}: module absent {file}")
                continue
            if file in by_file and 'Phase=' not in by_file[file] and not module.get('Replace', False):
                old = by_file[file]
                if 'Phase' in module or 'Requires' in module:
                    # Legacy entry upgraded with the declared Phase/Requires; its DotSource is preserved.
                    by_file[file] = plan_entry(dict(module, DotSource=('DotSource=$false' not in old)))
                    continue
                # Existing legacy entry without plan metadata: keep it, only refresh its function list.
                funcs = top_functions(file)
                inner = ',\n'.join("            '%s'" % f for f in funcs)
                by_file[file] = re.sub(r"Functions=@\(.*\)\s*\}$", "Functions=@(\n" + inner + "\n        ) }", old, flags=re.S)
                continue
            by_file[file] = plan_entry(module)
            if file not in order:
                order.append(file)
    new_body = '\n'.join(comments + [by_file[f] for f in order])
    text = head + 'function Get-DomeniaRuntimeModulePlan {\n    @(\n' + new_body + '\n    )\n}\n' + tail
    # Type files
    types = [t for lot in lots for t in lot.get('TypeFiles', [])]
    for t in types:
        file = t['File'].split('/')[-1]
        if f"File='{file}'" in text:
            continue
        line = "        [pscustomobject]@{ File='%s'; Types=@(%s) }" % (file, ','.join("'%s'" % x for x in t['Types']))
        text = text.replace("        [pscustomobject]@{ File='Domenia-Identity.Types.cs';", line + "\n        [pscustomobject]@{ File='Domenia-Identity.Types.cs';", 1)
    write(path, text)


def refresh_functions(problems):
    """Recomputes the closed Functions list of every plan entry from its file (top-level functions, file order).
    Phase, Requires, DotSource and the order of the entries are kept. Used for rule changes made without a lane manifest."""
    path = WAD / 'Domenia-Modules.ps1'
    text = read(path)
    head, rest = text.split('function Get-DomeniaRuntimeModulePlan {\n    @(\n', 1)
    body, tail = rest.split('\n    )\n}\n', 1)
    changed = []
    def repl(match):
        block = match.group(0)
        file = re.search(r"File='([^']+)'", block).group(1)
        if not (WAD / 'modules' / file).is_file():
            problems.append('module absent ' + file)
            return block
        funcs = top_functions(file) if file.endswith('.ps1') else []
        inner = ('\n' + ',\n'.join("            '%s'" % f for f in funcs) + '\n        ') if funcs else ''
        updated = re.sub(r"Functions=@\(.*\)\s*\}$", lambda _m: "Functions=@(" + inner + ") }", block, flags=re.S)
        if updated != block:
            changed.append(file)
        return updated
    body = re.sub(r"        \[pscustomobject\]@\{[^\n]*?File='[^']+'[^\n]*?Functions=@\((?:.*?)\) \}", repl, body, flags=re.S)
    write(path, head + 'function Get-DomeniaRuntimeModulePlan {\n    @(\n' + body + '\n    )\n}\n' + tail)
    return changed


def apply_start(lots):
    """PF-19: Domenia-Start.ps1 derives the module and type files from the closed plan of Domenia-Modules.ps1. Only a
    required file outside that plan (StartRequired) is added to its short static list."""
    path = WAD / 'Domenia-Start.ps1'
    text = read(path)
    loader = read(WAD / 'Domenia-Modules.ps1')
    marker = "        'wad/Support/.lifecycle.lock'\n"
    if marker not in text:
        raise ValueError('Liste statique de Domenia-Start.ps1 introuvable.')
    for lot in lots:
        planned = {'wad/modules/' + m['File'].split('/')[-1] for m in lot.get('Modules', []) + lot.get('TypeFiles', [])}
        for rel in lot.get('StartRequired', []):
            name = rel.split('/')[-1]
            if rel in planned or (rel.startswith('wad/modules/') and f"File='{name}'" in loader):
                continue
            if f"'{rel}'" not in text:
                text = text.replace(marker, f"        '{rel}',\n" + marker, 1)
    write(path, text)


def apply_operations(lots, problems):
    core_path = WAD / 'Domenia-Core.ps1'
    core = read(core_path)
    meta_path = ROOT / 'tools' / 'operation-contracts.json'
    items = json.loads(meta_path.read_text())
    known = {i['Operation'] for i in items}
    getter_start = core.index('function Get-DomeniaWorkerOperationHashes {')
    open_idx = core.index('return [ordered]@{', getter_start) + len('return [ordered]@{')
    added = []
    for lot in lots:
        for op in lot.get('Operations', []):
            name = op['Operation']
            if name in known:
                continue
            if not re.fullmatch(r'[A-Za-z][A-Za-z0-9]*', name):
                problems.append(f"{lot['Lot']}: nom d operation invalide {name}")
                continue
            items.append({'Operation': name, 'File': op['File'] if op['File'].startswith('wad/') else 'wad/modules/' + op['File'].split('/')[-1],
                          'Function': op['Function'], 'LiteralIndex': int(op.get('LiteralIndex', 0)), 'Sha256': '0' * 64})
            known.add(name)
            added.append(name)
    if added:
        insert = ''.join('\n        %-21s = "%s"' % (n, '0' * 64) for n in added)
        core = core[:open_idx] + insert + core[open_idx:]
        write(core_path, core)
        meta_path.write_text(json.dumps(items, indent=2) + '\n')
    return added


def apply_help(lots):
    path = WAD / 'modules' / 'Domenia-UX.help.json'
    catalog = json.loads(read(path))
    names = {e['Name'] for e in catalog}
    for lot in lots:
        for h in lot.get('HelpEntries', []):
            if h['Name'] in names:
                continue
            catalog.append({'Name': h['Name'], 'Title': h['Title'], 'Text': h['Text'], 'Kind': h.get('Kind', 'Control'), 'Source': 'd120-' + lot['Lot']})
            names.add(h['Name'])
    write(path, json.dumps(catalog, ensure_ascii=False, indent=2) + '\n', bom=False)


def apply_selftest(lots):
    core_path = WAD / 'Domenia-Core.ps1'
    core = read(core_path)
    m = re.search(r"(    \$requiredFunctions = @\(\n)(.*?)(\n    \))", core, re.S)
    existing = set(re.findall(r"'([^']+)'", m.group(2)))
    extra = []
    for lot in lots:
        for f in lot.get('SelfTestRequiredFunctions', []):
            if f not in existing and f not in extra:
                extra.append(f)
    if extra:
        lines = m.group(2) + ',\n        ' + ','.join("'%s'" % f for f in extra)
        core = core[:m.start(2)] + lines + core[m.end(2):]
        write(core_path, core)
    return extra


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--apply', action='store_true')
    ap.add_argument('--refresh-functions', action='store_true', help='Recompute the closed function list of every module from its file.')
    ap.add_argument('lots', nargs='*')
    a = ap.parse_args()
    if a.refresh_functions:
        problems = []
        changed = refresh_functions(problems)
        print(json.dumps({'Refreshed': changed, 'Problems': problems}, ensure_ascii=False, indent=2))
        return 1 if problems else 0
    files = sorted(LOTS.glob('lot-*.json'))
    pairs = [(f, json.loads(f.read_text(encoding='utf-8-sig'))) for f in files]
    if a.lots:
        # A lot is selected by its name or by its file name (lot-<id>.json), never because another file matched.
        pairs = [(f, l) for f, l in pairs if l.get('Lot') in a.lots or f.stem in ['lot-' + x for x in a.lots]]
    lots = [l for _f, l in pairs]
    problems = []
    summary = {'Lots': [l.get('Lot') for l in lots]}
    if not a.apply:
        summary['Modules'] = [m['File'] for l in lots for m in l.get('Modules', [])]
        summary['Operations'] = [o['Operation'] for l in lots for o in l.get('Operations', [])]
        print(json.dumps(summary, ensure_ascii=False, indent=2))
        return 0
    apply_modules(lots, problems)
    apply_start(lots)
    summary['OperationsAdded'] = apply_operations(lots, problems)
    apply_help(lots)
    summary['SelfTestAdded'] = apply_selftest(lots)
    run = subprocess.run([sys.executable, str(ROOT / 'tools' / 'update_worker_contracts.py'), '--apply'], capture_output=True, text=True)
    summary['WorkerContracts'] = run.stdout.strip() + run.stderr.strip()
    summary['Problems'] = problems
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 1 if problems or run.returncode else 0


if __name__ == '__main__':
    sys.exit(main())
