#requires -Version 5.1
[CmdletBinding()]param([string]$ReportPath='')
$ErrorActionPreference='Stop';Set-StrictMode -Version 2
$modules=Join-Path (Split-Path -Parent $PSScriptRoot) 'modules'
foreach($n in @('Common.Model','HealthRules.Model','HealthRules.UI','Boards.Model','BoardFleet.Model')){. (Join-Path $modules ('Domenia-'+$n+'.ps1'))}
$checks=[Collections.Generic.List[object]]::new();$domain='DC=example,DC=invalid';$scope='OU=Fleet,'+$domain;$alpha='OU=Alpha,'+$scope;$beta='OU=Beta,'+$scope;$now=([datetime]'2026-10-13T12:00:00Z').ToUniversalTime()
function Expect($ok,$why){if(-not $ok){throw $why}}
function Case($name,[scriptblock]$body){try{&$body;$checks.Add([pscustomobject]@{Name=$name;Passed=$true;Error=''})}catch{$checks.Add([pscustomobject]@{Name=$name;Passed=$false;Error=($_.Exception.Message+' '+$_.ScriptStackTrace)})}}
function Throws([scriptblock]$body){$thrown=$false;try{&$body|Out-Null}catch{$thrown=$true};Expect $thrown 'Expected rejection'}
function New-PolicyBook([string]$Only='lowdisk'){
 $policy=ConvertTo-DomeniaHealthPolicy @{DisabledRules=@(Get-DomeniaHealthRuleCatalog|Where-Object{$_.Id -ne $Only}|ForEach-Object{$_.Id})}
 return ConvertTo-DomeniaHealthPolicyBook @{Default=$policy} $domain
}
function New-Source {
 $rows=@();$observations=@()
 for($i=1;$i -le 4;$i++){$ou=if($i -le 2){$alpha}else{$beta};$dn='CN=PC-'+$i+','+$ou;$guid='00000000-0000-0000-0000-'+$i.ToString('000000000000')
  $rows+=,[pscustomobject]@{name=('PC-'+$i);distinguished_name=$dn;object_guid=$guid;gid='1';st='A';logon='2026-10-12';PasswordUtc=$now.AddDays(-40).ToString('o')}
  $observations+=,[pscustomobject]@{object_key=$dn.ToLowerInvariant();object_guid=$guid;name=('PC-'+$i);distinguished_name=$dn;gid='1';in_scope=$true;observation=[pscustomobject]@{Guid=$guid;CheckedUtc=$now.ToString('o');PresenceCheckedUtc=$now.ToString('o');Presence='En ligne';Inventory=[pscustomobject]@{CheckedUtc=$now.ToString('o');Model=('Model-'+($i%2));RamBytes=$(if($i -eq 4){0}else{8GB});DiskSize=100GB;DiskFree=15GB;LastBootUtc=$now.AddDays(-2).ToString('o');OsCaption='Windows 11 Enterprise';Build='26100'}}}
 }
 [pscustomobject]@{Types=@();Groups=@([pscustomobject]@{gid='1';st='A';n=4;os='Windows 11 Enterprise';ver='10.0 (26100)';lb=0;cr='O';pw='R';lk='O';bk='K'});Machines=$rows;Targets=$rows;Presence=$observations;Parents=@([pscustomobject]@{p=$alpha;n=2},[pscustomobject]@{p=$beta;n=2});Coverage=[pscustomobject]@{FactsFresh=4;FactsStale=0;BitLockerRead=4;BitLockerAt=$now.ToString('o')};History=@();Links=0;DomainDn=$domain}
}
function Board($Book,[datetime]$At=$now){Get-DomeniaFleetBoardData (New-Source) -Scope $scope -Now $At -HealthPolicy (Resolve-DomeniaHealthPolicy $Book $scope) -HealthPolicyBook $Book}
Case 'Parent dashboard assesses each computer with its own inherited OU thresholds' {
 $book=New-PolicyBook;$p=Resolve-DomeniaHealthPolicy $book $beta;$p.Thresholds.DiskFreeAlert=20;$p.Thresholds.DiskFreeWarn=30;$book=Set-DomeniaHealthScopePolicy $book $beta $p;$board=Board $book
 Expect ($board.Last.ProblemTargets.Count -eq 2 -and $board.Last.HealthyTargets.Count -eq 2 -and $board.Last.UnknownTargets.Count -eq 0) 'Parent policy replaced child threshold'
 Expect (@($board.Last.ProblemTargets|Where-Object{$_.distinguished_name.EndsWith(','+$beta)}).Count -eq 2) 'Wrong OU affected'
 Expect ([int]$board.Entries['fleet.lowdisk'].Value -eq $board.Last.WidgetTargets['fleet.lowdisk'].Count) 'Scoped widget counter differs from detail'
}
Case 'Password threshold uses actual date, not the parent SQL bucket' {
 $book=New-PolicyBook pwdold;$p=Resolve-DomeniaHealthPolicy $book $beta;$p.Thresholds.PasswordDays=30;$book=Set-DomeniaHealthScopePolicy $book $beta $p;$board=Board $book
 Expect ($board.Last.ProblemTargets.Count -eq 2 -and $board.Last.HealthyTargets.Count -eq 2) 'Password date was reduced to parent bucket'
}
Case 'A descendant can enable a rule disabled at domain level' {
 $book=New-PolicyBook;$book.Default.DisabledRules=@(Get-DomeniaHealthRuleCatalog|ForEach-Object{$_.Id});$p=Resolve-DomeniaHealthPolicy $book $beta;$p.DisabledRules=@($p.DisabledRules|Where-Object{$_ -ne 'lowdisk'});$p.Thresholds.DiskFreeAlert=20;$book=Set-DomeniaHealthScopePolicy $book $beta $p;$board=Board $book
 Expect ($board.Last.ProblemTargets.Count -eq 2 -and $board.Last.UnknownTargets.Count -eq 2) 'Re-enabled descendant rule was filtered by default'
 Expect (@($board.HealthExplanation.Rows|Where-Object{$_.Id -eq 'lowdisk'})[0].Status -eq 'Selon lʼOU') 'Mixed policies not explained'
}
Case 'Suspension preserves evidence, excludes rule visibly and expires on next calculation' {
 $book=New-PolicyBook;$p=Resolve-DomeniaHealthPolicy $book $beta;$p.Thresholds.DiskFreeAlert=20;$p.Suspensions=@([pscustomobject]@{RuleId='lowdisk';Reason='Maintenance planifiée';UntilUtc=$now.AddHours(1).ToString('o')});$book=Set-DomeniaHealthScopePolicy $book $beta $p
 $before=Board $book;$after=Board $book $now.AddHours(2)
 Expect ($before.Last.ProblemTargets.Count -eq 0 -and $before.Last.UnknownTargets.Count -eq 2 -and $before.HealthExplanation.SuspendedRules -eq 1) 'Suspension invisible or falsely healthy'
 Expect ($after.Last.ProblemTargets.Count -eq 2 -and $after.HealthExplanation.SuspendedRules -eq 0) 'Expired suspension remained active'
 Expect ($before.Observations.Count -eq 4 -and $after.Observations.Count -eq 4) 'Suspension erased collected facts'
 Expect ($before.Snapshot.Figures.PolicyHash -cne $after.Snapshot.Figures.PolicyHash) 'Expiration not reflected in comparison policy identity'
}
Case 'Suspension validates UTC expiry, reason, uniqueness and domain inheritance' {
 Throws {ConvertTo-DomeniaHealthSuspensions @(@{RuleId='lowdisk';Reason='';UntilUtc='2026-10-14T12:00:00Z'}) -Strict}
 Throws {ConvertTo-DomeniaHealthSuspensions @(@{RuleId='lowdisk';Reason='Maintenance';UntilUtc='2026-10-14T12:00:00'}) -Strict}
 $s=@{RuleId='lowdisk';Reason='Maintenance';UntilUtc='2026-10-14T12:00:00Z'};Throws {ConvertTo-DomeniaHealthSuspensions @($s,$s) -Strict}
 $book=New-PolicyBook;$book.Default.Suspensions=@($s);$p=Resolve-DomeniaHealthPolicy $book $beta;$p.Suspensions=@();$book=Set-DomeniaHealthScopePolicy $book $beta $p
 $book=ConvertTo-DomeniaHealthPolicyBook ($book|ConvertTo-Json -Depth 15 -Compress) $domain -Strict
 Expect ((Resolve-DomeniaHealthPolicy $book $alpha).Suspensions.Count -eq 1 -and (Resolve-DomeniaHealthPolicy $book $beta).Suspensions.Count -eq 0) 'Empty suspension override lost'
}
Case 'Comparisons separate population coverage and policy changes from observed state' {
 $board=Board (New-PolicyBook);$a=[pscustomobject]@{Figures=($board.Snapshot.Figures|ConvertTo-Json -Depth 8|ConvertFrom-Json)};$b=[pscustomobject]@{Figures=($a.Figures|ConvertTo-Json -Depth 8|ConvertFrom-Json)};$b.Figures.Healthy=1;$b.Figures.Problems=3
 Expect ((Compare-DomeniaHealthSnapshots $a $b).Comparable) 'Identical population/coverage/policy not comparable'
 foreach($field in @('PopulationHash','AssessedHash','CoverageHash','PolicyHash')){$old=$b.Figures.$field;$b.Figures.$field='changed';Expect (-not (Compare-DomeniaHealthSnapshots $a $b).Comparable) ('Ignored '+$field);$b.Figures.$field=$old}
 Expect (-not (Compare-DomeniaHealthSnapshots @{Figures=@{Machines=4;Healthy=4}} $b).Comparable) 'Legacy snapshot invented coverage'
}
Case 'All cross-table cells keep exact unique GUIDs and include unread dimensions' {
 $board=Board (New-PolicyBook)
 foreach($key in @('OuWindows','ModelRam','SiteCoverage')){$pivot=$board.Pivots[$key];$ids=[Collections.Generic.HashSet[string]]::new();$total=0;foreach($cell in $pivot.Rows){Expect ($cell.Count -eq $cell.Targets.Count) ('Cell count mismatch '+$key);$total+=$cell.Count;foreach($target in $cell.Targets){Expect ($ids.Add([string]$target.object_guid)) ('GUID occurs in two cells '+$key)}};Expect ($total -eq 4 -and $ids.Count -eq 4 -and $pivot.Total -eq 4) ('Incomplete table '+$key)}
 Expect (@($board.Pivots.ModelRam.Rows|Where-Object{$_.Column -eq 'RAM non lue'}).Count -eq 1) 'Unknown RAM silently removed'
}
Case 'New GUI modules and worker body parse, keyboard and canonical hooks remain present' {
 foreach($n in @('HealthRules.Model','HealthRules.UI','Boards.Model','BoardFleet.Model','BoardComputer.UI','Charts.UI','Widgets.UI','Dashboard.UI','Engine.Worker','Refresh.UI')){$tokens=$null;$errors=$null;[void][Management.Automation.Language.Parser]::ParseFile((Join-Path $modules ('Domenia-'+$n+'.ps1')),[ref]$tokens,[ref]$errors);Expect (@($errors).Count -eq 0) ($n+' '+($errors|Out-String))}
 . (Join-Path $modules 'Domenia-Engine.Worker.ps1');$tokens=$null;$errors=$null;[void][Management.Automation.Language.Parser]::ParseInput((Get-DomeniaLocalIndexReadWorkerCode),[ref]$tokens,[ref]$errors);Expect (@($errors).Count -eq 0) ('Worker '+($errors|Out-String))
 $widgets=[IO.File]::ReadAllText((Join-Path $modules 'Domenia-Widgets.UI.ps1'));Expect ($widgets -match 'Controls.WrapPanel' -and $widgets -match 'ModifierKeys\]::Alt' -and $widgets -match "'FleetAnalysis'") 'Responsive/keyboard analysis hooks missing'
}
$failed=@($checks|Where-Object{-not $_.Passed}).Count;$report=[pscustomobject]@{Suite='HealthAdvanced';Passed=($failed -eq 0);Total=$checks.Count;Failed=$failed;WpfExecuted=$false;NetworkUsed=$false;Checks=$checks.ToArray()}
if($ReportPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))};$checks|Where-Object{-not $_.Passed}|Format-List|Out-String|Write-Output;Write-Output (($checks.Count-$failed).ToString()+'/'+$checks.Count+' passed');if($failed){exit 1}
