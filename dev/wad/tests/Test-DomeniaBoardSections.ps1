#requires -Version 5.1
# Focused native regression: section ordering, real WPF commands, persistence and undo. No AD/network.
[CmdletBinding()]
param([string]$ReportPath='')
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$wad=Split-Path -Parent $PSScriptRoot
foreach($file in @('Domenia-Common.Model.ps1','Domenia-HealthRules.Model.ps1','Domenia-Boards.Model.ps1','Domenia-Widgets.UI.ps1')){. (Join-Path $wad ('modules/'+$file))}
$script:Settings=@{};$script:Writes=0;$script:Draws=0
function Get-DomeniaSetting {param($Name,$Default) if($script:Settings.ContainsKey($Name)){return $script:Settings[$Name]};return $Default}
function Set-DomeniaSetting {param($Name,$Value) $script:Settings[$Name]=$Value;$script:Writes++}
function Get-DomeniaProbeCatalog {return @()}
function Get-DomeniaControl {param($Name) return $null}
function Show-DomeniaBoard {param($Board,[switch]$Quiet) $script:Draws++}
function Write-DomeniaSwallowed {param($Category,$Operation,$ErrorRecord,$Now) throw $ErrorRecord}
$script:Results=New-Object 'Collections.Generic.List[object]'
function Check {param($Name,[scriptblock]$Body) try {& $Body;$script:Results.Add([pscustomobject]@{Name=$Name;Passed=$true;Error=''})}catch{$script:Results.Add([pscustomobject]@{Name=$Name;Passed=$false;Error=($_|Out-String);Stack=$_.ScriptStackTrace})}}
function Expect {param([bool]$Value,[string]$Message) if(-not $Value){throw $Message}}
function Groups {param($Layout) return ((Get-DomeniaBoardGroups $Layout)-join '|')}
Check 'Delivered layouts put health last on each board; team and personal orders are preserved' {
 foreach($board in @('Fleet','Computer','Software')){
  $layout=@(Get-DomeniaBoardCatalogLayout $board);$groups=@(Get-DomeniaBoardGroups $layout)
  if($groups -contains 'Santé'){Expect ($groups[-1] -eq 'Santé') ($board+': health is not last')}
  $first=$groups[0];$moved=@(Move-DomeniaBoardGroup $layout $first Down)
  $json=ConvertTo-DomeniaBoardLayoutJson $moved
  Expect ((Groups @(ConvertTo-DomeniaBoardLayout -Board $board -Json $json)) -eq (Groups $moved)) 'Personal order lost'
  Expect ((Groups @(Get-DomeniaBoardDefaultLayout -Board $board -TeamJson $json)) -eq (Groups $moved)) 'Team order lost'
 }
}
Check 'A section moves all its interleaved widgets, preserving identities and relative order' {
 $layout=@([pscustomobject]@{Id='a1';Group='A'},[pscustomobject]@{Id='b1';Group='B'},[pscustomobject]@{Id='a2';Group='a'},[pscustomobject]@{Id='c1';Group='C'},[pscustomobject]@{Id='b2';Group='B'})
 $moved=@(Move-DomeniaBoardGroup $layout 'b' Up)
 Expect (($moved.Id -join ',') -ceq 'b1,b2,a1,a2,c1') 'Moved section dropped, duplicated or reordered widgets'
 Expect ([object]::ReferenceEquals($layout[1],$moved[0])) 'Widget identity replaced'
 Expect ((@(Move-DomeniaBoardGroup $layout 'A' Up).Id -join ',') -ceq ($layout.Id -join ',')) 'Boundary changed layout'
 Expect ((@(Move-DomeniaBoardGroup $layout 'missing' Down).Id -join ',') -ceq ($layout.Id -join ',')) 'Unknown section changed layout'
 Expect (@(Move-DomeniaBoardGroup @() 'A' Down).Count -eq 0) 'Empty layout gained widgets'
}
Check 'Native section buttons persist the order and existing Undo restores it' {
 $initial=@(Get-DomeniaBoardCatalogLayout Fleet);$group=@(Get-DomeniaBoardGroups $initial)[0]
 $script:Settings=@{};$script:DomeniaBoardStates=@{};$script:Writes=0
 $section=New-Object Windows.Controls.StackPanel;$title=New-Object Windows.Controls.TextBlock;$title.Text=$group;[void]$section.Children.Add($title)
 Add-DomeniaBoardSectionMoves -Section $section -Board Fleet -Group $group -Layout $initial
 $bar=$section.Children[0];$buttons=$bar.Children[0];$up=$buttons.Children[0];$down=$buttons.Children[1]
 Expect (-not $up.IsEnabled -and $down.IsEnabled) 'Section boundary buttons incorrect'
 Expect ([Windows.Automation.AutomationProperties]::GetName($down) -eq ('Descendre la section '+$group)) 'Accessible name lacks section'
 $down.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))
 $saved=@(Get-DomeniaBoardLayout Fleet);Expect (@(Get-DomeniaBoardGroups $saved)[1] -eq $group) 'Click did not save move'
 Expect ($script:Writes -eq 1 -and (Get-DomeniaBoardState Fleet).UndoStack.Count -eq 1) 'Save or undo missing'
 $document=ConvertTo-DomeniaBoardLayoutDocument -Board Fleet -Layout $saved
 $import=ConvertFrom-DomeniaBoardLayoutDocument -Board Fleet -Text $document
 Expect ($import.Valid -and (Groups $import.Items) -eq (Groups $saved)) 'Export/import lost section order'
 Invoke-DomeniaBoardAction -Tag @{Board='Fleet';Action='Undo'}
 Expect ((ConvertTo-DomeniaBoardLayoutJson @(Get-DomeniaBoardLayout Fleet)) -ceq (ConvertTo-DomeniaBoardLayoutJson $initial)) 'Undo did not restore original widgets'
 $script:Settings=@{};$script:Writes=0
 Invoke-DomeniaBoardAction -Tag @{Board='Fleet';Action='MoveGroup';Group=$group;Direction='Up'}
 Expect ($script:Writes -eq 0) 'Boundary move wrote a default layout'
}
Check 'The home page keeps onboarding above widgets without redundant navigation' {
 [xml]$xml=[IO.File]::ReadAllText((Join-Path $wad 'Domenia-Main.xaml'))
 $ns=New-Object Xml.XmlNamespaceManager($xml.NameTable);$ns.AddNamespace('x','http://schemas.microsoft.com/winfx/2006/xaml');$ns.AddNamespace('w','http://schemas.microsoft.com/winfx/2006/xaml/presentation')
 $homePanel=$xml.SelectSingleNode('//*[@x:Name="TabDashboard"]/w:ScrollViewer/w:StackPanel',$ns)
 Expect ($null -ne $homePanel) 'Home missing'
 Expect (-not $homePanel.InnerXml.Contains('Que souhaitez-vous faire') -and -not $homePanel.InnerXml.Contains('BtnUxHome')) 'Redundant navigation still present'
 $source=$homePanel.InnerXml
 Expect ($source.IndexOf('CardFirstSteps') -ge 0 -and $source.IndexOf('CardFirstSteps') -lt $source.IndexOf('PnlFleetDashboard')) 'Onboarding must precede the widgets'
}
$failed=@($script:Results|Where-Object{-not $_.Passed}).Count
$report=[pscustomobject]@{Suite='BoardSections';PowerShell=$PSVersionTable.PSVersion.ToString();Is64BitProcess=[Environment]::Is64BitProcess;ApartmentState=[Threading.Thread]::CurrentThread.ApartmentState.ToString();Wpf=$true;NoNetwork=$true;Passed=($script:Results.Count-$failed);Failed=$failed;Results=$script:Results.ToArray()}
if($ReportPath){[IO.File]::WriteAllText($ReportPath,($report|ConvertTo-Json -Depth 7),(New-Object Text.UTF8Encoding($false)))}
$report|Select-Object Suite,Passed,Failed|Format-List|Out-String|Write-Host
if($failed){exit 1}
