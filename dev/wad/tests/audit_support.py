#!/usr/bin/env python3
"""R1.5 source/XML audit and Python regex/contrast tests. NOT PowerShell/WPF execution."""
import argparse, hashlib, json, re, time, xml.etree.ElementTree as ET
from pathlib import Path
from powershell_lex import functions, mask_ps

def sha(s): return hashlib.sha256(s.encode('utf8')).hexdigest()
def require(ok, message='Assertion failed'):
    if not ok: raise AssertionError(message)
def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--root',type=Path,default=Path(__file__).resolve().parents[2])
    ap.add_argument('--report',type=Path,required=True)
    args=ap.parse_args();root=args.root
    core=(root/'wad/Domenia-Core.ps1').read_text(encoding='utf-8-sig')
    model=(root/'wad/modules/Domenia-Support.Model.ps1').read_text(encoding='utf-8-sig')
    ui=(root/'wad/modules/Domenia-Support.UI.ps1').read_text(encoding='utf-8-sig')
    native=(root/'wad/tests/Test-DomeniaSupport.ps1').read_text(encoding='utf-8-sig')
    install=(root/'INSTALLER-MISE-A-JOUR.ps1').read_text(encoding='utf-8-sig')
    baseline=json.loads((root/'wad/tests/support-baseline-r14.json').read_text())
    maps=[functions(s) for s in (core,model,ui)]
    def f(name):
        for text,funcs in zip((core,model,ui),maps):
            if name in funcs:
                require(len(funcs[name])==1,'Duplicate '+name);a,b=funcs[name][0];return text[a:b]
        raise KeyError(name)
    results=[]
    def test(name,kind,fn):
        start=time.monotonic()
        try:fn();status='PASS';detail=''
        except Exception as e:status='FAIL';detail=str(e)
        results.append(dict(Name=name,Kind=kind,Status=status,Detail=detail,Milliseconds=round(1000*(time.monotonic()-start),2)))
        print(status,name,detail)
    def delimiters(text):
        masked,issues=mask_ps(text);require(not issues,str(issues));stack=[];pairs={')':'(',']':'[','}':'{'}
        for i,c in enumerate(masked):
            if c in '([{':stack.append((c,i))
            elif c in ')]}':
                require(stack and stack[-1][0]==pairs[c],f'Mismatch at {i}');stack.pop()
        require(not stack,str(stack[:3]))
    for name,text in [('model',model),('adapter',ui),('native tests',native)]:
        test('Approximate lexical balance: '+name,'static-not-native',lambda text=text:delimiters(text))
    test('No original core functions removed','source-regression',lambda:require(set(baseline['Functions'])<=set(maps[0])))
    def stable_functions():
        ui_baseline=json.loads((root/'wad/tests/ui-baseline-r16.json').read_text())
        allowed=set(ui_baseline['AllowedChangedFunctions'])
        changed=[]
        for name,digest in ui_baseline['Functions'].items():
            if sha(f(name))!=digest:changed.append(name)
        require(set(changed)==allowed,str(changed))
    test('R1.7 core changes limited to 13 explicit UI integration functions','source-regression',stable_functions)
    test('Authentication probe, worker context and remote common text unchanged','source-regression',lambda: ([require(sha(f(n))==baseline['Functions'][n],n) for n in baseline['CriticalFunctions']],require(sha(re.search(r"(?ms)^\$script:WorkerCommon = @'\n(.*?)\n'@",core)[1])==baseline['WorkerCommonSha256'])))
    test('All new function names unique across modules and core','source-regression',lambda:require(sum(len(m) for m in maps)==len(set().union(*(set(m) for m in maps)))))
    test('Fixed module imports before application config load','integration',lambda:require(core.index(". (Join-Path $PSScriptRoot 'modules\\Domenia-Support.Model.ps1')")<core.index('Load-AppConfig',core.index('# Main autoritaire'))))
    test('Atelier init cannot abort an otherwise healthy application init','integration',lambda:require('try { Initialize-DomeniaSupportUi }' in f('Initialize-Window') and 'Stop-DomeniaSupportUi' in f('Initialize-Window')))
    test('Relogin clears local atelier data','integration',lambda:require('Reset-DomeniaSupportSession' in f('Start-DomeniaAccountRelogin')))
    test('Source hook accounts for cache and actual result Live flag','integration',lambda:require('-IsLive:($isLiveRead -and -not [bool]$script:ShowingCachedObject)' in f('Show-AdObjectResult')))
    test('Selected object metadata read without new LDAP or WMI operations','privacy-boundary',lambda:require(not re.search(r'\b(?:Invoke-Command|Get-ADUser|Get-ADComputer|Get-CimInstance|Start-UiTask|Start-Process|Invoke-Expression|DownloadString|LdapConnection)\b',model+'\n'+ui)))
    test('Only manual pin opener delegates to existing object read','privacy-boundary',lambda:require(len(re.findall(r'\bOpen-AdObject\b',ui))==1 and 'Open-AdObject' in f('Open-DomeniaSupportPin')))
    test('Model has no disk, clipboard, WPF or network calls','privacy-boundary',lambda:require(not re.search(r'\b(?:Set-Content|Out-File|WriteAllText|FileStream|Clipboard|Windows.Controls|WebClient|HttpClient|TcpClient)\b',model)))
    names=re.findall(r"'([^']+)'",f('Get-DomeniaSupportFieldNames'))
    test('29 positive fields, no dedicated secrets or arbitrary descriptions','privacy-boundary',lambda:require(len(names)==29 and not (set(names)&{'description','info','unicodePwd','msLAPS-Password','msFVE-RecoveryPassword','ms-Mcs-AdmPwd'})))
    test('Snapshots deep-copy primitive values and track coverage','source-contract',lambda:require('ToArray([string])' in f('New-DomeniaSupportSnapshot') and all(t in f('New-DomeniaSupportSnapshot') for t in ('NotProvided','Provided','Partial','128','memberOf;range='))))
    test('Comparisons reject unknown/partial coverage before computing removed groups','source-contract',lambda:require(f('Compare-DomeniaSupportSnapshots').index("$leftState -ne 'Provided'")<f('Compare-DomeniaSupportSnapshots').index("$field -eq 'memberOf'")))
    test('No cross-scope or cross-type comparison','source-contract',lambda:require('Before.Scope -ine' in f('Compare-DomeniaSupportSnapshots') and 'Before.Type -ine' in f('Compare-DomeniaSupportSnapshots')))
    test('Cache freshness never inferred from new capture time','source-contract',lambda:require("$Snapshot.Source -ne 'Live'" in f('Get-DomeniaSupportFindings') and 'DATA_NOT_LIVE' in f('Get-DomeniaSupportFindings')))
    test('Lockout history not used as computed current lock','source-contract',lambda:require(all(x in f('Get-DomeniaSupportFindings') for x in ('LOCKOUT_HISTORY','ACCOUNT_LOCKED','$computed -band 16'))))
    test('No pseudo health score or automatic remediation API','source-contract',lambda:require(not re.search(r'\b(?:Set-AD\w+|Remove-AD\w+|Unlock-AD\w+|Restart-Computer|Repair-\w+|HealthScore)\b',model+'\n'+ui)))
    test('Text bounded before regular expressions','source-contract',lambda:require(f('ConvertTo-DomeniaSupportText').index('$text.Substring')<f('ConvertTo-DomeniaSupportText').index('[regex]::Replace')))
    test('Explicit internal-export confirmation and atomic write','integration',lambda:require('Confirm-Action' in f('Export-DomeniaSupportHtml') and 'Write-DomeniaAtomicText' in f('Export-DomeniaSupportHtml')))
    test('Report builder never references raw incident details','privacy-boundary',lambda:require('Incident.Detail' not in f('New-DomeniaSupportReport') and 'Snapshot.Fields.Keys' not in f('New-DomeniaSupportReport')))
    test('Exported HTML escapes all report content and has restrictive CSP','privacy-boundary',lambda:require('[Net.WebUtility]::HtmlEncode($Report)' in f('ConvertTo-DomeniaSupportHtml') and "default-src 'none'" in f('ConvertTo-DomeniaSupportHtml') and not re.search(r'<script|<img|<iframe|https?://',f('ConvertTo-DomeniaSupportHtml'))))
    test('Incidents collected only after mount on UI thread with bounded memory','integration',lambda:require('CheckAccess()' in f('Add-DomeniaSupportIncidentFromLog') and '-Limit 200' in f('Add-DomeniaSupportIncidentFromLog')))
    test('Background local view defers captures during another target load','integration',lambda:require('en cours de chargement' in f('Update-DomeniaSupportView') and 'throw ' in f('Get-DomeniaSupportCurrentSnapshot')))
    test('Pin storage bounded, exact DN retained, no persistence','integration',lambda:require('Count -ge 24' in f('Add-DomeniaSupportPin') and 'Dn=([string]$script:SelectedObject.DN)' in f('Add-DomeniaSupportPin')))
    test('Session has explicit epoch and identity isolation','integration',lambda:require(all(x in f('Get-DomeniaSupportSessionKey') for x in ('SessionEpoch','Conn.BaseDn','Conn.BindUser'))))
    test('Optional timer stopped and control references removed on exit','integration',lambda:require(all(x in f('Stop-DomeniaSupportUi') for x in ('SupportTimer.Stop()','Items.Remove($tab)','Ctrl.Remove($key)'))))
    test('Installer runs support tests before backup/copy','integration',lambda:require(install.index('& $supportTests -ReportPath')<install.index("$backupParent=Join-Path")))
    test('52 functional tests and one optional WPF test supplied, not executed here','test-presence',lambda:require(len(re.findall(r'^Invoke-SupportTest ',native,re.M))==52 and len(re.findall(r'^    Invoke-SupportTest ',native,re.M))==1))
    ns='{http://schemas.microsoft.com/winfx/2006/xaml}'
    host=ET.fromstring(re.search(r'@"\n(.*?)\n"@',f('Get-MainXaml'),re.S).group(1))
    view=ET.parse(root/'wad/modules/Domenia-Support.xaml').getroot()
    ctrls=[e.attrib[ns+'Name'] for e in view.iter() if ns+'Name' in e.attrib]
    host_names={e.attrib[ns+'Name'] for e in host.iter() if ns+'Name' in e.attrib}
    keys={e.attrib[ns+'Key'] for e in host.iter() if ns+'Key' in e.attrib}|{e.attrib[ns+'Key'] for e in view.iter() if ns+'Key' in e.attrib}
    def resources_resolve():
        for el in view.iter():
            for value in el.attrib.values():
                match=re.fullmatch(r'\{(?:DynamicResource|StaticResource) ([^}]+)\}',value)
                if match:require(match[1] in keys,match[1])
    test('Actual Atelier XAML parses; every resource reference resolves statically','xml-not-wpf',resources_resolve)
    test('New control names unique and absent from host namescope','xml-not-wpf',lambda:require(len(ctrls)==len(set(ctrls)) and not(set(ctrls)&host_names)))
    def controls_resolve():
        required=set(re.findall(r"Get-DomeniaControl\s+(?:-Name\s+)?'([^']+)'",ui))
        require(required<=set(ctrls)|host_names|{'TabSupport'},str(required-(set(ctrls)|host_names|{'TabSupport'})))
    test('Adapter control names exist in actual host or view','xml-not-wpf',controls_resolve)
    test('All new buttons have a wired click handler','xml-not-wpf',lambda:[require("'"+n+"').Add_Click" in ui,n) for n in ctrls if n.startswith('BtnSupport')])
    test('Every new grid is read-only and virtualized by its real shared style','xml-not-wpf',lambda:require(all(x in ET.tostring(view,encoding='unicode') for x in ('EnableRowVirtualization','EnableColumnVirtualization','Recycling','IsReadOnly','CanContentScroll'))))
    test('No hard-coded black foreground in new view','xml-not-wpf',lambda:require(not re.search(r'(Foreground|Background)="(?:Black|#000000|#000|White)"',ET.tostring(view,encoding='unicode'))))
    # Python executes the literal regex patterns actually stored in the PowerShell rule table.
    patterns=dict(re.findall(r"Code='([^']+)';Pattern='([^']+)'",f('Get-DomeniaSupportIncidentRules')))
    samples={'SMB_SESSION_CONFLICT':'erreur 1219','CANCELLED':'BeginStop apres annulation','AUTH_CONTEXT':'0x8007052e','ACCESS_DENIED':"L'accès au chemin est refusé",'RPC_UNAVAILABLE':'0x800706ba','TIMEOUT':'Délai dépassé','DNS_NETWORK':'0x80070035','ENGINE_BUSY':'limite physique','PSEXEC_LICENSE':'SYSINTERNALS SOFTWARE LICENSE TERMS'}
    for code,sample in samples.items():
        test('Python execution of source regex: '+code,'python-regex-not-dotnet',lambda code=code,sample=sample:require(re.search(patterns[code],sample)))
    def classify(text):return {key for key,pattern in patterns.items() if re.search(pattern,text[:8192])}
    test('Combined incident retains multiple labels','python-regex-not-dotnet',lambda:require({'CANCELLED','TIMEOUT','ACCESS_DENIED'}<=classify('Annulation apres timeout et acces refuse')))
    test('Unrecognized incident matches no confident rule','python-regex-not-dotnet',lambda:require(not classify('Evenement synthetique non classe')))
    def luminance(c):
        rgb=[int(c[i:i+2],16)/255 for i in (1,3,5)]
        lin=[v/12.92 if v<=.04045 else ((v+.055)/1.055)**2.4 for v in rgb]
        return sum(x*y for x,y in zip(lin,(.2126,.7152,.0722)))
    palette_body=f('Apply-DomeniaTheme');colors=re.findall(r'@\{(.*?)\}',palette_body,re.S)[:2]
    for mode,body in zip(('Dark','Light'),colors):
        palette=dict(re.findall(r'(\w+)="(#[A-Fa-f0-9]{6})"',body))
        for fg,bg in [('TextColor','BgCard'),('TextColor','BgReadonly'),('TextColor','BgInput'),('MutedColor','BgCard'),('InfoFg','InfoBg')]:
            def contrast(palette=palette,fg=fg,bg=bg):
                a,b=sorted((luminance(palette[fg]),luminance(palette[bg])));require((b+.05)/(a+.05)>=4.5,str((b+.05)/(a+.05)))
            test(f'Palette contrast {mode}: {fg}/{bg}','calculation-not-render',contrast)
    # Ensure all package PowerShell files use the expected Windows-compatible encoding.
    test('New PowerShell files UTF-8 BOM for Windows PowerShell 5.1','source-contract',lambda:[require(p.read_bytes().startswith(b'\xef\xbb\xbf'),p.name) for p in [root/'wad/modules/Domenia-Support.Model.ps1',root/'wad/modules/Domenia-Support.UI.ps1',root/'wad/tests/Test-DomeniaSupport.ps1']])
    summary=dict(Build='2026.09.21-R1.7-SIDEBAR',SuiteOrigin='R1.5 support model, R1.7 UI guard',Passed=sum(r['Status']=='PASS' for r in results),Failed=sum(r['Status']=='FAIL' for r in results),NativePowerShellExecuted=False,WpfExecuted=False,ActiveDirectoryExecuted=False,NativeScenariosProvidedNotExecuted=52,OptionalWpfScenarioProvidedNotExecuted=1,Results=results)
    args.report.parent.mkdir(parents=True,exist_ok=True);args.report.write_text(json.dumps(summary,indent=2,ensure_ascii=False)+'\n')
    print(json.dumps({k:v for k,v in summary.items() if k!='Results'}));return 1 if summary['Failed'] else 0
if __name__=='__main__':raise SystemExit(main())
