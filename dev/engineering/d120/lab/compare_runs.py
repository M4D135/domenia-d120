#!/usr/bin/env python3
"""Summarize Domenia lab-run reports (Invoke-LabRun.ps1 output) and compare runs test by test.

  compare_runs.py RUN                                   summary of one run
  compare_runs.py OLD NEW [--retired FILE ...]          test-by-test comparison, exit 1 on any regression
  compare_runs.py --freeze RUN OUT.json [--label TEXT]  TE-04: freezes a run as a reference keyed by suite and name

RUN, OLD and NEW are a run folder (one <suite>.ps1.json report per suite, optional .exit file) or a reference frozen
by --freeze. A test that passed in OLD and is absent from NEW is a regression, unless 'Suite :: Name' matches a
pattern (fnmatch, case-sensitive) of a retired file, a JSON list of patterns (one file per lot, --retired repeatable):
a test removed or renamed on purpose is declared, never silently dropped. A frozen reference refuses an unreadable
suite report."""
import argparse, datetime, fnmatch, glob, json, os, sys
from pathlib import Path

SCHEMA = 'DomeniaTestReference/1'
PASSED = (True, 'Passed', 'PASS', 'True', 'OK', 'Pass', 'Success')


def load_run(directory):
    out = {}
    for path in sorted(glob.glob(os.path.join(directory, '*.json'))):
        suite = os.path.basename(path).replace('.ps1.json', '')
        try:
            report = json.loads(Path(path).read_text(encoding='utf-8-sig'))
        except Exception as error:
            out[suite] = {'__error__': str(error)}
            continue
        tests = None
        for value in report.values():
            if isinstance(value, list) and value and isinstance(value[0], dict) and ('Name' in value[0]):
                tests = value
                break
        results = {}
        for test in tests or []:
            status = test.get('Status', test.get('Passed', test.get('Result', test.get('Success', ''))))
            results[str(test.get('Name'))] = 'PASS' if status in PASSED else ('SKIP' if str(status) in ('Skipped', 'SKIP') else 'FAIL')
        exit_path = path + '.exit'
        exit_code = Path(exit_path).read_text().strip() if os.path.exists(exit_path) else None
        out[suite] = {'tests': results, 'exit': exit_code}
    return out


def load(source):
    """A run folder or a frozen reference, as {suite: {'tests': {name: status}, 'exit': code}}."""
    if os.path.isfile(source):
        reference = json.loads(Path(source).read_text(encoding='utf-8-sig'))
        if reference.get('Schema') != SCHEMA:
            raise SystemExit('Reference de tests inconnue : ' + source)
        return {suite: {'tests': dict(data.get('Tests', {})), 'exit': data.get('Exit')} for suite, data in reference.get('Suites', {}).items()}
    if not os.path.isdir(source):
        raise SystemExit('Execution introuvable : ' + source)
    return load_run(source)


def totals(run):
    counts = {'PASS': 0, 'FAIL': 0, 'SKIP': 0}
    for data in run.values():
        for status in data.get('tests', {}).values():
            counts[status] = counts.get(status, 0) + 1
    return counts


def freeze(source, output, label=''):
    run = load(source)
    broken = sorted(suite for suite, data in run.items() if '__error__' in data)
    if broken:
        raise SystemExit('Rapports illisibles, reference refusee : ' + ', '.join(broken))
    if not run:
        raise SystemExit('Aucun rapport de suite dans ' + source)
    count = totals(run)
    reference = {
        'Schema': SCHEMA,
        'Label': label,
        'Source': os.path.abspath(source),
        'FrozenUtc': datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
        'Totals': {'Passed': count['PASS'], 'Failed': count['FAIL'], 'Skipped': count['SKIP'], 'Suites': len(run)},
        'Suites': {suite: {'Exit': run[suite]['exit'], 'Tests': dict(sorted(run[suite]['tests'].items()))} for suite in sorted(run)},
    }
    with open(output, 'w', encoding='utf-8', newline='\n') as handle:
        handle.write(json.dumps(reference, ensure_ascii=False, indent=1) + '\n')
    return reference


def is_retired(suite, name, patterns):
    key = suite + ' :: ' + name
    return any(fnmatch.fnmatchcase(key, pattern) for pattern in patterns)


def compare(old, new, patterns=()):
    """Returns (lines, regressions, fixed, new_tests, retired)."""
    lines = []
    regress = fixed = added = retired = 0
    for suite in sorted(set(old) | set(new)):
        before = old.get(suite, {}).get('tests', {})
        after = new.get(suite, {}).get('tests', {})
        if suite in old and suite not in new:
            passing = [name for name, status in before.items() if status == 'PASS']
            undeclared = [name for name in passing if not is_retired(suite, name, patterns)]
            if undeclared or not passing:
                lines.append('SUITE MISSING in new run: ' + suite)
                regress += 1
            else:
                lines.append('RETIRED SUITE ' + suite)
                retired += len(passing)
            continue
        for name in sorted(set(before) | set(after)):
            x = before.get(name)
            y = after.get(name)
            if x == 'PASS' and y is None and is_retired(suite, name, patterns):
                lines.append('RETIRED ' + suite + ' :: ' + name)
                retired += 1
            elif x == 'PASS' and y != 'PASS':
                lines.append('REGRESSION ' + suite + ' :: ' + name + ' (' + str(x) + ' -> ' + str(y) + ')')
                regress += 1
            elif x not in (None, 'PASS') and y == 'PASS':
                fixed += 1
            elif x is None and y is not None:
                added += 1
                if y != 'PASS':
                    lines.append('NEW-FAIL ' + suite + ' :: ' + name)
    lines.append('regressions=%d fixed=%d new_tests=%d retired=%d' % (regress, fixed, added, retired))
    return lines, regress, fixed, added, retired


def summary(run):
    lines = []
    tp = tf = 0
    for suite, data in run.items():
        if '__error__' in data:
            lines.append(suite + ': UNREADABLE ' + data['__error__'])
            continue
        p = sum(1 for status in data['tests'].values() if status == 'PASS')
        f = sum(1 for status in data['tests'].values() if status == 'FAIL')
        tp += p
        tf += f
        lines.append('%s: pass=%d fail=%d exit=%s' % (suite, p, f, data['exit']))
    lines.append('TOTAL pass=%d fail=%d suites=%d' % (tp, tf, len(run)))
    return lines


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('runs', nargs='*')
    parser.add_argument('--freeze', nargs=2, metavar=('RUN', 'OUT'))
    parser.add_argument('--label', default='')
    parser.add_argument('--retired', action='append', default=[])
    args = parser.parse_args(argv)
    if args.freeze:
        reference = freeze(args.freeze[0], args.freeze[1], args.label)
        print('Reference figee : %(Passed)d reussis, %(Failed)d en echec, %(Skipped)d ignores, %(Suites)d suites' % reference['Totals'])
        return 0
    if len(args.runs) == 1:
        print('\n'.join(summary(load(args.runs[0]))))
        return 0
    if len(args.runs) != 2:
        parser.error('une execution, deux executions, ou --freeze RUN OUT')
    patterns = []
    for path in args.retired:
        patterns.extend(str(pattern) for pattern in json.loads(Path(path).read_text(encoding='utf-8-sig')))
    lines, regress, _fixed, _added, _retired = compare(load(args.runs[0]), load(args.runs[1]), patterns)
    print('\n'.join(lines))
    return 1 if regress else 0


if __name__ == '__main__':
    sys.exit(main())
