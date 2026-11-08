#requires -Version 5.1
[CmdletBinding()]
param([string]$ReportPath='',[switch]$QuerySource)
$ErrorActionPreference='Stop'
# P-CD-09: the catch blocks of the core and of the UI modules trace an ignored error with Write-DomeniaSwallowed, defined
# in the script scope of Domenia-Core.ps1. Functions loaded one by one stay silent here, as before the sweep (no-op double;
# the trace itself is tested in rules/Common.Tests.ps1 and Test-DomeniaFaults.ps1).
function Write-DomeniaSwallowed { param($Category,$Operation,$ErrorRecord,$Now) }
$modules=Join-Path (Split-Path -Parent $PSScriptRoot) 'modules'
if($QuerySource){Add-Type -Path (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'vendor/m4d-admin-common/src/Query/QueryEngine.cs')}else{Add-Type -Path (Join-Path $modules 'M4D.Admin.Common.Query.dll')}
Add-Type -Path (Join-Path $modules 'Domenia.Native.dll')
foreach($name in @('Common.Model','HealthRules.Model','Boards.Model','WidgetCollect.Model','Probes.Model','QuerySchema.Model','Workstation.Model','Query.Model','Query.UI')){. (Join-Path $modules ('Domenia-'+$name+'.ps1'))}
$checks=[Collections.Generic.List[object]]::new()
function Expect {param([bool]$Good,[string]$Name)$checks.Add([pscustomobject]@{Name=$Name;Passed=$Good});if(-not $Good){throw $Name}}
[xml]$xaml=[IO.File]::ReadAllText((Join-Path $modules 'Domenia-Query.xaml'))
$named=@($xaml.SelectNodes('//*[@*[local-name()="Name"]]'))
$names=@($named|ForEach-Object{$_.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml')})
Expect (@($names|Sort-Object -Unique).Count -eq $names.Count) 'Every workshop control has a unique name'
foreach($name in @('TabQueryCompose','TabQueryResults','TabQueryPublish','TxtQueryFieldSearch','CmbQueryValueChoice','LblQueryFieldHelp','BtnQueryPreview','BtnQueryContinueSave','LblQueryPublishSummary')){Expect ($names -ccontains $name) ('Guided control present '+$name)}
$tabs=@($named|Where-Object{$_.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml') -ceq 'QueryWorkspaceTabs'})[0]
Expect ([int]$tabs.SelectedIndex -eq 1 -and $tabs.ChildNodes[1].Header -ceq '1. Créer') 'Workshop opens on criteria, not an empty results page'
foreach($pair in @(@('BtnQueryAddCondition','TabQueryCompose'),@('BtnQueryContinueSave','TabQueryResults'),@('BtnQuerySave','TabQueryPublish'),@('BtnQueryApplySearch','TabQueryPublish'))){
 $node=@($named|Where-Object{$_.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml') -ceq $pair[0]})[0]
 $parent=$node.ParentNode;while($null -ne $parent -and $parent.LocalName -ne 'TabItem'){$parent=$parent.ParentNode}
 Expect ($null -ne $parent -and $parent.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml') -ceq $pair[1]) ('Action belongs to its workflow step '+$pair[0])
}
$script:FakeControls=@{}
function Get-DomeniaControl {param([string]$Name)return $script:FakeControls[$Name]}
function Set-DomeniaControlText {param([string]$Name,[string]$Text)if(-not $script:FakeControls.ContainsKey($Name)){$script:FakeControls[$Name]=[pscustomobject]@{Text=''}};$script:FakeControls[$Name].Text=$Text;return $true}
foreach($name in @('CmbQueryField','CmbQueryOperator','CmbQueryValueChoice','TxtQueryValue','BtnQueryAddCondition')){$script:FakeControls[$name]=[pscustomobject]@{SelectedItem=$null;SelectedIndex=-1;ItemsSource=@();DisplayMemberPath='';Visibility='Visible';Text='';IsEnabled=$true}}
$script:DomeniaQueryState=[pscustomobject]@{Catalog=@(Get-DomeniaQueryCatalog)}
$field=Get-DomeniaControl 'CmbQueryField'
$field.SelectedItem=@(Get-DomeniaQueryFields|Where-Object{$_.Id -ceq 'active'})[0];Update-DomeniaQueryOperators
Expect ((Get-DomeniaControl 'CmbQueryValueChoice').ItemsSource.Count -eq 2 -and (Get-DomeniaControl 'TxtQueryValue').Visibility -ceq 'Collapsed') 'Boolean criteria offer typed Yes/No choices'
Expect ((Get-DomeniaControl 'CmbQueryValueChoice').ItemsSource[0].Value -is [bool]) 'Boolean choice retains its actual Boolean type'
$field.SelectedItem=@(Get-DomeniaQueryFields|Where-Object{$_.Id -ceq 'laps'})[0];Update-DomeniaQueryOperators
Expect ((Get-DomeniaControl 'CmbQueryValueChoice').ItemsSource[0].Name -ceq 'Valide' -and (Get-DomeniaControl 'CmbQueryValueChoice').ItemsSource[0].Value -ceq 'O') 'Friendly code label preserves the engine value'
$field.SelectedItem=@(Get-DomeniaQueryFields|Where-Object{$_.Id -ceq 'ramGB'})[0];Update-DomeniaQueryOperators
Expect ((Get-DomeniaControl 'TxtQueryValue').Visibility -ceq 'Visible' -and (Get-DomeniaControl 'CmbQueryValueChoice').Visibility -ceq 'Collapsed') 'Numeric information keeps a numeric text input'
Expect ((Get-DomeniaControl 'LblQueryFieldHelp').Text -like '*Go*' -and (Get-DomeniaControl 'LblQueryFieldHelp').Text -like '*Date propre*') 'Editor explains the unit and independent source freshness'
$field.SelectedItem=$null;Update-DomeniaQueryOperators
Expect (-not (Get-DomeniaControl 'BtnQueryAddCondition').IsEnabled) 'No search result cannot accidentally add the previous field'
$catalog=@(Get-DomeniaQueryCatalog)
Expect (@(Find-DomeniaQueryCatalogEntries $catalog -Text 'memoire installee').Count -ge 1) 'Information search ignores accents'
$slow=@($catalog|Where-Object{$_.Id -ceq 'probe:evt.syserrors'})[0]
Expect ($slow.Cost -like 'Élevé*' -and $slow.Availability -like '*droits*') 'Slow source exposes cost and prerequisites'
# Execute the actual click handler with an inert navigation boundary. The stored target
# set takes precedence over recomputing an approximate query from a current data view.
function Initialize-DomeniaQueryWorkshop {}
function Show-DomeniaAttentionInWorkshop {param([object[]]$Targets=@(),[string]$Label)$script:CapturedTargets=$Targets;$script:CapturedLabel=$Label}
function Set-Status {param($Text,$Level)throw $Text}
$target=[pscustomobject]@{name='PC';distinguished_name='CN=PC,DC=example';object_guid='11111111-1111-1111-1111-111111111111'}
$script:FleetLast=[pscustomobject]@{WidgetTargets=@{'fleet.enabled'=@($target);'fleet.accountstatus|État inconnu'=@();'fleet.presence|Sans réponse'=@($target)}}
foreach($case in @(@('fleet.enabled','',1),@('fleet.accountstatus','État inconnu',0),@('fleet.presence','Sans réponse',1))){
 $script:CapturedTargets=$null;$selection=if($case[1]){[pscustomobject]@{Label=$case[1]}}else{$null}
 Show-DomeniaFleetWidgetDetails -Item ([pscustomobject]@{Key=$case[0];Title='Fixture';Source='BuiltIn'}) -Selection $selection
 Expect ($null -ne $script:CapturedTargets -and @($script:CapturedTargets).Count -eq $case[2]) ('Click preserves exact SQL GUID population including empty '+$case[0]+'/'+$case[1])
 Expect ([string]$script:CapturedLabel -like ('Fixture*'+[char]0x00B7+' '+$case[2]+' poste*')) ('Point 73 : la liste porte le compte du chiffre : '+[string]$script:CapturedLabel)
}
# Missing, stale, errors and measured zero remain different in the actual presentation adapter.
$values=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
$values['probe:disk.cfree']=0;$values['_quality:probe:hw.ram']='Expiré';$values['_quality:probe:sec.defender']='Erreur de lecture'
$record=[M4D.Admin.Common.Query.QueryRecord]::new('fixture',$values)
Expect ((Get-DomeniaQueryValuePresentation $record 'probe:disk.cfree').Value -ceq '0') 'Measured zero is retained'
Expect ((Get-DomeniaQueryValuePresentation $record 'probe:hw.ram').State -ceq 'Expiré') 'Expired is identified'
Expect ((Get-DomeniaQueryValuePresentation $record 'probe:sec.defender').State -ceq 'Erreur de lecture') 'Read error is identified'
Expect ((Get-DomeniaQueryValuePresentation $record 'probe:hw.cpu').State -ceq 'Non lu') 'Uncollected is identified'
$t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $modules 'Domenia-Query.UI.ps1'),[ref]$t,[ref]$e)
Expect ($e.Count -eq 0) 'Query UI source parses'
foreach($name in @('Update-DomeniaQueryOperators','Use-DomeniaQueryCatalogField','Update-DomeniaQueryCatalog','Update-DomeniaQueryLibrary')){
 $fn=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true))[0]
 $remote=@($fn.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in @('Start-UiTask','Start-DomeniaOnlinePark','Open-AdObject','Invoke-GlobalSearch')},$true))
 Expect ($remote.Count -eq 0) ('Choosing information remains local '+$name)
}
$report=[pscustomobject]@{Status='PASS';Checks=$checks.Count;Results=$checks.ToArray();PowerShell=$PSVersionTable.PSVersion.ToString();Scope='Actual XML, query editor functions and click handlers; inert controls/navigation; no WPF, AD, WMI or Windows qualification'}
if($ReportPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))}
$report|ConvertTo-Json -Depth 6
