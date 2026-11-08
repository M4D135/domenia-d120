#!/usr/bin/env python3
"""Describe committed release inputs without copying the Git database or local operator data.
Run by vm.sh before publication; the Windows publisher checks these exact bytes again.
"""
import hashlib
import json
import argparse
import os
import stat
from pathlib import Path, PurePosixPath
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--seed', type=Path)
parser.add_argument('--seed-output', type=Path)
args = parser.parse_args()
if bool(args.seed) != bool(args.seed_output):
    parser.error('--seed et --seed-output sont requis ensemble.')
REPO = Path(subprocess.check_output(['git', 'rev-parse', '--show-toplevel'], cwd=ROOT, text=True).strip())
if ROOT != REPO / 'v2':
    raise SystemExit('Publication : v2 doit appartenir au dépôt Git qualifié.')


def included(name):
    path = PurePosixPath(name)
    if any(part in ('bin', 'obj', '.vs', '.git', '__pycache__') for part in path.parts):
        return False
    if name.startswith(('src/', 'web/', 'tests/', 'tools/')):
        return not name.endswith(('.pyc', '.DS_Store'))
    if len(path.parts) == 3 and path.parts[:2] == ('vendor', 'nuget'):
        return path.name == 'SHA256SUMS' or path.suffix == '.nupkg'
    return name in ('Directory.Build.props', 'global.json', 'NuGet.config', 'README.md') or (name.startswith('docs/') and len(path.parts) == 2 and name.endswith('.md'))


def git(*args):
    return subprocess.check_output(['git', *args], cwd=REPO)


commit = git('rev-parse', 'HEAD').decode().strip()
if len(commit) != 40 or any(c not in '0123456789abcdef' for c in commit):
    raise SystemExit('Identité Git de publication invalide.')
entries = {}
for record in git('ls-tree', '-rz', '--full-tree', commit, '--', 'v2/').split(b'\0'):
    if not record:
        continue
    header, path_bytes = record.split(b'\t', 1)
    mode, kind, blob = header.decode().split()
    full = path_bytes.decode('utf-8', errors='strict')
    name = full.removeprefix('v2/')
    if not included(name):
        continue
    if kind != 'blob' or mode not in ('100644', '100755'):
        raise SystemExit('Source liée ou non régulière : ' + name)
    source = ROOT / name
    if not source.is_file() or source.is_symlink() or any(p.is_symlink() for p in source.parents if p != REPO.parent):
        raise SystemExit('Source absente ou redirigée : ' + name)
    actual = source.read_bytes()
    if actual != git('cat-file', 'blob', blob):
        raise SystemExit('Source non commitée : ' + name)
    entries[name] = {'path': name, 'length': len(actual), 'sha256': hashlib.sha256(actual).hexdigest()}
# Include untracked and ignored source files in the comparison: they must not silently enter a build.
observed = set()
for base in ('src', 'web', 'tests', 'tools', 'vendor'):
    for path in (ROOT / base).rglob('*'):
        name = path.relative_to(ROOT).as_posix()
        if included(name) and (path.is_file() or path.is_symlink()):
            observed.add(name)
missing = observed - entries.keys()
if missing:
    raise SystemExit('Sources hors commit : ' + ', '.join(sorted(missing)[:10]))
if not 10 <= len(entries) <= 4096 or sum(f['length'] for f in entries.values()) > 268435456:
    raise SystemExit('Inventaire source hors bornes.')
if git('rev-parse', 'HEAD').decode().strip() != commit:
    raise SystemExit('HEAD a changé pendant la préparation.')
seed = None
if args.seed:
    path = args.seed.expanduser().absolute()
    if any(p.is_symlink() for p in (path, *path.parents)):
        raise SystemExit('Configuration de distribution redirigée : exportez un fichier régulier.')
    with path.open('rb') as stream:
        before = os.fstat(stream.fileno())
        if not stat.S_ISREG(before.st_mode) or not 1 <= before.st_size <= 1048576:
            raise SystemExit('Configuration de distribution vide ou supérieure à 1 Mio.')
        content = stream.read(1048577)
        after = os.fstat(stream.fileno())
        if len(content) != before.st_size or before.st_mtime_ns != after.st_mtime_ns or before.st_size != after.st_size:
            raise SystemExit('Configuration modifiée pendant sa capture.')
    # The actual allowlist/semantic validation is performed by the compiled Windows application, offline.
    with args.seed_output.open('xb') as output:
        output.write(content)
    seed = {'fileName': 'Domenia.settings.seed.json', 'length': len(content), 'sha256': hashlib.sha256(content).hexdigest()}
json.dump({'format': 1, 'sourceCommit': commit, 'sourceDate': git('show', '-s', '--format=%cs', commit).decode().strip().replace('-', '.'), 'files': [entries[p] for p in sorted(entries)], 'seed': seed}, sys.stdout, ensure_ascii=False, separators=(',', ':'))
print()
