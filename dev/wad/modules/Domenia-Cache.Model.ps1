# Cache and loading rules: projections, cell updates, paging, freshness per nature of data,
# cache keys, incremental synchronisation, negative cache, single writer, retention, offline policy.
# Pure decisions: no SQLite, no LDAP and no file is touched here.

# ---------------------------------------------------------------- D021 minimal projection
function Get-DomeniaProjection {
    # Attributes requested for one purpose. A list never asks for memberships or security descriptors.
    param([Parameter(Mandatory=$true)][ValidateSet('List','Detail','Groups','Security','Presence','Identity')][string]$Kind)
    switch ($Kind) {
        'Identity' { return @('objectGUID','objectSid','distinguishedName','objectClass','name','sAMAccountName') }
        'List'     { return @('objectGUID','objectSid','distinguishedName','objectClass','name','sAMAccountName','userPrincipalName','dNSHostName','displayName','userAccountControl','msDS-User-Account-Control-Computed','lockoutTime','operatingSystem','lastLogonTimestamp','mail','description','whenChanged','adminCount') }
        'Groups'   { return @('objectGUID','distinguishedName','memberOf','primaryGroupID') }
        'Security' { return @('objectGUID','distinguishedName','nTSecurityDescriptor') }
        'Presence' { return @('objectGUID','distinguishedName','dNSHostName','name') }
        default    { return @() }
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

function Set-DomeniaObservationTime {
    # Records an observation or an attempt for ONE nature. The other natures keep their own dates:
    # a successful ping never rejuvenates the historical user or the AD attributes.
    param($Record,[Parameter(Mandatory=$true)][ValidateSet('Identity','Attributes','Presence','Console','History')][string]$Nature,[datetime]$WhenUtc=[datetime]::UtcNow,[bool]$Succeeded=$true)
    if ($null -eq $Record) { return $null }
    $times = Get-DomeniaMember $Record 'Times' $null
    if ($null -eq $times) {
        $times = @{}
        if ($Record -is [Collections.IDictionary]) { $Record['Times'] = $times } else { $Record | Add-Member -NotePropertyName Times -NotePropertyValue $times -Force }
    }
    if (-not $times.ContainsKey($Nature)) { $times[$Nature] = [pscustomobject]@{ObservedUtc=$null;LastAttemptUtc=$null} }
    $times[$Nature].LastAttemptUtc = $WhenUtc
    if ($Succeeded) { $times[$Nature].ObservedUtc = $WhenUtc }
    return $Record
}

function Get-DomeniaRecordFreshness {
    param($Record,[Parameter(Mandatory=$true)][string]$Nature,[datetime]$NowUtc=[datetime]::UtcNow)
    $times = Get-DomeniaMember $Record 'Times' $null
    $entry = $null
    if ($null -ne $times -and $times.ContainsKey($Nature)) { $entry = $times[$Nature] }
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
    if (-not $partial) { $next = [pscustomobject]@{Dc=[string](Get-DomeniaMember $Response 'Dc' '');InvocationId=[string](Get-DomeniaMember $Response 'InvocationId' '');Usn=[string](Get-DomeniaMember $Response 'HighestUsn' '');ScopeDn=[string](Get-DomeniaMember $Response 'ScopeDn' '')} }
    else { $next = $Checkpoint }
    return [pscustomobject]@{Mode=$mode;Upserts=$rows;Moves=$moves.ToArray();NotSeen=$deletions;DeletionsAsserted=@();CheckpointNext=$next;SaveTogether=$true;Notes=$notes.ToArray()}
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
    param([int]$Pending=0,[int]$Failed=0,[bool]$Suspended=$false)
    if ($Suspended) { return 'En memoire uniquement : enregistrement suspendu apres des echecs. Reprise dans Fiabilite.' }
    if ($Failed -gt 0) { return ('En memoire : ' + $Failed + ' enregistrement(s) en echec, nouvel essai prevu.') }
    if ($Pending -gt 0) { return ('En memoire : ' + $Pending + ' modification(s) a enregistrer.') }
    return 'Enregistre.'
}

# ---------------------------------------------------------------- D029 retention and quotas
function Get-DomeniaRetentionPolicy {
    # Purgeable=$false categories are never offered to the purge, whatever the operator selects.
    return @(
        [pscustomobject]@{Category='Observations';Label='Observations de presence et de console';MaxAgeDays=90;MaxRows=200000;Purgeable=$true}
        [pscustomobject]@{Category='Snapshots';Label='Captures et instantanes';MaxAgeDays=180;MaxRows=5000;Purgeable=$true}
        [pscustomobject]@{Category='Logs';Label='Journaux';MaxAgeDays=60;MaxRows=0;Purgeable=$true}
        [pscustomobject]@{Category='History';Label='Historique des relations';MaxAgeDays=730;MaxRows=100000;Purgeable=$true}
        [pscustomobject]@{Category='Index';Label='Index des objets';MaxAgeDays=0;MaxRows=0;Purgeable=$true}
        [pscustomobject]@{Category='Configuration';Label='Configuration et preferences';MaxAgeDays=0;MaxRows=0;Purgeable=$false}
        [pscustomobject]@{Category='ManualLinks';Label='Associations declarees';MaxAgeDays=0;MaxRows=0;Purgeable=$false}
        [pscustomobject]@{Category='Receipts';Label='Recus d operations';MaxAgeDays=0;MaxRows=0;Purgeable=$false}
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

function Get-DomeniaPurgePlan {
    # $Usage: rows {Category, Bytes, Rows, OldestUtc}. $Selection: categories ticked by the operator.
    param([object[]]$Usage=@(),[string[]]$Selection=@(),[datetime]$NowUtc=[datetime]::UtcNow)
    $policy = @{}
    foreach ($entry in @(Get-DomeniaRetentionPolicy)) { $policy[$entry.Category] = $entry }
    $actions = New-Object 'System.Collections.Generic.List[object]'
    $refused = New-Object 'System.Collections.Generic.List[string]'
    foreach ($category in @($Selection | Select-Object -Unique)) {
        if (-not $policy.ContainsKey($category)) { $refused.Add($category + ' : categorie inconnue.'); continue }
        if (-not $policy[$category].Purgeable) { $refused.Add($policy[$category].Label + ' : jamais purge.'); continue }
        $row = @(@($Usage) | Where-Object { [string](Get-DomeniaMember $_ 'Category' '') -eq $category } | Select-Object -First 1)
        $bytes = 0L; $rows = 0L
        if ($row.Count) { $bytes = [long](Get-DomeniaMember $row[0] 'Bytes' 0); $rows = [long](Get-DomeniaMember $row[0] 'Rows' 0) }
        $cutoff = $null
        if ($policy[$category].MaxAgeDays -gt 0) { $cutoff = $NowUtc.AddDays(-1 * $policy[$category].MaxAgeDays) }
        $actions.Add([pscustomobject]@{Category=$category;Label=$policy[$category].Label;OlderThanUtc=$cutoff;MaxRows=$policy[$category].MaxRows;CurrentBytes=$bytes;CurrentRows=$rows})
    }
    return [pscustomobject]@{Actions=$actions.ToArray();Refused=$refused.ToArray();KeepsUnresolvedReceipts=$true;KeepsConfiguration=$true;KeepsManualLinks=$true}
}

# ---------------------------------------------------------------- D030 offline consultation
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
