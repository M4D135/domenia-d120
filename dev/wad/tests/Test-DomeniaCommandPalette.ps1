#requires -Version 5.1
# W13 (points 115, 117, 120): command palette in the page, shortcuts and presentation undo of the result list.
# Real rule and adapter modules in a small WPF window (STA); inert doubles of the core. No domain, no network, no worker.
[CmdletBinding()]
param([string]$ReportPath='',[switch]$Quiet)
$ErrorActionPreference='Stop'
# P-CD-09: the catch blocks of the core and of the UI modules trace an ignored error with Write-DomeniaSwallowed, defined
# in the script scope of Domenia-Core.ps1. Functions loaded one by one stay silent here, as before the sweep (no-op double;
# the trace itself is tested in rules/Common.Tests.ps1 and Test-DomeniaFaults.ps1).
function Write-DomeniaSwallowed { param($Category,$Operation,$ErrorRecord,$Now) }
# PF-24 (lot Z04): a catalogued control carries its help in Domenia-UX.help.json only (the XAML keeps it for the
# other controls); this reads the effective tool tip or help text of a node of the main XAML.
$script:TestHelpCatalogue=$null
function Get-TestCatalogueHelp {
    param($Node,[string]$Attribute)
    $value=[string]$Node.GetAttribute($Attribute)
    if($value){return $value}
    if($null -eq $script:TestHelpCatalogue){
        $script:TestHelpCatalogue=@{}
        $catalogue=Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'modules') 'Domenia-UX.help.json'
        foreach($entry in @([IO.File]::ReadAllText($catalogue,[Text.Encoding]::UTF8)|ConvertFrom-Json)){$script:TestHelpCatalogue[[string]$entry.Name]=$entry}
    }
    $name=[string]$Node.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml')
    if($script:TestHelpCatalogue.ContainsKey($name)){return [string]$script:TestHelpCatalogue[$name].Text}
    return ''
}
$wad=Split-Path -Parent $PSScriptRoot
$modules=Join-Path $wad 'modules'
$core=Join-Path $wad 'Domenia-Core.ps1'
$script:Checks=New-Object 'System.Collections.Generic.List[object]'
function Check-Suite {param([string]$Name,[scriptblock]$Code)
    try{if(-not (& $Code)){throw 'Condition non verifiee.'};$script:Checks.Add([pscustomobject]@{Name=$Name;Passed=$true;Detail=''})}
    catch{$script:Checks.Add([pscustomobject]@{Name=$Name;Passed=$false;Detail=$_.Exception.Message})}
}
function Get-SuiteFunctionText {param([string]$Path,[string]$Name)
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
    if(@($errors).Count){throw $errors[0].Message}
    $nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name},$true))
    if($nodes.Count -ne 1){throw ('Definition absente : '+$Name)}
    return [string]$nodes[0].Extent.Text
}
function Import-SuiteFunction {param([string]$Path,[string]$Name) . ([scriptblock]::Create((Get-SuiteFunctionText $Path $Name) -replace ('^function\s+'+[regex]::Escape($Name)+'\b'),('function script:'+$Name)))}
foreach($file in @('Domenia-Common.Model.ps1','Domenia-Continuity.Model.ps1','Domenia-Commands.Model.ps1','Domenia-Commands.UI.ps1')){. (Join-Path $modules $file)}
Import-SuiteFunction (Join-Path $modules 'Domenia-Continuity.UI.ps1') 'Get-DomeniaGridColumnKey'
Import-SuiteFunction (Join-Path $modules 'Domenia-SearchWorkspace.UI.ps1') 'Get-DomeniaResultPresentation'
Import-SuiteFunction (Join-Path $modules 'Domenia-SearchWorkspace.UI.ps1') 'Restore-DomeniaResultPresentation'
Import-SuiteFunction (Join-Path $modules 'Domenia-UX.UI.ps1') 'Set-DomeniaLiveText'

# ---------------------------------------------------------------- inert doubles of the core
function Get-DomeniaControl {param([string]$Name);if($null -eq $script:Ctrl){return $null};return $script:Ctrl[$Name]}
function Set-DomeniaControlText {param([string]$Name,[string]$Text);$c=Get-DomeniaControl $Name;if($null -ne $c){$c.Text=$Text};return $true}
function Set-Status {param($Text,$Level);$script:Status=[string]$Text}
function Write-AppLog {param($Text,$Level)}
function Get-DomeniaSelectedMachineRows {return @()}
function Test-DomeniaOperationsPanelOpen {return $false}
function Hide-DomeniaOperationsPanel {}
function Invoke-DomeniaSafeUiAction {param([string]$Operation,[scriptblock]$Action) & $Action}
function Select-DomeniaWorkspace {param([string]$Workspace,[string]$Inner='',[string]$Tab='') $t=Get-DomeniaControl $Workspace;if(($null -ne $t) -and ($t.Visibility -eq 'Visible')){$t.IsSelected=$true};$script:Workspace=$Workspace}
function Update-DomeniaSearchFilterChips {$script:ChipUpdates++}
function Save-DomeniaGridLayout {param($Grid) $script:LayoutSaves++}
function New-DomeniaTimer {param([string]$Owner,[int]$IntervalMs,[scriptblock]$Tick) $t=[pscustomobject]@{Owner=$Owner;Running=$false};$t|Add-Member -MemberType ScriptMethod -Name Start -Value {$this.Running=$true};$t|Add-Member -MemberType ScriptMethod -Name Stop -Value {$this.Running=$false};return $t}
# The live region announcement is recorded: which control the screen reader is told about, in order.
$script:Announced=New-Object 'System.Collections.Generic.List[string]'
function Send-DomeniaUxLiveChange {param($Control) if($null -ne $Control){$script:Announced.Add([string]$Control.Name)}}
function Test-SuiteFocus {param($Control) return [object]::ReferenceEquals([Windows.Input.FocusManager]::GetFocusedElement($script:Window),$Control)}
function Pump {param($Window);$Window.UpdateLayout();$Window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ApplicationIdle);$Window.UpdateLayout()}

# ---------------------------------------------------------------- syntax tree checks of the real sources
Check-Suite 'P117 : Ctrl+K et le bouton passent par la vue de page, plus aucune fenetre construite' {
    $t=Get-SuiteFunctionText $core 'Show-DomeniaCommandPalette'
    $t.Contains('Show-DomeniaCommandPaletteView') -and $t.Contains('Hide-DomeniaCommandPalette') -and (-not $t.Contains('System.Windows.Window')) -and (-not $t.Contains('Invoke-DomeniaHostWindow'))
}
Check-Suite 'P115 : les raccourcis annonces par la palette sont ceux de la fenetre' {
    $t=Get-SuiteFunctionText $core 'Register-DomeniaShortcuts'
    $registered=@([regex]::Matches($t,'Key="([^"]+)"; Modifiers="([^"]+)"')|ForEach-Object{$_.Groups[1].Value+'|'+$_.Groups[2].Value}|Sort-Object)
    $announced=@(Get-DomeniaKeyboardShortcuts|Where-Object{$_.Scope -eq 'Window'}|ForEach-Object{[string]$_.Key+'|'+[string]$_.Modifiers}|Sort-Object)
    if(($registered -join ',') -cne ($announced -join ',')){throw ('Enregistres : '+($registered -join ',')+' ; annonces : '+($announced -join ','))}
    $true
}
Check-Suite 'P115 : Echap ferme la couche ouverte ou efface la saisie, jamais la liste de resultats' {
    $t=Get-SuiteFunctionText $core 'Register-DomeniaShortcuts'
    $escape=$t.Substring($t.IndexOf('Key="Escape"'))
    $escape=$escape.Substring(0,$escape.IndexOf('foreach ($entry in $map)'))
    $escape.Contains('Hide-DomeniaCommandPalette') -and $escape.Contains('Hide-DomeniaOperationsPanel') -and (-not $escape.Contains('Set-DomeniaItemsSource')) -and (-not $escape.Contains('BranchObjects'))
}
Check-Suite 'P120 : la liste de resultats a son annulation de presentation (puce et Ctrl+Z)' {
    $ws=Join-Path $modules 'Domenia-SearchWorkspace.UI.ps1';$ui=Join-Path $modules 'Domenia-Commands.UI.ps1'
    (Get-SuiteFunctionText $ws 'Update-DomeniaSearchFilterChips').Contains('New-DomeniaPresentationUndoChip') -and (Get-SuiteFunctionText $ws 'Initialize-DomeniaSearchWorkspace').Contains('Initialize-DomeniaPresentationUndo') -and (Get-SuiteFunctionText $ui 'Initialize-DomeniaPresentationUndo').Contains('Invoke-DomeniaPresentationUndoKey -KeyEvent $eventArgs') -and (Get-SuiteFunctionText $ui 'Invoke-DomeniaPresentationUndoKey').Contains('Test-DomeniaPresentationUndoKey')
}
Check-Suite 'P116 : la palette annonce ses changements (etat, detail, motif d un refus sur Entree)' {
    $ui=Join-Path $modules 'Domenia-Commands.UI.ps1'
    (Get-SuiteFunctionText $ui 'Update-DomeniaCommandPaletteList').Contains("Set-DomeniaLiveText -Control (Get-DomeniaControl 'LblPaletteStatus')") -and (Get-SuiteFunctionText $ui 'Update-DomeniaCommandPaletteDetail').Contains("Set-DomeniaLiveText -Control (Get-DomeniaControl 'LblPaletteDetail')") -and (Get-SuiteFunctionText $ui 'Invoke-DomeniaCommandPaletteEntry').Contains('Send-DomeniaUxLiveChange -Control $status') -and (Get-SuiteFunctionText (Join-Path $modules 'Domenia-UX.UI.ps1') 'Set-DomeniaLiveText').Contains('Send-DomeniaUxLiveChange -Control $Control')
}
Check-Suite 'P117/P116 : vue de la palette : noms accessibles, info-bulle egale au texte d aide et au catalogue' {
    [xml]$view=[IO.File]::ReadAllText((Join-Path $modules 'Domenia-CommandPalette.xaml'),[Text.Encoding]::UTF8)
    $help=@(Get-Content -LiteralPath (Join-Path $modules 'Domenia-UX.help.json') -Raw -Encoding UTF8 | ConvertFrom-Json)
    $byName=@{};foreach($entry in $help){$byName[[string]$entry.Name]=$entry}
    $x='http://schemas.microsoft.com/winfx/2006/xaml'
    foreach($name in @('BtnPaletteClose','TxtPaletteSearch','LstPaletteCommands','LblPaletteDetail','LblPaletteStatus')){
        $node=@($view.SelectNodes('//*')|Where-Object{$_.GetAttribute('Name',$x) -eq $name})
        if($node.Count -ne 1){throw ($name+' : '+$node.Count+' occurrence(s)')}
        $tip=[string](Get-TestCatalogueHelp $node[0] 'ToolTip')
        if((-not $tip) -or ($tip -cne [string](Get-TestCatalogueHelp $node[0] 'AutomationProperties.HelpText'))){throw ($name+' : info-bulle et texte d aide differents')}
        if(-not [string]$node[0].GetAttribute('AutomationProperties.Name')){throw ($name+' : nom accessible absent')}
        if((-not $byName.ContainsKey($name)) -or ([string]$byName[$name].Text -cne $tip)){throw ($name+' : catalogue d aide absent ou different')}
    }
    $true
}

# ---------------------------------------------------------------- WPF behaviour (STA)
if([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA){
    Check-Suite 'Comportement WPF (STA requis)' {throw 'Fil STA requis : lancer la suite avec -STA.'}
}else{
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
    $xaml=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Width="900" Height="640" ShowActivated="False">
  <Grid>
    <TabControl x:Name="WorkspaceTabs">
      <TabItem x:Name="WsSearch" Header="Rechercher">
        <StackPanel>
          <DataGrid x:Name="DgObjects" AutoGenerateColumns="False" Height="200" CanUserSortColumns="True" CanUserReorderColumns="True">
            <DataGrid.Columns>
              <DataGridTextColumn Header="Nom" Binding="{Binding Name}" Width="200"/>
              <DataGridTextColumn Header="Type" Binding="{Binding Type}" Width="90"/>
            </DataGrid.Columns>
          </DataGrid>
          <TextBox x:Name="TxtSuiteResultFilter"/>
          <ComboBox x:Name="CmbPresenceFilter"><ComboBoxItem Content="Tous" IsSelected="True"/><ComboBoxItem Content="En ligne"/></ComboBox>
          <WrapPanel x:Name="PnlSearchFilterChips"/>
          <TextBox x:Name="TxtGlobalSearch"/>
          <Button x:Name="BtnCommandPalette" Content="Ctrl K"/>
        </StackPanel>
      </TabItem>
      <TabItem x:Name="WsComputer" Header="Poste">
        <TabControl x:Name="ComputerTabs">
          <TabItem x:Name="TabComputerMain" Header="Poste">
            <StackPanel>
              <Button x:Name="BtnCompPing" Content="Ping"/>
              <Expander x:Name="ExpComputerTools" Header="Outils"><Button x:Name="BtnCompRestart" Content="Redémarrer"/></Expander>
            </StackPanel>
          </TabItem>
          <TabItem x:Name="TabWmi" Header="WMI" Visibility="Collapsed"><Button x:Name="BtnLoadSoftware" Content="Logiciels"/></TabItem>
        </TabControl>
      </TabItem>
    </TabControl>
    <Grid x:Name="DomeniaDialogLayer" Visibility="Collapsed"/>
  </Grid>
</Window>
'@
    [xml]$doc=$xaml;$reader=New-Object Xml.XmlNodeReader $doc
    $main=[Windows.Markup.XamlReader]::Load($reader)
    $script:Window=$main;$script:Ctrl=@{}
    foreach($node in $doc.SelectNodes('//*')){$n=$node.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml');if($n){$script:Ctrl[$n]=$main.FindName($n)}}
    $main.ShowInTaskbar=$false;$main.WindowStartupLocation='Manual';$main.Left=0;$main.Top=0
    $script:Clicks=@{}
    foreach($name in @('BtnCompPing','BtnCompRestart','BtnLoadSoftware')){$script:Clicks[$name]=0;$script:Ctrl[$name].Tag=$name;$script:Ctrl[$name].Add_Click({param($sender,$eventArgs) $script:Clicks[[string]$sender.Tag]++})}
    $script:Conn=[pscustomobject]@{BaseDn='DC=example,DC=invalid'};$script:ReadOnlyMode=$false;$script:DemoMode=$false
    $script:SelectedObject=[pscustomobject]@{Type='Machine';Name='PC-TEST-01'}
    $main.Show();try{[void]$main.Activate()}catch{};Pump $main
    try{
        Check-Suite 'P117 : portee d un controle : onglet masque ou bouton atteignable, chemin des onglets' {
            $ping=Get-DomeniaControlReach $script:Ctrl['BtnCompPing'];$soft=Get-DomeniaControlReach $script:Ctrl['BtnLoadSoftware'];$restart=Get-DomeniaControlReach $script:Ctrl['BtnCompRestart']
            $ping.Reachable -and (-not $soft.Reachable) -and $restart.Reachable -and (@($restart.Path).Count -eq 3) -and ($restart.Path[0].Name -eq 'WsComputer') -and ($restart.Path[2] -is [Windows.Controls.Expander])
        }
        Check-Suite 'P117 : une ecriture est amenee a l ecran sans jamais etre cliquee' {
            $entries=@(Get-DomeniaPaletteEntries -Context (Get-DomeniaPaletteContext))
            $restart=@($entries|Where-Object{$_.Id -eq 'restart'})[0]
            Invoke-DomeniaPaletteDecision -Entry $restart -Decision (Get-DomeniaPaletteDecision -Entry $restart);Pump $main
            $restart.Available -and ($script:Clicks['BtnCompRestart'] -eq 0) -and $script:Ctrl['WsComputer'].IsSelected -and $script:Ctrl['ExpComputerTools'].IsExpanded -and (Test-SuiteFocus $script:Ctrl['BtnCompRestart']) -and $script:Status.Contains('rien nʼest encore écrit')
        }
        Check-Suite 'P117 : une lecture d un bouton actif part une fois ; desactive ou masque, rien ne part' {
            $entries=@(Get-DomeniaPaletteEntries -Context (Get-DomeniaPaletteContext))
            $ping=@($entries|Where-Object{$_.Id -eq 'ping'})[0];$software=@($entries|Where-Object{$_.Id -eq 'software'})[0]
            Invoke-DomeniaPaletteDecision -Entry $ping -Decision (Get-DomeniaPaletteDecision -Entry $ping);Pump $main
            $script:Ctrl['BtnCompPing'].IsEnabled=$false
            Invoke-DomeniaPaletteDecision -Entry $ping -Decision (Get-DomeniaPaletteDecision -Entry $ping);Pump $main
            $refused=$script:Status
            $script:Ctrl['BtnCompPing'].IsEnabled=$true
            ($script:Clicks['BtnCompPing'] -eq 1) -and $refused.Contains('rien nʼa été lancé') -and (-not $software.Available) -and ((Get-DomeniaPaletteDecision -Entry $software).Action -eq 'None')
        }
        Check-Suite 'P117/P115 : palette dans la page : ouverture, filtre au clavier, Echap ferme et rend le focus' {
            $script:Ctrl['WsSearch'].IsSelected=$true;Pump $main
            $script:Ctrl['TxtGlobalSearch'].Focus()|Out-Null;Pump $main
            $opened=Show-DomeniaCommandPaletteView;Pump $main
            $layer=$script:Ctrl['DomeniaDialogLayer'];$list=Get-DomeniaControl 'LstPaletteCommands';$box=Get-DomeniaControl 'TxtPaletteSearch'
            $inLayer=($layer.Visibility -eq 'Visible') -and ($layer.Children.Count -eq 1) -and ($list.Items.Count -gt 10) -and (Test-SuiteFocus $box)
            $box.Text='redemarrer';Pump $main
            $filtered=($list.Items.Count -ge 1) -and ($list.SelectedItem.Id -eq 'restart') -and ([string](Get-DomeniaControl 'LblPaletteDetail').Text).Contains('confirmation')
            $key=New-Object Windows.Input.KeyEventArgs ([Windows.Input.Keyboard]::PrimaryDevice),([Windows.PresentationSource]::FromVisual($box)),0,([Windows.Input.Key]::Escape)
            $key.RoutedEvent=[Windows.Input.Keyboard]::PreviewKeyDownEvent;$box.RaiseEvent($key);Pump $main
            $opened -and $inLayer -and $filtered -and (-not (Test-DomeniaCommandPaletteOpen)) -and ($layer.Visibility -eq 'Collapsed') -and (Test-SuiteFocus $script:Ctrl['TxtGlobalSearch'])
        }
        Check-Suite 'P117 : Entree sur une action indisponible garde la palette ouverte et dit pourquoi' {
            [void](Show-DomeniaCommandPaletteView);Pump $main
            $script:Announced.Clear()
            (Get-DomeniaControl 'TxtPaletteSearch').Text='verrouillages';Pump $main
            $typedAnnounced=$script:Announced.Contains('LblPaletteStatus') -and $script:Announced.Contains('LblPaletteDetail')
            $row=(Get-DomeniaControl 'LstPaletteCommands').SelectedItem
            $script:Announced.Clear()
            Invoke-DomeniaCommandPaletteEntry -Row $row;Pump $main
            Invoke-DomeniaCommandPaletteEntry -Row $row;Pump $main
            # The focus stays in the field: the reason is told to the screen reader at each Entrée, even unchanged.
            $told=@($script:Announced|Where-Object{$_ -eq 'LblPaletteStatus'}).Count
            $still=Test-DomeniaCommandPaletteOpen;$why=[string](Get-DomeniaControl 'LblPaletteStatus').Text
            Hide-DomeniaCommandPalette;Pump $main
            ($row.Id -eq 'lockouts') -and $still -and $why.Contains('Sélectionnez un utilisateur') -and ($row.Glyph -eq [string][char]0x2298) -and $typedAnnounced -and ($told -eq 2)
        }
        Check-Suite 'P120 : filtre puis tri : une etape chacun, Ctrl+Z rend la liste precedente, la puce dit quoi' {
            $script:ChipUpdates=0;$script:LayoutSaves=0
            Initialize-DomeniaPresentationUndo
            $script:Ctrl['TxtSuiteResultFilter'].Text='compta';Save-DomeniaPresentationStep
            $chip=New-DomeniaPresentationUndoChip
            $chipText=[string]$chip.Content
            $grid=$script:Ctrl['DgObjects'];$grid.Items.SortDescriptions.Add((New-Object ComponentModel.SortDescription 'Name','Ascending'));Save-DomeniaPresentationStep
            $afterSort=Get-DomeniaPresentationUndoText $script:DomeniaPresentationHistory
            Undo-DomeniaResultPresentation;Pump $main
            $sortGone=($grid.Items.SortDescriptions.Count -eq 0) -and ($script:Ctrl['TxtSuiteResultFilter'].Text -eq 'compta')
            Undo-DomeniaResultPresentation;Pump $main
            $chipText.Contains('filtre de la liste') -and ($afterSort -eq 'tri') -and $sortGone -and ($script:Ctrl['TxtSuiteResultFilter'].Text -eq '') -and ($null -eq (New-DomeniaPresentationUndoChip)) -and ($script:LayoutSaves -eq 2) -and $script:Status.Contains('Aucune opération sur lʼannuaire')
        }
        Check-Suite 'P120 : Ctrl+Z depuis la liste annule ; depuis un champ de saisie, ou sans Ctrl, rien n est annule' {
            $grid=$script:Ctrl['DgObjects'];$filter=$script:Ctrl['TxtSuiteResultFilter']
            $filter.Text='paris';Save-DomeniaPresentationStep
            $fromGrid=New-Object Windows.Input.KeyEventArgs ([Windows.Input.Keyboard]::PrimaryDevice),([Windows.PresentationSource]::FromVisual($grid)),0,([Windows.Input.Key]::Z)
            $fromGrid.RoutedEvent=[Windows.Input.Keyboard]::PreviewKeyDownEvent
            # Routed through the real handler of the list with the real keyboard (Ctrl not held): Z alone undoes nothing.
            $grid.RaiseEvent($fromGrid);Pump $main
            $keptWithoutCtrl=($filter.Text -eq 'paris') -and (-not $fromGrid.Handled)
            $fromText=New-Object Windows.Input.KeyEventArgs ([Windows.Input.Keyboard]::PrimaryDevice),([Windows.PresentationSource]::FromVisual($filter)),0,([Windows.Input.Key]::Z)
            $fromText.RoutedEvent=[Windows.Input.Keyboard]::PreviewKeyDownEvent
            $filter.RaiseEvent($fromText);Pump $main
            # The same routing function with Ctrl held: refused from the text field, accepted from the list.
            $textRefused=(-not (Invoke-DomeniaPresentationUndoKey -KeyEvent $fromText -Modifiers 'Control')) -and ($filter.Text -eq 'paris')
            $undone=Invoke-DomeniaPresentationUndoKey -KeyEvent $fromGrid -Modifiers 'Control';Pump $main
            $keptWithoutCtrl -and $textRefused -and $undone -and $fromGrid.Handled -and ($filter.Text -eq '')
        }
        Check-Suite 'P120 : liste hors recherche en direct : le filtre local repeint la meme liste, son etape reste annulable' {
            $grid=$script:Ctrl['DgObjects'];$filter=$script:Ctrl['TxtSuiteResultFilter']
            $script:BranchObjects=@([pscustomobject]@{Name='PC-COMPTA-01';Type='Machine'},[pscustomobject]@{Name='PC-RH-01';Type='Machine'})
            $grid.ItemsSource=[Collections.ArrayList]::new(@($script:BranchObjects));Pump $main
            $newList=[object]::ReferenceEquals($script:DomeniaPresentationList,$script:BranchObjects)
            $before=$script:DomeniaPresentationHistory.Undo.Count
            $filter.Text='compta'
            # Apply-DomeniaPresenceFilter through Set-DomeniaItemsSource: a filtered copy of the same list, assigned twice,
            # before the 900 ms step timer records the filter.
            $grid.ItemsSource=$null;$grid.ItemsSource=[Collections.ArrayList]::new(@($script:BranchObjects[0]));Pump $main
            Save-DomeniaPresentationStep
            $text=Get-DomeniaPresentationUndoText $script:DomeniaPresentationHistory
            $count=$script:DomeniaPresentationHistory.Undo.Count
            Undo-DomeniaResultPresentation;Pump $main
            $restored=($filter.Text -eq '')
            $newList -and ($text -eq 'filtre de la liste') -and ($count -eq ($before+1)) -and $restored
        }
    }finally{try{$main.Close()}catch{}}
}
$failed=@($script:Checks|Where-Object{-not $_.Passed})
$report=[ordered]@{Suite='Test-DomeniaCommandPalette';Runtime=$PSVersionTable.PSVersion.ToString();Executed=(Get-Date).ToString('o');Passed=$script:Checks.Count-$failed.Count;Failed=$failed.Count;WpfExecuted=([Threading.Thread]::CurrentThread.GetApartmentState() -eq [Threading.ApartmentState]::STA);NoADAccess=$true;NoNetwork=$true;Tests=$script:Checks.ToArray()}
if(-not $ReportPath){$ReportPath=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-palette-'+[guid]::NewGuid().ToString('N')+'.json')}
[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 7),[Text.UTF8Encoding]::new($false))
if(-not $Quiet){$script:Checks|Format-Table Name,Passed -AutoSize;Write-Host ('Rapport : '+$ReportPath)}
if($failed.Count){throw ('Tests de la palette en echec : '+$failed.Count)}
