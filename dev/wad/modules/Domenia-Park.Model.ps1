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

function Test-DomeniaProbeNotApplicable {
    # A probe skipped as not applicable to the system (a domain controller, for instance). In memory it carries
    # Skipped; once stored, ConvertTo-DomeniaRemoteObservationChanges turns it into an error with the text below and
    # no success date. SummaryUnavailable marks a stored measurement whose summary was too large, never a skip.
    param($Value)
    if($null -eq $Value){return $false}
    $errorText=[string](Get-DomeniaMember $Value 'Error' '')
    if($errorText){return ($errorText -ceq 'Sonde non applicable au systeme.')}
    $skipped=[string](Get-DomeniaMember $Value 'Skipped' '')
    return (([bool]$skipped) -and ($skipped -cne 'SummaryUnavailable'))
}
function Get-DomeniaProbeAnswerUtc {
    # Date at which a stored probe result answers its workstation, '' when it does not: a success by its CheckedUtc,
    # a probe not applicable to the system by its attempt (its success date stays empty once stored). Any other
    # error and a partial read never answer.
    param($Value)
    if(($null -eq $Value) -or ([bool](Get-DomeniaMember $Value 'Truncated' $false))){return ''}
    if(Test-DomeniaProbeNotApplicable -Value $Value){
        $attempt=[string](Get-DomeniaMember $Value 'AttemptedUtc' '')
        if($attempt){return $attempt}
        return [string](Get-DomeniaMember $Value 'CheckedUtc' '')
    }
    if([string](Get-DomeniaMember $Value 'Error' '')){return ''}
    return [string](Get-DomeniaMember $Value 'CheckedUtc' '')
}
function New-DomeniaCollectionPlan {
    # Reuse only measurements of this object identity, each with its own timestamp. Errors are always retried.
    # Point 11: $Freshness is the resolved table of the usage profile (Inventory, StaticProbe, VolatileProbe in
    # seconds). The duration kept is the shortest of the family and of CacheMinutes; 0 forces a new read.
    # -ReuseMaxAgeDays (widget collections, decision David 2026-10-14): collect only what is missing, i.e. also reuse a
    # usable measurement younger than that many days whatever the cache minutes; a probe stored as not applicable to
    # the system is an answer there, dated by its attempt (Get-DomeniaProbeAnswerUtc). 0 keeps the cache-minute rule
    # alone; a forced refresh passes CacheMinutes 0 and no reuse age.
    param($Previous,[string]$Guid,[string]$Key,[object[]]$Probes=@(),[bool]$Inventory=$false,[int]$CacheMinutes=15,[datetime]$NowUtc=[datetime]::UtcNow,$Freshness=$null,[int]$ReuseMaxAgeDays=0)
    $valid=($null -ne $Previous -and $Guid -and [string]$Previous.Guid -ieq $Guid -and [string]$Previous.Key -ieq $Key)
    $minutes=[Math]::Max(0,[Math]::Min(1440,$CacheMinutes));$reuse=0;$readInventory=$Inventory
    $familySeconds={param([string]$Family,[int]$Default)
        $value=$Default;$table=Get-DomeniaMember $Freshness 'Seconds' $Freshness
        if(($table -is [Collections.IDictionary]) -and $table.Contains($Family)){$value=[int]$table[$Family]}
        return [int][Math]::Max(0,[Math]::Min([double]$value,[double]($minutes*60)))
    }
    $reuseDays=[Math]::Max(0,[Math]::Min(3650,$ReuseMaxAgeDays))
    $fresh={param($Value,[int]$Seconds)
        if($null -eq $Value -or $Seconds -le 0 -or [string](Get-DomeniaMember $Value 'Error') -or [string](Get-DomeniaMember $Value 'Skipped') -or [bool](Get-DomeniaMember $Value 'Truncated' $false)){return $false}
        $at=ConvertFrom-DomeniaUtcText ([string](Get-DomeniaMember $Value 'CheckedUtc'))
        return ($null -ne $at -and $at -le $NowUtc.AddMinutes(1) -and ($NowUtc-$at).TotalSeconds -lt $Seconds)
    }
    $usable={param($Value,[bool]$IsProbe)
        if(($reuseDays -le 0) -or ($null -eq $Value)){return $false}
        $stamp=''
        if($IsProbe){$stamp=Get-DomeniaProbeAnswerUtc -Value $Value}
        elseif((-not [string](Get-DomeniaMember $Value 'Error')) -and (-not [bool](Get-DomeniaMember $Value 'Truncated' $false))){$stamp=[string](Get-DomeniaMember $Value 'CheckedUtc')}
        $at=ConvertFrom-DomeniaUtcText $stamp
        return (($null -ne $at) -and ($at -le $NowUtc.AddMinutes(1)) -and (($NowUtc-$at).TotalDays -lt $reuseDays))
    }
    if(($valid) -and ($Inventory) -and (-not [string](Get-DomeniaMemberValue $Previous 'InventoryError'))){
        $previousInventory=Get-DomeniaMemberValue $Previous 'Inventory'
        if((& $fresh $previousInventory (& $familySeconds 'Inventory' 300)) -or (& $usable $previousInventory $false)){$readInventory=$false;$reuse++}
    }
    $planned=[Collections.Generic.List[object]]::new();$seen=@{}
    foreach($probe in @($Probes)){
        if($null -eq $probe -or -not [string]$probe.Id -or $seen.ContainsKey([string]$probe.Id)){continue};$seen[[string]$probe.Id]=$true
        $seconds=& $familySeconds 'StaticProbe' ($minutes*60)
        # CPU, battery, memory, services, network and events vary quickly. Static inventory can live longer.
        if([string]$probe.Id -match '^(evt\.|svc\.|net\.)|load|battery|free|users|stopped|process'){$seconds=& $familySeconds 'VolatileProbe' 60}
        $previousProbe=if($valid){Get-DomeniaMemberValue (Get-DomeniaMemberValue $Previous 'Probes') ([string]$probe.Id)}else{$null}
        $hash=[string](Get-DomeniaMemberValue $probe 'DefinitionHash');$previousHash=[string](Get-DomeniaMemberValue $previousProbe 'DefinitionHash')
        $sameDefinition=(([bool]$hash) -and ($previousHash -ceq $hash))
        # A probe that never succeeded is stored without its definition hash: its not-applicable answer is then dated
        # by the attempt alone (widget collections only; a forced refresh reads it again).
        $notApplicable=((-not $previousHash) -and (Test-DomeniaProbeNotApplicable -Value $previousProbe) -and (& $usable $previousProbe $true))
        if((($sameDefinition) -and ((& $fresh $previousProbe $seconds) -or (& $usable $previousProbe $true))) -or ($notApplicable)){$reuse++;continue}
        $planned.Add($probe)
    }
    return [pscustomobject]@{Inventory=$readInventory;Probes=$planned.ToArray();Reused=$reuse;Requested=($seen.Count+$(if($Inventory){1}else{0}));CacheMinutes=$minutes}
}
function Test-DomeniaParkTargetAnswered {
    # Widget collections (decision David 2026-10-14, collect only what is missing): the stored observation of this
    # identity already answers everything the run would read from the workstation, so it is not contacted at all.
    # Plan: New-DomeniaCollectionPlan of the target (nothing left for the light inventory nor the probes). -Ping and
    # -Console: the run also reads the presence or the console user, answered by a successful check younger than
    # ReuseMaxAgeDays of this identity. Never true without a reuse age (refresh, Analyser la liste).
    param($Previous,[string]$Guid,[string]$Key,$Plan,[bool]$Ping=$false,[bool]$Console=$false,[int]$ReuseMaxAgeDays=0,[datetime]$NowUtc=[datetime]::UtcNow)
    if(($ReuseMaxAgeDays -le 0) -or ($null -eq $Plan)){return $false}
    if(([bool]$Plan.Inventory) -or (@($Plan.Probes).Count -gt 0)){return $false}
    if((-not $Ping) -and (-not $Console)){return $true}
    $valid=(($null -ne $Previous) -and ([bool]$Guid) -and ([string]$Previous.Guid -ieq $Guid) -and ([string]$Previous.Key -ieq $Key))
    if(-not $valid){return $false}
    $days=[Math]::Min(3650,$ReuseMaxAgeDays)
    $recent={param([string]$Text)
        $at=ConvertFrom-DomeniaUtcText $Text
        return (($null -ne $at) -and ($at -le $NowUtc.AddMinutes(1)) -and (($NowUtc-$at).TotalDays -lt $days))
    }
    if(($Ping) -and (-not (& $recent ([string](Get-DomeniaMember $Previous 'PresenceCheckedUtc' ''))))){return $false}
    if($Console){
        $at='';foreach($name in @('UserCheckedUtc','ConsoleCheckedUtc','ObservedUtc')){$at=[string](Get-DomeniaMember $Previous $name '');if($at){break}}
        if(-not (& $recent $at)){return $false}
    }
    return $true
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
    # Widget collections (decision David 2026-10-14): -Widget names the collection of one widget ('Collecter 12
    # postes'), -NoConsole leaves the console user out of what is read, -ReuseMaxAgeDays says that only missing,
    # failed or older measurements are read, -AlreadyFresh counts the workstations set aside before any read and
    # -DirectLimit says why an added widget asks for its count above its direct limit.
    # Collection engine (points 11, 13, 14, 15 and 18): -ProfileLabel names the usage profile whose durations decide
    # what is reused, -CimRequested/-CimExecuted give the WMI queries of one workstation before and after grouping, and
    # -SourceBudgets says that the workstations of one presumed subnet share a budget (and, for reads other than the
    # ping, that a transient incident is read again at most twice).
    param(
        [int]$Count,[int]$Skipped=0,[int]$Ignored=0,[ValidateSet('Results','Selection','Scope')][string]$ScopeKind='Results',
        [AllowEmptyString()][string]$ScopeLabel='',[bool]$Subtree=$false,[int]$ListLimit=0,
        [bool]$PingOnly=$false,[bool]$WmiOnly=$false,[bool]$Inventory=$false,[int]$ProbeCount=0,[int]$Concurrency=4,[int]$CacheMinutes=15,
        [bool]$NoConsole=$false,[int]$ReuseMaxAgeDays=0,[int]$AlreadyFresh=0,[bool]$Widget=$false,[int]$DirectLimit=0,
        [AllowEmptyString()][string]$ProfileLabel='',[int]$CimRequested=0,[int]$CimExecuted=0,[bool]$SourceBudgets=$false
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
    if ($AlreadyFresh -gt 0) { $line1 += ' · ' + [string]$AlreadyFresh + ' ' + (Get-DomeniaParkPlural $AlreadyFresh 'poste déjà à jour, non contacté' 'postes déjà à jour, non contactés') }
    if (($DirectLimit -gt 0) -and ($Count -gt $DirectLimit)) { $line1 += ' · plus de ' + [string]$DirectLimit + ' postes à lire : nombre confirmé avant toute lecture' }
    $read = New-Object 'System.Collections.Generic.List[string]'
    if (-not $WmiOnly) { $read.Add('présence') }
    if ((-not $PingOnly) -and (-not $NoConsole)) { $read.Add('utilisateur connecté') }
    if ($Inventory -and (-not $PingOnly)) { $read.Add('matériel') }
    if (($ProbeCount -gt 0) -and (-not $PingOnly)) {
        if ($Widget) { $read.Add([string]$ProbeCount + ' ' + (Get-DomeniaParkPlural $ProbeCount 'requête du widget' 'requêtes du widget')) }
        else { $read.Add([string]$ProbeCount + ' ' + (Get-DomeniaParkPlural $ProbeCount 'requête des widgets' 'requêtes des widgets')) }
    }
    $line2 = 'Ce qui sera lu : ' + ($read.ToArray() -join ' · ') + ', en lecture seule.'
    if ((-not $PingOnly) -and ($CimExecuted -gt 0) -and ($CimRequested -gt $CimExecuted)) { $line2 += ' Requêtes WMI prévues par poste : ' + [string]$CimExecuted + ' au lieu de ' + [string]$CimRequested + ' grâce au regroupement.' }
    $parallel = [Math]::Max(1,[Math]::Min(8,$Concurrency))
    $seconds = Get-DomeniaParkDurationEstimate -Count $Count -PingOnly $PingOnly -WmiOnly ($WmiOnly -or $NoConsole) -Inventory $Inventory -ProbeCount $ProbeCount -Concurrency $parallel
    $line3 = 'Durée estimée : ' + (Format-DomeniaParkDuration $seconds)
    if ($PingOnly) { $line3 += ', échos envoyés par lots de 32' } else { $line3 += ', ' + [string]$parallel + ' ' + (Get-DomeniaParkPlural $parallel 'poste' 'postes') + ' à la fois' }
    $line3 += ' ; arrêt possible à tout moment.'
    if ($SourceBudgets) {
        $line3 += ' Les postes dʼun même sous-réseau présumé partagent un budget qui ralentit si leurs réponses tardent ; les autres continuent.'
        if (-not $PingOnly) { $line3 += ' Un incident transitoire est relu au plus deux fois, espacé ; aucun nouvel essai après un refus dʼidentifiants.' }
    }
    if ($ReuseMaxAgeDays -gt 0) { $line3 += ' Seules les mesures absentes, en erreur ou de plus de ' + [string]$ReuseMaxAgeDays + ' jours sont relues.' }
    elseif ((-not $PingOnly) -and ($CacheMinutes -gt 0)) {
        if ($ProfileLabel) { $line3 += ' Réutilisation des mesures encore fraîches selon le profil « ' + $ProfileLabel + ' », au plus ' + [string]$CacheMinutes + ' min.' }
        else { $line3 += ' Mesures de moins de ' + [string]$CacheMinutes + ' min réutilisées.' }
    }
    $verb = 'Vérifier'; $mode = 'qui est connecté ?'
    if ($PingOnly) { $verb = 'Pinger'; $mode = 'qui répond ?' }
    elseif ($Inventory -or ($ProbeCount -gt 0)) { $verb = 'Analyser'; $mode = 'matériel et widgets' }
    elseif ($WmiOnly) { $verb = 'Lire'; $mode = 'lecture WMI' }
    $title = switch ($ScopeKind) { 'Selection' { 'Vérifier la sélection : ' + $mode } 'Scope' { 'Relevé des postes : ' + $mode } default { 'Vérifier la liste : ' + $mode } }
    # The collection of one widget reads only what that widget shows: its own title and button.
    if ($Widget) { $verb = 'Collecter'; $title = 'Collecter pour le widget' }
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

