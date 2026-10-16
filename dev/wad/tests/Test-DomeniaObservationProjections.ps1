#requires -Version 5.1
[CmdletBinding()]param([string]$ReportPath='')
$ErrorActionPreference='Stop';Set-StrictMode -Version 2
# P-CD-09: the catch blocks of the core and of the UI modules trace an ignored error with Write-DomeniaSwallowed, defined
# in the script scope of Domenia-Core.ps1. Functions loaded one by one stay silent here, as before the sweep (no-op double;
# the trace itself is tested in rules/Common.Tests.ps1 and Test-DomeniaFaults.ps1).
function Write-DomeniaSwallowed { param($Category,$Operation,$ErrorRecord,$Now) }
$modules=Join-Path (Split-Path -Parent $PSScriptRoot) 'modules';$dev=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
# LocalIndexRead composes the shared SQLite layer of the workers (Domenia-Storage.Worker.ps1, P-CD-08).
. (Join-Path $modules 'Domenia-Storage.Worker.ps1')
. (Join-Path $modules 'Domenia-Engine.Worker.ps1')
. (Join-Path $modules 'Domenia-Probes.Model.ps1')
. (Join-Path $modules 'Domenia-QueryLibrary.Model.ps1')
if($null -eq ('Domenia.Native.ObservationReader' -as [type])){Add-Type -Path (Join-Path $dev 'native/ObservationReader.cs') -ReferencedAssemblies @('System.dll','System.Core.dll','System.Xml.dll','System.Runtime.Serialization.dll')}
$tokens=$null;$errors=$null;$code=Get-DomeniaLocalIndexReadWorkerCode
$ast=[Management.Automation.Language.Parser]::ParseInput($code,[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
foreach($name in @('Get-StoreWMap','Get-StoreWProjection','Convert-IdxWParkObservationSummary','Convert-IdxWFleetObservationSummary')){
 $definition=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true));if($definition.Count -ne 1){throw ('Helper absent '+$name)};. ([scriptblock]::Create($definition[0].Extent.Text))
}
$checks=[Collections.Generic.List[object]]::new();$now=([datetime]'2026-10-13T12:00:00Z').ToUniversalTime();$reader=New-DomeniaObservationReader;$guid='11111111-1111-1111-1111-111111111111';$dn='CN=PC,OU=Fleet,DC=example,DC=invalid'
function Expect($ok,$why){if(-not $ok){throw $why}}
function Case($name,[scriptblock]$body){try{&$body;$checks.Add([pscustomobject]@{Name=$name;Passed=$true;Error=''})}catch{$checks.Add([pscustomobject]@{Name=$name;Passed=$false;Error=($_.Exception.Message+' '+$_.ScriptStackTrace)})}}
function Observation($Id,$Entry,[string]$Status='Success'){
 $probes=[ordered]@{};$probes[$Id]=$Entry
 [pscustomobject]@{Guid=$guid;DN=$dn;Family=('Probe:'+$Id);Status=$Status;LastSuccessAtUtc=$now.AddMinutes(-2).ToString('o');LastAttemptAtUtc=$now.ToString('o');Revision=7L;Error=$(if($Status -eq 'Error'){'Lecture refusée'}else{''});Data=[pscustomobject]@{Computer='PC';Probes=[pscustomobject]$probes};AttemptData=$null}
}
function Entry($Rows,[int]$Count=1){[pscustomobject]@{CheckedUtc=$now.AddMinutes(-2).ToString('o');DefinitionHash='abc';Error='';Skipped='';Count=$Count;CountComplete=$true;StoredCount=$Count;Rows=$Rows;Instances=@([pscustomobject]@{Id='instance';Values=[pscustomobject]@{Name='last measured'};IncompleteProperties=@()});Truncated=$false}}
Case 'Canonical projection omits instance graph but preserves typed family readback unchanged' {
 $entry=Entry @(,@('8'));$o=Observation 'hw.cores' $entry;$projection=Get-StoreWProjection @($o) 'PC'
 Expect ($null -eq $projection.Probes.'hw.cores'.PSObject.Properties['Instances']) 'Instances retained in dashboard projection'
 Expect ($o.Data.Probes.'hw.cores'.Instances.Count -eq 1) 'Canonical detailed payload mutated'
 $summary=Convert-IdxWFleetObservationSummary $projection $reader $now
 Expect ($summary.Probes.'hw.cores'.Prepared -and $summary.Probes.'hw.cores'.Values[0] -eq 8 -and $null -eq $summary.Probes.'hw.cores'.Rows) 'Native summary not prepared'
}
Case 'One failed family does not replace prior successful data or hide all other families' {
 $entry=Entry @(,@('8'));$o=Observation 'hw.cores' $entry 'Error';$good=Observation 'hw.model' (Entry @(,@('Workstation')))
 $p=Get-StoreWProjection @($o,$good) 'PC';$s=Convert-IdxWFleetObservationSummary $p $reader $now
 Expect ($s.Probes.'hw.cores'.Values.Count -eq 0 -and $s.Probes.'hw.cores'.Error -eq 'Lecture refusée') 'Failed family considered current'
 Expect ($s.Probes.'hw.model'.Values[0] -eq 'Workstation') 'Other family lost'
 Expect ($s.Times.'Probe:hw.cores'.ObservedUtc -eq $now.AddMinutes(-2).ToString('o')) 'Failed attempt freshened success'
 Expect ($o.Data.Probes.'hw.cores'.Rows[0][0] -eq '8') 'Raw successful value overwritten'
}
Case 'Park scheduling projection retains provenance without rows or instances and does not mutate input' {
 $entry=Entry @(,@('8'));$p=Get-StoreWProjection @((Observation 'hw.cores' $entry)) 'PC'
 $s=Convert-IdxWParkObservationSummary $p;$v=$s.Probes.'hw.cores'
 Expect ($v.DefinitionHash -eq 'abc' -and $v.CountComplete -and $v.CheckedUtc -eq $entry.CheckedUtc) 'Scheduling provenance lost'
 Expect ($null -eq $v.PSObject.Properties['Rows'] -and $null -eq $v.PSObject.Properties['Instances']) 'Park retains heavy graph'
 Expect ($p.Probes.'hw.cores'.Rows.Count -eq 1) 'Scheduling mutated another reader projection'
}
Case 'Combined canonical families above old aggregate budget still produce independent summaries' {
 $obs=@();foreach($id in @('soft.servicedetails','soft.processdetails','soft.startupdetails','soft.hotfixdetails')){$rows=@(foreach($i in 1..200){,@(('value-'+$i),('x'*240))});$entry=Entry $rows 200;$entry.Instances=@(foreach($i in 1..200){[pscustomobject]@{Id=[string]$i;Values=[pscustomobject]@{Name=('x'*200)};IncompleteProperties=@()}});$obs+=Observation $id $entry}
 $fullJson=$obs|ConvertTo-Json -Depth 12 -Compress;Expect ([Text.Encoding]::UTF8.GetByteCount($fullJson) -gt 262144) 'Fixture does not reproduce large combined payload'
 $p=Get-StoreWProjection $obs 'PC';$s=Convert-IdxWFleetObservationSummary $p $reader $now
 foreach($id in @('soft.servicedetails','soft.processdetails','soft.startupdetails','soft.hotfixdetails')){Expect ($s.Probes.$id.Values.Count -eq 200 -and $null -eq $s.Probes.$id.Rows) ('Family lost '+$id)}
 $park=Convert-IdxWParkObservationSummary $p;Expect ([Text.Encoding]::UTF8.GetByteCount(($park|ConvertTo-Json -Depth 8 -Compress)) -lt 16384) 'Scheduling projection oversized'
}
Case 'Incomplete enumeration cannot become an exact Count and truncation remains explicit' {
 $e=Entry @(,@('A')) 14;$e.CountComplete=$false;$e.Truncated=$true
 $p=Get-StoreWProjection @((Observation 'soft.processes' $e)) 'PC';$s=Convert-IdxWFleetObservationSummary $p $reader $now
 Expect ($s.Probes.'soft.processes'.Values.Count -eq 0 -and -not $s.Probes.'soft.processes'.CountComplete) 'Partial Count treated as exact'
}
Case 'Worker keeps exact revision and targeted family guards before StoreRead' {
 Expect ($code -like '*SnapshotRevision* -ne $revision*') 'Exact snapshot guard missing'
 Expect ($code.Contains('$readArgs.ObservationFamilies=@([string]$query.Family)')) 'Family predicate not pushed to SQL read'
 Expect ($code.Contains('$readArgs.DetailProjection=[string]$query.DetailProjection')) 'Detail summary mode not forwarded'
 $dashboard=[IO.File]::ReadAllText((Join-Path $modules 'Domenia-Dashboard.UI.ps1'));Expect ($dashboard -like '*ObservationFamilies=$families*') 'Dashboard reads every probe family'
 $widgets=[IO.File]::ReadAllText((Join-Path $modules 'Domenia-Widgets.UI.ps1'));Expect ($widgets -like '*Show-DomeniaProbeDetails -ProbeId*') 'Recorded instance detail action missing'
}
$failed=@($checks|Where-Object{-not $_.Passed}).Count;$report=[pscustomobject]@{Suite='ObservationProjections';Passed=($failed -eq 0);Total=$checks.Count;Failed=$failed;DatabaseUsed=$false;NetworkUsed=$false;Checks=$checks.ToArray()}
if($ReportPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))}
$checks|Where-Object{-not $_.Passed}|Format-List|Out-String|Write-Output;Write-Output (($checks.Count-$failed).ToString()+'/'+$checks.Count+' passed');if($failed){exit 1}
