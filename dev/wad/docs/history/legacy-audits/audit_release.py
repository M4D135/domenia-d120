#!/usr/bin/env python3
"""Portable source/XML/PE/package checks, NOT a PowerShell, WPF or AD execution."""
import argparse, hashlib, json, re, struct, sys, xml.etree.ElementTree as ET
from pathlib import Path
root=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(root/'wad/tests'))
from powershell_lex import functions
from audit_experience import delimiters

def text(p):return p.read_text(encoding='utf-8-sig')
def sha(x):return hashlib.sha256(x.encode('utf-8') if isinstance(x,str) else x).hexdigest()
def defs(s):return {n:s[slice(*v[0])] for n,v in functions(s).items() if len(v)==1}
def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--report',type=Path,required=True);a=ap.parse_args()
    checks=[]
    def ck(name,test):
        try:
            result=test() if callable(test) else test
            assert result is None or bool(result),name
            checks.append(dict(Name=name,Passed=True))
        except Exception as e:checks.append(dict(Name=name,Passed=False,Detail=str(e)));print('FAIL',name,str(e))
    c=text(root/'wad/Domenia-Core.ps1');f=defs(c)
    baseline=json.loads(text(root/'tools/baseline-r112.json'))
    access=text(root/'wad/modules/Domenia-Access.UI.ps1');af=defs(access)
    model=text(root/'wad/modules/Domenia-Continuity.Model.ps1');mf=defs(model)
    ui=text(root/'wad/modules/Domenia-Continuity.UI.ps1');uf=defs(ui)
    live=text(root/'wad/modules/Domenia-Live.UI.ps1')
    ck('All baseline core functions retained',set(f)==set(baseline['CoreFunctions']))
    ck('No duplicate core definitions',all(len(v)==1 for v in functions(c).values()))
    changed=[n for n,h in baseline['CoreFunctions'].items() if sha(f[n])!=h]
    for n in ['Invoke-DomeniaInProcessAuthProbe','Start-DomeniaFastLoginAttempt','Update-DomeniaFastLoginAttempt','Complete-DomeniaFastLoginSuccess','Start-DomeniaLoginAuthRunspace','Get-DomeniaStandardLoginXaml','Get-DomeniaSearchScope','Test-DomeniaSearchStateCurrent','Invoke-GlobalSearch','Get-BranchQueryData','Assert-DomeniaCapability','Wire-Events']:
        ck('Preserved core function: '+n,sha(f[n])==baseline['CoreFunctions'][n])
    common=re.search(r"(?ms)^\$script:WorkerCommon = @'\n(.*?)\n'@",c).group(1)
    ck('Common remote worker unchanged',sha(common)==baseline['WorkerCommon'])
    reg=dict(re.findall(r'(\w+)\s*=\s*"([A-F0-9]{64})"',f['Get-DomeniaWorkerOperationHashes']))
    literals={sha(m.group(1)).upper():m.group(1) for s in [c]+[text(p) for p in (root/'wad/modules').glob('*.ps1')] for m in re.finditer(r"@'\n(.*?)\n'@",s,re.S)}
    ck('48 pinned operations with present exact bodies',len(reg)==48 and set(reg.values())<=set(literals))
    ck('Only LAPS replaced among 47 old operations',all(reg[n]==h for n,h in baseline['WorkerRegistry'].items() if n!='ReadLaps') and reg['ReadLaps']!=baseline['WorkerRegistry']['ReadLaps'])
    ck('New watcher is pinned',reg['LiveDirectoryCheck']==sha(re.search(r"return @'\n(.*?)\n'@",model,re.S).group(1)).upper())
    for path in sorted(root.rglob('*.ps1')):
        if path.relative_to(root).as_posix().startswith('wad/data/'):continue
        ck('Approximate delimiters, not native parser: '+str(path.relative_to(root)),lambda path=path:delimiters(text(path)))
    for op in ['ReadLaps','ReadBitLocker','LiveDirectoryCheck']:
        ck('Worker approximate delimiters: '+op,lambda op=op:delimiters(literals[reg[op]]))
    for rel,h in baseline['Files'].items():
        if rel in ['wad/modules/Domenia-Live.UI.ps1','wad/modules/Domenia-UX.help.json']:continue
        ck('Preserved runtime component: '+rel,sha((root/rel).read_bytes())==h)
    ck('Access helper names do not collide with core',not(set(f)&set(af)))
    ck('Continuity helper names do not collide',not(set(f)&(set(mf)|set(uf)) or set(af)&(set(mf)|set(uf)) or set(mf)&set(uf)))
    x=re.search(r'@"\n(.*?)\n"@',f['Get-MainXaml'],re.S).group(1);tree=ET.fromstring(x)
    X='{http://schemas.microsoft.com/winfx/2006/xaml}';W='{http://schemas.microsoft.com/winfx/2006/xaml/presentation}'
    names={n.get(X+'Name'):n for n in tree.iter() if n.get(X+'Name')}
    ck('Main XML parses',tree.tag==W+'Window')
    ck('Secret buttons and OU browser retained',{'BtnLoadLaps','BtnLoadBitLocker','TvDirectory','DgObjects','BtnAccessRecovery'}<=set(names))
    ck('New access command has static help',bool(names['BtnAccessRecovery'].get('ToolTip')) and bool(names['BtnAccessRecovery'].get('AutomationProperties.HelpText')))
    ck('Help catalogue registers access command',any(r['Name']=='BtnAccessRecovery' for r in json.loads(text(root/'wad/modules/Domenia-UX.help.json'))))
    resources={n.get(X+'Key') for n in tree.iter() if n.get(X+'Key')}
    refs=set(re.findall(r'\{StaticResource ([\w]+)\}',x))
    ck('Main static resource names resolved',not(refs-resources))
    for p in (root/'wad/modules').glob('*.xaml'):ck('XML parses: '+p.name,lambda p=p:ET.parse(p) is not None)
    ax=re.search(r"\$x=@'\n(.*?)\n'@",access,re.S).group(1);ad=ET.fromstring(ax)
    ck('Alternate credential XML parses',ad.tag==W+'Window')
    ck('New credential window non-maximizable',ad.get('ResizeMode')=='NoResize')
    ck('No synchronous auth wait in alternate login','WaitOne' not in af['Show-DomeniaAlternateCredential'] and 'Start-DomeniaLoginAuthRunspace' in af['Show-DomeniaAlternateCredential'] and 'DispatcherTimer' in af['Show-DomeniaAlternateCredential'])
    ck('Explicit confirmation before login',af['Invoke-DomeniaAccessRecovery'].index('Confirm-Action')<af['Invoke-DomeniaAccessRecovery'].index('$credential=Show-DomeniaAlternateCredential'))
    ck('Cancel preserves previous credential',af['Invoke-DomeniaAccessRecovery'].index('if($null -eq $credential){return}')<af['Invoke-DomeniaAccessRecovery'].index('$script:AccessState.Credentials[$Record.Scope]=$credential'))
    ck('Only secret reads auto-retry with one attempt',"@('ReadLaps','ReadBitLocker')" in af['Invoke-DomeniaAccessRecovery'] and '-RetryAttempt 1' in af['Invoke-DomeniaAccessRecovery'] and 'Start-DomeniaWriteTask' not in af['Invoke-DomeniaAccessRecovery'])
    ck('Unknown writes block recovery','UnknownPending' in af['Test-DomeniaAccessBusyWrite'] and 'Test-DomeniaAccessBusyWrite' in af['Invoke-DomeniaAccessRecovery'])
    ck('Per-resource denied state replaces shared disable','Test-DomeniaSecretDenied' in f['Update-DomeniaSecretActionUi'] and 'ActualSecretDeniedDn' not in f['Update-DomeniaSecretActionUi'] and 'ActualSecretDeniedDn' not in f['Start-LoadComputerSecrets'])
    ck('Alternate credentials never saved to settings',all(s not in access for s in ['Export-Clixml','Set-DomeniaSetting','WriteAllText','ConvertTo-Json']))
    ck('Background permission failures deduplicated and silent',"'LiveConsole','LiveCache','LiveDirectoryCheck'" in af['Request-DomeniaAccessRecovery'] and '$Interactive=$false' in af['Request-DomeniaAccessRecovery'] and 'Pending.Count -ge 16' in access)
    ck('Old identity cannot reuse credentials','SessionEpoch' in af['Get-DomeniaRetryCredential'] and 'BaseDn' in af['Get-DomeniaRetryCredential'])
    ck('Remote overrides preserve AD identity','MachineCredential=$credential' in af['Set-DomeniaRetryWorkerContext'] and "-eq 'Remote'" in af['Set-DomeniaRetryWorkerContext'])
    ck('Remote credential cannot bypass directory authentication breaker',"$retryScope -ne 'Remote'" in f['Get-WorkerContext'] and '-not $directoryRecovery' in f['Get-WorkerContext'])
    ck('Search cache sees changed temporary identity',"Get-DomeniaRetryCredential 'GlobalSearch'" in live and "Get-DomeniaRetryCredential 'LiveConsole'" in live and 'GetHashCode($adRetry)' in live)
    laps=literals[reg['ReadLaps']]
    ck('LAPS is one command call with same chosen decrypt identity',laps.count('Get-LapsADPassword @params')==1 and '$params.DecryptionCredential=$cred' in laps)
    ck('Missing LAPS module is not replaced by fake auth','ModuleMissing' in laps and "Success=($rows.Count -gt 0)" in laps)
    ck('Layout keys loaded via known settings','GridLayoutsJson' in f['Get-DomeniaDefaultSettings'] and 'OuBookmarksJson' in f['Get-DomeniaDefaultSettings'])
    ck('Layouts contain descriptors, not row values','DisplayIndex' in uf['Save-DomeniaGridLayout'] and 'ItemsSource' not in uf['Save-DomeniaGridLayout'] and 'ConvertTo-DomeniaColumnLayout' in uf['Save-DomeniaGridLayout'])
    ck('Layout numeric values are finite and bounded','IsNaN' in model and 'IsInfinity' in model and '2000' in mf['ConvertTo-DomeniaColumnLayout'])
    ck('OU saved per directory/account','BindUser' in uf['Get-DomeniaTreeContextKey'] and 'BaseDn' in uf['Get-DomeniaTreeContextKey'])
    ck('OU restore preserves exact DN without a content query','SuppressBranchAutoLoad=$true' in uf['Invoke-DomeniaTreeBookmarkRestore'] and 'Invoke-GlobalSearch' not in uf['Invoke-DomeniaTreeBookmarkRestore'])
    ck('OU restoration bounded and user-interruptible','600' in uf['Get-DomeniaRealizedTreeNodes'] and 'AddSeconds(60)' in uf['Start-DomeniaTreeBookmarkRestore'] and 'Add_PreviewMouseDown' in uf['Initialize-DomeniaContinuity'])
    ck('Watcher checks GUID and DC-specific change number',"'objectGUID','uSNChanged'" in model and "[string]$Context.Server+'|'+$stamp" in model)
    ck('Second read rechecks object identity',"$entry.Properties 'objectguid' ''" in model and "-ieq $guid" in model)
    ck('Invisible objects are not silently deleted',"Status='Unconfirmed'" in model and '.Remove($key)' not in uf['Invoke-DomeniaObjectChanges'])
    ck('Watcher processes bounded UI batches','$count -lt 8' in uf['Invoke-DomeniaObjectChanges'] and '$watch.ElapsedMilliseconds -lt 5' in uf['Invoke-DomeniaObjectChanges'])
    ck('Watcher suspends hidden and active-write views','-not $grid.IsVisible' in uf['Invoke-DomeniaObjectChanges'] and 'Test-DomeniaAccessBusyWrite' in uf['Invoke-DomeniaObjectChanges'])
    ck('Responses older than a dispatched write are ignored','$State.Mutation -ne' in uf['Complete-DomeniaObjectChanges'] and 'Continuity.Mutation++' in f['Start-DomeniaWriteTask'])
    ck('No synchronous worker wait added to continuity','WaitOne' not in ui and 'Start-Sleep' not in ui)
    ck('Changed details invalidate cached forms without overwriting editor','VisitCache.Remove' in ui and 'Open-AdObject' not in uf['Invoke-DomeniaObjectChanges'])
    ck('Only presentation metadata persisted to settings','GridLayoutsJson' in ui and 'OuBookmarksJson' in ui and 'Credential|ConvertTo-Json' not in ui)
    # Inspect the real launcher headers instead of labeling a text file .exe.
    b=(root/'Domenia.exe').read_bytes();pe=struct.unpack_from('<I',b,0x3c)[0];opt=pe+24
    ck('Launcher is a native x64 PE image',b[:2]==b'MZ' and b[pe:pe+4]==b'PE\x00\x00' and struct.unpack_from('<H',b,pe+4)[0]==0x8664 and struct.unpack_from('<H',b,opt)[0]==0x20b)
    ck('Launcher has no CLR header',struct.unpack_from('<II',b,opt+112+14*8)==(0,0))
    ck('Launcher is Windows GUI subsystem',struct.unpack_from('<H',b,opt+68)[0]==2)
    ck('Embedded manifest uses normal user rights',b'asInvoker' in b and b'requireAdministrator' not in b)
    ck('Launcher points directly to wad bootstrap', 'wad\\\\Domenia-Start.ps1' in text(root/'tools/launcher/launcher.c'))
    boot=text(root/'wad/Domenia-Start.ps1');unblock=text(root/'wad/maintenance/Debloquer-Paquet.ps1')
    ck('Startup verifies runtime only, not demos/tests', '$_.Runtime -eq $true' in boot and 'APERCU-' not in boot and 'TESTER-' not in boot)
    ck('Unblock validates only runtime files','$_.Runtime -eq $true' in unblock and 'Set-ExecutionPolicy' not in unblock and 'Set-MpPreference' not in unblock)
    ck('Updater deploys runtime production manifest','tools\\prod-manifest.json' in text(root/'INSTALLER-MISE-A-JOUR.ps1'))
    ck('Updater supplies code rollback', 'Restore-CodeTransaction' in text(root/'INSTALLER-MISE-A-JOUR.ps1'))
    ck('New native suite has 43 declared cases',len(re.findall(r'^Case ',text(root/'wad/tests/Test-DomeniaRelease.ps1'),re.M))==43)
    ck('Portable launcher helper test passed',json.loads(text(root/'wad/docs/LAUNCHER-PORTABLE-R1.13.json'))['failed']==0)
    report=dict(Build='2026.09.30-DOMENIA-1.0-RC1',Environment='Linux/Python/native C helpers, not Windows',Passed=sum(x['Passed'] for x in checks),Failed=sum(not x['Passed'] for x in checks),CoreFunctions=len(f),ChangedCoreFunctions=changed,WorkerOperations=len(reg),WindowsPowerShellExecuted=False,WpfExecuted=False,ADExecuted=False,Checks=checks)
    a.report.parent.mkdir(parents=True,exist_ok=True);a.report.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({k:v for k,v in report.items() if k!='Checks'},indent=2))
    return 1 if report['Failed'] else 0
if __name__=='__main__':sys.exit(main())
