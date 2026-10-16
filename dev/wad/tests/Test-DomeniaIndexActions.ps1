#requires -Version 5.1
# Exercise the actual action functions with inert picker, confirmation and worker adapters.
[CmdletBinding()]param([string]$ReportPath='')
$ErrorActionPreference='Stop'
# P-CD-09: the catch blocks of the core and of the UI modules trace an ignored error with Write-DomeniaSwallowed, defined
# in the script scope of Domenia-Core.ps1. Functions loaded one by one stay silent here, as before the sweep (no-op double;
# the trace itself is tested in rules/Common.Tests.ps1 and Test-DomeniaFaults.ps1).
function Write-DomeniaSwallowed { param($Category,$Operation,$ErrorRecord,$Now) }
$wad=Split-Path -Parent $PSScriptRoot
$t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $wad 'Domenia-Core.ps1'),[ref]$t,[ref]$e)
if($e.Count){throw 'Core syntax invalid'}
foreach($name in @('Get-DomeniaIndexScope','Start-DomeniaSelectedIndexScopeBuild','Start-DomeniaIndexBuild')){
    $f=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true))
    if($f.Count -ne 1){throw ('Function ambiguous: '+$name)}
    . ([scriptblock]::Create($f[0].Extent.Text))
}
$script:Checks=0
function Expect {param([bool]$Value,[string]$Name);$script:Checks++;if(-not $Value){throw $Name}}
function Reset-ActionFixture {
 $script:Conn=[pscustomobject]@{BaseDn='DC=example,DC=test'};$script:IndexScopeDn='';$script:IndexRows=@()
 $script:Picked=$null;$script:PickerCalls=0;$script:ScopeCalls=@();$script:Confirmations=@();$script:WorkerCalls=0;$script:LastStatus='';$script:Ready=$true
}
function Show-DomeniaInlinePicker {param($Kind,$Title,$Prompt);$script:PickerCalls++;return $script:Picked}
function Set-Status {param($Text,$Level);$script:LastStatus=$Text}
function Update-DomeniaIndexStats {}
function Request-DomeniaIndexSearch {}
function Invoke-DomeniaOuRefresh {param($Source,$Mode);$script:ScopeCalls+=@([pscustomobject]@{Source=$Source;Mode=$Mode;Dn=[string]$script:IndexScopeDn})}
function Test-DomeniaIndexWriteReady {return $script:Ready}
function Get-DomeniaOperationImpactEstimate {param($Operation,$ItemCount);return [pscustomobject]@{Kind='Synthetic'}}
function Format-DomeniaOperationImpact {param($Estimate);return [pscustomobject]@{Sentence='Estimation locale.';Details='Local fixture'}}
function Request-DomeniaInlineConfirmation {param($Title,$Message,$Target,$ConfirmText,$CancelText,$OnConfirm,$Details,$DetailsTitle,[switch]$DetailsExpertOnly);$script:Confirmations+=@([pscustomobject]@{Title=$Title;Message=$Message;Target=$Target;Button=$ConfirmText;Continuation=$OnConfirm})}
function Start-UiTask {param($Name);$script:WorkerCalls++;throw 'No transport allowed in action fixtures'}
function Set-DomeniaIndexProgress {param($Mode,$Message)}
function Show-DomeniaOperationError {param($Operation,$ErrorRecordOrException);throw $ErrorRecordOrException}
Reset-ActionFixture
$script:IndexScopeDn='OU=Paris,DC=example,DC=test'
Start-DomeniaSelectedIndexScopeBuild
Expect ($script:PickerCalls -eq 0) 'selected OU is favored without reprompt'
Expect ($script:ScopeCalls.Count -eq 1 -and $script:ScopeCalls[0].Dn -ceq $script:IndexScopeDn) 'primary action reads precisely the selected OU'
Expect ($script:ScopeCalls[0].Source -ceq 'Index' -and $script:ScopeCalls[0].Mode -ceq 'AD') 'primary action routes through the shared AD orchestrator with its own Index scope'
Expect ($script:Confirmations.Count -eq 0 -and $script:WorkerCalls -eq 0) 'primary OU route cannot trigger a full-domain operation'
Reset-ActionFixture
Start-DomeniaSelectedIndexScopeBuild
Expect ($script:PickerCalls -eq 1 -and $script:ScopeCalls.Count -eq 0) 'missing OU opens picker; cancel starts nothing'
Reset-ActionFixture
$script:Picked=[pscustomobject]@{DN='OU=Paris,DC=example,DC=test'}
Start-DomeniaSelectedIndexScopeBuild
Expect ($script:ScopeCalls.Count -eq 1 -and $script:ScopeCalls[0].Dn -ceq $script:Picked.DN -and $script:ScopeCalls[0].Source -ceq 'Index' -and $script:ScopeCalls[0].Mode -ceq 'AD') 'picked OU becomes the only read target through shared AD orchestration'
Expect ($script:IndexScopeDn -ceq $script:Picked.DN) 'selected OU retained'
foreach($dn in @('DC=example,DC=test','OU=Other,DC=elsewhere,DC=test','')){
 Reset-ActionFixture;$script:Picked=[pscustomobject]@{DN=$dn}
 Start-DomeniaSelectedIndexScopeBuild
 Expect ($script:ScopeCalls.Count -eq 0 -and $script:Confirmations.Count -eq 0 -and $script:WorkerCalls -eq 0) ('unsafe or domain choice never expands primary action: '+$dn)
 Expect ($script:IndexScopeDn -ceq '') ('rejected selection restores prior scope: '+$dn)
}
Reset-ActionFixture
Start-DomeniaIndexBuild
Expect ($script:Confirmations.Count -eq 1 -and $script:WorkerCalls -eq 0) 'full-domain read must wait for confirmation'
$confirmation=$script:Confirmations[0]
Expect ($confirmation.Message -like '*longue et occasionnelle*') 'domain confirmation explains cost and frequency'
Expect ($confirmation.Message -like '*premier chargement*' -and $confirmation.Message -like '*OU choisie au quotidien*') 'domain confirmation favors selected OU for daily use'
Expect ($confirmation.Message -like '*aucune modification dans Active Directory*') 'domain confirmation explains local-copy scope'
Expect ($confirmation.Button -ceq 'Relire tout le domaine' -and $confirmation.Target -ceq 'impact:IndexBuild') 'confirmation identifies explicit domain action'
Reset-ActionFixture;$script:Ready=$false
Start-DomeniaIndexBuild
Expect ($script:Confirmations.Count -eq 0 -and $script:WorkerCalls -eq 0) 'busy local storage blocks another full read'
# ---------------------------------------------------------------- DS-09 (lot X06): four tiles, durations and USN in the journal
. (Join-Path $wad 'modules/Domenia-Cache.Model.ps1')
$storageAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $wad 'modules/Domenia-Storage.UI.ps1'),[ref]$t,[ref]$e)
foreach($pair in @(@($ast,'Update-DomeniaIndexStats'),@($ast,'Complete-DomeniaIndexBuildUi'),@($storageAst,'Set-DomeniaIndexTiles'))){
    $f=@($pair[0].FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $pair[1]},$true))
    if($f.Count -ne 1){throw ('Function ambiguous: '+$pair[1])}
    . ([scriptblock]::Create($f[0].Extent.Text))
}
$script:Texts=@{};$script:Logs=[Collections.Generic.List[string]]::new()
function Set-DomeniaControlText {param($Name,$Text);$script:Texts[[string]$Name]=[string]$Text;return $true}
function Add-DomeniaUiLog {param($Area,$Text,$Level);$script:Logs.Add([string]$Text)}
function Write-AppLog {param($Text,$Level);$script:Logs.Add([string]$Text)}
function Request-DomeniaIndexMetadata {}
function Update-DomeniaIndexLocation {}
function Get-DomeniaIndexPartialText {return ''}
function Format-DomeniaAge {param($FromUtc,$NowUtc);return 'il y a 1 h'}
function Get-DomeniaFleetFreshness {param($ScopeDn,$DomainDn,$SyncStates);return [pscustomobject]@{At=$script:CoverageAt;SourceDn='OU=Paris,DC=example,DC=test';Partial=$false;AttemptAt=$null}}
Reset-ActionFixture
$script:IndexScopeDn='OU=Paris,DC=example,DC=test';$script:IndexMetadataError='';$script:IndexSyncStates=@{}
$script:IndexDbCount=1234;$script:IndexDbUsers=1000;$script:IndexDbComputers=234;$script:IndexDbMachinesActive=200;$script:IndexDbMachinesDisabled=34
$script:UserMachineLinks=@(1..3|ForEach-Object{[pscustomobject]@{UserLogin=('u'+$_);Computer=('PC'+$_)}})
$script:IndexInfo=[pscustomobject]@{Server='dc1.example.test';Usn=184522L;Date='2026-10-14T08:00:00Z'}
$script:CoverageAt=[datetime]::UtcNow.AddMinutes(-65)
Update-DomeniaIndexStats
$fr=[Globalization.CultureInfo]::GetCultureInfo('fr-FR')
Expect ($script:Texts['LblIndexTileAccounts'] -ceq (1000L).ToString('N0',$fr)) ('DS-09 accounts tile: '+$script:Texts['LblIndexTileAccounts'])
Expect ($script:Texts['LblIndexTileComputers'] -ceq '234' -and $script:Texts['LblIndexTileComputersDetail'] -ceq '200 actifs · 34 désactivés') ('DS-09 workstation tile: '+$script:Texts['LblIndexTileComputersDetail'])
Expect ($script:Texts['LblIndexTileLinks'] -ceq '3') 'DS-09 association tile'
Expect ($script:Texts['LblIndexTileUpdated'] -ceq 'il y a 1 h' -and $script:Texts['LblIndexTileUpdatedDetail'] -like 'le *') ('DS-09 last update tile: '+$script:Texts['LblIndexTileUpdated'])
Expect (-not $script:Texts.ContainsKey('LblIndexOverview')) 'DS-09: the technical sentence is gone'
Expect (-not ($script:Texts['LblIndexStats'] -match '184522') -and -not ($script:Texts['LblIndexStats'] -match 'Fichier')) ('DS-09: USN or path still on screen: '+$script:Texts['LblIndexStats'])
Expect (@($script:Logs|Where-Object{$_ -match '184522'}).Count -eq 1) 'DS-09: the USN goes to the journal'
Update-DomeniaIndexStats
Expect (@($script:Logs|Where-Object{$_ -match '184522'}).Count -eq 1) 'DS-09: the same USN is journaled once'
$script:IndexMetadataError='SQLite code 11 : database disk image is malformed'
Update-DomeniaIndexStats
Expect ($script:Texts['LblIndexTileAccounts'] -ceq '—' -and $script:Texts['LblIndexTileComputersDetail'] -ceq 'base illisible' -and $script:Texts['LblIndexFreshness'] -match 'ne peut pas être lue') 'DS-09: an unreadable base shows no figure'
# Durations of the AD read leave the summary and go to the journal.
function Update-DomeniaIndexStats {}
function Get-DomeniaEffectiveWorkerResult {param($Result,$RequiredProperties);return $Result}
function Save-DomeniaIndex {param($Rows,$Transfer,$Server,$BaseDn,$HighestUsn,$InvocationId,$Reconcile);return $true}
function Register-DomeniaOperationSample {param($Operation,$Mode,$ItemCount,$DurationMs,$BytesEstimated,$AdQueries,$SuccessCount,$StartedAt)}
function Set-DomeniaIndexProgress {param($Mode,$Message,$Current,$Total);$script:Texts['Progress']=[string]$Message}
$script:Logs.Clear()
$build=[pscustomobject]@{Rows=@([pscustomobject]@{Type='Utilisateur';Name='Alice'},[pscustomobject]@{Type='Machine';Name='PC1'});Truncated=$false;Server='dc1.example.test';BaseDn='DC=example,DC=test';HighestUsn=5L;InvocationId='inv';Reconcile=$null;DurationMs=48213L;Diagnostics=@()}
Complete-DomeniaIndexBuildUi -Result $build -State ([pscustomobject]@{UpdateLinks=$false;StartedAt=''})
Expect (-not ($script:Texts['LblIndexStatus'] -match '48213') -and -not ($script:LastStatus -match '48213') -and -not ($script:Texts['Progress'] -match '48213')) ('DS-09: milliseconds on screen: '+$script:Texts['LblIndexStatus'])
Expect ($script:Texts['LblIndexStatus'] -match '2 objet\(s\), dont 1 compte\(s\) et 1 poste\(s\)') ('DS-09 summary: '+$script:Texts['LblIndexStatus'])
Expect (@($script:Logs|Where-Object{$_ -match '48213 ms'}).Count -eq 1) 'DS-09: the duration goes to the journal'
# DS-09: Score and Correspondance explain the ranking of the local search; the real profile rule keeps them in Expert.
Add-Type -AssemblyName WindowsBase
$uxAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $wad 'modules/Domenia-UX.UI.ps1'),[ref]$t,[ref]$e)
$f=@($uxAst.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Update-DomeniaUxProfileVisibility'},$true))
if($f.Count -ne 1){throw 'Function ambiguous: Update-DomeniaUxProfileVisibility'}
. ([scriptblock]::Create($f[0].Extent.Text))
$script:IndexGridDouble=[pscustomobject]@{Columns=@(foreach($header in @('Type','Nom','Association','Score','Correspondance','Détail')){[pscustomobject]@{Header=$header;Visibility=[Windows.Visibility]::Visible}})}
function Get-DomeniaControl {param($Name);if($Name -eq 'DgIndex'){return $script:IndexGridDouble};return $null}
$script:Ctrl=@{};$script:UxProfileUpdating=$false
foreach($profile in @('Tech','Admin','Tech')){
    $script:CurrentUiProfile=$profile
    Update-DomeniaUxProfileVisibility -ObjectType ''
    $hidden=@($script:IndexGridDouble.Columns|Where-Object{$_.Visibility -ne [Windows.Visibility]::Visible}|ForEach-Object{[string]$_.Header})
    if($profile -eq 'Admin'){Expect ($hidden.Count -eq 0) ('DS-09: Expert sees every column of the local grid, hidden: '+($hidden -join ','))}
    else{Expect (($hidden -join ',') -ceq 'Score,Correspondance') ('DS-09: Score and Correspondance stay in Expert, hidden: '+($hidden -join ','))}
}
$report=[ordered]@{Kind='IndexActions';Passed=$script:Checks;Failed=0;NativeWindowsPowerShell51=($env:OS -eq 'Windows_NT' -and $PSVersionTable.PSVersion.Major -eq 5);WpfExecuted=$false;NetworkAccessed=$false}
if($ReportPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json),(New-Object Text.UTF8Encoding($false)))}
Write-Output ('PASS Index actions: '+$script:Checks+' assertions; no directory or VM transport.')
