#!/usr/bin/env python3
"""Source/XML/contract checks for RC1.8. This is NOT a PowerShell or WPF execution."""
from pathlib import Path
import argparse, hashlib, json, re, sys, functools, xml.etree.ElementTree as E
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'wad/tests'))
from powershell_lex import functions as raw_functions
functions=functools.lru_cache(maxsize=128)(raw_functions)
def getfunc(source,name):
    found=functions(source).get(name,[])
    if len(found)!=1:raise ValueError(name)
    a,b=found[0];return source[a:b]
from audit_activity_layout import lexically_balanced
W='{http://schemas.microsoft.com/winfx/2006/xaml/presentation}'
X='{http://schemas.microsoft.com/winfx/2006/xaml}'
def read(p):return p.read_text('utf-8-sig')
def sha(v):return hashlib.sha256(v.encode() if isinstance(v,str) else v).hexdigest().upper()
def literal(code):return re.search(r'@([\'"])\n(.*?)\n^\1@',code,re.M|re.S)[2]
def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--report',type=Path,required=True);args=ap.parse_args();checks=[]
    def ck(name,value,kind='Source'):
        try:
            ok=value() if callable(value) else value
            if not ok:raise ValueError('Condition false')
            checks.append(dict(Name=name,Passed=True,Kind=kind))
        except Exception as e:checks.append(dict(Name=name,Passed=False,Kind=kind,Error=str(e)))
    c=read(ROOT/'wad/Domenia-Core.ps1');r=read(ROOT/'wad/modules/Domenia-Relations.UI.ps1');access=read(ROOT/'wad/modules/Domenia-Access.UI.ps1')
    base=json.loads(read(ROOT/'wad/docs/RC1.8-baseline.json'))
    f=functions(c);changed=[n for n,h in base['CoreFunctions'].items() if n not in f or sha(getfunc(c,n))!=h]
    ck('All original core functions retained',set(f)==set(base['CoreFunctions']),'Hash')
    allowed={'Get-MainXaml','Initialize-DomeniaPresentation','Get-DomeniaUserComputersWorkerCode','Complete-DomeniaUserComputersUi','Fail-DomeniaUserComputersUi','Start-DomeniaUserComputerProbe','Update-DomeniaLinkActionUi','Refresh-LinkGrid','Wire-Events','Queue-DomeniaSelectedObjectOpen','Show-AdObjectResult','Add-SelectedLink','Remove-SelectedLink','Export-DomeniaLinksCsv','Show-DomeniaCommandPalette','Add-UserMachineLinkIfMissing','Get-WorkerContext','Get-DomeniaWorkerOperationHashes','Assert-DomeniaWorkerRegistry'}
    ck('Only reviewed core functions modified',set(changed)<=allowed,'Hash')
    for n in ['Invoke-DomeniaInProcessAuthProbe','Get-DomeniaStandardLoginXaml','Set-DomeniaFastLoginBusy','Update-TaskUi','Invoke-GlobalSearch','Get-DomeniaSearchScope','Test-DomeniaSearchStateCurrent','Assert-DomeniaCapability','Start-DomeniaWriteTask','Set-Status']:
        if n in base['CoreFunctions']:ck('Unchanged behavior: '+n,sha(getfunc(c,n))==base['CoreFunctions'][n],'Hash')
    allowed_runtime={'wad/Domenia-Core.ps1','wad/Domenia-Modules.ps1','wad/modules/Domenia-Access.UI.ps1','wad/modules/Domenia-UX.help.json'}
    for path,h in base['Runtime'].items():
        if path not in allowed_runtime:ck('Unchanged runtime bytes: '+path,sha((ROOT/path).read_bytes())==h,'Hash')
    for path in ['wad/Domenia-Core.ps1','wad/Domenia-Modules.ps1','wad/modules/Domenia-Relations.UI.ps1','wad/modules/Domenia-Access.UI.ps1','wad/tests/Test-DomeniaRelationsAlignment.ps1','wad/tests/Test-DomeniaModules.ps1','INSTALLER-MISE-A-JOUR.ps1']:
        ck('Approximate lexical delimiters: '+path,lambda path=path:lexically_balanced(read(ROOT/path)),'Lexical')
        ck('Windows PowerShell BOM: '+path,(ROOT/path).read_bytes().startswith(b'\xef\xbb\xbf'),'Encoding')
    xml=E.fromstring(literal(getfunc(c,'Get-MainXaml')));names={e.get(X+'Name'):e for e in xml.iter() if e.get(X+'Name')};parents={ch:p for p in xml.iter() for ch in p}
    strip=names['UxActivityStrip'];label=names['LblTaskElapsed'];ph=names['UxSearchPlaceholder'];box=names['TxtGlobalSearch']
    ck('Activity dimensions remain 44 fixed',all(strip.get(k)=='44' for k in ['Height','MinHeight','MaxHeight']),'XML')
    ck('Activity label occupies first flexible cell',label.get('Grid.Column')=='0' and list(strip.find(W+'Grid.ColumnDefinitions'))[0].get('Width')=='*','XML')
    ck('Activity text explicitly left aligned',label.get('TextAlignment')=='Left' and label.get('TextWrapping')=='NoWrap','XML')
    ck('Write warning retains independent fixed slot',names['WriteModeBanner'].get('Grid.Column')=='1' and list(strip.find(W+'Grid.ColumnDefinitions'))[1].get('Width')=='252','XML')
    ck('Progress and cancel reserve positions',all(names[n].get('Visibility')=='Hidden' for n in ['PbTop','BtnCancelTask','LblTaskElapsed']),'XML')
    ck('Counter button widths retained',names['BtnSuiteActivity'].get('Width')=='144' and names['BtnAccessRecovery'].get('Width')=='108','XML')
    template=box.find('.//'+W+'ControlTemplate');host=template.find('.//*[@'+X+'Name'+"='PART_ContentHost']")
    ck('Search TextBox has dedicated template',template is not None and host is not None,'XML')
    ck('Scroll host padding is not doubled by margin',host.get('Margin')=='0','XML')
    ck('Placeholder shares textbox padding',parents[ph].get('Margin')=='{TemplateBinding Padding}','XML')
    ck('Placeholder shares TextBoxView caret margin',ph.get('Margin')=='{Binding Content.Margin, ElementName=PART_ContentHost}','XML')
    ck('Placeholder cannot intercept clicks',ph.get('IsHitTestVisible')=='False','XML')
    for n in ['FontFamily','FontSize','FontWeight','FontStretch','TextAlignment']:
        ck('Placeholder inherits '+n,ph.get(n)=='{TemplateBinding '+n+'}','XML')
    relation=names['RelationTabs'];tabs=relation.findall(W+'TabItem')
    ck('Four distinct relationship tabs',[t.get(X+'Name') for t in tabs]==['TabLinksSelected','TabLinksAll','TabLinksDiscovery','TabLinksAttempts'],'XML')
    ck('Selected link grid belongs to first tab',names['DgLinks'] in set(tabs[0].iter()),'XML')
    ck('All link grid belongs only to all tab',names['DgAllLinks'] in set(tabs[1].iter()),'XML')
    ck('No automatic scan default',names['ChkUserScanPark'].get('IsChecked')=='False','XML')
    ck('Security event query opt-in',names['ChkRelationEvents'].get('IsChecked')=='False','XML')
    ck('Explicit bounded scan default 20',names['TxtRelationScanLimit'].get('Text')=='20','XML')
    ck('Scope choices explicit',[n.get('Tag') for n in names['CmbRelationScanScope'].findall(W+'ComboBoxItem')]==['Candidates','Loaded','OU'],'XML')
    for name in ['TabLinksSelected','TabLinksAll','TabLinksDiscovery','TabLinksAttempts','DgAllLinks','DgRelationCandidates','BtnRelationsStop','BtnRelationAdopt','BtnRelationOpenCandidate','CmbRelationScanScope','TxtRelationScanLimit','ChkRelationEvents']:
        ck('New control help/accessibility: '+name,all(names[name].get(k) for k in ['ToolTip','AutomationProperties.Name','AutomationProperties.HelpText']),'XML')
    keys={x.get(X+'Key') for x in xml.iter() if x.get(X+'Key')};refs={k for x in xml.iter() for v in x.attrib.values() for k in re.findall(r'\{StaticResource ([^{}]+)\}',v)}
    ck('Explicit static resources resolved',refs<=keys,'XML')
    ck('No child GotFocus handler resets links to All','TabRelations"].Add_GotFocus' not in c and "TabRelations'].Add_GotFocus" not in c)
    ck('Legacy all flag cannot override selected tab','Refresh-DomeniaRelationViews' in getfunc(c,'Refresh-LinkGrid') and '-All' not in getfunc(c,'Refresh-LinkGrid'))
    ck('Single-click captures relation selection without fiche','Set-DomeniaRelationsGridSelection;Select-DomeniaLiveResult;return' in getfunc(c,'Queue-DomeniaSelectedObjectOpen'))
    ck('Loaded fiche passes immutable original entry','Set-DomeniaRelationsSelection -Object $script:SelectedObject' in getfunc(c,'Show-AdObjectResult'))
    sel=getfunc(r,'Get-DomeniaRelationsSelectedLinks')
    ck('Selected links use login or machine match','Get-LinksForUser $s.Login' in sel and 'Get-LinksForComputer $s.Name' in sel)
    ck('GUID of recreated user does not match old link','$guid -ine $s.Guid' in sel)
    guard=getfunc(r,'Test-DomeniaRelationsCurrent')
    for fragment in ['SessionEpoch','BaseDn','Generation','RequestId','Guid','Login','AcceptResults','Identity']:
        ck('Late result guard includes '+fragment,fragment in guard)
    init=getfunc(r,'Initialize-DomeniaRelationsUi')
    ck('No network job started by UI initialization','Start-UiTask' not in init and '.Start()' not in init and 'Start-DomeniaRelationsSearch' not in init)
    ck('Timer released with window','Add_Closed' in init and 'Timer.Stop()' in init)
    start=getfunc(r,'Start-DomeniaRelationsSearch')
    ck('Explicit scan asks consent','if($scan)' in start and 'Confirm-Action' in start)
    ck('Scan count input limited 1..50','$limit -lt 1 -or $limit -gt 50' in start)
    ck('User DN/GUID immutable payload','UserDn=$s.DN;UserGuid=$s.Guid' in start)
    ck('Known associations seed worker','KnownLinks=@($known' in start)
    ck('Progress delivered through concurrent queue','ConcurrentQueue[object]' in start and '-CallbackState $state' in start)
    tick=getfunc(r,'Invoke-DomeniaRelationsTick')
    ck('Progress work per tick bounded','$n -lt 8' in tick and '$watch.ElapsedMilliseconds -lt 4' in tick)
    ck('Progress skips full association grids','Refresh-DomeniaRelationViews -ProgressOnly' in tick)
    ck('Canceled job results disallowed','$job.CancelRequested' in tick and '$q.AcceptResults=$false' in tick)
    save=getfunc(r,'Save-DomeniaRelationConfirmations')
    ck('Only confirmed exact AD computer saved','Confirmed -eq $true -and $_.Guid -and $_.DN' in save)
    ck('Manual link wins over observation','Saisie manuelle|Manual' in save and 'continue' in save)
    ck('Writer busy defers save','$script:Persistence.LinkBusy' in save and 'PendingConfirmed' in save)
    ck('Failed queue keeps old array','$script:UserMachineLinks=$before' in save)
    ck('One batched save not one transaction per host',save.count('Save-UserMachineLinks')==1)
    complete=getfunc(r,'Complete-DomeniaRelationsSearch')
    ck('Refusal details separate per source',"@('Directory','Remote')" in complete and '-Target $target' in complete)
    ck('Does not assert universal empty mapping','ne possède aucun poste' in complete)
    ck('Remote error has actual target parameter','[string]$Target=' in getfunc(access,'Request-DomeniaAccessRecovery'))
    ck('Inverse directory operation independent from remote fault',"if($OperationId -eq 'UserComputerProbe'){return 'AD:UserComputerProbe'}" in getfunc(access,'Get-DomeniaAccessScope'))
    worker=literal(getfunc(r,'Get-DomeniaRelationsWorkerCode'))
    ck('Worker lexical delimiters',lambda:lexically_balanced(worker),'Lexical')
    ck('Worker does not import alternate-credential guessing','Resolve-WBoundContext' not in worker)
    ck('Credential explicitly obtained','$credential=Get-WMachineCredential $Context' in worker and '$params.Credential=$credential' in worker)
    ck('DCOM only without WSMan alternative','-Protocol Dcom' in worker and 'WSMan' not in worker)
    ck('No ping or TCP gate',not re.search(r'Test-WPing|SendPing|Ping\]|Test-WTcp|TcpClient',worker))
    ck('No script/task/service fallback',not re.search(r'Invoke-WTaskPowerShell|Invoke-WPsExec|schtasks|ADMIN\$|LogonUI|LastLoggedOn',worker))
    ck('One console method with known limit',"-ClassName Win32_ComputerSystem" in worker and 'sessions RDP non recensées' in worker)
    ck('Names checked before remote assignment','$cs.Name -ine $c.Computer' in worker)
    ck('Exact domain qualification required',"$netbios+'\\'+$login" in worker and "$domain+'\\'+$login" in worker and '$current -ieq $upn' in worker)
    ck('Resource budget and progress queue bounded','Progress.Count -lt 256' in worker and '$probed -ge $limit' in worker)
    ck('Auth rejection stops further remote submissions',"$kind -eq 'AUTH_REJETEE'" in worker and '$remoteStopped=$true' in worker)
    ck('Auth rejection stops further LDAP submission','RelationDirectoryBlocked' in worker and 'Canal AD suspendu' in worker)
    ck('All CIM sessions are disposed in finally','finally{if($null -ne $session){Remove-CimSession' in worker)
    ck('AD collections/searchers/roots disposed',all(x in worker for x in ['$collection.Dispose()','$s.Dispose()','$owned.Dispose()']))
    ck('AD page bound and timeout explicit','$s.PageSize=40;$s.CacheResults=$false' in worker and '$s.ClientTimeout=[timespan]::FromSeconds(10)' in worker)
    ck('ManagedBy/description are not session assertions',"$Status='Indice AD'" in worker and 'Confirmed=$false' in worker)
    ck('No historical timestamp rejuvenation on failure',".ObservedUtc=[string]$known.When" in worker)
    ck('IP from security event preserved, not split',"$ip=[string]$d.IpAddress" in worker and "$ip.Split" not in worker and "Guid=''" in worker)
    ck('DC event selection by exact SID',"FilterXPath=$xpath" in worker and "Data[@Name='TargetSid']='$userSid'" in worker)
    ck('Security events use AD not machine credential','$adCredential=Get-WAdCredential $Context' in worker)
    ck('No ConcurrentQueue.Clear unavailable on desktop framework','Progress.Clear()' not in r)
    ck('Loaded and OU scans use only the approved GUID subset','$probeKeys.Add' in worker and "if($mode -eq 'Candidates')" in worker and '$items[$_]' in worker)
    ck('No whole-domain machine sweep unless OU explicitly chosen',"$mode -eq 'OU'" in worker and 'OU hors du domaine courant' in worker)
    plan=read(ROOT/'wad/Domenia-Modules.ps1');expected=list(functions(r));m=re.search(r"File='Domenia-Relations.UI.ps1'.*?Functions=@\((.*?)\) \}",plan,re.S);exports=re.findall(r"'([\w-]+)'",m[1])
    ck('Closed loader includes exactly all new functions',set(exports)==set(expected) and len(exports)==len(expected),'Contract')
    ck('Loader imports new module in caller scope',"File='Domenia-Relations.UI.ps1'; DotSource=$true" in plan,'Contract')
    contracts=json.loads(read(ROOT/'tools/operation-contracts.json'));registry=dict(re.findall(r'(\w+)\s*=\s*"([A-F0-9]{64})"',getfunc(c,'Get-DomeniaWorkerOperationHashes')))
    ck('Registry remains 55 operations',len(contracts)==len(registry)==55,'Contract')
    for op in contracts:
        source=getfunc(read(ROOT/op['File']),op['Function']);lits=[x[2] for x in re.finditer(r'@([\'"])\n(.*?)\n^\1@',source,re.S|re.M)];body=lits[op['LiteralIndex']]
        ck('Pinned operation body: '+op['Operation'],sha(body)==op['Sha256']==registry[op['Operation']],'Hash')
    test=read(ROOT/'wad/tests/Test-DomeniaRelationsAlignment.ps1');installer=read(ROOT/'INSTALLER-MISE-A-JOUR.ps1')
    ck('New native suite wired before install',installer.count("'Test-DomeniaRelationsAlignment.ps1'")==2)
    ck('Native tests explicit 65 scenarios','$expected=65' in test and len(re.findall(r"Case '\d\d ",test))==53 and len(re.findall(r'Case \(\$theme',test))==6)
    ck('Native tests use real AST without app bootstrap','ParseFile' in test and 'Import-SourceFunction $core' in test and '. (Join-Path $wad \'Domenia-Core.ps1\')' not in test)
    ck('Native fixtures intercept remote operations','function New-WSearcher' in test and 'function New-CimSession' in test and 'function Get-WinEvent' in test)
    ck('Native WPF tests measure character geometry','GetRectFromCharacterIndex(0)' in test and 'TranslatePoint' in test)
    ck('Native suite fails on skipped/incomplete count','$script:Cases.Count -eq $expected' in test and 'Skipped=0' in test)
    result=dict(Build='2026.10.01-DOMENIA-1.0-RC1.8-RELATIONS',Environment='Linux/Python source/XML checks',Passed=sum(x['Passed'] for x in checks),Failed=sum(not x['Passed'] for x in checks),CoreFunctions=len(f),ChangedCoreFunctions=changed,PreservedCoreFunctions=len(f)-len(changed),NewRuntimeFunctions=exports,PinnedOperations=len(contracts),WindowsPowerShellExecuted=False,WpfExecuted=False,LiveADExecuted=False,NativeTestsProvided=65,Checks=checks)
    args.report.parent.mkdir(parents=True,exist_ok=True);args.report.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n','utf-8')
    print(json.dumps({k:v for k,v in result.items() if k not in ['Checks','NewRuntimeFunctions']},ensure_ascii=False,indent=2))
    for x in checks:
        if not x['Passed']: print('FAIL',x)
    return 1 if result['Failed'] else 0
if __name__=='__main__':raise SystemExit(main())
