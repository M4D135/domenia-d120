#requires -Version 5.1
[CmdletBinding()]param([string]$ReportPath='',[ValidateSet(10000,20000)][int[]]$Counts=@(10000,20000))
$ErrorActionPreference='Stop';Set-StrictMode -Version 2
$modules=Join-Path (Split-Path -Parent $PSScriptRoot) 'modules'
foreach($n in @('Common.Model','HealthRules.Model','Boards.Model','BoardFleet.Model')){. (Join-Path $modules ('Domenia-'+$n+'.ps1'))}
$lifecycle=[IO.File]::ReadAllText((Join-Path $modules 'Domenia-WindowsLifecycle.json'))|ConvertFrom-Json
$checks=[Collections.Generic.List[object]]::new();$timings=[Collections.Generic.List[object]]::new()
function Expect($value,$why){if(-not $value){throw $why}}
function Case($name,[scriptblock]$code){try{&$code;$checks.Add([pscustomobject]@{Name=$name;Passed=$true;Error=''})}catch{$checks.Add([pscustomobject]@{Name=$name;Passed=$false;Error=($_.Exception.Message+' '+$_.ScriptStackTrace)})}}
foreach($count in $Counts){
 Case ('Full source, exact categories and GUIDs for '+$count+' objects') {
  $scope='OU=Fleet,DC=example,DC=invalid';$now=([datetime]'2026-10-13T12:00:00Z').ToUniversalTime();$stamp=$now.ToString('o');$enabled=[int]($count*.9);$disabled=[int]($count*.05)
  $machines=[Collections.Generic.List[object]]::new();$observations=[Collections.Generic.List[object]]::new();$parents=@{}
  for($i=1;$i -le $count;$i++){
   $state=if($i -le $enabled){'A'}elseif($i -le $enabled+$disabled){'D'}else{'U'};$parent='OU=Site-'+($i%40)+','+$scope;$dn='CN=PC-'+$i+','+$parent
   $guid='00000000-0000-0000-0000-'+$i.ToString('000000000000');$machine=[pscustomobject]@{name=('PC-'+$i);distinguished_name=$dn;object_guid=$guid;gid=$state;st=$state;logon='2026-10-12'};$machines.Add($machine)
   if($state -ne 'A'){continue};$parents[$parent]=1+[int]$parents[$parent]
   $presence=if($i%40 -eq 0){'Erreur de ping'}elseif($i%20 -eq 0){'Sans réponse'}else{'En ligne'};$free=if($i%20 -eq 0){5GB}else{40GB}
   $obs=[pscustomobject]@{Guid=$guid;CheckedUtc=$stamp;Presence=$presence;PresenceCheckedUtc=$stamp;ObservedUtc='';LinkUser='';Inventory=[pscustomobject]@{CheckedUtc=$stamp;Model=('Model-'+($i%60));OsCaption='Windows 11 Enterprise';Build='26100';RamBytes=8GB;DiskSize=100GB;DiskFree=$free;LastBootUtc=$now.AddDays(-2).ToString('o')}}
   $observations.Add([pscustomobject]@{object_key=$dn.ToLowerInvariant();object_guid=$guid;name=$machine.name;distinguished_name=$dn;gid='A';checked_utc=$stamp;in_scope=$true;observation=$obs})
  }
  $groups=@(foreach($state in @('A','D','U')){[pscustomobject]@{gid=$state;st=$state;n=$(if($state -eq 'A'){$enabled}else{$disabled});os='Windows 11 Enterprise';ver='10.0 (26100)';lb=0;cr='O';pw='R';lk='O';bk='K'}})
  $source=[pscustomobject]@{Types=@();Groups=$groups;Machines=$machines.ToArray();Targets=$machines.ToArray();Parents=@(foreach($key in $parents.Keys){[pscustomobject]@{p=$key;n=$parents[$key]}});Coverage=[pscustomobject]@{FactsFresh=$enabled;FactsStale=0;BitLockerRead=$enabled;BitLockerAt=$stamp};Presence=$observations.ToArray();History=@();Links=0}
  $watch=[Diagnostics.Stopwatch]::StartNew();$board=Get-DomeniaFleetBoardData $source -Scope $scope -Now $now -Lifecycle $lifecycle;$watch.Stop();$timings.Add([pscustomobject]@{Objects=$count;Enabled=$enabled;Observations=$observations.Count;CalculationMs=$watch.ElapsedMilliseconds})
  Expect ([int]$board.Entries['fleet.machines'].Value -eq $count -and [int]$board.Entries['fleet.enabled'].Value -eq $enabled -and [int]$board.Entries['fleet.accountunknown'].Value -eq $disabled) 'Account population mismatch'
  Expect ($board.Last.ProblemTargets.Count -eq $enabled/20 -and $board.Last.UnknownTargets.Count -eq 0 -and $board.Last.HealthyTargets.Count -eq ($enabled-$enabled/20)) 'Health partition mismatch'
  Expect ($board.Entries['fleet.models'].Items.Count -eq 60 -and $board.Entries['fleet.ou'].Items.Count -eq 40) 'Category data was truncated before rendering'
  foreach($key in @('fleet.accountstatus','fleet.presence','fleet.models','fleet.releases','fleet.ram','fleet.diskfree','fleet.versions','fleet.os','fleet.servers','fleet.lastlogon','fleet.ou')){
   $sum=0
   foreach($part in $board.Entries[$key].Items){$targetKey=$key+'|'+$part.Label;Expect ($board.Last.WidgetTargets.ContainsKey($targetKey)) ('Missing exact category '+$targetKey);$targets=@($board.Last.WidgetTargets[$targetKey]);Expect ($targets.Count -eq [int]$part.Value) ('Counter/detail mismatch '+$targetKey);$unique=[Collections.Generic.HashSet[string]]::new();foreach($target in $targets){[void]$unique.Add([string]$target.object_guid)};Expect ($unique.Count -eq $targets.Count) ('Duplicate GUID '+$targetKey);$sum+=[int]$part.Value}
   $expected=if($key -eq 'fleet.accountstatus'){$count}else{$enabled};Expect ($sum -eq $expected) ('Incomplete total '+$key)
  }
  $folded=Get-DomeniaChartCategoryGroups -Items $board.Entries['fleet.models'].Items -Maximum 8
  Expect ($folded.Count -eq 8 -and (($folded|Measure-Object Value -Sum).Sum) -eq $enabled -and $folded[-1].Items.Count -eq 53 -and $folded[-1].Select.Labels.Count -eq 53) 'Other categories lost values or original labels'
  $disk=@($board.HealthExplanation.Rows|Where-Object Id -eq lowdisk)[0];Expect ($disk.Machines -eq $enabled/20 -and $disk.Guids.Count -eq $enabled/20) 'Rule contribution count differs from exact targets'
 }
}
Case 'Grouping preserves original typed selections and supports an all-other single row' {
 $items=@(1..12|ForEach-Object{[pscustomobject]@{Label=('L'+$_);Value=$_;Select=[pscustomobject]@{ExactValue=$_;Unknown=$false}}})
 $folded=Get-DomeniaChartCategoryGroups $items 1
 Expect ($folded.Count -eq 1 -and $folded[0].Value -eq 78 -and $folded[0].Select.Selections.Count -eq 12 -and $folded[0].Select.Selections[11].ExactValue -eq 12) 'One-row grouping lost typed recipe selections'
}
$failed=@($checks|Where-Object{-not $_.Passed}).Count;$report=[pscustomobject]@{Suite='DashboardScale';Passed=($failed -eq 0);Total=$checks.Count;Failed=$failed;WpfExecuted=$false;NetworkUsed=$false;Timings=$timings.ToArray();Checks=$checks.ToArray()}
if($ReportPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 7),[Text.UTF8Encoding]::new($false))}
$checks|Where-Object{-not $_.Passed}|Format-List|Out-String|Write-Output;$timings|Format-Table|Out-String|Write-Output;Write-Output (($checks.Count-$failed).ToString()+'/'+$checks.Count+' passed');if($failed){exit 1}
