#requires -Version 5.1
param([string]$ReportPath='',[ValidateSet(10000,20000)][int]$Count=20000)
$ErrorActionPreference='Stop'
$source=Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'native/ObservationReader.cs'
# Windows PowerShell 5.1 uses the .NET Framework compiler; CompilerOptions is a PowerShell 7 parameter.
Add-Type -Path $source -ReferencedAssemblies @('System.dll','System.Core.dll','System.Xml.dll','System.Runtime.Serialization.dll')
$cases=[Collections.Generic.List[object]]::new();$script:assertions=0
function Expect {param([bool]$Value,[string]$Message);$script:assertions++;if(-not $Value){throw $Message}}
function Case {param([string]$Name,[scriptblock]$Code);try{& $Code;$cases.Add([pscustomobject]@{Name=$Name;Passed=$true;Error=''})}catch{$cases.Add([pscustomobject]@{Name=$Name;Passed=$false;Error=$_.Exception.Message});Write-Output ('FAIL '+$Name+': '+$_.Exception.Message)}}
$identity=[Domenia.Native.ObservationIdentityReader]::new()
$definition=[Domenia.Native.ProbeDefinition]::new();$definition.Id='fixture';$definition.Mode='First';$definition.Transform='Number';$definition.QueryNumeric=$true
$reader=[Domenia.Native.ObservationReader]::new([Domenia.Native.ProbeDefinition[]]@($definition));$now=[datetime]::UtcNow
function Pad-Json {param([int]$Bytes,[string]$Character='x');$start='{"Key":"fixture","Padding":"';$end='"}';$room=$Bytes-[Text.Encoding]::UTF8.GetByteCount($start+$end);$size=[Text.Encoding]::UTF8.GetByteCount($Character);return $start+($Character*[int][Math]::Floor($room/$size))+('x'*($room%$size))+$end}
Case 'Both readers accept the exact UTF8 byte budget' {
 foreach($character in @('x','é','漢')){
  $json=Pad-Json 262144 $character;Expect ([Text.Encoding]::UTF8.GetByteCount($json) -eq 262144) 'exact fixture bytes'
  Expect ($identity.Read($json).Key -eq 'fixture') 'identity boundary';Expect ($reader.Read($json,$now).Key -eq 'fixture') 'full boundary'
 }
}
Case 'Multibyte input below character cap still rejects byte overflow' {
 foreach($character in @('é','漢')){
  $json=Pad-Json 262145 $character;Expect ($json.Length -lt 262144) 'negative witness fits old character bound'
  $refused=$false;try{$identity.Read($json)|Out-Null}catch{$refused=$true};Expect $refused 'identity UTF8 overflow rejected'
  $refused=$false;try{$reader.Read($json,$now)|Out-Null}catch{$refused=$true};Expect $refused 'full UTF8 overflow rejected'
 }
}
Case ($Count.ToString()+' independent observations decode without loss') {
 $watch=[Diagnostics.Stopwatch]::StartNew();$seen=[Collections.Generic.HashSet[string]]::new()
 for($i=1;$i -le $Count;$i++){
  $guid='10000000-0000-0000-0000-'+$i.ToString('000000000000')
  $json='{"Version":1,"Guid":"'+$guid+'","Key":"cn=pc-'+$i+',dc=test","Probes":{"fixture":{"CheckedUtc":"2026-01-01T00:00:00Z","Rows":[["42"]]}}}'
  $row=$reader.Read($json,$now);Expect ($seen.Add($row.Guid)) 'unique object';Expect ($row.Probes['fixture'].Values[0] -eq 42 -and $null -eq $row.Probes['fixture'].Rows) 'prepared numeric value, raw graph released'
 }
 $watch.Stop();$script:elapsed=$watch.ElapsedMilliseconds;Expect ($seen.Count -eq $Count) 'exact decoded count'
}
$failed=@($cases|Where-Object{-not $_.Passed}).Count
$report=[pscustomobject]@{Suite='DomeniaObservationReaderBudget';Passed=($failed -eq 0);Total=$cases.Count;Failed=$failed;Assertions=$script:assertions;Objects=$Count;DecodeMs=$script:elapsed;SourceSHA256=(Get-FileHash $source -Algorithm SHA256).Hash;Platform=[Environment]::OSVersion.ToString();PowerShell=$PSVersionTable.PSVersion.ToString();Limitations='Compiles the C# source under test; does not qualify packaged Native.dll, Windows PowerShell 5.1, WPF or AD throughput. One numeric probe per object.';Cases=$cases.ToArray()}
if($ReportPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))}
Write-Output ('ObservationReader: '+($cases.Count-$failed)+'/'+$cases.Count+' cases, '+$script:assertions+' assertions')
if($failed){exit 1};exit 0
