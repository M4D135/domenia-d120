# Typed probe details, bounded before retention. No provider, SQLite or GUI call occurs here.
function ConvertTo-DomeniaProbeDetailValue {
    param($Value)
    if($null -eq $Value){return [pscustomobject]@{Value=$null;Complete=$true}}
    if($Value -is [array]){
        if($Value.Count -gt 256){return [pscustomobject]@{Value=$null;Complete=$false}}
        $items=[Collections.Generic.List[object]]::new()
        foreach($item in $Value){
            if($item -is [array]){return [pscustomobject]@{Value=$null;Complete=$false}}
            $converted=ConvertTo-DomeniaProbeDetailValue $item
            if(-not $converted.Complete){return [pscustomobject]@{Value=$null;Complete=$false}}
            $items.Add($converted.Value)
        }
        return [pscustomobject]@{Value=$items.ToArray();Complete=$true}
    }
    if($Value -is [datetime]){return [pscustomobject]@{Value=$Value.ToUniversalTime().ToString('o');Complete=$true}}
    if($Value -is [bool] -or $Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or $Value -is [uint16] -or $Value -is [int32] -or $Value -is [uint32] -or $Value -is [int64] -or $Value -is [uint64] -or $Value -is [decimal]){return [pscustomobject]@{Value=$Value;Complete=$true}}
    if($Value -is [double] -or $Value -is [single]){return [pscustomobject]@{Value=$(if([double]::IsNaN($Value) -or [double]::IsInfinity($Value)){$null}else{$Value});Complete=(-not [double]::IsNaN($Value) -and -not [double]::IsInfinity($Value))}}
    if($Value -is [string] -or $Value -is [char]){if(([string]$Value).Length -le 16384){return [pscustomobject]@{Value=[string]$Value;Complete=$true}}}
    return [pscustomobject]@{Value=$null;Complete=$false}
}
function ConvertTo-DomeniaProbeDetailInstance {
    param($Instance,[string[]]$Properties,[int]$Index=0)
    $values=[ordered]@{};$incomplete=[Collections.Generic.List[string]]::new()
    foreach($name in $Properties){
        if($name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$'){throw 'Nom de propriété de sonde invalide.'}
        $property=$Instance.PSObject.Properties[$name]
        if($null -eq $property){$values[$name]=$null;$incomplete.Add($name);continue}
        $converted=ConvertTo-DomeniaProbeDetailValue $property.Value
        $values[$name]=$converted.Value
        if(-not $converted.Complete){$incomplete.Add($name)}
    }
    $identity=''
    foreach($name in @('__RELPATH','__PATH')){if($null -ne $Instance.PSObject.Properties[$name] -and [string]$Instance.$name){$identity=[string]$Instance.$name;break}}
    if($identity.Length -gt 4096){$identity=''}
    [pscustomobject]@{Id=$identity;Index=$Index;Values=[pscustomobject]$values;IncompleteProperties=$incomplete.ToArray()}
}
function New-DomeniaProbeDetailProjection {
    param([object[]]$Instances,[string[]]$Properties,[long]$TotalCount,[bool]$EnumerationComplete=$true,[ValidateSet('All','First','Count')][string]$Mode='All',[int]$BudgetBytes=98304,[int]$MaxInstances=2000)
    if($BudgetBytes -lt 1024 -or $BudgetBytes -gt 196608 -or $MaxInstances -lt 1 -or $MaxInstances -gt 10000 -or $TotalCount -lt 0){throw 'Budget de détails invalide.'}
    $kept=[Collections.Generic.List[object]]::new();$rows=[Collections.Generic.List[object]]::new();$bytes=1024L;$incomplete=$false;$budgetReached=$false
    foreach($item in $Instances){
        if($Mode -eq 'First' -and $kept.Count){break}
        if($kept.Count -ge $MaxInstances){$budgetReached=$true;break}
        $values=[ordered]@{};$compatibility=[Collections.Generic.List[object]]::new();$missing=[Collections.Generic.List[string]]::new()
        foreach($name in $Properties){
            $property=$item.Values.PSObject.Properties[$name]
            $value=if($null -ne $property){$property.Value}else{$null}
            $values[$name]=$value
            if($null -eq $property -or $name -in @($item.IncompleteProperties)){$missing.Add($name)}
            # Legacy summaries keep one display value; Instances preserves every typed array element.
            $first=if($value -is [array]){if($value.Count){$value[0]}else{$null}}else{$value}
            $compatibility.Add($(if($null -eq $first){''}else{[Convert]::ToString($first,[Globalization.CultureInfo]::InvariantCulture)}))
        }
        $instance=[pscustomobject]@{Id=[string]$item.Id;Index=$item.Index;Values=[pscustomobject]$values;IncompleteProperties=$missing.ToArray()}
        $row=$compatibility.ToArray()
        $size=[Text.Encoding]::UTF8.GetByteCount((ConvertTo-Json -InputObject $instance -Depth 8 -Compress))+[Text.Encoding]::UTF8.GetByteCount((ConvertTo-Json -InputObject $row -Depth 5 -Compress))+2
        if($bytes+$size -gt $BudgetBytes){$budgetReached=$true;break}
        $kept.Add($instance);$rows.Add($row);$bytes+=$size
        if($missing.Count){$incomplete=$true}
    }
    $limited=($Mode -in @('All','Count') -and ($kept.Count -lt $TotalCount -or -not $EnumerationComplete)) -or ($budgetReached -or $incomplete)
    $reason=if(-not $EnumerationComplete){'Énumération interrompue'}elseif($budgetReached -or ($Mode -in @('All','Count') -and $kept.Count -lt $TotalCount)){'Budget de détails atteint'}elseif($incomplete){'Certaines valeurs ne sont pas entièrement conservées'}else{''}
    [pscustomobject]@{Properties=$Properties;Instances=$kept.ToArray();Rows=$rows.ToArray();Count=$TotalCount;StoredCount=$kept.Count;Truncated=$limited;CountComplete=$EnumerationComplete;Mode=$Mode;LimitReason=$reason;DetailBudgetBytes=$BudgetBytes;DetailBytes=$bytes;EnumerationComplete=$EnumerationComplete}
}
function Get-DomeniaProbeDetailPage {
    param($Probe,[string[]]$Properties,[int]$Offset=0,[int]$Limit=100)
    if($Offset -lt 0 -or $Limit -lt 1 -or $Limit -gt 500){throw 'Page de détails invalide.'}
    $legacy=($null -eq $Probe.PSObject.Properties['Instances'])
    $instances=if($null -ne $Probe.Instances){@($Probe.Instances)}else{@()};$rows=[Collections.Generic.List[object]]::new()
    if($legacy -and $null -ne $Probe.Rows){
        $converted=[Collections.Generic.List[object]]::new()
        $index=0
        foreach($row in $Probe.Rows){
            $values=[ordered]@{};$missing=[Collections.Generic.List[string]]::new();$cells=@($row)
            for($column=0;$column -lt $Properties.Count;$column++){
                $name=$Properties[$column]
                if($column -lt $cells.Count){$values[$name]=$cells[$column]}else{$values[$name]=$null;$missing.Add($name)}
            }
            $converted.Add([pscustomobject]@{Id='';Index=$index;Values=[pscustomobject]$values;IncompleteProperties=$missing.ToArray()});$index++
        }
        $instances=$converted.ToArray()
    }
    $stop=[Math]::Min([long]$instances.Count,[long]$Offset+$Limit)
    for($i=$Offset;$i -lt $stop;$i++){
        $instance=$instances[$i];$record=[ordered]@{Ligne=($i+1);Identité=[string]$instance.Id}
        foreach($name in $Properties){$value=$instance.Values.$name;$record[$name]=if($name -in @($instance.IncompleteProperties)){'Non conservé entièrement'}elseif($null -eq $value){'Non renseigné'}elseif($value -is [array]){ConvertTo-Json -InputObject $value -Depth 4 -Compress}else{$value}}
        $rows.Add([pscustomobject]$record)
    }
    $count=0L;$validCount=($null -ne $Probe.Count -and [long]::TryParse([string]$Probe.Count,[ref]$count) -and $count -ge 0)
    [pscustomobject]@{Rows=$rows.ToArray();Offset=$Offset;Limit=$Limit;StoredCount=$instances.Count;ReportedCount=$(if($validCount){$count}else{$null});CountComplete=($validCount -and $Probe.CountComplete -is [bool] -and $Probe.CountComplete);Legacy=$legacy;Truncated=[bool]$Probe.Truncated;HasPrevious=($Offset -gt 0);HasNext=($stop -lt $instances.Count);CheckedUtc=[string]$Probe.CheckedUtc;LimitReason=[string]$Probe.LimitReason}
}
function Get-DomeniaProbeDetailWorkerPrelude {
    if($script:DomeniaProbeDetailWorkerPrelude){return $script:DomeniaProbeDetailWorkerPrelude}
    $code=foreach($name in @('ConvertTo-DomeniaProbeDetailValue','ConvertTo-DomeniaProbeDetailInstance','New-DomeniaProbeDetailProjection')){'function '+$name+" {`n"+(Get-Command $name -CommandType Function).Definition+"`n}"}
    $script:DomeniaProbeDetailWorkerPrelude=$code -join "`n"
    return $script:DomeniaProbeDetailWorkerPrelude
}
