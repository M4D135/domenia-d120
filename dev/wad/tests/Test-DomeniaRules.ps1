#requires -Version 5.1
# Pure rule tests for the D001-D120 modules. No WPF, no domain, no network, no user data.
# The same file runs under Windows PowerShell 5.1 (qualifying) and under another engine
# (preparation only: the report then states that it is not a Windows PowerShell 5.1 result).
[CmdletBinding()]
param([string]$ReportPath='',[switch]$Quiet,[string]$Filter='')
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$wad=Split-Path -Parent $PSScriptRoot
$modules=Join-Path $wad 'modules'
Add-Type -Path (Join-Path $modules 'Domenia.Native.dll') -ErrorAction Stop
$edition=if($PSVersionTable.ContainsKey('PSEdition')){[string]$PSVersionTable.PSEdition}else{'Desktop'}
$native=($env:OS -eq 'Windows_NT' -and $edition -eq 'Desktop' -and $PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -eq 1)
$script:Checks=New-Object 'System.Collections.Generic.List[object]'
function Assert-True { param($Value,[string]$Why='Assertion fausse') if(-not [bool]$Value){throw $Why} }
function Assert-False { param($Value,[string]$Why='Assertion vraie alors que fausse attendue') if([bool]$Value){throw $Why} }
function Assert-Equal { param($Expected,$Actual,[string]$Why='') if($Expected -cne $Actual){throw ('Attendu <'+[string]$Expected+'> obtenu <'+[string]$Actual+'> '+$Why)} }
function Assert-Throws { param([scriptblock]$Body,[string]$Why='Exception attendue') $thrown=$false;try{& $Body|Out-Null}catch{$thrown=$true};if(-not $thrown){throw $Why} }
function Test-Case {
    param([Parameter(Mandatory=$true)][string]$Id,[Parameter(Mandatory=$true)][string]$Name,[Parameter(Mandatory=$true)][scriptblock]$Body)
    if($Filter -and $Id -notlike $Filter -and $Name -notlike ('*'+$Filter+'*')){return}
    try { & $Body | Out-Null; $script:Checks.Add([pscustomobject]@{Id=$Id;Name=$Name;Status='Passed';Detail=''}) }
    catch { $script:Checks.Add([pscustomobject]@{Id=$Id;Name=$Name;Status='Failed';Detail=$_.Exception.Message+' @ '+$_.ScriptStackTrace}) }
}
if($null -eq ('Domenia.SelectionIdentity' -as [type])){Add-Type -Path (Join-Path $modules 'Domenia-Identity.Types.cs') -ErrorAction Stop}
$script:RuleModules=@('Domenia-Common.Model.ps1','Domenia-Engine.Model.ps1','Domenia-Cache.Model.ps1','Domenia-Search.Model.ps1','Domenia-Relations.Model.ps1','Domenia-Access.Model.ps1','Domenia-Directory.Model.ps1','Domenia-Workstation.Model.ps1','Domenia-Shell.Model.ps1','Domenia-Safety.Model.ps1','Domenia-Insight.Model.ps1','Domenia-Release.Model.ps1','Domenia-Assist.Model.ps1','Domenia-DirectorySync.Model.ps1','Domenia-LogonActivity.Model.ps1','Domenia-DirectorySchema.Model.ps1')
foreach($file in $script:RuleModules){
    $path=Join-Path $modules $file
    if(-not [IO.File]::Exists($path)){throw ('Module de regles absent : '+$file)}
    . $path
}
foreach($testFile in @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'rules') -Filter '*.Tests.ps1' -File | Sort-Object Name)){ . $testFile.FullName }
$passed=@($script:Checks|Where-Object{$_.Status -eq 'Passed'}).Count
$failed=@($script:Checks|Where-Object{$_.Status -eq 'Failed'}).Count
$covered=@($script:Checks|ForEach-Object{$_.Id}|Sort-Object -Unique)
if(-not $ReportPath){$ReportPath=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-rules-'+[guid]::NewGuid().ToString('N')+'.json')}
$report=[ordered]@{
    Kind='PureRules';Host=@{Platform=$(if($env:OS -eq 'Windows_NT'){'Windows'}else{'NonWindows'});PSEdition=$edition;PSVersion=$PSVersionTable.PSVersion.ToString()}
    NativeWindowsPowerShell51=$native;WpfExecuted=$false;DomainAccessed=$false;NetworkAccessed=$false
    Passed=$passed;Failed=$failed;CoveredIds=$covered;Complete=($failed -eq 0 -and $passed -gt 0)
    Limitation='Regles pures uniquement. Ne prouve ni le raccordement, ni WPF, ni un acces au domaine.'
    Tests=$script:Checks.ToArray()
}
[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 6),(New-Object Text.UTF8Encoding($false)))
if(-not $Quiet){
    Write-Host ("Regles : $passed reussis, $failed en echec, "+$covered.Count+" points couverts. Rapport : "+$ReportPath)
    $script:Checks|Where-Object{$_.Status -eq 'Failed'}|ForEach-Object{Write-Host ('  ECHEC '+$_.Id+' '+$_.Name+' : '+$_.Detail)}
}
if($failed -gt 0 -or $passed -eq 0){exit 1}
exit 0
