#requires -Version 5.1
param([string]$ReportPath='')
$ErrorActionPreference='Stop'
$wad=Split-Path -Parent $PSScriptRoot
foreach($name in @('Common.Model','Engine.Model','Observability.Model','Dossier.Model','Dossier.UI')){. (Join-Path $wad ('modules/Domenia-'+$name+'.ps1'))}
$folder=Join-Path ([IO.Path]::GetTempPath()) ('domenia-diagnostic-'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($folder)
$cases=[Collections.Generic.List[object]]::new();$script:checks=0
function Expect {param([bool]$Condition,[string]$Message);$script:checks++;if(-not $Condition){throw $Message}}
function Case {param([string]$Name,[scriptblock]$Action);try{& $Action;$cases.Add([pscustomobject]@{Name=$Name;Passed=$true;Error=''})}catch{$cases.Add([pscustomobject]@{Name=$Name;Passed=$false;Error=$_.Exception.Message});Write-Output ('FAIL '+$Name+': '+$_.Exception.Message)}}
function Write-AppLog {param($Text,$Level)}
function Set-Status {param($Text,$Level)}
function New-DomeniaSessionDiagnostic {return $script:SessionDiagnostic}
function Show-DomeniaDialog {param($Title,$Message,$Details);$script:PreviewJson=[string]$Details;$script:PreviewCount++;return $true}
function Confirm-Action {param($Text);$script:ConfirmCount++;return $script:ConfirmAccepted}
function New-DomeniaFileRequest {
 param($Mode)
 $request=[pscustomobject]@{FileName='';Filter='';OverwritePrompt=$false;Title=''}
 $request|Add-Member -MemberType ScriptMethod -Name ShowDialog -Value {param($Window);$script:ChooserCount++;$this.FileName=$script:Destination;return $script:SelectionAccepted}
 return $request
}
function Start-UiTask {
 param($Name,$OperationId,$Code,$Payload,$CallbackState,$SuccessHandler,$ErrorHandler,[switch]$NonCancellable,$TimeoutSeconds)
 $script:DispatchCount++;$script:WrittenText=[string]$Payload.Text
 $script:DocumentReceipt=& ([scriptblock]::Create($Code))
 return 'diagnostic-write'
}
function Reset-Export {
 $script:PreviewJson='';$script:WrittenText='';$script:PreviewCount=0;$script:ConfirmCount=0;$script:ChooserCount=0;$script:DispatchCount=0;$script:DocumentReceipt=$null;$script:ConfirmAccepted=$true;$script:SelectionAccepted=$true
 $script:Destination=Join-Path $folder 'diagnostic.json';$script:AsyncJobs=@{};$script:SessionEpoch=12L;$script:Conn=[pscustomobject]@{BaseDn='DC=example,DC=invalid'}
}
try{
 $sentinel='SecretMachine'
 $diagnostic=New-DomeniaRedactedDiagnostic -Versions ([pscustomobject]@{Domenia='1.0';PowerShell='5.1.26100.1';UiProfile=$sentinel;Theme=$sentinel}) -Counters ([pscustomobject]@{Tasks=1;Password=$sentinel}) -Errors @([pscustomobject]@{Code='INC-00AF';Count=1;Type='System.InvalidOperationException';Where='Domenia-Core.ps1:123';Message=$sentinel;Stack=$sentinel}) -Traces @([pscustomobject]@{Reference='1234abcd';OperationId='GlobalSearch';Name=$sentinel;Category=$sentinel;Phases=@()})
 $script:SessionDiagnostic=[pscustomobject]@{Json=($diagnostic|ConvertTo-Json -Depth 8);Preview=(Get-DomeniaDiagnosticPreviewText $diagnostic)}
 Case 'Explicit local export writes exactly the previewed redacted JSON' {
  Reset-Export;Export-DomeniaTechnicalDossier
  Expect ($script:PreviewCount -eq 1 -and $script:ConfirmCount -eq 1 -and $script:ChooserCount -eq 1 -and $script:DispatchCount -eq 1) 'one preview, one confirmation, one selection, one local write'
  Expect ($script:DocumentReceipt.Saved -and [IO.File]::Exists($script:Destination)) 'document worker confirmed the file'
  $content=[IO.File]::ReadAllText($script:Destination,[Text.Encoding]::UTF8)
  Expect ($content -ceq $script:PreviewJson -and $content -ceq $script:WrittenText) 'the saved bytes describe precisely the confirmed preview'
  Expect (-not $content.Contains($sentinel)) 'no secret/name sentinels in the real exported file'
  $read=$content|ConvertFrom-Json;Expect ($read.Format -ceq 'Domenia.Diagnostic.2' -and (-not $read.ContainsSecrets) -and (-not $read.ContainsNames)) 'valid redacted document'
 }
 Case 'Refusing confirmation leaves an existing diagnostic unchanged and never opens a chooser' {
  Reset-Export;$before=[IO.File]::ReadAllText($script:Destination);$script:ConfirmAccepted=$false;Export-DomeniaTechnicalDossier
  Expect ($script:ChooserCount -eq 0 -and $script:DispatchCount -eq 0) 'no choice or write after refusal'
  Expect ([IO.File]::ReadAllText($script:Destination) -ceq $before) 'previous diagnostic kept'
 }
 Case 'Cancelling file selection leaves the prior diagnostic unchanged' {
  Reset-Export;$before=[IO.File]::ReadAllText($script:Destination);$script:SelectionAccepted=$false;Export-DomeniaTechnicalDossier
  Expect ($script:ChooserCount -eq 1 -and $script:DispatchCount -eq 0) 'selection cancelled before dispatch'
  Expect ([IO.File]::ReadAllText($script:Destination) -ceq $before) 'previous diagnostic kept'
 }
 Case 'A locked destination refuses replacement and leaves no partial document' {
  Reset-Export;$before=[IO.File]::ReadAllText($script:Destination)
  $lock=[IO.File]::Open($script:Destination,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None);$caught=$false
  try{try{Export-DomeniaTechnicalDossier}catch{$caught=$true}}finally{$lock.Dispose()}
  Expect $caught 'locked destination reports failure'
  Expect ([IO.File]::ReadAllText($script:Destination) -ceq $before) 'previous diagnostic preserved after failed replacement'
  Expect (@(Get-ChildItem -LiteralPath $folder -Filter '*.tmp' -File).Count -eq 0) 'no temporary document retained'
 }
}finally{if([IO.Directory]::Exists($folder)){[IO.Directory]::Delete($folder,$true)}}
$failed=@($cases|Where-Object{-not $_.Passed}).Count
$report=[ordered]@{Suite='DomeniaDiagnosticExport';Passed=($failed -eq 0);Total=$cases.Count;Failed=$failed;Assertions=$script:checks;PowerShell=$PSVersionTable.PSVersion.ToString();Edition=[string]$PSVersionTable.PSEdition;Cases=$cases.ToArray();NetworkUsed=$false;ProductionPreferencesTouched=$false}
if($ReportPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))}
Write-Output ('DiagnosticExport: '+($cases.Count-$failed)+'/'+$cases.Count+' cases, '+$script:checks+' assertions')
if($failed){exit 1};exit 0
