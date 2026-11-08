#!/usr/bin/env python3
"""RC1.3 targeted source/XML/integrity checks. Not a PowerShell or WPF run."""
import argparse,difflib,hashlib,json,re,sys,zipfile,xml.etree.ElementTree as ET
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
from audit_candidate import balanced,functions,getfunc,literals
BUILD='2026.10.01-DOMENIA-1.0-RC1.3-SELECTION'
def load(path):return path.read_text('utf-8-sig')
def sha(x):return hashlib.sha256(x if isinstance(x,bytes) else x.encode()).hexdigest().upper()
def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--baseline-dev',type=Path,required=True);ap.add_argument('--report',type=Path,required=True);a=ap.parse_args()
    with zipfile.ZipFile(a.baseline_dev) as z:old={n[4:]:z.read(n) for n in z.namelist() if n.startswith('dev/') and not n.endswith('/')};assert not z.testzip()
    checks=[]
    def ck(name,test):
        try:
            v=test() if callable(test) else test
            assert v is None or bool(v),name
            checks.append(dict(Name=name,Passed=True))
        except Exception as e:checks.append(dict(Name=name,Passed=False,Detail=str(e)))
    core=load(ROOT/'wad/Domenia-Core.ps1');live=load(ROOT/'wad/modules/Domenia-Live.UI.ps1');cont=load(ROOT/'wad/modules/Domenia-Continuity.UI.ps1');loader=load(ROOT/'wad/Domenia-Modules.ps1')
    cf=lambda n:getfunc(core,n);lf=lambda n:getfunc(live,n);tf=lambda n:getfunc(cont,n)
    xc='{http://schemas.microsoft.com/winfx/2006/xaml}';wp='{http://schemas.microsoft.com/winfx/2006/xaml/presentation}'
    tree=ET.fromstring(literals(cf('Get-MainXaml'))[0]);grid=next(e for e in tree.iter() if e.get(xc+'Name')=='DgObjects');columns=list(grid.find(wp+'DataGrid.Columns'))
    ck('18 result columns retained',len(columns)==18)
    for c in columns:ck('Plain nonempty header: '+str(c.get('Binding',c.get('SortMemberPath'))),bool(c.get('Header')) and c.find(wp+'DataGridTextColumn.Header') is None)
    field=lambda e:e.get('SortMemberPath') or re.search(r'Binding ([^}]+)',e.get('Binding','')).group(1)
    oldcore=old['wad/Domenia-Core.ps1'].decode('utf-8-sig').replace('\r\n','\n');oldtree=ET.fromstring(literals(getfunc(oldcore,'Get-MainXaml'))[0]);oldgrid=next(e for e in oldtree.iter() if e.get(xc+'Name')=='DgObjects');oldcols=list(oldgrid.find(wp+'DataGrid.Columns'))
    ck('Binding-based layout keys remain identical',[field(e) for e in columns]==[field(e) for e in oldcols])
    ck('Current console and remembered association labelled separately',columns[2].get('Header')=='Utilisateur connecté (console)' and columns[7].get('Header')=='Association mémorisée')
    names={e.get(xc+'Name'):e for e in tree.iter() if e.get(xc+'Name')}
    ck('Selection checkbox explained','sélectionné' in names['ChkLiveUsers'].get('Content',''))
    ck('Recheck concerns one computer',names['BtnLiveRecheck'].get('Content')=='Revérifier ce poste')
    ck('Grid help describes explicit opening','Double-clic' in grid.get('ToolTip','') and 'sélectionne' in grid.get('ToolTip',''))
    ck('Main selection event never opens a fiche','Add_SelectionChanged({ Queue-DomeniaSelectedObjectOpen' not in cf('Wire-Events'))
    ck('Double click is gated to a data row','ContainerFromElement' in cf('Wire-Events') and '$container -is [Windows.Controls.DataGridRow] -and @($sender.SelectedItems).Count -eq 1' in cf('Wire-Events'))
    ck('Passive selection compatibility no longer opens a fiche','if(-not $Immediate -and -not $Force){Select-DomeniaLiveResult;return}' in cf('Queue-DomeniaSelectedObjectOpen'))
    ck('No result-list ping call sites in the core',len(re.findall(r'\bStart-DomeniaResultPresenceScan\b',core))==1)
    ck('No automatic one-result open branch','elseif (-not $NoAutoOpen -and $script:BranchObjects.Count -eq 1)' not in cf('Show-ObjectRows'))
    ck('Boolean selection guard no longer manipulates menus','$Menu' not in cf('Test-DomeniaGridSelectionMatches'))
    ck('AD producer requires existing selection intent',"if($fresh -and (Test-DomeniaLiveProbeIntent -Row $row))" in lf('Add-DomeniaLiveRow'))
    ck('Intent created only by selection function',len(re.findall(r'\$script:Live\.ProbeSelection=\[pscustomobject\]',live))==1)
    ck('Intent checks generation and identity','Test-DomeniaLiveIdentity' in lf('Test-DomeniaLiveProbeIntent') and 'GlobalSearchGeneration' in lf('Test-DomeniaLiveProbeIntent'))
    ck('Intent checks GUID','intent.Guid' in lf('Test-DomeniaLiveProbeIntent'))
    ck('Selection respects disabled grid and multiple selection','@($grid.SelectedItems).Count -ne 1' in lf('Select-DomeniaLiveResult') and '-not $grid.IsEnabled' in lf('Select-DomeniaLiveResult'))
    ck('Selection never loads or clears a fiche',not any(x in lf('Select-DomeniaLiveResult') for x in ['Open-AdObject','Clear-ObjectDetails','Reset-DomeniaSelectionBoundViews']))
    ck('Explicit recheck does not iterate results', 'foreach' not in lf('Request-DomeniaLiveRecheck') and 'Select-DomeniaLiveResult -Force -Manual' in lf('Request-DomeniaLiveRecheck'))
    ck('Legacy autodetect flag cannot reinstate list scans','AutoDetectLoggedUser' not in lf('Initialize-DomeniaLive') and 'VerifyUserOnSelection' in lf('Initialize-DomeniaLive'))
    ck('Cached row requires fresh AD before probing','Search.Fresh.ContainsKey' in lf('Request-DomeniaLiveProbe'))
    ck('Starter only uses explicitly selected row','Get-DomeniaSelectedGridRow' in lf('Start-DomeniaLiveBackgroundWork') and 'Test-DomeniaLiveProbeIntent -Row $selected' in lf('Start-DomeniaLiveBackgroundWork'))
    ck('No visible-row or FIFO fallback starts other machines','ContainerFromItem' not in lf('Start-DomeniaLiveBackgroundWork') and 'Pending.Dequeue' not in lf('Start-DomeniaLiveBackgroundWork'))
    ck('Starter captures one-shot intent before dispatch',lf('Start-DomeniaLiveBackgroundWork').index('$intent.Requested=$true')<lf('Start-DomeniaLiveBackgroundWork').index("$id=Start-UiTask -Name ('Utilisateur console '"))
    ck('Native cleanup does not requeue probes','Request-DomeniaLiveProbe' not in lf('Invoke-DomeniaLiveTick'))
    ck('Already active probe must match GUID to be shared','job.CallbackState.Guid -ieq [string]$Row.Guid' in lf('Request-DomeniaLiveProbe'))
    ck('New search clears unsent intent','Clear-DomeniaLiveProbeIntent' in lf('Stop-DomeniaLiveSearch'))
    ck('No stopping native jobs when merely changing selection','Request-UiTaskStop' not in lf('Clear-DomeniaLiveProbeIntent'))
    ck('Disk cache processing retained','LiveCache' in lf('Start-DomeniaLiveBackgroundWork') and 'Live.SaveQueue' in lf('Complete-DomeniaLiveProbe'))
    ck('One tree restore per session/context','RestoreToken -ceq $token' in tf('Start-DomeniaTreeBookmarkRestore'))
    ck('Restore enqueues search after visual selection','RestoreSearch=[pscustomobject]' in tf('Invoke-DomeniaTreeBookmarkRestore') and tf('Invoke-DomeniaTreeBookmarkRestore').index('$n.IsSelected=$true')<tf('Invoke-DomeniaTreeBookmarkRestore').index('RestoreSearch=[pscustomobject]'))
    ck('Do not wait for unrelated branches before scheduling content','Invoke-DomeniaRestoredOuSearch' in tf('Initialize-DomeniaContinuity'))
    ck('Restored search consumed before dispatch',tf('Invoke-DomeniaRestoredOuSearch').rindex('$c.RestoreSearch=$null')<tf('Invoke-DomeniaRestoredOuSearch').index('Invoke-GlobalSearch -'))
    ck('Restored search preserves current workspace/selection','-AllowEmpty -SilentError -PreserveSelection' in tf('Invoke-DomeniaRestoredOuSearch'))
    for item in ['SessionEpoch','GlobalSearchGeneration','Context','TypeFilter','RestoringSettings','SuppressBranchAutoLoad','Test-DomeniaAccessBusyWrite','IsEnabled']:
        ck('Restored search gate: '+item,item in tf('Invoke-DomeniaRestoredOuSearch'))
    ck('Manual tree navigation cancels queued restore',tf('Initialize-DomeniaContinuity').count('$script:Continuity.RestoreSearch=$null')>=2)
    ck('No domain fallback for a missing OU','aucune recherche globale de remplacement' in tf('Invoke-DomeniaTreeBookmarkRestore'))
    access=load(ROOT/'wad/modules/Domenia-Access.UI.ps1')
    ck('Probe error target is not inferred from last fiche','Target=$resourceTarget' in getfunc(access,'Request-DomeniaAccessRecovery') and '$job.CallbackState.Key' in getfunc(access,'Request-DomeniaAccessRecovery'))
    ck('Alternate credential can use captured target','[string]$Record.Target' in getfunc(access,'Invoke-DomeniaAccessRecovery'))
    plan=list(re.finditer(r"\[pscustomobject\]@\{ File='([^']+)'; DotSource=\$(true|false); Functions=@\((.*?)\) \}",loader,re.S))
    ck('20 modules remain explicitly loaded',len(plan)==20)
    for m in plan:
        exports=re.findall(r"'([\w-]+)'",m[3]);defined=set(functions(load(ROOT/'wad/modules'/m[1])))
        ck('Complete explicit export plan: '+m[1],set(exports)==defined and len(exports)==len(defined))
    for n in ['Invoke-DomeniaInProcessAuthProbe','Initialize-DomeniaDataStore','Get-DomeniaWorkerOperationHashes','Open-AdObject','Complete-DomeniaLiveSearch']:
        source=live if n=='Complete-DomeniaLiveSearch' else core
        path='wad/modules/Domenia-Live.UI.ps1' if n=='Complete-DomeniaLiveSearch' else 'wad/Domenia-Core.ps1'
        ck('Preserved sensitive function: '+n,getfunc(source,n)==getfunc(old[path].decode('utf-8-sig').replace('\r\n','\n'),n))
    for path in ['Domenia.exe','wad/Domenia-Start.ps1','wad/modules/Domenia-Receipts.Worker.ps1','tools/operation-contracts.json','wad/Support/DEBLOQUER_TOUT.cmd','wad/Support/Debloquer-Paquet.ps1']:
        ck('Preserved file: '+path,(ROOT/path).read_bytes()==old[path])
    changed=[n for n in functions(oldcore) if getfunc(oldcore,n)!=cf(n)]
    ck('No deleted core functions',set(functions(oldcore))==set(functions(core)))
    for p in sorted(ROOT.rglob('*.ps1')):
        if 'history' in p.parts:continue
        ck('Lexical balance (not native execution): '+p.relative_to(ROOT).as_posix(),lambda p=p:balanced(load(p)))
    tests=load(ROOT/'wad/tests/Test-DomeniaSelection.ps1')
    ck('New native tests are included',tests.count("Case '")>=40)
    ck('WPF realization assertion present','DataGridColumnHeader' in tests and '$v.ActualHeight -gt 0' in tests)
    ck('Shared Suite boolean converter loaded by fixtures',"modules\\Domenia-Experience.Model.ps1" in tests)
    installer=load(ROOT/'INSTALLER-MISE-A-JOUR.ps1')
    ck('Installer invokes new suite before code copy',installer.index("'Test-DomeniaSelection.ps1'")<installer.index('# Backup all original code'))
    ck('Installer rejects skipped/incomplete new suite',"$suite -in @('Test-DomeniaModules.ps1','Test-DomeniaSelection.ps1')" in installer and '-not $result.Complete' in installer)
    report=dict(Build=BUILD,BaselineSha256=sha(a.baseline_dev.read_bytes()),CoreFunctionsChanged=changed,PreservedCoreFunctions=len(functions(core))-len(changed),Passed=sum(c['Passed'] for c in checks),Failed=sum(not c['Passed'] for c in checks),NativeTestCasesProvided=tests.count("Case '"),PowerShellExecuted=False,WindowsPowerShellExecuted=False,WpfExecuted=False,LiveADExecuted=False,LiveCimExecuted=False,Checks=checks)
    a.report.parent.mkdir(parents=True,exist_ok=True);a.report.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n','utf-8')
    print(json.dumps({k:v for k,v in report.items() if k!='Checks'},indent=2))
    for c in checks:
        if not c['Passed']:print(c)
    return int(bool(report['Failed']))
if __name__=='__main__':raise SystemExit(main())
