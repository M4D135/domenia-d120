#!/usr/bin/env python3
"""Portable source/XML/SQLite/PE verification. NOT a PowerShell or Windows execution."""
from pathlib import Path
import argparse,sys,re,json,hashlib,sqlite3,tempfile,struct,xml.etree.ElementTree as ET,collections,functools
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'wad/tests'))
from powershell_lex import functions as _functions,mask_ps
functions=functools.lru_cache(maxsize=128)(_functions)
def getfunc(s,name):
    pos=functions(s).get(name,[])
    if len(pos)!=1:raise ValueError((name,'count',len(pos)))
    a,b=pos[0];return s[a:b]
BUILD='2026.10.01-DOMENIA-1.0-RC1.9-INTEGRATED'

def load(p):return p.read_text('utf-8-sig')
def sha(t):return hashlib.sha256(t.encode() if isinstance(t,str) else t).hexdigest().upper()
def literals(t):return [m[2] for m in re.finditer(r'@([\'\"])\n(.*?)\n^\1@',t,re.S|re.M)]
def balanced(source):
    source=source.translate(str.maketrans({'\u2018':"'",'\u2019':"'",'\u201c':'"','\u201d':'"'}))
    s,errors=mask_ps(source);assert not errors,errors
    pairs={')':'(',']':'[','}':'{'};stack=[]
    for c in s:
        if c in '([{':stack.append(c)
        elif c in pairs:assert stack and stack.pop()==pairs[c],'mismatched delimiter'
    assert not stack,'unclosed delimiter'

def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--report',type=Path,required=True);a=ap.parse_args()
    checks=[]
    def ck(name,call,group='source'):
        try:
            v=call() if callable(call) else call
            assert v is None or bool(v),name
            checks.append(dict(Name=name,Passed=True,Group=group))
        except Exception as e:checks.append(dict(Name=name,Passed=False,Group=group,Error=str(e)));print('FAIL',name,str(e))
    core=load(ROOT/'wad/Domenia-Core.ps1');cf=lambda n:getfunc(core,n)
    paths=[ROOT/'wad/Domenia-Core.ps1',ROOT/'wad/Domenia-Start.ps1',ROOT/'wad/Domenia-Modules.ps1',ROOT/'INSTALLER-MISE-A-JOUR.ps1']+sorted((ROOT/'wad/modules').glob('*.ps1'))
    for p in paths:
        ck('Lexical balance (not native parser): '+p.name,lambda p=p:balanced(load(p)),'lexical')
    catalog=json.loads(load(ROOT/'wad/modules/Domenia-UX.help.json'))
    xml=literals(cf('Get-MainXaml'))[0];tree=ET.fromstring(xml)
    X='{http://schemas.microsoft.com/winfx/2006/xaml}';W='{http://schemas.microsoft.com/winfx/2006/xaml/presentation}'
    names={e.get(X+'Name'):e for e in tree.iter() if e.get(X+'Name')}
    keys={e.get(X+'Key') for e in tree.iter() if e.get(X+'Key')}
    ck('Main XAML is XML',tree.tag==W+'Window','XML')
    ck('Static resources all declared',not(set(re.findall(r'\{StaticResource ([\w]+)\}',xml))-keys),'XML')
    for n in ['BtnLoadLaps','BtnLoadBitLocker','TvDirectory','DgObjects','DgSessions','DgGuardReceipts','BtnAccessRecovery','BtnUxSidebarToggle','BtnUxHelpToggle','ChkSubtree']:
        ck('Control retained: '+n,n in names,'XML')
    for p in (ROOT/'wad/modules').glob('*.xaml'):ck('Module XML: '+p.name,lambda p=p:ET.parse(p) is not None,'XML')
    for p in paths:
        for idx,lit in enumerate(literals(load(p))):
            if lit.lstrip().startswith('<Window '):ck('Window XML: '+p.name+' #'+str(idx),lambda lit=lit:ET.fromstring(lit) is not None,'XML')
    missing=[]
    interactive={'Button','TextBox','PasswordBox','ComboBox','CheckBox','DataGrid','ListBox','TreeView','TabItem','GridSplitter'}
    for n,e in names.items():
        if e.tag.split('}')[-1] in interactive and (not e.get('ToolTip') or not e.get('AutomationProperties.HelpText')):missing.append(n)
    ck('Interactive main elements have static help',not missing,'XML')
    ck('New help catalog entries exist',{'BtnGuardWhy','BtnSessionsRead','BtnGuardExport'}<={x['Name'] for x in catalog},'XML')
    opmeta=json.loads(load(ROOT/'tools/operation-contracts.json'))
    reg=dict(re.findall(r'(\w+)\s*=\s*"([A-F0-9]{64})"',cf('Get-DomeniaWorkerOperationHashes')))
    ck('57 closed operations with exact contracts',len(reg)==57 and len(opmeta)==57,'integrity')
    fingerprint=sha('\n'.join(k+'='+reg[k] for k in sorted(reg)))
    expected_pin=re.search(r'\$expectedFingerprint\s*=\s*"([A-F0-9]{64})"',cf('Assert-DomeniaWorkerRegistry'))[1]
    ck('Whole registry pin matches reviewed names and hashes',fingerprint==expected_pin,'integrity')
    ck('Actual initialization uses registry validation, not stale count','Assert-DomeniaWorkerRegistry' in cf('Initialize-AsyncEngine') and not re.search(r'\.Count\s*-\w+\s*\d+',cf('Initialize-AsyncEngine')),'integrity')
    for e in opmeta:
        source=load(ROOT/e['File']);body=literals(getfunc(source,e['Function']))[e['LiteralIndex']]
        ck('Pinned operation: '+e['Operation'],sha(body)==reg[e['Operation']]==e['Sha256'],'integrity')
        ck('Worker lexical balance: '+e['Operation'],lambda body=body:balanced(body),'lexical')
    common="\n".join(re.findall(r"(?ms)^\$script:WorkerCommon (?:=|\+=) @'\n(.*?)\n'@",core))
    wf=lambda n: getfunc(common,n) if n in functions(common) else cf(n)
    ck('Common worker lexical balance',lambda:balanced(common),'lexical')
    ck('No duplicate core functions',all(len(v)==1 for v in functions(core).values()))
    all_names={}
    for p in [ROOT/'wad/Domenia-Core.ps1']+list((ROOT/'wad/modules').glob('*.ps1')):
        for fn in functions(load(p)):all_names.setdefault(fn,[]).append(p.name)
    duplicates={k:v for k,v in all_names.items() if len(v)>1}
    ck('No overriding duplicate module functions',not duplicates)
    account=load(ROOT/'wad/modules/Domenia-Accounts.Async.ps1');storage=load(ROOT/'wad/modules/Domenia-Storage.Worker.ps1');storeui=load(ROOT/'wad/modules/Domenia-Storage.UI.ps1');guard=load(ROOT/'wad/modules/Domenia-Guard.UI.ps1')
    access=load(ROOT/'wad/modules/Domenia-Access.UI.ps1');start=load(ROOT/'wad/Domenia-Start.ps1');installer=load(ROOT/'INSTALLER-MISE-A-JOUR.ps1')
    ck('Account validation no Dispatcher WaitOne',all(x not in account for x in ['WaitOne(', 'Start-Sleep', '.Wait()']))
    ck('Old credential call delegates to async', 'Start-DomeniaAccountValidation' in cf('Test-DomeniaCredentialBind'))
    ck('Index render queues persistence', 'Add-DomeniaIndexPersistence' in cf('Sync-DomeniaIndexEntry') and 'Upsert-DomeniaIndexEntryRow' not in cf('Sync-DomeniaIndexEntry'))
    ck('Link save is a delta queue','Queue-DomeniaLinkChanges' in cf('Save-UserMachineLinks') and 'DELETE FROM' not in cf('Save-UserMachineLinks'))
    ck('Targeted link compare-and-swap','if($actual -cne [string]$i.Expected)' in storage and 'WHERE computer_key=$key' in storage)
    ck('Storage transaction and rollback','BEGIN IMMEDIATE;' in storage and 'ROLLBACK;' in storage and 'COMMIT;' in storage)
    ck('PsExec never emits secret argument',"'-p'" not in wf('Invoke-WRemotePsExecScript'))
    ck('Task API replaces schtasks CLI','Schedule.Service' in wf('Invoke-WSchtasksRemote') and 'Invoke-WQuietProcess' not in wf('Invoke-WSchtasksRemote'))
    ck('Only own task mutations','Assert-WRemoteArtifactPermission' in wf('Invoke-WSchtasksRemote') and 'DOMENIA_(Remote|Rimotte)' in wf('Invoke-WSchtasksRemote'))
    ck('Private staging ACL and native Windows path','Get-WRemoteWindowsDirectory' in wf('Invoke-WRemoteScheduledTaskScript') and 'Set-Acl' in wf('Invoke-WRemoteScheduledTaskScript'))
    ck('Legacy lockoutTime not sufficient','Computed' in cf('Get-UacStatusLabel') and 'Computed' in wf('Get-WUacState'))
    ck('Direct membership query is server-side','(member=' in wf('Test-WDirectMembership') and 'Escape-WLdap' in wf('Test-WDirectMembership'))
    ck('Member ranges parsed','member;range' in wf('Get-WAllProperties') or ';range=' in wf('Get-WAllProperties'))
    ck('Case-only changes preserved','[StringComparison]::Ordinal' in cf('New-DomeniaAttributeChange'))
    ck('Incoming result cannot wipe dirty form','Keep-DomeniaDraftOnResult' in cf('Show-AdObjectResult'))
    ck('Navigation checks draft','Test-DomeniaDraftNavigation' in cf('Open-AdObject') and 'Test-DomeniaDraftNavigation' in cf('Invoke-GlobalSearch'))
    ck('Receipt before mutation wrapper','New-WReceipt $Context $Payload' in cf('New-DomeniaWorkerRunspace') and "Set-WReceiptStage 'Sent'" in cf('New-DomeniaWorkerRunspace'))
    ck('No uncertainty cleared by loading a form',"$script:WriteState = 'Idle'" not in cf('Show-AdObjectResult') and '$script:WriteState="Idle"' not in cf('Show-AdObjectResult'))
    ck('AD writes gated by durable receipts','ReceiptReady' in cf('Assert-WriteAllowed') and 'ReceiptPending' in cf('Assert-WriteAllowed'))
    ck('Secrets scopes independent','ReadLaps' in access and 'ReadBitLocker' in access and "-RetryAttempt 1" in access)
    ck('Temporary credentials expire and are never serialized','AddMinutes(30)' in access and 'Expires.Remove' in access and 'Export-Clixml' not in access)
    ck('Windows sessions separate from console guess','WTSOpenServerW' in load(ROOT/'wad/modules/Domenia-Sessions.Native.cs'))
    ck('No disconnect API in sessions reader','WTSLogoffSession' not in load(ROOT/'wad/modules/Domenia-Sessions.Native.cs'))
    ck('No password copied into reports', 'Get-DomeniaSupportFieldNames' in load(ROOT/'wad/modules/Domenia-Dossier.Model.ps1'))
    ck('Active database excludes network','DriveType' in cf('Initialize-DomeniaDataStore') and 'ReparsePoint' in cf('Initialize-DomeniaDataStore'))
    ck('Legacy database path kept','ADCC.db' in cf('Get-DomeniaDatabasePath'))
    ck('Legacy settings lower priority','ADCC.' in cf('Read-DomeniaPreference'))
    ck('DB schema future version refused','Version de base incompatible' in cf('Initialize-DomeniaDatabase') and 'Schema Domenia incompatible' in cf('Initialize-DomeniaDatabase'))
    ck('Migration backup before schema write',cf('Initialize-DomeniaDatabase').index('Backup-DomeniaDatabase') < cf('Initialize-DomeniaDatabase').index('$schema ='))
    ck('Shared lifecycle lock bootstrap/installer','Support\\.lifecycle.lock' in start and 'Support\\.lifecycle.lock' in installer)
    ck('Interrupted install denies startup','.update.pending' in start and 'Write-CodeJournal $pendingPath' in installer)
    ck('Normal startup verifies runtime hashes','Get-FileHash' in start and '$_.Runtime -eq $true' in start)
    ck('PROD has no test/demo startup dependency','TESTER-' not in start and 'APERCU-' not in start)
    ck('Updater preserves existing configuration','SourceOverride' in installer and 'ADCC.' in installer and 'PreserveExisting' in installer)
    # Real SQLite execution of the exact extracted schema (no credentials/user data).
    sql=re.search(r'\$schema = @"\n(.*?)\n"@',cf('Initialize-DomeniaDatabase'),re.S)[1]
    with tempfile.TemporaryDirectory(prefix='domenia-sql-') as td:
        db=sqlite3.connect(Path(td)/'cache.db',isolation_level=None)
        ck('SQLite exact schema executes',lambda:db.executescript(sql) is not None,'SQLite')
        ck('SQLite schema retains legacy and new versions',dict(db.execute('SELECT key,value FROM schema_info'))=={'schema_version':'11','domenia_schema':'1'},'SQLite')
        db.execute("INSERT INTO user_machine_links(computer_key,user_login,computer,source) VALUES(?,?,?,?)",('PC1',"o'hara",'PC1','Manual'))
        db.executescript(sql)
        ck('Reopening schema keeps existing links',db.execute('SELECT user_login FROM user_machine_links').fetchone()[0]=="o'hara",'SQLite')
        db.execute('BEGIN IMMEDIATE');db.execute("UPDATE user_machine_links SET user_login='other' WHERE computer_key='PC1'");db.execute('ROLLBACK')
        ck('Rollback preserves previous association',db.execute('SELECT user_login FROM user_machine_links').fetchone()[0]=="o'hara",'SQLite')
        other=sqlite3.connect(Path(td)/'cache.db',timeout=0.05,isolation_level=None);db.execute('BEGIN IMMEDIATE')
        blocked=False
        try:other.execute('BEGIN IMMEDIATE')
        except sqlite3.OperationalError:blocked=True
        finally:db.execute('ROLLBACK');other.close()
        ck('Second writer is rejected while locked',blocked,'SQLite')
        backup=sqlite3.connect(Path(td)/'snapshot.db');db.backup(backup)
        ck('Coherent SQLite backup includes data',backup.execute('SELECT user_login FROM user_machine_links').fetchone()[0]=="o'hara",'SQLite')
        ck('SQLite backup quick_check',backup.execute('PRAGMA quick_check').fetchone()[0]=='ok','SQLite')
        backup.close();db.close()
    b=(ROOT/'Domenia.exe').read_bytes();pe=struct.unpack_from('<I',b,0x3c)[0];opt=pe+24
    ck('Actual native x64 Windows PE',b[:2]==b'MZ' and b[pe:pe+4]==b'PE\x00\x00' and struct.unpack_from('<H',b,pe+4)[0]==0x8664,'PE')
    ck('No managed CLR bootstrap',struct.unpack_from('<II',b,opt+112+14*8)==(0,0),'PE')
    ck('GUI subsystem',struct.unpack_from('<H',b,opt+68)[0]==2,'PE')
    ck('AsInvoker not forced admin',b'asInvoker' in b and b'requireAdministrator' not in b,'PE')
    ck('PE product name Domenia','Domenia'.encode('utf-16le') in b and 'ProductName'.encode('utf-16le') in b,'PE')
    ck('Launcher holds lifecycle lock','CreateFileW' in load(ROOT/'tools/launcher/launcher.c') and '.lifecycle.lock' in load(ROOT/'tools/launcher/launcher.c'))
    report=dict(Build=BUILD,Passed=sum(c['Passed'] for c in checks),Failed=sum(not c['Passed'] for c in checks),Environment='Linux / Python / SQLite / PE inspection',CoreFunctions=len(functions(core)),RuntimeFunctions=len(all_names),PinnedOperations=len(reg),HelpEntries=len(catalog),WindowsPowerShellExecuted=False,WpfExecuted=False,LiveADExecuted=False,NativePEExecuted=False,Checks=checks)
    a.report.parent.mkdir(parents=True,exist_ok=True);a.report.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k!='Checks'},indent=2));return int(report['Failed']>0)
if __name__=='__main__':raise SystemExit(main())
