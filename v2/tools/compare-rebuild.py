#!/usr/bin/env python3
"""Read-only comparison of two extracted packs, including every file and build environment.
A matching comparison proves equal bytes, not Windows/domain acceptance or publisher trust.
"""
import argparse
import hashlib
import importlib.util
import json
import stat
from pathlib import Path

spec = importlib.util.spec_from_file_location('domenia_release_guard', Path(__file__).with_name('release-guard.py'))
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


def read_pack(root):
    root = root.absolute()
    guard.require(root.is_dir(), 'Dossier absent.')
    for path in (root, *root.parents):
        info = path.lstat()
        guard.require(stat.S_ISDIR(info.st_mode) and not stat.S_ISLNK(info.st_mode)
                      and not getattr(info, 'st_file_attributes', 0) & 0x400, 'Dossier redirigé.')
    manifest = root / 'wad/package-manifest.json'
    if not manifest.is_file():
        manifest = root / 'package-manifest.json'
    before = guard.digest_file(manifest, 2 * 1024**2)
    document = guard.parse_json(manifest.read_bytes())
    guard.require(guard.digest_file(manifest, 2 * 1024**2) == before, 'Manifeste changé pendant lecture.')
    light = document.get('format') == 2
    guard.members(document, ('format', 'packageType', 'files') if light else ('format', 'files'), 'Manifeste')
    guard.require(type(document['format']) is int and document['format'] in (1, 2)
                  and (not light or manifest.parent.name == 'wad' and document['packageType'] == 'PROD-LIGHT'), 'Format inconnu.')
    expected = guard.inventory(document['files'], 4096)
    actual, inconsistencies, total = {}, [], 0
    for path in root.rglob('*'):
        info = path.lstat()
        guard.require(not stat.S_ISLNK(info.st_mode) and not getattr(info, 'st_file_attributes', 0) & 0x400,
                      'Composant redirigé : ' + str(path.relative_to(root)))
        if not path.is_file():
            continue
        name = guard.relative_name(path.relative_to(root).as_posix())
        guard.require(len(actual) < 4098, 'Trop de fichiers à comparer.')
        identity = guard.digest_file(path, guard.MAX_EXPANDED)
        total += identity[0]
        guard.require(total <= guard.MAX_EXPANDED, 'Paquet trop volumineux.')
        actual[name] = identity
    permitted = {manifest.relative_to(root).as_posix(), ('wad/' if manifest.parent.name == 'wad' else '') + '.lifecycle.lock'}
    for name in sorted(set(expected) | (set(actual) - permitted)):
        if expected.get(name) != actual.get(name):
            inconsistencies.append({'path': name, 'expected': expected.get(name), 'actual': actual.get(name)})
    return actual, inconsistencies


def compare(delivered, rebuilt):
    first, bad_first = read_pack(delivered)
    second, bad_second = read_pack(rebuilt)
    rows = []
    for name in sorted(set(first) | set(second)):
        left, right = first.get(name), second.get(name)
        status = 'identical' if left == right else 'added' if left is None else 'missing' if right is None else 'different'
        rows.append({'path': name, 'status': status, 'delivered': left, 'rebuilt': right})
    return {'format': 'Domenia.RebuildComparison/1', 'equal': not bad_first and not bad_second and all(r['status'] == 'identical' for r in rows),
            'files': rows, 'deliveredManifestErrors': bad_first, 'rebuiltManifestErrors': bad_second,
            'windowsAcceptance': 'not-run', 'publisherTrust': 'not-assessed'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('delivered', type=Path)
    parser.add_argument('rebuilt', type=Path)
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    try:
        result = compare(args.delivered, args.rebuilt)
    except (OSError, ValueError, guard.Refused) as error:
        result = {'format': 'Domenia.RebuildComparison/1', 'equal': False, 'error': str(error)}
    content = json.dumps(result, ensure_ascii=False, indent=2) + '\n'
    if args.report:
        with args.report.open('x', encoding='utf-8') as output:
            output.write(content)
    else:
        print(content, end='')
    return 0 if result['equal'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
