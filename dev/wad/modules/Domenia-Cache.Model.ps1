# Cache and loading rules: projections, cell updates, paging, freshness per nature of data,
# cache keys, incremental synchronisation, negative cache, single writer, retention, offline policy.
# Pure decisions: no SQLite, no LDAP and no file is touched here.

# ---------------------------------------------------------------- D021 minimal projection
function Get-DomeniaProjection {
    # Attributes requested for one purpose. A list never asks for memberships or security descriptors.
    # The detail of one object is read by the fiche with its own explicit list; it is not a projection here,
    # so no kind silently returns an empty list (an empty list would make Get-WAllProperties refuse the read).
    # uSNChanged is part of the list: incremental synchronisation and cache versions need it (D025, D026).
    param([Parameter(Mandatory=$true)][ValidateSet('List','Groups','Security','Presence','Identity')][string]$Kind)
    switch ($Kind) {
        'Identity' { return @('objectGUID','objectSid','distinguishedName','objectClass','name','sAMAccountName') }
        'List'     { return @('objectGUID','objectSid','distinguishedName','objectClass','name','sAMAccountName','userPrincipalName','dNSHostName','displayName','userAccountControl','msDS-User-Account-Control-Computed','lockoutTime','operatingSystem','lastLogonTimestamp','mail','description','whenChanged','uSNChanged','adminCount') }
        'Groups'   { return @('objectGUID','distinguishedName','memberOf','primaryGroupID') }
        'Security' { return @('objectGUID','distinguishedName','nTSecurityDescriptor') }
        default    { return @('objectGUID','distinguishedName','dNSHostName','name') }
    }
}

function Test-DomeniaProjectionMinimal {
    # A list projection must not carry attributes that cost one extra round trip or a large payload per row.
    param([string[]]$Requested)
    $heavy = @('member','memberOf','nTSecurityDescriptor','tokenGroups','tokenGroupsGlobalAndUniversal','thumbnailPhoto','jpegPhoto','msDS-ReplAttributeMetaData','msDS-ReplValueMetaData','userCertificate','msExchMailboxSecurityDescriptor','*')
    $found = @(@($Requested) | Where-Object { $heavy -contains [string]$_ })
    return [pscustomobject]@{Minimal=($found.Count -eq 0);Heavy=$found}
}

# ---------------------------------------------------------------- D022 cell updates
function Get-DomeniaRowUpdatePlan {
    # Compares the rows already shown with an incoming batch. Existing rows are updated cell by cell;
    # the collection is never rebuilt, so sort order, scroll position and selection survive.
    param([object[]]$Existing=@(),[object[]]$Incoming=@(),[string]$KeyProperty='Guid',[string[]]$Properties=@(),[bool]$ContextChanged=$false)
    if ($ContextChanged) { return [pscustomobject]@{Mode='Replace';Updates=@();Inserts=@($Incoming);Unchanged=0;Reason='Contexte de recherche different.'} }
    $index = @{}
    foreach ($row in @($Existing)) {
        $key = ([string](Get-DomeniaMember $row $KeyProperty '')).ToLowerInvariant()
        if ($key -and -not $index.ContainsKey($key)) { $index[$key] = $row }
    }
    $updates = New-Object 'System.Collections.Generic.List[object]'
    $inserts = New-Object 'System.Collections.Generic.List[object]'
    $unchanged = 0
    $seen = @{}
    foreach ($row in @($Incoming)) {
        $key = ([string](Get-DomeniaMember $row $KeyProperty '')).ToLowerInvariant()
        if (-not $key) { continue }
        # A batch never introduces the same identity twice.
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        if (-not $index.ContainsKey($key)) { $inserts.Add($row); continue }
        $current = $index[$key]
        $names = @($Properties)
        if (-not $names.Count) { $names = @($row.PSObject.Properties | ForEach-Object { $_.Name }) }
        $changed = @{}
        foreach ($name in $names) {
            if ($name -eq $KeyProperty) { continue }
            $newValue = Get-DomeniaMember $row $name $null
            $oldValue = Get-DomeniaMember $current $name $null
            if ([string]$newValue -cne [string]$oldValue) { $changed[$name] = $newValue }
        }
        if ($changed.Count) { $updates.Add([pscustomobject]@{Key=$key;Row=$current;Changes=$changed}) } else { $unchanged++ }
    }
    return [pscustomobject]@{Mode='Merge';Updates=$updates.ToArray();Inserts=$inserts.ToArray();Unchanged=$unchanged;Reason=''}
}

# ---------------------------------------------------------------- D023 data paging
function New-DomeniaPageBuffer {
    param([ValidateRange(10,5000)][int]$PageSize=100,[ValidateRange(10,50000)][int]$MaxRowsInMemory=2000)
    return [pscustomobject]@{PageSize=$PageSize;MaxRowsInMemory=$MaxRowsInMemory;Rows=(New-Object System.Collections.ArrayList);Keys=(New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase));Pages=0;Limited=$false;Complete=$false;Dropped=0}
}

function Add-DomeniaPageRows {
    # Adds one page. Rows beyond the memory policy are refused and reported, never silently kept.
    param($Buffer,[object[]]$Rows=@(),[string]$KeyProperty='Guid',[bool]$LastPage=$false)
    $added = 0; $duplicates = 0
    foreach ($row in @($Rows)) {
        $key = [string](Get-DomeniaMember $row $KeyProperty '')
        if (-not $key) { continue }
        if ($Buffer.Rows.Count -ge $Buffer.MaxRowsInMemory) { $Buffer.Limited = $true; $Buffer.Dropped = [int]$Buffer.Dropped + 1; continue }
        if (-not $Buffer.Keys.Add($key)) { $duplicates++; continue }
        [void]$Buffer.Rows.Add($row); $added++
    }
    $Buffer.Pages = [int]$Buffer.Pages + 1
    if ($LastPage -and -not $Buffer.Limited) { $Buffer.Complete = $true }
    return [pscustomobject]@{Added=$added;Duplicates=$duplicates;Total=$Buffer.Rows.Count;Limited=[bool]$Buffer.Limited;Complete=[bool]$Buffer.Complete}
}

# ---------------------------------------------------------------- D024 freshness per nature
function Get-DomeniaDataNatures { return @('Identity','Attributes','Presence','Console','History') }

function Get-DomeniaFreshnessPolicy {
    param([Parameter(Mandatory=$true)][ValidateSet('Identity','Attributes','Presence','Console','History')][string]$Nature)
    switch ($Nature) {
        'Identity'   { return [pscustomobject]@{Nature=$Nature;FreshSeconds=86400;Label='Identite AD'} }
        'Attributes' { return [pscustomobject]@{Nature=$Nature;FreshSeconds=900;Label='Attributs AD'} }
        'Presence'   { return [pscustomobject]@{Nature=$Nature;FreshSeconds=120;Label='Presence reseau'} }
        'Console'    { return [pscustomobject]@{Nature=$Nature;FreshSeconds=300;Label='Session console'} }
        default      { return [pscustomobject]@{Nature=$Nature;FreshSeconds=0;Label='Historique'} }
    }
}

function Get-DomeniaFreshness {
    param([Parameter(Mandatory=$true)][string]$Nature,$ObservedUtc=$null,$LastAttemptUtc=$null,[datetime]$NowUtc=[datetime]::UtcNow)
    $policy = Get-DomeniaFreshnessPolicy $Nature
    $observed = ConvertTo-DomeniaUtcDate $ObservedUtc
    $attempt = ConvertTo-DomeniaUtcDate $LastAttemptUtc
    if ($null -eq $observed) {
        $label = $policy.Label + ' : jamais observe'
        if ($null -ne $attempt) { $label = $policy.Label + ' : tentative sans resultat le ' + $attempt.ToLocalTime().ToString('dd/MM HH:mm') }
        return [pscustomobject]@{Nature=$Nature;State='Unknown';AgeSeconds=-1;Label=$label;ObservedUtc=$null;LastAttemptUtc=$attempt}
    }
    $age = [Math]::Max(0,[long]($NowUtc - $observed).TotalSeconds)
    $state = 'Stale'
    if ($Nature -eq 'History') { $state = 'Historical' }
    elseif ($age -le $policy.FreshSeconds) { $state = 'Fresh' }
    $label = $policy.Label + ' : ' + $observed.ToLocalTime().ToString('dd/MM/yyyy HH:mm')
    if ($state -eq 'Stale') { $label += ' (a relire)' }
    if ($state -eq 'Historical') { $label += ' (historique)' }
    # A later failed attempt is shown; it never rejuvenates the observation.
    if ($null -ne $attempt -and $attempt -gt $observed) { $label += ' · derniere tentative ' + $attempt.ToLocalTime().ToString('dd/MM HH:mm') }
    return [pscustomobject]@{Nature=$Nature;State=$state;AgeSeconds=$age;Label=$label;ObservedUtc=$observed;LastAttemptUtc=$attempt}
}

function Get-DomeniaObservationTimes {
    # Copy the five known natures. JSON reloads produce PSCustomObject rather than dictionaries.
    # ISO UTC strings also survive the Windows PowerShell 5.1 JSON date round trip.
    param($Record)
    $times=@{};$stored=Get-DomeniaMember $Record 'Times' $null
    foreach($nature in Get-DomeniaDataNatures){
        $entry=Get-DomeniaMember $stored $nature $null
        if($null -eq $entry){continue}
        $observed=ConvertTo-DomeniaUtcDate (Get-DomeniaMember $entry 'ObservedUtc' $null)
        $attempt=ConvertTo-DomeniaUtcDate (Get-DomeniaMember $entry 'LastAttemptUtc' $null)
        $times[$nature]=[pscustomobject]@{ObservedUtc=$(if($null -ne $observed){$observed.ToString('o')}else{$null});LastAttemptUtc=$(if($null -ne $attempt){$attempt.ToString('o')}else{$null})}
    }
    # Legacy observations may supply real dates, but a reload never invents a new observation.
    if(-not $times.ContainsKey('Console') -and [string](Get-DomeniaMember $Record 'LastUser' '')){
        $observed=ConvertTo-DomeniaUtcDate (Get-DomeniaMember $Record 'ObservedUtc' $null)
        $attempt=ConvertTo-DomeniaUtcDate (Get-DomeniaMember $Record 'UserCheckedUtc' (Get-DomeniaMember $Record 'CheckedUtc' $null))
        if($null -ne $observed){$times['Console']=[pscustomobject]@{ObservedUtc=$observed.ToString('o');LastAttemptUtc=$(if($null -ne $attempt){$attempt.ToString('o')}else{$null})}}
    }
    if(-not $times.ContainsKey('Presence') -and [string](Get-DomeniaMember $Record 'Presence' '') -in @('En ligne','Sans réponse au ping')){
        $observed=ConvertTo-DomeniaUtcDate (Get-DomeniaMember $Record 'PresenceCheckedUtc' $null)
        if($null -ne $observed){$times['Presence']=[pscustomobject]@{ObservedUtc=$observed.ToString('o');LastAttemptUtc=$observed.ToString('o')}}
    }
    return $times
}

function Copy-DomeniaObservationTimes {
    param($Source,$Target)
    if($null -eq $Target){return $null}
    $sourceGuid=[string](Get-DomeniaMember $Source 'Guid' '')
    $targetGuid=[string](Get-DomeniaMember $Target 'Guid' '')
    $times=if($sourceGuid -and $targetGuid -and $sourceGuid -ine $targetGuid){@{}}else{Get-DomeniaObservationTimes $Source}
    if($Target -is [Collections.IDictionary]){$Target['Times']=$times}else{$Target | Add-Member -NotePropertyName Times -NotePropertyValue $times -Force}
    return $Target
}

function Set-DomeniaObservationTime {
    # A failed attempt never advances the last successful observation or another nature's date.
    param($Record,[Parameter(Mandatory=$true)][ValidateSet('Identity','Attributes','Presence','Console','History')][string]$Nature,[datetime]$WhenUtc=[datetime]::UtcNow,[bool]$Succeeded=$true)
    if($null -eq $Record){return $null}
    $times=Get-DomeniaObservationTimes $Record
    if(-not $times.ContainsKey($Nature)){$times[$Nature]=[pscustomobject]@{ObservedUtc=$null;LastAttemptUtc=$null}}
    $date=ConvertTo-DomeniaUtcDate $WhenUtc;$stamp=$date.ToString('o')
    $previousAttempt=ConvertTo-DomeniaUtcDate $times[$Nature].LastAttemptUtc
    $previousObservation=ConvertTo-DomeniaUtcDate $times[$Nature].ObservedUtc
    # Late progress packets cannot roll back a newer observation or attempt.
    if($null -eq $previousAttempt -or $date -ge $previousAttempt){$times[$Nature].LastAttemptUtc=$stamp}
    if($Succeeded -and ($null -eq $previousObservation -or $date -ge $previousObservation)){$times[$Nature].ObservedUtc=$stamp}
    if($Record -is [Collections.IDictionary]){$Record['Times']=$times}else{$Record | Add-Member -NotePropertyName Times -NotePropertyValue $times -Force}
    return $Record
}

function Get-DomeniaRecordFreshness {
    param($Record,[Parameter(Mandatory=$true)][string]$Nature,[datetime]$NowUtc=[datetime]::UtcNow)
    $entry=Get-DomeniaMember (Get-DomeniaObservationTimes $Record) $Nature $null
    return (Get-DomeniaFreshness $Nature (Get-DomeniaMember $entry 'ObservedUtc' $null) (Get-DomeniaMember $entry 'LastAttemptUtc' $null) $NowUtc)
}

# ---------------------------------------------------------------- D025 keys with identity and provenance
function Get-DomeniaCacheKey {
    # No password, token or credential object enters the key: only a hash of the reader's name.
    param([Parameter(Mandatory=$true)][string]$Domain,[string]$Guid='',[string]$Sid='',[string]$Reader='',[string]$Dc='',[string]$InvocationId='',[string]$Nature='Attributes',[string]$Version='')
    $identity = ConvertTo-DomeniaGuidText $Guid
    if (-not $identity) { $identity = ConvertTo-DomeniaSidText $Sid }
    if (-not $identity) { return '' }
    $readerHash = (Get-DomeniaTextHash ([string]$Reader).ToLowerInvariant()).Substring(0,16)
    return ('cache-v3|{0}|{1}|{2}|{3}|{4}|{5}|{6}' -f $Domain.ToLowerInvariant(),$identity.ToLowerInvariant(),$readerHash,([string]$Dc).ToLowerInvariant(),([string]$InvocationId).ToLowerInvariant(),$Nature,$Version)
}

function Test-DomeniaCacheEntryValid {
    # $Entry: what was stored. $Expected: the identity and provenance of the read being served now.
    param($Entry,$Expected)
    if ($null -eq $Entry -or $null -eq $Expected) { return [pscustomobject]@{Valid=$false;Reason='Entree ou contexte absent.'} }
    $entryGuid = ConvertTo-DomeniaGuidText (Get-DomeniaMember $Entry 'Guid' '')
    $expectedGuid = ConvertTo-DomeniaGuidText (Get-DomeniaMember $Expected 'Guid' '')
    if (-not $entryGuid) { return [pscustomobject]@{Valid=$false;Reason='Entree sans GUID.'} }
    if ($expectedGuid -and $entryGuid -ine $expectedGuid) { return [pscustomobject]@{Valid=$false;Reason='Meme DN, objet different (GUID different).'} }
    if (([string](Get-DomeniaMember $Entry 'Domain' '')) -ine ([string](Get-DomeniaMember $Expected 'Domain' ''))) { return [pscustomobject]@{Valid=$false;Reason='Domaine different.'} }
    if (([string](Get-DomeniaMember $Entry 'Reader' '')) -ine ([string](Get-DomeniaMember $Expected 'Reader' ''))) { return [pscustomobject]@{Valid=$false;Reason='Compte de lecture different.'} }
    $entryInvocation = [string](Get-DomeniaMember $Entry 'InvocationId' '')
    $expectedInvocation = [string](Get-DomeniaMember $Expected 'InvocationId' '')
    $entryUsn = [string](Get-DomeniaMember $Entry 'Usn' '')
    $expectedUsn = [string](Get-DomeniaMember $Expected 'Usn' '')
    if ($expectedUsn -and $entryUsn) {
        # A USN is local to one directory instance: equal numbers from two instances prove nothing.
        if (-not $entryInvocation -or -not $expectedInvocation -or $entryInvocation -ine $expectedInvocation) { return [pscustomobject]@{Valid=$false;Reason='USN non comparable : instance de controleur differente ou inconnue.'} }
        if ($entryUsn -ne $expectedUsn) { return [pscustomobject]@{Valid=$false;Reason='Version differente sur le meme controleur.'} }
    }
    return [pscustomobject]@{Valid=$true;Reason=''}
}

# ---------------------------------------------------------------- D026 careful incremental synchronisation
function Resolve-DomeniaIncrementalSync {
    # $Checkpoint: {Dc, InvocationId, Usn, ScopeDn}. $Response: {Dc, InvocationId, HighestUsn, Partial, VisibilityReduced, ScopeDn, Rows, KnownGuids}.
    # Absence from an answer is never turned into a deletion unless the whole scope was read on the same instance.
    param($Checkpoint,$Response)
    $notes = New-Object 'System.Collections.Generic.List[string]'
    $rows = @(Get-DomeniaMember $Response 'Rows' @())
    $sameInstance = ($null -ne $Checkpoint -and
        ([string](Get-DomeniaMember $Checkpoint 'Dc' '')) -ieq ([string](Get-DomeniaMember $Response 'Dc' '')) -and
        ([string](Get-DomeniaMember $Checkpoint 'InvocationId' '')) -and
        ([string](Get-DomeniaMember $Checkpoint 'InvocationId' '')) -ieq ([string](Get-DomeniaMember $Response 'InvocationId' '')))
    $sameScope = ($null -ne $Checkpoint -and ([string](Get-DomeniaMember $Checkpoint 'ScopeDn' '')) -ieq ([string](Get-DomeniaMember $Response 'ScopeDn' '')))
    $partial = [bool](Get-DomeniaMember $Response 'Partial' $false)
    $reduced = [bool](Get-DomeniaMember $Response 'VisibilityReduced' $false)
    $mode = 'Incremental'
    if (-not $sameInstance) { $mode = 'FullRescan'; $notes.Add('Controleur ou instance differents : le repere precedent n est pas reutilise.') }
    elseif (-not $sameScope) { $mode = 'FullRescan'; $notes.Add('Perimetre different : nouvelle lecture complete du perimetre choisi.') }
    $deletions = @()
    $canAssertAbsence = ($sameInstance -and $sameScope -and -not $partial -and -not $reduced -and [bool](Get-DomeniaMember $Response 'ScopeComplete' $false))
    if ($canAssertAbsence) {
        $returned = @{}
        foreach ($row in $rows) { $g = ConvertTo-DomeniaGuidText (Get-DomeniaMember $row 'Guid' ''); if ($g) { $returned[$g] = $true } }
        $deletions = @(@(Get-DomeniaMember $Response 'KnownGuids' @()) | ForEach-Object { ConvertTo-DomeniaGuidText $_ } | Where-Object { $_ -and -not $returned.ContainsKey($_) })
        if ($deletions.Count) { $notes.Add([string]$deletions.Count + ' objet(s) absents du perimetre complet : a marquer « non revu », pas a supprimer.') }
    } else {
        if ($partial) { $notes.Add('Reponse partielle : aucune absence n est deduite.') }
        if ($reduced) { $notes.Add('Visibilite reduite pour ce compte : aucune absence n est deduite.') }
    }
    $moves = New-Object 'System.Collections.Generic.List[object]'
    $knownDn = Get-DomeniaMember $Response 'KnownDnByGuid' $null
    if ($null -ne $knownDn) {
        foreach ($row in $rows) {
            $g = ConvertTo-DomeniaGuidText (Get-DomeniaMember $row 'Guid' '')
            if ($g -and $knownDn.ContainsKey($g) -and ([string]$knownDn[$g]) -ine ([string](Get-DomeniaMember $row 'DN' ''))) { $moves.Add([pscustomobject]@{Guid=$g;From=[string]$knownDn[$g];To=[string](Get-DomeniaMember $row 'DN' '')}) }
        }
    }
    $next = $null
    # The checkpoint only moves forward with the data it describes, and never after a partial answer.
    # A response whose instance is unknown (no invocationId) cannot become a checkpoint either: a later pass
    # could not prove it reads the same instance.
    $responseInvocation = [string](Get-DomeniaMember $Response 'InvocationId' '')
    $advance = (-not $partial -and -not $reduced -and [bool]$responseInvocation)
    if ($advance) { $next = [pscustomobject]@{Dc=[string](Get-DomeniaMember $Response 'Dc' '');InvocationId=$responseInvocation;Usn=[string](Get-DomeniaMember $Response 'HighestUsn' '');ScopeDn=[string](Get-DomeniaMember $Response 'ScopeDn' '')} }
    else { $next = $Checkpoint }
    # ScopeVerified: the whole scope was read on the instance of the checkpoint, so the local copy may mirror it
    # (rows absent from the answer may leave a local cache). It is never an AD deletion.
    return [pscustomobject]@{Mode=$mode;Upserts=$rows;Moves=$moves.ToArray();NotSeen=$deletions;DeletionsAsserted=@();CheckpointNext=$next;CheckpointAdvanced=$advance;ScopeVerified=$canAssertAbsence;Partial=$partial;SaveTogether=$true;Notes=$notes.ToArray()}
}

# ---------------------------------------------------------------- D027 temporary failure cache
function New-DomeniaNegativeCache { return @{} }

function Get-DomeniaNegativeTtlSeconds {
    param([Parameter(Mandatory=$true)][string]$Kind)
    switch ($Kind) {
        'Unreachable'        { return 120 }
        'Timeout'            { return 120 }
        'AccessDenied'       { return 600 }
        'CredentialRejected' { return 86400 }
        'Prerequisite'       { return 600 }
        default              { return 60 }
    }
}

function Register-DomeniaFailure {
    param($Cache,[Parameter(Mandatory=$true)][string]$Target,[Parameter(Mandatory=$true)][string]$Provider,[Parameter(Mandatory=$true)][string]$Kind,[datetime]$NowUtc=[datetime]::UtcNow,[string]$Detail='')
    if ($null -eq $Cache) { return $null }
    $key = ($Provider + '|' + $Target).ToLowerInvariant()
    $entry = [pscustomobject]@{Target=$Target;Provider=$Provider;Kind=$Kind;Detail=$Detail;FailedUtc=$NowUtc;UntilUtc=$NowUtc.AddSeconds((Get-DomeniaNegativeTtlSeconds $Kind))}
    $Cache[$key] = $entry
    return $entry
}

function Clear-DomeniaFailure {
    param($Cache,[string]$Target,[string]$Provider)
    if ($null -eq $Cache) { return }
    [void]$Cache.Remove(($Provider + '|' + $Target).ToLowerInvariant())
}

function Test-DomeniaNegativeCache {
    # A visual refresh does not hammer a machine that just failed. A voluntary retry always passes.
    param($Cache,[Parameter(Mandatory=$true)][string]$Target,[Parameter(Mandatory=$true)][string]$Provider,[datetime]$NowUtc=[datetime]::UtcNow,[bool]$Explicit=$false)
    if ($null -eq $Cache) { return [pscustomobject]@{Suppressed=$false;Reason='';UntilUtc=$null;Kind=''} }
    $key = ($Provider + '|' + $Target).ToLowerInvariant()
    if (-not $Cache.ContainsKey($key)) { return [pscustomobject]@{Suppressed=$false;Reason='';UntilUtc=$null;Kind=''} }
    $entry = $Cache[$key]
    if ($entry.UntilUtc -le $NowUtc) { [void]$Cache.Remove($key); return [pscustomobject]@{Suppressed=$false;Reason='';UntilUtc=$null;Kind=''} }
    if ($Explicit -and $entry.Kind -ne 'CredentialRejected') { return [pscustomobject]@{Suppressed=$false;Reason='Nouvelle tentative volontaire.';UntilUtc=$entry.UntilUtc;Kind=$entry.Kind} }
    $reason = 'Echec recent (' + $entry.Kind + ') : pas de nouvelle sonde avant ' + $entry.UntilUtc.ToLocalTime().ToString('HH:mm:ss') + '. La derniere donnee valide est conservee.'
    if ($entry.Kind -eq 'CredentialRejected') { $reason = 'Identifiants rejetes pour cette cible : changez de compte avant un nouvel essai.' }
    return [pscustomobject]@{Suppressed=$true;Reason=$reason;UntilUtc=$entry.UntilUtc;Kind=$entry.Kind}
}

# ---------------------------------------------------------------- D028 single writer queue
function New-DomeniaWriteQueue {
    param([ValidateRange(8,4096)][int]$Capacity=512)
    return [pscustomobject]@{Capacity=$Capacity;Items=(New-Object System.Collections.ArrayList);Index=@{};Sequence=0L;Rejected=0;Persisted=0L}
}

function Add-DomeniaWriteRequest {
    # Coalesces by table and key: the queue keeps the latest payload but remembers the version it was built from.
    param($Queue,[Parameter(Mandatory=$true)][string]$Table,[Parameter(Mandatory=$true)][string]$Key,[string]$BaseVersion='',$Payload=$null)
    $id = ($Table + '|' + $Key).ToLowerInvariant()
    if ($Queue.Index.ContainsKey($id)) {
        $existing = $Queue.Index[$id]
        $existing.Payload = $Payload
        return [pscustomobject]@{Accepted=$true;Coalesced=$true;Pending=$Queue.Items.Count}
    }
    if ($Queue.Items.Count -ge $Queue.Capacity) {
        $Queue.Rejected = [int]$Queue.Rejected + 1
        return [pscustomobject]@{Accepted=$false;Coalesced=$false;Pending=$Queue.Items.Count}
    }
    $Queue.Sequence = [long]$Queue.Sequence + 1
    $item = [pscustomobject]@{Id=$id;Table=$Table;Key=$Key;BaseVersion=$BaseVersion;Payload=$Payload;Sequence=[long]$Queue.Sequence}
    [void]$Queue.Items.Add($item); $Queue.Index[$id] = $item
    return [pscustomobject]@{Accepted=$true;Coalesced=$false;Pending=$Queue.Items.Count}
}

function Get-DomeniaWriteBatch {
    param($Queue,[ValidateRange(1,512)][int]$MaxItems=64)
    $batch = New-Object 'System.Collections.Generic.List[object]'
    while ($batch.Count -lt $MaxItems -and $Queue.Items.Count -gt 0) {
        $item = $Queue.Items[0]
        $Queue.Items.RemoveAt(0); [void]$Queue.Index.Remove($item.Id)
        $batch.Add($item)
    }
    return $batch.ToArray()
}

function Resolve-DomeniaWriteConflict {
    # Optimistic check done by the single writer inside its transaction.
    param([string]$StoredVersion='',[string]$BaseVersion='',[bool]$RowExists=$true)
    if (-not $RowExists) { return [pscustomobject]@{Apply=$true;Conflict=$false;Reason='Nouvelle ligne.'} }
    if (-not $BaseVersion) { return [pscustomobject]@{Apply=$false;Conflict=$true;Reason='Version de depart inconnue : la ligne enregistree est conservee.'} }
    if ($StoredVersion -cne $BaseVersion) { return [pscustomobject]@{Apply=$false;Conflict=$true;Reason='La ligne a change depuis sa lecture : aucune ecriture par-dessus.'} }
    return [pscustomobject]@{Apply=$true;Conflict=$false;Reason=''}
}

function Get-DomeniaPersistenceLabel {
    # D028: one sentence for the local save state, never claiming a save that did not happen. Priority: storage
    # unavailable, suspended, conflicts (an association changed by another console, kept on disk, ours only in memory
    # until the associations are reloaded), failures, pending, saved. Positional order of the first three is kept.
    # The conflict text names the gesture that really reloads them today (Comptes > Changer de compte, which calls
    # Request-DomeniaUserMachineLinks, or a restart): no dedicated reload button exists.
    param([int]$Pending=0,[int]$Failed=0,[bool]$Suspended=$false,[bool]$Unavailable=$false,[int]$Conflicts=0)
    if ($Unavailable) { return 'En memoire uniquement : stockage local indisponible, rien n est enregistre.' }
    if ($Suspended) { return 'En mémoire uniquement : enregistrement suspendu après des échecs. Reprise : « Reprendre les sauvegardes », Base autonome, onglet Stockage.' }
    if ($Conflicts -gt 0) { return ('En memoire : ' + $Conflicts + ' association(s) modifiee(s) ailleurs, non enregistree(s). Rechargez les associations : Comptes > Changer de compte, ou redemarrage.') }
    if ($Failed -gt 0) { return ('En memoire : ' + $Failed + ' enregistrement(s) en echec, nouvel essai prevu.') }
    if ($Pending -gt 0) { return ('En memoire : ' + $Pending + ' modification(s) a enregistrer.') }
    return 'Enregistre.'
}

# ---------------------------------------------------------------- D029 retention and quotas
function Get-DomeniaRetentionPolicy {
    # Manual cleanup policy, not the automatic writer's quotas. Reconstructible data is
    # emptied on request; only History uses an operator-selected age. No invented quotas.
    return @(
        [pscustomobject]@{Category='Observations';Label='Mesures de presence, console, inventaire et details WMI';Mode='All';Purgeable=$true}
        [pscustomobject]@{Category='Snapshots';Label='Captures et instantanes';Mode='All';Purgeable=$true}
        [pscustomobject]@{Category='History';Label='Historique ancien hors associations declarees';Mode='Bounded';Purgeable=$true}
        [pscustomobject]@{Category='Index';Label='Index des objets';Mode='All';Purgeable=$true}
        [pscustomobject]@{Category='Logs';Label='Journal d audit';Mode='Never';Purgeable=$false}
        [pscustomobject]@{Category='Configuration';Label='Configuration et preferences';Mode='Never';Purgeable=$false}
        [pscustomobject]@{Category='ManualLinks';Label='Associations declarees et leur historique';Mode='Never';Purgeable=$false}
        [pscustomobject]@{Category='Receipts';Label='Recus d operations';Mode='Never';Purgeable=$false}
    )
}

function Format-DomeniaSize {
    param([long]$Bytes)
    if ($Bytes -lt 0) { return 'inconnu' }
    if ($Bytes -lt 1024) { return ([string]$Bytes + ' o') }
    $units = @('Ko','Mo','Go','To'); $value = [double]$Bytes; $unit = 'o'
    foreach ($u in $units) { $value = $value / 1024; $unit = $u; if ($value -lt 1024) { break } }
    return ($value.ToString('0.#',[Globalization.CultureInfo]::GetCultureInfo('fr-FR')) + ' ' + $unit)
}

function Get-DomeniaPurgeTargets {
    # Closed identifiers, never SQL supplied by the UI. The pinned worker has its own
    # identical allowlist. PreserveDeclaredAssociations protects a historical source AND
    # the full history of a computer whose current association is declared.
    param([Parameter(Mandatory=$true)][string]$Category)
    switch($Category){
        'Observations' {
            [pscustomobject]@{Table='adcc_live_observations';TimeColumn='checked_utc';Filter='All';Action='Delete'}
            [pscustomobject]@{Table='presence_cache';TimeColumn='checked_at';Filter='All';Action='Delete'}
            [pscustomobject]@{Table='park_state';TimeColumn='last_probe';Filter='All';Action='Delete'}
            [pscustomobject]@{Table='park_session_cache';TimeColumn='checked_utc';Filter='All';Action='Delete'}
            [pscustomobject]@{Table='domenia_observations';TimeColumn='attempt_at';Filter='All';Action='Delete'}
            [pscustomobject]@{Table='domenia_details';TimeColumn='attempt_at';Filter='All';Action='Delete'}
            # Scope clocks of the ping and WMI campaigns (families Presence and Inventory), purged with their measures.
            [pscustomobject]@{Table='domenia_domain_metadata';TimeColumn='attempt_at';Filter='WorkstationRuns';Action='Delete'}
        }
        'Snapshots' {[pscustomobject]@{Table='adcc_live_queries';TimeColumn='observed_utc';Filter='All';Action='Delete'}}
        'History' {
            [pscustomobject]@{Table='user_machine_history';TimeColumn='observed_at';Filter='PreserveDeclaredAssociations';Action='Delete'}
            [pscustomobject]@{Table='user_scan_history';TimeColumn='scanned_at';Filter='All';Action='Delete'}
            [pscustomobject]@{Table='operation_runs';TimeColumn='finished_at';Filter='All';Action='Delete'}
            # Daily local snapshots of the fleet (FO-10), purged with the history.
            [pscustomobject]@{Table='fleet_snapshots';TimeColumn='snapshot_day';Filter='All';Action='Delete'}
        }
        'Index' {
            [pscustomobject]@{Table='ad_objects';TimeColumn='';Filter='All';Action='Delete'}
            [pscustomobject]@{Table='domenia_provenance';TimeColumn='';Filter='All';Action='Delete'}
            # Computer facts read with the index; secret_state (BitLocker and LAPS metadata) is never an index target.
            [pscustomobject]@{Table='ad_computer_facts';TimeColumn='';Filter='All';Action='Delete'}
            [pscustomobject]@{Table='domenia_directory_data';TimeColumn='';Filter='All';Action='Delete'}
            # Points 22, 24 and 30: census gaps, objects not seen again and directory snapshots copy directory rows; they
            # leave with the index (snapshot rows and their manifests in the same transaction).
            [pscustomobject]@{Table='ad_absences';TimeColumn='';Filter='All';Action='Delete'}
            [pscustomobject]@{Table='ad_census_gaps';TimeColumn='';Filter='All';Action='Delete'}
            [pscustomobject]@{Table='ad_snapshot_rows';TimeColumn='';Filter='All';Action='Delete'}
            [pscustomobject]@{Table='ad_snapshots';TimeColumn='';Filter='All';Action='Delete'}
            # Scope clock of the AD reads (family Directory), purged with the index it dated.
            [pscustomobject]@{Table='domenia_domain_metadata';TimeColumn='';Filter='DirectoryRuns';Action='Delete'}
            # Preserve other scopes, including the idempotence marker of an old-data import.
            [pscustomobject]@{Table='sync_state';TimeColumn='';Filter='DirectoryScope';Action='Reset'}
        }
        default {throw ('Categorie non purgeable : '+$Category)}
    }
}


function Get-DomeniaPurgePlan {
    param([object[]]$Usage=@(),[string[]]$Selection=@(),[datetime]$NowUtc=[datetime]::UtcNow,[ValidateRange(1,36500)][int]$HistoryAgeDays=730)
    $policy=@{};foreach($entry in @(Get-DomeniaRetentionPolicy)){$policy[$entry.Category]=$entry}
    $seen=@{};$actions=New-Object 'System.Collections.Generic.List[object]';$refused=New-Object 'System.Collections.Generic.List[string]'
    foreach($selected in $Selection){
        $key=([string]$selected).Trim()
        if($seen.ContainsKey($key)){continue};$seen[$key]=$true
        if(-not $policy.ContainsKey($key)){$refused.Add($key+' : categorie inconnue.');continue}
        $entry=$policy[$key]
        if(-not $entry.Purgeable){$refused.Add($entry.Label+' : jamais purge.');continue}
        $category=[string]$entry.Category
        $row=@($Usage | Where-Object {[string](Get-DomeniaMember $_ 'Category' '') -ieq $category} | Select-Object -First 1)
        $bytes=-1L;$rows=0L
        if($row.Count){$bytes=[long](Get-DomeniaMember $row[0] 'Bytes' -1);$rows=[long](Get-DomeniaMember $row[0] 'Rows' 0)}
        $cutoff=$null
        if($entry.Mode -eq 'Bounded'){$cutoff=$NowUtc.ToUniversalTime().AddDays(-$HistoryAgeDays).ToString('o')}
        $actions.Add([pscustomobject]@{Category=$category;Label=$entry.Label;Mode=$entry.Mode;OlderThanUtc=$cutoff;CurrentBytes=$bytes;CurrentRows=$rows;Targets=@(Get-DomeniaPurgeTargets $category)})
    }
    $targets=@($actions | ForEach-Object {$_.Targets})
    $tables=@($targets | ForEach-Object {$_.Table})
    $history=@($targets | Where-Object {$_.Table -eq 'user_machine_history'})
    return [pscustomobject]@{
        Actions=$actions.ToArray();Refused=$refused.ToArray()
        KeepsUnresolvedReceipts=($tables -notcontains 'receipts')
        KeepsConfiguration=($tables -notcontains 'configuration' -and $tables -notcontains 'preferences')
        KeepsManualLinks=($tables -notcontains 'user_machine_links' -and @($history | Where-Object {$_.Filter -ne 'PreserveDeclaredAssociations'}).Count -eq 0)
    }
}

# ---------------------------------------------------------------- D030 offline consultation
function Resolve-DomeniaDirectoryReachability {
    # Only a completed Directory request is evidence about directory reachability.
    # A query deadline is not proof of a network outage. Keep it as a separate warning.
    # A network comeback does not erase the outage: cached fiches still require a new read.
    param($State,[string]$Provider,[string]$Category='Unknown',[bool]$Cancelled=$false,[datetime]$NowUtc=[datetime]::UtcNow)
    $offline=[bool](Get-DomeniaMember $State 'Offline' $false)
    $slow=[bool](Get-DomeniaMember $State 'Slow' $false)
    $outage=Get-DomeniaMember $State 'LastOutageUtc' $null
    $success=Get-DomeniaMember $State 'LastSuccessUtc' $null
    $timeout=Get-DomeniaMember $State 'LastTimeoutUtc' $null
    $changed=$false
    if($Provider -eq 'Directory' -and -not $Cancelled){
        if($Category -eq 'Network'){
            $offline=$true;$slow=$false;$outage=$NowUtc.ToUniversalTime().ToString('o');$changed=$true
        } elseif($Category -eq 'Timeout'){
            $changed=(-not $slow);$slow=$true;$timeout=$NowUtc.ToUniversalTime().ToString('o')
        } elseif($Category -eq 'Success'){
            $changed=($offline -or $slow);$offline=$false;$slow=$false;$success=$NowUtc.ToUniversalTime().ToString('o')
        }
    }
    return [pscustomobject]@{Offline=$offline;Slow=$slow;LastOutageUtc=$outage;LastSuccessUtc=$success;LastTimeoutUtc=$timeout;Changed=$changed}
}

function Get-DomeniaCacheReadPolicy {
    # What may be done with a cached record. Reading and copying are possible offline; editing never is.
    param([bool]$HasSnapshot,[bool]$IdentityMatches,[bool]$FreshReadConfirmed,[bool]$Offline,[bool]$WriteUncertain)
    $view = ($HasSnapshot -and $IdentityMatches)
    $reason = 'Lecture AD confirmee'
    if (-not $HasSnapshot) { $reason = 'Aucune donnee en cache' }
    elseif (-not $IdentityMatches) { $reason = 'Identite non confirmee' }
    elseif ($WriteUncertain) { $reason = 'Operation a verifier' }
    elseif ($Offline) { $reason = 'Consultation historique hors ligne' }
    elseif (-not $FreshReadConfirmed) { $reason = 'Donnees en cache, relecture necessaire' }
    return [pscustomobject]@{
        CanView=$view;CanCopy=$view
        CanEdit=($view -and $FreshReadConfirmed -and -not $Offline -and -not $WriteUncertain)
        Historical=($view -and -not $FreshReadConfirmed)
        # Automatic retry policy only; an explicit read remains available offline.
        CanRetry=(-not $WriteUncertain -and -not $Offline)
        Reason=$reason
    }
}

function Get-DomeniaCacheCatalogRows {
    # One readable line per cached perimeter: source, dates, reader and what the data may be used for.
    param([object[]]$Entries=@(),[datetime]$NowUtc=[datetime]::UtcNow)
    foreach ($entry in @($Entries)) {
        if ($null -eq $entry) { continue }
        $observed = ConvertTo-DomeniaUtcDate (Get-DomeniaMember $entry 'ObservedUtc' $null)
        $age = ''
        if ($null -ne $observed) {
            $span = $NowUtc - $observed
            if ($span.TotalDays -ge 1) { $age = ([int]$span.TotalDays).ToString() + ' j' } elseif ($span.TotalHours -ge 1) { $age = ([int]$span.TotalHours).ToString() + ' h' } else { $age = ([int][Math]::Max(0,$span.TotalMinutes)).ToString() + ' min' }
        }
        [pscustomobject]@{
            Perimetre=[string](Get-DomeniaMember $entry 'Scope' '')
            Source=[string](Get-DomeniaMember $entry 'Source' '')
            Controleur=[string](Get-DomeniaMember $entry 'Dc' '')
            Lecteur=[string](Get-DomeniaMember $entry 'Reader' '')
            Objets=[long](Get-DomeniaMember $entry 'Rows' 0)
            Observe=$(if ($null -ne $observed) { $observed.ToLocalTime().ToString('dd/MM/yyyy HH:mm') } else { 'inconnu' })
            Age=$age
            Usage='Consultation historique. Aucune modification sans relecture AD.'
        }
    }
}

function Test-DomeniaProtectedAssociationSource {
    param([AllowNull()][string]$Source)
    return (([string]$Source).Trim() -in @('Manual','Saisie manuelle','Import CSV'))
}

# ---------------------------------------------------------------- FI-12, FI-13, UI-19 : base locale (lot X06)
function Get-DomeniaSqliteBusyTimeoutMs {
    # FI-12: lock wait of SQLite (LocalStore.DatabaseBusyTimeoutMs), clamped to 100..5000 ms like every connection.
    # An absent or unreadable value keeps the documented default of 2 500 ms (Get-WorkerContext applies the same rule).
    param($Value=$null)
    $number = 0
    if (($null -eq $Value) -or (-not [int]::TryParse(([string]$Value).Trim(),[ref]$number))) { return 2500 }
    return [int][Math]::Max(100,[Math]::Min(5000,$number))
}

function Test-DomeniaSqliteBusyText {
    # FI-12: a SQLite lock wait that ran out (SQLITE_BUSY 5, SQLITE_LOCKED 6), as worded by the workers
    # ('SQLite code 5', 'SQLite step code 5', 'SQLite prepare code 6'), the read worker ('SQLITE_BUSY') or SQLite itself.
    # The cross-process write lease ('StorageBusy') is another wait and is not counted here.
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    return [bool]($Text -match '(?i)\bSQLITE_(?:BUSY|LOCKED)\b|SQLite (?:prepare |step )?code [56](?!\d)|database (?:table )?is locked')
}

function Format-DomeniaSqliteBusySummary {
    # FI-12: one line for the Operations panel; session counters only, nothing is replayed from here.
    param([int]$Count=0,$LastUtc=$null,$TimeoutMs=2500)
    $timeout = [string](Get-DomeniaSqliteBusyTimeoutMs $TimeoutMs)
    if ($Count -le 0) { return ('Base locale : aucune attente de verrou SQLite dépassée dans cette session (délai ' + $timeout + ' ms).') }
    $text = 'Base locale occupée : ' + [string]$Count + ' attente(s) de verrou SQLite dépassée(s) dans cette session'
    if ($LastUtc -is [datetime]) { $text += ', la dernière à ' + $LastUtc.ToLocalTime().ToString('HH:mm:ss',[Globalization.CultureInfo]::InvariantCulture) }
    return ($text + ' (délai ' + $timeout + ' ms, réglage LocalStore.DatabaseBusyTimeoutMs).')
}

function Get-DomeniaGestureBackupLabel {
    # FI-13: the gestures that change the local base and are preceded by a verified backup: the AD read that rewrites
    # an OU (Index, Fleet and Search pages), the CSV import, the removal of orphan associations and the park reset.
    param([Parameter(Mandatory=$true)][ValidateSet('IndexUpdate','LinkImport','LinkPrune','ParkReset')][string]$Gesture)
    switch ($Gesture) {
        'IndexUpdate' { return 'la mise à jour de lʼOU choisie' }
        'LinkImport' { return 'lʼimport CSV des associations' }
        'LinkPrune' { return 'le retrait des associations orphelines' }
        default { return 'lʼoubli des relevés du parc' }
    }
}

function Get-DomeniaGestureBackupDecision {
    # FI-13: a verified backup of this base younger than ReuseMinutes is already the point of return of the gesture;
    # otherwise a new copy is due before it (StorageBackup worker, rotation of the backup policy). Pure rule.
    param([AllowEmptyString()][string]$LastSuccessUtc='',[datetime]$NowUtc=[datetime]::UtcNow,[int]$ReuseMinutes=30)
    $minutes = [Math]::Max(0,$ReuseMinutes)
    $now = $NowUtc.ToUniversalTime();$last = $null
    if (-not [string]::IsNullOrWhiteSpace($LastSuccessUtc)) {
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParse($LastSuccessUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$parsed)) { $last = $parsed.ToUniversalTime() }
    }
    if ($null -eq $last) { return [pscustomobject]@{Due=$true;Reason='NoBackup';LastUtc=$null;ReuseMinutes=$minutes} }
    # A date in the future cannot prove a recent copy: a new one is taken.
    if ($last -gt $now.AddMinutes(2)) { return [pscustomobject]@{Due=$true;Reason='InvalidClock';LastUtc=$last;ReuseMinutes=$minutes} }
    if ($last -ge $now.AddMinutes(-$minutes)) { return [pscustomobject]@{Due=$false;Reason='Recent';LastUtc=$last;ReuseMinutes=$minutes} }
    return [pscustomobject]@{Due=$true;Reason='Stale';LastUtc=$last;ReuseMinutes=$minutes}
}

function Get-DomeniaGestureBackupNotice {
    # FI-13: the sentence of the confirmation, true to what the gesture will do.
    param($Decision=$null)
    $due = $true;$last = $null;$minutes = 30
    if ($null -ne $Decision) { $due = [bool](Get-DomeniaMember $Decision 'Due' $true);$last = Get-DomeniaMember $Decision 'LastUtc' $null;$minutes = [int](Get-DomeniaMember $Decision 'ReuseMinutes' 30) }
    if ((-not $due) -and ($last -is [datetime])) { return ('Point de retour : la sauvegarde vérifiée de ' + $last.ToLocalTime().ToString('HH:mm',[Globalization.CultureInfo]::InvariantCulture) + ' a moins de ' + [string]$minutes + ' min ; aucune nouvelle copie.') }
    return 'Une sauvegarde vérifiée de la base sera faite avant.'
}

function Get-DomeniaElapsedText {
    # 'à lʼinstant', 'il y a 5 min', 'il y a 2 h', 'il y a 3 j' between two UTC times; a future date is named as such.
    param([datetime]$FromUtc,[datetime]$NowUtc=[datetime]::UtcNow)
    $span = $NowUtc.ToUniversalTime() - $FromUtc.ToUniversalTime()
    if ($span.TotalMinutes -lt -5) { return 'à une date future (horloge à vérifier)' }
    if ($span.TotalMinutes -lt 1) { return 'à lʼinstant' }
    if ($span.TotalHours -lt 1) { return ('il y a ' + [string][int][Math]::Floor($span.TotalMinutes) + ' min') }
    if ($span.TotalDays -lt 1) { return ('il y a ' + [string][int][Math]::Floor($span.TotalHours) + ' h') }
    return ('il y a ' + [string][int][Math]::Floor($span.TotalDays) + ' j')
}

function Get-DomeniaDatabaseLocationSummary {
    # UI-19: « Base du domaine example.local · 4,2 Mo · sauvegardée il y a 2 h » instead of the file path, which stays
    # in the tooltip and the copy button. No backup, or one older than StaleDays, gives a soft alert. Pure rule.
    param([AllowEmptyString()][string]$Domain='',[long]$Bytes=-1,$LastBackupUtc=$null,[datetime]$NowUtc=[datetime]::UtcNow,[int]$StaleDays=7,[switch]$Demo,[switch]$Missing)
    if ($Missing) { return [pscustomobject]@{Text='Aucune base locale pour ce domaine pour lʼinstant.';Alert=$false;AlertText=''} }
    $name = ([string]$Domain).Trim()
    $head = if ($Demo) { 'Base de démonstration' } elseif ($name) { 'Base du domaine ' + $name } else { 'Base locale' }
    $size = if ($Bytes -ge 0) { Format-DomeniaSize $Bytes } else { 'taille inconnue' }
    $alert = $false;$alertText = ''
    if ($LastBackupUtc -is [datetime]) {
        $saved = 'sauvegardée ' + (Get-DomeniaElapsedText -FromUtc $LastBackupUtc -NowUtc $NowUtc)
        if (($NowUtc.ToUniversalTime() - $LastBackupUtc.ToUniversalTime()).TotalDays -gt [Math]::Max(1,$StaleDays)) {
            $alert = $true;$alertText = 'Dernière sauvegarde il y a plus de ' + [string][Math]::Max(1,$StaleDays) + ' jours : pensez à « Sauvegarder maintenant ».'
        }
    }
    else { $saved = 'jamais sauvegardée';$alert = (-not $Demo);if ($alert) { $alertText = 'Aucune sauvegarde de cette base : pensez à « Sauvegarder maintenant ».' } }
    return [pscustomobject]@{Text=($head + ' · ' + $size + ' · ' + $saved);Alert=$alert;AlertText=$alertText}
}

function Get-DomeniaIndexTiles {
    # DS-09: the four figures of the local base as tiles (accounts, workstations, associations, last update of the
    # chosen perimeter). The USN, the memory use and the durations stay in the journal. Pure rule, fr-FR figures.
    param([long]$Users=0,[long]$Computers=0,[long]$Active=0,[long]$Disabled=0,[long]$Links=0,$LastUtc=$null,[datetime]$NowUtc=[datetime]::UtcNow,[switch]$Unreadable)
    $fr = [Globalization.CultureInfo]::GetCultureInfo('fr-FR')
    if ($Unreadable) {
        return @(
            [pscustomobject]@{Key='Accounts';Caption='Comptes';Value='—';Detail='base illisible'}
            [pscustomobject]@{Key='Computers';Caption='Postes';Value='—';Detail='base illisible'}
            [pscustomobject]@{Key='Links';Caption='Associations';Value='—';Detail='base illisible'}
            [pscustomobject]@{Key='Updated';Caption='Dernière mise à jour';Value='—';Detail='base illisible'}
        )
    }
    $users = [Math]::Max(0L,$Users);$computers = [Math]::Max(0L,$Computers);$links = [Math]::Max(0L,$Links)
    $active = [Math]::Max(0L,$Active);$disabled = [Math]::Max(0L,$Disabled)
    $updatedValue = 'Jamais';$updatedDetail = 'aucune lecture complète de ce périmètre'
    if ($LastUtc -is [datetime]) {
        $updatedValue = Get-DomeniaElapsedText -FromUtc $LastUtc -NowUtc $NowUtc
        $updatedDetail = 'le ' + $LastUtc.ToLocalTime().ToString('dd/MM/yyyy HH:mm',[Globalization.CultureInfo]::InvariantCulture)
    }
    return @(
        [pscustomobject]@{Key='Accounts';Caption='Comptes';Value=$users.ToString('N0',$fr);Detail='comptes utilisateurs'}
        [pscustomobject]@{Key='Computers';Caption='Postes';Value=$computers.ToString('N0',$fr);Detail=($active.ToString('N0',$fr) + ' actifs · ' + $disabled.ToString('N0',$fr) + ' désactivés')}
        [pscustomobject]@{Key='Links';Caption='Associations';Value=$links.ToString('N0',$fr);Detail='liens utilisateur-poste'}
        [pscustomobject]@{Key='Updated';Caption='Dernière mise à jour';Value=$updatedValue;Detail=$updatedDetail}
    )
}

# ---------------------------------------------------------------- FI-19 local reads answered off the Dispatcher
# The LocalIndexRead worker answers the reads that used to run on the WPF thread; these rules turn its answer into the
# state the interface keeps. A missing base is an empty base, a refused or unreadable answer is never presented empty.
function ConvertTo-DomeniaIndexMetadataState {
    # IndexMetadata answer -> sync rows by scope, the directory checkpoint (InvocationId read from 'inv=' in details)
    # and the counters of the Outils page.
    param($Result)
    if ($null -eq $Result) { throw 'Réponse de la base locale absente.' }
    $missing = [bool](Get-DomeniaMember $Result 'Missing' $false)
    $syncStates = @{}
    $counts = [pscustomobject]@{ Total=0; Users=0; Computers=0; MachinesActive=0; MachinesDisabled=0 }
    if (-not $missing) {
        if (($null -eq $Result.PSObject.Properties['SyncStates']) -or ($null -eq $Result.PSObject.Properties['Counts'])) { throw 'Réponse de la base locale incomplète.' }
        foreach ($row in @(Get-DomeniaMember $Result 'SyncStates' @())) {
            if ($null -eq $row) { continue }
            $scope = [string](Get-DomeniaMember $row 'scope' '')
            if ($scope) { $syncStates[$scope] = $row }
        }
        $c = Get-DomeniaMemberValue $Result 'Counts'
        $counts = [pscustomobject]@{
            Total=[int](Get-DomeniaMember $c 'Total' 0); Users=[int](Get-DomeniaMember $c 'Users' 0); Computers=[int](Get-DomeniaMember $c 'Computers' 0)
            MachinesActive=[int](Get-DomeniaMember $c 'MachinesActive' 0); MachinesDisabled=[int](Get-DomeniaMember $c 'MachinesDisabled' 0)
        }
    }
    $info = $null
    if ($syncStates.ContainsKey('directory')) {
        $d = $syncStates['directory']
        $inv = ''
        $m = [regex]::Match([string](Get-DomeniaMember $d 'details' ''),'(?i)inv=([0-9a-f-]{36})')
        if ($m.Success) { $inv = $m.Groups[1].Value }
        $info = [pscustomobject]@{
            Server=[string](Get-DomeniaMember $d 'server' ''); BaseDn=[string](Get-DomeniaMember $d 'base_dn' ''); Date=[string](Get-DomeniaMember $d 'last_sync' '')
            Count=[int](Get-DomeniaMember $d 'item_count' 0); Usn=[long](Get-DomeniaMember $d 'highest_usn' 0); InvocationId=$inv
            # Point 22: census identities still missing from the local copy (0 for a base without census).
            CensusGap=[long](Get-DomeniaMember $Result 'CensusGap' 0)
        }
    }
    return [pscustomobject]@{ SyncStates=$syncStates; Info=$info; Counts=$counts; Missing=$missing }
}

function Format-DomeniaSecretIndexSummary {
    # One sentence from the non-secret metadata of a workstation (SecretIndexEntry row): key count and date, LAPS
    # scheme and expiration, access verdict. '' when nothing was recorded. A value is never part of it.
    param($Entry,[datetime]$Now=(Get-Date))
    if ($null -eq $Entry) { return '' }
    $parts = New-Object 'System.Collections.Generic.List[string]'
    $keys = [int](Get-DomeniaMember $Entry 'bitlocker_keys' -1)
    $last = [string](Get-DomeniaMember $Entry 'bitlocker_last' '')
    if ($keys -gt 0) {
        $text = '{0} clé(s) BitLocker' -f $keys
        if (-not [string]::IsNullOrWhiteSpace($last)) { $text += ', la plus récente du ' + $last }
        $parts.Add($text)
    }
    elseif ($keys -eq 0) { $parts.Add('aucune clé BitLocker') }
    $scheme = [string](Get-DomeniaMember $Entry 'laps_scheme' '')
    if (-not [string]::IsNullOrWhiteSpace($scheme)) {
        $text = $scheme
        $expiry = [string](Get-DomeniaMember $Entry 'laps_expiry' '')
        if (-not [string]::IsNullOrWhiteSpace($expiry)) { $text += ', expiration ' + $expiry }
        $parts.Add($text)
    }
    if ($parts.Count -eq 0) { return '' }
    $checked = [string](Get-DomeniaMember $Entry 'checked_at' '')
    $age = 'le ' + $checked
    try {
        $span = $Now - [datetime]$checked
        if ([int]$span.TotalDays -ge 1) { $age = 'il y a ' + [int]$span.TotalDays + ' jour(s)' }
        else { $age = 'il y a ' + [int]$span.TotalHours + ' heure(s)' }
    }
    catch { $age = 'le ' + $checked }
    $verdict = [string](Get-DomeniaMember $Entry 'verdict' '')
    if (-not [string]::IsNullOrWhiteSpace($verdict)) { $verdict = ' ' + $verdict + '.' } else { $verdict = '' }
    return ('Relevé {0} : {1}.{2} Les valeurs ne sont jamais conservées : il faut les recharger.' -f $age,($parts.ToArray() -join ', '),$verdict)
}

function ConvertTo-DomeniaOperationHistoryModels {
    # OperationStats rows -> history model per operation for the impact estimates (samples with a duration only).
    param([object[]]$Rows=@())
    $models = @{}
    foreach ($row in @($Rows)) {
        if ($null -eq $row) { continue }
        $name = [string](Get-DomeniaMember $row 'operation' '')
        if (-not $name) { continue }
        $models[$name] = [pscustomobject]@{
            n=[int](Get-DomeniaMember $row 'n' 0)
            ms_per_item=(Get-DomeniaMember $row 'ms_per_item' $null); min_ms_per_item=(Get-DomeniaMember $row 'min_ms_per_item' $null); max_ms_per_item=(Get-DomeniaMember $row 'max_ms_per_item' $null)
            bytes_per_item=(Get-DomeniaMember $row 'bytes_per_item' $null); fallback_ratio=(Get-DomeniaMember $row 'fallback_ratio' $null); success_ratio=(Get-DomeniaMember $row 'success_ratio' $null)
        }
    }
    return $models
}

function Get-DomeniaParkCoverageFigures {
    # Coverage of the stored park survey. The workstation count comes from the in-memory index when it is loaded,
    # otherwise from the count read with the stored survey (LocalIndexRead ParkState); -1 means not read yet.
    param([Collections.IDictionary]$State,[object[]]$IndexRows=@(),[int]$KnownMachineCount=-1,[int]$Dormants=0)
    $machines = $KnownMachineCount
    $rows = @($IndexRows | Where-Object { $null -ne $_ })
    if ($rows.Count -gt 0) { $machines = @($rows | Where-Object { ([string]$_.Type -eq 'Machine') -and ([string]$_.State -ne 'Desactive') }).Count }
    $surveyed = 0; $withSession = 0; $latest = ''; $latestAt = $null
    if ($null -ne $State) {
        foreach ($key in @($State.Keys)) {
            $entry = $State[$key]
            $surveyed++
            if ([string](Get-DomeniaMember $entry 'Status' '') -eq 'Session') { $withSession++ }
            $text = [string](Get-DomeniaMember $entry 'LastProbe' '')
            $at = $null
            try { if ($text) { $at = [datetime]$text } } catch { $at = $null }
            if ($null -ne $at) { if (($null -eq $latestAt) -or ($at -gt $latestAt)) { $latestAt = $at; $latest = $text } }
            elseif (-not $latest) { $latest = $text }
        }
    }
    return [pscustomobject]@{ Machines=$machines; Releves=$surveyed; AvecSession=$withSession; Dernier=$latest; Dormants=$Dormants }
}
