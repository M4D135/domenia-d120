#!/usr/bin/env python3
"""R1.7 SOURCE/XML/contrast regression audit. Not a PowerShell or WPF runtime test.
No AD access. Standard library only. Native tests: TESTER-INTERFACE.cmd on Windows.
"""
from pathlib import Path
import argparse, hashlib, json, re, sys, xml.etree.ElementTree as ET
from powershell_lex import functions, mask_ps

X = '{http://schemas.microsoft.com/winfx/2006/xaml}'
TEMPLATES = {'ControlTemplate','DataTemplate','ItemsPanelTemplate'}
INTERACTIVE = {'Button','TextBox','PasswordBox','ComboBox','CheckBox','RadioButton','DataGrid','ListBox','TreeView','TabItem','TabControl','ProgressBar','GridSplitter','Expander'}

def sha(value):
    return hashlib.sha256(value.encode('utf8') if isinstance(value,str) else value).hexdigest()
def local(element): return element.tag.rsplit('}',1)[-1]
def window_controls(root):
    found = {}
    def visit(node, in_template=False):
        in_template |= local(node) in TEMPLATES
        name = node.get(X+'Name')
        if name and not in_template: found[name] = node
        for child in node: visit(child,in_template)
    visit(root)
    return found

def assert_scoped_names(root):
    seen = set()
    def visit(node,scope='window'):
        if local(node) in TEMPLATES: scope=id(node)
        name=node.get(X+'Name')
        if name:
            if (scope,name) in seen: raise AssertionError('Duplicate in namescope: '+name)
            seen.add((scope,name))
        for child in node:visit(child,scope)
    visit(root)

def cell_collisions(root):
    """Deux controles interactifs places dans la meme cellule d'une Grid se recouvrent a l'ecran.

    Seuls les controles interactifs sont compares : un libelle et son champ partagent legitimement une
    ligne, et une zone de repli peut volontairement se superposer a un conteneur. Un controle declare
    Collapsed ou Hidden ne compte pas : le journal brut et son pendant lisible se partagent une ligne,
    un seul des deux est montre. Deux TextBox, deux ComboBox ou un bouton et une zone de texte visibles
    dans la meme cellule ne sont jamais voulu.
    """
    hits = []
    for grid in root.iter():
        if local(grid) != 'Grid': continue
        cells = {}
        for child in grid:
            if local(child) not in INTERACTIVE: continue
            if (child.get('Visibility') or '') in ('Collapsed','Hidden'): continue
            raw_row = child.get('Grid.Row'); raw_col = child.get('Grid.Column')
            if raw_row is None and raw_col is None: continue
            try:
                row = int(raw_row or 0); col = int(raw_col or 0)
                span_row = int(child.get('Grid.RowSpan') or 1); span_col = int(child.get('Grid.ColumnSpan') or 1)
            except ValueError: continue
            label = local(child) + '/' + (child.get(X+'Name') or '')
            for r in range(row, row + span_row):
                for c in range(col, col + span_col):
                    if (r, c) in cells: hits.append((local(grid) + ' r' + str(r) + 'c' + str(c), cells[(r, c)], label))
                    else: cells[(r, c)] = label
    return hits

def assert_no_cell_collision(root):
    hits = cell_collisions(root)
    if hits: raise AssertionError('Controls sharing one grid cell: ' + '; '.join(' + '.join(h[1:]) for h in hits))

def outside(source,spans):
    result=[];previous=0
    for start,end in sorted(x[0] for x in spans.values()):
        result.append(source[previous:start]);previous=end
    result.append(source[previous:]);text=''.join(result)
    text=re.sub(r'2026\.09\.21-R1\.[67]-(?:APPLEUX|SIDEBAR)','<BUILD>',text)
    text=text.replace('DOMENIA 1.0 R1.6 APPLEUX','<DOMENIABUILD>').replace('DOMENIA 1.0 R1.7 INTERFACE GUIDEE','<DOMENIABUILD>')
    return text.replace("    . (Join-Path $PSScriptRoot 'modules\\Domenia-UX.UI.ps1')\n",'')

def contrast(foreground,background):
    def luminance(color):
        rgb=[int(color[i:i+2],16)/255 for i in (1,3,5)]
        linear=[x/12.92 if x<=.04045 else ((x+.055)/1.055)**2.4 for x in rgb]
        return sum(x*w for x,w in zip(linear,(.2126,.7152,.0722)))
    a,b=sorted((luminance(foreground),luminance(background)))
    return (b+.05)/(a+.05)

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--root',type=Path,default=Path(__file__).resolve().parents[2])
    ap.add_argument('--report',type=Path,default=Path('/tmp/domenia-ui-r17.json'))
    args=ap.parse_args();root=args.root.resolve()
    core=(root/'wad/Domenia-Core.ps1').read_text(encoding='utf-8-sig')
    module=(root/'wad/modules/Domenia-UX.UI.ps1').read_text(encoding='utf-8-sig')
    preview=(root/'wad/maintenance/Preview-DomeniaUi.ps1').read_text(encoding='utf-8-sig')
    install=(root/'INSTALLER-MISE-A-JOUR.ps1').read_text(encoding='utf-8-sig')
    baseline=json.loads((root/'wad/tests/ui-baseline-r16.json').read_text())
    catalog=json.loads((root/'wad/modules/Domenia-UX.help.json').read_text())
    catalogue={x['Name']:x for x in catalog}
    spans=functions(core);modspans=functions(module)
    def f(name,source=core,table=spans):
        assert len(table[name])==1,name
        a,b=table[name][0];return source[a:b]
    def mf(name): return f(name,module,modspans)
    rows=[]
    def test(name,condition,detail=''):
        try:
            result=condition() if callable(condition) else condition
            if result is False:raise AssertionError(detail or 'Assertion failed')
            status='PASS'
        except Exception as exc: status='FAIL';detail=str(exc)
        rows.append({'Name':name,'Status':status,'Kind':'Source/XML/LocalPython','Detail':detail})
        print(status,name,detail if status=='FAIL' else '')
    def require(condition,detail='Assertion failed'):
        if not condition:raise AssertionError(detail)
    xml=re.search(r'@"\n(.*?)\n"@',f('Get-MainXaml'),re.S)[1]
    mainxml=ET.fromstring(xml);controls=window_controls(mainxml)
    test('566 existing top-level functions retained',set(baseline['Functions']) <= set(spans) and len(spans)==566)
    changed=[n for n,d in baseline['Functions'].items() if sha(f(n))!=d]
    test('Only the 13 reviewed UI functions changed',set(changed)==set(baseline['AllowedChangedFunctions']),str(changed))
    test('553 other core functions exact-match R1.6',len(baseline['Functions'])-len(changed)==553)
    test('Code outside functions unchanged except fixed module import/build',sha(outside(core,spans))==baseline['OutsideFunctionsSha256'])
    common=re.search(r"(?ms)^\$script:WorkerCommon = @'\n(.*?)\n'@",core)[1]
    test('Remote worker common body exact-match',sha(common)==baseline['WorkerCommonSha256'])
    test('No duplicate top-level functions in core/new UI module',all(len(v)==1 for v in spans.values()) and all(len(v)==1 for v in modspans.values()) and not(set(spans)&set(modspans)))
    for rel,digest in baseline['PreservedFiles'].items():
        test('Preserved bytes: '+rel,sha((root/rel).read_bytes())==digest)
    test('All 363 original window-scope controls retain name/type',all(n in controls and local(controls[n])==t for n,t in baseline['MainControls'].items()))
    test('Main XAML has valid separate template namescopes',lambda:assert_scoped_names(mainxml))
    base='<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">{}</Window>'
    test('Audit allows PART names reused in separate templates',lambda:assert_scoped_names(ET.fromstring(base.format('<Window.Resources><ControlTemplate x:Key="A"><Border x:Name="Part"/></ControlTemplate><ControlTemplate x:Key="B"><Border x:Name="Part"/></ControlTemplate></Window.Resources>'))))
    def duplicate_rejected():
        try: assert_scoped_names(ET.fromstring(base.format('<StackPanel><Button x:Name="A"/><Button x:Name="A"/></StackPanel>')))
        except AssertionError: return True
        return False
    test('Audit still rejects duplicate controls in same scope',duplicate_rejected)
    def cell_collision_rejected():
        try: assert_no_cell_collision(ET.fromstring(base.format('<Grid><TextBox Grid.Row="8" Grid.Column="3"/><TextBox Grid.Row="8" Grid.Column="3"/></Grid>')))
        except AssertionError: return True
        return False
    test('Audit rejects two interactive controls in one grid cell',cell_collision_rejected)
    test('No interactive control pair shares a grid cell in main XAML',lambda:not cell_collisions(mainxml),str(cell_collisions(mainxml))[:400])
    def collapsed_pair_accepted():
        try: assert_no_cell_collision(ET.fromstring(base.format('<Grid><TextBox Grid.Row="2"/><ListBox Grid.Row="2" Visibility="Collapsed"/></Grid>')))
        except AssertionError: return False
        return True
    test('Audit tolerates a collapsed control sharing a cell',collapsed_pair_accepted)
    test('Core native preflight mirrors namescope separation',"$scopedName=$scopeId+'|'+$controlName" in f('Assert-DomeniaXamlPreflight'))
    keys={e.get(X+'Key') for e in mainxml.iter() if e.get(X+'Key')}
    refs=re.findall(r'\{StaticResource\s+([^}]+)\}',xml)
    test('All main static resource names resolve in literal resources',set(refs)-{'{x:Type TextBox'}<=keys,str(sorted(set(refs)-keys-{'{x:Type TextBox'})))
    test('Header search is the original TxtGlobalSearch control',local(controls['TxtGlobalSearch'])=='TextBox' and xml.count('x:Name="TxtGlobalSearch"')==1)
    test('Sidebar contains nine allowlisted destinations',len([n for n in controls if n.startswith('BtnUxNav')])==9)
    routes=set(re.findall(r"'([^']+)'",mf('Get-DomeniaUxRouteNames')))
    test('All sidebar/home/step routes exist',all(e.get('Uid') in routes for n,e in controls.items() if n.startswith(('BtnUxNav','BtnUxHome','BtnUxStep'))))
    test('Annuaire remains present as its own workspace','TabDirectory' in controls and 'TvDirectory' in controls)
    test('Original top-level TabControl is retained behind sidebar',controls['WorkspaceTabs'].get('Style')=='{StaticResource UxWorkspaceHost}')
    test('Real active nav state is synchronized with selection',"$button.Tag = if ($route -eq $current) { 'Active' }" in mf('Sync-DomeniaUxNavigation'))
    test('Unknown navigation commands rejected',"$Route -notin @(Get-DomeniaUxRouteNames)" in mf('Invoke-DomeniaUxRoute'))
    test('Unavailable navigation target never forcibly enabled','-not $target.IsEnabled' in mf('Invoke-DomeniaUxRoute'))
    test('Context type and detail profile are intersected',"TabWmi=($expert -and $ObjectType -eq 'Machine')" in mf('Update-DomeniaUxProfileVisibility'))
    test('Type refresh reapplies UI profile',"Update-DomeniaUxProfileVisibility -ObjectType $Type" in f('Set-VisibleTabsForType'))
    test('Hidden detail selection falls back to visible tab','if ($item.Visibility -eq [Windows.Visibility]::Visible)' in mf('Update-DomeniaUxProfileVisibility'))
    test('Profile changes never toggle readonly',not re.search(r'\$script:ReadOnlyMode\s*=|\.IsChecked\s*=',f('Apply-DomeniaUiProfile')))
    # Each permission expression remains identical; only the tooltip restore is new.
    restored=f('Apply-CurrentPermissionUi')
    restored=re.sub(r'^\s*Restore-DomeniaUxBaseToolTip -Name \$name\n','',restored,flags=re.M)
    test('Permission engine unchanged after removing help-only hook',sha(restored)==baseline['Functions']['Apply-CurrentPermissionUi'])
    test('Help catalogue has no duplicate/empty entries',len(catalogue)==len(catalog) and all(e['Name'] and e['Title'] and e['Text'] for e in catalog))
    actionable={n:e for n,e in controls.items() if local(e) in INTERACTIVE}
    test('All named main interactive controls have static descriptions',all(n in catalogue and bool(e.get('ToolTip')) for n,e in actionable.items()))
    test('All named main interactive controls have accessible names/help',all(e.get('AutomationProperties.Name') and e.get('AutomationProperties.HelpText') for e in actionable.values()))
    test('Help enabled even on disabled main controls',all(e.get('ToolTipService.ShowOnDisabled')=='True' for e in actionable.values()))
    helpcode='\n'.join(mf(n) for n in ('Get-DomeniaUxHelpEntry','Get-DomeniaUxControlHelpText','Initialize-DomeniaUxControlHelp','Show-DomeniaUxControlHelp'))
    test('Help never reads runtime Text/Password/Content/selection/DataContext',not re.search(r'\$(?:Control|sender)\.(?:Text|Password|Content|SelectedItem|DataContext|Tag)\b',mask_ps(helpcode)[0],re.I))
    test('Core friendly-label helper no longer reflects input data','Get-DomeniaUxHelpEntry' in f('Get-DomeniaFriendlyControlLabel') and '$Control.Text' not in f('Get-DomeniaFriendlyControlLabel'))
    test('Context title variable is separate from Title parameter',"$titleControl = Get-DomeniaControl" in f('Set-DomeniaContextHint') and not re.search(r'\$title\s*=',mask_ps(f('Set-DomeniaContextHint'))[0],re.I))
    test('Per-control help registration is idempotent',"$Control.Resources.Contains('Domenia.UxHelpAttached')" in mf('Initialize-DomeniaUxControlHelp'))
    test('Help has keyboard-focus and tooltip-open handlers','Add_GotKeyboardFocus' in mf('Initialize-DomeniaUxControlHelp') and 'Add_ToolTipOpening' in mf('Initialize-DomeniaUxControlHelp'))
    test('Child focus cannot replace specific help with parent help','$sender -eq $eventArgs.OriginalSource' in mf('Initialize-DomeniaUxControlHelp'))
    test('Login help cannot publish input context to another window','[Windows.Window]::GetWindow($Control) -ne $script:Window' in mf('Show-DomeniaUxControlHelp'))
    test('No per-control MouseLeave clears the help pane','Add_MouseLeave' not in module)
    test('Window and support controls registered before use','Initialize-DomeniaUxWindowHelp' in f('ConvertFrom-DomeniaXaml') and 'Initialize-DomeniaUxControlHelp' in f('Apply-AutoTooltips'))
    test('Fresh base description restored before each permission reason', 'Restore-DomeniaUxBaseToolTip -Name $name' in f('Apply-CurrentPermissionUi'))
    test('No AD, remote executor, credential API or executable launch in UI module',not re.search(r'\b(?:Get-ADUser|Get-ADComputer|Get-CimInstance|Invoke-Command|Start-UiTask|Start-Process|Open-AdObject|New-CimSession|LdapConnection|DirectoryEntry|GetNetworkCredential|NetworkCredential|Invoke-Expression)\b',module))
    test('UI module imported before application configuration',core.index(". (Join-Path $PSScriptRoot 'modules\\Domenia-UX.UI.ps1')") < core.index('Load-AppConfig',core.index('# Main autoritaire')))
    test('No external XAML image assets/fonts referenced','Source="http' not in xml and 'Source="https' not in xml and 'San Francisco' not in xml)
    test('Rounded input template preserves PART_ContentHost',xml.count('x:Name="PART_ContentHost"')>=2)
    test('ComboBox preserves popup part and two-way open state','x:Name="PART_Popup"' in xml and 'IsDropDownOpen, RelativeSource={RelativeSource TemplatedParent}, Mode=TwoWay' in xml)
    test('Nav/buttons have visible keyboard focus styles','Property="IsKeyboardFocused" Value="True"' in xml)
    test('Small windows can hide the right panel without reserving 290 px','$width -lt 1360' in module and '$column.Width = [Windows.GridLength]::new(0)' in module)
    test('Help overlay has opaque theme background',controls['UxHelpPanel'].get('Background')=='{DynamicResource WindowBg}')
    test('Journal reduce/expand does not clear or stop logs','UxLogRow' in mf('Switch-DomeniaUxLog') and not re.search(r'Clear\(|Stop-|\.Text\s*=',mf('Switch-DomeniaUxLog')))
    test('Theme resource hook runs without touching theme storage','Set-DomeniaUxPalette -Window $window -Theme $Theme' in f('Apply-DomeniaTheme'))
    for n in ('Load-DomeniaTheme','Save-DomeniaTheme','Get-DomeniaStoredTheme','Get-DomeniaBootThemePalette','Get-DomeniaStandardLoginXaml','Get-DomeniaStartupXaml'):
        test('Unchanged startup/theme function: '+n,sha(f(n))==baseline['Functions'][n])
    palettes=[]
    palettebody=mf('Set-DomeniaUxPalette')
    for mode,body in zip(('Dark','Light'),re.findall(r'@\{(.*?)\n        \}',palettebody,re.S)):
        palettes.append((mode,dict(re.findall(r"(\w+)='(#[0-9A-Fa-f]{6})'",body))))
    test('Both actual theme palettes extracted',len(palettes)==2)
    calculated=[]
    for mode,palette in palettes:
        for fg,bg in [('TextColor','BgCard'),('MutedColor','BgCard'),('TextColor','BgInput'),('BtnFg','BtnBg'),('RowSelFg','RowSelBg'),('AccentText','AccentSoft'),('InfoFg','InfoBg'),('#FFFFFF','AccentColor'),('#FFFFFF','DangerColor')]:
            ratio=contrast(palette.get(fg,fg),palette.get(bg,bg));calculated.append({'Theme':mode,'Foreground':fg,'Background':bg,'Contrast':round(ratio,2)})
            test('Contrast >=4.5:1 '+mode+' '+fg+'/'+bg,ratio>=4.5,str(ratio))
    test('Offline preview extracts only fixed UI functions','presentationNames = @(' in preview and 'FunctionDefinitionAst' in preview and 'Invoke-Expression $nodes[0].Extent.Text' in preview)
    test('Offline preview does not dot-source or invoke the whole core',not re.search(r'(?:&|\.)\s*\$corePath',preview) and 'Initialize-Window' not in preview)
    test('Offline preview is explicitly marked as demo data','APERÇU LOCAL' in preview and 'Données fictives' in preview and 'Aucun annuaire' in preview)
    test('Offline preview disables business-action buttons','^BtnUx' in preview and '$control.IsEnabled=$false' in preview)
    test('Offline native tests include a secret sentinel','SECRET_SENTINEL_98_R17' in preview)
    provided=len(re.findall(r'^\s*Test-PreviewAssertion ',preview,re.M))
    test('25 native WPF scenarios are provided (not run on Linux)',provided==25)
    test('Installer runs native WPF test before code backup/copy',install.index('Verification WPF locale') < install.index('$backupParent=') and 'if($LASTEXITCODE -ne 0)' in install)
    test('Installer requires nonempty successful native report','[int]$interfaceResult.Passed -lt 20' in install)
    test('Edited PowerShell files have BOM for Windows PowerShell 5.1',all((root/p).read_bytes().startswith(b'\xef\xbb\xbf') for p in ('wad/Domenia-Core.ps1','wad/modules/Domenia-UX.UI.ps1','wad/maintenance/Preview-DomeniaUi.ps1','wad/tests/Test-DomeniaInterface.ps1','INSTALLER-MISE-A-JOUR.ps1')))
    def lexical():
        for path in root.rglob('*.ps1'):
            source=path.read_text(encoding='utf-8-sig');masked,issues=mask_ps(source)
            require(not issues,path.name+str(issues));stack=[];pairs={')':'(',']':'[','}':'{'}
            for ch in masked:
                if ch in '([{':stack.append(ch)
                elif ch in ')]}':require(stack and stack[-1]==pairs[ch],path.name+' mismatched delimiters');stack.pop()
            require(not stack,path.name+' unclosed delimiters')
        return True
    test('All delivered scripts pass approximate lexical/bracket checks',lexical)
    report={'Build':'2026.09.21-R1.7-SIDEBAR','Passed':sum(r['Status']=='PASS' for r in rows),'Failed':sum(r['Status']=='FAIL' for r in rows),'NativePowerShellExecuted':False,'WpfExecuted':False,'ActiveDirectoryExecuted':False,'MainWindowControls':len(controls),'OriginalWindowControlsPreserved':len(baseline['MainControls']),'NamedMainInteractiveHelpCount':len(actionable),'HelpCatalogueCount':len(catalog),'UnchangedCoreFunctions':553,'ChangedCoreFunctions':changed,'NewUiFunctions':len(modspans),'NativeScenariosProvidedNotExecuted':provided,'Contrasts':calculated,'Checks':rows}
    args.report.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf8')
    print(json.dumps({k:report[k] for k in ('Passed','Failed','HelpCatalogueCount','NamedMainInteractiveHelpCount','NativePowerShellExecuted','WpfExecuted')},ensure_ascii=False))
    return 1 if report['Failed'] else 0
if __name__=='__main__':sys.exit(main())
