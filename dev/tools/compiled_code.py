#!/usr/bin/env python3
"""Compiled code admitted only for measured hot spots (point 132). Offline, read-only.

tools/compiled-code.json lists every C# unit of the repository with its kind:
  - PointChaud: CPU, parsing or serialisation work measured by a Windows suite. Comparison 'PowerShell': the suite
    times the compiled path and the PowerShell path of the same work (Test-DomeniaHotspots); Hotspot names the
    measure, or lists one measure per operation when the unit holds several. The unit is justified only when every
    measure gives the same results on both paths, the compiled path is at least MinimumGain times faster and the
    report has no failed case. Comparison 'Budget': no PowerShell equivalent is maintained; the suite records the
    cost at the target volume;
  - Interop: a Windows interface with no PowerShell 5.1 command (DllImport, Reflection.Emit);
  - Types: immutable types shared between modules.
--check fails when a C# file, a module DLL or an inline interop definition (DllImport, DefinePInvokeMethod,
Add-Type -MemberDefinition) is not registered, or when a registered unit is incomplete or points to nothing.
--measurements REPORT applies the decision to the report of Test-DomeniaHotspots; without it the decision of each hot
spot stays « Mesure à produire », never « Justifié ».

Usage: python3 tools/compiled_code.py [--check] [--measurements REPORT.json ...]
"""
from pathlib import Path
import argparse, json, re, sys

DEV = Path(__file__).resolve().parents[1]
REGISTER = DEV / 'tools' / 'compiled-code.json'
KINDS = ('PointChaud', 'Interop', 'Types')
COMPARISONS = ('PowerShell', 'Budget')
INLINE = re.compile(r'DllImport\s*\(|DefinePInvokeMethod|Add-Type\s+[^\n]*-MemberDefinition')
SKIPPED_PARTS = {'tests', 'engineering', '__pycache__', 'history'}


def read(path):
    return Path(path).read_text(encoding='utf-8-sig')


def scan_sites(dev=DEV):
    """C# files, module DLLs and functions of PowerShell files holding an inline interop definition."""
    dev = Path(dev)
    sys.path.insert(0, str(dev / 'wad' / 'tests'))
    from powershell_lex import functions
    sources, binaries, inline = set(), set(), set()
    for path in sorted(dev.rglob('*.cs')):
        relative = path.relative_to(dev).as_posix()
        if not (SKIPPED_PARTS & set(relative.split('/')[:-1])):
            sources.add(relative)
    for path in sorted((dev / 'wad' / 'modules').glob('*.dll')):
        binaries.add(path.relative_to(dev).as_posix())
    for path in sorted(list((dev / 'wad').glob('*.ps1')) + list((dev / 'wad' / 'modules').glob('*.ps1'))):
        text = read(path)
        if not INLINE.search(text):
            continue
        spans = functions(text)
        relative = path.relative_to(dev).as_posix()
        for match in INLINE.finditer(text):
            owner = next((name for name, places in spans.items() for start, end in places if start <= match.start() < end), '')
            inline.add(relative + ':' + owner if owner else relative)
    return sources, binaries, inline


def hotspot_ids(measure):
    """Measures a hot spot needs: one id, or a list when one compiled unit holds several measured operations."""
    value = measure.get('Hotspot') if isinstance(measure, dict) else None
    if isinstance(value, str):
        value = [value]
    if not isinstance(value, list) or not value or not all(isinstance(i, str) and i.strip() for i in value):
        return []
    return value


def report_failures(report):
    """Failed cases of a measurement report (its Failed count or the cases marked not passed); None when the report
    does not count them, so that an unchecked report never justifies anything."""
    failed = report.get('Failed')
    if isinstance(failed, bool) or not isinstance(failed, int):
        return None
    listed = sum(1 for case in report.get('Tests') or [] if isinstance(case, dict) and case.get('Passed') is False)
    return max(failed, listed)


def judge(row, failures, gain):
    """(decision, detail) of one PowerShell comparison row."""
    if failures is None:
        return 'Non justifié', 'Rapport de mesure sans compte des cas en échec : résultats non établis.'
    if failures:
        return 'Non justifié', 'Rapport de mesure avec %d cas en échec : résultats non établis.' % failures
    try:
        ps, compiled = float(row['PowerShellMs']), float(row['CompiledMs'])
    except (KeyError, TypeError, ValueError):
        ps = compiled = None
    if ps is None or compiled is None or compiled <= 0 or row.get('Parity') is not True:
        return 'Non justifié', 'Mesure incomplète ou résultats différents entre PowerShell et C#.'
    if compiled * gain <= ps:
        return 'Justifié', 'C# %.0f ms contre PowerShell %.0f ms pour %s unités (gain %.1f).' % (compiled, ps, row.get('Units', '?'), ps / compiled)
    return 'Non justifié', 'Gain %.1f inférieur à %.1f : garder PowerShell.' % (ps / compiled, gain)


def validate(register, dev=DEV, sites=None):
    """(problems, units) of the register against the tree."""
    dev = Path(dev)
    problems = []
    if not isinstance(register, dict) or register.get('Schema') != 'DomeniaCompiledCode/1':
        return ['Registre du code compilé de schéma inconnu.'], []
    gain = register.get('MinimumGain')
    if not isinstance(gain, (int, float)) or gain < 1:
        problems.append('MinimumGain doit être un nombre supérieur ou égal à 1.')
    units = register.get('Units')
    if not isinstance(units, list) or not units:
        return problems + ['Registre sans unité.'], []
    seen, declared_sources, declared_binaries = set(), set(), set()
    sys.path.insert(0, str(dev / 'wad' / 'tests'))
    from powershell_lex import functions
    for unit in units:
        uid = unit.get('Id') if isinstance(unit, dict) else None
        if not isinstance(uid, str) or not uid or uid in seen:
            problems.append('Unité sans identifiant ou en double : ' + repr(uid))
            continue
        seen.add(uid)
        kind = unit.get('Kind')
        if kind not in KINDS:
            problems.append(uid + ' : nature inconnue (' + repr(kind) + ').')
        if not str(unit.get('Reason', '')).strip():
            problems.append(uid + ' : raison manquante.')
        for source in unit.get('Sources') or []:
            declared_sources.add(source)
            path, _, function = source.partition(':')
            if not (dev / path).is_file():
                problems.append(uid + ' : source absente ' + source)
            elif function and len(functions(read(dev / path)).get(function, [])) != 1:
                problems.append(uid + ' : fonction absente ou ambiguë ' + source)
        if not unit.get('Sources'):
            problems.append(uid + ' : aucune source.')
        binary = unit.get('Binary')
        if binary:
            declared_binaries.add(binary)
            if not (dev / binary).is_file():
                problems.append(uid + ' : binaire absent ' + binary)
        if kind == 'PointChaud':
            measure = unit.get('Measure') if isinstance(unit.get('Measure'), dict) else {}
            suite = str(measure.get('Suite', ''))
            if not suite or not (dev / 'wad' / 'tests' / (suite + '.ps1')).is_file():
                problems.append(uid + ' : suite de mesure absente (' + suite + ').')
            if measure.get('Comparison') not in COMPARISONS or not measure.get('Metrics') or not hotspot_ids(measure):
                problems.append(uid + ' : mesure incomplète (Comparison, Hotspot, Metrics).')
        if kind == 'Interop' and not str(unit.get('Api', '')).strip():
            problems.append(uid + ' : interface Windows (Api) manquante.')
    sources, binaries, inline = sites if sites is not None else scan_sites(dev)
    for source in sorted(sources | inline):
        if source not in declared_sources:
            problems.append('Code compilé non enregistré : ' + source)
    for binary in sorted(binaries):
        if binary not in declared_binaries:
            problems.append('Bibliothèque de module non enregistrée : ' + binary)
    return problems, units


def decide(register, measurements=None):
    """Decision per hot spot from measurement reports (Test-DomeniaHotspots, scale suites); never « Justifié » without
    a measure. A Budget unit only records the measured cost: no PowerShell equivalent is maintained to compare with."""
    gain = float(register.get('MinimumGain', 2.0))
    reports = measurements if isinstance(measurements, list) else ([measurements] if isinstance(measurements, dict) else [])
    measured = {}
    for report in reports:
        if not isinstance(report, dict):
            continue
        failures = report_failures(report)
        for row in report.get('Hotspots') or []:
            if isinstance(row, dict) and row.get('Id'):
                measured[row['Id']] = (row, failures)
    rows = []
    for unit in register.get('Units', []):
        if unit.get('Kind') != 'PointChaud':
            rows.append({'Id': unit['Id'], 'Kind': unit.get('Kind'), 'Decision': 'Hors mesure (' + str(unit.get('Kind')) + ')'})
            continue
        measure = unit.get('Measure', {})
        decision, detail = 'Mesure à produire', 'Aucune mesure de ' + str(measure.get('Suite')) + ' fournie.'
        if measure.get('Comparison') == 'PowerShell':
            ids = hotspot_ids(measure)
            outcomes = []
            for hid in ids:
                if hid in measured:
                    outcomes.append((hid,) + judge(measured[hid][0], measured[hid][1], gain))
                else:
                    outcomes.append((hid, 'Mesure à produire', 'Aucune mesure ' + hid + ' de ' + str(measure.get('Suite')) + ' fournie.'))
            label = (lambda o: o[0] + ' : ' + o[2]) if len(ids) > 1 else (lambda o: o[2])
            refused = [o for o in outcomes if o[1] == 'Non justifié']
            missing = [o for o in outcomes if o[1] == 'Mesure à produire']
            if refused:
                decision, detail = 'Non justifié', ' ; '.join(label(o) for o in refused)
            elif missing:
                decision, detail = 'Mesure à produire', ' ; '.join(label(o) for o in missing)
            elif outcomes:
                decision, detail = 'Justifié', ' ; '.join(label(o) for o in outcomes)
        else:
            metrics = measure.get('Metrics', [])
            report = next((r for r in reports if isinstance(r, dict) and metrics and all(k in r for k in metrics)), None)
            if report is not None:
                decision, detail = 'Budget mesuré', json.dumps({k: report.get(k) for k in metrics}, ensure_ascii=False)
        rows.append({'Id': unit['Id'], 'Kind': 'PointChaud', 'Decision': decision, 'Detail': detail})
    return rows


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--check', action='store_true', help='Vérifier le registre contre le dépôt (défaut).')
    ap.add_argument('--measurements', type=Path, action='append', default=[], help='Rapport JSON de Test-DomeniaHotspots ou dʼune suite dʼéchelle (répétable).')
    args = ap.parse_args()
    register = json.loads(read(REGISTER))
    problems, _units = validate(register)
    measurements = [json.loads(read(path)) for path in args.measurements]
    decisions = decide(register, measurements)
    unjustified = [d['Id'] for d in decisions if d['Decision'] == 'Non justifié']
    status = 'FAIL' if (problems or unjustified) else 'PASS'
    print(json.dumps({'Status': status, 'Problems': problems, 'Unjustified': unjustified, 'Decisions': decisions}, ensure_ascii=False, indent=2))
    return 0 if status == 'PASS' else 1


if __name__ == '__main__':
    sys.exit(main())
