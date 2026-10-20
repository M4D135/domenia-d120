param([string]$ReportPath)
$ErrorActionPreference='Stop'
$wad=Split-Path $PSScriptRoot -Parent
. (Join-Path $wad 'modules\Domenia-Common.Model.ps1')
. (Join-Path $wad 'modules\Domenia-Park.Model.ps1')
. (Join-Path $wad 'modules\Domenia-Live.Model.ps1')
$t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $wad 'modules\Domenia-Park.UI.ps1'),[ref]$t,[ref]$e)
if($e.Count){throw 'Park UI parse errors'}
foreach($name in @('Publish-DomeniaParkObservation','Invoke-DomeniaParkRunTick','Set-DomeniaParkTargetIndex')){
 $fn=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
 . ([scriptblock]::Create($fn.Extent.Text))
}
# Isolate scheduling/UI only; execute the production phase transition and publication logic.
function Get-DomeniaParkRun {param($Slot);return $script:run}
function Set-DomeniaCampaignTargetValidated {param($Run,$Index);$script:validated.Add($Index)}
function Update-DomeniaParkResultRows {}
function Clear-DomeniaParkPendingRow {}
function Submit-DomeniaParkPingResults {}
function Test-DomeniaParkWorkRemaining {return $false}
function Test-DomeniaParkPingBuffered {return $false}
function Set-Status {}
function Close-DomeniaParkStoreBacklog {}
function Get-DomeniaPersistenceState {return @{Pending=0;Suspended=$false}}
function Close-DomeniaParkCampaign {$script:closed++}
function Update-DomeniaParkRunStatus {}
function Expect($condition,$message){if(-not $condition){throw $message}}
$script:SessionEpoch=1;$script:DatabaseScopedPath='phase-fixture';$script:DomeniaAccountGeneration=1
$script:AsyncEngineClosing=$false;$script:GlobalSearchGeneration=2;$script:SelectedObject=$null;$script:FleetLast=$null
$script:AsyncJobs=@{};$script:DetachedReadJobs=@();$script:FleetObservations=@{}
$checks=[Collections.Generic.List[string]]::new()
try {
 foreach($online in @($true,$false)){
  $script:validated=[Collections.Generic.List[int]]::new();$script:closed=0
  $targets=@([pscustomobject]@{Key='cn=offline,dc=test'},[pscustomobject]@{Key='cn=online,dc=test'})
  $script:run=[pscustomobject]@{Epoch=1;Path='phase-fixture';AccountGeneration=1;RefreshOperationId='';Pending=@{};StorePending=@{};PingOnly=$false;WmiOnly=$false;PingBeforeWmi=$true;PingSwept=$false;Stopping=$false;PingJob='';Targets=$targets;PingOnline=@{};Next=2;Deferred=[Collections.Generic.List[object]]::new();Retry=[Collections.Generic.List[object]]::new();IndexByKey=@{};TargetsByKey=@{};Done=0;Online=0;NoReply=0;Errors=0;Failed=0;SkippedTargets=0;Timer=$null;Completed=$false;Generation=1;Approved=$true}
  Set-DomeniaParkTargetIndex $script:run
  if($online){$script:run.PingOnline[$targets[1].Key]=$true}
  Publish-DomeniaParkObservation $script:run ([pscustomobject]@{Key=$targets[0].Key;Presence='Sans réponse au ping'}) 0
  Publish-DomeniaParkObservation $script:run ([pscustomobject]@{Key=$targets[1].Key;Presence=$(if($online){'En ligne'}else{'Sans réponse au ping'})}) 1
  if($online){Expect (($script:validated -join ',') -eq '0') 'Online ping prematurely completes the durable WMI target'}
  Invoke-DomeniaParkRunTick
  Expect ($script:run.Done -eq 0 -and $script:run.Online -eq 0 -and $script:run.NoReply -eq 0) 'Ping counters leaked into WMI phase'
  Expect ($script:run.PingSummary.Done -eq 2) 'Preflight summary lost'
  Expect ($script:run.SkippedTargets -eq 0) 'Silent ping incorrectly classified as a remembered WMI refusal'
  Expect ($script:run.Targets.Count -eq $(if($online){1}else{0})) 'Incorrect WMI target set'
  if($online){
   Expect ($script:run.CampaignIndexByKey[$targets[1].Key] -eq 1) 'Original plan index lost'
   Publish-DomeniaParkObservation $script:run ([pscustomobject]@{Key=$targets[1].Key;Presence='En ligne'}) 0
   Expect (($script:validated -join ',') -eq '0,1') 'WMI committed to the filtered index instead of the original plan index'
   Expect ($script:run.Done -eq 1 -and $script:run.Online -eq 1 -and $script:run.NoReply -eq 0) 'WMI progress must finish at 1/1'
   $checks.Add('Mixed batch: preflight 2, WMI 1/1, original durable-plan indices retained')
  }else{
   Expect ($script:closed -eq 1 -and $script:run.Completed -and $script:run.Targets.Count -eq 0) 'All-silent batch not closed'
   Expect (($script:validated -join ',') -eq '0,1') 'Silent targets not committed'
   $checks.Add('All silent: zero WMI contacts, durable campaign closed')
  }
 }
 $result=[pscustomobject]@{Passed=$true;Checks=$checks.ToArray();PSVersion=$PSVersionTable.PSVersion.ToString();Utc=[datetime]::UtcNow.ToString('o')}
}catch{$result=[pscustomobject]@{Passed=$false;Checks=$checks.ToArray();Error=$_.Exception.Message;Stack=$_.ScriptStackTrace}}
if($ReportPath){$result|ConvertTo-Json -Depth 5|Set-Content $ReportPath -Encoding UTF8}
$result|ConvertTo-Json -Depth 5
if(-not $result.Passed){exit 1}
