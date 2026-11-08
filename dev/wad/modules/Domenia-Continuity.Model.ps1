# Bounded presentation records. No account password, result row or secret is serialized.
function ConvertTo-DomeniaStateMap {
    param([string]$Text)
    $out=@{}
    if(-not $Text -or $Text.Length -gt 524288){return $out}
    try{$obj=$Text|ConvertFrom-Json -ErrorAction Stop;foreach($p in $obj.PSObject.Properties){if($out.Count -ge 80){break};$out[$p.Name]=$p.Value}}catch{if (${function:Write-DomeniaRuleSwallowed}) { Write-DomeniaRuleSwallowed 'Continuity' 'ConvertTo-DomeniaStateMap' $_ }}
    return $out
}
function ConvertTo-DomeniaColumnLayout {
    param($Rows)
    $out=[Collections.Generic.List[object]]::new();$keys=@{}
    foreach($r in @($Rows)){
        if($out.Count -ge 100){break}
        $key=[string]$r.Key;$unit=[string]$r.Unit
        if(-not $key -or $key.Length -gt 256 -or $keys.ContainsKey($key) -or $unit -notin @('Pixel','Star','Auto','SizeToCells','SizeToHeader')){continue}
        $width=0.0;$index=0
        if(-not [double]::TryParse([string]$r.Width,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$width) -or [double]::IsNaN($width) -or [double]::IsInfinity($width)){continue}
        if(-not [int]::TryParse([string]$r.Index,[ref]$index) -or $index -lt 0 -or $index -ge 100){continue}
        if($unit -eq 'Pixel'){$width=[Math]::Max(32,[Math]::Min(2000,$width))}
        elseif($unit -eq 'Star'){$width=[Math]::Max(0.1,[Math]::Min(20,$width))}
        else{$width=1}
        $keys[$key]=$true;$out.Add([pscustomobject]@{Key=$key;Index=$index;Width=$width;Unit=$unit})
    }
    return ,$out.ToArray()
}
function ConvertTo-DomeniaTreeBookmark {
    param($Record,[string]$BaseDn)
    if($null -eq $Record -or -not $BaseDn){return $null}
    $selected=[string]$Record.Selected
    if($selected.Length -gt 4096 -or -not ($selected -ieq $BaseDn -or $selected.EndsWith(','+$BaseDn,[StringComparison]::OrdinalIgnoreCase))){return $null}
    $expanded=[Collections.Generic.List[string]]::new()
    foreach($dn in @($Record.Expanded)){
        $dn=[string]$dn
        if($expanded.Count -ge 128){break}
        if($dn -and $dn.Length -le 4096 -and ($dn -ieq $BaseDn -or $dn.EndsWith(','+$BaseDn,[StringComparison]::OrdinalIgnoreCase)) -and -not $expanded.Contains($dn)){$expanded.Add($dn)}
    }
    return [pscustomobject]@{Selected=$selected;Expanded=$expanded.ToArray();Subtree=(ConvertTo-SuiteFlag $Record.Subtree -Default $true);At=[string]$Record.At}
}
function Get-DomeniaTreeRevealPath {
    # Follow RDN boundaries, including escaped commas. A suffix match alone is not a DN boundary.
    param([string]$Dn,[string]$BaseDn)
    $path=[Collections.Generic.List[string]]::new()
    if(-not $Dn -or -not $BaseDn -or $Dn.Length -gt 4096 -or $BaseDn.Length -gt 4096){return ,$path.ToArray()}
    $current=$Dn.Trim();$base=$BaseDn.Trim()
    for($i=0;$i -lt 256 -and $current;$i++){
        $path.Add($current)
        if([string]::Equals($current,$base,[StringComparison]::OrdinalIgnoreCase)){
            $path.Reverse();return ,$path.ToArray()
        }
        $parent=Get-DomeniaRawDnParent $current
        if(-not $parent -or $parent -ceq $current){break}
        $current=$parent
    }
    return ,([string[]]@())
}
function Get-DomeniaChangeWorkerCode {
    return @'
# Read-only check of existing listed GUIDs. A missing result is never proof of deletion.
$Payload.DirectoryReadState.Started=$true
try {
if(@($Payload.Items).Count -gt 24){throw 'Lot de verification trop grand.'}
$versionSource=Get-WDirectoryVersionSource $Context
$results=[Collections.Generic.List[object]]::new()
$records=[Collections.Generic.List[object]]::new()
$parts=[Collections.Generic.List[string]]::new();$requested=@{}
foreach($i in @($Payload.Items)){
    $g=[guid]::Empty
    if(-not [guid]::TryParse([string]$i.Guid,[ref]$g) -or $g -eq [guid]::Empty){continue}
    $hex=($g.ToByteArray()|ForEach-Object{'\'+$_.ToString('X2')}) -join ''
    $parts.Add('(objectGUID='+$hex+')');$requested[$g.ToString().ToLowerInvariant()]=$i
}
if(-not $parts.Count){[pscustomobject]@{Rows=@();Records=@();Server=[string]$Context.Server};return}
$filter='(&'+[string]$Payload.Filter+'(|'+($parts -join '')+'))'
$s=$null;$all=$null;$root=$null
try{
    $s=New-WSearcher $Context ([string]$Payload.BaseDn) $filter @('objectGUID','uSNChanged','distinguishedName','objectClass') ([string]$Payload.Scope) 0
    $root=$s.SearchRoot;$s.PageSize=24;$s.ServerTimeLimit=[timespan]::FromSeconds(8);$all=$s.FindAll()
    foreach($r in $all){
        if($Payload.StopToken.IsCancellationRequested){throw 'Reverification arretee.'}
        $guid=Convert-WGuid (Get-WPropFirst $r.Properties 'objectguid' '')
        $g=[guid]$guid;$key=$g.ToString().ToLowerInvariant()
        if(-not $requested.ContainsKey($key)){continue}
        $i=$requested[$key];$dn=[string](Get-WPropFirst $r.Properties 'distinguishedname' '')
        $number=Convert-WLargeInteger (Get-WPropFirst $r.Properties 'usnchanged' 0)
        $stamp=if($number -gt 0){$number.ToString([Globalization.CultureInfo]::InvariantCulture)}else{''}
        $row=$null;$status='Same';$properties=New-WDirectoryStoreProperties $r.Properties @('objectGUID','uSNChanged','distinguishedName','objectClass')
        $type=Get-WObjectType $r.Properties
        if(-not $stamp -or [string]$i.Stamp -cne ($versionSource+'|'+$stamp) -or [string]$i.DN -ine $dn){
            $detail=$null;$entry=$null;$detailRoot=$null
            try{
                $detail=New-WSearcher $Context $dn '(objectClass=*)' @('objectGUID','uSNChanged','name','distinguishedName','objectClass','samaccountname','userprincipalname','dnshostname','useraccountcontrol','lockouttime','msDS-User-Account-Control-Computed','operatingsystem','lastlogontimestamp','mail','description','whenchanged') 'Base' 1
                $detailRoot=$detail.SearchRoot;$detail.ServerTimeLimit=[timespan]::FromSeconds(5);$entry=$detail.FindOne()
                if($null -ne $entry -and (Convert-WGuid (Get-WPropFirst $entry.Properties 'objectguid' '')) -ieq $guid){
                    $row=New-WBranchRow $entry;$row|Add-Member -NotePropertyName Guid -NotePropertyValue $guid;$status='Changed'
                    $properties=New-WDirectoryStoreProperties $entry.Properties @('objectGUID','uSNChanged','name','distinguishedName','objectClass','samaccountname','userprincipalname','dnshostname','useraccountcontrol','lockouttime','msDS-User-Account-Control-Computed','operatingsystem','lastlogontimestamp','mail','description','whenchanged')
                    $type=[string]$row.Type
                    $detailNumber=Convert-WLargeInteger (Get-WPropFirst $entry.Properties 'usnchanged' 0)
                    $stamp=if($detailNumber -gt 0){$detailNumber.ToString([Globalization.CultureInfo]::InvariantCulture)}else{''}
                }
                else{$status='Unconfirmed'}
            }finally{if($null -ne $detail){$detail.Dispose()};if($null -ne $detailRoot){$detailRoot.Dispose()}}
        }
        $change=[pscustomobject]@{Guid=$guid;OldDN=[string]$i.DN;DN=$dn;Stamp=($versionSource+'|'+$stamp);Status=$status;Row=$row}
        $results.Add($change);$Payload.ChangeResults[[string]$guid]=$change
        $record=[pscustomobject]@{Properties=$properties;Type=$type;ObservedUtc=[datetime]::UtcNow.ToString('o');Source=[string]$Context.Server}
        $records.Add($record);$Payload.Progress.Enqueue($record)
        [void]$requested.Remove($key)
    }
    foreach($i in $requested.Values){$change=[pscustomobject]@{Guid=[string]$i.Guid;OldDN=[string]$i.DN;DN=[string]$i.DN;Stamp='';Status='Unconfirmed';Row=$null};$results.Add($change);$Payload.ChangeResults[[string]$i.Guid]=$change}
    $final=[pscustomobject]@{Rows=$results.ToArray();Records=$records.ToArray();Server=[string]$Context.Server}
    $Payload.DirectoryReadState.Final=$final
    $final
}finally{if($null -ne $all){$all.Dispose()};if($null -ne $s){$s.Dispose()};if($null -ne $root){$root.Dispose()}}
}catch{$Payload.DirectoryReadState.Error=$_.Exception.Message;throw}finally{$Payload.DirectoryReadState.Done=$true}
'@
}
