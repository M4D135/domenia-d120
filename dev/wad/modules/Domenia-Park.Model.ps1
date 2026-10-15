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

# ---------------------------------------------------------------- X01: surveys of the displayed list (pure rules)
function Get-DomeniaParkPlural {
    param([int]$Count,[string]$One,[string]$Many)
    if ($Count -gt 1) { return $Many }
    return $One
}
function Test-DomeniaParkTargetAdmission {
    # SE-05: guard of a survey of the displayed list or of its selection, never a disguised whole-domain survey.
    # Refused above the ceiling (Park.MaxTargets, 500 by default), for a list of the domain root without any other
    # filter, and for a global search without a term. A selection that leaves rows of the list out is its own filter
    # (ceiling only); a selection of every displayed workstation (-SelectionCoversList, Ctrl+A) is the list itself and
    # follows the rules of the list.
    param([int]$Count,[int]$Maximum=500,[AllowEmptyString()][string]$ScopeDn='',[AllowEmptyString()][string]$BaseDn='',[bool]$HasFilter=$false,[bool]$Global=$false,[bool]$HasSearchTerm=$false,[bool]$Selection=$false,[bool]$SelectionCoversList=$false)
    $max = $Maximum
    if ($max -lt 1) { $max = 500 }
    $max = [Math]::Min(5000,$max)
    $refuse = { param([string]$Code,[string]$Reason) [pscustomobject]@{Allowed=$false;Code=$Code;Reason=$Reason;Maximum=$max} }
    if ($Count -le 0) {
        if ($Selection) { return (& $refuse 'Empty' 'Aucun poste dans la sélection.') }
        return (& $refuse 'Empty' 'Aucun poste dans les résultats affichés.')
    }
    if ($Count -gt $max) {
        if ($Selection) { return (& $refuse 'Ceiling' ([string]$Count + ' postes sélectionnés : plafond ' + [string]$max + '. Réduisez la sélection.')) }
        return (& $refuse 'Ceiling' ([string]$Count + ' postes affichés : plafond ' + [string]$max + '. Filtrez la liste.'))
    }
    if ((-not $Selection) -or $SelectionCoversList) {
        $whole = ''
        if ($Selection) { $whole = 'Toute la liste est sélectionnée. ' }
        if ($Global -and (-not $HasSearchTerm)) { return (& $refuse 'GlobalWithoutTerm' ($whole + 'Recherche globale sans terme : aucun relevé de tout le domaine. Saisissez un nom ou choisissez une OU.')) }
        $scope = ([string]$ScopeDn).Trim(); $base = ([string]$BaseDn).Trim()
        if ((-not $Global) -and $base -and ($scope -ieq $base) -and (-not $HasFilter)) { return (& $refuse 'DomainRoot' ($whole + 'Liste de la racine du domaine sans autre filtre : aucun relevé de tout le domaine. Choisissez une OU ou filtrez la liste.')) }
    }
    return [pscustomobject]@{Allowed=$true;Code='Allowed';Reason='';Maximum=$max}
}
function Get-DomeniaParkOutcomeKind {
    # CO-19: class of a committed presence for the counters of a survey: Online, NoReply or Error (DNS failure, worker
    # failure, no measure). A WMI-only survey sends no echo: its presence is an older value and is not counted ('').
    param([AllowEmptyString()][string]$Presence,[bool]$PingRequested=$true)
    if (-not $PingRequested) { return '' }
    switch (ConvertTo-DomeniaPresenceStateKey $Presence) {
        'Online' { return 'Online' }
        'NoReply' { return 'NoReply' }
        default { return 'Error' }
    }
}
function Get-DomeniaParkProgressText {
    # UX-12 / CO-19: short state of a survey beside its thin bar: '12/48 · 9 joignables' while it runs, then
    # '48/48 · 30 en ligne · 15 sans réponse · 3 erreurs'. A WMI-only survey counts readings, not echoes.
    param([int]$Done,[int]$Total,[int]$Online=0,[int]$NoReply=0,[int]$Errors=0,[int]$Failed=0,[int]$Unchecked=0,[bool]$PingRequested=$true,[bool]$Completed=$false,[bool]$Stopped=$false)
    $text = [string]$Done + '/' + [string]$Total
    if (-not $PingRequested) {
        $text += ' ' + (Get-DomeniaParkPlural $Done 'poste lu' 'postes lus')
    }
    elseif (-not $Completed) {
        $text += ' · ' + [string]$Online + ' ' + (Get-DomeniaParkPlural $Online 'joignable' 'joignables')
    }
    else {
        $text += ' · ' + [string]$Online + ' en ligne · ' + [string]$NoReply + ' sans réponse · ' + [string]$Errors + ' ' + (Get-DomeniaParkPlural $Errors 'erreur' 'erreurs')
    }
    if ($Failed -gt 0) { $text += ' · ' + [string]$Failed + ' ' + (Get-DomeniaParkPlural $Failed 'lecture non confirmée' 'lectures non confirmées') }
    if ($Unchecked -gt 0) { $text += ' · ' + [string]$Unchecked + ' ' + (Get-DomeniaParkPlural $Unchecked 'poste non vérifié' 'postes non vérifiés') }
    if ($Completed -and $Stopped) { $text = 'Arrêté à ' + $text }
    return $text
}
function Get-DomeniaParkDurationEstimate {
    # UX-24: plausible upper duration of a survey in seconds. An unreachable workstation waits for its delay: echoes
    # go by batches of 32 (about 2 s each with the name resolution and the storage), a console read takes about 4 s,
    # the light inventory about 4 s more and each widget query about 2 s, several workstations at a time.
    param([int]$Count,[bool]$PingOnly=$false,[bool]$WmiOnly=$false,[bool]$Inventory=$false,[int]$ProbeCount=0,[int]$Concurrency=4,[int]$PingBatch=32)
    $n = [Math]::Max(0,$Count)
    if ($n -eq 0) { return 0 }
    if ($PingOnly) { return [int]([Math]::Ceiling($n / [double][Math]::Max(1,$PingBatch)) * 2) }
    $per = 4.0
    if ($WmiOnly) { $per = 3.0 }
    if ($Inventory) { $per += 4.0 }
    $per += 2.0 * [Math]::Max(0,[Math]::Min(20,$ProbeCount))
    $parallel = [Math]::Max(1,[Math]::Min(8,$Concurrency))
    return [int][Math]::Ceiling([Math]::Ceiling($n / [double]$parallel) * $per)
}
function Get-DomeniaParkPingTimeoutSeconds {
    # MO-08: engine budget of one ParkPing job, from the waits of its own worker: per batch of echoes, at most 2.5 s of
    # name resolution plus the echo delay and 1 s of margin, plus 1 s of PowerShell work, and 20 s to start and end.
    # Bounded to 30 minutes; the ceiling of a list (5000 workstations at most) stays well under it.
    param([int]$Count,[int]$TimeoutMs=1000,[int]$BatchSize=32)
    $delay = [Math]::Max(250,[Math]::Min(3000,$TimeoutMs))
    $batch = [Math]::Max(1,[Math]::Min(64,$BatchSize))
    $batches = [Math]::Ceiling([Math]::Max(0,$Count) / [double]$batch)
    $perBatch = [Math]::Ceiling((2500 + $delay + 1000) / 1000.0) + 1
    return [int][Math]::Min(1800,20 + $perBatch * $batches)
}
function Format-DomeniaParkDuration {
    param([int]$Seconds)
    if ($Seconds -lt 60) { return 'moins dʼune minute' }
    if ($Seconds -lt 3600) { return 'environ ' + [string][int][Math]::Ceiling($Seconds / 60.0) + ' min' }
    return 'environ ' + ([Math]::Round($Seconds / 3600.0,1)).ToString('0.#',[Globalization.CultureInfo]::GetCultureInfo('fr-FR')) + ' h'
}
function New-DomeniaParkConfirmationText {
    # UX-24: three short lines: which workstations (and why the count differs from the list), what is read, how
    # long. The target names the list, the selection or the OU, never the domain. The confirm button carries the
    # count ('Pinger 48 postes').
    param(
        [int]$Count,[int]$Skipped=0,[int]$Ignored=0,[ValidateSet('Results','Selection','Scope')][string]$ScopeKind='Results',
        [AllowEmptyString()][string]$ScopeLabel='',[bool]$Subtree=$false,[int]$ListLimit=0,
        [bool]$PingOnly=$false,[bool]$WmiOnly=$false,[bool]$Inventory=$false,[int]$ProbeCount=0,[int]$Concurrency=4,[int]$CacheMinutes=15
    )
    $postes = [string]$Count + ' ' + (Get-DomeniaParkPlural $Count 'poste' 'postes')
    switch ($ScopeKind) {
        'Selection' { $line1 = $postes + ' ' + (Get-DomeniaParkPlural $Count 'sélectionné' 'sélectionnés') }
        'Scope' { $line1 = $postes + $(if ($ScopeLabel) { ' de ' + $ScopeLabel } else { ' du périmètre choisi' }) }
        default {
            $line1 = $postes + ' ' + (Get-DomeniaParkPlural $Count 'affiché' 'affichés')
            if ($ScopeLabel) { $line1 += ' (' + $ScopeLabel + $(if ($Subtree) { ', sous-OU' } else { '' }) + ')' }
        }
    }
    if ($Skipped -gt 0) { $line1 += ' · ' + [string]$Skipped + ' ' + (Get-DomeniaParkPlural $Skipped 'ligne sans identifiant AD ignorée' 'lignes sans identifiant AD ignorées') }
    if ($Ignored -gt 0) { $line1 += ' · ' + [string]$Ignored + ' ' + (Get-DomeniaParkPlural $Ignored 'poste au nom inutilisable ou en double ignoré' 'postes au nom inutilisable ou en double ignorés') }
    if ($ListLimit -gt 0) { $line1 += ' · liste limitée à ' + [string]$ListLimit + ' lignes : les autres postes ne sont pas concernés' }
    $read = New-Object 'System.Collections.Generic.List[string]'
    if (-not $WmiOnly) { $read.Add('présence') }
    if (-not $PingOnly) { $read.Add('utilisateur connecté') }
    if ($Inventory -and (-not $PingOnly)) { $read.Add('matériel') }
    if (($ProbeCount -gt 0) -and (-not $PingOnly)) { $read.Add([string]$ProbeCount + ' ' + (Get-DomeniaParkPlural $ProbeCount 'requête des widgets' 'requêtes des widgets')) }
    $line2 = 'Ce qui sera lu : ' + ($read.ToArray() -join ' · ') + ', en lecture seule.'
    $parallel = [Math]::Max(1,[Math]::Min(8,$Concurrency))
    $seconds = Get-DomeniaParkDurationEstimate -Count $Count -PingOnly $PingOnly -WmiOnly $WmiOnly -Inventory $Inventory -ProbeCount $ProbeCount -Concurrency $parallel
    $line3 = 'Durée estimée : ' + (Format-DomeniaParkDuration $seconds)
    if ($PingOnly) { $line3 += ', échos envoyés par lots de 32' } else { $line3 += ', ' + [string]$parallel + ' ' + (Get-DomeniaParkPlural $parallel 'poste' 'postes') + ' à la fois' }
    $line3 += ' ; arrêt possible à tout moment.'
    if ((-not $PingOnly) -and ($CacheMinutes -gt 0)) { $line3 += ' Mesures de moins de ' + [string]$CacheMinutes + ' min réutilisées.' }
    $verb = 'Vérifier'; $mode = 'qui est connecté ?'
    if ($PingOnly) { $verb = 'Pinger'; $mode = 'qui répond ?' }
    elseif ($Inventory -or ($ProbeCount -gt 0)) { $verb = 'Analyser'; $mode = 'matériel et widgets' }
    elseif ($WmiOnly) { $verb = 'Lire'; $mode = 'lecture WMI' }
    $title = switch ($ScopeKind) { 'Selection' { 'Vérifier la sélection : ' + $mode } 'Scope' { 'Relevé des postes : ' + $mode } default { 'Vérifier la liste : ' + $mode } }
    $target = 'les résultats affichés'
    if ($ScopeKind -eq 'Selection') { $target = 'la sélection' } elseif ($ScopeLabel) { $target = $ScopeLabel }
    return [pscustomobject]@{Title=$title;Target=$target;Lines=@($line1,$line2,$line3);Message=($line1 + "`r`n" + $line2 + "`r`n" + $line3);ConfirmText=($verb + ' ' + $postes);EstimateSeconds=$seconds}
}
function Get-DomeniaParkRunSlot {
    # FI-18: one survey per scope. 'Computer' for the single workstation open in the Poste page (queries of its
    # board); 'List' for the displayed list of Rechercher, its selection and the perimeter surveys (OU, board, query).
    param([AllowEmptyString()][string]$Slot='',[bool]$DisplayedResults=$false,[object[]]$Targets=@(),[AllowEmptyString()][string]$OpenComputerDn='')
    if ($Slot -in @('List','Computer')) { return $Slot }
    if ($DisplayedResults) { return 'List' }
    $list = @(@($Targets) | Where-Object { $null -ne $_ })
    if (($list.Count -eq 1) -and $OpenComputerDn -and ([string](Get-DomeniaMemberValue $list[0] 'distinguished_name') -ieq $OpenComputerDn)) { return 'Computer' }
    return 'List'
}
function Get-DomeniaParkVerifyModes {
    # UI-23: the graduated readings behind « Vérifier la liste ▾ », from the lightest to the most complete.
    return @(
        [pscustomobject]@{Mode='Ping';Label='Qui répond ?';Detail='Un ping par poste, échos envoyés en parallèle. Aucune lecture de session.'}
        [pscustomobject]@{Mode='Console';Label='Qui est connecté ?';Detail='Ping puis utilisateur connecté à la console (CIM), quatre postes à la fois.'}
        [pscustomobject]@{Mode='Analyse';Label='Matériel et widgets';Detail='Ping, utilisateur connecté, relevé WMI léger et requêtes des widgets des tableaux de bord.'}
    )
}

