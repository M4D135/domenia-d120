"""Offline packaging regression checks; temporary snapshots only, never run Domenia.

Usage: python3 dev/tools/tests/test_classic_packaging.py --powershell /path/to/pwsh
Windows PowerShell 5.1 may be passed instead. These checks do not qualify WPF or AD.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

DEV = Path(__file__).resolve().parents[2]
TOOLS = DEV / 'tools'
sys.path.insert(0, str(TOOLS))
sys.path.insert(0, str(DEV / 'wad/tests'))
import build_packages
from powershell_lex import functions

PS = None


def sha(data):
    return hashlib.sha256(data).hexdigest().upper()


def snapshot(root):
    return {p.relative_to(root).as_posix(): sha(p.read_bytes())
            for p in root.rglob('*') if p.is_file() and not p.is_symlink()}


def function_body(text, name):
    spans = functions(text).get(name, [])
    if len(spans) != 1:
        raise AssertionError('Ambiguous function: ' + name)
    a, b = spans[0]
    return text[a:b]


class ClassicProductionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not PS:
            raise unittest.SkipTest('Use --powershell to run the PowerShell builder checks.')
        # Resolve the temporary root: macOS /var is a symlink and is intentionally
        # rejected by the builder. All fixtures below are plain directories.
        cls.temp = tempfile.TemporaryDirectory(prefix='domenia-production-')
        cls.root = Path(cls.temp.name).resolve()
        cls.original = cls.root / 'snapshot'
        cls.original.mkdir()
        for relative in build_packages.runtime_paths():
            target = cls.original / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(DEV / relative, target)
        for name in ('Fabriquer-Prod.ps1', 'Production.Source.ps1', 'prod-layout.json',
                     'migration-worker.json', 'operation-contracts.json'):
            target = cls.original / 'tools' / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(TOOLS / name, target)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def setUp(self):
        self.case = self.root / self._testMethodName
        self.case.mkdir()
        self.dev = self.case / 'dev'
        shutil.copytree(self.original, self.dev)
        self.output = self.case / 'prod'

    def build(self, output=None, success=True, ps51_array_output=False):
        output = output or self.output
        before = snapshot(self.dev)
        entry = self.dev / 'tools/Fabriquer-Prod.ps1'
        if ps51_array_output:
            # Reproduce PS5.1's non-enumerated ConvertFrom-Json array on PS7 too.
            # Only the command's pipeline shape is adapted; the real builder and
            # all identity/hash/source-immutability assertions below still run.
            wrapper = self.case / 'ps51-json-array.ps1'
            target = str(entry).replace("'", "''")
            wrapper.write_text(
                "param([string]$SourceWad,[string]$OutputDirectory)\n$ErrorActionPreference='Stop'\n"
                "function ConvertFrom-Json {\n"
                " [CmdletBinding()]param([Parameter(ValueFromPipeline=$true)][string]$InputObject)\n"
                " process {$decoded=Microsoft.PowerShell.Utility\\ConvertFrom-Json -InputObject $InputObject -ErrorAction Stop; if($decoded -is [array]){return ,$decoded}else{return $decoded}}\n"
                "}\n"
                "& '" + target + "' -SourceWad $SourceWad -OutputDirectory $OutputDirectory\n",
                encoding='utf-8-sig')
            entry = wrapper
        args = [PS, '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                '-File', str(entry),
                '-SourceWad', str(self.dev / 'wad'), '-OutputDirectory', str(output)]
        run = subprocess.run(args, capture_output=True, text=True, timeout=120)
        message = run.stdout + run.stderr
        self.assertEqual(snapshot(self.dev), before, 'The source folder was modified.')
        self.assertFalse(list(self.case.glob('.domenia-build-*')), 'A partial staging folder survived.')
        if success:
            self.assertEqual(run.returncode, 0, message)
            self.assertTrue(output.is_dir(), message)
            self.assertEqual({p.name for p in output.iterdir()}, {'Domenia.exe', 'wad'})
            manifest = json.loads((output / 'wad/package-manifest.json').read_text('utf-8-sig'))
            expected = {x['Path'] for x in manifest['Files']} | {'wad/package-manifest.json'}
            self.assertEqual(set(snapshot(output)), expected)
            for item in manifest['Files']:
                raw = (output / item['Path']).read_bytes()
                self.assertEqual(sha(raw), item['Sha256'])
                self.assertEqual(len(raw), item['Bytes'])
            self.assertEqual(manifest['ReleaseStatus'], 'LocalBuildRequiresValidation')
            return manifest
        self.assertNotEqual(run.returncode, 0, 'The invalid build unexpectedly succeeded.')
        return message

    def edit(self, relative, transform):
        path = self.dev / relative
        path.write_text(transform(path.read_text('utf-8-sig')), encoding='utf-8-sig')

    def verify_worker_contracts(self):
        items = json.loads((self.dev / 'tools/operation-contracts.json').read_text('utf-8-sig'))
        core = (self.output / 'wad/Domenia-Core.ps1').read_text('utf-8-sig')
        hashes = dict(re.findall(r'(\w+)\s*=\s*"([0-9A-F]{64})"',
                                 function_body(core, 'Get-DomeniaWorkerOperationHashes')))
        # P-CD-08: the pin is the hash of the body the generator returns at run time, layer and lease of a composed
        # operation included: the reviewed mirror (composed_body) reads the prepared package, never the sources.
        spec = importlib.util.spec_from_file_location('contracts_test', TOOLS / 'update_worker_contracts.py')
        mirror = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mirror)
        mirror.ROOT = self.output
        computed = {item['Operation']: sha(mirror.composed_body(item).encode()) for item in items}
        composed = [item['Operation'] for item in items if mirror.composed_body(item) != mirror.literal_bodies(
            function_body((self.output / item['File']).read_text('utf-8-sig'), item['Function']))[item['LiteralIndex']]]
        self.assertTrue({'LocalIndexRead', 'RelationHistoryRead', 'LegacyMigration', 'LocalStore'} <= set(composed), composed)
        self.assertEqual(hashes, computed)
        fingerprint = sha('\n'.join(k + '=' + computed[k] for k in sorted(computed)).encode())
        self.assertIn('$expectedFingerprint="' + fingerprint + '"',
                      function_body(core, 'Assert-DomeniaWorkerRegistry').replace(' ', ''))

    def test_baseline_and_factory_layout_agree(self):
        manifest = self.build()
        self.assertEqual(sorted(x['Path'] for x in manifest['Files']), build_packages.runtime_paths(self.dev))
        self.verify_worker_contracts()
        # Independently generate the migration literal with the Python factory.
        spec = importlib.util.spec_from_file_location('migration_test', TOOLS / 'update_migration_worker.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        module.ROOT = self.dev
        expected = b'\xef\xbb\xbf' + module.render().encode()
        self.assertEqual((self.output / 'wad/modules/Domenia-Migration.Worker.ps1').read_bytes(), expected)

    def test_prepared_module_plan_is_byte_identical(self):
        expected = (self.dev / 'wad/Domenia-Modules.ps1').read_bytes()
        self.build()
        self.assertEqual((self.output / 'wad/Domenia-Modules.ps1').read_bytes(), expected)

    def test_export_name_with_internal_space_is_regenerated(self):
        self.edit('wad/Domenia-Modules.ps1', lambda text:
                  text.replace("'Get-DomeniaMember'", "'Get- DomeniaMember'", 1))
        self.build()
        result = (self.output / 'wad/Domenia-Modules.ps1').read_text('utf-8-sig')
        self.assertNotIn("'Get- DomeniaMember'", result)
        self.assertIn("'Get-DomeniaMember'", result)

    def test_ps51_non_enumerated_json_array_preserves_worker_contracts(self):
        self.build(ps51_array_output=True)
        self.verify_worker_contracts()

    def test_worker_contract_requires_array_root(self):
        path = self.dev / 'tools/operation-contracts.json'
        items = json.loads(path.read_text())
        path.write_text(json.dumps(items[0]))
        self.assertIn('Tableau JSON attendu', self.build(success=False))

    def test_worker_contract_rejects_nested_arrays(self):
        path = self.dev / 'tools/operation-contracts.json'
        items = json.loads(path.read_text())
        path.write_text(json.dumps([[item] for item in items]))
        self.assertIn('Objet operation JSON attendu', self.build(success=False))

    def test_worker_contract_missing_operation_still_refused(self):
        path = self.dev / 'tools/operation-contracts.json'
        items = json.loads(path.read_text())
        path.write_text(json.dumps(items[:-1]))
        self.assertIn('Operations worker differentes', self.build(success=False))

    def test_worker_contract_duplicate_operation_still_refused(self):
        path = self.dev / 'tools/operation-contracts.json'
        items = json.loads(path.read_text())
        items[-1] = items[0]
        path.write_text(json.dumps(items))
        self.assertIn('Operation inconnue ou dupliquee', self.build(success=False))

    def test_worker_contract_unknown_operation_still_refused(self):
        path = self.dev / 'tools/operation-contracts.json'
        items = json.loads(path.read_text())
        items[0]['Operation'] = 'UnregisteredOperation'
        path.write_text(json.dumps(items))
        self.assertIn('Operation inconnue ou dupliquee', self.build(success=False))

    def test_modified_worker_function_dll_and_crlf_are_rebuilt_without_execution(self):
        core = self.dev / 'wad/Domenia-Core.ps1'
        core.write_bytes(core.read_text('utf-8-sig').replace('\n', '\r\n').encode('utf-8-sig'))
        marker = self.case / 'executed.txt'
        sentinel = str(marker).replace("'", "''")
        self.edit('wad/modules/Domenia-Common.Model.ps1', lambda s:
                  s + "\nfunction Get-DomeniaBuildFixture { return 1 }\n" +
                  "[IO.File]::WriteAllText('" + sentinel + "','SHOULD NOT RUN')\n")
        items = json.loads((self.dev / 'tools/operation-contracts.json').read_text())
        item = next(x for x in items if x['Operation'] == 'EmbeddedPathBrowse')
        self.edit(item['File'], lambda s: s.replace("@'\n", "@'\n# changed build fixture\n", 1))
        native = self.dev / 'wad/modules/Domenia.Native.dll'
        native.write_bytes(native.read_bytes() + b'fixture-trailer')
        self.build()
        self.assertFalse(marker.exists(), 'Packaging executed application code.')
        modules = (self.output / 'wad/Domenia-Modules.ps1').read_text('utf-8-sig')
        self.assertIn("'Get-DomeniaBuildFixture'", modules)
        self.assertIn(sha(native.read_bytes()).lower(), modules)
        release = json.loads((self.output / 'wad/Domenia.release.json').read_text())
        component = next(x for x in release['Components'] if x['Path'] == 'wad/modules/Domenia.Native.dll')
        self.assertEqual(component['Sha256'], sha(native.read_bytes()).lower())
        self.verify_worker_contracts()

    def test_runtime_assets_are_included_but_data_and_tests_are_excluded(self):
        for relative in ('assets/icons/custom.svg', 'modules/data/private.json', 'modules/tests/broken.ps1',
                         'assets/.DS_Store', 'assets/local.sqlite', 'assets/Thumbs.db', 'assets/BACKUPS/private.txt'):
            target = self.dev / 'wad' / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text('fixture')
        manifest = self.build()
        paths = {x['Path'] for x in manifest['Files']}
        self.assertIn('wad/assets/icons/custom.svg', paths)
        self.assertFalse(any('private' in p or 'broken' in p or p.endswith('local.sqlite') for p in paths))
        self.assertEqual(sorted(paths), build_packages.runtime_paths(self.dev))

    def test_invalid_configuration_rolls_back(self):
        (self.dev / 'wad/Domenia.config.json').write_text('{broken')
        self.assertIn('JSON', self.build(success=False))
        self.assertFalse(self.output.exists())

    def test_array_configuration_is_refused(self):
        (self.dev / 'wad/Domenia.config.json').write_text('[]')
        self.assertIn('Objet JSON', self.build(success=False))
        self.assertFalse(self.output.exists())

    def test_demo_configuration_is_refused(self):
        (self.dev / 'wad/Domenia.config.json').write_text('{"Auth":{"DemoProvider":true}}')
        self.assertIn('DemoProvider', self.build(success=False))
        self.assertFalse(self.output.exists())

    def test_invalid_module_json_is_refused(self):
        (self.dev / 'wad/modules/Domenia-UX.help.json').write_text('{broken')
        self.assertIn('JSON', self.build(success=False))
        self.assertFalse(self.output.exists())

    def test_invalid_script_is_refused(self):
        self.edit('wad/modules/Domenia-Query.Model.ps1', lambda s: s + '\nfunction Broken {\n')
        self.assertIn('ligne', self.build(success=False))
        self.assertFalse(self.output.exists())

    def test_non_ascii_powershell_requires_utf8_bom(self):
        path = self.dev / 'wad/modules/Domenia-Query.Worker.ps1'
        path.write_bytes(path.read_text('utf-8-sig').encode('utf-8'))
        self.assertIn('BOM', self.build(success=False))
        self.assertFalse(self.output.exists())
        with self.assertRaisesRegex(ValueError, 'BOM'):
            build_packages.runtime_paths(self.dev)

    def test_missing_runtime_component_is_refused(self):
        (self.dev / 'wad/modules/Domenia.Native.dll').unlink()
        self.assertIn('absent', self.build(success=False))
        self.assertFalse(self.output.exists())

    def test_undeclared_module_is_refused(self):
        (self.dev / 'wad/modules/Domenia-Unregistered.ps1').write_text('function Get-DomeniaUnregistered { return 1 }')
        self.assertIn('Module non declare', self.build(success=False))
        self.assertFalse(self.output.exists())

    def test_duplicate_function_is_refused(self):
        self.edit('wad/modules/Domenia-Query.Model.ps1', lambda s: s + '\nfunction Get-DomeniaMember { return 1 }\n')
        self.assertIn('duplique', self.build(success=False))
        self.assertFalse(self.output.exists())

    def test_signed_source_is_refused_before_rewriting(self):
        self.edit('wad/modules/Domenia-Query.Model.ps1', lambda s: s + '\n# SIG # Begin signature block\n')
        self.assertIn('Source signee', self.build(success=False))
        self.assertFalse(self.output.exists())

    def test_unknown_migration_dependency_is_refused(self):
        self.edit('wad/modules/Domenia-Common.Model.ps1', lambda s:
                  s.replace('function Get-DomeniaMember {', 'function Get-DomeniaMember {\nGet-DomeniaMissingFixture'))
        self.assertIn('migration absente', self.build(success=False))
        self.assertFalse(self.output.exists())

    def test_output_existing_is_preserved(self):
        self.output.mkdir()
        (self.output / 'keep.txt').write_text('keep')
        before = snapshot(self.output)
        self.assertIn('existe deja', self.build(success=False))
        self.assertEqual(snapshot(self.output), before)

    def test_output_inside_sources_is_refused(self):
        output = self.dev / 'wad' / 'prod'
        self.assertIn('hors du dossier', self.build(output=output, success=False))
        self.assertFalse(output.exists())

    def test_case_collision_in_layout_is_refused(self):
        path = self.dev / 'tools/prod-layout.json'
        layout = json.loads(path.read_text())
        layout['RequiredFiles'].append(layout['RequiredFiles'][0].upper())
        path.write_text(json.dumps(layout))
        self.assertIn('duplique', self.build(success=False))
        with self.assertRaises(ValueError):
            build_packages.runtime_paths(self.dev)
        self.assertFalse(self.output.exists())

    def test_windows_reserved_asset_name_is_refused(self):
        if os.name == 'nt':
            self.skipTest('Windows itself forbids creating the malformed source file.')
        path = self.dev / 'wad/assets'
        path.mkdir(exist_ok=True)
        (path / 'AUX.txt').write_text('fixture')
        self.assertIn('Windows invalide', self.build(success=False))
        with self.assertRaises(ValueError):
            build_packages.runtime_paths(self.dev)

    def test_symlink_asset_is_refused_before_traversal(self):
        assets = self.dev / 'wad/assets'
        assets.mkdir(exist_ok=True)
        target = self.case / 'outside'
        target.mkdir()
        (target / 'private.txt').write_text('never package')
        try:
            (assets / 'redirect').symlink_to(target, target_is_directory=True)
        except OSError as error:
            self.skipTest('Symlink creation unavailable: ' + str(error))
        self.assertIn('redirige', self.build(success=False))
        with self.assertRaises(ValueError):
            build_packages.runtime_paths(self.dev)
        self.assertFalse(self.output.exists())

    def test_symlink_output_parent_is_refused_before_mkdir(self):
        target = self.case / 'outside'
        target.mkdir()
        link = self.case / 'redirect'
        try:
            link.symlink_to(target, target_is_directory=True)
        except OSError as error:
            self.skipTest('Symlink creation unavailable: ' + str(error))
        self.assertIn('redirige', self.build(output=link / 'new' / 'prod', success=False))
        self.assertFalse((target / 'new').exists())


class FactoryConfigurationTests(unittest.TestCase):
    def test_bad_config_and_demo_variants_are_refused(self):
        for raw in (b'[]', b'null', b'{bad', b'{"Auth":{"DemoProvider":1}}',
                    b'{"Auth":{"DemoProvider":"oui"}}'):
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                build_packages.assert_config_not_demo(raw)
        build_packages.assert_config_not_demo(b'{"Auth":{"DemoProvider":false}}')

    def test_dev_symlink_file_is_not_packaged(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            dev = root / 'dev'
            dev.mkdir()
            (root / 'outside.txt').write_text('private')
            try:
                (dev / 'linked.txt').symlink_to(root / 'outside.txt')
            except OSError as error:
                self.skipTest('Symlink creation unavailable: ' + str(error))
            with self.assertRaises(ValueError):
                build_packages.select_members(dev)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--powershell', required=True)
    args, remaining = parser.parse_known_args()
    PS = str(Path(args.powershell).resolve()) if Path(args.powershell).exists() else args.powershell
    unittest.main(argv=[sys.argv[0], *remaining], verbosity=2)
