#requires -Version 5.1
param([string]$ReportPath='')
$ErrorActionPreference='Stop';$wad=Split-Path -Parent $PSScriptRoot
Add-Type -Path (Join-Path $wad 'modules/Domenia.Native.dll')
foreach($name in @('QueryLibrary.Model','Storage.Worker')){. (Join-Path $wad ('modules/Domenia-'+$name+'.ps1'))}
$t=$null;$e=$null;$worker=Get-DomeniaStorageWorkerCode;$ast=[Management.Automation.Language.Parser]::ParseInput($worker,[ref]$t,[ref]$e)
if($e.Count){throw 'Worker parse failed'}
foreach($name in @('Get-StoreWMap','Get-StoreWProjection')){$fn=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true))[0];. ([scriptblock]::Create($fn.Extent.Text))}
$cases=[Collections.Generic.List[object]]::new();$script:checks=0
function Expect {param([bool]$Condition,[string]$Text);$script:checks++;if(-not $Condition){throw $Text}}
function Case {param([string]$Name,[scriptblock]$Code);try{& $Code;$cases.Add([pscustomobject]@{Name=$Name;Passed=$true;Error=''})}catch{$cases.Add([pscustomobject]@{Name=$Name;Passed=$false;Error=$_.Exception.Message})}}
$now=[datetime]'2026-10-13T12:00:00Z';$at=$now.AddMinutes(-1).ToString('o');$definitions=[Collections.Generic.List[Domenia.Native.ProbeDefinition]]::new();$families=[Collections.Generic.List[object]]::new()
for($i=0;$i -lt 32;$i++){
 $id='fixture.'+$i;$d=[Domenia.Native.ProbeDefinition]::new();$d.Id=$id;$d.Mode='First';$d.Transform='Number';$d.QueryNumeric=$true;$definitions.Add($d)
 $probes=[ordered]@{};$probes[$id]=[pscustomobject]@{CheckedUtc=$at;Count=1;Rows=@(,@([string]$i));Instances=@([pscustomobject]@{Detail=('é'*9000)})}
 $families.Add([pscustomobject]@{Guid='00000000-0000-0000-0000-000000000001';DN='CN=Fixture,DC=test';Family=('Probe:'+$id);Revision=$i+1;Status='Success';Error='';LastSuccessAtUtc=$at;LastAttemptAtUtc=$at;Data=[pscustomobject]@{Probes=[pscustomobject]$probes};AttemptData=$null})
}
$reader=[Domenia.Native.ObservationReader]::new($definitions.ToArray());$projection=$null;$observation=$null
Case 'Summary removes instance graphs while canonical family data remains unchanged' {
 $raw=$families.ToArray()|ConvertTo-Json -Depth 12 -Compress;Expect ([Text.Encoding]::UTF8.GetByteCount($raw) -gt 262144) 'aggregate exceeds legacy bound'
 $script:projection=Get-StoreWProjection $families.ToArray() 'Fixture'
 foreach($family in $families){$id=$family.Family.Substring(6);Expect ($null -eq $projection.Probes[$id].PSObject.Properties['Instances']) 'no instance graph in projection';Expect ($family.Data.Probes.$id.Instances[0].Detail.Length -eq 9000) 'canonical unchanged'}
}
Case 'Separate preparation merges all families without concatenating their raw JSON' {
 $base=[ordered]@{};foreach($field in $projection.PSObject.Properties){if($field.Name -ne 'Probes'){$base[$field.Name]=$field.Value}}
 $script:observation=$reader.Read(($base|ConvertTo-Json -Depth 8 -Compress),$now);$observation.Probes=[Collections.Generic.Dictionary[string,Domenia.Native.ProbeResult]]::new([StringComparer]::Ordinal)
 foreach($id in $projection.Probes.Keys){$prepared=$reader.ReadProbe($id,($projection.Probes[$id]|ConvertTo-Json -Depth 8 -Compress),$now);$observation.Probes.Add($id,$prepared);Expect ($prepared.Prepared -and $null -eq $prepared.Rows) 'prepared and raw rows released'}
 Expect ($observation.Probes.Count -eq 32) 'all families retained';$values=[Collections.Generic.Dictionary[string,object]]::new();[void]$observation.CopyQueryProbesTo($values,$now,30)
 for($i=0;$i -lt 32;$i++){Expect ([double]$values['probe:fixture.'+$i] -eq $i) 'same numeric value'}
}
Case 'Failed family retains last success timestamp but is excluded from current query values' {
 $family=$families[0];$family.Status='Error';$family.Error='refused';$family.LastAttemptAtUtc=$now.ToString('o')
 $p=Get-StoreWProjection @($family) 'Fixture';$v=$reader.ReadProbe('fixture.0',($p.Probes['fixture.0']|ConvertTo-Json -Depth 8 -Compress),$now)
 Expect ($v.CheckedUtc -ceq $at -and $v.AttemptedUtc -ceq $now.ToString('o') -and $v.Succeeded -eq $false) 'two clocks retained'
 Expect ($v.Values.Count -eq 0 -and $null -eq $v.Rows -and $v.Error -ceq 'refused') 'failure unknown, small projection'
 Expect ($family.Data.Probes.'fixture.0'.Rows[0][0] -eq '0') 'last success canonical rows preserved'
}
Case 'Per-family UTF8 limit rejects multibyte overflow without accepting a partial result' {
 $caught=$false;try{[void]$reader.ReadProbe('fixture.0',('{"Error":"'+('é'*131072)+'"}'),$now)}catch{$caught=$true};Expect $caught 'UTF8 rather than character bound'
}
Case 'Count remains complete when details were truncated' {
 $d=[Domenia.Native.ProbeDefinition]::new();$d.Id='count';$d.Mode='Count';$d.Transform='Number';$d.QueryNumeric=$true;$r=[Domenia.Native.ObservationReader]::new(@($d))
 $p=$r.ReadProbe('count',('{"CheckedUtc":"'+$at+'","Count":20000,"Truncated":true}'),$now)
 Expect ($p.Values.Count -eq 1 -and [double]$p.Values[0] -eq 20000) 'full count'
}
Case 'Count with incomplete enumeration is unknown even when a partial count exists' {
 $d=[Domenia.Native.ProbeDefinition]::new();$d.Id='count';$d.Mode='Count';$d.Transform='Number';$r=[Domenia.Native.ObservationReader]::new(@($d))
 $p=$r.ReadProbe('count',('{"CheckedUtc":"'+$at+'","Count":20000,"CountComplete":false,"Rows":[["20000"]]}'),$now)
 Expect ($p.CountComplete -eq $false -and $p.Values.Count -eq 0 -and $null -eq $p.Rows) 'incomplete count unknown'
}
Case 'Unknown definition drops raw details while keeping diagnostics' {
 $p=$reader.ReadProbe('unknown',('{"CheckedUtc":"'+$at+'","Count":1,"Rows":[["value"]]}'),$now)
 Expect (-not $p.Prepared -and $null -eq $p.Rows -and $p.Count -eq 1) 'unknown catalog compact'
}
Case 'All truncation stays unknown and releases discarded rows' {
 $d=[Domenia.Native.ProbeDefinition]::new();$d.Id='all';$d.Mode='All';$d.Transform='Number';$r=[Domenia.Native.ObservationReader]::new(@($d))
 $p=$r.ReadProbe('all',('{"CheckedUtc":"'+$at+'","Rows":[["1"]],"Truncated":true}'),$now)
 Expect ($p.Values.Count -eq 0 -and $null -eq $p.Rows) 'unknown not sample-as-total'
}
$report=[pscustomobject]@{Suite='ObservationFamilies';Total=$cases.Count;Passed=@($cases|Where-Object Passed).Count;Failed=@($cases|Where-Object{-not $_.Passed}).Count;Assertions=$script:checks;Cases=$cases.ToArray();NativeSHA256=(Get-FileHash (Join-Path $wad 'modules/Domenia.Native.dll') -Algorithm SHA256).Hash;NoNetwork=$true;PowerShell=$PSVersionTable.PSVersion.ToString()}
if($ReportPath){[IO.File]::WriteAllText($ReportPath,($report|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))}
$report|Select-Object Total,Passed,Failed,Assertions|Format-List
if($report.Failed){exit 1};exit 0
