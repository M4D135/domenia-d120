#!/usr/bin/env python3
"""Source/XML/integrity checks for R1.9; not a PowerShell/WPF/LDAP execution."""
from pathlib import Path
import argparse,hashlib,json,re,xml.etree.ElementTree as ET
from powershell_lex import functions,mask_ps
from audit_ui import window_controls,assert_scoped_names,local

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--root',type=Path,default=Path(__file__).resolve().parents[2])
    ap.add_argument('--report',type=Path,default=Path('/tmp/domenia-search-scope.json'))
    args=ap.parse_args();root=args.root
    core=(root/'wad/Domenia-Core.ps1').read_text(encoding='utf-8-sig');fs=functions(core)
    base=json.loads((root/'wad/tests/search-baseline-dev.json').read_text())
    sha=lambda x:hashlib.sha256(x.encode() if isinstance(x,str) else x).hexdigest()
    def f(n):a,b=fs[n][0];return core[a:b]
    checks=[]
    def check(name,condition,detail=''):
        try:
            value=condition() if callable(condition) else condition
            if value is False: raise AssertionError(detail or 'Condition non verifiee')
            result={'Name':name,'Status':'PASS','Detail':''}
        except Exception as ex:result={'Name':name,'Status':'FAIL','Detail':str(ex)}
        checks.append(result);print(result['Status'],name,result['Detail'])
    def delimiters(s):
        m,issues=mask_ps(s)
        if issues: raise AssertionError(str(issues))
        stack=[];pairs={')':'(',']':'[','}':'{'}
        for ch in m:
            if ch in '([{':stack.append(ch)
            elif ch in pairs:
                if not stack or stack.pop()!=pairs[ch]:raise AssertionError('Delimiteur non equilibre')
        if stack:raise AssertionError('Delimiteur non ferme')
    check('All original core functions retained',set(base['Functions'])<=set(fs))
    check('No duplicate top-level function',all(len(v)==1 for v in fs.values()))
    changes={n for n,h in base['Functions'].items() if sha(f(n))!=h}
    check('Only reviewed functions changed against dev.zip',changes==set(base['AllowedChanges']))
    check('Only the six search helpers added',set(fs)-set(base['Functions'])==set(base['AddedFunctions']) and len(base['AddedFunctions'])==6)
    check('Login engine exact normalized source preserved',all(sha(f(n))==h for n,h in base['Functions'].items() if re.search(r'Auth|Login|Credential',n)))
    check('Worker common body byte-equivalent after newline normalization',sha(re.search(r"(?ms)^\$script:WorkerCommon = @'\n(.*?)\n'@",core)[1])==base['InputWorkerCommonSha256'])
    for rel,h in base['PreservedFiles'].items():check('Preserved '+rel,sha((root/rel).read_bytes())==h)
    for rel in ['wad/Domenia-Core.ps1','wad/modules/Domenia-UX.UI.ps1','wad/maintenance/Preview-DomeniaUi.ps1','wad/tests/Test-DomeniaSearchScope.ps1','INSTALLER-MISE-A-JOUR.ps1']:
        text=(root/rel).read_text(encoding='utf-8-sig');check('Approximate delimiters '+rel,lambda s=text:delimiters(s));check('UTF8 BOM '+rel,(root/rel).read_bytes().startswith(b'\xef\xbb\xbf'))
    x=(root/'wad/Domenia-Main.xaml').read_text(encoding='utf-8-sig');r=ET.fromstring(x);controls=window_controls(r)
    check('XAML namescopes unique',lambda:assert_scoped_names(r))
    ns='{http://schemas.microsoft.com/winfx/2006/xaml/presentation}';xn='{http://schemas.microsoft.com/winfx/2006/xaml}Name'
    names={e.get(xn) for e in controls['WsSearch'].iter()}
    check('Real tree and real result grid share WsSearch',{'TvDirectory','DgObjects','ChkSubtree','TxtBranchDn','BtnSearchAllDomain'}<=names)
    check('No independent directory page or sidebar entry','TabDirectory' not in controls and 'BtnUxNavDirectory' not in controls)
    grid=controls['SearchBrowserLayout'];children=[e for e in grid if local(e)!='Grid.ColumnDefinitions']
    check('Tree left / splitter / results right',[e.get('Grid.Column') for e in children]==['0','1','2'])
    check('Splitter preserves both panel sizing',controls['SearchOuSplitter'].get('ResizeBehavior')=='PreviousAndNext')
    check('Subtree checkbox initially checked',controls['ChkSubtree'].get('IsChecked')=='True')
    def visible_ancestry(target):
        def walk(e,hidden=False):
            hidden=hidden or e.get('Visibility') in ('Collapsed','Hidden')
            if e is target:return not hidden
            for c in e:
                value=walk(c,hidden)
                if value is not None:return value
            return None
        return walk(r)
    check('Scope control is not hidden in the old legacy block',lambda:visible_ancestry(controls['ChkSubtree']))
    keys={e.get('{http://schemas.microsoft.com/winfx/2006/xaml}Key') for e in r.iter()}
    implicit={e.get('TargetType') for e in r.iter() if local(e)=='Style' and not e.get('{http://schemas.microsoft.com/winfx/2006/xaml}Key')}
    refs=set(re.findall(r'\{StaticResource\s+(\{x:Type\s+\w+\}|[^{}]+)\}',x))
    check('All static resource references resolved',all(v in keys or (v.startswith('{x:Type ') and v[8:-1] in implicit) for v in refs))
    cat={e['Name']:e for e in json.loads((root/'wad/modules/Domenia-UX.help.json').read_text(encoding='utf-8-sig'))}
    for n in ['BtnSearchAllDomain','SearchOuSplitter','ChkSubtree','TvDirectory','CmbGlobalType']:
        e=controls[n];check('Accessible explanation '+n,n in cat and bool(e.get('ToolTip')) and bool(e.get('AutomationProperties.HelpText')))
    body=f('Invoke-GlobalSearch');w=re.search(r"\$code = @'\n(.*?)\n'@",body,re.S)[1]
    check('Worker root is Payload.BaseDn','New-WSearcher $ctx ([string]$Payload.BaseDn)' in w and 'New-WSearcher $ctx ([string]$Context.BaseDn)' not in w)
    check('Worker depth is Payload.Scope','@($Payload.Properties) ([string]$Payload.Scope)' in w)
    check('No silent root fallback in worker', 'if ([string]::IsNullOrWhiteSpace([string]$Payload.BaseDn)) { throw' in w)
    check('Only supported depths accepted','[string]$Payload.Scope -notin @("Subtree","OneLevel")' in w)
    check('Worker result identifies root and scope','BaseDn=[string]$Payload.BaseDn' in w and 'Scope=[string]$Payload.Scope' in w)
    check('Groups and OU allowed in the result', '"Utilisateur","Machine","Groupe","OU","Conteneur"' in w)
    check('Local previews skipped outside whole-domain subtree','$scope.IsDomain -and $scope.Scope -eq "Subtree"' in body)
    check('Cache segregates root and depth','scoped-v19|$serverKey|$baseKey|$($scope.Scope)|' in body)
    check('Result state validates root depth text type generation',all(a in f('Test-DomeniaSearchStateCurrent') for a in ['$State.Generation','$State.BaseDn','$State.Scope','$State.TypeFilter','$State.Search']))
    check('Both success/error reject stale scope',all('Test-DomeniaSearchStateCurrent -State $State' in f(n) for n in ['Complete-DomeniaGlobalSearchUi','Fail-DomeniaGlobalSearchUi']))
    check('Tree selection uses unified query','Invoke-DomeniaSearchFilterChanged' in f('Set-SelectedBranch'))
    check('Old branch actions use unified worker','Invoke-GlobalSearch' in f('Load-BranchObjects') and 'Start-UiTask' not in f('Load-BranchObjects'))
    check('New filter controls included in write lock set',all('"'+n+'"' in f('Start-DomeniaWriteTask') for n in ['BtnSearchAllDomain','ChkSubtree','CmbGlobalType']))
    check('No extra write operation in new helpers',not any(re.search(r'(?i)(Set-AD(?!cc)|Remove-AD(?!cc)|WriteAttributes|Start-DomeniaWriteTask)',f(n)) for n in base['AddedFunctions']))
    check('Reset domain preserves query text','TxtGlobalSearch' not in f('Reset-DomeniaSearchScope'))
    check('Startup suppression honored before querying','if ($script:SuppressBranchAutoLoad) { return }' in f('Set-SelectedBranch'))
    check('Checkbox and type filter changes trigger query',all(v in f('Wire-Events') for v in ['["ChkSubtree"].Add_Checked({ Invoke-DomeniaSearchFilterChanged })','["ChkSubtree"].Add_Unchecked({ Invoke-DomeniaSearchFilterChanged })','["CmbGlobalType"].Add_SelectionChanged({ Invoke-DomeniaSearchFilterChanged })']))
    check('Explicit searches do not preserve an old selection','if ($PreserveSelection)' in body and 'PreserveSelectionDn = $preserveDn' in body)
    reg=dict(re.findall(r'(\w+)\s*=\s*"([A-F0-9]{64})"',f('Get-DomeniaWorkerOperationHashes')))
    literals={sha(m[1]).upper() for m in re.finditer(r"@'\n(.*?)\n'@",core,re.S)}
    check('All 45 active pinned workers resolve to exact literals',len(reg)==45 and set(reg.values())<=literals)
    check('New search worker matches pinned hash',sha(w).upper()==reg['GlobalSearch'])
    check('Retired separate branch worker is not registered','BranchObjects' not in reg)
    check('Engine startup count agrees with registry','$registry.Count -ne 45' in f('Initialize-AsyncEngine'))
    preview=(root/'wad/maintenance/Preview-DomeniaUi.ps1').read_text(encoding='utf-8-sig')
    check('Preview remains offline and uses actual XAML','$presentationNames = @(' in preview and '[Management.Automation.Language.Parser]::ParseFile($corePath' in preview and '& $corePath' not in preview and '. $corePath' not in preview)
    check('Preview includes OU synthetic filter interactions',all(v in preview for v in ['OU=Marseille','Reset-DomeniaSearchScope','function Invoke-DomeniaSearchFilterChanged']))
    installer=(root/'INSTALLER-MISE-A-JOUR.ps1').read_text(encoding='utf-8-sig')
    check('Native search tests run before backup/copy',installer.index('$searchTests=')<installer.index('$backupParent=') and 'searchResult.Passed -lt 42' in installer)
    tests=(root/'wad/tests/Test-DomeniaSearchScope.ps1').read_text(encoding='utf-8-sig')
    count=len(re.findall(r'^Test-Case ',tests,re.M));check('42 isolated PowerShell cases provided',count==42)
    check('Native tests load only fixed function definitions', '$nodes[0].Extent.Text' in tests and '$names=@(' in tests and '& $core' not in tests)
    report={'Build':'2026.09.30-R1.9-OUSEARCH','Environment':'Linux/Python','PowerShellExecuted':False,'WpfExecuted':False,'LiveAdExecuted':False,'NativeScenariosProvidedNotExecuted':count,'ChangedFunctions':sorted(changes),'UnchangedOriginalFunctions':len(base['Functions'])-len(changes),'Passed':sum(c['Status']=='PASS' for c in checks),'Failed':sum(c['Status']=='FAIL' for c in checks),'Checks':checks}
    args.report.parent.mkdir(parents=True,exist_ok=True);args.report.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps({k:report[k] for k in ['Passed','Failed','UnchangedOriginalFunctions']}));return int(report['Failed']>0)
if __name__=='__main__':raise SystemExit(main())
