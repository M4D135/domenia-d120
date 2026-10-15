#requires -Version 5.1
[CmdletBinding()]
param([string]$ReportPath='',[ValidateRange(200,20000)][int]$Count=2000,[switch]$Quiet)
# Point 132: measured hot spots. The same synthetic observations go through the PowerShell path and the compiled path
# (Domenia.Native.dll) of the same work, after a warm-up; Parity says whether both gave the same results at full scale.
# Each class of the native units is timed against a PowerShell equivalent: ObservationReader (decode), ProbeBatch,
# ProbeSamples and ValueGroup (aggregation, against the PowerShell reference below) and ProbeSelection (query segment).
# The report (Hotspots: PowerShellMs, CompiledMs, Units, Parity; Failed) feeds tools/compiled_code.py --measurements,
# which keeps a compiled unit only when every measure of it is at least MinimumGain times faster with identical results
# and the report has no failed case. No network, no AD, no window; fictitious data only.
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
function Get-ProbeValueRows {
    # Values of every selected probe of every workstation, read as the boards read them (Get-DomeniaProbeValues): the
    # timed work of the decode. The comparison text is built afterwards, outside the measure.
    param($Map)
    $rows=New-Object 'System.Collections.Generic.List[object]'
    foreach($key in $Map.Keys){
        $results=Get-DomeniaMemberValue $Map[$key] 'Probes'
        foreach($probe in $probes){$rows.Add([object[]]@([string]$key,[string]$probe.Id,@(Get-DomeniaProbeValues $probe (Get-DomeniaMemberValue $results ([string]$probe.Id)))))}
    }
    return ,$rows
}
function ConvertTo-ProbeValueText {
    # One line per workstation and probe, in ordinal order, values as compact JSON (type and number format included).
    param($Rows)
    $lines=New-Object 'System.Collections.Generic.List[string]'
    foreach($row in $Rows){$lines.Add([string]$row[0]+'|'+[string]$row[1]+'|'+(ConvertTo-Json -InputObject @($row[2]) -Compress))}
    $sorted=$lines.ToArray();[Array]::Sort($sorted,[StringComparer]::Ordinal)
    return [string]::Join("`n",$sorted)
}
function Get-EntryText {param($Entries) return [string]::Join("`n",@(@($Entries.Keys|Sort-Object)|ForEach-Object{$_+'='+((@($Entries[$_].Items)|ForEach-Object{[string]$_.Label+':'+[string]$_.Value}) -join ',')}))}
function ConvertTo-ReferenceNumber {
    # PowerShell reference of ProbeResult.Number: invariant number, NaN and infinities refused; $null otherwise.
    param([AllowNull()][string]$Text)
    $number=0.0
    if(([double]::TryParse([string]$Text,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$number)) -and (-not [double]::IsNaN($number)) -and (-not [double]::IsInfinity($number))){return $number}
    return $null
}
function New-PowerShellProbeSamples {
    # PowerShell reference of Domenia.Native.ProbeSamples and ValueGroup: the same members and rules (categories ignore
    # case, numbers counted per value, a workstation counted once per category in All mode), as script members.
    $samples=[pscustomobject]@{
        Values=[Collections.Generic.List[object]]::new();Machines=0;Skipped=0;Newest=$null;Oldest=$null;NumericCount=0;Sum=0.0;Min=0.0;Max=0.0
        GroupTable=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
        NumberTable=[Collections.Generic.SortedDictionary[double,int]]::new()
        UniqueRows=[Collections.Generic.List[object[]]]::new()
    }
    $samples|Add-Member -MemberType ScriptProperty -Name Numeric -Value {($this.Values.Count -gt 0) -and ($this.NumericCount -eq $this.Values.Count)}
    $samples|Add-Member -MemberType ScriptProperty -Name Distinct -Value {,([double[]]@($this.NumberTable.Keys))}
    $samples|Add-Member -MemberType ScriptMethod -Name Skip -Value {$this.Skipped=$this.Skipped+1}
    $samples|Add-Member -MemberType ScriptMethod -Name Add -Value {
        param([object[]]$Items,[datetime]$At)
        if(($null -eq $Items) -or ($Items.Count -eq 0)){return}
        $this.Machines=$this.Machines+1
        if(($null -eq $this.Newest) -or ($At -gt $this.Newest)){$this.Newest=$At}
        if(($null -eq $this.Oldest) -or ($At -lt $this.Oldest)){$this.Oldest=$At}
        $invariant=[Globalization.CultureInfo]::InvariantCulture
        foreach($value in $Items){
            $this.Values.Add($value)
            $text=[Convert]::ToString($value,$invariant);$group=$null
            if($this.GroupTable.TryGetValue($text,[ref]$group)){$group.Value=$group.Value+1}else{$this.GroupTable.Add($text,[pscustomobject]@{Label=$text;Value=1.0})}
            if(($value -is [double]) -or ($value -is [int]) -or ($value -is [long])){
                $number=[Convert]::ToDouble($value,$invariant);$count=0
                [void]$this.NumberTable.TryGetValue($number,[ref]$count);$this.NumberTable[$number]=$count+1
                if(($this.NumericCount -eq 0) -or ($number -lt $this.Min)){$this.Min=$number}
                if(($this.NumericCount -eq 0) -or ($number -gt $this.Max)){$this.Max=$number}
                $this.Sum=$this.Sum+$number;$this.NumericCount=$this.NumericCount+1
            }
        }
    }
    $samples|Add-Member -MemberType ScriptMethod -Name AddUnique -Value {
        param([object[]]$Items,[datetime]$At)
        $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $unique=[Collections.Generic.List[object]]::new()
        foreach($value in $Items){if($seen.Add([Convert]::ToString($value,[Globalization.CultureInfo]::InvariantCulture))){$unique.Add($value)}}
        $row=$unique.ToArray()
        if($row.Count -gt 0){$this.UniqueRows.Add($row)}
        $this.Add($row,$At)
    }
    $samples|Add-Member -MemberType ScriptMethod -Name CountEqual -Value {param([double]$Number) $count=0;if($this.NumberTable.TryGetValue($Number,[ref]$count)){return $count};return 0}
    $samples|Add-Member -MemberType ScriptMethod -Name CountRange -Value {
        param([double]$Low,[double]$High)
        $n=0
        if($this.UniqueRows.Count -gt 0){
            foreach($row in $this.UniqueRows){foreach($value in $row){$number=ConvertTo-ReferenceNumber ([Convert]::ToString($value,[Globalization.CultureInfo]::InvariantCulture));if(($null -ne $number) -and ($number -gt $Low) -and ($number -le $High)){$n++;break}}}
        }else{foreach($pair in $this.NumberTable.GetEnumerator()){if(($pair.Key -gt $Low) -and ($pair.Key -le $High)){$n+=$pair.Value}}}
        return $n
    }
    $samples|Add-Member -MemberType ScriptMethod -Name CountOther -Value {
        param([string[]]$Excluded)
        $known=[Collections.Generic.HashSet[string]]::new([string[]]@($Excluded),[StringComparer]::OrdinalIgnoreCase)
        $n=0
        if($this.UniqueRows.Count -gt 0){
            foreach($row in $this.UniqueRows){foreach($value in $row){if(-not $known.Contains([Convert]::ToString($value,[Globalization.CultureInfo]::InvariantCulture))){$n++;break}}}
        }else{foreach($pair in $this.GroupTable.GetEnumerator()){if(-not $known.Contains($pair.Key)){$n+=[int]$pair.Value.Value}}}
        return $n
    }
    $samples|Add-Member -MemberType ScriptMethod -Name Groups -Value {
        # Most frequent first, then label (invariant culture, case ignored), as ProbeSamples.Groups.
        $list=[Collections.Generic.List[object]]::new()
        foreach($group in $this.GroupTable.Values){$list.Add($group)}
        $list.Sort([Comparison[object]]{param($x,$y) $order=([double]$y.Value).CompareTo([double]$x.Value);if($order -ne 0){return $order};return [StringComparer]::InvariantCultureIgnoreCase.Compare([string]$x.Label,[string]$y.Label)})
        return ,$list.ToArray()
    }
    return $samples
}
function Measure-PowerShellFleetProbeEntries {
    # PowerShell reference of the compiled aggregation: the traversal, the hashtable of buckets and the widget measure
    # of Measure-DomeniaFleetProbeEntries, with PowerShell samples in place of ProbeBatch and ProbeSamples.
    param($Fleet,[hashtable]$Observations,[object[]]$Requests,[int]$MaxAgeDays=30,[datetime]$NowUtc)
    $buckets=@{};$entries=@{}
    foreach($request in $Requests){
        $id=[string]$request.Key
        if($buckets.ContainsKey($id)){continue}
        $probe=Get-DomeniaProbe $id;if($null -eq $probe){continue}
        $buckets[$id]=[pscustomobject]@{Probe=$probe;Samples=(New-PowerShellProbeSamples)}
    }
    $targets=Get-DomeniaMemberValue $Fleet 'Targets' @()
    foreach($target in $targets){
        $observation=$Observations[([string]$target.distinguished_name).ToLowerInvariant()]
        $observedGuid=[string](Get-DomeniaMember $observation 'Guid');$expectedGuid=[string]$target.object_guid
        if((-not $expectedGuid) -or (-not $observedGuid) -or ($expectedGuid.Trim().Trim('{','}').ToLowerInvariant() -ne $observedGuid.Trim().Trim('{','}').ToLowerInvariant())){continue}
        $results=Get-DomeniaMemberValue $observation 'Probes'
        foreach($id in @($buckets.Keys)){
            $result=Get-DomeniaMemberValue $results $id;if($null -eq $result){continue}
            $at=ConvertFrom-DomeniaUtcText ([string](Get-DomeniaMember $result 'CheckedUtc'))
            if((Test-DomeniaObservationAge -CheckedUtc $at -NowUtc $NowUtc -MaxDays $MaxAgeDays) -eq 'Expired'){continue}
            $bucket=$buckets[$id]
            if([string](Get-DomeniaMember $result 'Skipped')){$bucket.Samples.Skip();continue}
            if($bucket.Probe.Mode -eq 'All'){$bucket.Samples.AddUnique(@(Get-DomeniaProbeValues $bucket.Probe $result),$at)}else{$bucket.Samples.Add(@(Get-DomeniaProbeValues $bucket.Probe $result),$at)}
        }
    }
    foreach($request in $Requests){
        $id=[string]$request.Key;$visual=[string]$request.Visual;$key=$id+'|'+$visual
        if(($entries.ContainsKey($key)) -or (-not $buckets.ContainsKey($id))){continue}
        $bucket=$buckets[$id]
        $measure=Measure-DomeniaWidgetData -Probe $bucket.Probe -Samples $bucket.Samples -Visual $visual
        $entry=ConvertFrom-DomeniaProbeMeasure -Probe $bucket.Probe -Measured $measure -Board Fleet -Key $id
        if($measure.Machines){
            $coverage=Get-DomeniaCoverageText -Analysed $measure.Machines -Total $targets.Count -LastUtc $bucket.Samples.Newest
            $entry.Detail=([string]$entry.Detail+' · '+$coverage);$entry.Subtitle=$coverage
            if($bucket.Probe.Mode -eq 'All'){$entry.Detail+=' · Un poste peut figurer dans plusieurs catégories.'}
            if(($null -ne $bucket.Samples.Oldest) -and (($NowUtc-$bucket.Samples.Oldest).TotalDays -gt 7)){$entry.State='Off'}
        }
        $entries[$key]=$entry
    }
    return $entries
}
function Test-PowerShellProbeSelection {
    # PowerShell reference of Domenia.Native.ProbeSelection.Matches: one value of the workstation is enough.
    param($Selection,[Collections.Generic.Dictionary[string,object]]$Fields)
    $raw=$null
    if(-not $Fields.TryGetValue('_probe:'+[string]$Selection.Key,[ref]$raw)){return $false}
    if($raw -isnot [object[]]){return $false}
    $invariant=[Globalization.CultureInfo]::InvariantCulture
    foreach($value in $raw){
        $text=[Convert]::ToString($value,$invariant)
        if($Selection.Mode -ceq 'Range'){$number=ConvertTo-ReferenceNumber $text;if(($null -ne $number) -and ($number -gt $Selection.Low) -and ($number -le $Selection.High)){return $true}}
        elseif($Selection.Mode -ceq 'Equal'){
            if($Selection.Numeric){$number=ConvertTo-ReferenceNumber $text;$wanted=ConvertTo-ReferenceNumber $Selection.Value;if(($null -ne $number) -and ($null -ne $wanted) -and ($number -eq $wanted)){return $true}}
            elseif([string]::Equals($text,$Selection.Value,[StringComparison]::OrdinalIgnoreCase)){return $true}
        }
        elseif($Selection.Mode -ceq 'Other'){
            $excluded=$false
            foreach($item in $Selection.Excluded){if([string]::Equals($text,$item,[StringComparison]::OrdinalIgnoreCase)){$excluded=$true;break}}
            if(-not $excluded){return $true}
        }
    }
    return $false
}
function New-HotspotSelection {
    param([string]$Key,[string]$Mode,[bool]$Numeric,[string]$Value='',[double]$Low=0,[double]$High=0,[string[]]$Excluded=@())
    $selection=[Domenia.Native.ProbeSelection]::new();$selection.Key=$Key;$selection.Mode=$Mode;$selection.Numeric=$Numeric
    $selection.Value=$Value;$selection.Low=$Low;$selection.High=$High;$selection.Excluded=$Excluded
    return $selection
}

Case ('Selection de sondes reproductible ('+$probes.Count+' familles de transformation)') {
    Expect ($probes.Count -ge 5) 'Trop peu de sondes pour une mesure representative'
    Expect ($jsons.Count -eq $Count) 'Observations synthetiques incompletes'
}
Case ('Decodage des observations : memes valeurs et temps mesure pour '+$Count+' postes') {
    [void](Get-ProbeValueRows (Read-PowerShellObservations 50));[void](Get-ProbeValueRows (Read-CompiledObservations 50))
    # Timed: reading the JSON and normalising the values; the comparison text is built after the measure.
    $watch=[Diagnostics.Stopwatch]::StartNew();$psRows=Get-ProbeValueRows (Read-PowerShellObservations);$watch.Stop();$psMs=$watch.Elapsed.TotalMilliseconds
    $watch=[Diagnostics.Stopwatch]::StartNew();$nativeRows=Get-ProbeValueRows (Read-CompiledObservations);$watch.Stop();$nativeMs=$watch.Elapsed.TotalMilliseconds
    $parity=((ConvertTo-ProbeValueText $psRows) -ceq (ConvertTo-ProbeValueText $nativeRows))
    $script:Hotspots.Add([pscustomobject]@{Id='observation-decode';Units=$Count;PowerShellMs=[Math]::Round($psMs,1);CompiledMs=[Math]::Round($nativeMs,1);Parity=$parity;Probes=$probes.Count})
    Expect ($psRows.Count -eq ($Count*$probes.Count)) ('Valeurs lues : '+$psRows.Count)
    Expect $parity 'Valeurs differentes entre PowerShell et C#'
}
Case 'Agregation des sondes du parc : memes tranches avec des observations PowerShell ou C#' {
    $sample=[Math]::Min(300,$Count)
    $subset=[pscustomobject]@{Targets=@($targets|Select-Object -First $sample)}
    $ps=Measure-DomeniaFleetProbeEntries -Fleet $subset -Observations (Read-PowerShellObservations $sample) -Requests $requests -NowUtc $now
    $native=Measure-DomeniaFleetProbeEntries -Fleet $subset -Observations (Read-CompiledObservations $sample) -Requests $requests -NowUtc $now
    Expect ($ps.Count -eq $requests.Count) ('Entrees attendues : '+$requests.Count+', obtenues : '+$ps.Count)
    Expect ((Get-EntryText $ps) -ceq (Get-EntryText $native)) 'Tranches differentes entre les deux chemins'
}
Case ('Agregation des sondes du parc : memes tranches et temps mesure pour '+$Count+' postes') {
    # Both paths read the same decoded observations: only the aggregation is timed, the PowerShell buckets and samples
    # against ProbeBatch, ProbeSamples and ValueGroup.
    $observations=Read-CompiledObservations
    $warm=[pscustomobject]@{Targets=@($targets|Select-Object -First 50)}
    [void](Measure-PowerShellFleetProbeEntries -Fleet $warm -Observations $observations -Requests $requests -NowUtc $now)
    [void](Measure-DomeniaFleetProbeEntries -Fleet $warm -Observations $observations -Requests $requests -NowUtc $now)
    $watch=[Diagnostics.Stopwatch]::StartNew();$ps=Measure-PowerShellFleetProbeEntries -Fleet $fleet -Observations $observations -Requests $requests -NowUtc $now;$watch.Stop();$psMs=$watch.Elapsed.TotalMilliseconds
    $watch=[Diagnostics.Stopwatch]::StartNew();$native=Measure-DomeniaFleetProbeEntries -Fleet $fleet -Observations $observations -Requests $requests -NowUtc $now;$watch.Stop();$nativeMs=$watch.Elapsed.TotalMilliseconds
    $parity=(($ps.Count -eq $requests.Count) -and ((Get-EntryText $ps) -ceq (Get-EntryText $native)))
    $script:Hotspots.Add([pscustomobject]@{Id='probe-aggregation';Units=$Count;PowerShellMs=[Math]::Round($psMs,1);CompiledMs=[Math]::Round($nativeMs,1);Parity=$parity;Probes=$probes.Count})
    Expect $parity 'Tranches differentes entre la reference PowerShell et ProbeBatch a pleine echelle'
}
Case ('Segment de sonde des requetes : memes postes retenus et temps mesure pour '+$Count+' postes') {
    # Fields of the query records exactly as the query engine fills them (Observation.CopyQueryProbesTo).
    $observations=Read-CompiledObservations
    $records=New-Object 'System.Collections.Generic.List[object]'
    foreach($key in @($observations.Keys|Sort-Object)){$fields=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal);[void]$observations[$key].CopyQueryProbesTo($fields,$now,30);$records.Add($fields)}
    $numeric=@($probes|Where-Object{[string]$_.Transform -match '^(GB|GBfromKB|MB|Mbps|Number|DaysSince|PercentFree)$'})|Select-Object -First 1
    $category=@($probes|Where-Object{[string]$_.Transform -like 'Map:*'})|Select-Object -First 1
    Expect (($null -ne $numeric) -and ($null -ne $category)) 'Sonde numerique ou categorie absente de la selection'
    $numbers=@(@(foreach($fields in $records){$raw=$null;if($fields.TryGetValue('_probe:'+[string]$numeric.Id,[ref]$raw)){foreach($value in @($raw)){$n=ConvertTo-ReferenceNumber ([Convert]::ToString($value,[Globalization.CultureInfo]::InvariantCulture));if($null -ne $n){$n}}}})|Sort-Object)
    $first=$null;[void]$records[0].TryGetValue('_probe:'+[string]$category.Id,[ref]$first)
    Expect (($numbers.Count -gt 1) -and ($null -ne $first)) 'Valeurs de segment absentes'
    $label=[Convert]::ToString(@($first)[0],[Globalization.CultureInfo]::InvariantCulture)
    $selections=@(
        (New-HotspotSelection -Key ([string]$numeric.Id) -Mode 'Range' -Numeric $true -Low ([double]$numbers[0]) -High ([double]$numbers[-1]))
        (New-HotspotSelection -Key ([string]$numeric.Id) -Mode 'Equal' -Numeric $true -Value ([Convert]::ToString([double]$numbers[0],[Globalization.CultureInfo]::InvariantCulture)))
        (New-HotspotSelection -Key ([string]$category.Id) -Mode 'Equal' -Numeric $false -Value $label)
        (New-HotspotSelection -Key ([string]$category.Id) -Mode 'Other' -Numeric $false -Excluded @($label))
    )
    foreach($fields in @($records|Select-Object -First 50)){foreach($selection in $selections){[void]$selection.Matches($fields);[void](Test-PowerShellProbeSelection $selection $fields)}}
    $psHits=New-Object 'System.Collections.Generic.List[bool]';$nativeHits=New-Object 'System.Collections.Generic.List[bool]'
    $watch=[Diagnostics.Stopwatch]::StartNew();foreach($fields in $records){foreach($selection in $selections){$psHits.Add((Test-PowerShellProbeSelection $selection $fields))}};$watch.Stop();$psMs=$watch.Elapsed.TotalMilliseconds
    $watch=[Diagnostics.Stopwatch]::StartNew();foreach($fields in $records){foreach($selection in $selections){$nativeHits.Add($selection.Matches($fields))}};$watch.Stop();$nativeMs=$watch.Elapsed.TotalMilliseconds
    $parity=([string]::Join(',',$psHits.ToArray()) -ceq [string]::Join(',',$nativeHits.ToArray()))
    $script:Hotspots.Add([pscustomobject]@{Id='probe-selection';Units=$records.Count;PowerShellMs=[Math]::Round($psMs,1);CompiledMs=[Math]::Round($nativeMs,1);Parity=$parity;Probes=2})
    Expect ($records.Count -eq $Count) ('Enregistrements : '+$records.Count)
    Expect (($nativeHits -contains $true) -and ($nativeHits -contains $false)) 'Segments sans poste retenu ou sans poste ecarte : mesure non representative'
    Expect $parity 'Postes retenus differents entre PowerShell et ProbeSelection'
}

$bad=@($script:Tests|Where-Object{-not $_.Passed})
$report=[ordered]@{Suite='Test-DomeniaHotspots';Host=[ordered]@{Platform=$(if($env:OS -eq 'Windows_NT'){'Windows'}else{'Other'});PSEdition=[string]$PSVersionTable.PSEdition;PSVersion=$PSVersionTable.PSVersion.ToString()};Units=$Count;NoNetwork=$true;Passed=$script:Tests.Count-$bad.Count;Failed=$bad.Count;Hotspots=$script:Hotspots.ToArray();Tests=$script:Tests.ToArray()}
if(-not $ReportPath){$ReportPath=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-hotspots-'+[guid]::NewGuid().ToString('N')+'.json')}
[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
foreach($row in $script:Hotspots){Write-Host ($row.Id+' : PowerShell '+$row.PowerShellMs+' ms, C# '+$row.CompiledMs+' ms pour '+$row.Units+' postes.')}
Write-Host ('Rapport : '+$ReportPath)
if($bad.Count){exit 1};exit 0
