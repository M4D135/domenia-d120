"""Browser evidence verifier tests using synthetic files only, with no browser or application.

These portable standard-library tests do not qualify a real build or human visual review.
"""
import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import re
import struct
import sys
import tempfile
import unittest
from unittest import mock
import zlib


ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("domenia_browser_evidence", ROOT / "tools" / "verify-ci-browser-evidence.py")
verifier = importlib.util.module_from_spec(spec)
previous = sys.dont_write_bytecode
try:
    sys.dont_write_bytecode = True
    spec.loader.exec_module(verifier)
finally:
    sys.dont_write_bytecode = previous
COMMIT = "a" * 40


def encoded(value):
    return json.dumps(value, ensure_ascii=False).encode("utf-8")


def png():
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(b"\0\0\0\0")) + chunk(b"IEND", b""))


class BrowserEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name).resolve()
        self.web, self.ui, self.package = [self.directory / name for name in ("web", "ui", "package")]
        for directory in (self.web, self.ui, self.package):
            directory.mkdir()
        self.make_fixture("2.0.1")

    def write(self, path, value):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(encoded(value))

    def make_fixture(self, version, light=False):
        payload = self.package / "wad" if version in ("2.0.4", "2.0.5", "2.0.6", "2.0.7", "2.0.8", "2.1.0", "2.1.1", "2.1.2", "2.1.3", "2.1.4", "2.1.5") else self.package
        for name in ("package-release.json", "package-manifest.json"):
            for directory in (self.package, self.package / "wad"):
                (directory / name).unlink(missing_ok=True)
        exe = b"synthetic executable, never run"
        (self.package / "Domenia.exe").write_bytes(exe)
        self.write(payload / "package-release.json", {"project": "Domenia", "packageType": "PROD-LIGHT" if light else "PROD", "version": version,
                   "sourceCommit": COMMIT, "architecture": "win-x64", "executableSha256": hashlib.sha256(exe).hexdigest()})
        rows = [{"path": "Domenia.exe", "length": len(exe), "sha256": hashlib.sha256(exe).hexdigest()}]
        self.write(payload / "package-manifest.json", {"format": 2, "packageType": "PROD-LIGHT", "files": rows} if light else {"format": 1, "files": rows})
        self.write(self.web / "report.json", {"status": "passed", "error": "", "report": {"selection": "critical-only",
                   "passed": 1, "failed": 0, "results": [{"name": "synthetic check", "passed": True}]}})
        (self.web / "page.png").write_bytes(png())
        if version in verifier.CORRECTIVE_VERSIONS:
            for name in verifier.recipe_captures(version):
                (self.web / ("visual-" + name + ".png")).write_bytes(png())
                self.write(self.web / ("visual-" + name + ".json"), {"name": name, "facts": {}})
        scenarios = []
        for name in sorted(verifier.SETTINGS_REQUIRED if version in verifier.COLLECTION_VERSIONS else verifier.REQUIRED):
            steps = []
            for index, action in enumerate(("start", "capture")):
                relative = "shots/" + name + "/" + str(index).zfill(2) + "-" + action + ".png"
                path = self.ui / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(png())
                steps.append({"index": index, "action": action, "verdict": "passed", "screenshot": relative})
            scenarios.append({"id": name, "verdict": "passed", "exitCode": 0, "consoleErrors": [], "steps": steps})
        self.write(self.ui / "report.json", {"format": "domenia.e2e.report", "version": 1, "mode": "simulation",
                   "machine": "fixture", "exe": str(self.package / "Domenia.exe"), "startedAt": "2026-10-26T12:00:00Z",
                   "scenarios": scenarios, "summary": {"passed": len(scenarios), "failed": 0, "skipped": 0, "invalid": 0}})

    def verify(self, version="2.0.1"):
        return verifier.verify(self.web / "report.json", self.ui / "report.json", self.package, COMMIT, version)

    def test_corrective_evidence_rehashes_images_and_facts_without_claiming_human_review(self):
        result = self.verify()
        self.assertEqual("2.0.1", result["version"])
        self.assertEqual(16, result["visualCaptureCount"])
        self.assertEqual("pending", result["visualReview"])
        self.assertEqual("not-run", result["domainAcceptance"])
        for capture in result["web"]["visualCaptures"]:
            for kind in ("image", "facts"):
                reference = capture[kind]
                raw = (self.web / reference["path"]).read_bytes()
                self.assertEqual((len(raw), hashlib.sha256(raw).hexdigest()), (reference["length"], reference["sha256"]))

    def test_declared_names_match_the_current_browser_recipe(self):
        source = (ROOT / "tests" / "web" / "recette-ui.test.mjs").read_text(encoding="utf-8")
        names = re.findall(r"await capture\('([^']+)'", source)
        self.assertEqual(len(names), len(set(names)))
        # The recipe in the tree is the one of the version being built.
        version = re.search(r"<Version>([^<]+)</Version>", (ROOT / "Directory.Build.props").read_text(encoding="utf-8")).group(1)
        self.assertEqual(verifier.recipe_captures(version), set(names))

    def test_evidence_scenarios_keep_a_screenshot_for_every_step(self):
        # The verifier requires one screenshot per step: a step of these scenarios cannot opt out of its capture.
        for identifier in sorted(verifier.SETTINGS_REQUIRED):
            with self.subTest(scenario=identifier):
                document = json.loads((ROOT / "tests" / "e2e" / (identifier + ".json")).read_text(encoding="utf-8"))
                self.assertFalse([step for step in document["steps"] if step.get("capture") is False])

    def test_legacy_delivery_remains_explicit_and_does_not_require_corrective_captures(self):
        self.make_fixture("2.0.0")
        for path in self.web.glob("visual-*"):
            path.unlink()
        result = self.verify("2.0.0")
        self.assertEqual("2.0.0", result["version"])
        self.assertEqual(0, result["visualCaptureCount"])

    def test_collection_version_requires_its_exact_extra_captures(self):
        for version in sorted(verifier.COLLECTION_VERSIONS):
            with self.subTest(version=version):
                self.make_fixture(version)
                result = self.verify(version)
                self.assertEqual(len(verifier.recipe_captures(version)), result["visualCaptureCount"])
                (self.web / "visual-comptes-domaine-mesure-affichee.png").unlink()
                with self.assertRaises(verifier.guard.Refused):
                    self.verify(version)

    def test_incomplete_presence_capture_is_required_from_2_0_8_only(self):
        for version in sorted(verifier.PRESENCE_VERSIONS):
            with self.subTest(version=version):
                self.make_fixture(version)
                for extension in (".png", ".json"):
                    (self.web / ("visual-actualisation-incomplete" + extension)).unlink()
                with self.assertRaises(verifier.guard.Refused):
                    self.verify(version)
        for extension in (".png", ".json"):
            (self.web / ("visual-mises-a-jour-encadre-lisible" + extension)).unlink(missing_ok=True)
        self.make_fixture("2.0.7")
        self.assertEqual(len(verifier.COLLECTION_CAPTURES), self.verify("2.0.7")["visualCaptureCount"])

    def test_published_light_pack_is_accepted_only_with_a_consistent_light_manifest(self):
        self.make_fixture("2.0.8", light=True)
        self.assertEqual(7, self.verify("2.0.8")["simulationUiCount"])
        release = self.package / "wad" / "package-release.json"
        manifest = self.package / "wad" / "package-manifest.json"
        metadata = json.loads(release.read_text())
        self.write(release, {**metadata, "packageType": "PROD"})
        with self.assertRaises(verifier.guard.Refused):
            self.verify("2.0.8")
        self.write(release, metadata)
        document = json.loads(manifest.read_text())
        for changed in ({**document, "packageType": "PROD"}, {key: value for key, value in document.items() if key != "packageType"}):
            with self.subTest(manifest=changed):
                self.write(manifest, changed)
                with self.assertRaises(verifier.guard.Refused):
                    self.verify("2.0.8")

    def test_collection_version_requires_the_settings_keyboard_scenario(self):
        for version in sorted(verifier.COLLECTION_VERSIONS):
            with self.subTest(version=version):
                self.make_fixture(version)
                self.assertEqual(7, self.verify(version)["simulationUiCount"])
                path = self.ui / "report.json"
                report = json.loads(path.read_text())
                report["scenarios"] = [item for item in report["scenarios"] if item["id"] != "shell/apparence-clavier"]
                report["summary"]["passed"] = len(report["scenarios"])
                self.write(path, report)
                with self.assertRaises(verifier.guard.Refused):
                    self.verify(version)

    def test_other_or_mismatched_versions_are_refused(self):
        for version in ("2.0.0", "2.0.2", "2.0.3", "2.0.4", "2.0.5", "2.0.6", "2.0.7", "2.0.8", "2.1.0", "2.1.1", "2.1.2", "2.1.3", "2.1.4", "2.1.5", "2.0.1-rc.1", "3.0.0"):
            with self.subTest(version=version), self.assertRaises(verifier.guard.Refused):
                self.verify(version)

    def test_missing_image_or_facts_file_and_corrupt_png_are_refused(self):
        for suffix in (".png", ".json"):
            path = self.web / ("visual-accueil-deconnecte" + suffix)
            raw = path.read_bytes()
            path.unlink()
            with self.subTest(missing=suffix), self.assertRaises(verifier.guard.Refused):
                self.verify()
            path.write_bytes(raw)
        (self.web / "visual-accueil-deconnecte.png").write_bytes(png()[:-1])
        with self.assertRaises(verifier.guard.Refused):
            self.verify()

    def test_mismatched_or_malformed_facts_and_extra_capture_are_refused(self):
        path = self.web / "visual-accueil-deconnecte.json"
        for document in ({"name": "another-screen", "facts": {}}, {"name": "accueil-deconnecte", "facts": []},
                         {"name": "accueil-deconnecte"}):
            self.write(path, document)
            with self.subTest(document=document), self.assertRaises(verifier.guard.Refused):
                self.verify()
        self.write(path, {"name": "accueil-deconnecte", "facts": {}})
        (self.web / "visual-extra.png").write_bytes(png())
        with self.assertRaises(verifier.guard.Refused):
            self.verify()

    def test_capture_mutation_during_validation_is_refused(self):
        original = verifier.guard.Evidence.unchanged
        def mutate(evidence):
            if evidence.root == self.web:
                (self.web / "visual-accueil-deconnecte.json").write_bytes(b"{}")
            original(evidence)
        with mock.patch.object(verifier.guard.Evidence, "unchanged", mutate), self.assertRaises(verifier.guard.Refused):
            self.verify()

    def test_cli_requires_version_and_returns_it_in_report_and_stdout(self):
        output = self.directory / "verified.json"
        args = ["--web-report", str(self.web / "report.json"), "--ui-report", str(self.ui / "report.json"),
                "--package", str(self.package), "--commit", COMMIT, "--out", str(output)]
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            verifier.main(args)
        self.assertFalse(output.exists())
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            self.assertEqual(0, verifier.main(args + ["--version", "2.0.1"]))
        self.assertEqual("2.0.1", json.loads(stdout.getvalue())["version"])
        self.assertEqual("2.0.1", json.loads(output.read_text(encoding="utf-8"))["version"])


if __name__ == "__main__":
    unittest.main()
