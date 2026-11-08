#!/usr/bin/env python3
"""Source/XML/contract comparisons only. Does not execute PowerShell, WPF, LDAP or ICMP."""
from pathlib import Path
import json,re,sys,argparse,hashlib,xml.etree.ElementTree as ET
from audit_candidate import getfunc,balanced,literals
R=Path(__file__).resolve().parents[1]
def read(p):return p.read_text('utf-8-sig')
def sha(s):return hashlib.sha256(s.encode() if isinstance(s,str) else s).hexdigest()
def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--report',type=Path,required=True);args=ap.parse_args()
    checks=[]
    def ck(name,value):
        try:
            v=value() if callable(value) else value
            assert v is None or bool(v)
            checks.append({'Name':name,'Passed':True})
        except Exception as exc:checks.append({'Name':name,'Passed':False,'Error':str(exc)})
    c=read(R/'wad/Domenia-Core.ps1');m=read(R/'wad/modules/Domenia-Live.Model.ps1');u=read(R/'wad/modules/Domenia-Live.UI.ps1');ct=read(R/'wad/modules/Domenia-Continuity.UI.ps1');gu=read(R/'wad/modules/Domenia-Guard.UI.ps1')
    f=lambda n:getfunc(c,n);mf=lambda n:getfunc(m,n);uf=lambda n:getfunc(u,n)
    base=json.loads(read(R/'tools/baselines/RC1.3-search.json'))
    from powershell_lex import functions
    now={n:sha(c[a[0][0]:a[0][1]]) for n,a in functions(c).items()}
    changed=[n for n,h in base['CoreFunctions'].items() if now.get(n)!=h]
    ck('All original core functions retained',set(base['CoreFunctions'])<=set(now))
    for n in ['Invoke-DomeniaInProcessAuthProbe','Start-DomeniaFastLoginAttempt','Update-DomeniaFastLoginAttempt','Complete-DomeniaFastLoginSuccess','Start-DomeniaLoginAuthRunspace','Assert-DomeniaCapability','Start-DomeniaTreeBookmarkRestore']:
        if n in base['CoreFunctions']:ck('Unchanged critical core '+n,now.get(n)==base['CoreFunctions'][n])
    for rel,h in base['Files'].items():ck('Unchanged binary/config '+rel,(R/rel).exists() and sha((R/rel).read_bytes())==h)
    ck('Header entry defaults to Global',"[string]$SearchMode = 'Global'" in f('Invoke-GlobalSearch'))
    ck('Domain root and subtree global branch',"BaseDn=$domainDn; Scope='Subtree'; IsDomain=$true; Mode='Global'" in f('Get-DomeniaSearchScope'))
    ck('OU scope still uses branch and checkbox',all(x in f('Get-DomeniaSearchScope') for x in ['$script:SelectedBranchDn',"'ChkSubtree'","'OneLevel'"]))
    ck('Global text separated from branch text',"'TxtGlobalSearch' } else { 'TxtBranchSearch'" in f('Get-DomeniaSearchText'))
    ck('Global type ignores combo',"if ($Mode -eq 'Global') { return (Get-TypeLdapFilter -Type 'Tous') }" in f('Get-GlobalSelectedTypeFilter'))
    ck('Header click/key request explicit global mode',f('Wire-Events').count('Invoke-GlobalSearch -SearchMode Global')>=2)
    ck('OU changes explicitly request scoped search', '-SearchMode OU' in f('Invoke-DomeniaSearchFilterChanged'))
    ck('Manual OU clears only scoped term',"'TxtBranchSearch' -Text ''" in f('Set-SelectedBranch') and 'TxtGlobalSearch' not in f('Set-SelectedBranch'))
    ck('Restored OU explicitly requests scoped search','-SearchMode OU' in getfunc(ct,'Invoke-DomeniaRestoredOuSearch'))
    ck('Restored OU checks state before launch','RestoreSearch=$null' in getfunc(ct,'Invoke-DomeniaRestoredOuSearch') and 'Generation' in getfunc(ct,'Invoke-DomeniaRestoredOuSearch'))
    ck('Refresh retains active search mode','-SearchMode (Get-DomeniaSearchMode)' in f('Load-BranchObjects'))
    for token in ['SearchMode','Generation','BaseDn','Scope','TypeFilter','Get-DomeniaSearchText']:ck('Late return guard includes '+token,token in f('Test-DomeniaSearchStateCurrent'))
    ck('Cache key includes mode and new namespace','scope-v214|$SearchMode' in f('Invoke-GlobalSearch') and "'search-v214|'+[string]$State.SearchMode" in uf('Begin-DomeniaLiveSearch'))
    ck('Actual global LDAP first pass includes all human-name fields',all(x in f('Invoke-GlobalSearch') for x in ['(displayName=$escapedRaw*)','(givenName=$escapedRaw*)','(sn=$escapedRaw*)','(mail=$escapedRaw*)','(anr=$escapedRaw)']))
    ck('Safe limit remains 500','$limit -gt 500' in f('Invoke-GlobalSearch'))
    ck('Writes and draft decision still guard searches','Test-DomeniaAccessBusyWrite' in f('Invoke-GlobalSearch') and 'Test-DomeniaDraftNavigation' in f('Invoke-GlobalSearch'))
    ck('Live local filters are ignored in Global mode',"if((Get-DomeniaSearchMode) -eq 'Global'){$query='';$presence='Tous'}" in uf('Update-DomeniaLiveFilter'))
    ck('No native code in selection UI','Ping.Send' not in u and 'New-Object Net.NetworkInformation.Ping' not in u)
    ck('No collective ping call sites',len(re.findall(r'(?m)^\s*(?:function\s+)?Start-DomeniaResultPresenceScan\b',c))==1)
    ck('Single intent only from selection','Select-DomeniaLiveResult' in uf('Select-DomeniaLiveResult') and 'Clear-DomeniaLiveProbeIntent' in uf('Select-DomeniaLiveResult'))
    ck('Row arrival requires preexisting intent','Test-DomeniaLiveProbeIntent -Row $row' in uf('Add-DomeniaLiveRow'))
    ck('Multiple selections cannot enqueue',"@($grid.SelectedItems).Count -ne 1" in uf('Select-DomeniaLiveResult'))
    ck('One request marked before dispatch','$intent.Requested=$true' in uf('Start-DomeniaLiveBackgroundWork'))
    ck('Common physical bound includes ping-only','LiveSelectedPing' in uf('Start-DomeniaLiveBackgroundWork') and "$parallel=[Math]::Max(1,[Math]::Min(3" in uf('Start-DomeniaLiveBackgroundWork'))
    ck('Double click shares selected row presence','Select-DomeniaLiveResult' in f('Start-DomeniaSelectedMachinePresence') and 'return' in f('Start-DomeniaSelectedMachinePresence'))
    probe=literals(mf('Get-DomeniaLiveProbeCode'))[0]
    ck('Exactly one ICMP send',probe.count('.Send(')==1 and '$ping.Send($target,900)' in probe)
    ck('Ping precedes CIM',probe.index('$ping.Send')<probe.index('New-CimSession @parameters'))
    ck('Ping published before user lookup',probe.index('PresenceProgress.Enqueue')<probe.index('$credential=Get-WMachineCredential'))
    ck('ICMP disposed in finally','finally {if($null -ne $ping){$ping.Dispose()}}' in probe)
    ck('Ping-only exits before accessing credentials',probe.index("$answer.Outcome='PresenceOnly'")<probe.index('$credential=Get-WMachineCredential'))
    ck('CIM-disabled case still performs ping',probe.index('$ping.Send')<probe.index("$Context.PSObject.Properties['UseCim']"))
    ck('Probe does not deploy task or service',all(x not in probe for x in ['PsExec','schtasks','ADMIN$','Invoke-WSchtasksRemote','Invoke-WRemoteScheduledTaskScript']))
    ck('No ping success required for requested CIM',"if($answer.Presence -eq 'En ligne')" not in probe)
    ck('CIM response can confirm network presence',"$answer.Presence='En ligne';$answer.PresenceCheckedUtc" in probe)
    ck('No ICMP return labelled without shutdown assumption',"$answer.Presence='Sans réponse au ping'" in probe and "$answer.Presence='Hors ligne'" not in probe)
    ck('Error status distinguished',"$answer.Presence='Erreur de ping'" in probe)
    ck('New machine initially non verified',"'Non vérifié'" in uf('Add-DomeniaLiveRow'))
    ck('Dates and sources separated in persistent record',all(x in mf('ConvertTo-DomeniaLiveObservation') for x in ['UserCheckedUtc','PresenceCheckedUtc','ObservedUtc','PresenceDetail']))
    ck('Ping-only keeps user observation date',"if(-not $presenceOnly -and $outcome -eq 'Observed')" in mf('ConvertTo-DomeniaLiveObservation'))
    ck('Ping-only keeps attempted-user date',"$userChecked=if($presenceOnly)" in mf('ConvertTo-DomeniaLiveObservation'))
    ck('Older network result cannot replace newer timestamp',"$newStamp -ge $oldStamp" in mf('ConvertTo-DomeniaLiveObservation'))
    ck('Cache tooltip includes date and explicit historic marker','Observation historique' in mf('Get-DomeniaLivePresenceView') and 'UTC' in mf('Get-DomeniaLivePresenceView'))
    ck('Filtering recognizes old cache labels',"' \\(cache\\)$'" in mf('Test-DomeniaPresenceMatch') and 'Hors ligne' in mf('Test-DomeniaPresenceMatch'))
    ck('Ping-only does not present previous user as fresh',"-Cached:([string]$result.Outcome -eq 'PresenceOnly')" in uf('Complete-DomeniaLiveProbe'))
    ck('Association time is user observation, not ping', '$Observation.ObservedUtc' in uf('Merge-DomeniaLiveLinkMemory'))
    ck('Only new ping date marks the result fresh',"if (Get-DomeniaLiveField $result 'PresenceCheckedUtc')" in uf('Complete-DomeniaLiveProbe'))
    ck('Early presence respects context and GUID',all(t in uf('Complete-DomeniaLivePresence') for t in ['Test-DomeniaLiveIdentity','$State.Key','$State.Guid']))
    ck('Early presence UI work bounded to 4 packets','$i -lt 4' in uf('Invoke-DomeniaLiveTick'))
    ck('Ping-only is credential free in worker context','"LiveSelectedPing"' in f('Get-WorkerContext'))
    ck('Ping access scope is separate',"'LiveSelectedPing'" in read(R/'wad/modules/Domenia-Access.UI.ps1') and "return 'Presence'" in read(R/'wad/modules/Domenia-Access.UI.ps1'))
    ck('Global favorite leaves OU intact',"if($mode -eq 'OU'){$script:SelectedBranchDn=[string]$v.DN}" in getfunc(gu,'Load-DomeniaFavouriteSearch'))
    x=literals(f('Get-MainXaml'))[0];tree=ET.fromstring(x);W='{http://schemas.microsoft.com/winfx/2006/xaml/presentation}';X='{http://schemas.microsoft.com/winfx/2006/xaml}'
    names={e.get(X+'Name'):e for e in tree.iter() if e.get(X+'Name')};parent={c:p for p in tree.iter() for c in p}
    for n in ['CmbGlobalType','CmbPresenceFilter','TxtSuiteResultFilter']:
        e=names[n];a=parent[e];triggers=a.findall('.//'+W+'DataTrigger')
        ck('Global disables filter ancestor '+n,any(t.get('Value')=='Global' and 'SearchBrowserLayout' in t.get('Binding','') and any(s.get('Property')=='IsEnabled' and s.get('Value')=='False' for s in t.findall(W+'Setter')) for t in triggers))
    for n in ['BtnSearchInOu','TxtGlobalSearch','DgObjects','BtnLiveRecheck','ChkLiveUsers','TvDirectory']:ck('Control and help retained '+n,n in names and bool(names[n].get('ToolTip')))
    cols=list(names['DgObjects'].find(W+'DataGrid.Columns'));ck('18 named columns retained',len(cols)==18 and all(e.get('Header') for e in cols))
    net=[e for e in cols if e.get('SortMemberPath')=='Presence'];ck('Presence keeps stable layout key',len(net)==1 and net[0].get('Header')=='Présence réseau')
    ck('Presence tooltip binds only network detail',bool(net) and any(e.get('ToolTip')=='{Binding PresenceDetail}' for e in net[0].iter()))
    cat=json.loads(read(R/'wad/modules/Domenia-UX.help.json'));ck('New scoped button is in help catalog','BtnSearchInOu' in {e['Name'] for e in cat})
    operations=json.loads(read(R/'tools/operation-contracts.json'));reg=dict(re.findall(r'(\w+)\s*=\s*"([A-F0-9]{64})"',f('Get-DomeniaWorkerOperationHashes')))
    ck('55 registered workers and contracts',len(operations)==55 and len(reg)==55)
    for op in operations:
        fn=getfunc(read(R/op['File']),op['Function']);body=literals(fn)[op['LiteralIndex']];ck('Exact worker hash '+op['Operation'],sha(body).upper()==op['Sha256']==reg[op['Operation']])
    loader=read(R/'wad/Domenia-Modules.ps1');plans=re.findall(r"File='([^']+)'; DotSource=\$(?:true|false); Functions=@\((.*?)\)\s*\}",loader,re.S)
    ck('20 explicit module plans',len(plans)==20)
    for name,body in plans:ck('Module exports exact '+name,set(re.findall(r"'([^']+)'",body))==set(functions(read(R/'wad/modules'/name))))
    native=read(R/'wad/tests/Test-DomeniaSearchPresence.ps1');ck('Native tests use AST only','Parser]::ParseFile' in native and "Invoke-Expression $nodes[0].Extent.Text" in native)
    ck('Network doubles explicit','Unexpected native object' in native and 'No LDAP request is permitted' in native)
    for rel in ['wad/tests/Test-DomeniaSearchPresence.ps1','wad/tests/Test-DomeniaSelection.ps1','wad/tests/Test-DomeniaSearchScope.ps1','wad/tests/Test-DomeniaStreaming.ps1','wad/maintenance/Preview-DomeniaUi.ps1','wad/maintenance/Preview-DomeniaProgress.ps1','INSTALLER-MISE-A-JOUR.ps1']:ck('Lexical delimiters '+rel,lambda rel=rel:balanced(read(R/rel)))
    installer=read(R/'INSTALLER-MISE-A-JOUR.ps1');ck('Native test gated before install',"'Test-DomeniaSearchPresence.ps1'" in installer and 'Skipped' in installer)
    ck('PROD required runtime excludes tests','tests' not in read(R/'wad/Domenia-Start.ps1').split('$entries=')[0].lower())
    ck('Build label core RC1.4','2026.10.01-DOMENIA-1.0-RC1.4-SEARCH' in c)
    ck('Historical source base unchanged',bool(base['CoreFunctions']))
    oldops={e['Operation']:e['Sha256'] for e in base['Operations']};changedops=[e['Operation'] for e in operations if e['Operation'] in oldops and e['Sha256']!=oldops[e['Operation']]]
    result={'Build':'2026.10.01-DOMENIA-1.0-RC1.4-SEARCH','Environment':'Linux/Python source, XML and contract inspection','Passed':sum(e['Passed'] for e in checks),'Failed':sum(not e['Passed'] for e in checks),'Checks':checks,'OriginalCoreFunctions':len(base['CoreFunctions']),'PreservedCoreFunctions':len(base['CoreFunctions'])-len(changed),'ChangedCoreFunctions':changed,'AddedCoreFunctions':sorted(set(now)-set(base['CoreFunctions'])),'ChangedExistingWorkers':changedops,'NewWorkers':sorted(set(reg)-set(oldops)),'NativeTestScenariosWritten':len(re.findall(r"(?m)^\s*Case '",native)),'WindowsPowerShellExecuted':False,'WpfExecuted':False,'LiveADExecuted':False,'LivePingExecuted':False}
    args.report.parent.mkdir(parents=True,exist_ok=True);args.report.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps({k:v for k,v in result.items() if k not in ['Checks','ChangedCoreFunctions']},ensure_ascii=False,indent=2))
    for e in checks:
        if not e['Passed']:print('FAIL',e)
    return 1 if result['Failed'] else 0
if __name__=='__main__':sys.exit(main())
