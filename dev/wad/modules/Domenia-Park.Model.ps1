# Persistent workstation observations. A failed check never erases the last known user.
function Expand-DomeniaParkPrevious {
    # Called only when a bounded worker slot is available, never for the whole fleet.
    param($Target)
    $json=[string](Get-DomeniaMemberValue $Target 'PreviousJson')
    if(-not $json){return}
    try{
        $previous=$json|ConvertFrom-Json -ErrorAction Stop
        if([string]$previous.Key -ine [string]$Target.Key -or [string]$previous.Guid -ine [string]$Target.Guid){throw 'Identite du cache differente.'}
        $previous|Add-Member -NotePropertyName DirectoryChanged -NotePropertyValue ([bool](Get-DomeniaMemberValue $Target 'DirectoryChanged')) -Force
        $Target.Previous=$previous
    }finally{$Target.PreviousJson=''}
}
function Clear-DomeniaParkTargetBuffers {
    param([object[]]$Targets)
    foreach($target in $Targets){
        if($null -eq $target){continue}
        $target.Previous=$null
        if($null -ne $target.PSObject.Properties['PreviousJson']){$target.PreviousJson=''}
    }
}

function ConvertTo-DomeniaParkSession {
    param($Result,$Previous,[string]$NowUtc=([datetime]::UtcNow.ToString('o')))
    if($null -ne $Previous -and ([string]$Previous.Key -ine [string]$Result.Key -or [string]$Previous.Guid -ine [string]$Result.Guid)){$Previous=$null}
    $record=[ordered]@{Version=1;Key=[string]$Result.Key;Guid=[string]$Result.Guid;Computer=[string]$Result.Computer;CheckedUtc=$NowUtc;Outcome=[string]$Result.Outcome;Presence=[string]$Result.Presence;Detail=[string]$Result.Detail;RawAccount='';LinkUser='';UserDn='';UserGuid='';UserUsn='';ObservedUtc='';IdentityCheckedUtc=''}
    foreach($name in @('RawAccount','LinkUser','UserDn','UserGuid','UserUsn','ObservedUtc','IdentityCheckedUtc')){if($null -ne $Previous){$record[$name]=[string]$Previous.$name}}
    if([string]$Result.Outcome -eq 'NoConsole'){foreach($name in @('RawAccount','LinkUser','UserDn','UserGuid','UserUsn','ObservedUtc','IdentityCheckedUtc')){$record[$name]=''}}
    if([string]$Result.Outcome -eq 'Observed'){
        $record.RawAccount=[string]$Result.User
        foreach($name in @('LinkUser','UserDn','UserGuid','UserUsn','IdentityCheckedUtc')){$record[$name]=[string]$Result.$name}
        # CIM observed the same account now; LDAP reuse does not make that observation older.
        $record.ObservedUtc=$NowUtc
    }
    # Light WMI inventory of a fleet analysis; the previous one is kept when this reading has none.
    $record.Inventory=$null
    if($null -ne $Result.PSObject.Properties['Inventory'] -and $null -ne $Result.Inventory){$record.Inventory=$Result.Inventory}
    elseif($null -ne $Previous -and $null -ne $Previous.PSObject.Properties['Inventory']){$record.Inventory=$Previous.Inventory}
    # Keep the last successful inventory with its original date, and the failed attempt separately.
    $record.InventoryError='';$record.InventoryAttemptUtc=''
    if($null -ne $Previous){$record.InventoryError=[string](Get-DomeniaMemberValue $Previous 'InventoryError');$record.InventoryAttemptUtc=[string](Get-DomeniaMemberValue $Previous 'InventoryAttemptUtc')}
    $inventoryError=[string](Get-DomeniaMemberValue $Result 'InventoryError')
    if($inventoryError){$record.InventoryError=$inventoryError;$record.InventoryAttemptUtc=$NowUtc}
    elseif($null -ne (Get-DomeniaMemberValue $Result 'Inventory')){$record.InventoryError='';$record.InventoryAttemptUtc=$NowUtc}
    if($record.InventoryError){$record.Detail+= ' Dernière lecture dʼinventaire non confirmée ('+$record.InventoryAttemptUtc+') : '+$record.InventoryError+' Les dernières valeurs connues conservent leur date.'}
    # Widget probe results: the latest result of each probe, older probes of this workstation kept.
    $record.Probes=$null;$merged=[ordered]@{}
    if($null -ne $Previous -and $null -ne $Previous.PSObject.Properties['Probes'] -and $null -ne $Previous.Probes){foreach($p in $Previous.Probes.PSObject.Properties){$merged[$p.Name]=$p.Value}}
    if($null -ne $Result.PSObject.Properties['Probes'] -and $null -ne $Result.Probes){foreach($p in $Result.Probes.PSObject.Properties){$merged[$p.Name]=$p.Value}}
    if($merged.Count){$record.Probes=[pscustomobject]$merged}
    return [pscustomobject]$record
}
function Test-DomeniaParkLinkChanged {
    param($Observation,$Existing)
    if($Observation.Outcome -ne 'Observed' -or -not $Observation.LinkUser -or -not $Observation.UserDn -or -not $Observation.UserGuid){return $false}
    if($null -eq $Existing){return $true}
    if(Test-DomeniaProtectedAssociationSource ([string]$Existing.Source)){return $false}
    return ([string]$Existing.UserLogin -ine [string]$Observation.LinkUser -or [string]$Existing.UserGuid -ine [string]$Observation.UserGuid -or [string]$Existing.ComputerGuid -ine [string]$Observation.Guid)
}

function New-DomeniaCollectionPlan {
    # Reuse only measurements of this object identity, each with its own timestamp. Errors are always retried.
    param($Previous,[string]$Guid,[string]$Key,[object[]]$Probes=@(),[bool]$Inventory=$false,[int]$CacheMinutes=15,[datetime]$NowUtc=[datetime]::UtcNow)
    $valid=($null -ne $Previous -and $Guid -and [string]$Previous.Guid -ieq $Guid -and [string]$Previous.Key -ieq $Key)
    $minutes=[Math]::Max(0,[Math]::Min(1440,$CacheMinutes));$reuse=0;$readInventory=$Inventory
    $fresh={param($Value,[int]$Seconds)
        if($null -eq $Value -or $Seconds -le 0 -or [string](Get-DomeniaMember $Value 'Error') -or [string](Get-DomeniaMember $Value 'Skipped') -or [bool](Get-DomeniaMember $Value 'Truncated' $false)){return $false}
        $at=ConvertFrom-DomeniaUtcText ([string](Get-DomeniaMember $Value 'CheckedUtc'))
        return ($null -ne $at -and $at -le $NowUtc.AddMinutes(1) -and ($NowUtc-$at).TotalSeconds -lt $Seconds)
    }
    if($valid -and $Inventory -and -not [string](Get-DomeniaMemberValue $Previous 'InventoryError') -and (& $fresh (Get-DomeniaMemberValue $Previous 'Inventory') ([Math]::Min(300,$minutes*60)))){$readInventory=$false;$reuse++}
    $planned=[Collections.Generic.List[object]]::new();$seen=@{}
    foreach($probe in @($Probes)){
        if($null -eq $probe -or -not [string]$probe.Id -or $seen.ContainsKey([string]$probe.Id)){continue};$seen[[string]$probe.Id]=$true
        $seconds=$minutes*60
        # CPU, battery, memory, services, network and events vary quickly. Static inventory can live longer.
        if([string]$probe.Id -match '^(evt\.|svc\.|net\.)|load|battery|free|users|stopped|process'){$seconds=[Math]::Min(60,$seconds)}
        $previousProbe=if($valid){Get-DomeniaMemberValue (Get-DomeniaMemberValue $Previous 'Probes') ([string]$probe.Id)}else{$null}
        if(& $fresh $previousProbe $seconds){$reuse++;continue}
        $planned.Add($probe)
    }
    return [pscustomobject]@{Inventory=$readInventory;Probes=$planned.ToArray();Reused=$reuse;Requested=($seen.Count+$(if($Inventory){1}else{0}));CacheMinutes=$minutes}
}
