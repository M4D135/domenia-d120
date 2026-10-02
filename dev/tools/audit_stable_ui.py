#!/usr/bin/env python3
"""RC1.6 source/XML/hash regression checks. These checks do NOT run WPF or PowerShell."""
from pathlib import Path
import argparse,hashlib,json,re,sys,functools
import xml.etree.ElementTree as E
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'wad/tests'))
from powershell_lex import functions as raw_functions,mask_ps
functions=functools.lru_cache(maxsize=64)(raw_functions)
def read(p):return p.read_text('utf-8-sig')
def sha(s):return hashlib.sha256(s.encode() if isinstance(s,str) else s).hexdigest().upper()
def fn(s,n):
    entries=functions(s).get(n,[])
    if len(entries)!=1:raise ValueError('Missing/duplicate function '+n)
    a,b=entries[0];return s[a:b]
def literal(s):return re.search(r'@"\n(.*?)\n"@',s,re.S)[1]
W='{http://schemas.microsoft.com/winfx/2006/xaml/presentation}';X='{http://schemas.microsoft.com/winfx/2006/xaml}'
def normalize(e):return (e.tag,tuple(sorted(e.attrib.items())),(e.text or '').strip(),tuple(normalize(c) for c in e))
def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--report',type=Path,required=True);a=ap.parse_args();checks=[]
    def ck(name,ok,kind='Source'):
        try:
            value=ok() if callable(ok) else ok
            if not value:raise ValueError('Condition false')
            checks.append(dict(Name=name,Passed=True,Kind=kind))
        except Exception as exc:checks.append(dict(Name=name,Passed=False,Kind=kind,Detail=str(exc)))
    c=read(ROOT/'wad/Domenia-Core.ps1');baseline=json.loads(read(ROOT/'wad/docs/RC1.6-baseline.json'))
    changed={n for n,h in baseline['CoreFunctions'].items() if n not in functions(c) or sha(fn(c,n))!=h}
    ck('Same complete set of core functions',set(functions(c))==set(baseline['CoreFunctions']),'Hash')
    ck('Only four presentation-related core functions modified',changed=={'Get-MainXaml','Get-DomeniaStandardLoginXaml','Set-DomeniaFastLoginBusy','Initialize-DomeniaPresentation'},'Hash')
    protected=['Get-DomeniaStartupXaml','New-DomeniaStartupWindow','Set-DomeniaStartupStage','Get-DomeniaDebugLoginXaml','Show-LoginWindow','Start-DomeniaFastLoginAttempt','Update-DomeniaFastLoginAttempt','Complete-DomeniaFastLoginSuccess','Reset-DomeniaFastLoginAttempt','Add-DomeniaFastLoginDetail','Start-DomeniaLoginAuthRunspace','Assert-DomeniaWorkerRegistry','Get-DomeniaWorkerOperationHashes','Initialize-AsyncEngine','Invoke-GlobalSearch','Open-AdObject','Get-DomeniaSearchScope','Wire-Events']
    for n in protected:ck('Unchanged: '+n,sha(fn(c,n))==baseline['CoreFunctions'][n],'Hash')
    allow={'Domenia-UX.UI':{'Initialize-DomeniaUxLoginPresentation'},'Domenia-Experience.UI':{'Update-DomeniaExperienceActivity'},'Domenia-Access.UI':{'Update-DomeniaAccessButton'}}
    for stem,allowed in allow.items():
        s=read(ROOT/('wad/modules/'+stem+'.ps1'));b=json.loads(read(ROOT/('wad/docs/RC1.6-'+stem+'-baseline.json')))
        ck('Module function set unchanged: '+stem,set(functions(s))==set(b),'Hash')
        ck('Only intended functions changed: '+stem,{n for n,h in b.items() if sha(fn(s,n))!=h}==allowed,'Hash')
    allowedruntime={'wad/Domenia-Core.ps1','wad/modules/Domenia-UX.UI.ps1','wad/modules/Domenia-Experience.UI.ps1','wad/modules/Domenia-Access.UI.ps1','wad/modules/Domenia-UX.help.json'}
    for rel,h in baseline['Runtime'].items():
        if rel not in allowedruntime:ck('Unchanged runtime bytes: '+rel,sha((ROOT/rel).read_bytes())==h,'Hash')
    registry=dict(re.findall(r'(\w+)\s*=\s*"([A-F0-9]{64})"',fn(c,'Get-DomeniaWorkerOperationHashes')))
    contracts=json.loads(read(ROOT/'tools/operation-contracts.json'))
    ck('Exactly same 55 reviewed worker operations',len(registry)==55 and set(registry)=={e['Operation'] for e in contracts},'Hash')
    fingerprint=re.search(r'\$expectedFingerprint\s*=\s*"([A-F0-9]{64})"',fn(c,'Assert-DomeniaWorkerRegistry'))[1]
    ck('Registry fingerprint still matches',fingerprint==sha('\n'.join(k+'='+registry[k] for k in sorted(registry))),'Hash')
    for op in contracts:
        code=fn(read(ROOT/op['File']),op['Function']);lits=[m[2] for m in re.finditer(r'@([\'\"])\n(.*?)\n^\1@',code,re.S|re.M)]
        ck('Worker body preserved: '+op['Operation'],sha(lits[op['LiteralIndex']])==op['Sha256']==registry[op['Operation']],'Hash')
    login=E.fromstring(literal(fn(c,'Get-DomeniaStandardLoginXaml')));main=E.fromstring(literal(fn(c,'Get-MainXaml')))
    names={e.get(X+'Name'):e for e in login.iter() if e.get(X+'Name')};mn={e.get(X+'Name'):e for e in main.iter() if e.get(X+'Name')}
    parents={child:p for p in login.iter() for child in p}
    ck('FILPRO idle card metrics retained',login.get('Width')=='480' and names['PanelLogin'].get('Margin')=='16' and names['PanelLogin'].get('Padding')=='20','XML')
    ck('Standard window not maximizable',login.get('ResizeMode')=='NoResize','XML')
    for n in ['TxtLogin','PwdLogin']:ck('Field height/padding: '+n,names[n].get('MinHeight')=='40' and names[n].get('Padding')=='11,7','XML')
    ck('No inline expanding transcript in standard login',not login.findall('.//'+W+'Expander'),'XML')
    for n in ['TxtLoginTechnical','LblLoginStage']:
        ck('Technical control always collapsed: '+n,names[n].get('Visibility')=='Collapsed' and parents[names[n]] is names['LoginDiagnosticBuffer'],'XML')
    ck('Diagnostic buffer always collapsed and noninteractive',all(names['LoginDiagnosticBuffer'].get(k)==v for k,v in [('Visibility','Collapsed'),('IsHitTestVisible','False'),('Focusable','False')]),'XML')
    ck('Diagnostics remain wired by name',all('FindName("'+n+'")' in fn(c,'Show-LoginWindow') for n in ['TxtLoginTechnical','LblLoginStage','BtnLoginLog','BtnCopyLoginDiag']),'Source')
    for e in names.values():
        if e.tag==W+'TextBox' and e is not names['TxtLogin']:
            p=e;hidden=False
            while p is not None:
                hidden|=p.get('Visibility')=='Collapsed';p=parents.get(p)
            ck('No other visible text area: '+e.get(X+'Name'),hidden,'XML')
    ck('Error feedback hidden for empty message and busy',len(names['UxLoginFeedback'].findall('.//'+W+'DataTrigger/'+W+'Setter[@Property="Visibility"][@Value="Collapsed"]'))==2,'XML')
    ck('Error detail bounded',names['UxLoginFeedback'].find('.//'+W+'ScrollViewer').get('MaxHeight')=='60','XML')
    ck('Error commands outside the bounded message',parents[names['BtnCopyLoginDiag']] is names['UxLoginDiagnostics'] and parents[names['UxLoginDiagnostics']] is names['UxLoginFeedback'],'XML')
    ck('Same-window busy card uses FILPRO geometry',names['PanelSplash'].get('Margin')=='16' and names['PanelSplash'].get('Padding')=='24','XML')
    ck('Busy text is static and not bound to technical output',names['LblLoginWait'].get('Text')=='Vérification du compte…' and not any('Binding' in v for v in names['LblLoginWait'].attrib.values()),'XML')
    ck('Busy animation not invented percentage',names['PbLogin'].get('IsIndeterminate')=='True' and names['PbLogin'].get('Height')=='6','XML')
    ck('Input area hidden during waiting without removing its layout slot',names['PanelLogin'].find('.//'+W+'DataTrigger/'+W+'Setter[@Property="Visibility"]').get('Value')=='Hidden','XML')
    busy=fn(c,'Set-DomeniaFastLoginBusy')
    ck('Busy locks outer height before progress appears',busy.index('SizeToContent = [Windows.SizeToContent]::Manual')<busy.index('$ui.Progress.Visibility'))
    ck('Only real standard WPF window sized',"$ui.Window -is [Windows.Window]" in busy and "FindName('PanelSplash')" in busy)
    ck('Idle failure allows natural height again','[Windows.SizeToContent]::Height' in busy and '[double]::NaN' in busy)
    ck('Busy helper does not wait or access AD',not re.search(r'WaitOne|Start-Sleep|Start-Process|\.Wait\(|\.Result\b|New-.*Searcher',busy))
    ux=fn(read(ROOT/'wad/modules/Domenia-UX.UI.ps1'),'Initialize-DomeniaUxLoginPresentation')
    ck('Wait cancel routed to existing action',"FindName('BtnCancel')" in ux and 'RaiseEvent' in ux)
    ck('Escape handled once for in-window wait','PreviewKeyDown' in ux and '$eventArgs.Handled = $true' in ux)
    ck('Wait handlers registered at most once',"DomeniaLoginWaitWired" in ux and "Resources.Contains" in ux)
    ck('No new authentication path in presentation initializer',not re.search(r'Start-DomeniaLogin|Start-DomeniaFastLogin|PSCredential|GetNetworkCredential|Password\.Password',ux))
    # The original FILPRO style trees are still identical after mapping color resource names.
    ref=E.parse(ROOT/'wad/docs/reference-filpro/Controls.xaml').getroot();refstyles={(s.get(X+'Key') or s.get('TargetType')):s for s in ref if s.tag==W+'Style'}
    color={'BgWindow':'Window','BgCard':'Surface','FgText':'Text','FgMuted':'Muted','ClrBorder':'Border','BgInput':'Input','BtnFg':'ButtonText','BtnBg':'Button','BtnBorder':'Border','AddBg':'Accent','FgAccent':'AccentText','WarnFg':'Warning','ErrFg':'Error','ErrBg':'Surface','ErrBorder':'Error','SelBg':'Accent'}
    styles=login.findall('.//'+W+'Grid.Resources/'+W+'Style');ck('Twelve FILPRO styles present',len(styles)==12,'XML')
    for style in styles:
        key=style.get(X+'Key') or style.get('TargetType');st=E.tostring(refstyles[key],encoding='unicode')
        for old,new in color.items():st=st.replace('{DynamicResource '+old+'}','{DynamicResource DomeniaBoot'+new+'}')
        ck('FILPRO reference style retained: '+key,normalize(style)==normalize(E.fromstring(st)),'XML reference')
    for name,width,badge,label in [('BtnSuiteActivity','144','BadgeSuiteActivity','LblSuiteActivityCount'),('BtnAccessRecovery','108','BadgeAccessRecovery','LblAccessRecoveryCount')]:
        button=mn[name]
        ck('Fixed outer width: '+name,all(button.get(k)==width for k in ['Width','MinWidth','MaxWidth']),'XML')
        ck('Fixed outer height: '+name,all(button.get(k)=='40' for k in ['Height','MinHeight','MaxHeight']),'XML')
        ck('Badge reserved when idle: '+badge,mn[badge].get('Width')=='30' and mn[badge].get('Visibility')=='Hidden','XML')
        ck('Counter separately addressable: '+label,mn[label].get('FontSize')=='11' and mn[label].get('Text')=='0','XML')
    for path,name,var in [('Domenia-Experience.UI.ps1','Update-DomeniaExperienceActivity','button'),('Domenia-Access.UI.ps1','Update-DomeniaAccessButton','b')]:
        body=fn(read(ROOT/'wad/modules'/path),name)
        ck('Does not replace button content: '+name,not re.search(r'\$'+var+r'\.Content\s*=',body))
        ck('Badge count capped at 99+: '+name,"'99+'" in body and '-gt 99' in body)
        ck('Full count in tooltip: '+name,'$help=' in body and 'ToolTip=$help' in body)
        ck('Counter keeps slot at zero: '+name,"else{'Hidden'}" in body)
        ck('Counter source does not perform measure or network calls: '+name,not re.search(r'UpdateLayout|\.Width\s*=|Start-Sleep|New-Cim|FindAll',body))
    for p in [ROOT/'wad/Domenia-Core.ps1',ROOT/'wad/tests/Test-DomeniaStableUi.ps1',ROOT/'wad/tests/Test-DomeniaStartupLogin.ps1',ROOT/'wad/maintenance/Preview-DomeniaLogin.ps1']:
        ck('Lexical source check (not native): '+p.name,not mask_ps(read(p))[1],'Lexical')
    tests=read(ROOT/'wad/tests/Test-DomeniaStableUi.ps1');install=read(ROOT/'INSTALLER-MISE-A-JOUR.ps1')
    ck('Tests cover actual busy setter and actual counter update','Set-DomeniaFastLoginBusy $true' in tests and 'Update-DomeniaExperienceActivity;Pump-Layout' in tests)
    ck('Tests inspect positions of neighbouring header controls','TranslatePoint' in tests and 'Expect-SameGeometry $geometry (Get-HeaderGeometry $w)' in tests)
    ck('Test lifecycle includes success-like feedback while still busy','confirmation de succes ne revele pas de mini-log' in tests)
    ck('New native suite complete count required','$expected=52' in tests and 'Complete=($script:Checks.Count -eq $expected' in tests)
    ck('No post-login startup modification claimed by test','New-DomeniaStartupWindow' not in tests and 'TxtStartupDetail' not in tests)
    ck('Installer runs native suite before code copies',install.index('Test-DomeniaStableUi.ps1')<install.index('Copy-CodeAtomically $from $to'))
    ck('Installer refuses skipped/incomplete suite',"'Test-DomeniaStableUi.ps1','Test-DomeniaStartupLogin.ps1'" in install and '-not $result.Complete' in install)
    ck('Demo can simulate waiting without authentication','Simuler une connexion' in read(ROOT/'wad/maintenance/Preview-DomeniaLogin.ps1'))
    bad=[i for i in checks if not i['Passed']]
    report=dict(Build='2026.10.01-DOMENIA-1.0-RC1.6-STABLEUI',Environment='Linux/Python: source, XML, hashes only',Passed=len(checks)-len(bad),Failed=len(bad),PowerShellExecuted=False,WpfExecuted=False,LiveADExecuted=False,NativeTestsProvided=52,ChangedCoreFunctions=sorted(changed),Checks=checks)
    a.report.parent.mkdir(parents=True,exist_ok=True);a.report.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k!='Checks'},ensure_ascii=False,indent=2))
    for i in bad:print('FAIL',i)
    return bool(bad)
if __name__=='__main__':raise SystemExit(main())
