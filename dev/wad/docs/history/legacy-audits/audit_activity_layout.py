#!/usr/bin/env python3
"""RC1.7 source, XML, contracts and preservation checks. Does not execute PowerShell/WPF."""
from pathlib import Path
import argparse, difflib, hashlib, json, re, sys, functools
import xml.etree.ElementTree as E
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'wad/tests'))
from powershell_lex import functions as raw_functions, mask_ps
functions = functools.lru_cache(maxsize=128)(raw_functions)
BUILD = '2026.10.01-DOMENIA-1.0-RC1.7-FIXEDACTIVITY'
W = '{http://schemas.microsoft.com/winfx/2006/xaml/presentation}'
X = '{http://schemas.microsoft.com/winfx/2006/xaml}'
def read(p): return p.read_text('utf-8-sig')
def sha(b): return hashlib.sha256(b.encode() if isinstance(b,str) else b).hexdigest().upper()
def fn(s, n):
    nodes=functions(s).get(n,[])
    if len(nodes)!=1: raise ValueError('Function absent/ambiguous: '+n)
    return s[nodes[0][0]:nodes[0][1]]
def literal(s): return re.search(r'@"\n(.*?)\n"@',s,re.S)[1]
def lexically_balanced(s):
    s=s.translate(str.maketrans({'\u2018':"'",'\u2019':"'",'\u201c':'"','\u201d':'"'}))
    t, errors=mask_ps(s)
    if errors: raise ValueError(errors)
    stack=[];pairs={')':'(',']':'[','}':'{'}
    for c in t:
        if c in '([{':stack.append(c)
        elif c in pairs:
            if not stack or stack.pop()!=pairs[c]: raise ValueError('Unbalanced delimiters')
    if stack: raise ValueError('Unclosed delimiters')
    return True

def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--report',type=Path,required=True);a=ap.parse_args()
    checks=[]
    def ck(n, condition, kind='Source'):
        try:
            ok=condition() if callable(condition) else condition
            if not ok: raise ValueError('Condition false')
            checks.append(dict(Name=n,Passed=True,Kind=kind))
        except Exception as e: checks.append(dict(Name=n,Passed=False,Kind=kind,Error=str(e)))
    core=read(ROOT/'wad/Domenia-Core.ps1');base=json.loads(read(ROOT/'wad/docs/RC1.7-baseline.json'))
    f=functions(core);changed={n for n,h in base['CoreFunctions'].items() if n not in f or sha(fn(core,n))!=h}
    ck('Exactly the 577 existing core functions, none added or removed',set(f)==set(base['CoreFunctions']) and len(f)==577,'Hash')
    ck('Only main XAML, task UI and presentation version modified',changed=={'Get-MainXaml','Update-TaskUi','Initialize-DomeniaPresentation'},'Hash')
    ck('574 original function bodies unchanged',len(base['CoreFunctions'])-len(changed)==574,'Hash')
    for rel,h in base['Runtime'].items():
        if rel not in {'wad/Domenia-Core.ps1','wad/modules/Domenia-UX.help.json'}:
            ck('Preserved runtime bytes: '+rel,sha((ROOT/rel).read_bytes())==h,'Hash')
    ck('Core keeps UTF-8 BOM for Windows PowerShell', (ROOT/'wad/Domenia-Core.ps1').read_bytes().startswith(b'\xef\xbb\xbf'))
    for rel in ['wad/Domenia-Core.ps1','INSTALLER-MISE-A-JOUR.ps1','wad/tests/Test-DomeniaActivityLayout.ps1']:
        ck('Lexical delimiters only, not native parser: '+rel,lambda rel=rel:lexically_balanced(read(ROOT/rel)),'Lexical')
    main=E.fromstring(literal(fn(core,'Get-MainXaml')))
    names={e.get(X+'Name'):e for e in main.iter() if e.get(X+'Name')}
    parents={c:p for p in main.iter() for c in p}
    row=names['UxActivityRow'];strip=names['UxActivityStrip'];progress=names['PbTop'];cancel=names['BtnCancelTask'];label=names['LblTaskElapsed']
    ck('Activity row always reserves 44 WPF units', all(row.get(k)=='44' for k in ('Height','MinHeight','MaxHeight')),'XML')
    ck('Activity strip always visible, fixed height and no wrapping parent', strip.tag==W+'Grid' and all(strip.get(k)=='44' for k in ('Height','MinHeight','MaxHeight')) and strip.get('Visibility','Visible')=='Visible','XML')
    ck('No visibility trigger can remove strip',not strip.findall('./'+W+'Grid.Style') and not row.findall('.//'+W+'DataTrigger'),'XML')
    ck('Single fixed strip row index', strip.get('Grid.Row')=='1','XML')
    ck('Columns do not depend on content', [e.get('Width') for e in strip.find(W+'Grid.ColumnDefinitions')]==['252','*','144','96'],'XML')
    ck('Progress, text and cancel are direct children of reserved grid',all(parents[e] is strip for e in [progress,cancel,label]),'XML')
    ck('Progress slot is fixed in both directions',all(progress.get(k)=='130' for k in ('Width','MinWidth','MaxWidth')) and all(progress.get(k)=='8' for k in ('Height','MinHeight','MaxHeight')),'XML')
    ck('Cancel slot is fixed in both directions',all(cancel.get(k)=='96' for k in ('Width','MinWidth','MaxWidth')) and all(cancel.get(k)=='32' for k in ('Height','MinHeight','MaxHeight')),'XML')
    ck('All activity controls reserve space at rest',all(e.get('Visibility')=='Hidden' for e in [progress,cancel,label]),'XML')
    ck('No animation at rest',progress.get('IsIndeterminate')=='False','XML')
    ck('Long task names cannot grow or wrap the row',label.get('TextWrapping')=='NoWrap' and label.get('TextTrimming')=='CharacterEllipsis' and label.get('Height')==label.get('MaxHeight')=='24','XML')
    ck('Full task text available by hover',label.get('ToolTip')=='{Binding Text, RelativeSource={RelativeSource Self}}','XML')
    ck('Warning kept in its own reserved column',names['WriteModeBanner'].get('Grid.Column')=='0' and names['LblWriteMode'].get('Text')=='MODE ECRITURE AD ACTIF','XML')
    ck('Inherited placeholder controls retained', all(n in names for n in ['LblStatus','LblPrivilegeTop','BtnAccountsHeader']),'XML')
    ck('Existing stable counter widths remain 144 and 108',names['BtnSuiteActivity'].get('Width')=='144' and names['BtnAccessRecovery'].get('Width')=='108','XML')
    ck('Activity controls have specific help and accessibility names',all(e.get('ToolTip') and e.get('AutomationProperties.Name') and e.get('ToolTipService.ShowOnDisabled')=='True' for e in [progress,cancel]),'XML')
    keys={e.get(X+'Key') for e in main.iter() if e.get(X+'Key')}
    refs={ref for e in main.iter() for val in e.attrib.values() for ref in re.findall(r'\{StaticResource ([^{}]+)\}',val)}
    ck('Main XAML explicit-key static resources are defined',refs<=keys,'XML')
    ui=fn(core,'Update-TaskUi')
    ck('Controller hides instead of collapsing all three indicators',ui.count('[System.Windows.Visibility]::Hidden')==3 and '[System.Windows.Visibility]::Collapsed' not in ui)
    ck('Controller starts/stops indeterminate animation with tasks', '$progress.IsIndeterminate = ($count -gt 0)' in ui)
    ck('Busy remains a presentation update, no new wait/network/pump', not re.search(r'WaitOne|Start-Sleep|\.Wait\(|UpdateLayout|New-.*Searcher|Start-Process|SendPing|Invoke-Cim',ui))
    ck('Existing refresh throttling and callbacks preserved', all(t in ui for t in ['$refreshMs','LastTaskUiRefresh','Update-DomeniaExperienceActivity -Force:$Force','Request-DomeniaDashboardRefresh']))
    ck('Cancellation handler still wired exactly once',core.count('$script:Ctrl["BtnCancelTask"].Add_Click({ Stop-LatestUiTask })')==1)
    reg=dict(re.findall(r'(\w+)\s*=\s*"([A-F0-9]{64})"',fn(core,'Get-DomeniaWorkerOperationHashes')))
    contracts=json.loads(read(ROOT/'tools/operation-contracts.json'))
    ck('55 unchanged operations',len(reg)==len(contracts)==55,'Hash')
    for e in contracts:
        code=fn(read(ROOT/e['File']),e['Function']);lits=[m[2] for m in re.finditer(r'@([\'"])\n(.*?)\n^\1@',code,re.S|re.M)]
        ck('Unchanged worker: '+e['Operation'],sha(lits[e['LiteralIndex']])==e['Sha256']==reg[e['Operation']],'Hash')
    pin=re.search(r'\$expectedFingerprint\s*=\s*"([A-F0-9]{64})"',fn(core,'Assert-DomeniaWorkerRegistry'))[1]
    ck('Registry pin unchanged and valid',sha('\n'.join(k+'='+reg[k] for k in sorted(reg)))==pin,'Hash')
    for name in ['Get-DomeniaStandardLoginXaml','Set-DomeniaFastLoginBusy','Get-DomeniaStartupXaml','Initialize-AsyncEngine','Wire-Events','Show-LoginWindow','Stop-LatestUiTask','Update-DomeniaWriteModeVisual']:
        ck('Unchanged boundary: '+name,sha(fn(core,name))==base['CoreFunctions'][name],'Hash')
    native=read(ROOT/'wad/tests/Test-DomeniaActivityLayout.ps1');installer=read(ROOT/'INSTALLER-MISE-A-JOUR.ps1')
    ck('Windows tests compare old fixture and real new XAML','RC1.6-PageHeader.xaml.txt' in native and 'XamlReader]::Load' in native and 'Get-MainXaml' in native)
    ck('Windows tests measure neighboring controls and actual slots','TranslatePoint' in native and 'Same-Geometry' in native and "'DgObjects','LogPanel'" in native)
    ck('Windows tests cover 3 widths and both themes','@(1600,960,204),@(1280,800,204),@(960,640,68)' in native and "@('Light','Dark')" in native)
    ck('Windows tests cover busy, long names, elapsed time, write state, selection and returning idle',all(t in native for t in ['0,1,9,10,100,0','999999','texte très long','WriteModeBanner','ReferenceEquals','IsIndeterminate']))
    ck('Windows fixture is old Auto plus WrapPanel', '<RowDefinition Height="Auto"/>' in read(ROOT/'wad/tests/fixtures/RC1.6-PageHeader.xaml.txt') and '<WrapPanel Grid.Row="1"' in read(ROOT/'wad/tests/fixtures/RC1.6-PageHeader.xaml.txt'))
    ck('New Windows suite gates installer before copies',installer.index('Test-DomeniaActivityLayout.ps1')<installer.index('Copy-CodeAtomically $from $to'))
    ck('Incomplete/skipped Windows suite is rejected',installer.count('Test-DomeniaActivityLayout.ps1')==2 and '-not $result.Complete' in installer and '[int]$result.Skipped -ne 0' in installer)
    ck('Preview has only local synthetic jobs, never bootstrap','Set-FakeActivity' in native and 'Install-PreviewMode' in native and 'Start-UiTask' not in native and 'Start-DomeniaLoginAuthRunspace' not in native)
    ck('Preview removes its timer', 'Remove_Tick($script:PreviewTick)' in native and '$script:PreviewTimer.Stop()' in native)
    failed=[c for c in checks if not c['Passed']]
    report=dict(Build=BUILD,Environment='Linux/Python source, XML and hash checks',Passed=len(checks)-len(failed),Failed=len(failed),ChangedCoreFunctions=sorted(changed),PowerShellExecuted=False,WpfExecuted=False,NativeNewScenariosProvided=52,Checks=checks)
    a.report.parent.mkdir(parents=True,exist_ok=True);a.report.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n','utf-8')
    print(json.dumps({k:v for k,v in report.items() if k!='Checks'},ensure_ascii=False,indent=2))
    for c in failed: print('FAIL',c)
    return bool(failed)
if __name__=='__main__':raise SystemExit(main())
