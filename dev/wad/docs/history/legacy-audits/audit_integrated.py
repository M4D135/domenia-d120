#!/usr/bin/env python3
"""RC1.9 static integration audit. No claim of Windows/WPF or PowerShell execution."""
import argparse, json, re, hashlib, sys, functools, xml.etree.ElementTree as ET
from pathlib import Path
R=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(R/'wad/tests'))
from powershell_lex import functions as raw_functions, mask_ps
functions=functools.lru_cache(maxsize=128)(raw_functions)

def text(path):return path.read_text('utf-8-sig')
def sha(value):return hashlib.sha256(value.encode() if isinstance(value,str) else value).hexdigest().upper()
def fn(src,name):
    locations=functions(src).get(name,[])
    if len(locations)!=1:raise ValueError('Missing or duplicate function: '+name)
    a,b=locations[0];return src[a:b]
def balance(src):
    normalized=src.translate(str.maketrans({'\u2018':"'",'\u2019':"'",'\u201c':'"','\u201d':'"'}))
    masked,errors=mask_ps(normalized)
    if errors:raise ValueError(str(errors))
    stack=[];pairs={')':'(',']':'[','}':'{'}
    for c in masked:
        if c in '([{':stack.append(c)
        elif c in pairs:
            if not stack or stack.pop()!=pairs[c]:raise ValueError('Unbalanced delimiters')
    if stack:raise ValueError('Unclosed delimiters')
    return True

def run(report):
    checks=[]
    def check(name,value):
        try:
            result=value() if callable(value) else value
            if not result:raise ValueError('assertion false')
            checks.append(dict(Name=name,Passed=True,Error=''))
        except Exception as e:checks.append(dict(Name=name,Passed=False,Error=str(e)))
    core=text(R/'wad/Domenia-Core.ps1');mod=text(R/'wad/modules/Domenia-Embedded.UI.ps1');access=text(R/'wad/modules/Domenia-Access.UI.ps1')
    baseline=json.loads(text(R/'wad/docs/RC1.9-source-baseline.json'))
    check('No original main functions lost',set(functions(core))==set(baseline['Core']))
    changed=[n for n,h in baseline['Core'].items() if sha(fn(core,n))!=h]
    allowed=['Get-MainXaml','Show-DomeniaDialog','Show-DomeniaFormDialog','Show-DomeniaObjectPicker','Show-DomeniaOuPicker','Show-DomeniaRimotteDialog','Show-DomeniaCommandPalette','Show-LoginWindow','Complete-DomeniaFastLoginSuccess','Confirm-DomeniaOperationImpact','Import-LinksCsv','Export-CurrentResults','Export-SelfCheckReport','Get-WorkerContext','Get-DomeniaWorkerOperationHashes','Assert-DomeniaWorkerRegistry','Initialize-DomeniaPresentation']
    # Exact list is retained in evidence; sensitive functions outside the reviewed UI changes stay identical.
    check('Core changes stay within reviewed set',set(changed)<=set(allowed))
    for n in ['Invoke-DomeniaInProcessAuthProbe','Start-DomeniaFastLoginAttempt','Update-DomeniaFastLoginAttempt','Start-DomeniaLoginAuthRunspace','Invoke-GlobalSearch','Assert-DomeniaCapability','Start-DomeniaWriteTask','Assert-WriteAllowed','Set-DomeniaFastLoginBusy','Add-SelectedLink']:
        check('Sensitive function preserved: '+n,sha(fn(core,n))==baseline['Core'][n])
    check('New module definition-only (no invoked host)',mod.count('function Show-DomeniaEmbeddedWindow {')==1 and mod.startswith('# Definition-only'))
    check('Surface module exports exactly twenty unique functions',len(functions(mod))==20 and all(len(v)==1 for v in functions(mod).values()))
    for p in [R/'wad/Domenia-Core.ps1',R/'wad/Domenia-Modules.ps1',R/'wad/Domenia-Start.ps1',R/'INSTALLER-MISE-A-JOUR.ps1']+list((R/'wad/modules').glob('*.ps1'))+[R/'wad/tests/Test-DomeniaEmbeddedUi.ps1',R/'wad/tests/Test-DomeniaRelationsAlignment.ps1']:
        check('Lexical only: '+p.relative_to(R).as_posix(),lambda p=p:balance(text(p)))
    body=re.search(r'@"\n(.*?)\n"@',fn(core,'Get-MainXaml'),re.S)[1]
    doc=ET.fromstring(body);ns={'w':'http://schemas.microsoft.com/winfx/2006/xaml/presentation'};xn='{http://schemas.microsoft.com/winfx/2006/xaml}Name'
    elements={n.attrib[xn]:n for n in doc.iter() if xn in n.attrib};layer=elements['DomeniaDialogLayer']
    check('Layer is sibling overlay, no new flow row',layer.attrib.get('Panel.ZIndex')=='2000' and layer.attrib.get('Visibility')=='Collapsed')
    check('Explicit user selector in Relations',elements['BtnRelationSelectUser'].attrib['Content']=='Choisir un utilisateur')
    check('All original named controls retained',set(baseline['Controls'])<=set(elements))
    for n in ['BtnRelationSelectUser']:
        check('Tooltip/accessibility: '+n,all(elements[n].attrib.get(k) for k in ['ToolTip','ToolTipService.ShowOnDisabled','AutomationProperties.Name','AutomationProperties.HelpText']))
    for n in ['Show-DomeniaDialog','Show-DomeniaFormDialog','Show-DomeniaCommandPalette','Show-DomeniaRimotteDialog','Show-LoginWindow']:
        f=fn(core,n);check('Same-window route: '+n,'Show-DomeniaEmbeddedWindow' in f and '.ShowDialog(' not in f)
    for n in ['Show-DomeniaObjectPicker','Show-DomeniaOuPicker']:
        f=fn(core,n);check('Async inline picker route: '+n,'Show-DomeniaInlinePicker' in f and 'New-Object' not in f and 'Search-' not in f)
    check('Native Window.ShowDialog kept only for main; other calls are integrated file requests',len(re.findall(r'\.ShowDialog\(',core))==4 and all('New-DomeniaFileRequest' in fn(core,n) for n in ['Import-LinksCsv','Export-CurrentResults','Export-SelfCheckReport']))
    for p in [R/'wad/Domenia-Core.ps1']+list((R/'wad/modules').glob('*.ps1')):
        check('No native Win32 file/message popup in '+p.name,not re.search(r'new-Object\s+(?:Microsoft\.Win32\.(?:Open|Save)FileDialog|.*FolderBrowserDialog)|\[(?:Microsoft\.Win32\.(?:Open|Save)FileDialog|.*MessageBox)\]::(?:new|Show)',text(p),re.I))
    shell=fn(mod,'Show-DomeniaEmbeddedWindow')
    for name,expression in [
        ('Only prehost fallback may call native ShowDialog',shell.count('.ShowDialog()')==1 and 'if(-not (Test-DomeniaEmbeddedHost))' in shell),
        ('No EnsureHandle or native window generation','EnsureHandle' not in mod and 'HwndSource' not in mod),
        ('Content transferred rather than shown','$Window.Content=$null' in shell and '$layout.Children.Add($body)' in shell),
        ('Decision default remains refusal','Accepted=$false' in shell),
        ('Duplicate sheet rejected not stacked','$parent.Status.Text=' in shell and 'return $false' in shell),
        ('Dispatcher frame pumps, no polling wait','PushFrame' in shell and not re.search(r'WaitOne|Start-Sleep|\.Wait\(',shell)),
        ('Keyboard page shortcuts held and restored','$main.InputBindings.Clear()' in shell and '$main.InputBindings.Add($binding)' in shell),
        ('Underlying page disabled then restored','$item.IsEnabled=$false' in shell and '$s.Control.IsEnabled=$s.Enabled' in shell),
        ('Source cleanup fires Closed handler','Add_Closed($onClosed)' in shell and 'Remove_Closed($onClosed)' in shell),
        ('Focus restored without implicit new selection','$previousFocus.Focus()' in shell),
        ('Password fields cleared on close','$c.Clear()' in shell),
        ('Session or shutdown invalidates pending choice','$current.Epoch -ne $epoch' in shell and '$current.Closing' in shell),
        ('Theme is inherited as resources','SetResourceReference' in fn(mod,'Set-DomeniaEmbeddedTheme') and "'BgInput'" in mod),
        ('No value reflected into help',not re.search(r'\$c\.(?:Text|Password|Content)\b',fn(mod,'Set-DomeniaEmbeddedTheme'))),
        ('Outstanding file error not presented as bad AD credential',"'EmbeddedPathBrowse')){return $false}" in fn(access,'Request-DomeniaAccessRecovery')),
        ('Access prompt waits while current sheet active','DomeniaSurfaceState' in fn(access,'Invoke-DomeniaAccessRecovery')),
    ]:check(name,expression)
    for name,keys in {
        'Show-DomeniaInlinePicker':['Start-UiTask','EmbeddedDirectoryLookup','Request-UiTaskStop','RequestId','Kind'],
        'Get-DomeniaEmbeddedLookupCode':['$Context.BaseDn','Escape-WLdap','Subtree',"$scope='Base'",'$Payload.Guid','$set.Dispose()','$owned.Dispose()'],
        'Complete-DomeniaEmbeddedLookup':['$r.Closed','$State.RequestId','$script:SessionEpoch','$State.BaseDn','$State.Guid'],
        'Show-DomeniaInlineFilePicker':['Start-UiTask','EmbeddedPathBrowse','Request-UiTaskStop'],
        'Get-DomeniaEmbeddedPathCode':['ItemNotFoundException','-ErrorAction Stop','500',"$action -eq 'Validate'"],
        'Complete-DomeniaEmbeddedPath':['$State.Epoch','$data.Signature',"$r.Accept.Content='Remplacer'"],
    }.items():
        check('Guards and contract: '+name,all(k in fn(mod,name) for k in keys))
    common=re.search(r"(?ms)^\$script:WorkerCommon = @'\n(.*?)\n'@",core)[1]
    check('AD binary getter does not unroll bytes','return ,$value' in fn(common,'Get-WPropFirst'))
    check('GUID parser validates 16 byte bounds',all(k in fn(common,'Convert-WGuid') for k in ['16','255','TryParse',"ToString('D')"]))
    rt=text(R/'wad/tests/Test-DomeniaRelationsAlignment.ps1')
    check('Full Relations fixtures now carry actual binary GUID','GuidHelpers' in rt and "objectguid=@(,([guid]" in rt and 'function Convert-WGuid {param($Value);return [string]$Value}' not in rt)
    check('First Relations failure is visible','Recherche AD non confirmée.' in text(R/'wad/modules/Domenia-Relations.UI.ps1') and "$first[0].Detail" in text(R/'wad/modules/Domenia-Relations.UI.ps1'))
    for p,h in baseline['Binaries'].items():check('Binary unchanged: '+p,sha((R/p).read_bytes())==h)
    for p,h in baseline['UnchangedModules'].items():check('Business module unchanged: '+p,sha(text(R/p))==h)
    plan=text(R/'wad/Domenia-Modules.ps1')
    declared=re.search(r"File='Domenia-Embedded.UI.ps1'.*?Functions=@\((.*?)\)\s*}",plan,re.S)[1]
    check('Closed loader includes every new function',set(re.findall(r"'([^']+)'",declared))==set(functions(mod)))
    check('New suite required before install copy','Test-DomeniaEmbeddedUi.ps1' in text(R/'INSTALLER-MISE-A-JOUR.ps1'))
    result=dict(Build='2026.10.01-DOMENIA-1.0-RC1.9-INTEGRATED',Environment='Linux/Python',Passed=sum(c['Passed'] for c in checks),Failed=sum(not c['Passed'] for c in checks),CoreFunctionsChanged=changed,NoWindowsExecution=True,Checks=checks)
    report.parent.mkdir(parents=True,exist_ok=True);report.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps({k:v for k,v in result.items() if k!='Checks'},indent=2))
    for c in checks:
        if not c['Passed']:print('FAIL:',c['Name'],c['Error'])
    return int(result['Failed']>0)
if __name__=='__main__':
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--report',type=Path,required=True);raise SystemExit(run(ap.parse_args().report))
