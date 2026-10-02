#!/usr/bin/env python3
"""R1.11: source, XML, palette and integrity audit. Standard Python library only.
Not a PowerShell parser, WPF run, LDAP test or claim of operational certification.
Use TESTER-EXPERIENCE.cmd and the Windows previews for native tests.
"""
import argparse, hashlib, json, re, sys, xml.etree.ElementTree as ET
from pathlib import Path
from powershell_lex import functions, mask_ps
from audit_ui import window_controls, assert_scoped_names, contrast, INTERACTIVE

BUILD = '2026.09.30-R1.11-SUITE'
X = '{http://schemas.microsoft.com/winfx/2006/xaml}'
EXPECTED = {'Set-DomeniaItemsSource','Get-DomeniaDefaultSettings','Load-DomeniaSettings','Save-DomeniaSettings',
            'Get-DomeniaBootThemePalette','Save-DomeniaTheme','Apply-DomeniaTheme','Get-MainXaml',
            'Update-TaskUi','Clear-DomeniaGlobalSearch','Export-CurrentResults',
            'Update-DomeniaAccountUi','Get-DomeniaStandardLoginXaml'}

def sha(value):
    return hashlib.sha256(value.encode('utf8') if isinstance(value,str) else value).hexdigest()

def text(path): return path.read_text(encoding='utf-8-sig')

def func(source, spans, name):
    assert len(spans.get(name,[])) == 1, 'Missing/duplicate function '+name
    return source[slice(*spans[name][0])]

def delimiters(source):
    # PS recognizes typographic quotes; normalizing these makes the approximation stricter.
    source=source.translate(str.maketrans({'\u2018':"'",'\u2019':"'",'\u201c':'"','\u201d':'"'}))
    masked,errors=mask_ps(source)
    assert not errors,str(errors)
    stack=[];pairs={')':'(',']':'[','}':'{'}
    for c in masked:
        if c in '([{': stack.append(c)
        elif c in pairs: assert stack and stack.pop()==pairs[c],'Delimiter mismatch'
    assert not stack,'Unclosed delimiter'

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root',type=Path,default=Path(__file__).resolve().parents[2])
    parser.add_argument('--report',type=Path,default=Path('/tmp/domenia-r111-audit.json'))
    args=parser.parse_args();root=args.root.resolve();checks=[];observations={}
    def ck(name,condition,detail=''):
        try:
            result=condition() if callable(condition) else condition
            assert result is None or bool(result),detail or name
            checks.append({'Name':name,'Passed':True,'Detail':detail})
        except Exception as ex:
            checks.append({'Name':name,'Passed':False,'Detail':str(ex)})
            print('FAIL:',name,':',ex)
    core=text(root/'wad/Domenia-Core.ps1');fs=functions(core);f=lambda n:func(core,fs,n)
    ux=text(root/'wad/modules/Domenia-UX.UI.ps1');us=functions(ux);u=lambda n:func(ux,us,n)
    model=text(root/'wad/modules/Domenia-Experience.Model.ps1');ms=functions(model);m=lambda n:func(model,ms,n)
    ui=text(root/'wad/modules/Domenia-Experience.UI.ps1');ss=functions(ui);a=lambda n:func(ui,ss,n)
    baseline=json.loads(text(root/'wad/tests/experience-baseline-r110.json'))
    changes=[n for n,d in baseline['CoreFunctions'].items() if n not in fs or sha(f(n))!=d]
    observations['ChangedCoreFunctions']=changes
    observations['UnchangedCoreFunctions']=len(baseline['CoreFunctions'])-len(changes)
    observations['OriginalCoreFunctions']=len(baseline['CoreFunctions'])
    ck('All 573 original core functions retained, no duplicate definitions',set(fs)==set(baseline['CoreFunctions']) and all(len(v)==1 for v in fs.values()))
    ck('Exactly the 13 reviewed core functions changed',set(changes)==EXPECTED,str(changes))
    ck('New module function names do not collide with existing functions',not(set(ms)&set(fs) or set(ss)&set(fs) or set(ms)&set(us) or set(ss)&set(us) or set(ms)&set(ss)))
    for name in ['Invoke-DomeniaInProcessAuthProbe','Start-DomeniaFastLoginAttempt','Update-DomeniaFastLoginAttempt','Complete-DomeniaFastLoginSuccess','Start-DomeniaLoginAuthRunspace','Invoke-GlobalSearch','Get-DomeniaSearchScope','Test-DomeniaSearchStateCurrent','Invalidate-DomeniaSearchResults','Start-DomeniaWriteTask','Assert-DomeniaCapability','Wire-Events']:
        ck('Unchanged engine '+name,sha(f(name))==baseline['CoreFunctions'][name])
    common=re.search(r"(?ms)^\$script:WorkerCommon = @'\n(.*?)\n'@",core)[1]
    ck('Remote worker common source unchanged',sha(common)==baseline['WorkerCommonSha256'])
    registry=dict(re.findall(r'(\w+)\s*=\s*"([A-F0-9]{64})"',f('Get-DomeniaWorkerOperationHashes')))
    literals={sha(match[1]).upper() for match in re.finditer(r"@'\n(.*?)\n'@",core,re.S)}
    ck('All 45 pinned worker bodies resolve and registry is unchanged',len(registry)==45 and registry==baseline['WorkerRegistry'] and set(registry.values())<=literals)
    observations['PinnedWorkersMatched']=len(registry)
    for relative,digest in baseline['ProtectedFiles'].items():
        ck('Protected file unchanged: '+relative,sha((root/relative).read_bytes())==digest)
    for name in ['Get-DomeniaUxLayoutPlan','Get-DomeniaUxOuDisplay','Save-DomeniaUxLayoutSettings','Update-DomeniaUxLayout','Set-DomeniaUxNavigationLayout']:
        if name in baseline['UxFunctions']:
            ck('Preserved collapsible/OU behavior '+name,sha(u(name))==baseline['UxFunctions'][name])
    codepaths=['wad/Domenia-Core.ps1','wad/modules/Domenia-UX.UI.ps1','wad/modules/Domenia-Experience.Model.ps1','wad/modules/Domenia-Experience.UI.ps1','wad/maintenance/Preview-DomeniaUi.ps1','wad/maintenance/Preview-DomeniaLogin.ps1','wad/maintenance/Verifier-Paquet.ps1','wad/tests/Test-DomeniaExperience.ps1','wad/tests/Test-DomeniaTheme.ps1','INSTALLER-MISE-A-JOUR.ps1']
    for path in codepaths:
        ck('Approximate lexical balance, NOT native parse: '+path,lambda p=root/path:delimiters(text(p)))
    ck('Edited PowerShell files retain UTF-8 BOM',all((root/p).read_bytes().startswith(b'\xef\xbb\xbf') for p in codepaths))
    documents={};controls={}
    for factory,old in baseline['OriginalControls'].items():
        body=f(factory);match=re.search(r'@"\n(.*?)\n"@',body,re.S) or re.search(r"@'\n(.*?)\n'@",body,re.S)
        try:
            doc=ET.fromstring(match[1]);documents[factory]=doc;controls[factory]=window_controls(doc)
        except Exception as e:
            ck('XML '+factory,False,str(e));continue
        ck('XML and unique template/window namescopes: '+factory,lambda doc=doc:assert_scoped_names(doc))
        new={k:v.tag.rsplit('}',1)[-1] for k,v in controls[factory].items()}
        ck('Original controls and types retained: '+factory,all(new.get(n)==t for n,t in old.items()))
    c=controls['Get-MainXaml'];login=controls['Get-DomeniaStandardLoginXaml'];r=documents['Get-MainXaml']
    keys={node.get(X+'Key') for node in r.iter() if node.get(X+'Key')}
    refs={ref for node in r.iter() for value in node.attrib.values() for ref in re.findall(r'\{(?:Static|Dynamic)Resource ([\w.]+)\}',value)}
    ck('Main XAML static/dynamic named resources are defined',refs<=keys,str(sorted(refs-keys)))
    ck('New activity view is nested in the existing tools host','TabExperience' in {n.get(X+'Name') for n in c['ApplicationToolTabs'].iter()})
    ck('OU tree and results remain together','TvDirectory' in {n.get(X+'Name') for n in c['WsSearch'].iter()} and 'DgObjects' in {n.get(X+'Name') for n in c['WsSearch'].iter()})
    ck('Local filter controls track the result write lock',all(c[n].get('IsEnabled')=='{Binding IsEnabled, ElementName=DgObjects}' for n in ['TxtSuiteResultFilter','BtnSuiteResultClear']))
    ck('Local timer checks disabled grid before applying pending filter',"$grid.IsEnabled" in a('Initialize-DomeniaExperience') and "if($null -ne $grid -and $grid.IsEnabled){Apply-DomeniaPresenceFilter}" in ui)
    ck('Result grid virtualization retained',c['DgObjects'].get('EnableRowVirtualization')=='True' and c['DgObjects'].get('VirtualizingPanel.VirtualizationMode')=='Recycling')
    catalogue=json.loads(text(root/'wad/modules/Domenia-UX.help.json'));catalog={n['Name']:n for n in catalogue}
    ck('Unique names in static help catalogue',len(catalogue)==len(catalog))
    added={name:node for scope,cs in controls.items() for name,node in cs.items() if name not in baseline['OriginalControls'][scope] and node.tag.rsplit('}',1)[-1] in INTERACTIVE}
    def validate_help():
        for name,node in added.items():
            assert name in catalog,name+' not in catalogue'
            assert node.get('ToolTip') and node.get('ToolTipService.ShowOnDisabled')=='True',name+' tooltip'
            assert node.get('AutomationProperties.Name') and node.get('AutomationProperties.HelpText'),name+' accessibility'
    ck('All new interactive controls have catalogue, tooltip and accessible names',validate_help)
    observations['NewInteractiveControls']=sorted(added)
    ck('Login remains non-maximizable with adaptive height',documents['Get-DomeniaStandardLoginXaml'].get('ResizeMode')=='NoResize' and documents['Get-DomeniaStandardLoginXaml'].get('SizeToContent')=='Height')
    ck('Caps Lock hint is initially collapsed, never reads password',login['LblSuiteCapsLock'].get('Visibility')=='Collapsed' and 'IsKeyToggled' in a('Update-DomeniaExperienceCapsLock') and 'Password' not in a('Update-DomeniaExperienceCapsLock'))
    ck('Theme saving error is a visible independent message','LblSuiteThemeSave' in login and "Thème appliqué mais non enregistré" in a('Switch-DomeniaExperienceLoginTheme'))
    ck('Login theme does not run authentication or modify credential fields',not re.search(r'(?i)(Start-DomeniaFastLoginAttempt|Start-DomeniaLoginAuthRunspace|\.Password\s*=|\.Credential\s*=)',a('Switch-DomeniaExperienceLoginTheme')))
    design=json.loads(text(root/'wad/modules/SupportSuite.UI.json'))
    ck('Contract names only DOMENIA as actually implemented',design['SchemaVersion']==1 and design['ImplementedIn']==['DOMENIA R1.11'])
    ck('Contract is fixed local JSON, validated and size limited','32768' in m('Get-SuiteDesign') and "'SupportSuite.UI.json'" in m('Get-SuiteDesign') and 'SchemaVersion -ne 1' in m('Get-SuiteDesign'))
    ck('Main and startup read the same shared palette','Get-SuitePalette' in f('Get-DomeniaBootThemePalette') and 'Get-SuitePalette' in u('Set-DomeniaUxPalette'))
    ratios={}
    for theme,p in design['Palettes'].items():
        pairs=[('TextColor','BgCard'),('MutedColor','BgCard'),('TextColor','BgInput'),('MutedColor','DataGridAlt'),('BtnFg','BtnBg'),('RowSelFg','RowSelBg'),('InfoFg','InfoBg'),('AccentText','AccentSoft'),('StatusError','BgCard'),('StatusWarning','BgCard'),('StatusSuccess','BgCard')]
        for foreground,background in pairs:
            ratio=contrast(p[foreground],p[background]);ratios[theme+'/'+foreground+'/'+background]=round(ratio,3)
        ratios[theme+'/White/AccentColor']=round(contrast('#FFFFFF',p['AccentColor']),3)
    ck('Selected opaque text palette pairs meet 4.5:1 (not a full accessibility audit)',all(r>=4.5 for r in ratios.values()),'Minimum '+str(min(ratios.values())))
    observations['CalculatedContrastRatios']=ratios
    steps=[node for node in r.iter() if node.get(X+'Key')=='UxStepButton'];ck('Step active indication follows navigation Tag, disabled text not faded',len(steps)==1 and any(n.get('Property')=='Tag' and n.get('Value')=='Active' for n in steps[0].iter()) and any(n.get('Property')=='Opacity' and n.get('Value')=='1' for n in steps[0].iter()))
    ck('Valid JSON profile takes precedence over legacy configuration','$validJsonProfile' in f('Load-DomeniaSettings') and 'if (-not $validJsonProfile -and $legacyProfile' in f('Load-DomeniaSettings'))
    ck('Preference normalization is closed over existing default keys','foreach($key in $Defaults.Keys)' in m('ConvertTo-DomeniaExperienceSettings') and '[bool]::TryParse' in m('ConvertTo-SuiteFlag') and 'IsNaN' in m('ConvertTo-SuiteNumber') and 'IsInfinity' in m('ConvertTo-SuiteNumber'))
    defaults=f('Get-DomeniaDefaultSettings');ck('Transient filter, passwords and write enablement are not new defaults',all(n not in defaults for n in ['TxtSuiteResultFilter','Password','Credential','ReadOnlyMode','ConfirmWrite']))
    ck('Theme save checks result and throws only when requested','$written=Write-DomeniaPreference' in f('Save-DomeniaSettings') and 'if(-not $written){throw' in f('Save-DomeniaSettings') and '-Immediate -ThrowOnFailure' in f('Save-DomeniaTheme'))
    ck('Export is based on visible grid and excludes hidden selected items','Get-DomeniaExperienceVisibleRows' in f('Export-CurrentResults') and '$script:BranchObjects' not in f('Export-CurrentResults') and '[object]::ReferenceEquals' in a('Get-DomeniaExperienceExportRows'))
    ck('Result filter uses literal matching over six fixed nonsensitive fields',"@('Type','Name','Login','UPN','Association','Presence')" in m('Test-DomeniaExperienceRow') and 'IndexOf' in m('Test-DomeniaExperienceRow') and '2048' in m('Test-DomeniaExperienceRow') and '120' in m('Test-DomeniaExperienceRow'))
    ck('Local result filter neither invokes LDAP nor mutates search root',not re.search(r'(?i)(Invoke-GlobalSearch|Directory(Searcher|Entry)|\.BaseDn\s*=|Start-UiTask)',m('Test-DomeniaExperienceRow')))
    ck('Activity projection excludes payload and output assignments',not re.search(r'(?im)^\s*(CallbackState|Payload|Credential|Password|Output)\s*=',m('Get-DomeniaExperienceTaskRow')))
    ck('Cancellation rechecks live job, never force-stops a write',all(t in a('Stop-DomeniaExperienceSelectedRead') for t in ['Test-DomeniaExperienceCanCancel','Request-UiTaskStop','$script:AsyncJobs[$id]']) and '-Force' not in a('Stop-DomeniaExperienceSelectedRead').split('Request-UiTaskStop')[0] and 'Request-UiTaskStop -Id $id -Reason' in a('Stop-DomeniaExperienceSelectedRead') and '-not $Job.IsWrite' in m('Test-DomeniaExperienceCanCancel'))
    ck('Malformed jobs and cross-session cancellation rejected by guards',all(t in m('Test-DomeniaExperienceCanCancel') for t in ['SessionEpoch','-isnot [bool]','NonCancellable','CancelRequested','return $false']))
    ck('No invented completed task history or automatic replay',"$state='À vérifier'" in m('Get-DomeniaExperienceTaskRow') and "$state='Arrêt demandé'" in m('Get-DomeniaExperienceTaskRow') and not re.search(r"\$state='(?:Succès|Vérifié|Terminé)'",m('Get-DomeniaExperienceTaskRow')))
    ck('Activity uses existing throttled UI updates and bounded rows','Update-DomeniaExperienceActivity -Force:$Force' in f('Update-TaskUi') and '$refreshMs' in f('Update-TaskUi') and '64' in a('Update-DomeniaExperienceActivity') and '$tab.IsSelected' in a('Update-DomeniaExperienceActivity'))
    ck('Local filter timer stops on close and no network timer added',"FromMilliseconds(180)" in ui and "$script:ExperienceFilterTimer=$null" in a('Initialize-DomeniaExperience'))
    ck('New UI modules have no AD mutation or remote process invocation',not re.search(r'(?i)(\b(?:Set|Remove|Add|Disable|Enable)-AD(?:User|Computer|Group|Object)\b|\bAdd-Computer\b|\bRestart-Computer\b|\bInvoke-Command\b|\bStart-Process\b|\bInvoke-WebRequest\b|\bInvoke-RestMethod\b|dsregcmd|schtasks)',model+'\n'+ui))
    ck('Log find pauses scrolling without clearing/rewriting log','IsChecked=$false' in a('Find-DomeniaExperienceLog') and '.Select(' in a('Find-DomeniaExperienceLog') and '.Clear(' not in a('Find-DomeniaExperienceLog') and '.Text=' not in a('Find-DomeniaExperienceLog'))
    ck('Collapsed log hides both search controls and log without deletion',"@('UxSuiteLogTools','TxtUiLog')" in a('Set-DomeniaExperienceJournalLayout') and '.Clear(' not in a('Set-DomeniaExperienceJournalLayout') and '.Text=' not in a('Set-DomeniaExperienceJournalLayout'))
    ck('Log font and expanded height bounded','-Minimum 10 -Maximum 18' in a('Apply-DomeniaExperienceLogReading') and '-Minimum 100 -Maximum 600' in a('Set-DomeniaExperienceJournalLayout'))
    native=text(root/'wad/tests/Test-DomeniaExperience.ps1');native_count=len(re.findall(r'^Check-Suite ',native,re.M))
    ck('48 isolated PowerShell test definitions provided, not executed',native_count==48)
    preview=text(root/'wad/maintenance/Preview-DomeniaUi.ps1');loginview=text(root/'wad/maintenance/Preview-DomeniaLogin.ps1')
    ck('Previews extract fixed presentation functions, no real app bootstrap','[Management.Automation.Language.Parser]::ParseFile($corePath' in preview and '$presentationNames = @(' in preview and '& $corePath' not in preview and '. $corePath' not in preview)
    ck('Preview uses isolated settings and empty job fixture','function Save-DomeniaSettings ' in preview and '$script:AsyncJobs=@{}' in preview and 'function Save-DomeniaTheme ' in loginview)
    ck('Login verification uses appearance-only mock, no live auth invocation','PreviewLoginTheme' in loginview and 'Start-DomeniaFastLoginAttempt' not in loginview)
    installer=text(root/'INSTALLER-MISE-A-JOUR.ps1');verifier=text(root/'wad/maintenance/Verifier-Paquet.ps1')
    ck('New native suite blocks incomplete tests before backup or copy',installer.index('$suiteTests=')<installer.index('$backupParent=') and 'suiteResult.Passed -lt 48' in installer and '$LASTEXITCODE -ne 0' in installer)
    ck('Read-only verifier checks hash and native syntax without bootstrapping','Get-FileHash' in verifier and 'Parser]::ParseFile' in verifier and 'NoApplicationStartup=$true' in verifier and not re.search(r'(?i)(Start-Process|Invoke-Expression|Domenia-Core.ps1\s*\))',verifier))
    ck('Verifier bounds manifest and rejects links/path traversal','4MB' in verifier and '5000' in verifier and 'ReparsePoint' in verifier and "-contains '..'" in verifier and "StartsWith($prefix" in verifier)
    ck('Verifier does not claim authentic publisher from self-supplied hashes','SignatureVerified=$false' in verifier and 'provenance' in verifier)
    ck('Write locks, read-only defaults and auth source were not softened',all(sha(f(n))==baseline['CoreFunctions'][n] for n in ['Assert-DomeniaCapability','Start-DomeniaWriteTask','Apply-CurrentPermissionUi','Request-UiTaskStop']))
    observations['PowerShellCasesProvidedNotRun']=native_count
    observations['MainPreviewAssertionDefinitionsProvidedNotRun']=len(re.findall(r'^\s*Test-PreviewAssertion ',preview,re.M))
    observations['NewWpfScenariosProvidedNotRun']=13
    report={'Build':BUILD,'Environment':'Linux/Python, source/XML/contrast/hash checks only','PowerShellExecuted':False,'WpfExecuted':False,'LiveAdExecuted':False,'GPOrRBPCodeModified':False,'Passed':sum(c['Passed'] for c in checks),'Failed':sum(not c['Passed'] for c in checks),'Observations':observations,'Checks':checks}
    args.report.parent.mkdir(parents=True,exist_ok=True)
    args.report.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf8')
    print(json.dumps({k:report[k] for k in ['Build','Passed','Failed']},ensure_ascii=False))
    return int(report['Failed']>0)

if __name__=='__main__':raise SystemExit(main())
