#requires -Version 5.1
[CmdletBinding()]param([string]$ReportPath='')
$ErrorActionPreference='Stop';Set-StrictMode -Version 2
$modules=Join-Path (Split-Path -Parent $PSScriptRoot) 'modules'
foreach($name in @('Common.Model','HealthRules.Model','Boards.Model','BoardFleet.Model','HealthRules.UI','Dashboard.UI','Storage.Worker','Engine.Worker')){. (Join-Path $modules ('Domenia-'+$name+'.ps1'))}
$checks=[Collections.Generic.List[object]]::new()
function Expect($ok,$why){if(-not $ok){throw $why}}
function Case($name,[scriptblock]$body){try{&$body;$checks.Add([pscustomobject]@{Name=$name;Passed=$true;Error=''})}catch{$checks.Add([pscustomobject]@{Name=$name;Passed=$false;Error=($_.Exception.Message+' '+$_.ScriptStackTrace)})}}
function Test-DomeniaGuidText([string]$Text){$g=[guid]::Empty;return [guid]::TryParse($Text,[ref]$g)}
function Get-DomeniaEffectiveWorkerResult($Result,$Properties){return $Result}
function New-DomeniaStoreContext($RequestId,$Generation){return [pscustomobject]@{StoreId='fixture';Path=$script:DatabaseScopedPath;Generation=$Generation}}
function Request-DomeniaStoreRead($Context,$Query,$CallbackState,$SuccessHandler,$ErrorHandler){$script:Reads.Add([pscustomobject]@{Context=$Context;Query=$Query;State=$CallbackState});return 'read-job'}
function Show-DomeniaBoard($Board,[switch]$Quiet,[switch]$DeferIfHidden){$script:Renders++}
function Get-DomeniaSetting($Key,$Default){if($script:Settings.ContainsKey($Key)){return $script:Settings[$Key]};return $Default}
function Reset-State {
 $script:SessionEpoch=4L;$script:DatabaseScopedPath='/fixture/store.db';$script:SelectedObjectGeneration=9L;$script:StoreSnapshotRevision=10L
 $script:SelectedObject=[pscustomobject]@{Type='Machine';Guid='00000000-0000-0000-0000-000000000001';DN='CN=PC,OU=Test,DC=example,DC=invalid'}
 $script:FleetSelectedReads=@{};$script:FleetObservations=@{};$script:Reads=[Collections.Generic.List[object]]::new();$script:Renders=0;$script:Settings=@{}
}
function Response([object[]]$Rows=@(),[long]$Revision=10){[pscustomobject]@{ObservationRows=$Rows;SnapshotRevision=$Revision;Busy=$false;Missing=$false;DataSource='SQLite';StoreId='fixture';Path=$script:DatabaseScopedPath}}
function Row([long]$Revision=10){[pscustomobject]@{Guid=$script:SelectedObject.Guid;Revision=$Revision;Presence='En ligne';PresenceCheckedUtc='2026-10-13T12:00:00Z'}}
Case 'State marker includes epoch path GUID selection generation and revision' {
 Reset-State;Expect (Request-DomeniaSelectedObservation) 'First read not admitted';Expect (-not (Request-DomeniaSelectedObservation)) 'Duplicate read admitted'
 Expect ($script:Reads[0].State.Marker -ceq '4|/fixture/store.db|00000000-0000-0000-0000-000000000001|9|10') 'Marker incomplete'
 foreach($change in @('Revision','Generation','Path','Guid','Epoch')){
  switch($change){Revision{$script:StoreSnapshotRevision++}Generation{$script:SelectedObjectGeneration++}Path{$script:DatabaseScopedPath='/fixture/other.db'}Guid{$script:SelectedObject.Guid='00000000-0000-0000-0000-000000000002'}Epoch{$script:SessionEpoch++}}
  Expect (Request-DomeniaSelectedObservation) ('Read blocked after '+$change)
 }
 Expect ($script:Reads.Count -eq 6) 'Unexpected read count'
}
Case 'Explicit local invalidation clears a complete marker once' {
 Reset-State;[void](Request-DomeniaSelectedObservation);Expect (Request-DomeniaSelectedObservation -Force) 'Force retained old marker';Expect (-not (Request-DomeniaSelectedObservation)) 'Force caused repeated reads'
}
Case 'Canonical committed observation publishes once; raw and wrong-store results do not' {
 foreach($invalid in @('Raw','Store','Path')){
  Reset-State;[void](Request-DomeniaSelectedObservation);$state=$script:Reads[0].State;$r=Response @((Row))
  switch($invalid){Raw{$r.DataSource='Memory'}Store{$r.StoreId='other'}Path{$r.Path='/other.db'}}
  Complete-DomeniaSelectedObservation $r $state;Expect ($script:FleetObservations.Count -eq 0 -and $script:FleetSelectedReads.Count -eq 0) 'Uncommitted data published'
 }
 Reset-State;[void](Request-DomeniaSelectedObservation);Complete-DomeniaSelectedObservation (Response @((Row))) $script:Reads[0].State
 Expect ($script:FleetObservations.Count -eq 1 -and $script:Renders -eq 1) 'Committed observation not published'
}
Case 'Commit during read rejects old snapshot and schedules current revision' {
 Reset-State;[void](Request-DomeniaSelectedObservation);$old=$script:Reads[0].State;$script:StoreSnapshotRevision=11
 Complete-DomeniaSelectedObservation (Response @((Row))) $old
 Expect ($script:FleetObservations.Count -eq 0 -and $script:Reads.Count -eq 2 -and $script:Reads[1].State.RequestedRevision -eq 11) 'Old read repainted or current read missing'
 Complete-DomeniaSelectedObservation (Response @((Row 11)) 11) $script:Reads[1].State
 Expect ($script:FleetObservations.Values[0].Revision -eq 11) 'Latest snapshot not published'
}
Case 'Callback from another selection never clears or renders the new selection' {
 foreach($change in @('Object','Epoch','Path','Generation')){
  Reset-State;[void](Request-DomeniaSelectedObservation);$state=$script:Reads[0].State;$response=Response @((Row))
  switch($change){Object{$script:SelectedObject=$null}Epoch{$script:SessionEpoch++}Path{$script:DatabaseScopedPath='/different.db'}Generation{$script:SelectedObjectGeneration++}}
  Complete-DomeniaSelectedObservation $response $state
  Expect ($script:Renders -eq 0 -and $script:FleetObservations.Count -eq 0) 'Stale callback affected UI'
 }
}
Case 'Canonical absence clears a deleted observation and does not cause a read loop' {
 Reset-State;$script:FleetObservations[$script:SelectedObject.DN.ToLowerInvariant()]=Row 9;[void](Request-DomeniaSelectedObservation)
 Complete-DomeniaSelectedObservation (Response) $script:Reads[0].State
 Expect ($script:FleetObservations.Count -eq 0 -and $script:Renders -eq 1 -and -not (Request-DomeniaSelectedObservation)) 'Canonical absence retained ghost or looped'
}
Case 'Older object revision never overwrites newer canonical object' {
 Reset-State;$script:FleetObservations[$script:SelectedObject.DN.ToLowerInvariant()]=Row 12;[void](Request-DomeniaSelectedObservation)
 Complete-DomeniaSelectedObservation (Response @((Row 9)) 12) $script:Reads[0].State
 Expect ($script:FleetObservations.Values[0].Revision -eq 12 -and $script:Renders -eq 0) 'Older object replaced newer measurement'
}
Case 'Worker captures health policy and loads its pure dependency before model' {
 $text=Get-DomeniaLocalIndexReadWorkerCode;$tokens=$null;$errors=$null;[void][Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
 Expect (@($errors).Count -eq 0) 'Worker no longer parses'
 Expect ($text -match "'Domenia-HealthRules.Model.ps1','Domenia-Boards.Model.ps1'" -and $text -match '-HealthPolicy.*Payload.HealthPolicy') 'Worker ignores captured policy'
 $ui=[IO.File]::ReadAllText((Join-Path $modules 'Domenia-Dashboard.UI.ps1'))
 Expect ($ui -match 'HealthPolicy=\$policy' -and $ui -match 'Get-DomeniaFleetQueryPlan[^\r\n]+-HealthPolicy \$policy' -and $ui -match 'Get-DomeniaComputerBoardData[^\r\n]+-HealthPolicy') 'Policy UI hook missing'
}
$failed=@($checks|Where-Object{-not $_.Passed}).Count
$report=[pscustomobject]@{Suite='DashboardState';Passed=($failed -eq 0);Total=$checks.Count;Failed=$failed;WpfExecuted=$false;NetworkUsed=$false;Checks=$checks.ToArray()}
if($ReportPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))}
$checks|Where-Object{-not $_.Passed}|Format-List|Out-String|Write-Output
Write-Output (($checks.Count-$failed).ToString()+'/'+$checks.Count+' passed');if($failed){exit 1}
