#requires -Version 5.1
# Offline date provenance: pure rules, UI ports and real workers on a disposable SQLite database. No AD/network.
[CmdletBinding()]
param([string]$ReportPath='',[switch]$SkipStorage)
$ErrorActionPreference='Stop'
$wad=Split-Path -Parent $PSScriptRoot;$modules=Join-Path $wad 'modules'
foreach($name in @('Common.Model','Boards.Model','BoardFleet.Model','Dashboard.UI')){. (Join-Path $modules ('Domenia-'+$name+'.ps1'))}
$script:Checks=[Collections.Generic.List[object]]::new();$script:Assertions=0
function Expect([bool]$Condition,[string]$Message){$script:Assertions++;if(-not $Condition){throw $Message}}
function Case([string]$Name,[scriptblock]$Body){try{& $Body;$script:Checks.Add([pscustomobject]@{Name=$Name;Passed=$true;Error=''})}catch{$script:Checks.Add([pscustomobject]@{Name=$Name;Passed=$false;Error=$_.Exception.ToString()})}}
$script:Now=([datetime]'2026-10-13T12:00:00Z').ToUniversalTime();$script:Domain='DC=example,DC=invalid';$script:Ou='OU=Postes,'+$script:Domain
function Sync([string]$Key,[string]$Base,[string]$At,[string]$Details='complete;depth=Subtree'){[pscustomobject]@{scope=$Key;base_dn=$Base;last_sync=$At;details=$Details}}
function Coverage($States,[string]$Scope=$script:Ou,[bool]$Subtree=$true){Get-DomeniaFleetFreshness -ScopeDn $Scope -DomainDn $script:Domain -SyncStates $States -Subtree $Subtree -NowUtc $script:Now}
function Observation([string]$Key,[string]$Ping='2026-10-13T11:50:00Z',[string]$Inventory='2026-10-13T11:00:00Z',[bool]$InScope=$true){
 [pscustomobject]@{object_key=$Key;checked_utc='2026-10-13T11:59:00Z';in_scope=$InScope;observation=[pscustomobject]@{CheckedUtc=$Ping;Presence='En ligne';Inventory=[pscustomobject]@{CheckedUtc=$Inventory}}}
}
Case 'Successful OU date survives a later calculation and no global date fallback is invented' {
 $states=@{directory=(Sync directory $Domain '2026-10-13T09:00:00Z');ou=(Sync ('ou:'+$Ou) $Ou '2026-10-13T11:48:00Z')}
 $first=Coverage $states;$later=Get-DomeniaFleetFreshness -ScopeDn $Ou -DomainDn $Domain -SyncStates $states -NowUtc $Now.AddMinutes(5)
 Expect ($first.At -eq (ConvertFrom-DomeniaUtcText '2026-10-13T11:48:00Z') -and $later.At -eq $first.At -and $later.SourceDn -eq $Ou) 'OU checkpoint changed during local recalculation'
 $summary=Format-DomeniaOuFreshnessSummary $first $null $Now -NowUtc $Now
 Expect ($summary.BaseText -like '*12 min*' -and $summary.ComputedText -like '*Vue recalculée*') 'Data age and calculation time are conflated'
 $missing=Coverage @{};Expect ($null -eq $missing.At -and $missing.Status -eq 'Missing') 'Missing coverage has a fabricated date'
}
Case 'Child, sibling and mismatched scope identities cannot date the selected OU' {
 $states=@{child=(Sync ('ou:OU=Child,'+$Ou) ('OU=Child,'+$Ou) '2026-10-13T11:59:00Z');sibling=(Sync ('ou:OU=Other,'+$Domain) ('OU=Other,'+$Domain) '2026-10-13T11:59:00Z');wrong=(Sync 'ou:OU=Other,DC=example,DC=invalid' $Ou '2026-10-13T11:59:00Z')}
 Expect ($null -eq (Coverage $states).At) 'Unrelated or malformed marker accepted'
}
Case 'Escaped comma in an RDN is not an ancestor boundary' {
 $child='OU=Child\,OU=Postes,'+$Domain
 $states=@{ou=(Sync ('ou:'+$Ou) $Ou '2026-10-13T11:48:00Z')}
 Expect ($null -eq (Coverage $states $child).At) 'Escaped RDN grants false coverage'
}
Case 'Valid ancestor Subtree applies to descendants but not to the whole domain' {
 $states=@{ou=(Sync ('ou:'+$Ou) $Ou '2026-10-13T11:48:00Z')}
 Expect ((Coverage $states ('OU=Child,'+$Ou)).At.Hour -eq 11) 'Ancestor subtree not inherited'
 Expect ($null -eq (Coverage $states '').At) 'OU marks whole domain fresh'
}
Case 'Legacy OU depth is unknown; legacy complete directory remains a valid ancestor' {
 $states=@{ou=(Sync ('ou:'+$Ou) $Ou '2026-10-13T11:48:00Z' 'async')}
 $unknown=Coverage $states;Expect ($null -eq $unknown.At -and $unknown.DepthUnknown -and $unknown.Status -eq 'UnknownDepth') 'Legacy depth fabricated'
 $states.directory=Sync directory $Domain '2026-10-13T09:00:00Z' 'inv=00000000-0000-0000-0000-000000000001'
 $coverage=Coverage $states;Expect ($coverage.At.Hour -eq 9 -and $coverage.DepthUnknown) 'Valid old domain coverage lost or legacy OU rejuvenates it'
}
Case 'OneLevel covers only the exact direct scope and never replaces a Subtree timestamp' {
 $states=@{tree=(Sync ('ou:'+$Ou) $Ou '2026-10-13T10:00:00Z');direct=(Sync ('ou:onelevel:'+$Ou) $Ou '2026-10-13T11:59:00Z' 'complete;depth=OneLevel')}
 Expect ((Coverage $states).At.Hour -eq 10) 'Direct pass replaced subtree date'
 Expect ((Coverage $states $Ou $false).At.Minute -eq 59) 'Direct pass not recognized for exact OneLevel scope'
 Expect ((Coverage $states ('OU=Child,'+$Ou)).At.Hour -eq 10) 'Direct parent pass certifies descendant'
}
Case 'Legacy root OU marker never substitutes for a domain census' {
 $states=@{root=(Sync ('ou:'+$Domain) $Domain '2026-10-13T11:59:00Z' 'async')}
 Expect ($null -eq (Coverage $states).At -and $null -eq (Coverage $states '').At) 'Legacy walk root accepted as full coverage'
}
Case 'Partial attempt retains successful coverage and clears only after a later complete pass' {
 $states=@{ou=(Sync ('ou:'+$Ou) $Ou '2026-10-13T10:00:00Z');attempt=(Sync ('attempt:ou:'+$Ou) $Ou '2026-10-13T11:00:00Z' 'partial;depth=Subtree')}
 $partial=Coverage $states;Expect ($partial.Partial -and $partial.At.Hour -eq 10 -and $partial.Status -eq 'Partial') 'Partial pass replaced success'
 $states.ou.last_sync='2026-10-13T11:30:00Z';Expect (-not (Coverage $states).Partial) 'Old failed attempt still supersedes fresh success'
}
Case 'Future, malformed and missing dates never become just now' {
 foreach($stamp in @('2026-10-13T12:00:01Z','broken','')){
  $coverage=Coverage @{ou=(Sync ('ou:'+$Ou) $Ou $stamp)}
  $summary=Format-DomeniaOuFreshnessSummary $coverage $null -NowUtc $Now
  Expect ($null -eq $coverage.At -and $summary.BaseText -notlike '*instant*') ('Invalid date accepted: '+$stamp)
 }
 $coverage=Coverage @{future=(Sync ('ou:'+$Ou) $Ou '2026-10-13T12:00:01Z');directory=(Sync directory $Domain '2026-10-13T09:00:00Z')}
 Expect ($coverage.ClockInvalid -and $coverage.At.Hour -eq 9) 'Future marker hides prior reliable coverage'
}
Case 'Ping and WMI report independent dates, ranges and coverage' {
 $rows=@((Observation a),(Observation b '2026-10-13T11:58:00Z' ''),(Observation c '2026-10-13T11:59:00Z' '2026-10-13T11:59:00Z' $false))
 $f=Get-DomeniaOuObservationFreshness $rows 3 $Now
 Expect ($f.Ping.Count -eq 2 -and $f.Inventory.Count -eq 1 -and $f.Ping.Missing -eq 1 -and $f.Inventory.Missing -eq 2) 'Measurement coverage wrong'
 Expect ($f.Ping.OldestUtc.Minute -eq 50 -and $f.Ping.NewestUtc.Minute -eq 58 -and $f.Inventory.NewestUtc.Hour -eq 11 -and $f.Inventory.NewestUtc.Minute -eq 0) 'Measurement clocks merged'
 $text=Format-DomeniaOuFreshnessSummary $null $f $Now -NowUtc $Now
 Expect ($text.ObservationsText -like '*ping 2/3*du*au*inventaire WMI 1/3*') 'Range or exact coverage missing'
}
Case 'Ping family date overrides a newer cache write timestamp; duplicate objects count once' {
 $row=Observation a;$row.observation|Add-Member -NotePropertyName PresenceCheckedUtc -NotePropertyValue '2026-10-13T10:00:00Z'
 $f=Get-DomeniaOuObservationFreshness @($row,$row) 1 $Now
 Expect ($f.Ping.Count -eq 1 -and $f.Ping.NewestUtc.Hour -eq 10) 'Cache date masquerades as ping time or duplicates inflate coverage'
}
Case 'Invalid, expired and unknown measurements are excluded independently' {
 $rows=@((Observation a '2026-10-13T12:00:01Z' '2026-09-01T12:00:00Z'),(Observation b '' 'broken'),(Observation c))
 $rows[2].observation.Presence='Non vérifié'
 $f=Get-DomeniaOuObservationFreshness $rows 3 $Now 30
 Expect ($f.Ping.Count -eq 0 -and $f.Inventory.Count -eq 1) 'Invalid measurement accepted or valid family erased'
}
Case 'Empty population has no fabricated coverage or timestamps' {
 $f=Get-DomeniaOuObservationFreshness @() 0 $Now
 Expect ($f.Ping.Count -eq 0 -and $f.Inventory.Count -eq 0 -and $null -eq $f.Ping.NewestUtc -and $null -eq $f.Inventory.OldestUtc) 'Empty date synthesized'
}
# Render the actual callback through inert UI ports: no WPF objects, timers or network tasks are needed.
function Get-DomeniaControl([string]$Name){if($Name -eq 'PnlFleetCrumbs'){return $null};return $script:Controls[$Name]}
function Set-DomeniaControlText([string]$Name,[string]$Text){$script:Labels[$Name]=$Text;return $true}
function Get-DomeniaEffectiveWorkerResult($Result,$Properties){return $Result}
function Merge-DomeniaFleetObservations($Stored,$Current,$RetainKeys){return $Stored}
function Update-DomeniaFleetMachineList {}
function Show-DomeniaBoard($Board,$Data,[switch]$Quiet,[switch]$DeferIfHidden){if($null -ne $Data){$script:Rendered=$Data}}
function Save-DomeniaFleetSnapshot($Scope,$Board){return $true}
function Update-DomeniaFirstSteps {}
Case 'Real completion renders the snapshot date even if in-memory metadata is older' {
 $script:Controls=@{PnlFleetDashboard=[pscustomobject]@{};LblFleetScope=[pscustomobject]@{ToolTip=''}};$script:Labels=@{}
 $script:Conn=[pscustomobject]@{BaseDn=$Domain};$script:SessionEpoch=7L;$script:FleetPendingKey='chosen';$script:FleetStale=$false;$script:SelectedObject=$null;$script:LastComputerDashboardResult=$null;$script:FleetObservations=@{}
 $script:IndexSyncStates=@{directory=(Sync directory $Domain '2026-10-13T09:00:00Z')}
 $snapshotAt=[datetime]::UtcNow;$adAt=$snapshotAt.AddMinutes(-12)
 $states=@{ou=(Sync ('ou:'+$Ou) $Ou $adAt.ToString('o'))}
 $source=[pscustomobject]@{Types=@();Groups=@();Machines=@();Targets=@();Presence=@();History=@();SyncStates=$states;SnapshotAtUtc=$snapshotAt.ToString('o');DomainDn=$Domain}
 $board=Get-DomeniaFleetBoardData $source -Scope $Ou -Now $adAt.AddMinutes(-3)
 Expect ($board.Freshness.Index.At -eq $adAt) 'Snapshot timestamp falsely rejected using older queued plan time'
 $source|Add-Member -NotePropertyName Board -NotePropertyValue $board
 $state=[pscustomobject]@{Epoch=7L;Key='chosen';Scope=$Ou;Subtree=$true;Name='Postes';ScopePath=$Ou}
 Complete-DomeniaFleetDashboard $source $state
 Expect ([object]::ReferenceEquals($script:Rendered.Freshness,$board.Freshness) -and $script:FleetLast.Freshness.Index.At -eq $adAt) 'Snapshot provenance was replaced'
 Expect ($script:Labels.LblFleetScope -like ('*Base locale (AD)*'+$board.Freshness.Index.At.ToLocalTime().ToString('HH:mm')+'*')) 'UI used mutable old directory date'
 Expect ($script:Labels.LblFleetDashboard -like '*Postes actifs*ping 0/0*inventaire WMI 0/0*Vue recalculée*') 'UI mixes three clocks'
}
Case 'Commit during an in-flight snapshot never repaints older dates or counts' {
 $script:FleetPendingKey='chosen';$script:FleetJobId='previous';$script:FleetComputedKey='chosen';$script:FleetStale=$true
 $script:FleetLastResult='keep latest';$before=$script:Rendered;$beforeLabel=$script:Labels.LblFleetScope;$script:RefreshCalls=0
 function Request-DomeniaFleetRefresh {$script:RefreshCalls++}
 $stale=[pscustomobject]@{Types=@();Machines=@();Board=[pscustomobject]@{}}
 Complete-DomeniaFleetDashboard $stale ([pscustomobject]@{Epoch=7L;Key='chosen'})
 Expect ($script:RefreshCalls -eq 1 -and $script:FleetPendingKey -eq '' -and $script:FleetJobId -eq '') 'Stale completion did not request a fresh local snapshot'
 Expect ([object]::ReferenceEquals($before,$script:Rendered) -and $script:Labels.LblFleetScope -eq $beforeLabel -and $script:FleetLastResult -eq 'keep latest') 'Stale callback repainted data before restarting'
 Expect ($script:FleetStale) 'Dirty generation was silently cleared'
}
Case 'Legacy LastSyncUtc argument is never used to synthesize scope coverage' {
 $script:IndexSyncStates=@{};$scope=[pscustomobject]@{Dn=$Ou;Subtree=$true;Path=$Ou}
 Update-DomeniaFleetScopeText $scope -Count 3 -LastSyncUtc '2026-10-13T11:59:00Z' -NowUtc $Now
 Expect ($script:Labels.LblFleetScope -like '*aucune lecture complète*') 'Global fallback accepted'
}
if(-not $SkipStorage){
 Case 'Real SQLite depth checkpoints, partial commits and repeat FleetStats preserve timestamps' {
  if($PSVersionTable.PSVersion.Major -ne 5 -or -not [Environment]::Is64BitProcess){throw 'Storage proof requires Windows PowerShell 5.1 x64'}
  $tokens=$null;$errors=$null;$core=[Management.Automation.Language.Parser]::ParseFile((Join-Path $wad 'Domenia-Core.ps1'),[ref]$tokens,[ref]$errors)
  if($errors.Count){throw 'Core parse error'}
  $native=@($core.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Initialize-DomeniaWinSqliteNative'},$true))
  if($native.Count -ne 1){throw 'Native bootstrap is ambiguous'}
  . ([scriptblock]::Create($native[0].Extent.Text));[void](Initialize-DomeniaWinSqliteNative)
  Add-Type -Path (Join-Path $modules 'Domenia.Native.dll')
  foreach($name in @('Storage.Worker','Engine.Worker','Probes.Model')){. (Join-Path $modules ('Domenia-'+$name+'.ps1'))}
  $storage=Get-DomeniaStorageWorkerCode;$read=Get-DomeniaLocalIndexReadWorkerCode
  $ast=[Management.Automation.Language.Parser]::ParseInput($storage,[ref]$tokens,[ref]$errors)
  foreach($f in $ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)){. ([scriptblock]::Create($f.Extent.Text))}
  $folder=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-Freshness-'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($folder);$path=Join-Path $folder 'freshness.sqlite'
  try{
   $schema=@($core.FindAll({param($n)($n -is [Management.Automation.Language.StringConstantExpressionAst] -or $n -is [Management.Automation.Language.ExpandableStringExpressionAst]) -and $n.Value -match '^PRAGMA journal_mode=WAL;' -and $n.Value -match 'CREATE TABLE IF NOT EXISTS schema_info'},$true))[0].Value
   $db=Open-DomeniaDatabase $path;try{[void](Invoke-DomeniaDbExec $schema $db)}finally{Close-DomeniaDatabase $db}
   function Read-States {
    $db=Open-DomeniaDatabase $path
    try{$states=@{};foreach($row in @(Invoke-DomeniaDbQuery 'SELECT scope,base_dn,last_sync,details FROM sync_state;' $db)){$states[[string]$row.scope]=$row};return $states}finally{Close-DomeniaDatabase $db}
   }
   function Write-Coverage([string]$Depth,[string]$At,[bool]$Complete=$true){
    $meta=[pscustomobject]@{Mode='Rows';ScopeDn=$Ou;SearchScope=$Depth;Complete=$Complete;ExpectedCount=0;Identities=@();StartedUtc='2026-10-01T08:00:00Z';Server='dc.example.invalid';InvocationId='instance-1'}
    $bulk=[pscustomobject]@{Rows=@();Transfer=$null;Reconcile=$meta;Server='dc.example.invalid';BaseDn=$Ou;SyncScope=('ou:'+$Ou.ToLowerInvariant());Complete=$Complete;ReplaceAll=$false;HighestUsn=10;InvocationId='instance-1';At=$At}
    $Payload=[pscustomobject]@{Path=$path;Items=@([pscustomobject]@{Kind='IndexBulk';Row=$bulk})}
    $receipt=& ([scriptblock]::Create($storage));Expect ([bool]$receipt.Saved) 'Missing SQLite commit receipt'
   }
   Write-Coverage Subtree '2026-10-01T10:00:00Z'
   Write-Coverage OneLevel '2026-10-01T11:00:00Z'
   $states=Read-States
   Expect ($states.ContainsKey('ou:'+$Ou.ToLowerInvariant()) -and $states.ContainsKey('ou:onelevel:'+$Ou.ToLowerInvariant())) 'Depth markers overwrite each other'
   Expect ((Coverage $states).At.Hour -eq 10 -and (Coverage $states $Ou $false).At.Hour -eq 11) 'Depth marker semantics wrong'
   Write-Coverage Subtree '2026-10-01T11:30:00Z' $false
   $states=Read-States;Expect ((Coverage $states).Partial -and (Coverage $states).At.Hour -eq 10) 'Partial committed read advanced successful date'
   Write-Coverage Subtree '2026-10-01T11:45:00Z'
   $states=Read-States;Expect (-not (Coverage $states).Partial -and (Coverage $states).At.Minute -eq 45) 'Complete commit did not replace partial state'
   $results=@()
   foreach($n in @(1,2)){
    $Payload=[pscustomobject]@{Action='FleetStats';Path=$path;BusyTimeoutMs=50;ModuleRoot=$modules;Scope=$Ou;Subtree=$true;DomainDn=$Domain;Plan=(Get-DomeniaFleetQueryPlan -Now ([datetime]::UtcNow));Keys=@();ScopeKey='fixture';ComputeBoard=$true;Lifecycle=$null;ObservationMaxAgeDays=30;IndexPartial='obsolete UI partial state'}
    $results+=& ([scriptblock]::Create($read))
   }
   Expect ($results.Count -eq 2 -and $results[0].Board.Freshness.Index.At -eq $results[1].Board.Freshness.Index.At -and $results[1].Board.Freshness.Index.At.Minute -eq 45) 'Repeated local read changed AD coverage date'
   Expect ($null -ne $results[1].SnapshotAtUtc -and $results[1].SyncStates.Count -eq $states.Count -and $results[1].Board.Freshness.Version -eq 1) 'Transactional provenance missing'
   Expect (@($results[1].Board.Attention|Where-Object{$_.Point -eq 'index.partial'}).Count -eq 0) 'Stale UI partial text overrides committed snapshot'
   $after=Read-States;Expect ($after['ou:'+$Ou.ToLowerInvariant()].last_sync -eq $states['ou:'+$Ou.ToLowerInvariant()].last_sync) 'Read-only worker changed checkpoint'
  }finally{if([IO.Directory]::Exists($folder)){Remove-Item -LiteralPath $folder -Recurse -Force}}
 }
}
$failed=@($script:Checks|Where-Object{-not $_.Passed}).Count
$report=[pscustomobject]@{Suite='Freshness';Passed=($failed -eq 0);Total=$script:Checks.Count;Failed=$failed;Assertions=$script:Assertions;StorageExecuted=(-not $SkipStorage);PowerShellVersion=[string]$PSVersionTable.PSVersion;Cases=$script:Checks.ToArray();Limitations=@('Synthetic local data only; no live AD or workstation measurement.')}
if($ReportPath){$parent=Split-Path -Parent $ReportPath;if($parent){[void][IO.Directory]::CreateDirectory($parent)};$report|ConvertTo-Json -Depth 9|Set-Content -LiteralPath $ReportPath -Encoding UTF8}
$report|ConvertTo-Json -Depth 9
if($failed){exit 1};exit 0
