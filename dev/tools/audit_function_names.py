#!/usr/bin/env python3
"""Offline gate for the closed module loader (D011). No PowerShell, network or personal data.

Every runtime script is dot-sourced into ONE scope (Domenia-Core.ps1 + wad/Domenia-Modules.ps1 + wad/modules),
so a function defined twice silently replaces the first definition. This gate fails when:
  1. a function name is defined in two runtime files (case-insensitive, worker here-strings excluded);
  2. a function listed in Get-DomeniaRuntimeModulePlan is not defined at top level of its declared file;
  3. a top-level function of a dot-sourced module is missing from the closed list (it would be loaded unverified);
  4. a module file in wad/modules (*.ps1) is neither declared in the plan nor explicitly excluded below.
Usage: python tools/audit_function_names.py [--json]
"""
from pathlib import Path
import json, re, sys

ROOT = Path(__file__).resolve().parents[1]
WAD = ROOT / 'wad'
# Files present in wad/modules that are deliberately not part of the dot-sourced plan, with the reason.
NOT_PLANNED = {}
FUNC = re.compile(r'^(\s*)function\s+([A-Za-z][\w-]*)', re.I)


def scan(path):
    """Return [(name, line, indent)] for function definitions outside here-strings."""
    out, here = [], None
    for no, line in enumerate(path.read_text(encoding='utf-8-sig').split('\n'), 1):
        text = line.rstrip('\r')
        if here:
            if text.lstrip().startswith(here + '@'):
                here = None
            continue
        m = FUNC.match(text)
        if m:
            out.append((m.group(2), no, len(m.group(1))))
        stripped = text.rstrip()
        if stripped.endswith("@'"):
            here = "'"
        elif stripped.endswith('@"'):
            here = '"'
    return out


def read_plan():
    text = (WAD / 'Domenia-Modules.ps1').read_text(encoding='utf-8-sig')
    body = text.split('function Get-DomeniaRuntimeModulePlan', 1)[1].split('\nfunction ', 1)[0]
    plan = []
    for block in re.split(r"\[pscustomobject\]@\{", body)[1:]:
        file_match = re.search(r"File='([^']+)'", block)
        if not file_match:
            continue
        dot = re.search(r"DotSource=\$(true|false)", block, re.I)
        funcs = re.findall(r"'([A-Za-z][\w-]*)'", block.split('Functions=@(', 1)[1]) if 'Functions=@(' in block else []
        plan.append({'File': file_match.group(1), 'DotSource': (dot is None or dot.group(1).lower() == 'true'), 'Functions': funcs})
    return plan


def main():
    problems = []
    plan = read_plan()
    planned = {m['File'] for m in plan}
    runtime = [WAD / 'Domenia-Core.ps1', WAD / 'Domenia-Modules.ps1'] + [WAD / 'modules' / m['File'] for m in plan if m['File'].endswith('.ps1')]
    owners = {}
    for path in runtime:
        if not path.is_file():
            problems.append(f'Fichier du plan absent : {path.relative_to(ROOT).as_posix()}')
            continue
        for name, line, _indent in scan(path):
            key = name.lower()
            where = f'{path.relative_to(ROOT).as_posix()}:{line}'
            if key in owners and not owners[key].startswith(where.split(':')[0] + ':'):
                problems.append(f'Fonction definie deux fois : {name} ({owners[key]} et {where})')
            owners.setdefault(key, where)
    for module in plan:
        path = WAD / 'modules' / module['File']
        if not path.is_file() or not module['File'].endswith('.ps1'):
            continue
        top = {n.lower(): n for n, _l, indent in scan(path) if indent == 0}
        declared = {f.lower() for f in module['Functions']}
        for name in module['Functions']:
            if name.lower() not in top:
                problems.append(f'Declaree mais absente au premier niveau : {name} dans {module["File"]}')
        if module['DotSource']:
            for key, name in sorted(top.items()):
                if key not in declared:
                    problems.append(f'Fonction chargee hors liste fermee : {name} dans {module["File"]}')
    for path in sorted((WAD / 'modules').glob('*.ps1')):
        if path.name not in planned and path.name not in NOT_PLANNED:
            problems.append(f'Module present mais ni declare ni exclu : {path.name}')
    result = {'Kind': 'FunctionNames', 'Modules': len(plan), 'Functions': len(owners), 'Problems': problems, 'Status': 'FAIL' if problems else 'PASS'}
    if '--json' in sys.argv:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        print(f"Noms de fonctions : {result['Status']} ({len(plan)} modules, {len(owners)} fonctions, {len(problems)} probleme(s))")
        for p in problems:
            print('  ' + p)
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main())
