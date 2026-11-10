#!/usr/bin/env python3
"""Verify the current PROD-LIGHT archive and earlier PROD/DEV deliveries.

Standard library only. No extraction, network, build, test or application execution.
This is an integrity report, not the strict two-VM release gate or a UI acceptance.
"""
import argparse
import hashlib
import importlib.util
import json
import os
import stat
import sys
import zipfile
import zlib
from datetime import datetime, timezone
from pathlib import Path


FORMAT = "Domenia.ManualPackageVerification/1"
AUTHORIZED_VERSIONS = {"2.0.0": "25 octobre 2026", "2.0.1": "26 octobre 2026", "2.0.2": "26 octobre 2026", "2.0.3": "26 octobre 2026", "2.0.4": "28 octobre 2026", "2.0.5": "28 octobre 2026", "2.0.6": "28 octobre 2026", "2.0.7": "29 octobre 2026", "2.0.8": "30 octobre 2026", "2.1.0": "8 novembre 2026", "2.1.1": "9 novembre 2026", "2.1.2": "9 novembre 2026", "2.1.3": "10 novembre 2026"}
MAX_REPORT = 16 * 1024**2
SCRIPT = Path(__file__).absolute()
GUARD_SCRIPT = SCRIPT.with_name("release-guard.py")


def load_guard():
    spec = importlib.util.spec_from_file_location("domenia_manual_delivery_guard", GUARD_SCRIPT)
    if spec is None or spec.loader is None:
        raise ValueError("Primitives de contrôle des archives indisponibles.")
    module = importlib.util.module_from_spec(spec)
    previous = sys.dont_write_bytecode
    try:
        # Importing the existing gate must not create a bytecode cache next to it.
        sys.dont_write_bytecode = True
        spec.loader.exec_module(module)
    finally:
        sys.dont_write_bytecode = previous
    return module


guard = load_guard()


def ordinary_directory(path):
    guard.require(path.is_absolute(), "Dossier absolu attendu.")
    for current in (path, *path.parents):
        info = current.lstat()
        guard.require(stat.S_ISDIR(info.st_mode) and not stat.S_ISLNK(info.st_mode)
                      and not (getattr(info, "st_file_attributes", 0) & 0x400),
                      "Dossier lié, redirigé ou non ordinaire.")


def reference(name, identity):
    return {"path": name, "length": identity[0], "sha256": identity[1]}


def read_bounded(path, maximum, identity):
    guard.ordinary(path)
    with path.open("rb") as stream:
        raw = stream.read(maximum + 1)
    guard.require(len(raw) <= maximum and (len(raw), hashlib.sha256(raw).hexdigest()) == identity,
                  "Fichier modifié pendant sa lecture : " + path.name)
    return raw


def inventory_rows(files):
    return [reference(name, files[name]) for name in sorted(files)]


def archive_report(path, identity, checked):
    metadata, files, manifest_hash, _, _ = checked
    prefix = guard.payload_prefix(metadata["version"])
    with zipfile.ZipFile(path) as archive:
        manifest_length = archive.getinfo(prefix + "package-manifest.json").file_size
        guard.require(0 < manifest_length <= 2 * 1024**2, "Manifeste ZIP hors borne.")
        lock = archive.getinfo(prefix + ".lifecycle.lock")
        guard.require(lock.file_size == 0, "Verrou de paquet non vide.")
        with archive.open(lock) as stream:
            guard.require(stream.read(1) == b"", "Verrou de paquet altéré.")
    all_files = dict(files)
    all_files[prefix + "package-manifest.json"] = (manifest_length, manifest_hash)
    all_files[prefix + ".lifecycle.lock"] = (0, hashlib.sha256(b"").hexdigest())
    binaries = {name: value for name, value in files.items()
                if Path(name).suffix.lower() in (".exe", ".dll")}
    return {
        **reference(path.name, identity),
        "metadata": metadata,
        "manifest": reference(prefix + "package-manifest.json", (manifest_length, manifest_hash)),
        "executable": reference("Domenia.exe", files["Domenia.exe"]),
        "entryCount": len(all_files),
        "expandedLength": sum(length for length, _ in all_files.values()),
        "binaries": inventory_rows(binaries),
        "files": inventory_rows(all_files),
    }


def source_provenance(path, checked, prod_files, commit):
    files, sources = checked[1], checked[3]
    prefix = guard.payload_prefix(checked[0]["version"])
    name = prefix + "developer/source-commit.json"
    with zipfile.ZipFile(path) as archive:
        info = archive.getinfo(name)
        guard.require(0 < info.file_size <= 2 * 1024**2, "Inventaire source DEV hors borne.")
        with archive.open(info) as stream:
            raw = stream.read(2 * 1024**2 + 1)
    guard.require((len(raw), hashlib.sha256(raw).hexdigest()) == files[name],
                  "Inventaire source DEV modifié pendant sa lecture.")
    document = guard.parse_json(raw)
    guard.require(guard.source_inventory(document, commit) == sources,
                  "Inventaire source DEV différent de celui contrôlé.")
    seed = document["seed"]
    seed_name = "Domenia.settings.seed.json"
    if seed is None:
        guard.require(prefix + seed_name not in prod_files, "Configuration diffusée absente de la provenance source.")
    else:
        guard.members(seed, ("fileName", "length", "sha256"), "Configuration diffusée")
        guard.require(seed["fileName"] == seed_name and type(seed["length"]) is int
                      and 1 <= seed["length"] <= 1024**2 and guard.hex_value(seed["sha256"], 64)
                      and prod_files.get(prefix + seed_name) == (seed["length"], seed["sha256"]),
                      "Configuration diffusée différente de sa provenance source.")
    return {
        "sourceCommit": commit,
        "manifest": reference(name, files[name]),
        "fileCount": len(sources),
        "length": sum(length for length, _ in sources.values()),
        "files": inventory_rows(sources),
        "seed": seed,
        "binding": "Inventaire source DEV et octets cohérents avec le commit attendu déclaré.",
        "gitObjectVerification": "not-performed",
        "binaryBuildProvenance": "not-established-by-this-tool",
    }


def production_provenance(path, package, prefix, commit, inventory_path):
    identity = guard.digest_file(inventory_path, 2 * 1024**2)
    document = guard.parse_json(read_bounded(inventory_path, 2 * 1024**2, identity))
    sources = guard.check_production_sources(path, package, document, prefix, commit)
    return {"sourceCommit": commit, "fileCount": len(sources), "manifest": reference(inventory_path.name, identity),
            "sourceUrl": "https://github.com/M4D135/domenia-d120/tree/" + commit,
            "gitObjectVerification": "not-performed", "binaryBuildProvenance": "not-established-by-this-tool"}


def verify_packages(directory, commit, version, require_production=False):
    guard.require(version in AUTHORIZED_VERSIONS, "Version hors des livraisons manuelles explicitement autorisées.")
    guard.require(guard.hex_value(commit, 40), "Commit attendu requis (40 caractères hexadécimaux minuscules).")
    ordinary_directory(directory)
    light_name = "Domenia_" + version + "_PROD-LIGHT_Windows-x64.zip"
    production = require_production or (directory / light_name).exists()
    # Only PROD-LIGHT is published since 2026-11-08; PROD/DEV pairs are earlier deliveries.
    kinds = ("PROD-LIGHT",) if production else ("PROD", "DEV")
    names = {kind: "Domenia_" + version + "_" + kind + "_Windows-x64.zip" for kind in kinds}
    if production:
        guard.require({p.name for p in directory.iterdir() if p.suffix.casefold() == ".zip"} == set(names.values()),
                      "La livraison courante exige exactement le ZIP PROD-LIGHT, sans PROD ni DEV.")

    limits = {name: guard.MAX_ARCHIVE for name in names.values()}
    limits["SHA256SUMS.txt"] = 65536
    if production:
        limits["source-commit.json"] = 2 * 1024**2
    initial = {name: guard.digest_file(directory / name, limit) for name, limit in limits.items()}
    tools = {"verifier": (SCRIPT, guard.digest_file(SCRIPT, 1024**2)),
             "archiveGuard": (GUARD_SCRIPT, guard.digest_file(GUARD_SCRIPT, 1024**2))}
    checked = {kind: guard.check_archive(directory / name, kind, version, commit)
               for kind, name in names.items()}
    prod = checked[kinds[0]]
    prefix = guard.payload_prefix(version)
    guard.require(not any(name.casefold().startswith(prefix + "developer/") for name in prod[1]),
                  "Sources de développement présentes dans le pack de production.")
    if production:
        sources = production_provenance(directory / names["PROD-LIGHT"], prod, prefix, commit, directory / "source-commit.json")
    else:
        dev = checked["DEV"]
        sources = source_provenance(directory / names["DEV"], dev, prod[1], commit)
        guard.require({key: value for key, value in prod[0].items() if key != "packageType"}
                      == {key: value for key, value in dev[0].items() if key != "packageType"}
                      and all(dev[1].get(name) == value for name, value in prod[1].items()
                              if name not in (prefix + "package-release.json", prefix + "package-contract.json")),
                      "Binaires, ressources ou identité PROD/DEV différents.")
        guard.require(set(dev[1]) == set(prod[1]) | {prefix + "developer/source-commit.json"}
                      | {prefix + "developer/v2/" + name for name in dev[3]},
                      "Fichier DEV non justifié par le PROD ou les sources du commit.")
    if not production and prefix + "package-contract.json" in prod[1]:
        contracts = []
        for kind in kinds:
            contracts.append(guard.bounded_archive_json(directory / names[kind], prefix + "package-contract.json", checked[kind][1], 65536))
        guard.require({k: v for k, v in contracts[0].items() if k != "componentsFingerprint"}
                      == {k: v for k, v in contracts[1].items() if k != "componentsFingerprint"},
                      "Les deux contrats correspondent à des builds différents.")
    lines = read_bounded(directory / "SHA256SUMS.txt", 65536,
                         initial["SHA256SUMS.txt"]).decode("utf-8-sig").splitlines()
    expected = {initial[name][1] + "  " + name for name in names.values()}
    guard.require(len(lines) == len(names) and set(lines) == expected,
                  "SHA256SUMS ne décrit pas exactement les archives livrées.")
    archives = {kind: archive_report(directory / name, initial[name], checked[kind])
                for kind, name in names.items()}
    # Repeat the whole-file checks after all ZIP/inventory reads. This does not lock
    # the files against subsequent changes; delivery must use these exact hashes.
    for name, identity in initial.items():
        guard.require(guard.digest_file(directory / name, limits[name]) == identity,
                      "Archive ou empreintes modifiées pendant la qualification : " + name)
    for path, identity in tools.values():
        guard.require(guard.digest_file(path, 1024**2) == identity,
                      "Outil de qualification modifié pendant le contrôle.")
    return {
        "format": FORMAT,
        "verifiedAt": datetime.now(timezone.utc).isoformat(),
        "eligibleForManualDelivery": True,
        "version": version,
        "sourceCommit": commit,
        "build": prod[0]["build"],
        "dataSchemaVersion": prod[0]["dataSchemaVersion"],
        "dataSchemaRevision": prod[0]["dataSchemaRevision"],
        "directory": str(directory),
        "archives": archives,
        "checksums": reference("SHA256SUMS.txt", initial["SHA256SUMS.txt"]),
        "sourceProvenance": sources,
        "verificationTools": {key: reference(path.name, identity) for key, (path, identity) in tools.items()},
        "integrity": "verified",
        "rehashedAfterValidation": True,
        "uiAcceptance": "not-run",
        "twoVmAcceptance": "not-run",
        "domainAcceptance": "not-run",
        "userManualAcceptance": "pending",
        "ciVerification": "not-performed-by-this-tool",
        "runtimeExecution": "not-run",
        "published": False,
        "publisherTrust": "not-established",
        "scope": ("Intégrité de l’archive PROD-LIGHT nommée uniquement" if production else "Intégrité des deux archives nommées uniquement")
                 + " ; autorisation humaine du " + AUTHORIZED_VERSIONS[version] + ", recette manuelle en attente. Aucun verdict du parcours strict ni résultat de test déduit.",
    }


def fresh_output(path):
    ordinary_directory(path.parent)
    guard.require(not os.path.lexists(path), "Rapport existant conservé : " + path.name)


def write_report(path, report):
    fresh_output(path)
    raw = (json.dumps(report, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    guard.require(len(raw) <= MAX_REPORT, "Rapport d’intégrité supérieur à sa borne.")
    # Exclusive creation preserves every earlier report, including a partial one.
    with path.open("xb") as output:
        output.write(raw)
        output.flush()
        os.fsync(output.fileno())
    expected = (len(raw), hashlib.sha256(raw).hexdigest())
    guard.require(guard.digest_file(path, MAX_REPORT) == expected, "Rapport écrit différent des octets vérifiés.")
    return reference(str(path), expected)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, required=True, help="Dossier des ZIP standard et de SHA256SUMS.txt.")
    parser.add_argument("--production-only", action="store_true", help="Exiger le seul ZIP PROD-LIGHT, avec provenance source, sans PROD ni DEV.")
    parser.add_argument("--commit", required=True, help="Commit source attendu, 40 caractères hexadécimaux minuscules.")
    parser.add_argument("--version", required=True, choices=tuple(AUTHORIZED_VERSIONS))
    parser.add_argument("--out", type=Path, required=True, help="Rapport JSON neuf ; son dossier doit déjà exister.")
    args = parser.parse_args(argv)
    try:
        output = args.out.absolute()
        fresh_output(output)
        report = verify_packages(args.directory.absolute(), args.commit, args.version, args.production_only)
        written = write_report(output, report)
    except (guard.Refused, OSError, ValueError, KeyError, TypeError, AttributeError,
            zipfile.BadZipFile, zlib.error, EOFError, RuntimeError) as error:
        print("Intégrité de livraison manuelle refusée : " + str(error), file=sys.stderr)
        return 1
    print(json.dumps({"format": FORMAT, "eligibleForManualDelivery": True,
                      "sourceCommit": args.commit, "version": args.version, "report": written,
                      "uiAcceptance": "not-run", "twoVmAcceptance": "not-run", "domainAcceptance": "not-run",
                      "userManualAcceptance": "pending", "published": False}, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
