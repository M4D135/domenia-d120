#!/usr/bin/env python3
"""Offline, standard-library audit. No AD calls; no application startup.
Windows PowerShell/WPF tests are separate: Test-Domenia.ps1.
SQL tests execute the actual query template against synthetic SQLite records.
"""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import re
import sqlite3
import tempfile
import time
import traceback
import xml.etree.ElementTree as ET
from powershell_lex import mask_ps, functions
from functools import lru_cache

@lru_cache(maxsize=8)
def function_map(text):
    return functions(text)

def function_text(text, name):
    entries = function_map(text).get(name, [])
    if len(entries) != 1:
        raise ValueError(f"Unique function expected: {name}")
    start, end = entries[0]
    return text[start:end]


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest().upper()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument('--report', type=Path, default=Path(tempfile.gettempdir())/'domenia-audit.json')
    args = parser.parse_args()
    root = args.root.resolve()
    source = (root/'wad/Domenia-Core.ps1').read_text(encoding='utf-8-sig')
    fs = functions(source)
    baseline = json.loads((root/'wad/tests/baseline.json').read_text(encoding='utf-8'))
    results = []
    observations = {}

    def check(name, kind, fn):
        start = time.perf_counter()
        try:
            fn()
            result = {'Name': name, 'Kind': kind, 'Status': 'PASS', 'Detail': ''}
        except Exception as exc:
            result = {'Name': name, 'Kind': kind, 'Status': 'FAIL', 'Detail': f'{type(exc).__name__}: {exc}'}
        result['Milliseconds'] = round((time.perf_counter()-start)*1000, 2)
        results.append(result)
        print(f"{result['Status']:4} {name}", result['Detail'])

    def require(value, message='Assertion failed'):
        if not value:
            raise AssertionError(message)

    def delimiters(text):
        masked, issues = mask_ps(text)
        require(not issues, str(issues))
        stack = []
        pairs = {')': '(', ']': '[', '}': '{'}
        for index, char in enumerate(masked):
            if char in '([{':
                stack.append((char, index))
            elif char in ')]}':
                require(stack and stack[-1][0] == pairs[char], f'Delimiter {char} at line {text.count(chr(10), 0, index)+1}')
                stack.pop()
        require(not stack, f'{len(stack)} unclosed delimiters')

    for path in sorted(root.rglob('*.ps1')):
        if 'data' in path.relative_to(root).parts or 'backups' in path.relative_to(root).parts:
            continue
        check(f'Lexique et delimitateurs : {path.relative_to(root)}', 'StaticLexical',
              lambda path=path: delimiters(path.read_text(encoding='utf-8-sig')))
    check('539 fonctions originales conservees', 'StaticStructure', lambda: require(set(baseline['OriginalFunctions']).issubset(fs)))
    check('Pas de definition principale en double', 'StaticStructure', lambda: require(all(len(spans) == 1 for spans in fs.values())))
    observations['MainFunctionCount'] = len(fs)
    observations['OriginalFunctionCount'] = len(baseline['OriginalFunctions'])
    for name in ['Get-MainXaml', 'Get-DomeniaStandardLoginXaml', 'Get-DomeniaStartupXaml']:
        def validate_xml(name=name):
            if name == 'Get-MainXaml':
                element = ET.parse(root/'wad/Domenia-Main.xaml').getroot()
            else:
                matches = list(re.finditer(r'@([\'\"])\n(.*?)^\1@', function_text(source, name), re.S | re.M))
                require(matches, f'No literal XML for {name}')
                element = ET.fromstring(matches[0][2].strip())
            names = [item.attrib['{http://schemas.microsoft.com/winfx/2006/xaml}Name'] for item in element.iter() if '{http://schemas.microsoft.com/winfx/2006/xaml}Name' in item.attrib]
            # R1.7: standard PART_* names may recur in distinct WPF template namescopes.
            def scoped_names(node, scope='window', seen=None):
                if seen is None: seen = set()
                if node.tag.rsplit('}', 1)[-1] in ('ControlTemplate','DataTemplate','ItemsPanelTemplate'):
                    scope = id(node)
                value = node.attrib.get('{http://schemas.microsoft.com/winfx/2006/xaml}Name')
                if value:
                    require((scope, value) not in seen, 'Duplicate x:Name in same scope: '+value)
                    seen.add((scope, value))
                for child in node: scoped_names(child, scope, seen)
            scoped_names(element)
            observations[name+'Controls'] = len(names)
            if name == 'Get-MainXaml':
                require(set(baseline['OriginalMainControls']).issubset(names), 'Existing control removed')
                require({'ChkUiLogFollow','BtnRuntimeHealth','BtnCopyUiLog'}.issubset(names))
        check('XML bien forme et noms uniques : '+name, 'XmlParser', validate_xml)

    registry = dict(re.findall(r'(\w+)\s*=\s*"([A-F0-9]{64})"', function_text(source, 'Get-DomeniaWorkerOperationHashes')))
    literals = {}
    for match in re.finditer(r"@'\n(.*?)^'@", source, re.S | re.M):
        body = match[1][:-1]  # exactly one here-string boundary newline, NOT strip()
        literals.setdefault(sha(body.encode('utf-8')), []).append(body)
    def validate_workers():
        require(len(registry) == 45)
        for operation, digest in registry.items():
            require(digest in literals, 'Missing pinned body: '+operation)
            body = literals[digest][0]
            delimiters(body)
            require(sha((body+'\n# altered').encode()) != digest, 'Tampering not detected')
        observations['PinnedWorkersMatched'] = len(registry)
    check('45 empreintes workers exactes, corps equilibres et modification detectee', 'StaticIntegrity', validate_workers)
    common = re.search(r"(?ms)^\$script:WorkerCommon = @'\n(.*?)\n'@", source)[1]
    check('Lexique du code commun execute dans les workers', 'StaticLexical', lambda: delimiters(common))
    for relative, digest in baseline['OriginalBinaries'].items():
        check('Binaire original inchange : '+relative, 'Sha256', lambda relative=relative, digest=digest: require(sha((root/relative).read_bytes()) == digest))

    def inspect_guards():
        start = function_text(source, 'Start-UiTask')
        require('MaxOutstandingWorkers' in start and '@($script:DetachedReadJobs).Count' in start)
        require('SessionEpoch=' in start)
        reap = function_text(source, 'Complete-DomeniaDetachedReadJobs')
        require(reap.index('if (-not $invokeDone -or -not $stopDone) { continue }') < reap.index('.EndInvoke('))
        complete = function_text(source, 'Complete-UiTasks')
        require('-or ($null -ne $job.StopHandle -and -not $stopCompleted)' in complete)
        require('$job.SessionEpoch -ne [long]$script:SessionEpoch' in complete)
        require('WaitForExit()' not in function_text(common, 'Invoke-WQuietProcess'))
    check('Gardes statiques : concurrence, generation et arret non bloquant', 'StaticGuards', inspect_guards)
    def inspect_secrets():
        grid = function_text(source, 'Update-SecretsGrid')
        require("else { '********' }" in grid)
        bound = re.search(r'\$rows.Add\(\[pscustomobject\]@\{(.*?)\}\)', grid, re.S)[1]
        require(not re.search(r'(?<!\w)Value\s*=', bound), 'Raw secret still bound')
        clear = function_text(source, 'Clear-Secrets')
        require("$script:ActiveSecretRequestId = ''" in clear and "$row.Value = ''" in clear)
        require('FromSeconds(60)' in function_text(source, 'Toggle-SecretsVisibility'))
        require('SecretMemorySeconds' in function_text(source, 'Restart-DomeniaSecretLifetime'))
    check('Gardes statiques : secret masque, index opaque, expiration et invalidation', 'StaticGuards', inspect_secrets)
    def inspect_persistence():
        atomic = function_text(source, 'Write-DomeniaAtomicText')
        require('.Flush($true)' in atomic and '[IO.File]::Replace(' in atomic)
        require('[IO.File]::Delete($full)' not in atomic)
        backup = function_text(source, 'Backup-DomeniaDatabase')
        for needle in ('sqlite3_backup_init', 'sqlite3_backup_step', 'sqlite3_backup_finish', 'PRAGMA quick_check', 'BackupTimeoutSeconds'):
            require(needle in backup, needle)
        recovery = function_text(source, 'Recover-DomeniaDatabase')
        require('throw' in recovery and 'Move-Item' not in recovery and 'Copy-Item' not in recovery)
        relog = function_text(source, 'Start-DomeniaAccountRelogin')
        require(relog.index('Flush-DomeniaIndex') < relog.index('Show-LoginWindow'))
    check('Gardes statiques : sauvegarde coherente, ecriture atomique, pas de restauration implicite', 'StaticGuards', inspect_persistence)
    def inspect_exports():
        for name in fs:
            text = function_text(source, name)
            require(not re.search(r'(?<!ConvertTo-DomeniaSpreadsheetSafeRow) \| Export-Csv', text), 'Raw CSV export in '+name)
        diag = function_text(source, 'Export-SelfCheckReport')
        require('Copy-Item -LiteralPath $script:AuditPath' not in diag)
        require('Copy-Item -LiteralPath $script:StartupTracePath' not in diag)
        require('[IO.File]::Replace($zipTemp' in diag)
    check('Gardes statiques : exports CSV filtres et journaux bruts exclus', 'StaticGuards', inspect_exports)

    # Execute the actual SQL source template, not a re-designed equivalent query.
    search = function_text(source, 'Search-DomeniaDatabaseRows')
    template = re.search(r'\$sql = @"\n(.*?)\n"@', search, re.S)[1]
    connection = sqlite3.connect(':memory:')
    columns = ['object_type','name','login','upn','display_name','description','extra','state','distinguished_name','when_changed','usn_changed','last_logon','object_guid','search_key']
    connection.execute('CREATE TABLE ad_objects ('+','.join(c+' '+('INTEGER' if c == 'usn_changed' else 'TEXT') for c in columns)+')')
    samples = [('sam','sam@a.test'),('sam','sam@b.test'),('pc_01','pc_01@a.test'),('pcX01','pcX01@a.test'),('pc%02','pc%02@a.test'),("O'Neil","o'neil@a.test"),('PC!03','PC!03@a.test'),('été','été@a.test')]
    for i, (name, upn) in enumerate(samples):
        connection.execute('INSERT INTO ad_objects VALUES ('+','.join(['?']*len(columns))+')', ('User',name,name,upn,name,'','','OK',upn,'',0,'',str(i),f'{name} {upn}'.lower()))
    connection.commit()
    def literal(text): return "'"+text.replace("'", "''")+"'"
    def escape_like(text): return text.replace('!', '!!').replace('%', '!%').replace('_', '!_')
    def query(text, limit=50):
        clean = text.strip().split('\\')[-1].strip().rstrip('$')
        if len(clean) < 2: return []
        sql = template
        replacements = {'$termSql': literal(clean), '$prefixSql': literal(escape_like(clean)+'%'), '$containsSql': literal('%'+escape_like(clean.lower())+'%'), '$Limit': str(max(1,min(500,limit)))}
        for key,value in replacements.items(): sql = sql.replace(key,value)
        return list(connection.execute(sql))
    for term, expected in [('sam@a.test',1),('sam@b.test',1),('pc_01',1),('pc%02',1),("O'Neil",1),('pc!03',1),('été',1),("zz' OR 1=1 --",0),('DOM\\sam',2),('sam',2),('x',0)]:
        check('SQL reel sur donnees synthetiques : '+repr(term), 'SqliteActualQuery', lambda term=term,expected=expected: require(len(query(term)) == expected))
    check('SQL reel : limite et score exact prioritaire', 'SqliteActualQuery', lambda: require(len(query('sam',1)) == 1 and query('sam')[0][-1] == 100))
    connection.close()

    def wal_snapshot():
        with tempfile.TemporaryDirectory(prefix='domenia-wal-') as directory:
            path = Path(directory)
            src = sqlite3.connect(path/'source.db')
            dst = sqlite3.connect(path/'copy.db')
            try:
                require(src.execute('PRAGMA journal_mode=WAL').fetchone()[0] == 'wal')
                src.execute('CREATE TABLE sample (id INTEGER PRIMARY KEY, value TEXT)')
                src.executemany('INSERT INTO sample(value) VALUES (?)', [(str(i),) for i in range(4096)])
                src.commit()
                require((path/'source.db-wal').stat().st_size > 0, 'Test must have committed WAL pages')
                src.backup(dst,pages=256)
                require(dst.execute('PRAGMA quick_check').fetchone()[0] == 'ok')
                require(dst.execute('SELECT count(*) FROM sample').fetchone()[0] == 4096)
                src.execute("INSERT INTO sample(value) VALUES ('later')"); src.commit()
                require(dst.execute('SELECT count(*) FROM sample').fetchone()[0] == 4096)
                require(src.execute('SELECT count(*) FROM sample').fetchone()[0] == 4097)
            finally: dst.close();src.close()
    check('API SQLite via Python : instantane incluant WAL, copie independante', 'SqliteBackupApiNotPowerShell', wal_snapshot)
    def busy_deadline():
        with tempfile.TemporaryDirectory(prefix='domenia-busy-') as directory:
            path=Path(directory)
            writer=sqlite3.connect(path/'locked.db',timeout=0.01)
            reader=sqlite3.connect(path/'locked.db',timeout=0.01)
            target=sqlite3.connect(path/'copy.db')
            try:
                writer.execute('CREATE TABLE sample (value TEXT)');writer.commit();writer.execute('BEGIN EXCLUSIVE')
                start=time.monotonic();statuses=[]
                def progress(status,remaining,total):
                    statuses.append(status)
                    if time.monotonic()-start > 0.15:raise TimeoutError('expected busy deadline')
                try:reader.backup(target,pages=256,progress=progress,sleep=0.01)
                except TimeoutError:pass
                else:raise AssertionError('Busy deadline was not reached')
                require(5 in statuses or 6 in statuses, str(statuses))
                require(time.monotonic()-start < 2)
                writer.rollback();require(writer.execute('PRAGMA quick_check').fetchone()[0]=='ok')
            finally:target.close();reader.close();writer.close()
    check('API SQLite via Python : verrouillage BUSY et interruption bornee', 'SqliteBackupApiNotPowerShell', busy_deadline)
    def clean_package():
        forbidden=[]
        for path in root.rglob('*'):
            relative=path.relative_to(root).as_posix()
            if path.is_file() and (path.suffix.lower() in {'.db','.log'} or relative.startswith('wad/data/')):forbidden.append(relative)
        require(not forbidden, 'Private data included: '+str(forbidden))
        require(not (root/'mod').exists(), 'Legacy mod layout')
        json.loads((root/'wad/Domenia.config.json').read_text(encoding='utf-8-sig'))
    check('Paquet neuf : aucun cache, identifiant enregistre ou journal personnel', 'PackagePrivacy', clean_package)
    manifest_path=root/'wad/package-manifest.json'
    if manifest_path.exists():
        def validate_manifest():
            manifest=json.loads(manifest_path.read_text(encoding='utf-8'))
            for entry in manifest['Files']:
                path=(root/entry['Path']).resolve()
                require(root in path.parents,'Manifest path outside package')
                require(sha(path.read_bytes())==entry['Sha256'],entry['Path'])
            observations['ManifestFileCount']=len(manifest['Files'])
        check('Manifeste SHA-256 du paquet final', 'Sha256', validate_manifest)
    report={'Environment':'Linux / Python '+__import__('platform').python_version()+' / SQLite '+sqlite3.sqlite_version,
            'NativePowerShellExecuted':False,'WpfExecuted':False,'ActiveDirectoryExecuted':False,
            'Passed':sum(item['Status']=='PASS' for item in results),'Failed':sum(item['Status']=='FAIL' for item in results),
            'Observations':observations,'Results':results}
    args.report.parent.mkdir(parents=True,exist_ok=True)
    args.report.write_text(json.dumps(report,indent=2,ensure_ascii=False),encoding='utf-8')
    print(json.dumps({key:report[key] for key in ('Passed','Failed','NativePowerShellExecuted','WpfExecuted','ActiveDirectoryExecuted')},ensure_ascii=False))
    return 1 if report['Failed'] else 0

if __name__=='__main__':
    raise SystemExit(main())
