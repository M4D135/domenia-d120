#!/usr/bin/env python3
"""Check CI browser reports and PNG evidence for the exact executable of the tested pack.

Standard library only; no browser, test, network or application is started.
This simulation smoke report is separate from human review and two-VM acceptance.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import stat
import sys
from datetime import datetime, timezone


spec = importlib.util.spec_from_file_location("domenia_ci_browser_guard", Path(__file__).absolute().with_name("release-guard.py"))
if spec is None or spec.loader is None:
    raise ValueError("Primitives de qualification des preuves absentes.")
guard = importlib.util.module_from_spec(spec)
previous = sys.dont_write_bytecode
try:
    sys.dont_write_bytecode = True
    spec.loader.exec_module(guard)
finally:
    sys.dont_write_bytecode = previous

FORMAT = "Domenia.CiBrowserEvidence/1"
SCOPE = "UI-simulation-smoke"
AUTHORIZED_VERSIONS = frozenset({"2.0.0", "2.0.1", "2.0.2", "2.0.3", "2.0.4", "2.0.5", "2.0.6", "2.0.7", "2.0.8", "2.1.0", "2.1.1", "2.1.2", "2.1.3", "2.1.4", "2.1.5"})
COLLECTION_VERSIONS = frozenset({"2.0.2", "2.0.3", "2.0.4", "2.0.5", "2.0.6", "2.0.7", "2.0.8", "2.1.0", "2.1.1", "2.1.2", "2.1.3", "2.1.4", "2.1.5"})
CORRECTIVE_VERSIONS = frozenset({"2.0.1"}) | COLLECTION_VERSIONS
REQUIRED = frozenset({"accueil/actualiser-ou", "accueil/catalogue-widgets", "fiche/modifier-description",
                      "operations/releve-reprise", "parametres/collecte-fenetre", "synchro/parc-partage"})
SETTINGS_REQUIRED = REQUIRED | frozenset({"shell/apparence-clavier"})
# Exact names emitted by tests/web/recette-ui.test.mjs in the corrective delivery.
CORRECTIVE_CAPTURES = frozenset({
    "accueil-deconnecte", "accueil-connexion-en-cours", "accueil-connecte-sans-ou", "selecteur-ou-connecte",
    "actualisation-en-cours-sha", "actualisation-interrompue", "reprise-confirmation",
    "actualisation-erreur-rendu-conserve", "actualisation-terminee", "accueil-erreur-debut-cycle",
    "accueil-erreur-fin-cycle", "fiche-sans-historique", "accueil-premiere-lecture-necessaire",
    "accueil-deconnecte-hero", "accueil-connexion-en-cours-hero", "accueil-indicateur-premiere-lecture",
})
COLLECTION_CAPTURES = CORRECTIVE_CAPTURES | frozenset({
    "comptes-domaine-lecture-incomplete", "comptes-domaine-mesure-affichee",
})
# From 2.0.8: a presence stage left incomplete by a transient cause (field report on 2.0.7); earlier evidence never had it.
PRESENCE_VERSIONS = frozenset({"2.0.8", "2.1.0", "2.1.1", "2.1.2", "2.1.3", "2.1.4", "2.1.5"})
PRESENCE_CAPTURES = COLLECTION_CAPTURES | frozenset({"actualisation-incomplete"})


def recipe_captures(version):
    """Exact capture names the browser recipe of this version emits."""
    if version in {"2.1.3", "2.1.4", "2.1.5"}:
        return PRESENCE_CAPTURES | frozenset({"mises-a-jour-encadre-lisible"})
    if version in PRESENCE_VERSIONS:
        return PRESENCE_CAPTURES
    return COLLECTION_CAPTURES if version in COLLECTION_VERSIONS else CORRECTIVE_CAPTURES
MAX_REPORT = 16 * 1024**2
MAX_PNG = 32 * 1024**2
MAX_FACTS = 64 * 1024


def absolute_path(path):
    path = path.absolute()
    guard.require(".." not in path.parts, "Traversée de dossier refusée.")
    return path


def reference(evidence, name, maximum):
    name = guard.relative_name(name)
    length, digest = guard.digest_file(evidence.root / name, maximum)
    result = {"path": name, "length": length, "sha256": digest}
    evidence.path(result, maximum)
    return result


def json_report(evidence, name, maximum=MAX_REPORT):
    identity = reference(evidence, name, maximum)
    document = evidence.json(identity, maximum)
    guard.require(isinstance(document, dict), "Rapport JSON objet requis.")
    return document, identity


def image_reference(evidence, name):
    identity = reference(evidence, name, MAX_PNG)
    guard.png(evidence.read(identity, MAX_PNG))
    return identity


def no_errors(document, label):
    guard.require(document.get("error") is None or document.get("error") == "", label + " : erreur présente.")
    for key in ("errors", "consoleErrors"):
        if key in document:
            guard.require(isinstance(document[key], list) and not document[key], label + " : erreurs présentes.")


def corrective_captures(evidence, names=CORRECTIVE_CAPTURES):
    expected = {"visual-" + name + extension for name in names for extension in (".png", ".json")}
    observed = {path.name for path in evidence.root.iterdir() if path.name.startswith("visual-")}
    guard.require(observed == expected, "Captures de recette corrective absentes ou inattendues.")
    captures = []
    for name in sorted(names):
        image = image_reference(evidence, "visual-" + name + ".png")
        document, facts = json_report(evidence, "visual-" + name + ".json", MAX_FACTS)
        guard.members(document, ("name", "facts"), "Faits de capture corrective")
        guard.require(document["name"] == name and isinstance(document["facts"], dict),
                      "Faits de capture absents ou d’un autre écran.")
        captures.append({"name": name, "image": image, "facts": facts})
    return captures


def verify(web_report, ui_report, package, commit, version):
    guard.require(version in AUTHORIZED_VERSIONS, "Version de livraison non autorisée.")
    guard.require(guard.hex_value(commit, 40), "Commit attendu requis (40 caractères hexadécimaux minuscules).")
    web_files, ui_files, pack_files = guard.Evidence(web_report.parent), guard.Evidence(ui_report.parent), guard.Evidence(package)
    prefix = guard.payload_prefix(version)
    guard.require(all((package / (prefix + name)).is_file() for name in ("package-release.json", "package-manifest.json")),
                  "Disposition du pack absente ou différente de la version attendue.")
    metadata, release_ref = json_report(pack_files, prefix + "package-release.json", 16384)
    manifest, manifest_ref = json_report(pack_files, prefix + "package-manifest.json", 2 * 1024**2)
    # PROD-LIGHT (format 2) is the only published pack since 2026-11-08; earlier evidence used PROD (format 1).
    light = isinstance(manifest, dict) and manifest.get("format") == 2
    guard.members(manifest, ("format", "packageType", "files") if light else ("format", "files"), "Manifeste du pack")
    guard.require(type(manifest["format"]) is int and manifest["format"] in (1, 2)
                  and (not light or prefix == "wad/" and manifest["packageType"] == "PROD-LIGHT"), "Format du manifeste du pack inconnu.")
    inventory = guard.inventory(manifest["files"], 4096)
    executable = package / "Domenia.exe"
    exe_ref = reference(pack_files, "Domenia.exe", guard.MAX_ARCHIVE)
    guard.require(metadata.get("project") == "Domenia" and metadata.get("packageType") == ("PROD-LIGHT" if light else "PROD")
                  and metadata.get("version") == version and metadata.get("sourceCommit") == commit
                  and metadata.get("architecture") == "win-x64"
                  and metadata.get("executableSha256") == exe_ref["sha256"]
                  and inventory.get("Domenia.exe") == (exe_ref["length"], exe_ref["sha256"]),
                  "Pack, commit ou empreinte d’exécutable différents des métadonnées manifestées.")
    web, web_ref = json_report(web_files, web_report.name)
    guard.check_web(web)
    no_errors(web, "Rapport WebView")
    guard.require(not os.path.lexists(web_report.parent / "failure.txt"), "Le harnais WebView a conservé un échec d’infrastructure.")
    web_page = image_reference(web_files, "page.png")
    visual_captures = corrective_captures(web_files, recipe_captures(version)) if version in CORRECTIVE_VERSIONS else []
    ui, ui_ref = json_report(ui_files, ui_report.name)
    guard.require(ui.get("format") == "domenia.e2e.report" and type(ui.get("version")) is int and ui["version"] == 1
                  and ui.get("mode") == "simulation" and guard.text(ui.get("machine"), 63)
                  and guard.text(ui.get("exe"), 32768), "Rapport UI d’un autre format ou mode, ou sans identité.")
    reported_exe = Path(ui["exe"])
    guard.require(reported_exe.is_absolute() and ".." not in reported_exe.parts
                  and os.path.normcase(os.path.normpath(str(reported_exe))) == os.path.normcase(str(executable)),
                  "Le rapport UI ne désigne pas l’exécutable exact du PROD.")
    guard.ordinary(reported_exe)
    guard.timestamp(ui.get("startedAt"))
    no_errors(ui, "Rapport UI")
    required = SETTINGS_REQUIRED if version in COLLECTION_VERSIONS else REQUIRED
    scenarios, summary = ui.get("scenarios"), ui.get("summary")
    guard.require(isinstance(scenarios, list) and len(scenarios) == len(required) and isinstance(summary, dict)
                  and type(summary.get("passed")) is int and summary["passed"] == len(required)
                  and all(type(summary.get(key)) is int and summary[key] == 0 for key in ("failed", "skipped", "invalid")),
                  "Les scénarios UI requis doivent être tous réussis, sans omission.")
    seen, capture_names, captures, results = set(), set(), [], []
    capture_bytes = web_page["length"] + sum(item["image"]["length"] for item in visual_captures)
    for scenario in scenarios:
        guard.require(isinstance(scenario, dict) and isinstance(scenario.get("id"), str), "Scénario UI invalide.")
        identifier = scenario["id"]
        guard.require(identifier in required and identifier not in seen and scenario.get("verdict") == "passed"
                      and type(scenario.get("exitCode")) is int and scenario["exitCode"] == 0
                      and scenario.get("consoleErrors") == [], "Scénario UI inattendu, répété, incomplet ou en échec.")
        no_errors(scenario, "Scénario " + identifier)
        steps = scenario.get("steps")
        # ScenarioLoader allows 200 actions, plus ScenarioRunner's mandatory start step.
        guard.require(isinstance(steps, list) and 2 <= len(steps) <= 201, "Étapes UI absentes ou hors borne.")
        for index, step in enumerate(steps):
            guard.require(isinstance(step, dict) and type(step.get("index")) is int and step["index"] == index
                          and guard.text(step.get("action")) and (index != 0 or step["action"] == "start")
                          and step.get("verdict") == "passed", "Étape UI manquante, désordonnée ou non verte.")
            no_errors(step, "Étape UI")
            screenshot = guard.relative_name(step.get("screenshot"))
            guard.require(screenshot.startswith("shots/" + identifier + "/") and screenshot.endswith(".png")
                          and Path(screenshot).name.startswith(str(index).zfill(2) + "-")
                          and screenshot.casefold() not in capture_names, "Capture UI absente, réutilisée ou d’une autre étape.")
            identity = image_reference(ui_files, screenshot)
            capture_bytes += identity["length"]
            guard.require(capture_bytes <= 1024**3, "Captures UI supérieures à 1 Gio.")
            capture_names.add(screenshot.casefold())
            captures.append({"scenario": identifier, "step": index, **identity})
        seen.add(identifier)
        results.append({"id": identifier, "status": "passed", "stepCount": len(steps), "exitCode": 0})
    guard.require(seen == required, "Sélection des scénarios UI requis incomplète.")
    for evidence in (web_files, ui_files, pack_files):
        evidence.unchanged()
    return {
        "format": FORMAT, "scope": SCOPE, "status": "passed", "version": version,
        "verifiedAt": datetime.now(timezone.utc).isoformat(), "sourceCommit": commit,
        "webCriticalCount": web["report"]["passed"], "simulationUiCount": len(results), "stepCount": len(captures),
        "package": {"root": str(package), "executable": exe_ref, "release": release_ref, "manifest": manifest_ref},
        "visualCaptureCount": len(visual_captures),
        "web": {"root": str(web_files.root), "report": web_ref, "page": web_page, "visualCaptures": visual_captures},
        "ui": {"root": str(ui_files.root), "report": ui_ref, "mode": "simulation", "machine": ui["machine"],
               "exe": str(executable), "scenarios": results, "captures": captures},
        "rehashedAfterValidation": True, "visualReview": "pending",
        "uiAcceptance": "not-run", "domainAcceptance": "not-run", "twoVmAcceptance": "not-run",
        "userManualAcceptance": "pending", "published": False,
        "limits": "Rapports et structure/CRC des PNG contrôlés ; captures à examiner humainement. La cohérence des archives et la provenance des processus CI restent contrôlées séparément. Aucune recette domaine ou deux VM déduite.",
    }


def fresh_output(path):
    for parent in path.parents:
        info = parent.lstat()
        guard.require(stat.S_ISDIR(info.st_mode) and not stat.S_ISLNK(info.st_mode)
                      and not (getattr(info, "st_file_attributes", 0) & 0x400), "Dossier du rapport redirigé ou non ordinaire.")
    guard.require(not os.path.lexists(path), "Rapport existant conservé.")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--web-report", type=Path, required=True)
    parser.add_argument("--ui-report", type=Path, required=True)
    parser.add_argument("--package", type=Path, required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--version", choices=sorted(AUTHORIZED_VERSIONS), required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        output = absolute_path(args.out)
        fresh_output(output)
        report = verify(absolute_path(args.web_report), absolute_path(args.ui_report), absolute_path(args.package), args.commit, args.version)
        raw = (json.dumps(report, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
        guard.require(len(raw) <= MAX_REPORT, "Rapport de preuves supérieur à sa borne.")
        fresh_output(output)
        with output.open("xb") as stream:
            stream.write(raw)
            stream.flush()
            os.fsync(stream.fileno())
        identity = (len(raw), hashlib.sha256(raw).hexdigest())
        guard.require(guard.digest_file(output, MAX_REPORT) == identity, "Rapport écrit différent de sa relecture.")
    except (guard.Refused, OSError, ValueError, KeyError, TypeError, AttributeError, RuntimeError) as error:
        print("Preuves navigateur CI refusées : " + str(error), file=sys.stderr)
        return 1
    print(json.dumps({"format": FORMAT, "scope": SCOPE, "status": "passed", "version": args.version, "sourceCommit": args.commit,
                      "report": {"path": str(output), "length": identity[0], "sha256": identity[1]},
                      "webCriticalCount": report["webCriticalCount"], "simulationUiCount": report["simulationUiCount"],
                      "stepCount": report["stepCount"], "visualCaptureCount": report["visualCaptureCount"], "visualReview": "pending",
                      "domainAcceptance": "not-run", "twoVmAcceptance": "not-run", "published": False},
                     ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
