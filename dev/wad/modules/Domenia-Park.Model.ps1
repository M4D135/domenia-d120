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
        if([string](Get-DomeniaMemberValue $probe 'DefinitionHash') -and [string](Get-DomeniaMemberValue $previousProbe 'DefinitionHash') -ceq [string](Get-DomeniaMemberValue $probe 'DefinitionHash') -and (& $fresh $previousProbe $seconds)){$reuse++;continue}
        $planned.Add($probe)
    }
    return [pscustomobject]@{Inventory=$readInventory;Probes=$planned.ToArray();Reused=$reuse;Requested=($seen.Count+$(if($Inventory){1}else{0}));CacheMinutes=$minutes}
}

function ConvertTo-DomeniaRemoteObservationChanges {
    # Only source-stamped fields actually collected are admitted. No callback timestamp becomes freshness.
    param($Result,[string]$Guid,[string]$DN)
    $identity=[guid]::Empty
    if(-not [guid]::TryParse($Guid,[ref]$identity) -or $identity -eq [guid]::Empty -or -not $DN){throw 'Identite distante incomplete.'}
    if([string](Get-DomeniaMemberValue $Result 'Guid') -ine $Guid -or [string](Get-DomeniaMemberValue $Result 'Key') -ine $DN){throw 'Resultat distant hors de sa cible.'}
    $changes=[Collections.Generic.List[object]]::new()
    $make={param([string]$Family,[string]$At,[bool]$Success,[string]$ErrorText,$Data,[string]$DefinitionHash='')
        $parsed=[datetimeoffset]::MinValue
        if(-not [datetimeoffset]::TryParse($At,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$parsed)){throw ('Date de collecte absente pour '+$Family)}
        $utc=$parsed.ToUniversalTime().ToString('o')
        [pscustomobject]@{Kind='Observation';Guid=$identity.ToString('D');DN=$DN;Family=$Family;AttemptedAtUtc=$utc;ObservedAtUtc=$(if($Success){$utc}else{''});Status=$(if($Success){'Success'}else{'Error'});Error=$ErrorText;Data=$Data;DefinitionHash=$DefinitionHash}
    }
    $computer=[string](Get-DomeniaMemberValue $Result 'Computer')
    $pingAt=[string](Get-DomeniaMemberValue $Result 'PresenceCheckedUtc')
    if($pingAt){
        $presence=[string](Get-DomeniaMemberValue $Result 'Presence');$detail=[string](Get-DomeniaMemberValue $Result 'PresenceDetail')
        $success=$presence -in @('En ligne','Sans réponse au ping')
        $changes.Add((& $make 'Presence' $pingAt $success $(if($success){''}else{$detail}) ([pscustomobject]@{Computer=$computer;Presence=$presence;PresenceDetail=$detail;PresenceCheckedUtc=$pingAt})))
    }
    $consoleAt=[string](Get-DomeniaMemberValue $Result 'ConsoleCheckedUtc')
    if($consoleAt -and [bool](Get-DomeniaMemberValue $Result 'ConsoleAttempted')){
        $outcome=[string](Get-DomeniaMemberValue $Result 'Outcome');$success=$outcome -in @('Observed','NoConsole')
        $data=[ordered]@{Computer=$computer;Outcome=$outcome;CheckedUtc=$consoleAt;UserCheckedUtc=$consoleAt;ObservedUtc=$(if($outcome -eq 'Observed'){$consoleAt}else{''});CurrentUser='';LastUser='';RawAccount=''}
        foreach($name in @('User','LinkUser','UserGuid','UserDn','UserUsn','IdentityCheckedUtc','Detail','Source')){$data[$name]=[string](Get-DomeniaMemberValue $Result $name)}
        if($outcome -eq 'Observed'){$data.CurrentUser=$data.User;$data.LastUser=$data.User;$data.RawAccount=$data.User}
        $data.DirectoryAuthRejected=[bool](Get-DomeniaMemberValue $Result 'DirectoryAuthRejected')
        $changes.Add((& $make 'Console' $consoleAt $success $(if($success){''}else{$data.Detail}) ([pscustomobject]$data)))
    }
    if([bool](Get-DomeniaMemberValue $Result 'InventoryAttempted')){
        $inventory=Get-DomeniaMemberValue $Result 'Inventory';$errorText=[string](Get-DomeniaMemberValue $Result 'InventoryError')
        $at=[string](Get-DomeniaMemberValue $Result 'InventoryCheckedUtc');if(-not $at){$at=[string](Get-DomeniaMemberValue $inventory 'CheckedUtc')}
        $success=($null -ne $inventory -and -not $errorText)
        $changes.Add((& $make 'Inventory' $at $success $errorText ([pscustomobject]@{Computer=$computer;Inventory=$inventory;InventoryError=$errorText;InventoryAttemptUtc=$at})))
    }
    $probes=Get-DomeniaMemberValue $Result 'Probes'
    $probeNames=if($probes -is [Collections.IDictionary]){@($probes.Keys)}elseif($null -ne $probes){@($probes.PSObject.Properties.Name)}else{@()}
    foreach($probeId in $probeNames){
        if([string]$probeId -notmatch '^[A-Za-z0-9_.-]{1,128}$'){throw 'Identifiant de sonde invalide.'}
        $entry=Get-DomeniaMemberValue $probes ([string]$probeId);$errorText=[string](Get-DomeniaMemberValue $entry 'Error')
        if([bool](Get-DomeniaMemberValue $entry 'Truncated') -and -not $errorText -and -not ([string](Get-DomeniaMemberValue $entry 'Mode') -ceq 'Count' -and [bool](Get-DomeniaMemberValue $entry 'CountComplete'))){$errorText='Lecture partielle : details incomplets ('+[string](Get-DomeniaMemberValue $entry 'LimitReason')+').'}
        if([string](Get-DomeniaMemberValue $entry 'Skipped') -and -not $errorText){$errorText='Sonde non applicable au systeme.'}
        $map=[ordered]@{};$map[[string]$probeId]=$entry
        $changes.Add((& $make ('Probe:'+[string]$probeId) ([string](Get-DomeniaMemberValue $entry 'CheckedUtc')) (-not $errorText) $errorText ([pscustomobject]@{Computer=$computer;Probes=[pscustomobject]$map}) ([string](Get-DomeniaMemberValue $entry 'DefinitionHash'))))
    }
    if(-not $changes.Count){throw 'Aucune mesure datee a enregistrer.'}
    return $changes.ToArray()
}

function Test-DomeniaRemoteStoreContext {
    param($State,$Result)
    if([bool](Get-DomeniaMemberValue $State 'SuppressPublish')){return $false}
    $context=Get-DomeniaMemberValue $State 'StoreContext'
    if($null -eq $context -or [long]$context.SessionEpoch -ne [long]$script:SessionEpoch -or [string]$context.Path -cne [string]$script:DatabaseScopedPath){return $false}
    if([string]$context.DomainDn -ine ([string]$script:Conn.BaseDn).Trim()){return $false}
    if([long](Get-DomeniaMemberValue $State 'AccountGeneration') -ne [long]$script:DomeniaAccountGeneration){return $false}
    if($null -ne $Result){
        if(-not [bool]$Result.Saved -or [string]$Result.DataSource -cne 'SQLite' -or [string]$Result.StoreId -cne [string]$context.StoreId -or [string]$Result.RequestId -cne [string]$context.RequestId){return $false}
    }
    return $true
}

function Add-DomeniaRemoteProbeDefinitionHash {
    param([object[]]$Probes)
    foreach($probe in @($Probes)){
        if($null -eq $probe){continue}
        $definition=[ordered]@{}
        foreach($name in @('Id','Namespace','Class','Properties','Filter','Mode','Skip')){$definition[$name]=Get-DomeniaMemberValue $probe $name}
        $copy=($probe|ConvertTo-Json -Depth 8 -Compress)|ConvertFrom-Json -ErrorAction Stop
        $copy|Add-Member -NotePropertyName DefinitionHash -NotePropertyValue (Get-DomeniaStoreHash ($definition|ConvertTo-Json -Depth 8 -Compress)) -Force
        $copy
    }
}
