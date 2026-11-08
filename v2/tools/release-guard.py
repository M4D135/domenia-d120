#!/usr/bin/env python3
"""Read-only final release gate. Preparation of an unvalidated candidate never calls this gate.

No network, build, test execution or dependency installation. Raw VM results and an explicit
review are required; a successful native protocol is not treated as business acceptance.
"""
import argparse
import hashlib
import json
import re
import stat
import sys
import zipfile
import zlib
from datetime import datetime
from pathlib import Path, PurePosixPath


VMS = {
    "CNAMTS-DC01": "7625c944-b4fc-4f8b-ac23-c796cc1be791",
    "DOMENIA-FIRSTRUN-20261020": "bc2f1ac0-9545-49bd-a0f5-cb89d352cf61",
}
NATIVE_AVAILABLE = {
    "directory.scope", "audit.findTarget", "audit.searchObjects", "audit.domainGroup",
    "audit.overview", "audit.localTotals", "audit.controllers", "audit.probes", "audit.services",
    "audit.compare", "audit.passwordPolicy", "audit.nestedGroups", "audit.membership",
    "audit.delegations", "audit.tokenGroups", "audit.gpoLinks", "audit.appliedPolicies",
    "audit.machineIdentity", "audit.relations", "audit.relationHistory", "audit.identityScan",
    "audit.localNames", "operations.runs", "operations.providers", "operations.history",
    "operations.check", "poste.inventory", "poste.software", "poste.sessions", "poste.diagnostic",
}
NATIVE_READS = {"directory.scope", "audit.machineIdentity", "operations.history", "poste.inventory"}
REVIEW_CHECKS = {
    "portable-start", "configuration-defaults", "demonstration-isolation", "update-rollback",
    "read-retry-stop", "settings-effective", "home-resume", "widget-collection",
    "offline-cli-read-only", "ad-scope-receipts",
}
REQUIRED_UI = {
    "simulation": {
        "accueil/actualiser-ou", "accueil/catalogue-widgets", "fiche/modifier-description",
        "operations/releve-reprise", "parametres/collecte-fenetre", "synchro/parc-partage",
    },
    "annuaire": {"parametres/apparence-theme", "parametres/recherche-reglage", "schema/panneau-annuaire"},
}
MAX_ARCHIVE = 2 * 1024**3
MAX_EXPANDED = 8 * 1024**3
RESERVED = re.compile(r"^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)", re.I)


class Refused(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise Refused(message)


def members(value, names, label):
    require(isinstance(value, dict) and set(value) == set(names), label + " : propriétés absentes ou inconnues.")


def text(value, limit=512):
    return isinstance(value, str) and 0 < len(value) <= limit and not any(ord(c) < 32 for c in value)


def hex_value(value, length):
    return isinstance(value, str) and re.fullmatch("[0-9a-f]{" + str(length) + "}", value) is not None


def timestamp(value):
    require(text(value, 64), "Horodatage absent.")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise Refused("Horodatage invalide.") from error
    require(parsed.tzinfo is not None, "Horodatage sans fuseau.")
    return parsed


def relative_name(value):
    require(text(value) and "\\" not in value and not re.search(r'[\x00-\x1f:<>"|?*]', value), "Chemin non portable.")
    parts = value.split("/")
    require(len(parts) <= 32 and all(p and p not in (".", "..") and not p.endswith((".", " "))
            and not RESERVED.match(p) for p in parts), "Chemin redirigé, réservé ou ambigu.")
    return value


def ordinary(path):
    require(path.is_absolute(), "Chemin absolu attendu.")
    for current in (path, *path.parents):
        info = current.lstat()
        require(not stat.S_ISLNK(info.st_mode) and not (getattr(info, "st_file_attributes", 0) & 0x400), "Lien ou jonction refusé.")
    require(path.is_file(), "Fichier ordinaire attendu.")


def digest_file(path, limit):
    ordinary(path)
    digest = hashlib.sha256()
    count = 0
    with path.open("rb") as stream:
        while block := stream.read(1024 * 1024):
            count += len(block)
            require(count <= limit, "Fichier supérieur à sa borne.")
            digest.update(block)
    return count, digest.hexdigest()


def parse_json(raw):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, "Clé JSON dupliquée : " + key)
            result[key] = value
        return result
    def invalid(value):
        raise Refused("Constante JSON invalide : " + value)
    try:
        return json.loads(raw.decode("utf-8-sig"), object_pairs_hook=unique, parse_constant=invalid)
    except (UnicodeError, json.JSONDecodeError, RecursionError) as error:
        raise Refused("Document JSON illisible.") from error


class Evidence:
    def __init__(self, root):
        self.root = root
        self.observed = {}

    def path(self, reference, maximum=64 * 1024**2):
        members(reference, ("path", "length", "sha256"), "Référence de preuve")
        name = relative_name(reference["path"])
        require(type(reference["length"]) is int and 0 <= reference["length"] <= maximum
                and hex_value(reference["sha256"], 64), "Métadonnées de preuve invalides.")
        path = self.root / name
        actual = digest_file(path, maximum)
        require(actual == (reference["length"], reference["sha256"]), "Preuve modifiée : " + name)
        prior = self.observed.setdefault(name, actual)
        require(prior == actual, "Deux identités pour une preuve : " + name)
        return path

    def read(self, reference, maximum=64 * 1024**2):
        path = self.path(reference, maximum)
        data = path.read_bytes()
        require(len(data) == reference["length"] and hashlib.sha256(data).hexdigest() == reference["sha256"], "Preuve changée pendant sa lecture.")
        return data

    def json(self, reference, maximum=4 * 1024**2):
        return parse_json(self.read(reference, maximum))

    def unchanged(self):
        for name, expected in self.observed.items():
            require(digest_file(self.root / name, max(expected[0], 1)) == expected, "Preuve modifiée pendant la qualification : " + name)


def source_inventory(document, commit):
    fields = ("format", "sourceCommit", "files", "seed")
    if isinstance(document, dict) and "sourceDate" in document:
        fields += ("sourceDate",)
        require(isinstance(document["sourceDate"], str) and re.fullmatch(r"20[0-9]{2}\.[0-9]{2}\.[0-9]{2}", document["sourceDate"]), "Date source invalide.")
        try:
            datetime.strptime(document["sourceDate"], "%Y.%m.%d")
        except ValueError as error:
            raise Refused("Date source impossible.") from error
    members(document, fields, "Inventaire source")
    require(type(document["format"]) is int and document["format"] == 1 and document["sourceCommit"] == commit, "Source d’un autre commit.")
    return inventory(document["files"], 4096, 256 * 1024**2)


def inventory(entries, maximum=8192, byte_limit=MAX_EXPANDED):
    require(isinstance(entries, list) and 1 <= len(entries) <= maximum, "Inventaire vide ou trop long.")
    result, folded, total = {}, set(), 0
    for entry in entries:
        members(entry, ("path", "length", "sha256"), "Entrée d’inventaire")
        name = relative_name(entry["path"])
        require(name.casefold() not in folded and type(entry["length"]) is int and entry["length"] >= 0
                and hex_value(entry["sha256"], 64), "Entrée d’inventaire ambiguë.")
        total += entry["length"]
        require(total <= byte_limit, "Inventaire supérieur à sa borne.")
        folded.add(name.casefold())
        result[name] = (entry["length"], entry["sha256"])
    return result


def payload_prefix(version):
    # Keep verification of historical releases unchanged.
    return "wad/" if version in ("2.0.4", "2.0.5", "2.0.6", "2.0.7", "2.0.8", "2.1.0") else ""


def check_archive(path, kind, version, commit):
    with zipfile.ZipFile(path) as archive:
        entries, names, expanded = {}, set(), 0
        require(12 <= len(archive.infolist()) <= 8192, "Nombre d’entrées ZIP invalide.")
        for entry in archive.infolist():
            name = relative_name(entry.filename)
            unix_kind = stat.S_IFMT(entry.external_attr >> 16)
            require(not entry.is_dir() and name.casefold() not in names and unix_kind in (0, stat.S_IFREG)
                    and not entry.external_attr & 0x410 and not entry.flag_bits & 1
                    and entry.compress_type in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED), "Entrée ZIP liée, répétée, chiffrée ou non ordinaire.")
            require(0 <= entry.file_size <= MAX_ARCHIVE and (entry.file_size == 0
                    or 0 < entry.compress_size and entry.file_size <= entry.compress_size * 500), "Ratio ou taille ZIP excessif.")
            expanded += entry.file_size
            require(expanded <= MAX_EXPANDED, "Archive décompressée trop grande.")
            entries[name] = entry
            names.add(name.casefold())
        for name in entries:
            require(not any(str(parent).casefold() in names for parent in PurePosixPath(name).parents if str(parent) != "."), "Un fichier ZIP masque un dossier.")
        prefix = payload_prefix(version)
        if prefix:
            require(all(name == "Domenia.exe" or name.startswith(prefix) for name in entries), "La racine doit contenir seulement Domenia.exe et wad.")
        require({"Domenia.exe", prefix + "package-release.json", prefix + "package-manifest.json", prefix + ".lifecycle.lock"} <= set(entries), "Racine PROD/DEV incomplète.")
        require(entries[prefix + ".lifecycle.lock"].file_size == 0, "Verrou de paquet non vide.")
        def small(name, maximum):
            require(name in entries and 0 < entries[name].file_size <= maximum, "Document ZIP absent ou trop grand : " + name)
            return archive.read(entries[name])
        manifest_raw = small(prefix + "package-manifest.json", 2 * 1024**2)
        manifest = parse_json(manifest_raw)
        light = kind == "PROD-LIGHT"
        members(manifest, ("format", "packageType", "files") if light else ("format", "files"), "Manifeste de paquet")
        require(type(manifest["format"]) is int and manifest["format"] == (2 if light else 1), "Format de paquet incompatible avec son édition.")
        if light:
            require(prefix == "wad/" and manifest["packageType"] == kind, "Discriminant PROD-LIGHT absent.")
        files = inventory(manifest["files"], 4096)
        require(set(files) == set(entries) - {prefix + "package-manifest.json", prefix + ".lifecycle.lock"}, "Couverture du manifeste non exacte.")
        for name, (length, expected) in files.items():
            require(entries[name].file_size == length, "Taille ZIP différente du manifeste.")
            digest, count = hashlib.sha256(), 0
            with archive.open(entries[name]) as stream:
                while block := stream.read(1024 * 1024):
                    count += len(block)
                    require(count <= length, "Entrée ZIP plus longue qu’annoncé.")
                    digest.update(block)
            require(count == length and digest.hexdigest() == expected, "Composant ZIP altéré : " + name)
        metadata = parse_json(small(prefix + "package-release.json", 16384))
        members(metadata, ("version", "build", "dataSchemaVersion", "dataSchemaRevision", "project", "architecture", "packageType", "sourceCommit", "executableSha256", "dependencies"), "Métadonnées de livraison")
        require(metadata["version"] == version and metadata["sourceCommit"] == commit and metadata["project"] == "Domenia"
                and metadata["architecture"] == "win-x64" and metadata["packageType"] == kind
                and metadata["executableSha256"] == files["Domenia.exe"][1]
                and type(metadata["dataSchemaVersion"]) is int and metadata["dataSchemaVersion"] == 11
                and type(metadata["dataSchemaRevision"]) is int and metadata["dataSchemaRevision"] == (2 if version in ("2.0.5", "2.0.6", "2.0.7", "2.0.8", "2.1.0") else 1)
                and text(metadata["build"], 128) and metadata["build"].startswith(version + "+")
                and hex_value(metadata["build"][len(version) + 1:], 64), "Identité de livraison incompatible.")
        members(metadata["dependencies"], (".NET", "WebView2"), "Versions embarquées")
        require(all(text(v, 100) for v in metadata["dependencies"].values()), "Version de runtime absente.")
        required = {"Domenia.Core.dll", "Domenia.Bridge.dll", "Domenia.Ad.dll", "Domenia.Engine.dll",
                    "Domenia.Store.dll", "Domenia.Inventory.dll", "Domenia.Simulation.dll", "web/index.html"}
        require({prefix + name for name in required} <= set(files), "Ressource de production manquante.")
        web_prefix = prefix + "runtime/webview2/"
        if light:
            require(metadata["dependencies"]["WebView2"] == "Evergreen" and prefix + "package-contract.json" in files,
                    "Le pack LIGHT exige Evergreen et son contrat de livraison.")
            net = metadata["dependencies"][".NET"]
            require(re.fullmatch(r"10\.0\.(0|[1-9][0-9]*)", net) is not None, "Version privée .NET invalide.")
            needed = ("dotnet.exe", "host/fxr/" + net + "/hostfxr.dll", "shared/Microsoft.NETCore.App/" + net + "/coreclr.dll",
                      "shared/Microsoft.NETCore.App/" + net + "/System.Private.CoreLib.dll",
                      "shared/Microsoft.WindowsDesktop.App/" + net + "/System.Windows.Forms.dll")
            require(all(prefix + "runtime/dotnet/" + name in files for name in needed), "Runtime privé .NET incomplet dans LIGHT.")
            require(not any(n.casefold() == web_prefix.rstrip("/") or n.casefold().startswith(web_prefix) or PurePosixPath(n.casefold()).name in ("msedgewebview2.exe", "msedge.dll")
                            for n in files), "Moteur WebView2 embarqué dans PROD-LIGHT.")
        else:
            require(metadata["dependencies"]["WebView2"] != "Evergreen" and any(n.startswith(web_prefix) and n.endswith("msedgewebview2.exe") for n in files),
                    "Runtime WebView2 autonome manquant.")
        if prefix + "package-contract.json" in files:
            contract = parse_json(small(prefix + "package-contract.json", 65536))
            check_release_contract(contract, metadata, files, prefix)
            registry = parse_json(small(prefix + "contracts/operation-contracts.json", 2 * 1024**2))
            check_operation_registry(registry, contract["registryFingerprint"])
            environment = parse_json(small(prefix + "contracts/build-environment.json", 65536))
            require(environment.get("format") == "Domenia.BuildEnvironment/1" and environment.get("sourceCommit") == commit
                    and text(environment.get("sdk"), 100) and text(environment.get("powershell"), 100)
                    and isinstance(environment.get("steps"), list) and environment["steps"], "Environnement de reconstruction incomplet.")
        sources, critical = None, None
        if kind == "DEV":
            source_document = parse_json(small(prefix + "developer/source-commit.json", 2 * 1024**2))
            sources = source_inventory(source_document, commit)
            require({n.removeprefix(prefix + "developer/v2/") for n in files if n.startswith(prefix + "developer/v2/")} == set(sources), "Sources DEV incomplètes ou supplémentaires.")
            require(all(files.get(prefix + "developer/v2/" + n) == identity for n, identity in sources.items()), "Source DEV différente de son commit.")
            if prefix + "package-contract.json" in files:
                require(source_document.get("sourceDate") == contract["sourceDate"], "Date source différente du contrat.")
                require(files.get(prefix + "contracts/operation-contracts.json") == files.get(prefix + "developer/v2/tools/operation-contracts.json"),
                        "Registre livré différent du registre source.")
                require(all(row["path"] in sources and sources[row["path"]][1] == row["sha256"] for row in registry["files"]),
                        "Corps épinglé différent des sources DEV.")
            critical = small(prefix + "developer/v2/tests/Domenia.Tests/CriticalTestSelection.cs", 65536).decode("utf-8-sig")
        return metadata, files, hashlib.sha256(manifest_raw).hexdigest(), sources, critical


def bounded_archive_json(path, name, files, maximum):
    length, expected = files[name]
    require(0 < length <= maximum, "Preuve ZIP absente ou hors borne : " + name)
    with zipfile.ZipFile(path) as archive, archive.open(name) as stream:
        raw = stream.read(length + 1)
    require(len(raw) == length and hashlib.sha256(raw).hexdigest() == expected, "Preuve ZIP modifiée : " + name)
    return parse_json(raw)


def check_production_sources(path, prod, source, prefix, commit):
    sources = source_inventory(source, commit)
    contract = bounded_archive_json(path, prefix + "package-contract.json", prod[1], 65536)
    registry = bounded_archive_json(path, prefix + "contracts/operation-contracts.json", prod[1], 2 * 1024**2)
    require(source.get("sourceDate") == contract["sourceDate"]
            and sources.get("tools/operation-contracts.json") == prod[1][prefix + "contracts/operation-contracts.json"]
            and all(row["path"] in sources and sources[row["path"]][1] == row["sha256"] for row in registry["files"]),
            "Le registre ou les sources de production ne correspondent pas à la provenance déclarée.")
    seed = source["seed"]
    if seed is not None:
        members(seed, ("fileName", "length", "sha256"), "Configuration de distribution")
        require(seed["fileName"] == "Domenia.settings.seed.json" and type(seed["length"]) is int and 1 <= seed["length"] <= 1024**2
                and hex_value(seed["sha256"], 64), "Configuration de distribution invalide.")
    require(prod[1].get(prefix + "Domenia.settings.seed.json") == (None if seed is None else (seed["length"], seed["sha256"])),
            "Configuration différente de la provenance source.")
    return sources


def check_operation_registry(document, expected):
    members(document, ("format", "scope", "operations", "files", "fingerprint"), "Registre des opérations")
    require(document["format"] == "Domenia.OperationContracts/1" and document["scope"] == "compiled-implementation-closure", "Format de registre inconnu.")
    operations = ("DnsReverseLookup", "LegacyMigration", "LocalIndexRead", "LocalStore", "ParkSharedSync", "StorageBackup",
                  "StorageIntegrity", "StorageMaintenance", "StoragePurge", "StorageRetention", "StorageUsage")
    files = document["files"]
    require(isinstance(files, list) and 10 <= len(files) <= 4096, "Fermeture du registre hors bornes.")
    names = []
    for row in files:
        members(row, ("path", "sha256"), "Corps épinglé")
        names.append(relative_name(row["path"]))
        projects = ("Domenia.Core", "Domenia.Store", "Domenia.Ad", "Domenia.Bridge", "Domenia.Inventory", "Domenia.App", "Domenia.Engine", "Domenia.Simulation")
        name = row["path"]
        require((name in ("Directory.Build.props", "global.json", "NuGet.config")
                 or any(name.startswith("src/" + project + "/") for project in projects)
                 and name.endswith((".cs", ".csproj")) and not any(part.casefold() in ("bin", "obj") for part in name.split("/")))
                and hex_value(row["sha256"], 64), "Chemin ou empreinte de corps invalide.")
    require(names == sorted(names) and len({name.casefold() for name in names}) == len(names), "Corps non triés ou répétés.")
    implementation = hashlib.sha256("".join(row["path"] + "=" + row["sha256"] + "\n" for row in files).encode()).hexdigest()
    rows = document["operations"]
    require(isinstance(rows, list) and len(rows) == len(operations), "Registre des opérations non fermé.")
    for row, name in zip(rows, operations):
        members(row, ("name", "implementationSha256"), "Opération épinglée")
        require(row["name"] == name and row["implementationSha256"] == implementation, "Corps ou nom différent du registre fermé.")
    fingerprint = hashlib.sha256("".join(name + "=" + implementation + "\n" for name in operations).encode()).hexdigest()
    require(document["fingerprint"] == fingerprint == expected, "Empreinte du registre différente de ses corps ou du contrat.")


def check_release_contract(contract, metadata, files, prefix="wad/"):
    members(contract, ("format", "label", "version", "build", "stage", "channel", "sourceCommit", "sourceDate", "registryFingerprint", "executableSha256", "executableVersion", "componentsFingerprint"), "Contrat de livraison")
    require(contract["format"] == "Domenia.Release/1" and contract["stage"] == "candidate" and contract["channel"] == "manual", "Étape de livraison invalide.")
    require(all(contract[k] == metadata[k] for k in ("version", "build", "sourceCommit", "executableSha256")), "Identités du contrat contradictoires.")
    require(isinstance(contract["sourceDate"], str) and re.fullmatch(r"20[0-9]{2}\.[0-9]{2}\.[0-9]{2}", contract["sourceDate"]), "Date du contrat invalide.")
    try:
        datetime.strptime(contract["sourceDate"], "%Y.%m.%d")
    except ValueError as error:
        raise Refused("Date du contrat impossible.") from error
    label = contract["sourceDate"] + "-DOMENIA-" + contract["version"] + "-CANDIDATE-" + contract["build"].split("+", 1)[1]
    require(contract["label"] == label and hex_value(contract["registryFingerprint"], 64), "Étiquette ou registre contradictoire.")
    require(isinstance(contract["executableVersion"], str) and contract["executableVersion"] == contract["version"] + ".0", "Version déclarée de l’exécutable différente.")
    text = "".join(name + "=" + digest + ":" + str(length) + "\n" for name, (length, digest) in sorted(files.items()) if name != prefix + "package-contract.json")
    require(contract["componentsFingerprint"] == hashlib.sha256(text.encode()).hexdigest(), "Composants du contrat différents.")
    for name in files:
        if name.startswith(prefix + "runtime/") or metadata["packageType"] == "DEV" and name.startswith(prefix + "developer/"):
            continue
        require(not re.search(r"(^|/)(tests?|fixtures?|samples?|previews?|screenshots?|developer|node_modules|\.git|\.env)(/|$)", name, re.I)
                and not re.search(r"(^|/)Domenia\.(Tests|WebTests|E2e|Capture)(\.|/)", name, re.I)
                and not re.search(r"\.(ps1|cmd|bat|sh|py|pdb|log|db|sqlite|env)$", name, re.I),
                "Contenu de recette ou privé dans le runtime : " + name)


def check_csharp(raw, expected_classes):
    log = raw.decode("utf-8-sig").replace("\r\n", "\n")
    selected = re.findall(r"^Sélection : critique ciblée ; ([0-9]+)/([0-9]+) tests retenus, ([0-9]+) non exécutés\.$", log, re.M)
    final = re.findall(r"^([0-9]+) réussis, ([0-9]+) en échec, ([0-9]+) au total\.$", log, re.M)
    passed = re.findall(r"^OK    ([A-Za-z0-9_]+\.[A-Za-z0-9_]+)\s*$", log, re.M)
    require(len(selected) == len(final) == 1 and "ECHEC " not in log, "Rapport C# critique absent, ambigu ou en échec.")
    count, available, omitted = map(int, selected[0])
    ok, failed, total = map(int, final[0])
    require(0 < count == total == ok == len(passed) == len(set(passed)) and failed == 0 and count + omitted == available
            and {name.split(".", 1)[0] for name in passed} == expected_classes, "Sélection C# vide, incomplète ou différente des classes critiques.")


def check_web(document):
    require(document.get("status") == "passed" and not document.get("error"), "Tests WebView2 non verts.")
    report = document.get("report", {})
    rows = report.get("results", [])
    require(report.get("selection") == "critical-only" and isinstance(rows, list) and rows
            and type(report.get("failed")) is int and report["failed"] == 0
            and type(report.get("passed")) is int and report["passed"] == len(rows), "Sélection WebView2 critique absente ou vide.")
    require(all(text(row.get("name")) and row.get("passed") is True and not row.get("error") for row in rows)
            and len({row["name"] for row in rows}) == len(rows), "Résultat WebView2 incomplet, répété ou en échec.")


def png(raw):
    require(len(raw) >= 33 and raw[:8] == b"\x89PNG\r\n\x1a\n" and raw[12:16] == b"IHDR"
            and 0 < int.from_bytes(raw[16:20], "big") <= 16384 and 0 < int.from_bytes(raw[20:24], "big") <= 16384, "Capture PNG absente ou inutilisable.")
    offset, chunks, payload = 8, 0, False
    while offset < len(raw):
        require(offset + 12 <= len(raw), "Capture PNG interrompue.")
        length = int.from_bytes(raw[offset:offset + 4], "big")
        end = offset + 12 + length
        require(end <= len(raw), "Bloc PNG tronqué.")
        kind = raw[offset + 4:offset + 8]
        require(zlib.crc32(raw[offset + 4:end - 4]) & 0xffffffff == int.from_bytes(raw[end - 4:end], "big"), "Bloc PNG altéré.")
        chunks += 1
        require(chunks <= 16384 and (kind != b"IHDR" or chunks == 1 and length == 13), "Structure PNG invalide.")
        payload |= kind == b"IDAT" and length > 0
        if kind == b"IEND":
            require(length == 0 and end == len(raw) and payload, "Fin PNG invalide.")
            return
        offset = end
    raise Refused("Capture PNG sans événement de fin.")


def check_ui(evidence, references, captures, machine, pack_path):
    observed = {mode: set() for mode in REQUIRED_UI}
    require(isinstance(references, list) and 2 <= len(references) <= 64, "Rapports UI ciblés requis dans les deux modes.")
    require(isinstance(captures, list) and 1 <= len(captures) <= 8192, "Inventaire des captures UI absent ou hors borne.")
    images = {}
    for reference in captures:
        image_path = evidence.path(reference, 32 * 1024**2)
        require(reference["path"] not in images, "Capture UI répétée dans le snapshot.")
        png(evidence.read(reference, 32 * 1024**2))
        images[reference["path"]] = image_path
    used = set()
    for reference in references:
        path = evidence.path(reference, 16 * 1024**2)
        report = evidence.json(reference, 16 * 1024**2)
        mode = report.get("mode")
        require(report.get("format") == "domenia.e2e.report" and report.get("version") == 1
                and report.get("machine", "").casefold() == machine.casefold() and mode in observed
                and report.get("exe", "").casefold() == pack_path.casefold(), "Rapport UI d’un autre poste, mode ou exécutable.")
        scenarios, summary = report.get("scenarios", []), report.get("summary", {})
        require(isinstance(scenarios, list) and scenarios and type(summary.get("passed")) is int and summary["passed"] == len(scenarios)
                and all(type(summary.get(key)) is int and summary[key] == 0 for key in ("failed", "skipped", "invalid")), "Scénario UI omis, invalide ou en échec.")
        for scenario in scenarios:
            require(text(scenario.get("id")) and scenario["id"] not in observed[mode] and scenario.get("verdict") == "passed"
                    and not scenario.get("error") and not scenario.get("consoleErrors") and scenario.get("exitCode") == 0,
                    "Scénario UI répété, non terminé ou en échec.")
            steps = scenario.get("steps", [])
            require(isinstance(steps, list) and len(steps) >= 2, "Scénario UI sans étapes exercées.")
            for step in steps:
                require(step.get("verdict") == "passed" and not step.get("error"), "Étape UI non verte.")
                screenshot = relative_name(step.get("screenshot"))
                image_path = path.parent / screenshot
                name = image_path.relative_to(evidence.root).as_posix()
                require(name in images and images[name] == image_path, "Capture UI non figée dans le snapshot : " + name)
                used.add(name)
            observed[mode].add(scenario["id"])
    for mode, required in REQUIRED_UI.items():
        require(required <= observed[mode], "Scénarios critiques UI manquants en " + mode + " : " + ", ".join(sorted(required - observed[mode])))
    require(used == set(images), "Capture UI sans étape correspondante.")


def check_native(raw, machine, commit, test_hash):
    require(raw.endswith(b"\n"), "Journal natif interrompu.")
    rows = [parse_json(line) for line in raw.splitlines()]
    require(2 <= len(rows) <= 129 and all(type(row.get("sequence")) is int and row["sequence"] == i + 1 for i, row in enumerate(rows)), "Séquence native invalide.")
    operations = [row.get("operation") for row in rows]
    require(len(set(operations)) == len(operations) and operations[0] == "manifest" and operations[-1] == "finished", "Recette native incomplète ou répétée.")
    events = {row["operation"]: row["value"] for row in rows}
    start, end = events["manifest"], events["finished"]
    manifest = start.get("manifest", {})
    require(start.get("machine", "").casefold() == machine.casefold() and type(start.get("sessionId")) is int
            and start["sessionId"] > 0 and start.get("mode") == "--critical-canary" and manifest.get("sourceCommit") == commit
            and manifest.get("assemblySha256") == test_hash and manifest.get("machine", "").casefold() == machine.casefold(), "Identité du protocole natif différente du lot ou du bureau.")
    require(end.get("state") == "ProtocolCompleted" and type(end.get("errors")) is int and end["errors"] == 0 and end.get("canaryRequested") is True
            and end.get("qualified") is False, "Protocole natif interrompu, en échec ou faussement qualifié.")
    selected = events.get("selection", {})
    members(selected, ("kind", "selected", "notExecuted", "selectedCount", "availableCount", "notExecutedCount", "qualified"), "Sélection native")
    require(selected["kind"] == "critical-only" and selected["qualified"] is False
            and isinstance(selected["selected"], list) and len(selected["selected"]) == len(NATIVE_READS)
            and set(selected["selected"]) == NATIVE_READS and isinstance(selected["notExecuted"], list)
            and len(selected["notExecuted"]) == len(NATIVE_AVAILABLE - NATIVE_READS)
            and set(selected["notExecuted"]) == NATIVE_AVAILABLE - NATIVE_READS
            and all(type(selected[key]) is int and selected[key] == value for key, value in (
                ("selectedCount", len(NATIVE_READS)), ("availableCount", len(NATIVE_AVAILABLE)),
                ("notExecutedCount", len(NATIVE_AVAILABLE - NATIVE_READS)))), "Sélection native critique absente ou ambiguë.")
    expected_events = {"manifest", "selection", "preflight", "canary.plan", "canary.receipt", "compensation.plan",
                       "compensation.receipt", "canary.restored", "finished"} | NATIVE_READS | {name + ".started" for name in NATIVE_READS}
    require(set(events) == expected_events, "Recette native critique incomplète ou lecture hors sélection.")
    for operation in NATIVE_READS:
        result = events[operation]
        require(result.get("state") == "Returned" and result.get("qualified") is False
                and result.get("identitiesCheckedAfter") is True, "Lecture native non terminée : " + operation)
    for operation in ("canary.receipt", "compensation.receipt"):
        receipt = events.get(operation, {})
        require(receipt.get("pending") is False and receipt.get("simulated") is False
                and receipt.get("result") == "Applied" and receipt.get("verification") == "Verified", "Canari ou compensation sans reçu vérifié.")
    restored = events.get("canary.restored", {})
    require(restored.get("independentRead") is True and restored.get("original") == events["canary.receipt"].get("id")
            and restored.get("compensation") == events["compensation.receipt"].get("id"), "Restauration du canari non prouvée.")
    for key in ("canary", "group"):
        require(manifest.get(key, {}).get("dn", "").lower().endswith(",ou=domenia-tests,dc=cnamts,dc=local"), "Cible de recette hors OU dédiée.")
    return set(NATIVE_READS)


def check_review(evidence, reference, snapshot, native_operations):
    review = evidence.json(reference)
    members(review, ("format", "reviewer", "reviewedAt", "sourceCommit", "machine", "packageManifestSha256", "native", "checks"), "Revue métier")
    require(review["format"] == "Domenia.ReleaseReview/1" and text(review["reviewer"], 100)
            and review["sourceCommit"] == snapshot["sourceCommit"] and review["machine"] == snapshot["machine"]
            and review["packageManifestSha256"] == snapshot["packageManifestSha256"], "Revue d’un autre contexte.")
    timestamp(review["reviewedAt"])
    require(isinstance(review["native"], dict) and set(review["native"]) == native_operations, "Chaque résultat natif brut doit être relu explicitement.")
    for key, value in review["native"].items():
        members(value, ("verdict", "note"), "Qualification native " + key)
        require(value["verdict"] == "passed" and text(value["note"], 2000), "Résultat natif non qualifié : " + key)
    require(isinstance(review["checks"], dict) and set(review["checks"]) == REVIEW_CHECKS, "Parcours critiques de revue incomplets.")
    for key, value in review["checks"].items():
        members(value, ("verdict", "note", "evidence"), "Revue " + key)
        require(value["verdict"] == "passed" and text(value["note"], 2000)
                and isinstance(value["evidence"], list) and 1 <= len(value["evidence"]) <= 32, "Parcours non validé : " + key)
        has_capture = False
        for reference in value["evidence"]:
            raw = evidence.read(reference, 32 * 1024**2)
            if reference["path"].lower().endswith(".png"):
                png(raw)
                has_capture = True
        require(key == "offline-cli-read-only" or has_capture, "Capture réellement revue requise : " + key)


def validate(path, commit):
    require(hex_value(commit, 40), "Commit attendu requis (40 caractères minuscules).")
    ordinary(path)
    evidence = Evidence(path.parent)
    size, digest = digest_file(path, 4 * 1024**2)
    document = evidence.json({"path": path.name, "length": size, "sha256": digest})
    members(document, ("format", "version", "sourceCommit", "packages", "vms"), "Dossier de livraison")
    require(document["format"] == "Domenia.ReleaseEvidence/1" and document["sourceCommit"] == commit
            and isinstance(document["version"], str) and re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", document["version"]), "Identité finale invalide.")
    version = document["version"]
    # Only PROD-LIGHT is published since 2026-11-08; PROD/DEV pairs are earlier deliveries.
    production = "prodLight" in document["packages"]
    keys = ("prodLight",) if production else ("prod", "dev")
    members(document["packages"], (*keys, "sha256", "sourceManifest", "criticalSelection") if production else (*keys, "sha256"), "Archives finales")
    packages = {}
    for key in keys:
        kind = {"prod": "PROD", "prodLight": "PROD-LIGHT", "dev": "DEV"}[key]
        archive_path = evidence.path(document["packages"][key], MAX_ARCHIVE)
        require(archive_path.name == "Domenia_" + version + "_" + kind + "_Windows-x64.zip", "Nom de ZIP de livraison inattendu.")
        packages[kind] = check_archive(archive_path, kind, version, commit)
    prod = packages["PROD-LIGHT" if production else "PROD"]
    prefix = payload_prefix(version)
    if production:
        require(not any(n.casefold().startswith(prefix + "developer/") for n in prod[1]), "Sources de développement dans le pack de production.")
        sources = check_production_sources(evidence.path(document["packages"]["prodLight"], MAX_ARCHIVE), prod,
                                          evidence.json(document["packages"]["sourceManifest"]), prefix, commit)
        raw = evidence.read(document["packages"]["criticalSelection"], 65536)
        require(sources.get("tests/Domenia.Tests/CriticalTestSelection.cs") == (len(raw), hashlib.sha256(raw).hexdigest()),
                "La sélection critique ne provient pas du commit.")
        selection = raw.decode("utf-8-sig")
    else:
        dev = packages["DEV"]
        require({k: v for k, v in prod[0].items() if k != "packageType"} == {k: v for k, v in dev[0].items() if k != "packageType"}
                and all(dev[1].get(name) == value for name, value in prod[1].items() if name != prefix + "package-release.json"), "Binaires ou ressources PROD/DEV différents.")
        require(set(dev[1]) == set(prod[1]) | {prefix + "developer/source-commit.json"} | {prefix + "developer/v2/" + name for name in dev[3]}, "Fichier DEV non justifié par le PROD ou les sources du commit.")
        sources, selection = dev[3], dev[4]
    lines = evidence.read(document["packages"]["sha256"], 65536).decode("utf-8-sig").splitlines()
    expected = {document["packages"][key]["sha256"] + "  " + Path(document["packages"][key]["path"]).name for key in keys}
    require(len(lines) == len(keys) and set(lines) == expected, "SHA256SUMS ne décrit pas exactement les archives livrées.")
    critical = set(re.findall(r'"([A-Za-z0-9_]+Tests)"', selection))
    require(len(critical) >= 20, "Sélection critique C# absente des sources.")
    require(isinstance(document["vms"], list) and len(document["vms"]) == 2, "Deux dossiers VM distincts sont obligatoires.")
    seen_vms, seen_machines, test_files = set(), set(), None
    for vm in document["vms"]:
        members(vm, ("snapshot", "review"), "Preuves VM")
        snapshot = evidence.json(vm["snapshot"])
        members(snapshot, ("format", "capturedAt", "vmName", "vmUuid", "machine", "systemUuid", "sessionId", "os",
                           "sourceCommit", "packageManifestSha256", "executableSha256", "executablePath", "testFiles",
                           "sourceManifest", "debugBuild", "releaseBuild", "csharp", "web", "webScreenshot", "ui", "uiScreenshots", "native"), "Capture de preuves VM")
        name, machine = snapshot["vmName"], snapshot["machine"]
        require(snapshot["format"] == "Domenia.ReleaseSnapshot/1" and name in VMS and name not in seen_vms
                and snapshot["vmUuid"] == VMS[name] and snapshot["systemUuid"].lower() == VMS[name]
                and text(machine, 63) and machine.casefold() not in seen_machines and snapshot["os"] == "Win32NT"
                and type(snapshot["sessionId"]) is int and snapshot["sessionId"] > 0, "Identité VM ou session interactive non qualifiée.")
        timestamp(snapshot["capturedAt"])
        require(snapshot["sourceCommit"] == commit and snapshot["packageManifestSha256"] == prod[2]
                and snapshot["executableSha256"] == prod[0]["executableSha256"] and text(snapshot["executablePath"]), "Paquet testé différent du pack livré exact.")
        current_tests = inventory(snapshot["testFiles"], 1024, 512 * 1024**2)
        require("Domenia.Tests.dll" in current_tests, "Assemblage de tests absent.")
        require(test_files is None or current_tests == test_files, "Les deux VM n’ont pas testé les mêmes octets du pilote.")
        test_files = current_tests
        require(source_inventory(evidence.json(snapshot["sourceManifest"]), commit) == sources, "Sources VM différentes de la provenance déclarée.")
        for configuration, key in (("Debug", "debugBuild"), ("Release", "releaseBuild")):
            build = evidence.read(snapshot[key], 32 * 1024**2).decode("utf-8-sig")
            require("Build succeeded." in build and re.search(r"^\s*0 Warning\(s\)\s*$", build, re.M)
                    and re.search(r"^\s*0 Error\(s\)\s*$", build, re.M) and "\\" + configuration + "\\" in build
                    and not re.search(r"\b(?:warning|error)\s+[A-Z]+\d+\s*:", build, re.I), "Compilation " + configuration + " non verte.")
        check_csharp(evidence.read(snapshot["csharp"], 32 * 1024**2), critical)
        check_web(evidence.json(snapshot["web"], 16 * 1024**2))
        png(evidence.read(snapshot["webScreenshot"], 32 * 1024**2))
        check_ui(evidence, snapshot["ui"], snapshot["uiScreenshots"], machine, snapshot["executablePath"])
        native = check_native(evidence.read(snapshot["native"]), machine, commit, current_tests["Domenia.Tests.dll"][1])
        check_review(evidence, vm["review"], snapshot, native)
        seen_vms.add(name)
        seen_machines.add(machine.casefold())
    require(seen_vms == set(VMS), "VM autorisée manquante.")
    evidence.unchanged()
    return {"format": "Domenia.ReleaseGate/1", "eligible": True, "sourceCommit": commit, "version": version,
            "evidenceSha256": digest, "archives": document["packages"], "vms": sorted(seen_vms),
            "scope": "Tests critiques et revues natives/UI fournis ; aucune validation exhaustive déduite.",
            "published": False, "publisherTrust": "not-established"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--commit", required=True)
    args = parser.parse_args()
    try:
        result = validate(args.evidence.absolute(), args.commit)
    except (Refused, OSError, ValueError, KeyError, TypeError, AttributeError, zipfile.BadZipFile, EOFError) as error:
        print("Publication finale refusée : " + str(error), file=sys.stderr)
        return 1
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
