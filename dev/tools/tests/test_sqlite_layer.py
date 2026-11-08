"""P-CD-08: one SQLite access layer for every worker of the local base (tools/check_sqlite_layer.py).

Offline: reads copies of the sources in a temporary folder, never runs PowerShell.
Usage: python3 -m unittest discover -s tools/tests -q   (from dev/)
"""
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

DEV = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(DEV / 'tools'))
sys.path.insert(0, str(DEV / 'wad/tests'))
import check_sqlite_layer as layer  # noqa: E402
import update_worker_contracts as contracts  # noqa: E402


class SqliteLayerTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='domenia-sqlite-layer-')
        self.root = Path(self.temp.name)
        (self.root / 'wad/modules').mkdir(parents=True)
        (self.root / 'tools').mkdir()
        shutil.copyfile(DEV / 'wad/Domenia-Core.ps1', self.root / 'wad/Domenia-Core.ps1')
        for path in (DEV / 'wad/modules').glob('*.ps1'):
            shutil.copyfile(path, self.root / 'wad/modules' / path.name)
        shutil.copyfile(DEV / 'wad/modules/Domenia-ProbeCatalog.json', self.root / 'wad/modules/Domenia-ProbeCatalog.json')
        shutil.copyfile(DEV / 'tools/operation-contracts.json', self.root / 'tools/operation-contracts.json')
        shutil.copyfile(DEV / 'tools/Production.Source.ps1', self.root / 'tools/Production.Source.ps1')
        self.saved = (layer.ROOT, contracts.ROOT)
        layer.ROOT = contracts.ROOT = self.root

    def tearDown(self):
        layer.ROOT, contracts.ROOT = self.saved
        self.temp.cleanup()

    def edit(self, relative, old, new):
        path = self.root / relative
        text = path.read_text(encoding='utf-8-sig')
        self.assertEqual(1, text.count(old), old)
        path.write_bytes(b'\xef\xbb\xbf' + text.replace(old, new, 1).encode('utf-8'))

    def problems(self):
        return '\n'.join(layer.check())

    def test_repository_holds_one_composed_layer(self):
        self.assertEqual('', self.problems())

    def test_a_copy_in_a_worker_body_is_refused(self):
        copy = "function New-DomeniaUtf8Ptr {\n    param([string]$Text)\n    return [IntPtr]::Zero\n}\n"
        self.edit('wad/modules/Domenia-AdAudit.Worker.ps1', "$literal=ConvertTo-DomeniaSqlLiteral $key\n", copy + "$literal=ConvertTo-DomeniaSqlLiteral $key\n")
        self.assertIn('Domenia-AdAudit.Worker.ps1', self.problems())
        self.assertIn('copie de New-DomeniaUtf8Ptr', self.problems())

    def test_a_private_native_open_is_refused(self):
        self.edit('wad/modules/Domenia-AdAudit.Worker.ps1', "    $db=Open-DomeniaDatabase -Path $path -ReadOnly -BusyTimeoutMs $busyMs\n",
                  "    $rc=[Domenia.WinSqliteNative]::sqlite3_open_v2($ptr,[ref]$db,1,[IntPtr]::Zero)\n")
        self.assertIn('appel natif sqlite3_open_v2', self.problems())

    def test_a_worker_that_stops_composing_the_layer_is_refused(self):
        self.edit('wad/modules/Domenia-Engine.Worker.ps1', '    return (Get-DomeniaSqliteWorkerCommon)+[Environment]::NewLine+@\'\n', "    return @'\n")
        # The contract mirror still composes the layer: the generator no longer matches what the hash pins.
        self.assertIn('LocalIndexRead : Get-DomeniaLocalIndexReadWorkerCode ne compose pas', self.problems())

    def test_a_worker_that_calls_the_layer_without_composing_it_is_refused(self):
        self.edit('wad/modules/Domenia-Secrets.Worker.ps1', "return @'\n$entries = New-Object Collections.ArrayList\n",
                  "return @'\n# Invoke-DomeniaDbQuery in a comment is not a call.\n$entries = New-Object Collections.ArrayList\n")
        self.assertEqual('', self.problems())
        self.edit('wad/modules/Domenia-Secrets.Worker.ps1', "$entries = New-Object Collections.ArrayList\n",
                  "$cached=@(Invoke-DomeniaDbQuery 'SELECT 1;' $db)\n$entries = New-Object Collections.ArrayList\n")
        self.assertIn('ReadBitLockerList : utilise la couche SQLite sans etre declaree', self.problems())

    def test_core_and_layer_keep_the_same_literal_rule(self):
        self.edit('wad/Domenia-Core.ps1', '    if ($null -eq $Value) { return "NULL" }\n', '    if ($null -eq $Value) { return "null" }\n')
        self.assertIn('divergent pour ConvertTo-DomeniaSqlLiteral', self.problems())

    def test_schema_literal_in_a_worker_is_refused(self):
        self.edit('wad/modules/Domenia-Storage.Worker.ps1', "    if(-not (Test-DomeniaSqliteSchemaRows $schema)){throw 'Schema de retention incompatible.'}\n",
                  "    if(@($schema|Where-Object{$_.value -ceq '11'}).Count -ne 1){throw 'Schema de retention incompatible.'}\n")
        self.assertIn('version de schema comparee a un litteral', self.problems())

    def test_revision_literal_in_a_worker_is_refused(self):
        self.edit('wad/modules/Domenia-Storage.Worker.ps1', "    if(-not (Test-DomeniaSqliteSchemaRows $schema)){throw 'Schema de retention incompatible.'}\n",
                  "    $revision=[string]@($schema|Where-Object{$_.key -ceq 'domenia_schema'})[0].value\n"
                  "    if($revision -ne '1'){throw 'Schema de retention incompatible.'}\n")
        self.assertIn('revision domenia_schema comparee a un litteral', self.problems())

    def test_reviewed_revision_rules_follow_the_layer(self):
        self.edit('wad/modules/Domenia-Release.Model.ps1', "elseif ($revision -and ($revision -cne '1')) {", "elseif ($revision -and ($revision -cne '2')) {")
        self.assertIn('Get-DomeniaMigrationPlan (wad/modules/Domenia-Release.Model.ps1) : revision domenia_schema 2 differente', self.problems())
        self.edit('wad/modules/Domenia-Migration.Worker.ps1', "    if ($revision -ne '1') {", "    if ($revision -ne '3') {")
        self.assertIn('revision domenia_schema 3 differente de la couche partagee', self.problems())

    def test_prod_builder_composes_like_the_contract_mirror(self):
        self.edit('tools/Production.Source.ps1', "$sqliteReadOnly=@('LocalIndexRead','RelationHistoryRead')", "$sqliteReadOnly=@('LocalIndexRead')")
        self.assertIn('$sqliteReadOnly differente de tools/update_worker_contracts.py', self.problems())
        self.edit('tools/Production.Source.ps1', '$hash=Get-DomeniaBuildHash (Get-DomeniaBuildWorkerBody $WadRoot $item $cache)',
                  '$hash=Get-DomeniaBuildHash (Get-DomeniaBuildLiteral (Get-DomeniaBuildFunction $ast $item.Function) 0 $op)')
        self.assertIn('epingle un litteral seul', self.problems())

    def test_prod_builder_keeps_the_storage_markers(self):
        self.edit('tools/Production.Source.ps1', "'$path=Test-DomeniaStorageMeasurePath ([string]$Payload.Path)'", "'$path=Test-DomeniaStorageMeasurePath'")
        self.assertIn('differente de THROUGH_STORAGE', self.problems())

    def test_schema_target_follows_the_core_schema_script(self):
        self.edit('wad/Domenia-Core.ps1', "VALUES('schema_version','11');", "VALUES('schema_version','12');")
        self.assertIn('Script de schema du coeur', self.problems())


if __name__ == '__main__':
    unittest.main()
