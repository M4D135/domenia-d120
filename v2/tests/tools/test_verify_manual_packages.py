"""Critical integrity checks for manual delivery, using synthetic ZIP fixtures only.

Reserved for the final Windows validation phase. These fixtures never qualify a real
application, native/UI acceptance or the provenance of a compiled production binary.
"""
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock
import zipfile


spec = importlib.util.spec_from_file_location(
    "domenia_verify_manual_packages", Path(__file__).resolve().parents[2] / "tools" / "verify-manual-packages.py")
verifier = importlib.util.module_from_spec(spec)
previous = sys.dont_write_bytecode
try:
    sys.dont_write_bytecode = True
    spec.loader.exec_module(verifier)
finally:
    sys.dont_write_bytecode = previous

COMMIT = "a" * 40
VERSION = "2.0.0"


def encoded(document):
    return json.dumps(document, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def rows(files):
    return [{"path": name, "length": len(raw), "sha256": hashlib.sha256(raw).hexdigest()}
            for name, raw in sorted(files.items())]


def make_packages(directory, dev_changes=None, seed=None, version=VERSION, schema_revision=None, contract=False, contract_change=None, production=False, light_changes=None):
    prod = {"Domenia.exe": b"synthetic executable, never run", "web/index.html": b"<p>original</p>",
            "runtime/webview2/msedgewebview2.exe": b"synthetic runtime, never run",
            "System.Private.CoreLib.dll": b"synthetic library"}
    for name in ("Core", "Bridge", "Ad", "Engine", "Store", "Inventory", "Simulation"):
        prod["Domenia." + name + ".dll"] = ("synthetic " + name).encode()
    sources = {"tests/Domenia.Tests/CriticalTestSelection.cs": b'class CriticalTestSelection { }',
               "src/Domenia.App/Program.cs": b"// original source fixture"}
    if contract:
        for number in range(10):
            sources[f"src/Domenia.Core/Fixture{number:02}.cs"] = ("// source fixture " + str(number)).encode()
        bodies = [{"path": name, "sha256": hashlib.sha256(raw).hexdigest()} for name, raw in sorted(sources.items()) if name.startswith('src/')]
        implementation = hashlib.sha256(''.join(row['path'] + '=' + row['sha256'] + '\n' for row in bodies).encode()).hexdigest()
        operations = ('DnsReverseLookup', 'LegacyMigration', 'LocalIndexRead', 'LocalStore', 'ParkSharedSync', 'StorageBackup',
                      'StorageIntegrity', 'StorageMaintenance', 'StoragePurge', 'StorageRetention', 'StorageUsage')
        fingerprint = hashlib.sha256(''.join(name + '=' + implementation + '\n' for name in operations).encode()).hexdigest()
        registry = encoded({"format": "Domenia.OperationContracts/1", "scope": "compiled-implementation-closure",
                            "operations": [{"name": name, "implementationSha256": implementation} for name in operations], "files": bodies, "fingerprint": fingerprint})
        prod["contracts/operation-contracts.json"] = registry
        prod["contracts/build-environment.json"] = encoded({"format": "Domenia.BuildEnvironment/1", "sourceCommit": COMMIT, "sdk": "10.0.401", "powershell": "5.1", "steps": ["synthetic fixture only"]})
        sources["tools/operation-contracts.json"] = registry
    source_manifest = {"format": 1, "sourceCommit": COMMIT, "files": rows(sources), "seed": seed}
    if contract:
        source_manifest["sourceDate"] = "2026.11.01"
    if production:
        if not contract:
            raise ValueError("Production fixtures require a sealed contract")
        for name in ("dotnet.exe", "host/fxr/10.0.13/hostfxr.dll", "shared/Microsoft.NETCore.App/10.0.13/coreclr.dll",
                     "shared/Microsoft.NETCore.App/10.0.13/System.Private.CoreLib.dll", "shared/Microsoft.WindowsDesktop.App/10.0.13/System.Windows.Forms.dll"):
            prod["runtime/dotnet/" + name] = b"synthetic private runtime"
        (directory / "source-commit.json").write_bytes(encoded(source_manifest))
    dev = dict(prod)
    dev["developer/source-commit.json"] = encoded(source_manifest)
    dev.update({"developer/v2/" + name: raw for name, raw in sources.items()})
    dev.update(dev_changes or {})
    checksums = []
    if production:
        light = {name: raw for name, raw in prod.items() if not name.startswith("runtime/webview2/")}
        light.update(light_changes or {})
        editions = (("PROD-LIGHT", light),)
    else:
        editions = (("PROD", prod), ("DEV", dev))
    for kind, files in editions:
        files["package-release.json"] = encoded({
            "version": version, "build": version + "+" + "b" * 64,
            "dataSchemaVersion": 11, "dataSchemaRevision": schema_revision if schema_revision is not None else (2 if version in ("2.0.5", "2.0.6", "2.0.7", "2.0.8", "2.1.0", "2.1.1", "2.1.2", "2.1.3", "2.1.4") else 1), "project": "Domenia",
            "architecture": "win-x64", "packageType": kind, "sourceCommit": COMMIT,
            "executableSha256": hashlib.sha256(files["Domenia.exe"]).hexdigest(),
            "dependencies": {".NET": "10.0.13" if production else "fixture", "WebView2": "Evergreen" if kind == "PROD-LIGHT" else "fixture"}})
        prefix = "wad/" if version in ("2.0.4", "2.0.5", "2.0.6", "2.0.7", "2.0.8", "2.1.0", "2.1.1", "2.1.2", "2.1.3", "2.1.4") else ""
        files = {name if name == "Domenia.exe" else prefix + name: raw for name, raw in files.items()}
        if contract:
            metadata = json.loads(files[prefix + "package-release.json"])
            identity = "".join(name + "=" + hashlib.sha256(raw).hexdigest() + ":" + str(len(raw)) + "\n" for name, raw in sorted(files.items()))
            document = {"format": "Domenia.Release/1", "label": "2026.11.01-DOMENIA-" + version + "-CANDIDATE-" + "b" * 64,
                        "version": version, "build": metadata["build"], "stage": "candidate", "channel": "manual", "sourceCommit": COMMIT,
                        "sourceDate": "2026.11.01", "registryFingerprint": fingerprint, "executableSha256": metadata["executableSha256"],
                        "executableVersion": version + ".0", "componentsFingerprint": hashlib.sha256(identity.encode()).hexdigest()}
            if contract_change:
                contract_change(kind, document)
            files[prefix + "package-contract.json"] = encoded(document)
        manifest = encoded({"format": 2, "packageType": "PROD-LIGHT", "files": rows(files)} if kind == "PROD-LIGHT"
                           else {"format": 1, "files": rows(files)})
        path = directory / ("Domenia_" + version + "_" + kind + "_Windows-x64.zip")
        with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for name, raw in sorted(files.items()):
                archive.writestr(name, raw)
            archive.writestr(prefix + "package-manifest.json", manifest)
            archive.writestr(prefix + ".lifecycle.lock", b"")
        checksums.append(hashlib.sha256(path.read_bytes()).hexdigest() + "  " + path.name)
    (directory / "SHA256SUMS.txt").write_text("\n".join(checksums) + "\n", encoding="utf-8")


class ManualPackageIntegrityCriticalTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name).absolute()

    def test_current_delivery_is_the_light_package_alone_with_its_source_provenance(self):
        for extra in (None, "PROD", "DEV"):
            with self.subTest(extra=extra), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                make_packages(root, version="2.0.8", contract=True, production=True)
                if extra is None:
                    report = verifier.verify_packages(root, COMMIT, "2.0.8", require_production=True)
                    self.assertEqual(set(report["archives"]), {"PROD-LIGHT"})
                    self.assertEqual(report["archives"]["PROD-LIGHT"]["metadata"]["dependencies"]["WebView2"], "Evergreen")
                    self.assertEqual(report["sourceProvenance"]["sourceCommit"], COMMIT)
                    self.assertTrue(report["scope"].startswith("Intégrité de l’archive PROD-LIGHT"))
                    continue
                (root / ("Domenia_2.0.8_" + extra + "_Windows-x64.zip")).write_bytes(b"unrequested")
                with self.assertRaises(verifier.guard.Refused):
                    verifier.verify_packages(root, COMMIT, "2.0.8", require_production=True)

    def test_self_consistent_light_zip_cannot_embed_a_browser(self):
        for changes in ({"runtime/webview2/msedgewebview2.exe": b"browser"}, {"other/msedge.dll": b"browser"}):
            with self.subTest(changes=tuple(changes)), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                make_packages(root, version="2.0.8", contract=True, production=True, light_changes=changes)
                with self.assertRaises(verifier.guard.Refused):
                    verifier.verify_packages(root, COMMIT, "2.0.8", require_production=True)

    def test_release_contract_binds_both_archives_source_date_and_registry(self):
        make_packages(self.directory, version="2.0.8", contract=True)
        result = verifier.verify_packages(self.directory, COMMIT, "2.0.8")
        self.assertEqual("verified", result["integrity"])
        self.assertEqual("not-established", result["publisherTrust"])
        for key, value in (("label", "wrong"), ("registryFingerprint", "d" * 64), ("componentsFingerprint", "e" * 64),
                           ("executableVersion", "9.0.0.0"), ("sourceDate", "2026.02.30")):
            with self.subTest(key=key):
                make_packages(self.directory, version="2.0.8", contract=True, contract_change=lambda kind, doc: doc.update({key: value}))
                with self.assertRaises(verifier.guard.Refused):
                    verifier.verify_packages(self.directory, COMMIT, "2.0.8")

    def test_registry_cannot_keep_its_fingerprint_after_body_or_operation_changes(self):
        make_packages(self.directory, version="2.0.8", contract=True)
        with zipfile.ZipFile(self.directory / 'Domenia_2.0.8_PROD_Windows-x64.zip') as archive:
            raw = archive.read('wad/contracts/operation-contracts.json')
        original = json.loads(raw)
        expected = original['fingerprint']
        for mutation in (lambda doc: doc['files'][0].update(sha256='0' * 64),
                         lambda doc: doc.update(files=[]),
                         lambda doc: doc['operations'][0].update(name='Unknown'),
                         lambda doc: doc['operations'][0].update(implementationSha256='0' * 64),
                         lambda doc: doc['files'].append(doc['files'][0])):
            document = json.loads(raw)
            mutation(document)
            with self.assertRaises(verifier.guard.Refused):
                verifier.guard.check_operation_registry(document, expected)

    def test_exact_archives_yield_only_integrity_and_pending_acceptance(self):
        make_packages(self.directory)
        result = verifier.verify_packages(self.directory, COMMIT, VERSION)
        self.assertTrue(result["eligibleForManualDelivery"])
        self.assertNotIn("eligible", result)
        self.assertEqual("Domenia.ManualPackageVerification/1", result["format"])
        self.assertFalse(result["published"])
        self.assertEqual("pending", result["userManualAcceptance"])
        for key in ("uiAcceptance", "twoVmAcceptance", "domainAcceptance"):
            self.assertEqual("not-run", result[key])
        self.assertEqual("not-established-by-this-tool", result["sourceProvenance"]["binaryBuildProvenance"])
        self.assertEqual(2, result["sourceProvenance"]["fileCount"])
        self.assertEqual(result["archives"]["PROD"]["executable"], result["archives"]["DEV"]["executable"])
        for kind in ("PROD", "DEV"):
            archive = result["archives"][kind]
            self.assertEqual(hashlib.sha256((self.directory / archive["path"]).read_bytes()).hexdigest(), archive["sha256"])
            self.assertEqual(archive["entryCount"], len(archive["files"]))
        output = self.directory / "integrity.json"
        receipt = verifier.write_report(output, result)
        self.assertEqual(result, json.loads(output.read_text(encoding="utf-8")))
        self.assertEqual(hashlib.sha256(output.read_bytes()).hexdigest(), receipt["sha256"])

    def test_corrective_version_is_explicit_and_other_versions_remain_refused(self):
        make_packages(self.directory, version="2.0.1")
        result = verifier.verify_packages(self.directory, COMMIT, "2.0.1")
        self.assertEqual("2.0.1", result["version"])
        self.assertIn("26 octobre 2026", result["scope"])
        self.assertEqual("pending", result["userManualAcceptance"])
        for version in ("2.0.9", "3.0.0", "2.0.1-rc.1"):
            with self.subTest(version=version), self.assertRaises(verifier.guard.Refused):
                verifier.verify_packages(self.directory, COMMIT, version)

    def test_collection_login_corrective_version(self):
        for version in ("2.0.2", "2.0.3", "2.0.4", "2.0.5", "2.0.6", "2.0.7", "2.0.8", "2.1.0", "2.1.1", "2.1.2", "2.1.3", "2.1.4"):
            with self.subTest(version=version):
                make_packages(self.directory, version=version)
                result = verifier.verify_packages(self.directory, COMMIT, version)
                self.assertEqual(version, result["version"])
                self.assertEqual("pending", result["userManualAcceptance"])

    def test_wad_layout_covers_executable_and_payload_and_refuses_root_extras(self):
        make_packages(self.directory, version="2.0.4")
        result = verifier.verify_packages(self.directory, COMMIT, "2.0.4")
        self.assertEqual("wad/package-manifest.json", result["archives"]["PROD"]["manifest"]["path"])
        self.assertEqual("wad/developer/source-commit.json", result["sourceProvenance"]["manifest"]["path"])
        path = self.directory / "Domenia_2.0.4_PROD_Windows-x64.zip"
        with zipfile.ZipFile(path, "a") as archive:
            archive.writestr("Domenia.Core.dll", b"old leftover")
        with self.assertRaises(verifier.guard.Refused):
            verifier.guard.check_archive(path, "PROD", "2.0.4", COMMIT)

    def test_fleet_migration_revision_cannot_be_mislabeled_in_an_otherwise_valid_archive(self):
        for version, revision in (("2.0.5", 1), ("2.0.6", 1), ("2.0.7", 1), ("2.0.8", 1), ("2.1.0", 1), ("2.1.1", 1), ("2.1.2", 1), ("2.1.3", 1), ("2.1.4", 1), ("2.0.4", 2)):
            with self.subTest(version=version, revision=revision):
                make_packages(self.directory, version=version, schema_revision=revision)
                with self.assertRaises(verifier.guard.Refused):
                    verifier.verify_packages(self.directory, COMMIT, version)

    def test_same_executable_does_not_hide_a_different_dev_resource(self):
        make_packages(self.directory, {"web/index.html": b"<p>changed</p>"})
        with self.assertRaises(verifier.guard.Refused):
            verifier.verify_packages(self.directory, COMMIT, VERSION)

    def test_valid_zip_manifests_do_not_hide_source_mutation_or_unjustified_dev_files(self):
        for changes in ({"developer/v2/src/Domenia.App/Program.cs": b"// changed source"},
                        {"private/unjustified.txt": b"not a PROD file or source"}):
            with self.subTest(changes=tuple(changes)):
                make_packages(self.directory, changes)
                with self.assertRaises(verifier.guard.Refused):
                    verifier.verify_packages(self.directory, COMMIT, VERSION)

    def test_checksum_file_must_cover_the_actual_two_archives(self):
        make_packages(self.directory)
        path = self.directory / "SHA256SUMS.txt"
        text = path.read_text(encoding="utf-8")
        path.write_text(("0" if text[0] != "0" else "1") + text[1:], encoding="utf-8")
        with self.assertRaises(verifier.guard.Refused):
            verifier.verify_packages(self.directory, COMMIT, VERSION)

    def test_change_after_zip_validation_cannot_create_a_success_report(self):
        make_packages(self.directory)
        original = verifier.guard.check_archive

        def change_after(path, kind, version, commit):
            result = original(path, kind, version, commit)
            if kind == "DEV":
                with (self.directory / "Domenia_2.0.0_PROD_Windows-x64.zip").open("ab") as stream:
                    stream.write(b"changed after archive validation")
            return result

        output = self.directory / "must-not-exist.json"
        with mock.patch.object(verifier.guard, "check_archive", side_effect=change_after), contextlib.redirect_stderr(io.StringIO()):
            status = verifier.main(["--directory", str(self.directory), "--commit", COMMIT,
                                    "--version", VERSION, "--out", str(output)])
        self.assertEqual(1, status)
        self.assertFalse(output.exists())

    def test_existing_output_is_preserved_even_for_valid_archives(self):
        make_packages(self.directory)
        output = self.directory / "integrity.json"
        output.write_bytes(b"prior evidence remains exact")
        with contextlib.redirect_stderr(io.StringIO()):
            status = verifier.main(["--directory", str(self.directory), "--commit", COMMIT,
                                    "--version", VERSION, "--out", str(output)])
        self.assertEqual(1, status)
        self.assertEqual(b"prior evidence remains exact", output.read_bytes())

    def test_seed_declared_by_source_cannot_be_missing_from_both_packages(self):
        make_packages(self.directory, seed={"fileName": "Domenia.settings.seed.json", "length": 1, "sha256": "c" * 64})
        with self.assertRaises(verifier.guard.Refused):
            verifier.verify_packages(self.directory, COMMIT, VERSION)


if __name__ == "__main__":
    if os.name != "nt":
        raise SystemExit("Tests critiques réservés à Windows, en phase finale ; aucune suite exécutée ici.")
    unittest.main()
