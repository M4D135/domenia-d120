#requires -Version 5.1
# Exercises the actual UI completion finally block with a controlled clock; no WPF or network.
[CmdletBinding()]
param([string]$ReportPath='')
$ErrorActionPreference='Stop'
$wad=Split-Path $PSScriptRoot -Parent
function Read-Ast([string]$Path){$tokens=$null;$errors=$null;$tree=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors);if($errors.Count){throw ($errors.Message -join '; ')};return $tree}
function Import-TestFunction($Tree,[string]$Name){
    $nodes=@($Tree.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name},$true))
    if($nodes.Count -ne 1){throw ('Function missing or ambiguous: '+$Name)}
    . ([scriptblock]::Create(($nodes[0].Extent.Text -replace ('^function\s+'+[regex]::Escape($Name)+'\b'),('function script:'+$Name))))
}
$core=Read-Ast (Join-Path $wad 'Domenia-Core.ps1')
$engine=Read-Ast (Join-Path $wad 'modules/Domenia-Engine.UI.ps1')
$experience=Read-Ast (Join-Path $wad 'modules/Domenia-Experience.UI.ps1')
Import-TestFunction $engine 'Add-DomeniaRuntimeMetric'
Import-TestFunction $engine 'Get-DomeniaRuntimeMetricSummary'
Import-TestFunction $experience 'Get-DomeniaOperationsHealthText'
$tries=@($core.FindAll({param($n)$n -is [Management.Automation.Language.TryStatementAst] -and $null -ne $n.Finally -and $n.Body.Extent.Text -match '^\{\s*Invoke-DomeniaJobSuccessUi\b'},$true))
if($tries.Count -ne 1){throw 'Actual callback timer finally block missing or ambiguous'}
$body=$tries[0].Finally.Extent.Text
$script:CompleteMetric=[scriptblock]::Create($body.Substring(1,$body.Length-2))
$script:Results=[Collections.Generic.List[object]]::new();$script:Assertions=0;$script:Logs=[Collections.Generic.List[object]]::new()
function Write-AppLog {param($Text,$Level)$script:Logs.Add([pscustomobject]@{Text=[string]$Text;Level=[string]$Level})}
function Get-DomeniaPersistenceState {return [pscustomobject]@{Label=''}}
function Expect([bool]$Value,[string]$Message){$script:Assertions++;if(-not $Value){throw $Message}}
function Case([string]$Name,[scriptblock]$Body){try{&$Body;$script:Results.Add([pscustomobject]@{Name=$Name;Pass=$true;Error=''})}catch{$script:Results.Add([pscustomobject]@{Name=$Name;Pass=$false;Error=($_.Exception.Message+' '+$_.ScriptStackTrace)})}}
function Invoke-TimedCompletion([long]$Elapsed,[long]$Modal=0,[int]$Threshold=120,[string]$Operation='LocalQuery'){
    $callbackWatch=[pscustomobject]@{ElapsedMilliseconds=$Elapsed};$callbackWatch|Add-Member -MemberType ScriptMethod -Name Stop -Value {}
    $modalBefore=[long]100;$script:ModalBlockedMs=[long](100+$Modal);$callbackWarningMs=$Threshold
    $job=[pscustomobject]@{CorrelationId='synthetic';Name='Traitement fictif';OperationId=$Operation;SuccessHandler='Complete-Test'}
    & $script:CompleteMetric
}
Case '551 ms is recorded separately and warns with threshold and handler' {
    $script:DomeniaRuntimeMetrics=@{};$script:Logs.Clear()
    Invoke-TimedCompletion 551
    $metric=Get-DomeniaRuntimeMetricSummary Dispatcher 'Callback:LocalQuery'
    Expect ($metric.Count -eq 1 -and $metric.Max -eq 551) 'Callback duration missing'
    Expect ($script:Logs.Count -eq 1 -and $script:Logs[0].Level -eq 'WARN') 'Expected warning missing'
    Expect ($script:Logs[0].Text -match '551 ms' -and $script:Logs[0].Text -match 'seuil 120 ms' -and $script:Logs[0].Text -match 'LocalQuery' -and $script:Logs[0].Text -match 'Complete-Test') 'Warning lacks actionable context'
}
Case 'Modal waits are subtracted and negative effective durations are clamped' {
    $script:DomeniaRuntimeMetrics=@{};$script:Logs.Clear()
    Invoke-TimedCompletion 1000 900
    Invoke-TimedCompletion 100 150
    $metric=Get-DomeniaRuntimeMetricSummary Dispatcher 'Callback:'
    Expect ($metric.Count -eq 2 -and $metric.Max -eq 100 -and $metric.P50 -eq 0) 'Modal exclusion differs'
    Expect ($script:Logs.Count -eq 0) 'Modal wait produced a slow callback warning'
}
Case 'The warning threshold is preserved, with strict greater-than semantics' {
    $script:DomeniaRuntimeMetrics=@{};$script:Logs.Clear()
    Invoke-TimedCompletion 120;Invoke-TimedCompletion 121
    Expect ($script:Logs.Count -eq 1 -and $script:Logs[0].Text -match '121 ms') 'Warning threshold changed'
    $metric=Get-DomeniaRuntimeMetricSummary Dispatcher 'Callback:'
    Expect ($metric.Count -eq 2) 'Below-threshold timings were discarded'
}
Case 'Callback, worker and heartbeat samples stay isolated and bounded' {
    $script:DomeniaRuntimeMetrics=@{}
    1..520|ForEach-Object{Add-DomeniaRuntimeMetric Dispatcher 'Callback:LocalQuery' $_}
    Add-DomeniaRuntimeMetric Sqlite LocalQuery 9000
    Add-DomeniaRuntimeMetric Dispatcher Pulse 3
    $metric=Get-DomeniaRuntimeMetricSummary Dispatcher 'Callback:'
    Expect ($metric.Count -eq 512 -and $metric.Max -eq 520) 'Callback sample bound differs'
    Expect ((Get-DomeniaRuntimeMetricSummary Dispatcher Pulse).Max -eq 3) 'Heartbeat conflated with callbacks'
    Expect ((Get-DomeniaRuntimeMetricSummary Sqlite LocalQuery).Max -eq 9000) 'Worker conflated with callbacks'
}
Case 'Operations health exposes measured callback percentiles without claiming network performance' {
    $script:DomeniaRuntimeMetrics=@{};$script:Persistence=$null
    Add-DomeniaRuntimeMetric Dispatcher 'Callback:LocalQuery' 100
    Add-DomeniaRuntimeMetric Dispatcher 'Callback:LocalQuery' 551
    $text=Get-DomeniaOperationsHealthText
    Expect ($text -match 'Traitement des résultats dans lʼinterface' -and $text -match 'médiane 100 ms' -and $text -match 'maximum 551 ms') 'Health panel omits actual callback metrics'
    Expect ($text -match 'pas encore mesurée') 'Heartbeat was invented from callback measurements'
}
$failed=@($script:Results|Where-Object{-not $_.Pass}).Count
$report=[pscustomobject]@{Passed=($script:Results.Count-$failed);Failed=$failed;Assertions=$script:Assertions;PowerShell=$PSVersionTable.PSVersion.ToString();Data='Controlled clock, actual Core finally block and real in-memory metric functions; no AD/WPF';Cases=$script:Results.ToArray()}
if($ReportPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))}
$report|ConvertTo-Json -Depth 8
if($failed){exit 1}
