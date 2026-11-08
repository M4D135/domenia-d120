#requires -Version 5.1
[CmdletBinding()]
param([string]$CorePath='', [string]$ReportPath='')
$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition -ne 'Desktop' -or -not [Environment]::Is64BitProcess){throw 'Windows PowerShell 5.1 x64 required'}
if(-not $CorePath){$CorePath=Join-Path (Split-Path -Parent $PSScriptRoot) 'Domenia-Core.ps1'}
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($CorePath,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Core parser errors'}
# Execute the actual pre-login loop: the self-test returns before this startup path.
$loops=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.ForEachStatementAst] -and $node.Condition.Extent.Text -match '\$script:ConfigLoadIssues'},$true))
if($loops.Count -ne 1){throw 'Expected exactly one pre-login configuration loop'}
$body=[scriptblock]::Create($loops[0].Extent.Text)
$script:Traces=New-Object 'System.Collections.Generic.List[object]'
$script:Warnings=New-Object 'System.Collections.Generic.List[string]'
function Write-StartupTrace {param($Stage,$Status,$Detail);$script:Traces.Add([pscustomobject]@{Stage=$Stage;Status=$Status;Detail=$Detail})}
function Show-WarningBox {param($Message);$script:Warnings.Add([string]$Message)}
$results=New-Object 'System.Collections.Generic.List[object]'
foreach($mode in @('Empty','Warnings')){
 $script:ConfigLoadIssues=New-Object 'System.Collections.Generic.List[object]'
 $script:Traces.Clear();$script:Warnings.Clear()
 if($mode -eq 'Warnings'){
  $script:ConfigLoadIssues.Add([pscustomobject]@{Source='Fichier';Warning=$true;Text='Invalid configuration fixture'})
  $script:ConfigLoadIssues.Add([pscustomobject]@{Source='Registre';Warning=$false;Text='Unreadable preference fixture'})
 }
 try {
  & $body
  if($mode -eq 'Empty' -and ($script:Traces.Count -ne 0 -or $script:Warnings.Count -ne 0)){throw 'Clean configuration must not report an issue'}
  if($mode -eq 'Warnings'){
   if($script:Traces.Count -ne 2 -or $script:Warnings.Count -ne 1){throw 'Every issue must be logged, only actionable warnings shown'}
   if($script:Traces[0].Stage -ne 'Configuration/Fichier' -or $script:Traces[1].Stage -ne 'Configuration/Registre'){throw 'Issue source was lost'}
   if($script:Warnings[0] -ne 'Invalid configuration fixture'){throw 'Warning content was lost'}
  }
  $results.Add([pscustomobject]@{Name=$mode;Passed=$true;Error=''})
 }catch{$results.Add([pscustomobject]@{Name=$mode;Passed=$false;Error=$_.Exception.Message})}
}
$failed=@($results|Where-Object{-not $_.Passed}).Count
$report=[pscustomobject]@{Suite='StartupConfiguration';NativeWindowsPowerShell51=$true;PowerShell=$PSVersionTable.PSVersion.ToString();Passed=($results.Count-$failed);Failed=$failed;Cases=$results.ToArray()}
$json=$report|ConvertTo-Json -Depth 5
if($ReportPath){[IO.File]::WriteAllText($ReportPath,$json,[Text.UTF8Encoding]::new($false))}
Write-Output $json
if($failed){exit 1}
