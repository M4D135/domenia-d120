#!/usr/bin/env python3
"""Delivery acceptance of a Domenia build (point 150). Offline; nothing is installed, signed or published.

tools/delivery-recipe.json lists measurable criteria, the support means and the rollback means; tools/known-issues.json
lists the unresolved incidents. This tool measures each criterion from real artefacts and writes, in the build output
folder, recette.json and RECETTE.md:
  - offline checks (R01-R06, R11) run here, from this tree;
  - R07 reads build-report.json and SHA256SUMS of the output folder and recomputes the archive hashes;
  - R12 compares the archives with those of a second build of the same commit (--rebuild-output);
  - R08 checks the Windows PowerShell 5.1 campaign report against both archives (release_guard.require_evidence);
  - R09 compares two lab runs (compare_runs.py), R10 reads the scale suites of the delivery run.
A criterion without evidence is NON_MESURE, never PASS. The verdict is « Livrable » only when every blocking criterion
passed and no open incident is Bloquant.

Usage: python3 tools/delivery_recipe.py --output BUILD_DIR [--rebuild-output DIR2] [--windows-report R] [--evidence-dir D]
       [--baseline-run DIR --lab-run DIR] [--skip-offline]
"""
from pathlib import Path
import argparse, hashlib, json, re, subprocess, sys

DEV = Path(__file__).resolve().parents[1]
RECIPE = DEV / 'tools' / 'delivery-recipe.json'
ISSUES = DEV / 'tools' / 'known-issues.json'
SEVERITIES = ('Bloquant', 'Majeur', 'Mineur')
ISSUE_STATUSES = ('Ouvert', 'Résolu')
RESULTS = ('PASS', 'FAIL', 'NON_MESURE')


def read_json(path):
    return json.loads(Path(path).read_text(encoding='utf-8-sig'))


def result(status, detail, evidence=''):
    if status not in RESULTS:
        raise ValueError('Statut de critère inconnu : ' + str(status))
    return {'Status': status, 'Detail': detail, 'Evidence': evidence}


def validate_recipe(recipe):
    problems = []
    if not isinstance(recipe, dict) or recipe.get('Schema') != 'DomeniaDeliveryRecipe/1':
        return ['Schéma de recette inconnu.']
    ids = [c.get('Id') for c in recipe.get('Criteria', []) if isinstance(c, dict)]
    if not ids or len(ids) != len(set(ids)):
        problems.append('Identifiants de critères absents ou en double.')
    for criterion in recipe.get('Criteria', []):
        if not isinstance(criterion, dict) or not criterion.get('Label') or not criterion.get('Threshold') or not isinstance(criterion.get('Blocking'), bool):
            problems.append('Critère incomplet : ' + str(criterion.get('Id') if isinstance(criterion, dict) else criterion))
    for section in ('Support', 'Rollback'):
        if not isinstance(recipe.get(section), list) or not recipe[section]:
            problems.append('Section ' + section + ' vide : support et retour arrière doivent être documentés.')
    return problems


def check_issues(data):
    """R11: every incident is complete; an open Bloquant incident fails the criterion."""
    problems = []
    if not isinstance(data, dict) or data.get('Schema') != 'DomeniaKnownIssues/1':
        return result('FAIL', 'Registre des incidents illisible ou de schéma inconnu.', 'tools/known-issues.json'), []
    issues = data.get('Issues')
    if not isinstance(issues, list):
        return result('FAIL', 'Registre des incidents sans liste.', 'tools/known-issues.json'), []
    seen = set()
    for issue in issues:
        iid = issue.get('Id') if isinstance(issue, dict) else None
        if not isinstance(iid, str) or not re.fullmatch(r'KI-\d{3}', iid) or iid in seen:
            problems.append('Incident sans identifiant KI-nnn ou en double : ' + str(iid))
            continue
        seen.add(iid)
        if issue.get('Severity') not in SEVERITIES or issue.get('Status') not in ISSUE_STATUSES:
            problems.append(iid + ' : gravité ou état inconnu.')
        for field in ('Title', 'Impact', 'Workaround', 'Source'):
            if not str(issue.get(field, '')).strip():
                problems.append(iid + ' : ' + field + ' manquant.')
    opened = [i for i in issues if isinstance(i, dict) and i.get('Status') == 'Ouvert']
    blocking = [i['Id'] for i in opened if i.get('Severity') == 'Bloquant']
    if problems:
        return result('FAIL', ' '.join(problems), 'tools/known-issues.json'), opened
    if blocking:
        return result('FAIL', 'Incident(s) ouvert(s) bloquant(s) : ' + ', '.join(blocking) + '.', 'tools/known-issues.json'), opened
    return result('PASS', str(len(opened)) + ' incident(s) ouvert(s), tous documentés, aucun bloquant.', 'tools/known-issues.json'), opened


def run_offline(criterion, dev=DEV):
    command = criterion.get('Command') or []
    if not command:
        return result('NON_MESURE', 'Aucune commande déclarée.')
    run = subprocess.run([sys.executable, str(Path(dev) / command[0])] + list(command[1:]), capture_output=True, text=True, cwd=str(dev))
    status = 'PASS' if run.returncode == 0 else 'FAIL'
    detail = 'Code de sortie ' + str(run.returncode)
    if status == 'FAIL':
        detail += ' : ' + summarize_output(run.stdout, run.stderr)
    return result(status, detail, ' '.join(command))


def summarize_output(stdout, stderr):
    """Short reason of a failed check: its FAILED lines, its JSON problems or blocking items, else its last lines."""
    failed = [l.strip() for l in stdout.splitlines() if l.startswith('FAILED')]
    if failed:
        return ' | '.join(failed[:5])
    try:
        data = json.loads(stdout)
    except ValueError:
        data = None
    if isinstance(data, dict):
        parts = []
        for key in ('Problems', 'New'):
            if data.get(key):
                parts.append(key + ' : ' + ' ; '.join(str(x) for x in data[key][:5]))
        if data.get('Blocking'):
            parts.append('Bloquants : ' + ', '.join(str(b.get('Id', b)) if isinstance(b, dict) else str(b) for b in data['Blocking']))
        if parts:
            return ' | '.join(parts)
    lines = (stdout + stderr).strip().splitlines()
    return ' | '.join(lines[-3:])


def check_build(out):
    """R07 from the build output folder: archives, manifests, identical runtime, clean commit, SHA256SUMS."""
    out = Path(out)
    report_path = out / 'build-report.json'
    if not report_path.is_file():
        return result('NON_MESURE', 'build-report.json absent du dossier de livraison.')
    report = read_json(report_path)
    problems = []
    for edition in ('prod', 'dev'):
        info = report.get(edition)
        if not isinstance(info, dict) or info.get('ZipIntegrity') is not True or info.get('ManifestValid') is not True:
            problems.append(edition.upper() + ' : archive ou manifeste non validé.')
            continue
        archive = out / str(info.get('Archive', ''))
        if not archive.is_file():
            problems.append(edition.upper() + ' : archive absente (' + str(info.get('Archive')) + ').')
        elif hashlib.sha256(archive.read_bytes()).hexdigest().upper() != str(info.get('Sha256', '')).upper():
            problems.append(edition.upper() + ' : SHA-256 de lʼarchive différent du rapport.')
    prod = report.get('prod') if isinstance(report.get('prod'), dict) else {}
    if report.get('IdenticalRuntimeFiles') != prod.get('Files'):
        problems.append('Runtime PROD et DEV non vérifié identique fichier par fichier.')
    environment = report.get('Environment') if isinstance(report.get('Environment'), dict) else {}
    if not re.fullmatch(r'[0-9a-f]{40}', str(environment.get('Commit', ''))) or environment.get('Dirty') is not False:
        problems.append('Construit hors dʼun commit propre : reconstruction à lʼidentique non garantie.')
    sums = out / 'SHA256SUMS'
    if not sums.is_file():
        problems.append('SHA256SUMS absent.')
    else:
        for line in sums.read_text(encoding='utf-8').splitlines():
            match = re.fullmatch(r'([0-9a-f]{64})  (\S+)', line)
            if not match:
                problems.append('Ligne de SHA256SUMS illisible.')
                continue
            target = out / match.group(2)
            if not target.is_file() or hashlib.sha256(target.read_bytes()).hexdigest() != match.group(1):
                problems.append('SHA256SUMS ne correspond pas à ' + match.group(2) + '.')
    if problems:
        return result('FAIL', ' '.join(problems), 'build-report.json, SHA256SUMS')
    return result('PASS', 'Archives PROD et DEV valides, runtime identique, commit ' + environment['Commit'][:12] + ', SHA256SUMS conforme.', 'build-report.json, SHA256SUMS')


def check_rebuild(out, rebuild=None):
    """R12: a second build of the same commit gives byte-identical archives (SHA256SUMS of both folders)."""
    if not rebuild:
        return result('NON_MESURE', 'Seconde construction non fournie (--rebuild-output).')
    def archives(folder):
        sums = Path(folder) / 'SHA256SUMS'
        if not sums.is_file():
            return None
        rows = {}
        for line in sums.read_text(encoding='utf-8').splitlines():
            match = re.fullmatch(r'([0-9a-f]{64})  (\S+\.zip)', line)
            if match:
                rows[match.group(2)] = match.group(1)
        return rows
    first, second = archives(out), archives(rebuild)
    if not first or not second:
        return result('FAIL', 'SHA256SUMS absent dʼune des deux constructions.', str(rebuild))
    if first != second:
        differ = sorted(k for k in set(first) | set(second) if first.get(k) != second.get(k))
        return result('FAIL', 'Archives différentes entre les deux constructions : ' + ', '.join(differ) + '.', str(rebuild))
    for folder in (out, rebuild):
        for name, digest in first.items():
            target = Path(folder) / name
            if not target.is_file() or hashlib.sha256(target.read_bytes()).hexdigest() != digest:
                return result('FAIL', 'SHA256SUMS ne correspond pas à ' + str(target) + '.', str(rebuild))
    return result('PASS', str(len(first)) + ' archive(s) identiques à lʼoctet dans les deux constructions.', str(rebuild))


def check_windows(out, report_path=None, evidence_dir=None, dev=DEV):
    """R08: the campaign report is bound to both archives of the output folder (release_guard rules)."""
    if not report_path:
        return result('NON_MESURE', 'Aucun rapport de qualification Windows PowerShell 5.1 fourni (--windows-report).')
    sys.path.insert(0, str(Path(dev) / 'engineering' / 'd120'))
    import release_guard
    build = read_json(Path(out) / 'build-report.json')
    report = read_json(report_path)
    try:
        for edition in ('prod', 'dev'):
            info = release_guard.inspect_archive(Path(out) / build[edition]['Archive'])
            release_guard.require_evidence(info, report, Path(evidence_dir) if evidence_dir else None)
    except (release_guard.GateError, OSError, KeyError, ValueError) as error:
        return result('FAIL', 'Rapport refusé : ' + str(error), str(report_path))
    proof = 'preuves recalculées' if evidence_dir else 'preuves non recalculées (--evidence-dir absent)'
    return result('PASS', 'Rapport Windows PowerShell 5.1 lié aux deux ZIP, scénarios requis réussis ; ' + proof + '.', str(report_path))


def lab_load(run_dir, dev=DEV):
    sys.path.insert(0, str(Path(dev) / 'engineering' / 'd120' / 'lab'))
    import compare_runs
    return compare_runs.load(str(run_dir))


def check_regressions(baseline_run=None, lab_run=None, dev=DEV):
    """R09: a test that passed in the reference campaign and fails or disappears now is a regression."""
    if not baseline_run or not lab_run:
        return result('NON_MESURE', 'Campagnes de référence et de livraison non fournies (--baseline-run, --lab-run).')
    old, new = lab_load(baseline_run, dev), lab_load(lab_run, dev)
    regressions = []
    for suite in sorted(old):
        before = old[suite].get('tests', {}) if isinstance(old[suite], dict) else {}
        if suite not in new or '__error__' in new[suite]:
            if any(v == 'PASS' for v in before.values()):
                regressions.append(suite + ' : suite absente ou illisible')
            continue
        after = new[suite].get('tests', {})
        for name, status in sorted(before.items()):
            if status == 'PASS' and after.get(name) != 'PASS':
                regressions.append(suite + ' :: ' + name)
    if regressions:
        return result('FAIL', str(len(regressions)) + ' régression(s) : ' + ' ; '.join(regressions[:10]), str(lab_run))
    return result('PASS', 'Aucune régression par rapport à ' + str(baseline_run) + '.', str(lab_run))


def check_scale(criterion, lab_run=None, dev=DEV):
    """R10: every scale suite ran in the delivery campaign, exited 0 and has no failed test."""
    if not lab_run:
        return result('NON_MESURE', 'Campagne de livraison non fournie (--lab-run).')
    runs = lab_load(lab_run, dev)
    problems = []
    for suite in criterion.get('Suites', []):
        key = next((k for k in runs if k == suite or k == suite + '.ps1'), None)
        data = runs.get(key) if key else None
        if not data or '__error__' in data:
            problems.append(suite + ' absente ou illisible')
            continue
        failed = [n for n, s in data.get('tests', {}).items() if s == 'FAIL']
        if str(data.get('exit')) != '0' or failed or not data.get('tests'):
            problems.append(suite + ' : code ' + str(data.get('exit')) + ', ' + str(len(failed)) + ' test(s) en échec')
    if problems:
        return result('FAIL', ' ; '.join(problems), str(lab_run))
    return result('PASS', 'Suites dʼéchelle réussies : ' + ', '.join(criterion.get('Suites', [])) + '.', str(lab_run))


def verdict(recipe, results):
    """Livrable only when every blocking criterion passed (NON_MESURE never counts as passed)."""
    reasons = []
    for criterion in recipe['Criteria']:
        outcome = results.get(criterion['Id'], result('NON_MESURE', 'Critère non évalué.'))
        if criterion['Blocking'] and outcome['Status'] != 'PASS':
            reasons.append(criterion['Id'] + ' ' + ('non mesuré' if outcome['Status'] == 'NON_MESURE' else 'en échec') + ' : ' + criterion['Label'])
    return ('Livrable' if not reasons else 'Non livrable'), reasons


def render(recipe, results, decision, reasons, opened, build):
    labels = {'PASS': 'Réussi', 'FAIL': 'En échec', 'NON_MESURE': 'Non mesuré'}
    lines = ['# Recette de livraison Domenia', '', 'Build : ' + (build or 'inconnu'), '', 'Verdict : **' + decision + '**', '']
    if reasons:
        lines += ['Motifs :', ''] + ['- ' + r for r in reasons] + ['']
    lines += ['| Critère | Résultat | Seuil | Mesure |', '|---|---|---|---|']
    for criterion in recipe['Criteria']:
        outcome = results.get(criterion['Id'], result('NON_MESURE', 'Critère non évalué.'))
        cell = lambda s: str(s).replace('|', '/').replace('\n', ' ')
        lines.append('| %s %s | %s | %s | %s |' % (criterion['Id'], cell(criterion['Label']), labels[outcome['Status']], cell(criterion['Threshold']), cell(outcome['Detail'])))
    lines += ['', '## Incidents non résolus', '']
    if opened:
        lines += ['| Incident | Gravité | Impact | Contournement |', '|---|---|---|---|']
        for issue in opened:
            lines.append('| %s %s | %s | %s | %s |' % (issue['Id'], issue['Title'], issue['Severity'], issue['Impact'], issue['Workaround']))
    else:
        lines.append('Aucun incident ouvert.')
    lines += ['', '## Support', ''] + ['- ' + s for s in recipe['Support']]
    lines += ['', '## Retour arrière', ''] + ['- ' + s for s in recipe['Rollback']] + ['']
    return '\n'.join(lines)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--output', type=Path, required=True, help='Dossier de livraison produit par build_packages.py.')
    ap.add_argument('--rebuild-output', type=Path, help='Seconde construction du meme commit, pour R12.')
    ap.add_argument('--windows-report', type=Path)
    ap.add_argument('--evidence-dir', type=Path)
    ap.add_argument('--baseline-run', type=Path)
    ap.add_argument('--lab-run', type=Path)
    ap.add_argument('--skip-offline', action='store_true', help='Ne pas relancer les contrôles hors ligne (ils restent non mesurés).')
    args = ap.parse_args()
    out = args.output.resolve()
    if not out.is_dir():
        ap.error('Dossier de livraison absent : ' + str(out))
    if out == DEV or DEV in out.parents:
        ap.error('Le dossier de livraison doit être hors de lʼarbre source.')
    recipe = read_json(RECIPE)
    problems = validate_recipe(recipe)
    if problems:
        print(json.dumps({'Status': 'FAIL', 'Problems': problems}, ensure_ascii=False, indent=2))
        return 1
    results = {}
    issues_result, opened = check_issues(read_json(ISSUES))
    for criterion in recipe['Criteria']:
        cid = criterion['Id']
        if cid == 'R07':
            results[cid] = check_build(out)
        elif cid == 'R08':
            if args.windows_report and not (out / 'build-report.json').is_file():
                results[cid] = result('NON_MESURE', 'build-report.json absent : rapport Windows non rattachable aux archives.')
            else:
                results[cid] = check_windows(out, args.windows_report, args.evidence_dir)
        elif cid == 'R12':
            results[cid] = check_rebuild(out, args.rebuild_output)
        elif cid == 'R09':
            results[cid] = check_regressions(args.baseline_run, args.lab_run)
        elif cid == 'R10':
            results[cid] = check_scale(criterion, args.lab_run)
        elif cid == 'R11':
            results[cid] = issues_result
        elif criterion.get('Command'):
            results[cid] = result('NON_MESURE', 'Contrôle hors ligne non relancé (--skip-offline).') if args.skip_offline else run_offline(criterion)
        else:
            results[cid] = result('NON_MESURE', 'Aucune mesure définie.')
    decision, reasons = verdict(recipe, results)
    build = ''
    if (out / 'build-report.json').is_file():
        build = str(read_json(out / 'build-report.json').get('Build', ''))
    data = {'Schema': 'DomeniaDeliveryAcceptance/1', 'Build': build, 'Verdict': decision, 'Reasons': reasons,
            'Criteria': [dict(c, Result=results[c['Id']]) for c in recipe['Criteria']], 'OpenIssues': opened,
            'Support': recipe['Support'], 'Rollback': recipe['Rollback']}
    with open(out / 'recette.json', 'w', encoding='utf-8', newline='\n') as handle:
        handle.write(json.dumps(data, ensure_ascii=False, indent=2) + '\n')
    with open(out / 'RECETTE.md', 'w', encoding='utf-8', newline='\n') as handle:
        handle.write(render(recipe, results, decision, reasons, opened, build))
    print(json.dumps({'Verdict': decision, 'Reasons': reasons, 'Report': str(out / 'RECETTE.md')}, ensure_ascii=False, indent=2))
    return 0 if decision == 'Livrable' else 1


if __name__ == '__main__':
    sys.exit(main())
