#requires -Version 5.1
[CmdletBinding()]param([string]$ReportPath='')
$ErrorActionPreference='Stop';Set-StrictMode -Version 2
$modules=Join-Path (Split-Path -Parent $PSScriptRoot) 'modules'
foreach($name in @('Common.Model','HealthRules.Model','Boards.Model','BoardFleet.Model','BoardComputer.UI')){. (Join-Path $modules ('Domenia-'+$name+'.ps1'))}
$checks=[Collections.Generic.List[object]]::new();$now=[datetime]'2026-10-13T12:00:00Z';$scope='OU=Test,DC=example,DC=invalid'
$lifecycle=[IO.File]::ReadAllText((Join-Path $modules 'Domenia-WindowsLifecycle.json'))|ConvertFrom-Json
function Assert($value,$why){if(-not $value){throw $why}}
function Check($name,[scriptblock]$body){try{&$body;$checks.Add([pscustomobject]@{Name=$name;Passed=$true;Error=''})}catch{$checks.Add([pscustomobject]@{Name=$name;Passed=$false;Error=($_.Exception.Message+' '+$_.ScriptStackTrace)})}}
function Machine([int]$N,[string]$State='A'){[pscustomobject]@{name=('PC-'+$N);distinguished_name=('CN=PC-'+$N+','+$scope);object_guid=('00000000-0000-0000-0000-'+$N.ToString('000000000000'));gid=[string]$N;st=$State;logon='2026-10-12'}}
function New-HealthFixtureGroup($Machine){[pscustomobject]@{gid=$Machine.gid;st=$Machine.st;n=1;os='Windows 11 Enterprise';ver='10.0 (26100)';lb=0;cr='O';pw='R';lk='O';bk='K'}}
function Observation($Machine,[string]$Presence='En ligne',[double]$Free=40){$stamp=$now.ToUniversalTime().ToString('o');[pscustomobject]@{object_key=$Machine.distinguished_name.ToLowerInvariant();object_guid=$Machine.object_guid;name=$Machine.name;distinguished_name=$Machine.distinguished_name;gid=$Machine.gid;checked_utc=$stamp;in_scope=$true;observation=[pscustomobject]@{Guid=$Machine.object_guid;Presence=$Presence;PresenceCheckedUtc=$stamp;ObservedUtc=$stamp;LinkUser='';Inventory=[pscustomobject]@{CheckedUtc=$stamp;Model='Fixture';OsCaption='Windows 11 Enterprise';Build='26100';RamBytes=8GB;DiskSize=100GB;DiskFree=($Free*1GB);LastBootUtc=$now.AddDays(-2).ToString('o')}}}}
function Source([object[]]$Machines,[object[]]$Presence=@()){[pscustomobject]@{Types=@();Groups=@($Machines|ForEach-Object{New-HealthFixtureGroup $_});Machines=$Machines;Targets=$Machines;Parents=@();Coverage=[pscustomobject]@{FactsFresh=$Machines.Count;FactsStale=0;BitLockerRead=$Machines.Count;BitLockerAt=$now.ToString('o')};Presence=$Presence;History=@();Links=0}}
function Board($Source,$Policy=$null){Get-DomeniaFleetBoardData -Result $Source -Scope $scope -Now $now -Lifecycle $lifecycle -HealthPolicy $Policy}
Check 'All changed PowerShell modules parse' {
 foreach($name in @('HealthRules.Model','HealthRules.UI','Boards.Model','BoardFleet.Model','BoardComputer.UI','Widgets.UI')){$tokens=$null;$errors=$null;[void][Management.Automation.Language.Parser]::ParseFile((Join-Path $modules ('Domenia-'+$name+'.ps1')),[ref]$tokens,[ref]$errors);Assert (@($errors).Count -eq 0) (@($errors)|Out-String)}
}
Check 'Policy bounds reject inversions, nonnumbers and oversized custom rules' {
 $failed=$false;try{ConvertTo-DomeniaHealthPolicy @{Thresholds=@{DiskFreeAlert=90;DiskFreeWarn=10}} -Strict|Out-Null}catch{$failed=$true};Assert $failed 'Inverted thresholds accepted'
 $failed=$false;try{ConvertTo-DomeniaHealthPolicy @{Thresholds=@{StaleDays='NaN'}} -Strict|Out-Null}catch{$failed=$true};Assert $failed 'Invalid age accepted'
 $p=ConvertTo-DomeniaHealthPolicy @{Thresholds=@{DiskFreeAlert=-1};DisabledRules=@('nonexistent')};Assert ($p.Thresholds.DiskFreeAlert -eq 10 -and $p.DisabledRules.Count -eq 0) 'Malformed saved preference has no safe default'
}
Check 'AD enabled, disabled and unknown counts and GUID selections agree' {
 $m=@((Machine 1),(Machine 2 'D'),(Machine 3 'U'));$b=Board (Source $m)
 Assert ($b.Entries['fleet.machines'].Value -eq '3' -and $b.Entries['fleet.enabled'].Value -eq '1' -and $b.Entries['fleet.disabled'].Value -eq '1' -and $b.Entries['fleet.accountunknown'].Value -eq '1') 'Unknown account was classified as enabled'
 foreach($pair in @(@('fleet.enabled','fleet.accountstatus|Activés'),@('fleet.disabled','fleet.accountstatus|Désactivés'),@('fleet.accountunknown','fleet.accountstatus|État inconnu'))){Assert ([int]$b.Entries[$pair[0]].Value -eq @($b.Last.WidgetTargets[$pair[1]]).Count) 'Counter and drilldown disagree'}
 Assert ($b.Last.Targets.Count -eq 1 -and $b.Last.Targets[0].object_guid -eq $m[0].object_guid) 'Unknown/disabled account enters remote target list'
}
Check 'A new WMI observation never refreshes an expired ping' {
 $m=Machine 1;$o=Observation $m;$o.observation.PresenceCheckedUtc=$now.AddDays(-31).ToString('o');$b=Board (Source @($m) @($o))
 Assert (@($b.Last.WidgetTargets['fleet.presence|En ligne']).Count -eq 0 -and @($b.Last.WidgetTargets['fleet.presence|Non vérifié']).Count -eq 1) 'Recent WMI fabricated online presence'
 Assert ($b.Entries.ContainsKey('fleet.models')) 'Fresh WMI was discarded with expired ping'
 Assert ($b.Entries['fleet.lastcheck'].Value -eq 'Aucune') 'Recent WMI fabricated ping date'
}
Check 'Ping error is unknown, a real timeout is without response, timestamps mandatory' {
 $m=@((Machine 1),(Machine 2),(Machine 3));$o=@((Observation $m[0] 'Erreur de ping'),(Observation $m[1] 'Sans reponse au ping'),(Observation $m[2]));$o[2].observation.PresenceCheckedUtc='';$b=Board (Source $m $o)
 Assert (@($b.Last.WidgetTargets['fleet.presence|Non vérifié']).Count -eq 2 -and @($b.Last.WidgetTargets['fleet.presence|Sans réponse']).Count -eq 1) 'Technical error became offline or missing timestamp became fresh'
 Assert ((($b.Entries['fleet.presence'].Items|Measure-Object Value -Sum).Sum) -eq 3) 'Presence counts differ from enabled population'
}
Check 'Ping and WMI widgets are catalog entries with exact GUID drilldown (point 72)' {
 $m=@((Machine 1),(Machine 2),(Machine 3));$o=@((Observation $m[0] 'Sans reponse au ping'),(Observation $m[1]));$b=Board (Source $m $o)
 foreach($key in @('fleet.wmi','fleet.reach')){
  Assert ($null -ne (Get-DomeniaBoardCatalogItem Fleet $key)) ('Catalog misses '+$key);$sum=0
  foreach($part in @($b.Entries[$key].Items)){$sum+=[int]$part.Value;Assert (@($b.Last.WidgetTargets[$key+'|'+[string]$part.Label]).Count -eq [int]$part.Value) ('Drilldown differs '+$key+' '+$part.Label)}
  Assert ($sum -eq 3) ('Population differs '+$key)
 }
 Assert ((@($b.Last.WidgetTargets['fleet.reach|WMI répond, pas le ping']).Count -eq 1) -and ($b.Last.WidgetTargets['fleet.reach|WMI répond, pas le ping'][0].object_guid -eq $m[0].object_guid)) 'Filtered ICMP classified as unreachable'
 Assert (@($b.Last.WidgetTargets['fleet.presence|Sans réponse']).Count -eq 1) 'Ping bucket changed by WMI answer'
}
Check 'Duplicate and outside-scope observations do not inflate a widget' {
 $m=@((Machine 1),(Machine 2));$a=Observation $m[0];$outside=Observation (Machine 99);$outside.in_scope=$false;$b=Board (Source $m @($a,$a,$outside))
 Assert (@($b.Last.WidgetTargets['fleet.presence|En ligne']).Count -eq 1 -and @($b.Last.WidgetTargets['fleet.presence|Non vérifié']).Count -eq 1) 'Duplicate observation inflated count'
}
Check 'Wrong GUID or excluded scope never contaminates the canonical health projection' {
 $m=Machine 1
 foreach($reason in @('Guid','Scope')){
  $o=Observation $m
  if($reason -eq 'Guid'){$o.object_guid=(Machine 2).object_guid}else{$o.in_scope=$false}
  $b=Board (Source @($m) @($o))
  Assert ($b.Observations.Count -eq 0 -and $b.Last.UnknownTargets.Count -eq 1 -and $b.Last.HealthyTargets.Count -eq 0) 'Unrelated observation made an uncollected machine healthy'
 }
}
Check 'A recent probe is retained without making missing ping or inventory current' {
 $m=Machine 1;$o=Observation $m;$o.observation.PresenceCheckedUtc='';$o.observation.ObservedUtc='';$o.observation.Inventory=$null
 $o.observation|Add-Member -NotePropertyName Probes -NotePropertyValue @{fixture=[pscustomobject]@{CheckedUtc=$now.ToString('o');Rows=@()}}
 $b=Board (Source @($m) @($o))
 Assert ($b.Observations.Count -eq 1 -and $b.Last.WidgetTargets['fleet.presence|Non vérifié'].Count -eq 1 -and $b.Last.UnknownTargets.Count -eq 1) 'Fresh probe lost or reused to freshen other families'
}
Check 'Empty or unknown-only perimeter has no synthetic 100 score' {
 foreach($machines in @(@(),@((Machine 1 'U')))){$b=Board (Source $machines);Assert ($null -eq $b.Entries['fleet.health'].Number -and $b.Entries['fleet.health'].State -eq 'Off') 'Unmeasured park reported healthy'}
}
Check 'Incomplete coverage is explicit and not counted healthy' {
 $m=Machine 1;$b=Board (Source @($m))
 Assert ($b.Population.Unassessed -eq 1 -and $b.Last.UnknownTargets.Count -eq 1 -and $b.Last.HealthyTargets.Count -eq 0 -and $null -eq $b.Entries['fleet.health'].Number) 'Missing WMI treated as healthy'
 Assert ($b.Entries['fleet.health'].Badge -match 'incomplet') 'Coverage not visible'
}
Check 'Disabling a rule removes its score penalty and its detail targets' {
 $m=Machine 1;$s=Source @($m) @((Observation $m 'En ligne' 5));$bad=Board $s;$policy=ConvertTo-DomeniaHealthPolicy @{DisabledRules=@('lowdisk')};$good=Board $s $policy
 Assert ($bad.Last.ProblemTargets.Count -eq 1 -and $bad.Entries['fleet.health'].Number -eq 0) 'Disk critical point not counted'
 Assert ($good.Last.ProblemTargets.Count -eq 0 -and $good.Last.HealthyTargets.Count -eq 1 -and $good.Entries['fleet.health'].Number -eq 100) 'Disabled rule remains in score or detail'
}
Check 'Configurable activity uses AD date and not ping state' {
 $m=Machine 1;$m.logon='2026-08-24';$s=Source @($m) @((Observation $m));$default=Board $s;$custom=Board $s (ConvertTo-DomeniaHealthPolicy @{Thresholds=@{StaleDays=40}})
 Assert ($default.Entries['fleet.stale'].Value -eq '0' -and $custom.Entries['fleet.stale'].Value -eq '1') 'Custom activity threshold ignored'
 Assert ($custom.Last.WidgetTargets['fleet.stale'][0].object_guid -eq $m.object_guid -and $custom.Last.WidgetTargets['fleet.presence|En ligne'].Count -eq 1) 'AD activity conflated with network presence'
}
Check 'Password threshold is captured in the SQL query plan' {
 $p=Get-DomeniaFleetQueryPlan -Now $now -HealthPolicy (ConvertTo-DomeniaHealthPolicy @{Thresholds=@{PasswordDays=14}})
 Assert ($p.PasswordBefore -eq $now.ToUniversalTime().AddDays(-14).ToString('yyyy-MM-ddTHH:mm:ssZ')) 'Plan uses a different threshold than view'
}
Check 'Custom alert supports add, disable and remove without stale score membership' {
 $m=Machine 1;$s=Source @($m) @((Observation $m));$r=[pscustomobject]@{Id=('custom.'+('a'*32));Name='Disque moins de 50 %';Measure='DiskFree';Operator='LessThan';Threshold=50;Severity='Warn';Enabled=$true}
 $p=ConvertTo-DomeniaHealthPolicy @{CustomRules=@($r)} -Strict;$b=Board $s $p
 Assert ($b.Last.ProblemTargets.Count -eq 1 -and @($b.Attention|Where-Object Point -eq $r.Id).Count -eq 1) 'Custom alert has no exact targets'
 $r.Enabled=$false;$b=Board $s (ConvertTo-DomeniaHealthPolicy @{CustomRules=@($r)} -Strict);Assert ($b.Last.ProblemTargets.Count -eq 0) 'Disabled custom alert remains in score'
 $b=Board $s (ConvertTo-DomeniaHealthPolicy @{CustomRules=@()} -Strict);Assert ($b.Last.HealthyTargets.Count -eq 1) 'Removed alert remains active'
}
Check 'High custom disk thresholds retain coherent chart buckets' {
 $m=Machine 1;$b=Board (Source @($m) @((Observation $m 'En ligne' 90))) (ConvertTo-DomeniaHealthPolicy @{Thresholds=@{DiskFreeAlert=60;DiskFreeWarn=80}})
 Assert ((($b.Entries['fleet.diskfree'].Items|Measure-Object Value -Sum).Sum) -eq 1) 'High threshold lost a disk'
 Assert ($b.Entries['fleet.diskfree'].Items[-1].Label -eq '80 % et plus') 'High threshold made backwards interval'
}
function Get-DomeniaEntryFirstString {param($Entry,$Name)if($Entry.ContainsKey($Name)){return [string]$Entry[$Name]};return ''}
function Get-DomeniaEntryFileTimeUtc {param($Entry,$Name)return $null}
Check 'Machine card with absent or malformed UAC is unknown' {
 foreach($uac in @('','invalid','-1')){$d=New-DomeniaBoardData Computer;Add-DomeniaComputerBoardAdEntries $d ([pscustomobject]@{DN='CN=PC,'+$scope;Entry=@{userAccountControl=$uac}});Assert ($d.Entries['computer.ad.account'].Value -eq 'État inconnu' -and $d.Entries['computer.ad.account'].State -eq 'Off') 'Missing UAC became enabled'}
}
Check 'Computer with missing checks has no zero or one-hundred health gauge' {
 $d=New-DomeniaBoardData Computer;$d.Partial=[pscustomobject]@{Text='Contrôles non lus';Action=$null};Complete-DomeniaBoardData $d|Out-Null
 Assert ($null -eq $d.Entries['computer.health'].Number -and $d.Entries['computer.health'].Value -eq 'Données insuffisantes') 'Unknown checks generated numeric score'
}
Check 'Disabling every computer check never manufactures a perfect score' {
 $d=New-DomeniaBoardData Computer;$d.HealthPolicy=ConvertTo-DomeniaHealthPolicy @{DisabledRules=@(Get-DomeniaHealthRuleCatalog|ForEach-Object{$_.Id})};Complete-DomeniaBoardData $d|Out-Null
 Assert ($null -eq $d.Entries['computer.health'].Number -and $d.Entries['computer.health'].Value -eq 'Aucun contrôle activé') 'Zero active rules generated a perfect score'
}
Check '5000 machine perimeter keeps every AD state and exact GUID drilldown' {
 $rows=[Collections.Generic.List[object]]::new()
 for($i=1;$i -le 5000;$i++){$state=if($i -le 4500){'A'}elseif($i -le 4750){'D'}else{'U'};$m=Machine $i $state;$m.gid=$state;$rows.Add($m)}
 $source=Source @();$source.Machines=$rows.ToArray();$source.Targets=$rows.ToArray();$source.Coverage.FactsFresh=4500
 $source.Groups=@(foreach($st in @('A','D','U')){$g=New-HealthFixtureGroup (Machine 1 $st);$g.gid=$st;$g.n=if($st -eq 'A'){4500}else{250};$g})
 $watch=[Diagnostics.Stopwatch]::StartNew();$b=Board $source;$watch.Stop();$script:Health5000DurationMs=$watch.ElapsedMilliseconds
 Assert ($b.Entries['fleet.machines'].Value -eq '5000' -and $b.Entries['fleet.enabled'].Value -eq '4500' -and $b.Entries['fleet.disabled'].Value -eq '250' -and $b.Entries['fleet.accountunknown'].Value -eq '250') '5000-machine counters lost objects'
 Assert ($b.Last.WidgetTargets['fleet.machines'].Count -eq 5000 -and $b.Last.WidgetTargets['fleet.presence|Non vérifié'].Count -eq 4500 -and $b.Last.UnknownTargets.Count -eq 4500) 'Large drilldown or coverage lost objects'
 Assert ($null -eq $b.Entries['fleet.health'].Number) 'Uncollected large park claims healthy'
}
$failed=@($checks|Where-Object{-not $_.Passed}).Count
$report=[pscustomobject]@{Suite='HealthRules';Passed=($failed -eq 0);Total=$checks.Count;Failed=$failed;WpfExecuted=$false;NetworkUsed=$false;Health5000DurationMs=$script:Health5000DurationMs;Checks=$checks.ToArray()}
if($ReportPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))}
$checks|Where-Object{-not $_.Passed}|Format-List|Out-String|Write-Output
Write-Output (($checks.Count-$failed).ToString()+'/'+$checks.Count+' passed')
if($failed){exit 1}
