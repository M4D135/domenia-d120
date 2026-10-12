#requires -Version 5.1
# Exercise the actual action functions with inert picker, confirmation and worker adapters.
[CmdletBinding()]param([string]$ReportPath='')
$ErrorActionPreference='Stop'
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
function Start-DomeniaIndexScopeBuild {param($Dn);$script:ScopeCalls+=@($Dn)}
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
Expect ($script:ScopeCalls.Count -eq 1 -and $script:ScopeCalls[0] -ceq $script:IndexScopeDn) 'primary action reads precisely the selected OU'
Expect ($script:Confirmations.Count -eq 0 -and $script:WorkerCalls -eq 0) 'primary OU route cannot trigger a full-domain operation'
Reset-ActionFixture
Start-DomeniaSelectedIndexScopeBuild
Expect ($script:PickerCalls -eq 1 -and $script:ScopeCalls.Count -eq 0) 'missing OU opens picker; cancel starts nothing'
Reset-ActionFixture
$script:Picked=[pscustomobject]@{DN='OU=Paris,DC=example,DC=test'}
Start-DomeniaSelectedIndexScopeBuild
Expect ($script:ScopeCalls.Count -eq 1 -and $script:ScopeCalls[0] -ceq $script:Picked.DN) 'picked OU becomes the only read target'
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
$report=[ordered]@{Kind='IndexActions';Passed=$script:Checks;Failed=0;NativeWindowsPowerShell51=($env:OS -eq 'Windows_NT' -and $PSVersionTable.PSVersion.Major -eq 5);WpfExecuted=$false;NetworkAccessed=$false}
if($ReportPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json),(New-Object Text.UTF8Encoding($false)))}
Write-Output ('PASS Index actions: '+$script:Checks+' assertions; no directory or VM transport.')
