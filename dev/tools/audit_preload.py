#!/usr/bin/env python3
"""Source/XML/contract checks for selection preloading. Not a Windows/PowerShell execution."""
from pathlib import Path
import argparse,hashlib,json,re,sys,subprocess,zipfile
import xml.etree.ElementTree as ET
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'wad/tests'))
from powershell_lex import functions,mask_ps
SHA=lambda s:hashlib.sha256(s.encode('utf-8')).hexdigest().upper()

def audit():
    checks=[]
    def ck(name,value,detail=''):
        checks.append(dict(Name=name,Passed=bool(value),Detail=detail))
    source=(ROOT/'wad/Domenia-Core.ps1').read_text('utf-8-sig').replace('\r\n','\n')
    spans=functions(source)
    def fn(name):
        span=spans.get(name,[])
        if len(span)!=1: raise ValueError('Missing/ambiguous function: '+name)
        return source[span[0][0]:span[0][1]]
    baseline=json.loads((ROOT/'tools/preload-baseline.json').read_text())
    ck('Every original core function retained',set(spans)==set(baseline['CoreFunctions']))
    ck('No duplicate core functions',all(len(v)==1 for v in spans.values()))
    changed=[k for k,v in baseline['CoreFunctions'].items() if SHA(fn(k))!=v]
    critical=['Invoke-DomeniaInProcessAuthProbe','Start-DomeniaFastLoginAttempt','Update-DomeniaFastLoginAttempt','Complete-DomeniaFastLoginSuccess','Start-DomeniaLoginAuthRunspace','Get-DomeniaStandardLoginXaml','Get-DomeniaBootThemePalette','Test-DomeniaMainHostAvailable','Invoke-DomeniaHostWindow','Initialize-AsyncEngine','Assert-DomeniaWorkerRegistry','Get-DomeniaSearchScope','Test-DomeniaSearchStateCurrent','Invoke-GlobalSearch','Get-BranchQueryData','Start-DomeniaWriteTask','Get-DomeniaWorkerOperationHashes']
    for name in critical:
        ck('Unchanged critical function: '+name,SHA(fn(name))==baseline['CoreFunctions'].get(name))
    for name in ['Domenia.exe','wad/Microsoft.ActiveDirectory.Management.dll','wad/ActiveDirectoryPowerShellResources.dll','wad/PsExec.exe','wad/Domenia.config.json','wad/Domenia.theme.cfg','wad/Domenia.login-mode.cfg','wad/Domenia.ui-profile.cfg','wad/Domenia-Start.ps1','wad/Support/DEBLOQUER_TOUT.cmd','wad/Support/Debloquer-Paquet.ps1','wad/modules/Domenia-Live.UI.ps1','wad/modules/Domenia-Relations.UI.ps1']:
        ck('Unchanged payload: '+name,hashlib.sha256((ROOT/name).read_bytes()).hexdigest().upper()==baseline['Files'][name])
    wire=fn('Wire-Events')
    event=re.search(r'\["DgObjects"\]\.Add_SelectionChanged\((.*?)\n    \}\)',wire,re.S).group(1)
    ck('Actual grid SelectionChanged invokes preload', 'Queue-DomeniaSelectedObjectOpen' in event)
    ck('Actual grid event is not console-only','Select-DomeniaLiveResult' not in event)
    ck('Actual click-up also invokes the coalesced selection path',bool(re.search(r'Add_PreviewMouseLeftButtonUp\([\s\S]*?Queue-DomeniaSelectedObjectOpen',wire)))
    double=re.search(r'\["DgObjects"\]\.Add_MouseDoubleClick\((.*?)\n    \}\)',wire,re.S).group(1)
    key=re.search(r'\["DgObjects"\]\.Add_KeyDown\((.*?)\n    \}\)',wire,re.S).group(1)
    ck('Double click opens without forcing reread','Open-SelectedObject' in double and '-Force' not in double)
    ck('Enter opens without forcing reread','Open-SelectedObject' in key and '-Force' not in key)
    ck('Double-click validates a real row and a single selection','DataGridRow' in double and 'SelectedItems' in double)
    ck('Selection is initialized from real Wire-Events','Initialize-DomeniaSelectionPreload' in wire)
    queue=fn('Queue-DomeniaSelectedObjectOpen');pending=fn('Invoke-DomeniaPendingSelectionOpen')
    for guard in ['SuppressGridSelectionEvents','AsyncEngineClosing','Test-DomeniaAccessBusyWrite','Test-DomeniaDraftNavigation','CurrentObjectRequestId','SelectionDebounceMs','ReadOnlyRetry']:
        ck('Queue guard: '+guard,guard in queue)
    ck('Draft decision precedes remote request',queue.index('Test-DomeniaDraftNavigation')<queue.index('Select-DomeniaLiveResult'))
    ck('Pending read suppresses navigation and remote effects','-SelectionBound -NoNavigate -SuppressRemoteProbes' in pending)
    ck('Busy-write pause precedes grid-current check',pending.index('Test-DomeniaAccessBusyWrite')<pending.index('Test-DomeniaSelectionLoadCurrent'))
    ck('No wait or sleep in interactive preload',not re.search(r'WaitOne\(|\.Wait\(|Start-Sleep|\.Result\b',queue+pending+fn('Open-AdObject')))
    callback=fn('Test-DomeniaObjectCallbackIsCurrent')
    for g in ['CurrentObjectRequestId','Epoch','Identity','SelectionToken','Test-DomeniaSelectionLoadCurrent','Test-DomeniaGridSelectionMatches']:
        ck('Callback guard: '+g,g in callback)
    success=fn('Complete-DomeniaOpenObjectTaskUi')
    ck('Identity validated before display',success.index('Assert-DomeniaObjectResultIdentity')<success.index('Complete-DomeniaOpenObjectUi'))
    ck('Completion cannot steal navigation','-NoNavigate:([bool]$State.NoNavigate)' in success)
    ck('Failure is inline for a selection','-not $State.SelectionBound' in fn('Fail-DomeniaOpenObjectTaskUi'))
    ck('User cancellation exits loading phase','Lecture interrompue' in fn('Request-UiTaskStop'))
    ck('Fresh-read safety required for writes',"Phase -ne 'Ready'" in fn('Get-DomeniaSafetyDescriptor'))
    ck('Type display has true non-navigation mode','[switch]$PreserveWorkspace' in fn('Set-VisibleTabsForType') and '-not $PreserveWorkspace' in fn('Set-VisibleTabsForType'))
    show=fn('Show-AdObjectResult')
    ck('Preload cannot ping associated user machine','RenderingObjectWithoutProbes' in fn('Fill-UserObject'))
    ck('Preload does not duplicate machine probes','RenderingObjectWithoutProbes' in fn('Fill-ComputerObject'))
    ck('Rendering restores the suppression flag in finally','finally { $script:RenderingObjectWithoutProbes=$oldProbeGuard }' in show)
    ck('One index synchronization per fresh render',show.count('Sync-DomeniaIndexEntry')==1 and 'Sync-DomeniaIndexEntry' not in fn('Fill-ComputerObject'))
    ck('Direct open releases view wrappers','if (-not $NoNavigate)' in show and "ReadContent" in show)
    m=(ROOT/'wad/modules/Domenia-Selection.UI.ps1').read_text('utf-8-sig')
    for g in ['Get-DomeniaCacheKey','GlobalSearchGeneration','GetHashCode','ExpectedGuid','ToString(\'D\')','DN -ieq','Phase -eq \'Ready\'','SameSelectionContext']:
        ck('Selection/cache identity rule: '+g,g in m)
    cache_rule=(ROOT/'wad/modules/Domenia-Cache.Model.ps1').read_text('utf-8-sig')
    ck('Selection/cache identity rule: reader hashed by the cache-v3 rule',"'cache-v3|" in cache_rule and 'Get-DomeniaTextHash' in cache_rule)
    ck('One type update per selection type','if ($load.VisibleType -cne $context.Type)' in m)
    ck('Read retry does not reprobe','-Immediate -Force -ReadOnlyRetry' in m)
    ck('Old object hidden before request','SelectedObject = $null' in m and "Visibility = 'Collapsed'" in m)
    ck('No network commands or windows in presentation module',not re.search(r'\b(?:Get-CimInstance|Get-ADUser|Get-ADComputer|Test-Connection|Start-Process|ShowDialog)\b',m))
    ck('Selection module no timer starts on import',all(not line.startswith('$script:') or not any(x in line for x in ['.Start(','[Windows.','[System.Windows.']) for line in m.splitlines()))
    # Full closed export plan must match every real module, not a list of helper-name strings.
    loader=(ROOT/'wad/Domenia-Modules.ps1').read_text('utf-8-sig')
    plans=re.findall(r"File='([^']+)';\s*DotSource=\$true;\s*Functions=@\((.*?)\)\s*}",loader,re.S)
    exports=[]
    for name,body in plans:
        expected=re.findall(r"'([^']+)'",body)
        definitions=functions((ROOT/'wad/modules'/name).read_text('utf-8-sig'))
        ck('Closed exports match: '+name,set(expected)==set(definitions) and len(expected)==len(set(expected)) and all(len(v)==1 for v in definitions.values()))
        exports.extend(expected)
    ck('Selection module included in bootstrap plan',any(n=='Domenia-Selection.UI.ps1' for n,_ in plans))
    ck('Module names are unique',len(exports)==len(set(exports)))
    # Avoid automatic readonly PowerShell variables in the modified executable bodies.
    for label,s in [('selection module',m)]+[(n,fn(n)) for n in changed if n!='Get-MainXaml']:
        masked,_=mask_ps(s)
        ck('No readonly variable assignment: '+label,not re.search(r'(?i)\$(?:host|pid|pshome|psversiontable|true|false|null)\s*(?:[+*/-]?=(?!=)|\+\+|--)',masked))
    raw=re.search(r'@"\s*\n(.*?)\n"@',fn('Get-MainXaml'),re.S).group(1)
    xml=ET.fromstring(raw);ns={'w':'http://schemas.microsoft.com/winfx/2006/xaml/presentation'};x='{http://schemas.microsoft.com/winfx/2006/xaml}';w='{http://schemas.microsoft.com/winfx/2006/xaml/presentation}'
    byname={n.get(x+'Name'):n for n in xml.iter() if n.get(x+'Name')}
    for kind in ['Object','Computer']:
        host=byname[kind+'ReadContent'];retry=byname['Btn'+kind+'ReadRetry']
        ck('Named content host: '+kind,host.get('IsEnabled')=='False' and host.get('Visibility')=='Collapsed')
        ck('Reserved retry slot: '+kind,retry.get('Visibility')=='Hidden' and retry.get('ToolTip') and retry.get('AutomationProperties.Name'))
        ck('Non-modal placeholder: '+kind,byname[kind+'ReadPlaceholder'].tag==w+'Border')
    ck('No extra Window in main XAML',sum(n.tag==w+'Window' for n in xml.iter())==1)
    grid=byname['DgObjects'];ck('Existing data columns retained',len(grid.find(w+'DataGrid.Columns'))==18)
    ck('Result row virtualisation preserved',grid.get('EnableRowVirtualization')=='True' and grid.get('EnableColumnVirtualization')=='True')
    ck('No busy state injected in the global layout',byname['LblSelectionReadState'].get('Height')=='20')
    for name in ['ObjectReadRoot','ComputerReadRoot']:
        ck('Read state reserved row: '+name,byname[name].find(w+'Grid.RowDefinitions')[0].get('Height')=='38')
    helpdata=json.loads((ROOT/'wad/modules/Domenia-UX.help.json').read_text('utf-8-sig'))
    ck('Retry help catalog entries exist',all(n in {h['Name'] for h in helpdata} for n in ['BtnObjectReadRetry','BtnComputerReadRetry']))
    test=(ROOT/'wad/tests/Test-DomeniaPreload.ps1').read_text('utf-8-sig')
    for item in ['Parser]::ParseFile','Parser]::ParseInput','Add_SelectionChanged','GetScriptBlock','XamlReader','NativeWindowsPowerShell','Requests.Count','Late A','SkipWpf','Failed','Complete']:
        ck('Windows suite contains: '+item,item in test)
    # FI-06: the installer ships in PROD and never runs a test suite on the target workstation; the prepared version
    # must pass Domenia-Start -CheckOnly before activation and a qualification report is checked against the ZIP hash.
    install=(ROOT/'wad/Support/INSTALLER-MISE-A-JOUR.ps1').read_text('utf-8-sig')
    ck('Installer runs no test suite on the target','wad\\tests' not in install and 'wad/tests' not in install and 'Test-Domenia' not in install)
    ck('Installer checks the prepared version before activation',install.index("Join-Path $staged 'wad/Domenia-Start.ps1') -CheckOnly")<install.index('$started=$false'))
    ck('Installer binds a qualification report to the ZIP hash','RequireQualification' in install and 'Get-QualificationState' in install and 'GetEntry(' in install)
    ck('DEV installer entry point forwards to the shipped installer',"wad\\Support\\INSTALLER-MISE-A-JOUR.ps1') @PSBoundParameters" in (ROOT/'INSTALLER-MISE-A-JOUR.ps1').read_text('utf-8-sig'))
    # These are actual host-side validators; neither one is the native parser.
    for tool in ['validate_powershell_static.py','update_worker_contracts.py']:
        result=subprocess.run([sys.executable,str(ROOT/'tools'/tool)],capture_output=True,text=True)
        ck('Executed: '+tool,result.returncode==0,(result.stdout+result.stderr).strip())
    failed=[c for c in checks if not c['Passed']]
    build=json.loads((ROOT/'tools/release-contract.json').read_text(encoding='utf-8-sig')).get('Build','')
    return dict(Build=build,SourceBase=baseline['Archive'],Passed=len(checks)-len(failed),Failed=len(failed),CoreFunctions=len(spans),ChangedCoreFunctions=changed,UnchangedCoreFunctions=len(spans)-len(changed),ModuleFiles=len(plans),ModuleExports=len(exports),WindowsPowerShellExecuted=False,WpfExecuted=False,LiveADExecuted=False,Kind='Source/XML and archive-level contract verification only',Checks=checks)

PAYLOADS=['Domenia.exe','wad/Microsoft.ActiveDirectory.Management.dll','wad/ActiveDirectoryPowerShellResources.dll','wad/PsExec.exe','wad/Domenia.config.json','wad/Domenia.theme.cfg','wad/Domenia.login-mode.cfg','wad/Domenia.ui-profile.cfg','wad/Domenia-Start.ps1','wad/Support/DEBLOQUER_TOUT.cmd','wad/Support/Debloquer-Paquet.ps1','wad/modules/Domenia-Live.UI.ps1','wad/modules/Domenia-Relations.UI.ps1']

def rebaseline(decision,source_label):
    """Re-pins the reviewed state after a written decision. Every core function and every checked payload is
    re-hashed; the decision (what changed and why it was accepted) is appended to the baseline history."""
    if not decision or len(decision.strip())<20: raise SystemExit('Decision ecrite requise (--decision, 20 caracteres au moins).')
    path=ROOT/'tools/preload-baseline.json'
    baseline=json.loads(path.read_text())
    source=(ROOT/'wad/Domenia-Core.ps1').read_text('utf-8-sig').replace('\r\n','\n')
    spans=functions(source)
    dup=[k for k,v in spans.items() if len(v)!=1]
    if dup: raise SystemExit('Fonctions du coeur ambigues : '+', '.join(dup))
    core={k:SHA(source[v[0][0]:v[0][1]]) for k,v in spans.items()}
    changed=sorted(k for k,v in core.items() if baseline['CoreFunctions'].get(k)!=v)
    added=sorted(set(core)-set(baseline['CoreFunctions']));removed=sorted(set(baseline['CoreFunctions'])-set(core))
    files=dict(baseline['Files'])
    payloads=[]
    for name in PAYLOADS:
        digest=hashlib.sha256((ROOT/name).read_bytes()).hexdigest().upper()
        if files.get(name)!=digest: payloads.append(name)
        files[name]=digest
    history=list(baseline.get('Decisions',[]))
    history.append(dict(Previous=baseline['Archive'],Source=source_label,Decision=decision.strip(),ChangedCoreFunctions=changed,AddedCoreFunctions=added,RemovedCoreFunctions=removed,ChangedPayloads=payloads))
    out=dict(Archive=source_label,ArchiveSHA256=baseline.get('ArchiveSHA256',''),CoreFunctions=core,Files=files,Decisions=history)
    with open(path,'w',encoding='utf-8',newline='\n') as handle: handle.write(json.dumps(out,ensure_ascii=False,indent=2)+'\n')
    return history[-1]

if __name__=='__main__':
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--report',type=Path)
    ap.add_argument('--rebaseline',action='store_true',help='Re-pin the reviewed core functions and payloads (requires --decision).')
    ap.add_argument('--decision',default='',help='Written decision recorded in tools/preload-baseline.json.')
    ap.add_argument('--source',default='',help='Label of the reviewed source (commit, lot).')
    args=ap.parse_args()
    if args.rebaseline:
        entry=rebaseline(args.decision,args.source or 'source tree')
        print(json.dumps(entry,ensure_ascii=False,indent=2))
    report=audit()
    if args.report: args.report.parent.mkdir(parents=True,exist_ok=True);args.report.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k!='Checks'},ensure_ascii=False,indent=2))
    for c in report['Checks']:
        if not c['Passed']: print('FAILED: '+c['Name']+' '+c['Detail'])
    sys.exit(1 if report['Failed'] else 0)
