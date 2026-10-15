#requires -Version 5.1
[CmdletBinding()]
param([string]$ReportPath='',[ValidateRange(200,20000)][int]$Count=2000,[switch]$Quiet)
# Point 132: measured hot spots. The same synthetic observations go through the PowerShell path and the compiled path
# (Domenia.Native.dll) of the same work, after a warm-up; both must give the same values. The report (Hotspots:
# PowerShellMs, CompiledMs, Units, Parity) feeds tools/compiled_code.py --measurements, which keeps a compiled unit only
# when it is at least MinimumGain times faster. No network, no AD, no window; fictitious data only.
$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition -ne 'Desktop' -or -not [Environment]::Is64BitProcess){throw 'Windows PowerShell 5.1 x64 requis.'}
$modules=Join-Path (Split-Path $PSScriptRoot -Parent) 'modules'
Add-Type -Path (Join-Path $modules 'Domenia.Native.dll')
foreach($name in @('Common.Model','HealthRules.Model','Boards.Model','BoardFleet.Model','Probes.Model')){. (Join-Path $modules ('Domenia-'+$name+'.ps1'))}
$script:Tests=[Collections.Generic.List[object]]::new()
$script:Hotspots=[Collections.Generic.List[object]]::new()
function Expect {param([bool]$Value,[string]$Message) if(-not $Value){throw $Message}}
function Case {param([string]$Name,[scriptblock]$Body)
    try{& $Body|Out-Null;$ok=$true;$detail=''}catch{$ok=$false;$detail=$_.Exception.Message}
    $script:Tests.Add([pscustomobject]@{Name=$Name;Passed=$ok;Detail=$detail})
    if(-not $Quiet -or -not $ok){Write-Host ("$ok | $Name | $detail")}
}
$now=[datetime]::UtcNow;$at=$now.AddHours(-1).ToString('o')
# Reproducible selection: the first probe of each transform family read in First or All mode (at most 12).
$catalog=@(Get-DomeniaProbeCatalog)
$probes=@($catalog|Where-Object{[string]$_.Mode -in @('First','All')}|Group-Object -Property Transform|Sort-Object -Property Name|ForEach-Object{$_.Group[0]}|Select-Object -First 12)
function Get-HotspotCells {
    # Plausible raw row of one probe, varied with the workstation index so that categories and buckets are filled.
    param($Probe,[int]$Index)
    switch -Regex ([string]$Probe.Transform){
        '^GB$'{return @([string](4294967296L*(1+($Index%8))))}
        '^GBfromKB$'{return @([string](4194304L*(1+($Index%8))))}
        '^MB$'{return @([string](1048576L*(512*(1+($Index%4)))))}
        '^Mbps$'{return @([string](100000000L*(1+($Index%10))))}
        '^DaysSince$'{return @($now.AddDays(-1*($Index%400)).ToString('o'))}
        '^Year$'{return @(([datetime]'2018-01-01').AddDays($Index%2500).ToString('o'))}
        '^PercentFree$'{return @([string](($Index%90)+5),'100')}
        '^Release$'{return @($(if($Index%2){'26100'}else{'22631'}),'1')}
        '^Map:'{$keys=@(([string]$Probe.Transform).Substring(4).Split(';')|ForEach-Object{$_.Split('=')[0]});return @($keys[$Index%$keys.Count])}
        default{return @([string](($Index%16)+1))}
    }
}
$jsons=New-Object 'System.Collections.Generic.List[string]'
$targets=New-Object 'System.Collections.Generic.List[object]'
for($i=1;$i -le $Count;$i++){
    $guid='20000000-0000-4000-8000-'+$i.ToString('000000000000')
    $dn='CN=PC-'+$i+',OU=Postes,DC=example,DC=invalid'
    $probeRows=@{}
    foreach($probe in $probes){$probeRows[[string]$probe.Id]=[pscustomobject]@{CheckedUtc=$at;Count=1;Rows=@(,@(Get-HotspotCells $probe $i));Error=''}}
    $jsons.Add((ConvertTo-Json -InputObject ([pscustomobject]@{Version=1;Guid=$guid;Key=$dn.ToLowerInvariant();CheckedUtc=$at;Probes=$probeRows}) -Depth 8 -Compress))
    $targets.Add([pscustomobject]@{name='PC-'+$i;distinguished_name=$dn;object_guid=$guid})
}
$fleet=[pscustomobject]@{Targets=$targets.ToArray()}
$requests=@($probes|ForEach-Object{[pscustomobject]@{Key=[string]$_.Id;Visual='Bar'}})
function Read-PowerShellObservations {param([int]$Take=[int]::MaxValue) $map=@{};$n=0;foreach($json in $jsons){if($n -ge $Take){break};$o=ConvertFrom-Json -InputObject $json;$map[[string]$o.Key]=$o;$n++};return $map}
function Read-CompiledObservations {param([int]$Take=[int]::MaxValue) $reader=New-DomeniaObservationReader;$map=@{};$n=0;foreach($json in $jsons){if($n -ge $Take){break};$o=$reader.Read($json,$now);$map[[string]$o.Key]=$o;$n++};return $map}
function Get-ProbeValueText {param($Map) $lines=New-Object 'System.Collections.Generic.List[string]';foreach($key in @($Map.Keys|Sort-Object)){foreach($probe in $probes){$lines.Add($key+'|'+[string]$probe.Id+'|'+((@(Get-DomeniaProbeValues $probe (Get-DomeniaMemberValue (Get-DomeniaMemberValue $Map[$key] 'Probes') ([string]$probe.Id))))|ConvertTo-Json -Compress))}};return [string]::Join("`n",$lines.ToArray())}
function Get-EntryText {param($Entries) return [string]::Join("`n",@(@($Entries.Keys|Sort-Object)|ForEach-Object{$_+'='+((@($Entries[$_].Items)|ForEach-Object{[string]$_.Label+':'+[string]$_.Value}) -join ',')}))}

Case ('Selection de sondes reproductible ('+$probes.Count+' familles de transformation)') {
    Expect ($probes.Count -ge 5) 'Trop peu de sondes pour une mesure representative'
    Expect ($jsons.Count -eq $Count) 'Observations synthetiques incompletes'
}
Case 'Decodage des observations : memes valeurs en PowerShell et en C#' {
    $sample=[Math]::Min(200,$Count)
    Expect ((Get-ProbeValueText (Read-PowerShellObservations $sample)) -ceq (Get-ProbeValueText (Read-CompiledObservations $sample))) 'Valeurs differentes entre les deux chemins'
}
Case ('Decodage des observations : temps mesure pour '+$Count+' postes') {
    [void](Read-PowerShellObservations 50);[void](Read-CompiledObservations 50)
    $watch=[Diagnostics.Stopwatch]::StartNew();$psMap=Read-PowerShellObservations;$psValues=(Get-ProbeValueText $psMap).Length;$watch.Stop();$psMs=$watch.Elapsed.TotalMilliseconds
    $watch=[Diagnostics.Stopwatch]::StartNew();$nativeMap=Read-CompiledObservations;$nativeValues=(Get-ProbeValueText $nativeMap).Length;$watch.Stop();$nativeMs=$watch.Elapsed.TotalMilliseconds
    Expect ($psValues -eq $nativeValues) 'Volumes de valeurs differents'
    $script:Hotspots.Add([pscustomobject]@{Id='observation-decode';Units=$Count;PowerShellMs=[Math]::Round($psMs,1);CompiledMs=[Math]::Round($nativeMs,1);Parity=$true;Probes=$probes.Count})
}
Case 'Agregation des sondes du parc : memes tranches avec des observations PowerShell ou C#' {
    $sample=[Math]::Min(300,$Count)
    $subset=[pscustomobject]@{Targets=@($targets|Select-Object -First $sample)}
    $ps=Measure-DomeniaFleetProbeEntries -Fleet $subset -Observations (Read-PowerShellObservations $sample) -Requests $requests -NowUtc $now
    $native=Measure-DomeniaFleetProbeEntries -Fleet $subset -Observations (Read-CompiledObservations $sample) -Requests $requests -NowUtc $now
    Expect ($ps.Count -eq $requests.Count) ('Entrees attendues : '+$requests.Count+', obtenues : '+$ps.Count)
    Expect ((Get-EntryText $ps) -ceq (Get-EntryText $native)) 'Tranches differentes entre les deux chemins'
}
Case ('Agregation des sondes du parc : temps mesure pour '+$Count+' postes') {
    $psMap=Read-PowerShellObservations;$nativeMap=Read-CompiledObservations
    [void](Measure-DomeniaFleetProbeEntries -Fleet ([pscustomobject]@{Targets=@($targets|Select-Object -First 50)}) -Observations $psMap -Requests $requests -NowUtc $now)
    $watch=[Diagnostics.Stopwatch]::StartNew();$ps=Measure-DomeniaFleetProbeEntries -Fleet $fleet -Observations $psMap -Requests $requests -NowUtc $now;$watch.Stop();$psMs=$watch.Elapsed.TotalMilliseconds
    $watch=[Diagnostics.Stopwatch]::StartNew();$native=Measure-DomeniaFleetProbeEntries -Fleet $fleet -Observations $nativeMap -Requests $requests -NowUtc $now;$watch.Stop();$nativeMs=$watch.Elapsed.TotalMilliseconds
    Expect ((Get-EntryText $ps) -ceq (Get-EntryText $native)) 'Tranches differentes a pleine echelle'
    $script:Hotspots.Add([pscustomobject]@{Id='probe-aggregation';Units=$Count;PowerShellMs=[Math]::Round($psMs,1);CompiledMs=[Math]::Round($nativeMs,1);Parity=$true;Probes=$probes.Count})
}

$bad=@($script:Tests|Where-Object{-not $_.Passed})
$report=[ordered]@{Suite='Test-DomeniaHotspots';Host=[ordered]@{Platform=$(if($env:OS -eq 'Windows_NT'){'Windows'}else{'Other'});PSEdition=[string]$PSVersionTable.PSEdition;PSVersion=$PSVersionTable.PSVersion.ToString()};Units=$Count;NoNetwork=$true;Passed=$script:Tests.Count-$bad.Count;Failed=$bad.Count;Hotspots=$script:Hotspots.ToArray();Tests=$script:Tests.ToArray()}
if(-not $ReportPath){$ReportPath=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-hotspots-'+[guid]::NewGuid().ToString('N')+'.json')}
[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
foreach($row in $script:Hotspots){Write-Host ($row.Id+' : PowerShell '+$row.PowerShellMs+' ms, C# '+$row.CompiledMs+' ms pour '+$row.Units+' postes.')}
Write-Host ('Rapport : '+$ReportPath)
if($bad.Count){exit 1};exit 0
